"""Synthetic PostgreSQL16 integration on an explicitly enabled disposable Linux CI runner.

No AWS calls, legacy data, application code or published database ports. Do not
enable this test on a host whose data/containers belong to another environment.
"""
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from unittest.mock import patch

IMAGE = 'postgres@sha256:472efd9a66f2b2f1a5aeb18b28de74332e6ef88c2b93a1a5d812fb6db67a5f60'
spec = importlib.util.spec_from_file_location('database_backup', Path(__file__).parents[1] / 'operations/dev-database/backup.py')
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class Storage:
    objects = {}
    downloads = []

    def __init__(self, config):
        self.bucket = config['bucket']

    def upload(self, path, key):
        data = path.read_bytes()
        version = uuid.uuid4().hex
        self.objects[(key, version)] = data
        return {'key': key, 'version': version, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

    def download(self, item, destination):
        self.downloads.append((item['key'], item['version']))
        data = self.objects[(item['key'], item['version'])]
        assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']
        destination.write_bytes(data)


def main():
    if sys.platform != 'linux' or os.geteuid() != 0 or os.environ.get('CHICO_DATABASE_INTEGRATION') != 'true':
        raise SystemExit('Requires explicit enablement on disposable Linux CI; no containers started')
    os.umask(0o077)
    suffix = uuid.uuid4().hex[:12]
    source_name = 'chico-dev-database-integration-' + suffix
    proof_name = 'chico-dev-database-proof-' + suffix
    data_roots = [Path('/srv/chico/database-integration') / suffix, Path('/srv/chico/restore-proof') / suffix]
    secret_root = Path('/run/chico/database-proof-' + suffix)
    created_paths = []
    containers = []
    try:
        backup.invoke(['docker', 'pull', IMAGE], timeout=600)
        uid = int(backup.invoke(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'id', IMAGE, '-u', 'postgres']).strip())
        gid = int(backup.invoke(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'id', IMAGE, '-g', 'postgres']).strip())
        secret_root.mkdir(parents=True, mode=0o700)
        created_paths.append(secret_root)
        for data_root, name, role, purpose in zip(data_roots, [source_name, proof_name], ['dev_backup', 'dev_proof'], ['database', 'database-proof']):
            data_root.mkdir(parents=True, mode=0o700)
            created_paths.append(data_root)
            data = data_root / 'pgdata'
            data.mkdir(mode=0o700)
            os.chown(data, uid, gid)
            password = secrets.token_hex(32)
            init = secret_root / (role + '_init_password')
            pgpass = secret_root / (role + '_pgpass')
            init.write_text(password + '\n')
            pgpass.write_text(f'127.0.0.1:5432:chico_dev:{role}:{password}\n')
            for path in (init, pgpass):
                os.chmod(path, 0o600)
                os.chown(path, uid, gid)
            args = ['docker', 'run', '-d', '--name', name, '--user', f'{uid}:{gid}', '--network', 'none', '--read-only',
                    '--restart', 'no', '--cpus', '1', '--memory', '768m', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                    '--tmpfs', f'/var/run/postgresql:rw,uid={uid},gid={gid},size=16m', '--tmpfs', '/tmp:rw,size=64m',
                    '--label', 'org.chico.environment=dev', '--label', 'org.chico.role=' + purpose,
                    '--mount', f'type=bind,src={data},dst=/var/lib/postgresql/data',
                    '--mount', f'type=bind,src={init},dst=/run/secrets/init_password,readonly',
                    '--mount', f'type=bind,src={pgpass},dst=/run/secrets/{role}_pgpass,readonly',
                    '-e', 'POSTGRES_USER=' + role, '-e', 'POSTGRES_DB=chico_dev',
                    '-e', 'POSTGRES_PASSWORD_FILE=/run/secrets/init_password', IMAGE,
                    '-c', 'shared_preload_libraries=pg_stat_statements']
            container_id = backup.invoke(args).decode().strip()
            containers.append(container_id)
            for _ in range(60):
                result = subprocess.run(['docker', 'exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', role, '-d', 'chico_dev'],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result.returncode == 0:
                    break
                time.sleep(1)
            else:
                raise RuntimeError('synthetic database readiness failed')
        source = backup.Database(source_name, 'chico_dev', 'dev_backup')
        sql = b"""
CREATE EXTENSION pg_trgm; CREATE EXTENSION pg_stat_statements;
CREATE TABLE public.items(id bigserial PRIMARY KEY, value text NOT NULL CHECK(value<>''));
INSERT INTO public.items(value) SELECT 'synthetic-'||n FROM generate_series(1,1000) n;
CREATE TABLE public.empty_items(id bigserial PRIMARY KEY);
CREATE TABLE public.alembic_version(version_num varchar(64) PRIMARY KEY);
INSERT INTO public.alembic_version VALUES('synthetic_backup_1');
CREATE SCHEMA reporting;
CREATE TYPE reporting.status AS ENUM('synthetic_a','synthetic_b');
CREATE VIEW reporting.item_count AS SELECT count(*) AS total FROM public.items;
CREATE MATERIALIZED VIEW reporting.first_items AS SELECT id,value FROM public.items ORDER BY id LIMIT 10;
CREATE FUNCTION reporting.item_count_function() RETURNS bigint LANGUAGE sql STABLE AS 'SELECT count(*) FROM public.items';
CREATE SEQUENCE reporting.desc_seq INCREMENT -1 MINVALUE -10000 MAXVALUE -1 START -1;
CREATE TABLE reporting.descending(id bigint DEFAULT nextval('reporting.desc_seq'));
ALTER SEQUENCE reporting.desc_seq OWNED BY reporting.descending.id;
INSERT INTO reporting.descending DEFAULT VALUES;
SELECT lo_from_bytea(0,decode('112233','hex'));
"""
        backup.invoke(source.command('psql', '-X', '-qAt', '--set=ON_ERROR_STOP=1'), input=sql)
        original_snapshot = backup.exported_snapshot

        @contextmanager
        def write_after_export(database):
            with original_snapshot(database) as snapshot:
                # Prove the exported snapshot excludes a concurrent committed writer.
                backup.invoke(source.command('psql', '-X', '-qAt', '--set=ON_ERROR_STOP=1'), input=b"INSERT INTO public.items(value) VALUES('concurrent-synthetic');")
                yield snapshot

        config = {'account_id': '123456789012', 'bucket': 'chico-dev-ci-synthetic-only', 'database': 'chico_dev'}
        with tempfile.TemporaryDirectory() as temporary, patch.object(backup, 'Storage', Storage), patch.object(backup, 'SOURCE_CONTAINER', source_name), patch.object(backup, 'STATE_ROOT', Path(temporary) / 'state'), patch.object(backup, 'exported_snapshot', write_after_export):
            root = Path(temporary)
            work = root / 'backup'
            work.mkdir()
            reference = backup.backup(config, work)
            manifest = json.loads((work / 'manifest.json').read_text())
            count = next(item['rows'] for item in manifest['tables'] if item['schema'] == 'public' and item['name'] == 'items')
            assert count == 1000 and int(source.sql('SELECT count(*) FROM public.items;')) == 1001
            wrong_work = root / 'unreviewed'
            wrong_work.mkdir()
            try:
                backup.proof(config, wrong_work, reference, proof_name, '0' * 64)
                raise AssertionError('unreviewed dump was accepted')
            except backup.OperationFailed as error:
                assert error.args == ('dump_not_privately_reviewed',)
            verify_work = root / 'proof'
            verify_work.mkdir()
            result = backup.proof(config, verify_work, reference, proof_name, manifest['dumpSHA256'])
            assert result['verified'] and result['tablesReconciled'] == 5 and not result['rowsEmitted']
            repeated_work = root / 'refuse-overwrite'
            repeated_work.mkdir()
            try:
                backup.proof(config, repeated_work, reference, proof_name, manifest['dumpSHA256'])
                raise AssertionError('existing restored database was accepted')
            except backup.OperationFailed as error:
                assert error.args == ('proof_database_not_empty',)
            assert json.loads((backup.STATE_ROOT / 'database-last-restore-proof.json').read_text())['commit'] == reference['commit']
        print(json.dumps({'syntheticOnly': True, 'postgres16DumpRestorePassed': True,
                          'sameSnapshotCountsPassed': True, 'reviewedHashEnforced': True,
                          'existingDestinationRefused': True, 'awsCalls': 0, 'rowsEmitted': False}))
    finally:
        for container_id in reversed(containers):
            subprocess.run(['docker', 'rm', '-f', container_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        for path in reversed(created_paths):
            if path.name not in (suffix, 'database-proof-' + suffix):
                raise RuntimeError('unexpected cleanup target')
            shutil.rmtree(path)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        safe = error.args[0] if isinstance(error, backup.OperationFailed) else type(error).__name__
        raise SystemExit(f'Synthetic database integration failed: {safe}; raw SQL/rows/credentials/errors omitted') from None
