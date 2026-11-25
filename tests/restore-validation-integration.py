"""Disposable Linux CI PG16 metadata/snapshot/logical-restore test, synthetic only.

This does not read AWS, legacy backups, host PGDATA, or application configuration.
All PGDATA is tmpfs, no port/network is exposed, and only the new container is
removed. The existing dev-database manifest and exported snapshot are reused.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'postgres@sha256:472efd9a66f2b2f1a5aeb18b28de74332e6ef88c2b93a1a5d812fb6db67a5f60'


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


backup = load('existing_manifest', 'operations/dev-database/backup.py')
review = load('restore_review', 'operations/restore-validation/review.py')


def execute(args, data=None, timeout=120):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError('synthetic_command_failed')
    return result.stdout


def main():
    if sys.platform != 'linux' or os.environ.get('CHICO_RESTORE_VALIDATION_INTEGRATION') != 'true':
        raise SystemExit('Explicit disposable Linux CI enablement required; no container started')
    name = 'chico-restore-validation-' + uuid.uuid4().hex
    created = False
    try:
        execute(['docker', 'pull', IMAGE], timeout=600)
        execute(['docker', 'run', '-d', '--name', name, '--network=none', '--read-only', '--user=999:999',
                 '--cap-drop=ALL', '--security-opt=no-new-privileges', '--pids-limit=128', '--memory=768m', '--cpus=1',
                 '--tmpfs', '/var/lib/postgresql/data:rw,uid=999,gid=999,mode=0700,size=256m',
                 '--tmpfs', '/var/run/postgresql:rw,uid=999,gid=999,mode=0700,size=16m',
                 '--tmpfs', '/tmp:rw,nosuid,nodev,size=64m',
                 '--env=POSTGRES_HOST_AUTH_METHOD=trust', '--env=POSTGRES_DB=fixture',
                 '--label=org.chico.environment=synthetic-ci', IMAGE])
        created = True
        for _ in range(45):
            # The official image uses a temporary Unix-only initialization
            # server. TCP readiness waits for initialization to finish fully.
            if subprocess.run(['docker', 'exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'fixture'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('synthetic_pg16_not_ready')
        def psql(database, query):
            return execute(['docker', 'exec', '-i', '--user=postgres', name, 'psql', '-X', '-qAt',
                            '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', database], query.encode())
        if not 160000 <= int(psql('fixture', 'SHOW server_version_num;')) < 170000:
            raise RuntimeError('postgres16_required')
        # Fake contents only. No real credentials; trust is confined to this
        # ephemeral network-none fixture, never an operational role contract.
        psql('fixture', '''
CREATE TABLE public.synthetic_records(id bigserial PRIMARY KEY, value text NOT NULL);
INSERT INTO public.synthetic_records(value) VALUES ('synthetic-a'),('synthetic-b');
CREATE TABLE public.alembic_version(version_num varchar(64) PRIMARY KEY);
INSERT INTO public.alembic_version VALUES ('synthetic_snapshot_1');
CREATE FUNCTION public.synthetic_guard() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE TRIGGER synthetic_trigger BEFORE INSERT ON public.synthetic_records FOR EACH ROW EXECUTE FUNCTION public.synthetic_guard();
CREATE FUNCTION public.synthetic_definer() RETURNS integer LANGUAGE sql SECURITY DEFINER AS 'SELECT 1';
ALTER TABLE public.synthetic_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY synthetic_policy ON public.synthetic_records USING (true);
''')
        sql = (ROOT / 'operations/restore-validation/catalog_preflight.sql').read_text()
        metadata = json.loads(psql('fixture', sql))
        assessment = review.assess_preflight(metadata)
        if not assessment['metadataCompatible'] or not {'triggers', 'rowSecurity', 'securityDefinerRoutines'} <= set(assessment['technicalReviewRequired']):
            raise RuntimeError('metadata_surface_not_detected')
        if any(field in json.dumps(metadata) for field in ('rolpassword', 'subconninfo', 'synthetic-a', 'synthetic-b')):
            raise RuntimeError('metadata_includes_forbidden_values')
        source = backup.Database(name, 'fixture', 'postgres')
        with backup.exported_snapshot(source) as snapshot:
            baseline = backup.database_manifest(source, snapshot)
            dump = backup.invoke(source.command('pg_dump', '-Fc', '--no-owner', '--no-privileges', '--snapshot=' + snapshot))
        psql('postgres', 'CREATE DATABASE fixture_restored;')
        destination = backup.Database(name, 'fixture_restored', 'postgres')
        backup.invoke(destination.command('pg_restore', '--no-owner', '--no-privileges', '--exit-on-error'), input=dump)
        restored = backup.database_manifest(destination)
        comparison = review.compare_manifests(review.canonical(baseline), review.canonical(restored), review.sha(review.canonical(baseline)))
        if not comparison['catalogAndCountsEquivalent'] or comparison['rowContentEquivalent']:
            raise RuntimeError('manifest_contract_changed')
        # A real changed row count must fail the same comparator after restore.
        psql('fixture_restored', "INSERT INTO public.synthetic_records(value) VALUES ('synthetic-extra');")
        changed = backup.database_manifest(destination)
        try:
            review.compare_manifests(review.canonical(baseline), review.canonical(changed), review.sha(review.canonical(baseline)))
        except review.ReviewRejected:
            pass
        else:
            raise RuntimeError('real_count_drift_accepted')
        print(json.dumps({'syntheticOnly': True, 'postgres16MetadataTested': True, 'snapshotManifestReused': True,
                          'syntheticLogicalRestoreCompared': True, 'changedCountRejected': True,
                          'realDatabaseRestored': False, 'exportApproved': False}))
    finally:
        if created:
            subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Synthetic PG16 validation failed; raw SQL/process output omitted') from None
