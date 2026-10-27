"""Dev database backups and isolated recovery proof. No business process is started.

Only aggregate/catalog metadata is returned by SQL. Raw command errors and database
rows are never printed. Credentials must already be resolved into a read-only
0600 pgpass mount inside the explicitly reviewed container.
"""
import argparse
from contextlib import contextmanager
import datetime
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import threading
import time
import uuid

REGION = 'sa-east-1'
SOURCE_CONTAINER = 'chico-dev-database'
WORK_ROOT = Path('/srv/chico/backups/database')
STATE_ROOT = Path('/var/lib/chico')
SNAPSHOT = re.compile(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{8}-[0-9]+$')
BACKUP_PREFIX = re.compile(r'^dev/database/[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}$')
USER_SCHEMAS = "n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast' AND n.nspname !~ '^pg_temp_'"


class OperationFailed(Exception):
    """Code only; never embed raw subprocess output or SQL in this exception."""


def invoke(args, *, input=None, stdout=None, timeout=1800):
    result = subprocess.run(args, input=input, stdout=stdout or subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False, timeout=timeout)
    if result.returncode:
        state = re.search(rb'ERROR:\s+([A-Z0-9]{5})\s*(?:\n|$)', result.stderr)
        raise OperationFailed('command_failed' + ('_sqlstate_' + state[1].decode() if state else ''))
    return result.stdout


def identifier(value):
    return '"' + value.replace('"', '""') + '"'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    with temp.open('xb') as stream:
        os.chmod(temp, 0o600)
        stream.write(canonical(value) + b'\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def backup_age(marker, now=None):
    now = int(time.time()) if now is None else now
    try:
        completed = json.loads(marker.read_text())['completedEpoch']
        if type(completed) is not int or completed < 0 or completed > now:
            return 99999
        return (now - completed) // 3600
    except (OSError, ValueError, KeyError, TypeError):
        return 99999


def load_config(path):
    config = json.loads(path.read_text())
    if set(config) != {'account_id', 'bucket', 'database'}:
        raise OperationFailed('unsupported_config_fields')
    if not re.fullmatch(r'[0-9]{12}', config['account_id']):
        raise OperationFailed('invalid_account')
    if not re.fullmatch(r'chico-dev-[a-z0-9-]{3,50}', config['bucket']) or config['bucket'].startswith('chico-dev-access-'):
        raise OperationFailed('invalid_backup_bucket')
    if not re.fullmatch(r'chico_dev[a-z0-9_]{0,40}', config['database']):
        raise OperationFailed('invalid_dev_database')
    return config


class Database:
    def __init__(self, container, database, user):
        self.container, self.database, self.user = container, database, user

    def command(self, program, *args):
        return ['docker', 'exec', '-i', '--user', 'postgres',
                '-e', 'PGHOST=127.0.0.1', '-e', f'PGPASSFILE=/run/secrets/{self.user}_pgpass',
                '-e', 'PGAPPNAME=chico-dev-database-backup', self.container,
                program, '--no-password', '-U', self.user, '-d', self.database, *args]

    def psql_command(self):
        return self.command('psql', '-X', '-qAt', '--set=ON_ERROR_STOP=1', '--set=VERBOSITY=sqlstate')

    def sql(self, query, snapshot=None):
        if snapshot is not None and not SNAPSHOT.fullmatch(snapshot):
            raise OperationFailed('invalid_snapshot')
        start = 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n'
        if snapshot:
            start += f"SET TRANSACTION SNAPSHOT '{snapshot}';\n"
        query = start + "SET LOCAL search_path=pg_catalog; SET LOCAL row_security=off; SET LOCAL statement_timeout='25min';\n" + query + '\nCOMMIT;\n'
        return invoke(self.psql_command(), input=query.encode()).decode().strip()

    def scalar(self, query, snapshot=None):
        return json.loads(self.sql(query, snapshot))

    def inspect(self, *, proof=False):
        item = json.loads(invoke(['docker', 'inspect', self.container]))[0]
        labels = item['Config'].get('Labels') or {}
        if labels.get('org.chico.environment') != 'dev' or labels.get('org.chico.role') != ('database-proof' if proof else 'database'):
            raise OperationFailed('container_ownership_mismatch')
        if item['HostConfig'].get('PortBindings') or item['HostConfig'].get('Privileged'):
            raise OperationFailed('unsafe_database_container')
        mode = item['HostConfig'].get('NetworkMode', '')
        if mode == 'host' or mode.startswith('container:'):
            raise OperationFailed('host_or_shared_network_not_allowed')
        if proof and item['HostConfig']['NetworkMode'] != 'none':
            raise OperationFailed('proof_requires_network_none')
        if not proof and mode != 'none':
            networks = item.get('NetworkSettings', {}).get('Networks', {})
            if not networks:
                raise OperationFailed('database_network_not_verified')
            for network in networks.values():
                details = json.loads(invoke(['docker', 'network', 'inspect', network['NetworkID']]))[0]
                if not details.get('Internal'):
                    raise OperationFailed('database_requires_internal_network')
        for entry in item['Config'].get('Env') or []:
            key, _, value = entry.partition('=')
            if value and key in ('PGPASSWORD', 'POSTGRES_PASSWORD', 'PGSERVICE', 'PGSERVICEFILE'):
                raise OperationFailed('plaintext_or_ambient_database_credentials')
            if key == 'POSTGRES_HOST_AUTH_METHOD' and value == 'trust':
                raise OperationFailed('trust_authentication_not_allowed')
        pgpass_mounts = [m for m in item.get('Mounts', []) if m.get('Destination') == f'/run/secrets/{self.user}_pgpass']
        if len(pgpass_mounts) != 1 or pgpass_mounts[0].get('RW'):
            raise OperationFailed('readonly_pgpass_mount_required')
        if proof:
            suffix = self.container.removeprefix('chico-dev-database-proof-')
            data_mounts = [m for m in item.get('Mounts', []) if m.get('Destination') == '/var/lib/postgresql/data']
            expected_data = f'/srv/chico/restore-proof/{suffix}/pgdata'
            if len(data_mounts) != 1 or data_mounts[0].get('Type') != 'bind' or data_mounts[0].get('Source') != expected_data:
                raise OperationFailed('proof_data_mount_not_isolated')
            for mount in item.get('Mounts', []):
                if mount.get('Destination') == '/var/lib/postgresql/data':
                    continue
                if mount.get('Type') == 'tmpfs' and mount.get('Destination') in ('/tmp', '/var/run/postgresql'):
                    continue
                if not mount.get('Destination', '').startswith('/run/secrets/') or mount.get('RW') or not mount.get('Source', '').startswith(f'/run/chico/database-proof-{suffix}/'):
                    raise OperationFailed('unexpected_proof_mount')
            if not item['HostConfig'].get('ReadonlyRootfs') or item['Config'].get('User', '').split(':')[0] in ('', '0', 'root'):
                raise OperationFailed('proof_requires_nonroot_readonly_container')
            if 'ALL' not in (item['HostConfig'].get('CapDrop') or []) or item['HostConfig'].get('CapAdd') or not any(x.startswith('no-new-privileges') for x in item['HostConfig'].get('SecurityOpt') or []):
                raise OperationFailed('proof_requires_dropped_capabilities')
        if not re.search(r'@sha256:[a-f0-9]{64}$', item['Config']['Image']):
            raise OperationFailed('database_image_not_pinned')
        if any(m.get('Source') == '/var/run/docker.sock' or m.get('Destination') == '/var/run/docker.sock' for m in item.get('Mounts', [])):
            raise OperationFailed('docker_socket_in_database')
        if not item['State']['Running']:
            raise OperationFailed('database_not_running')
        version = int(self.sql('SHOW server_version_num;'))
        if not 160000 <= version < 170000:
            raise OperationFailed('postgres16_required')
        return {'image': item['Config']['Image'], 'version': version, 'proofDataPath': expected_data if proof else None}


@contextmanager
def exported_snapshot(database):
    # Keep the exporting transaction alive until both pg_dump and metadata finish.
    with open(os.devnull, 'wb') as errors:
        process = subprocess.Popen(database.psql_command(), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            process.stdin.write('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n')
            process.stdin.flush()
            responses = queue.Queue()
            reader = threading.Thread(target=lambda: responses.put(process.stdout.readline().strip()), daemon=True)
            reader.start()
            snapshot = responses.get(timeout=30)
            if not SNAPSHOT.fullmatch(snapshot):
                raise OperationFailed('snapshot_export_failed')
            yield snapshot
        finally:
            if process.poll() is None:
                try:
                    process.stdin.write('ROLLBACK;\n\\q\n')
                    process.stdin.flush()
                    process.wait(timeout=10)
                except (BrokenPipeError, subprocess.TimeoutExpired):
                    process.kill()
                    process.wait(timeout=10)
            process.stdin.close()
            process.stdout.close()


def database_manifest(database, snapshot=None):
    catalog = database.scalar(f"""
SELECT json_build_object(
 'encoding', pg_encoding_to_char(d.encoding), 'collation', d.datcollate, 'ctype', d.datctype,
 'databaseBytes', pg_database_size(current_database()),
 'extensions', (SELECT coalesce(json_agg(x ORDER BY x.extname),'[]') FROM (SELECT extname,extversion FROM pg_extension) x),
 'tables', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.name),'[]') FROM
   (SELECT n.nspname AS schema,c.relname AS name,c.relkind AS kind,c.relispopulated AS populated FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE {USER_SCHEMAS} AND c.relkind IN ('r','p','m')) x),
 'columns', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.table_name,x.position),'[]') FROM
   (SELECT n.nspname AS schema,t.relname AS table_name,a.attnum AS position,a.attname AS name,format_type(a.atttypid,a.atttypmod) AS type,
    a.attnotnull AS not_null,a.attidentity AS identity,a.attgenerated AS generated,encode(sha256(convert_to(pg_get_expr(ad.adbin,ad.adrelid),'UTF8')),'hex') AS default_hash
    FROM pg_attribute a JOIN pg_class t ON t.oid=a.attrelid JOIN pg_namespace n ON n.oid=t.relnamespace
    LEFT JOIN pg_attrdef ad ON ad.adrelid=a.attrelid AND ad.adnum=a.attnum
    WHERE {USER_SCHEMAS} AND t.relkind IN ('r','p','m','v') AND a.attnum>0 AND NOT a.attisdropped) x),
 'views', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.name),'[]') FROM
   (SELECT n.nspname AS schema,c.relname AS name,encode(sha256(convert_to(pg_get_viewdef(c.oid,true),'UTF8')),'hex') AS definition_hash
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE {USER_SCHEMAS} AND c.relkind IN ('v','m')) x),
 'functions', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.name,x.arguments),'[]') FROM
   (SELECT n.nspname AS schema,p.proname AS name,pg_get_function_identity_arguments(p.oid) AS arguments,encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') AS definition_hash
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE {USER_SCHEMAS} AND p.prokind IN ('f','p','w')) x),
 'largeObjects', json_build_object('objects',(SELECT count(*) FROM pg_largeobject_metadata),'bytes',(SELECT coalesce(sum(octet_length(data)),0) FROM pg_largeobject)),
 'userTypes', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.name),'[]') FROM
   (SELECT n.nspname AS schema,t.typname AS name,t.typtype AS kind,CASE WHEN t.typtype='d' THEN format_type(t.typbasetype,t.typtypmod) ELSE NULL END AS base_type,t.typnotnull AS not_null,
    encode(sha256(convert_to(t.typdefault,'UTF8')),'hex') AS default_hash,
    encode(sha256(convert_to((SELECT json_agg(e.enumlabel ORDER BY e.enumsortorder)::text FROM pg_enum e WHERE e.enumtypid=t.oid),'UTF8')),'hex') AS enum_hash
    FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE {USER_SCHEMAS} AND t.typtype IN ('d','e')) x),
 'indexes', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.name),'[]') FROM
   (SELECT n.nspname AS schema,c.relname AS name,i.indisvalid AS valid,i.indisready AS ready,encode(sha256(convert_to(pg_get_indexdef(i.indexrelid),'UTF8')),'hex') AS definition_hash
    FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE {USER_SCHEMAS}) x),
 'constraints', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.table_name,x.name),'[]') FROM
   (SELECT n.nspname AS schema,t.relname AS table_name,c.conname AS name,c.convalidated AS validated,encode(sha256(convert_to(pg_get_constraintdef(c.oid),'UTF8')),'hex') AS definition_hash
    FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace LEFT JOIN pg_class t ON t.oid=c.conrelid WHERE {USER_SCHEMAS}) x),
 'sequenceDefinitions', (SELECT coalesce(json_agg(x ORDER BY x.schema,x.name),'[]') FROM
   (SELECT n.nspname AS schema,s.relname AS name,q.seqincrement AS increment,q.seqmin AS minimum,q.seqmax AS maximum,q.seqcycle AS cycle,
     tn.nspname AS table_schema,t.relname AS table_name,a.attname AS column_name
    FROM pg_class s JOIN pg_sequence q ON q.seqrelid=s.oid JOIN pg_namespace n ON n.oid=s.relnamespace
    LEFT JOIN pg_depend dep ON dep.objid=s.oid AND dep.classid='pg_class'::regclass AND dep.refclassid='pg_class'::regclass AND dep.deptype IN ('a','i')
    LEFT JOIN pg_class t ON t.oid=dep.refobjid LEFT JOIN pg_namespace tn ON tn.oid=t.relnamespace
    LEFT JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=dep.refobjsubid WHERE {USER_SCHEMAS}) x)
) FROM pg_database d WHERE d.datname=current_database();
""", snapshot)
    for table in catalog['tables']:
        table['rows'] = None if table['kind'] == 'm' and not table['populated'] else int(database.sql(f"SELECT count(*) FROM {identifier(table['schema'])}.{identifier(table['name'])};", snapshot))
    catalog['alembic'] = database.scalar("SELECT coalesce(json_agg(version_num ORDER BY version_num),'[]') FROM public.alembic_version;", snapshot) if any(t['schema'] == 'public' and t['name'] == 'alembic_version' for t in catalog['tables']) else []
    catalog['sequences'] = []
    for sequence in catalog['sequenceDefinitions']:
        name = identifier(sequence['schema']) + '.' + identifier(sequence['name'])
        state = database.scalar(f"SELECT json_build_object('last',last_value,'called',is_called) FROM {name};", snapshot)
        if sequence['table_name']:
            column = identifier(sequence['column_name'])
            table = identifier(sequence['table_schema']) + '.' + identifier(sequence['table_name'])
            extreme = 'max' if sequence['increment'] > 0 else 'min'
            state['bound'] = database.scalar(f"SELECT coalesce(to_json({extreme}({column})),'null'::json) FROM {table};", snapshot)
        else:
            state['bound'] = None
        catalog['sequences'].append({**sequence, **state})
    catalog['sequenceObservation'] = 'Sequence counters are non-MVCC; compare definitions and validate next-value safety, not source counter equality.'
    return catalog


def validate_sequences(sequences):
    for sequence in sequences:
        if not sequence.get('table_name'):
            raise OperationFailed('unowned_sequence_requires_review')
        step = sequence['increment']
        candidate = sequence['last'] + step if sequence['called'] else sequence['last']
        if candidate > sequence['maximum'] or candidate < sequence['minimum']:
            if not sequence['cycle']:
                raise OperationFailed('sequence_exhausted')
            candidate = sequence['minimum'] if step > 0 else sequence['maximum']
        bound = sequence['bound']
        if bound is not None and (candidate <= bound if step > 0 else candidate >= bound):
            raise OperationFailed('sequence_may_collide')


def reconcile(expected, actual):
    for key in ('encoding', 'collation', 'ctype', 'extensions', 'tables', 'columns', 'views', 'functions', 'largeObjects', 'userTypes', 'alembic', 'indexes', 'constraints', 'sequenceDefinitions'):
        if expected[key] != actual[key]:
            raise OperationFailed('manifest_mismatch_' + key)
    if any(not i['valid'] or not i['ready'] for i in actual['indexes']):
        raise OperationFailed('invalid_index')
    if any(not c['validated'] for c in actual['constraints']):
        raise OperationFailed('unvalidated_constraint')
    validate_sequences(actual['sequences'])


class Storage:
    def __init__(self, config):
        self.bucket = config['bucket']
        identity = self.json_call('sts', 'get-caller-identity')
        if identity['Account'] != config['account_id']:
            raise OperationFailed('foreign_aws_account')

    @staticmethod
    def json_call(service, operation, *args):
        return json.loads(invoke(['aws', service, operation, '--region', REGION, '--no-cli-pager', '--output', 'json', *args]))

    def upload(self, path, key):
        # High-level transfer handles >5 GiB multipart objects. Never print transfer logs.
        invoke(['aws', 's3', 'cp', str(path), f's3://{self.bucket}/{key}', '--region', REGION,
                '--sse', 'AES256', '--checksum-algorithm', 'SHA256', '--only-show-errors', '--no-progress'], timeout=7200)
        head = self.json_call('s3api', 'head-object', '--bucket', self.bucket, '--key', key)
        if head['ContentLength'] != path.stat().st_size or head.get('ServerSideEncryption') != 'AES256' or not head.get('VersionId') or head['VersionId'] == 'null':
            raise OperationFailed('uploaded_object_not_versioned_or_mismatched')
        return {'key': key, 'version': head['VersionId'], 'bytes': path.stat().st_size, 'sha256': file_hash(path)}

    def download(self, item, destination):
        if not isinstance(item.get('bytes'), int) or item['bytes'] < 1 or not item.get('version') or item['version'] == 'null' or not re.fullmatch(r'[a-f0-9]{64}', item.get('sha256', '')):
            raise OperationFailed('invalid_download_binding')
        head = self.json_call('s3api', 'head-object', '--bucket', self.bucket, '--key', item['key'], '--version-id', item['version'])
        if head['ContentLength'] != item['bytes'] or shutil.disk_usage(destination.parent).free < item['bytes'] + 1024**3:
            raise OperationFailed('download_size_or_space_mismatch')
        self.json_call('s3api', 'get-object', '--bucket', self.bucket, '--key', item['key'], '--version-id', item['version'], str(destination))
        if destination.stat().st_size != item['bytes'] or file_hash(destination) != item['sha256']:
            raise OperationFailed('download_checksum_mismatch')


def commit_bundle(storage, work, manifest, prefix, state_root=None):
    state_root = STATE_ROOT if state_root is None else state_root
    if not BACKUP_PREFIX.fullmatch(prefix):
        raise OperationFailed('invalid_database_prefix')
    atomic_json(work / 'manifest.json', manifest)
    objects = [storage.upload(work / name, prefix + '/' + name) for name in ('database.dump', 'manifest.json')]
    commit = {'format': 1, 'bucket': storage.bucket, 'prefix': prefix, 'objects': objects,
              'completedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    atomic_json(work / 'commit.json', commit)
    reference = storage.upload(work / 'commit.json', prefix + '/commit.json')
    # No success marker advances after a failed dump, manifest or final commit upload.
    atomic_json(state_root / 'database-last-backup.json', {'bucket': storage.bucket, 'commit': reference, 'completedEpoch': int(time.time())})
    return {'commit': reference, 'bucket': storage.bucket}


def backup(config, work):
    database = Database(SOURCE_CONTAINER, config['database'], 'dev_backup')
    image = database.inspect()
    storage = Storage(config)
    with exported_snapshot(database) as snapshot:
        size = int(database.sql('SELECT pg_database_size(current_database());', snapshot))
        if shutil.disk_usage(work).free < size + 1024**3:
            raise OperationFailed('insufficient_backup_work_space')
        with (work / 'database.dump').open('xb') as dump:
            invoke(database.command('pg_dump', '-Fc', '-Z', '3', '--no-owner', '--no-privileges', '--snapshot=' + snapshot), stdout=dump, timeout=7200)
        manifest = database_manifest(database, snapshot)
    manifest.update({'format': 1, 'database': config['database'], 'postgres': image,
                     'dumpSHA256': file_hash(work / 'database.dump'), 'dumpBytes': (work / 'database.dump').stat().st_size})
    prefix = 'dev/database/' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex
    return commit_bundle(storage, work, manifest, prefix)


def validate_commit(commit, config):
    if commit.get('format') != 1 or commit.get('bucket') != config['bucket'] or not BACKUP_PREFIX.fullmatch(commit.get('prefix', '')):
        raise OperationFailed('foreign_or_invalid_commit')
    objects = commit.get('objects', [])
    if len(objects) != 2 or {x.get('key') for x in objects} != {commit['prefix'] + '/database.dump', commit['prefix'] + '/manifest.json'}:
        raise OperationFailed('unexpected_backup_objects')
    for item in objects:
        if not re.fullmatch(r'[a-f0-9]{64}', item.get('sha256', '')) or not isinstance(item.get('bytes'), int) or item['bytes'] < 1 or not item.get('version') or item['version'] == 'null':
            raise OperationFailed('incomplete_object_binding')


def proof(config, work, reference, container, reviewed_dump_sha256):
    if not re.fullmatch(r'chico-dev-database-proof-[a-f0-9]{12}', container):
        raise OperationFailed('invalid_proof_container')
    database = Database(container, config['database'], 'dev_proof')
    image = database.inspect(proof=True)
    existing = database.sql(f"SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE {USER_SCHEMAS}) + (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE {USER_SCHEMAS});")
    if int(existing) != 0:
        raise OperationFailed('proof_database_not_empty')
    storage = Storage(config)
    if reference.get('bucket') != config['bucket'] or not re.fullmatch(r'dev/database/[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}/commit.json', reference.get('commit', {}).get('key', '')):
        raise OperationFailed('invalid_commit_reference')
    storage.download(reference['commit'], work / 'commit.json')
    commit = json.loads((work / 'commit.json').read_text())
    validate_commit(commit, config)
    metadata = next(x for x in commit['objects'] if x['key'].endswith('/manifest.json'))
    storage.download(metadata, work / 'manifest.json')
    manifest = json.loads((work / 'manifest.json').read_text())
    if not {item['extname'] for item in manifest['extensions']} <= {'plpgsql', 'pg_trgm', 'pg_stat_statements'}:
        raise OperationFailed('extension_requires_private_review')
    if image['image'].rsplit('@sha256:', 1)[-1] != manifest['postgres']['image'].rsplit('@sha256:', 1)[-1]:
        raise OperationFailed('proof_database_image_differs')
    if manifest['database'] != config['database'] or manifest['dumpSHA256'] != reviewed_dump_sha256:
        raise OperationFailed('dump_not_privately_reviewed')
    if shutil.disk_usage(work).free < int(manifest['databaseBytes'] * 1.25) + manifest['dumpBytes']:
        raise OperationFailed('insufficient_proof_space')
    if shutil.disk_usage(image['proofDataPath']).free < int(manifest['databaseBytes'] * 1.25):
        raise OperationFailed('insufficient_proof_pgdata_space')
    dump = next(x for x in commit['objects'] if x['key'].endswith('/database.dump'))
    if dump['sha256'] != manifest['dumpSHA256']:
        raise OperationFailed('dump_binding_mismatch')
    storage.download(dump, work / 'database.dump')
    with (work / 'database.dump').open('rb') as stream:
        result = subprocess.run(database.command('pg_restore', '--no-owner', '--no-privileges', '--exit-on-error'), stdin=stream,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False, timeout=7200)
        if result.returncode:
            raise OperationFailed('restore_failed')
    restored = database_manifest(database)
    reconcile(manifest, restored)
    result = {'verified': True, 'bucket': config['bucket'], 'prefix': commit['prefix'], 'commit': reference['commit'],
              'dumpSHA256': manifest['dumpSHA256'], 'tablesReconciled': len(restored['tables']),
              'rowsEmitted': False, 'businessWritersStarted': False, 'completedEpoch': int(time.time())}
    atomic_json(STATE_ROOT / 'database-last-restore-proof.json', result)
    return result


@contextmanager
def operation_lock():
    # Linux host only. One disk-heavy backup/proof at a time on the small Dev box.
    import fcntl
    STATE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE_ROOT / 'database-backup.lock').open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise OperationFailed('database_operation_already_running') from None
        yield


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['backup', 'proof', 'freshness'])
    parser.add_argument('--config', type=Path)
    parser.add_argument('--reference', type=Path)
    parser.add_argument('--proof-container')
    parser.add_argument('--reviewed-dump-sha256')
    args = parser.parse_args()
    os.umask(0o077)
    if args.operation == 'freshness':
        print(backup_age(STATE_ROOT / 'database-last-backup.json'))
        return 0
    work = None
    try:
        if args.config is None:
            raise OperationFailed('explicit_config_required')
        config = load_config(args.config)
        WORK_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        if WORK_ROOT.is_symlink() or WORK_ROOT.resolve() != WORK_ROOT:
            raise OperationFailed('unsafe_work_root')
        with operation_lock():
            work = WORK_ROOT / ('run-' + uuid.uuid4().hex)
            work.mkdir(mode=0o700)
            if args.operation == 'backup':
                result = backup(config, work)
            else:
                if not args.reference or not args.proof_container or not re.fullmatch(r'[a-f0-9]{64}', args.reviewed_dump_sha256 or ''):
                    raise OperationFailed('explicit_proof_inputs_required')
                result = proof(config, work, json.loads(args.reference.read_text()), args.proof_container, args.reviewed_dump_sha256)
        print(json.dumps({'operation': args.operation, 'success': True, 'result': result}))
        # Only the new per-run work directory is cleaned. Never delete a failed proof or existing PGDATA.
        if work.parent.resolve() != WORK_ROOT.resolve() or not re.fullmatch(r'run-[a-f0-9]{32}', work.name):
            raise OperationFailed('unsafe_work_path')
        shutil.rmtree(work)
        return 0
    except Exception as error:
        code = error.args[0] if isinstance(error, OperationFailed) else 'unexpected_runtime_error'
        print(json.dumps({'operation': args.operation, 'success': False, 'code': code, 'evidence': 'private work directory retained; no raw SQL/rows/errors emitted'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
