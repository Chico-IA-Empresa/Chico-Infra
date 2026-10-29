"""Synthetic-only consumer config tests; no AWS, passphrase source or Docker."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('private_config', ROOT / 'operations/restore-staging/prepare-private-config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
clone_spec = importlib.util.spec_from_file_location('clone_templates', ROOT / 'operations/restore-staging/clone-startup-templates.py')
clone = importlib.util.module_from_spec(clone_spec)
clone_spec.loader.exec_module(clone)
integration_spec = importlib.util.spec_from_file_location('clone_integration', ROOT / 'tests/restore-private-config-integration.py')
integration = importlib.util.module_from_spec(integration_spec)
integration_spec.loader.exec_module(integration)
NOW = datetime(2026, 10, 28, 12, tzinfo=timezone.utc)
START, END = '2026-10-28T00:00:00Z', '2026-10-29T00:00:00Z'
SOURCE_SHA = 'a' * 64
INSTANCE = 'i-' + '1' * 17
IMAGE = 'sha256:' + 'b' * 64
SECRET = b'synthetic-only=pass#with"quotes\\inside'


class PrivateConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='synthetic-config-')
        self.directory = Path(self.temp.name).resolve() / 'synthetic-import'
        self.directory.mkdir(mode=0o700)
        self.context = {'schema': 1, 'account': '306915830875', 'region': 'sa-east-1',
                        'sourceManifestSHA256': SOURCE_SHA, 'instanceId': INSTANCE,
                        'importId': self.directory.name, 'recipientPublicKeySHA256': 'c' * 64,
                        'ssmCommandId': '11111111-1111-1111-1111-111111111111',
                        'notBeforeUTC': START, 'expiresAtUTC': END}
        self.metadata = {'algorithm': 'RSA3072-OAEP-SHA256-MGF1SHA256', 'context': self.context,
                         'ciphertextSHA256': 'd' * 64}
        self.transfer = {'account': '306915830875', 'sourceBucket': 'chico-backup', 'sourceWrites': False,
                         'sourceManifestSHA256': SOURCE_SHA, 'objectCount': 1, 'copiedBytes': 42,
                         'databaseRestored': False, 'readOnlyContainerMountStillRequired': True,
                         'objects': [{'key': 'pgbackrest/sofascore-postgres/backup/main/backup.info',
                                      'versionId': 'synthetic-version', 'bytes': 42, 'sha256': 'e' * 64}]}
        recipient = {key: self.context[key] for key in ('importId', 'notBeforeUTC', 'expiresAtUTC', 'recipientPublicKeySHA256')}
        self.write('recipient-lease.json', json.dumps(recipient).encode())
        self.write('repo.pass', SECRET)
        self.guard = patch.object(config.cipher, 'require_private_tmpfs')
        self.guard.start()
        self.addCleanup(self.guard.stop)
        # Production root chowns the newly created file. Unit tests may run as
        # an unprivileged CI user; verify the requested fchown separately.
        self.chown = patch.object(config.os, 'fchown', create=True)
        self.chown_mock = self.chown.start()
        self.addCleanup(self.chown.stop)
        self.addCleanup(self.temp.cleanup)

    def write(self, name, data):
        path = self.directory / name
        path.write_bytes(data)
        if os.name == 'posix':
            path.chmod(0o600)
        return path

    def prepare(self, metadata=None, transfer=None, **kwargs):
        raw_meta = json.dumps(metadata or self.metadata).encode()
        raw_transfer = json.dumps(transfer or self.transfer).encode()
        return config.prepare(self.directory, raw_meta, hashlib.sha256(raw_meta).hexdigest(),
                              raw_transfer, hashlib.sha256(raw_transfer).hexdigest(),
                              SOURCE_SHA, INSTANCE, kwargs.pop('uid', 999), kwargs.pop('gid', 999),
                              kwargs.pop('image', IMAGE), now=kwargs.pop('now', lambda: NOW), **kwargs)

    def test_config_exact_private_value_only_in_file_and_no_acceptance_claim(self):
        result = self.prepare()
        raw = (self.directory / 'pgbackrest.conf').read_bytes()
        self.assertIn(b'repo1-cipher-pass=' + SECRET + b'\n', raw)
        self.assertIn(b'repo1-type=posix\nrepo1-path=/repo\n', raw)
        self.assertIn(b'archive-async=n\n', raw)
        self.assertNotIn(SECRET.decode(), json.dumps(result))
        self.assertFalse(result['credentialsEmitted'])
        self.assertFalse(result['databaseRestored'])
        self.assertFalse(result['sourcePayloadIntegrityValidated'])
        self.assertEqual(result['toolchainImage'], IMAGE)
        if os.name == 'posix':
            self.chown_mock.assert_called_once()
            self.assertEqual(self.chown_mock.call_args.args[1:], (999, 999))
            self.assertEqual((self.directory / 'pgbackrest.conf').stat().st_mode & 0o777, 0o600)

    def test_existing_config_is_never_overwritten(self):
        previous = self.write('pgbackrest.conf', b'private-existing')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(previous.read_bytes(), b'private-existing')

    def test_unpinned_metadata_or_transfer_is_refused_before_secret_read(self):
        with self.assertRaises(ValueError):
            config.pinned_json(json.dumps(self.metadata).encode(), '0' * 64)
        with self.assertRaises(ValueError):
            config.pinned_json(json.dumps(self.transfer).encode(), '0' * 64)
        self.assertFalse((self.directory / 'pgbackrest.conf').exists())

    def test_host_source_account_import_and_recipient_drift_are_refused(self):
        for field, value in [('account', '000000000000'), ('instanceId', 'i-' + '2' * 17),
                             ('sourceManifestSHA256', 'f' * 64), ('importId', 'other-import'),
                             ('recipientPublicKeySHA256', 'f' * 64)]:
            metadata = json.loads(json.dumps(self.metadata))
            metadata['context'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.prepare(metadata=metadata)
            self.assertFalse((self.directory / 'pgbackrest.conf').exists())

    def test_partial_version_mismatch_and_foreign_transfer_are_refused(self):
        changes = [{'sourceWrites': True}, {'sourceBucket': 'foreign'}, {'objectCount': 2},
                   {'copiedBytes': 43}, {'sourceManifestSHA256': 'f' * 64}, {'databaseRestored': True}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.prepare(transfer={**self.transfer, **change})
        for change in [{'versionId': 'null'}, {'bytes': -1}, {'sha256': 'bad'},
                       {'key': 'pgbackrest/sofascore-postgres/../escape'}]:
            transfer = {**self.transfer, 'objects': [{**self.transfer['objects'][0], **change}]}
            with self.subTest(item=change), self.assertRaises(ValueError):
                self.prepare(transfer=transfer)

    def test_expired_lease_never_creates_config_or_modifies_passfile(self):
        with self.assertRaises(ValueError):
            self.prepare(now=lambda: datetime(2026, 10, 29, tzinfo=timezone.utc))
        self.assertFalse((self.directory / 'pgbackrest.conf').exists())
        self.assertEqual((self.directory / 'repo.pass').read_bytes(), SECRET)

    def test_expiry_after_write_removes_only_new_config(self):
        times = iter([NOW, NOW, datetime(2026, 10, 29, tzinfo=timezone.utc)])
        with self.assertRaises(ValueError):
            self.prepare(now=lambda: next(times))
        self.assertFalse((self.directory / 'pgbackrest.conf').exists())
        self.assertEqual((self.directory / 'repo.pass').read_bytes(), SECRET)
        self.assertTrue((self.directory / 'recipient-lease.json').exists())

    def test_root_uid_unpinned_image_and_unsupported_passphrase_are_refused(self):
        for kwargs in ({'uid': 0}, {'gid': 0}, {'uid': -1}, {'image': 'postgres:latest'}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.prepare(**kwargs)
        for secret in (b'', b' leading', b'trailing ', b'new\nline', b'tab\tinside', b'null\x00', b'\xff'):
            with self.subTest(secretCase='unsupported-bytes'), self.assertRaises((ValueError, UnicodeDecodeError)):
                config.render_config(secret)

    def test_fifo_or_oversized_private_file_are_refused(self):
        path = self.write('oversized', b'x' * 320)
        with self.assertRaises(ValueError):
            config.read_private(path, 318)

    @unittest.skipUnless(os.name == 'posix', 'Production Linux owner handoff')
    def test_failed_owner_handoff_removes_only_new_output(self):
        with patch.object(config.os, 'fchown', side_effect=PermissionError('synthetic-denial')):
            with self.assertRaises(PermissionError):
                self.prepare()
        self.assertFalse((self.directory / 'pgbackrest.conf').exists())
        self.assertEqual((self.directory / 'repo.pass').read_bytes(), SECRET)

    def test_malformed_cipher_metadata_and_duplicate_transfer_are_rejected(self):
        with self.assertRaises(ValueError):
            self.prepare(metadata={**self.metadata, 'ciphertextSHA256': 'not-a-sha'})
        transfer = {**self.transfer, 'objects': self.transfer['objects'] * 2, 'objectCount': 2, 'copiedBytes': 84}
        with self.assertRaises(ValueError):
            self.prepare(transfer=transfer)

    @unittest.skipUnless(os.name == 'posix', 'Production Linux file-mode and link guards')
    def test_symlink_hardlink_and_open_permissions_are_refused(self):
        path = self.directory / 'repo.pass'
        link = self.directory / 'symlink'
        link.symlink_to(path)
        with self.assertRaises(ValueError):
            config.read_private(link, 318)
        link.unlink()
        os.link(path, link)
        with self.assertRaises(ValueError):
            config.read_private(path, 318)
        link.unlink()
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            config.read_private(path, 318)
        fifo = self.directory / 'fifo'
        os.mkfifo(fifo, 0o600)
        with self.assertRaises(ValueError):
            config.read_private(fifo, 318)

    def test_bootstrap_sets_stop_timer_before_packages_and_verifies_cliv2(self):
        bootstrap = (ROOT / 'modules/restore-staging/bootstrap.sh').read_text()
        self.assertIn('docker curl-minimal jq python3 awscli-2 ', bootstrap)
        self.assertNotIn('awscli2', bootstrap)
        self.assertLess(bootstrap.index('systemctl enable --now chico-restore-expiry.timer'), bootstrap.index('until dnf install'))
        self.assertIn('[[ "$(aws --version 2>&1)" == aws-cli/2.* ]]', bootstrap)
        self.assertNotIn('terminate-instances', bootstrap)

    def control(self):
        return {'schema': 1, 'postgresMajor': 16, 'systemIdentifier': '1234567890123456789',
                'sourceManifestSHA256': SOURCE_SHA, 'settings': {'max_connections': 100,
                'max_worker_processes': 8, 'max_wal_senders': 10, 'max_prepared_transactions': 0,
                'max_locks_per_transaction': 64}}

    def test_clone_templates_do_not_load_source_configs_or_external_commands(self):
        templates = clone.render(self.control(), SOURCE_SHA)
        text = templates['postgresql.conf'].decode()
        self.assertNotIn('include', text)
        for key in ('shared_preload_libraries', 'session_preload_libraries', 'local_preload_libraries',
                    'archive_command', 'archive_library', 'recovery_end_command', 'primary_conninfo'):
            self.assertIn(key + " = ''\n", text)
        self.assertIn("restore_command = '" + clone.RESTORE_COMMAND + "'\n", text)
        self.assertIn("listen_addresses = ''\n", text)
        self.assertIn("recovery_target = 'immediate'\n", text)
        self.assertIn("recovery_target_timeline = 'current'\n", text)
        self.assertIn("recovery_target_action = 'pause'\n", text)
        self.assertIn('max_logical_replication_workers = 0\n', text)
        self.assertEqual(templates['pg_hba.conf'].splitlines()[0], b'local all postgres peer')
        self.assertEqual(clone.START_ARGV[-1], 'config_file=/scripts/clone/postgresql.conf')
        self.assertEqual(clone.START_ARGV[0], '/usr/lib/postgresql/16/bin/postgres')
        self.assertNotIn('PGPASSWORD', clone.CLIENT_OPTIONS)

    def test_clone_control_values_are_exact_and_not_guessed_or_shell_interpreted(self):
        control = self.control()
        control['settings']['max_connections'] = 345
        self.assertIn(b'max_connections = 345\n', clone.render(control, SOURCE_SHA)['postgresql.conf'])
        for name, value in [('max_connections', '100; touch /tmp/side-effect'), ('max_connections', 0),
                            ('max_worker_processes', True), ('max_prepared_transactions', -1)]:
            bad = self.control()
            bad['settings'][name] = value
            with self.subTest(name=name), self.assertRaises(ValueError):
                clone.render(bad, SOURCE_SHA)
        for change in ({'postgresMajor': 15}, {'sourceManifestSHA256': 'f' * 64},
                       {'systemIdentifier': '18446744073709551616'}, {'include': 'production.conf'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                clone.render({**self.control(), **change}, SOURCE_SHA)

    def test_synthetic_integration_pins_image_and_isolates_every_mount(self):
        base = self.directory
        argv = integration.command(base / 'scripts', base / 'pgdata', base / 'private')
        self.assertIn('--network=none', argv)
        self.assertIn('--read-only', argv)
        self.assertIn('--user=999:999', argv)
        self.assertIn('--cap-drop=ALL', argv)
        self.assertIn('--security-opt=no-new-privileges', argv)
        self.assertIn(integration.IMAGE, argv)
        self.assertIn('sha256:472efd9a66f2b2f1a5aeb18b28de74332e6ef88c2b93a1a5d812fb6db67a5f60', integration.IMAGE)
        self.assertTrue(any('/var/lib/postgresql/data:rw,' in item for item in argv))
        self.assertTrue(any('dst=/scripts,readonly' in item for item in argv))
        self.assertNotIn('docker.sock', ' '.join(argv))
        script = (ROOT / 'operations/restore-staging/test-clone-startup.sh').read_text()
        self.assertIn('test ! -e /pgdata/PG_VERSION', script)
        self.assertIn('test ! -e /pgdata/recovery.signal', script)
        self.assertIn('synthetic_missing_shared_preload', script)


if __name__ == '__main__':
    unittest.main()
