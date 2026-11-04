"""Synthetic crypto round trips; never loads production recovery configuration."""
import contextlib
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cipher_envelope', ROOT / 'operations/restore-staging/cipher-envelope.py')
cipher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cipher)
OPENSSL = shutil.which('openssl') or r'C:\Program Files\Git\mingw64\bin\openssl.exe'
NOW = datetime(2026, 10, 28, 12, tzinfo=timezone.utc)
START, END = '2026-10-28T00:00:00Z', '2026-10-29T00:00:00Z'
SECRET = b'synthetic-cipher-passphrase-never-production'


class EnvelopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.allowed = (ROOT / 'reports').resolve()
        cls.allowed.mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix='cipher-test-', dir=cls.allowed)
        cls.base = Path(cls.temp.name).resolve()
        assert cls.base.is_relative_to(cls.allowed)
        cls.directory = cls.base / 'synthetic-import'
        cls.public = cipher.recipient(OPENSSL, cls.directory, START, END, now=NOW)
        cls.context = {'schema': 1, 'account': '306915830875', 'region': 'sa-east-1',
                       'sourceManifestSHA256': '1' * 64, 'instanceId': 'i-' + '1' * 17,
                       'importId': cls.directory.name, 'recipientPublicKeySHA256': cls.public['recipientPublicKeySHA256'],
                       'ssmCommandId': '11111111-1111-1111-1111-111111111111', 'notBeforeUTC': START, 'expiresAtUTC': END}
        cls.ciphertext, cls.metadata = cipher.seal(OPENSSL, SECRET, cls.directory / 'recipient-public.pem', cls.context, now=NOW)

    @classmethod
    def tearDownClass(cls):
        assert cls.base.is_relative_to(cls.allowed) and cls.base != cls.allowed
        cls.temp.cleanup()

    def tearDown(self):
        output = self.directory / 'repo.pass'
        if output.exists():
            assert output.resolve().is_relative_to(self.base)
            output.unlink()

    def open(self, metadata=None, ciphertext=None, now=NOW, digest=None):
        raw = json.dumps(metadata or self.metadata).encode()
        return cipher.open_envelope(OPENSSL, self.directory, raw, digest or hashlib.sha256(raw).hexdigest(),
                                    ciphertext if ciphertext is not None else self.ciphertext, now=now)

    def test_round_trip_only_writes_private_file_and_returns_no_secret(self):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            result = self.open()
        self.assertEqual((self.directory / 'repo.pass').read_bytes(), SECRET)
        self.assertEqual(captured.getvalue(), '')
        self.assertNotIn(SECRET.decode(), json.dumps(result))
        self.assertNotIn('PRIVATE KEY', json.dumps(self.public))
        self.assertFalse(result['credentialsEmitted'])
        if os.name != 'nt':
            self.assertEqual((self.directory / 'repo.pass').stat().st_mode & 0o777, 0o600)

    def test_changed_outer_hash_and_corrupt_ciphertext_never_write_plaintext(self):
        with self.assertRaises(ValueError):
            self.open(digest='0' * 64)
        broken = bytearray(self.ciphertext)
        broken[-1] ^= 1
        metadata = json.loads(json.dumps(self.metadata))
        metadata['ciphertextSHA256'] = hashlib.sha256(broken).hexdigest()
        with self.assertRaises(ValueError):
            self.open(metadata, bytes(broken))
        self.assertFalse((self.directory / 'repo.pass').exists())

    def test_oaep_label_binds_source_and_instance_even_if_outer_metadata_is_rehashed(self):
        for field, value in [('sourceManifestSHA256', '2' * 64), ('instanceId', 'i-' + '2' * 17),
                             ('ssmCommandId', '22222222-2222-2222-2222-222222222222')]:
            changed = json.loads(json.dumps(self.metadata))
            changed['context'][field] = value
            with self.assertRaises(ValueError):
                self.open(changed)
            self.assertFalse((self.directory / 'repo.pass').exists())

    def test_expired_or_changed_recipient_lease_is_refused(self):
        with self.assertRaises(ValueError):
            self.open(now=datetime(2026, 10, 29, tzinfo=timezone.utc))
        changed = json.loads(json.dumps(self.metadata))
        changed['context']['expiresAtUTC'] = '2026-10-29T01:00:00Z'
        with self.assertRaises(ValueError):
            self.open(changed)
        self.assertFalse((self.directory / 'repo.pass').exists())

    def test_no_key_or_decrypted_file_overwrite(self):
        with self.assertRaises(ValueError):
            cipher.recipient(OPENSSL, self.directory, START, END, now=NOW)
        output = self.directory / 'repo.pass'
        cipher.write_private(output, b'existing-private-material')
        with self.assertRaises(ValueError):
            self.open()
        self.assertEqual(output.read_bytes(), b'existing-private-material')

    def test_wrong_recipient_and_unsupported_plaintext_are_refused(self):
        context = {**self.context, 'recipientPublicKeySHA256': '0' * 64}
        with self.assertRaises(ValueError):
            cipher.seal(OPENSSL, SECRET, self.directory / 'recipient-public.pem', context, now=NOW)
        for secret in [b'', b'a' * 319, b'line\nbreak', b'null\x00value']:
            with self.assertRaises(ValueError):
                cipher.seal(OPENSSL, secret, self.directory / 'recipient-public.pem', self.context, now=NOW)

    def test_weak_rsa_key_is_refused_before_encrypting(self):
        private, public = self.base / 'weak-private.pem', self.base / 'weak-public.pem'
        cipher.command(OPENSSL, ['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(private)])
        cipher.command(OPENSSL, ['pkey', '-in', str(private), '-pubout', '-out', str(public)])
        with self.assertRaises(ValueError):
            cipher.public_fingerprint(OPENSSL, public)

    def test_recipient_command_binds_script_and_refuses_shell_injection(self):
        command = cipher.recipient_command('a' * 64, 'synthetic-import', START, END, now=NOW)
        self.assertIn('/usr/bin/sha256sum /usr/local/lib/chico/restore-cipher-envelope.py', command)
        self.assertIn('"' + 'a' * 64 + '"', command)
        self.assertNotIn(SECRET.decode(), command)
        for import_id in ['../escape', 'name;echo injected', 'name\ncommand']:
            with self.assertRaises(ValueError):
                cipher.recipient_command('a' * 64, import_id, START, END, now=NOW)

    @unittest.skipUnless(sys.platform == 'linux', 'Production Linux tmpfs guard tested on Linux CI')
    def test_persistent_mount_is_refused_even_when_path_and_ownership_match(self):
        directory = Path('/run/chico-restore/synthetic-import')
        with patch.object(os, 'geteuid', return_value=0), patch.object(Path, 'resolve', lambda value: value), \
                patch.object(Path, 'is_dir', return_value=True), patch.object(Path, 'exists', return_value=False), \
                patch.object(Path, 'stat', return_value=SimpleNamespace(st_uid=0, st_mode=0o40700)), \
                patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'ext4\n')):
            with self.assertRaises(ValueError):
                cipher.require_private_tmpfs(directory)


if __name__ == '__main__':
    unittest.main()
