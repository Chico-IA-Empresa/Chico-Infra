import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('database_backup', Path(__file__).parents[1] / 'operations/dev-database/backup.py')
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)
PREFIX = 'dev/database/20261027T030000Z-' + 'a' * 32
CONFIG = {'account_id': '123456789012', 'bucket': 'chico-dev-unit-backups', 'database': 'chico_dev'}


def sequence(**change):
    return {**dict(schema='public', name='id_seq', table_schema='public', table_name='items', column_name='id',
                   increment=1, minimum=1, maximum=10000, cycle=False, last=1, called=True, bound=1), **change}


def manifest():
    return {'encoding': 'UTF8', 'collation': 'en_US.utf8', 'ctype': 'en_US.utf8',
            'extensions': [{'extname': 'plpgsql', 'extversion': '1.0'}],
            'tables': [{'schema': 'public', 'name': 'items', 'rows': 9}],
            'columns': [{'schema': 'public', 'table_name': 'items', 'name': 'id', 'type': 'bigint'}],
            'views': [], 'functions': [], 'userTypes': [], 'alembic': ['synthetic_1'], 'largeObjects': {'objects': 0, 'bytes': 0},
            'indexes': [{'valid': True, 'ready': True}], 'constraints': [{'validated': True}],
            'sequenceDefinitions': [{'schema': 'public', 'name': 'id_seq'}], 'sequences': [sequence()]}


class FakeStorage:
    bucket = CONFIG['bucket']

    def __init__(self, fail_on=None):
        self.fail_on = fail_on
        self.uploaded = []

    def upload(self, path, key):
        if key.endswith(self.fail_on or '/impossible-suffix'):
            raise backup.OperationFailed('simulated_upload_failure')
        self.uploaded.append(key)
        return {'key': key, 'version': 'version-' + str(len(self.uploaded)),
                'bytes': path.stat().st_size, 'sha256': backup.file_hash(path)}


class DatabaseBackupTest(unittest.TestCase):
    def test_config_rejects_legacy_sink_credentials_and_invalid_database(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            path.write_text(json.dumps(CONFIG))
            self.assertEqual(backup.load_config(path), CONFIG)
            for change in ({'bucket': 'chico-backup'}, {'bucket': 'chico-dev-access-unit-logs'},
                           {'database': 'production'}, {'account_id': '*'}, {'password': 'synthetic-rejected-field'}):
                path.write_text(json.dumps({**CONFIG, **change}))
                with self.assertRaises(backup.OperationFailed):
                    backup.load_config(path)

    def test_successful_commit_binds_both_versions_and_advances_only_database_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / 'work'
            state = Path(directory) / 'state'
            work.mkdir()
            state.mkdir()
            (work / 'database.dump').write_bytes(b'synthetic dump bytes')
            (state / 'last-backup-success').write_text('10')
            storage = FakeStorage()
            reference = backup.commit_bundle(storage, work, manifest(), PREFIX, state)
            commit = json.loads((work / 'commit.json').read_text())
            backup.validate_commit(commit, CONFIG)
            self.assertEqual(storage.uploaded, [PREFIX + '/database.dump', PREFIX + '/manifest.json', PREFIX + '/commit.json'])
            self.assertEqual(json.loads((state / 'database-last-backup.json').read_text())['commit'], reference['commit'])
            self.assertEqual((state / 'last-backup-success').read_text(), '10')

    def test_any_upload_failure_preserves_previous_success(self):
        for fail_on in ('database.dump', 'manifest.json', 'commit.json'):
            with self.subTest(fail_on=fail_on), tempfile.TemporaryDirectory() as directory:
                work = Path(directory) / 'work'
                state = Path(directory) / 'state'
                work.mkdir()
                state.mkdir()
                (work / 'database.dump').write_bytes(b'synthetic')
                marker = state / 'database-last-backup.json'
                marker.write_text('{"completedEpoch":10}')
                with self.assertRaises(backup.OperationFailed):
                    backup.commit_bundle(FakeStorage(fail_on), work, manifest(), PREFIX, state)
                self.assertEqual(marker.read_text(), '{"completedEpoch":10}')

    def test_object_commit_refuses_cross_prefix_missing_versions_and_foreign_bucket(self):
        item = lambda name: {'key': PREFIX + '/' + name, 'version': 'pinned-version', 'bytes': 9, 'sha256': 'a' * 64}
        valid = {'format': 1, 'bucket': CONFIG['bucket'], 'prefix': PREFIX,
                 'objects': [item('database.dump'), item('manifest.json')]}
        backup.validate_commit(valid, CONFIG)
        for change in ({'bucket': 'chico-backup'}, {'prefix': 'dev/fixtures/arbitrary'}):
            with self.assertRaises(backup.OperationFailed):
                backup.validate_commit({**valid, **change}, CONFIG)
        for field, value in (('version', 'null'), ('sha256', 'unchecked'), ('key', 'dev/database/../../source')):
            bad = copy.deepcopy(valid)
            bad['objects'][0][field] = value
            with self.assertRaises(backup.OperationFailed):
                backup.validate_commit(bad, CONFIG)

    def test_download_uses_pinned_version_and_rejects_tampering(self):
        payload = b'synthetic bytes'
        binding = {'key': PREFIX + '/database.dump', 'version': 'exact-version',
                   'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            storage = backup.Storage.__new__(backup.Storage)
            storage.bucket = CONFIG['bucket']
            calls = []

            def api(service, operation, *args):
                calls.append((service, operation, args))
                if operation == 'head-object':
                    return {'ContentLength': len(payload)}
                Path(args[-1]).write_bytes(payload)
                return {}

            storage.json_call = api
            destination = Path(directory) / 'dump'
            storage.download(binding, destination)
            self.assertTrue(all('--version-id' in args and 'exact-version' in args for _, _, args in calls))
            with self.assertRaisesRegex(backup.OperationFailed, 'checksum'):
                storage.download({**binding, 'sha256': '0' * 64}, destination)

    def test_restore_manifest_detects_count_column_extension_and_extra_object_drift(self):
        expected = manifest()
        backup.reconcile(expected, copy.deepcopy(expected))
        for key in ('tables', 'columns', 'extensions', 'views', 'functions', 'largeObjects', 'userTypes', 'alembic'):
            actual = copy.deepcopy(expected)
            if key == 'largeObjects':
                actual[key]['bytes'] = 1
            else:
                actual[key].append({'unexpected': True})
            with self.subTest(key=key), self.assertRaises(backup.OperationFailed):
                backup.reconcile(expected, actual)

    def test_invalid_indexes_and_unvalidated_constraints_cannot_inherit_a_pass(self):
        for key, field in (('indexes', 'valid'), ('indexes', 'ready'), ('constraints', 'validated')):
            bad = manifest()
            bad[key][0][field] = False
            with self.assertRaises(backup.OperationFailed):
                backup.reconcile(bad, copy.deepcopy(bad))

    def test_sequence_collision_is_detected_without_modifying_sequence(self):
        broken = {**sequence(), 'called': False}
        with self.assertRaisesRegex(backup.OperationFailed, 'collide'):
            backup.validate_sequences([broken])
        self.assertFalse(broken['called'])
        backup.validate_sequences([sequence()])

    def test_non_mvcc_sequence_counter_drift_is_allowed_only_when_next_value_safe(self):
        expected = manifest()
        actual = copy.deepcopy(expected)
        actual['sequences'][0]['last'] = 42
        backup.reconcile(expected, actual)
        for change in ({'last': 10000}, {'last': 10000, 'cycle': True}, {'table_name': None}):
            with self.assertRaises(backup.OperationFailed):
                backup.validate_sequences([{**sequence(), **change}])
        backup.validate_sequences([{**sequence(), 'increment': -1, 'last': -5, 'bound': -5, 'minimum': -100}])

    def test_freshness_missing_corrupt_future_and_noninteger_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'database-last-backup.json'
            self.assertEqual(backup.backup_age(marker, 100000), 99999)
            for text in ('broken', '{}', '{"completedEpoch":100001}', '{"completedEpoch":true}', '{"completedEpoch":-1}'):
                marker.write_text(text)
                self.assertEqual(backup.backup_age(marker, 100000), 99999)
            marker.write_text('{"completedEpoch":64000}')
            self.assertEqual(backup.backup_age(marker, 100000), 10)

    def test_snapshot_connection_stays_open_until_manifest_and_dump_finish(self):
        class Input(io.StringIO):
            def close(self):
                self.saved = self.getvalue()
                super().close()

        class Process:
            stdin = Input()
            stdout = io.StringIO('00000001-0000001A-1\n')
            returncode = None

            def poll(self):
                return self.returncode

            def wait(self, timeout):
                self.returncode = 0

        process = Process()
        database = backup.Database('chico-dev-database', 'chico_dev', 'dev_backup')
        with patch.object(backup.subprocess, 'Popen', return_value=process):
            with backup.exported_snapshot(database) as snapshot:
                self.assertEqual(snapshot, '00000001-0000001A-1')
                self.assertIsNone(process.poll())
                self.assertNotIn('ROLLBACK', process.stdin.getvalue())
        self.assertIn('ROLLBACK', process.stdin.saved)

    def test_proof_refuses_a_networked_container_before_sql_or_restore(self):
        item = {'Config': {'Labels': {'org.chico.environment': 'dev', 'org.chico.role': 'database-proof'}},
                'HostConfig': {'NetworkMode': 'bridge', 'PortBindings': {}, 'Privileged': False}}
        database = backup.Database('chico-dev-database-proof-' + 'a' * 12, 'chico_dev', 'dev_proof')
        with patch.object(backup, 'invoke', return_value=json.dumps([item]).encode()):
            with self.assertRaisesRegex(backup.OperationFailed, 'network_none'):
                database.inspect(proof=True)

    def test_proof_refuses_live_data_mount_and_writable_root_before_sql(self):
        suffix = 'a' * 12
        item = {'Config': {'Labels': {'org.chico.environment': 'dev', 'org.chico.role': 'database-proof'},
                           'Image': 'postgres@sha256:' + 'a' * 64, 'User': '999:999', 'Env': []},
                'HostConfig': {'NetworkMode': 'none', 'PortBindings': {}, 'Privileged': False, 'ReadonlyRootfs': True},
                'Mounts': [{'Type': 'bind', 'Source': '/srv/chico/postgres', 'Destination': '/var/lib/postgresql/data', 'RW': True},
                           {'Type': 'bind', 'Source': f'/run/chico/database-proof-{suffix}/pass', 'Destination': '/run/secrets/dev_proof_pgpass', 'RW': False}]}
        database = backup.Database('chico-dev-database-proof-' + suffix, 'chico_dev', 'dev_proof')
        for unsafe in (item, {**item, 'HostConfig': {**item['HostConfig'], 'ReadonlyRootfs': False},
                             'Mounts': [{**item['Mounts'][0], 'Source': f'/srv/chico/restore-proof/{suffix}/pgdata'}, item['Mounts'][1]]}):
            with patch.object(backup, 'invoke', return_value=json.dumps([unsafe]).encode()):
                with self.assertRaises(backup.OperationFailed):
                    database.inspect(proof=True)

    def test_plaintext_or_trust_credentials_fail_before_database_connection(self):
        base = {'Config': {'Labels': {'org.chico.environment': 'dev', 'org.chico.role': 'database'}},
                'HostConfig': {'PortBindings': {}, 'Privileged': False, 'NetworkMode': 'none'}}
        database = backup.Database('chico-dev-database', 'chico_dev', 'dev_backup')
        for entry in ('PGPASSWORD=synthetic-forbidden', 'POSTGRES_PASSWORD=synthetic-forbidden', 'POSTGRES_HOST_AUTH_METHOD=trust'):
            item = {**base, 'Config': {**base['Config'], 'Env': [entry]}}
            with patch.object(backup, 'invoke', return_value=json.dumps([item]).encode()):
                with self.assertRaises(backup.OperationFailed):
                    database.inspect()


if __name__ == '__main__':
    unittest.main()
