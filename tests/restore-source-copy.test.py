"""Offline transport failures; uses synthetic bytes and never calls AWS."""
import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('copy_source', ROOT / 'operations/restore-staging/copy-selected-source.py')
copy_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(copy_source)
NOW = datetime(2026, 10, 28, 12, tzinfo=timezone.utc)
START, END = '2026-10-28T00:00:00Z', '2026-10-29T00:00:00Z'
PAYLOAD = b'synthetic encrypted repository bytes, no business data'


def selection():
    return {'schema': 1, 'bucket': 'chico-backup', 'account': copy_source.ACCOUNT, 'region': 'sa-east-1',
            'sourceReadOnly': True, 'allSelectedPrefixListingsNotTruncated': True,
            'inspectedMetadataVersionsUnchanged': True, 'stanza': 'main', 'objectCount': 1,
            'objects': [{'key': copy_source.PREFIX + 'backup/main/backup.info', 'versionId': 'frozen-version',
                         'bytes': len(PAYLOAD), 'etag': '"not-a-sha256"', 'lastModified': START}]}


def validated(value):
    raw = json.dumps(value).encode()
    digest = hashlib.sha256(raw).hexdigest()
    result = copy_source.validate_selection(raw, digest)
    result['_reviewedSHA256'] = digest
    return result


class CopyTests(unittest.TestCase):
    def setUp(self):
        self.allowed = (ROOT / 'reports').resolve()
        self.allowed.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='restore-source-test-', dir=self.allowed)
        self.parent = Path(self.temp.name).resolve()
        assert self.parent.is_relative_to(self.allowed)
        self.destination = self.parent / 'fresh-import'
        self.calls = []
        self.response_change = {}
        self.identity = {'Account': copy_source.ACCOUNT, 'Arn': f'arn:aws:sts::{copy_source.ACCOUNT}:assumed-role/chico-dev-restore/synthetic-session'}

    def tearDown(self):
        # Verify absolute scope before recursive TemporaryDirectory cleanup.
        assert self.parent.is_relative_to(self.allowed) and self.parent != self.allowed
        self.temp.cleanup()

    def aws(self, arguments):
        self.calls.append(arguments)
        if arguments == ['sts', 'get-caller-identity']:
            return self.identity
        self.assertEqual(arguments[:2], ['s3api', 'get-object'])
        self.assertIn('--version-id', arguments)
        self.assertEqual(arguments[arguments.index('--version-id') + 1], 'frozen-version')
        self.assertEqual(arguments[arguments.index('--expected-bucket-owner') + 1], copy_source.ACCOUNT)
        Path(arguments[-1]).write_bytes(PAYLOAD)
        return {'VersionId': 'frozen-version', 'ContentLength': len(PAYLOAD), 'ETag': '"not-a-sha256"',
                'LastModified': START, **self.response_change}

    def run_copy(self, **kwargs):
        return copy_source.copy_selection(validated(selection()), self.destination, self.aws, START, END,
                                          now=kwargs.pop('now', lambda: NOW), **kwargs)

    def test_success_binds_versions_and_hashes_but_never_declares_database_integrity(self):
        evidence = self.run_copy()
        self.assertEqual([call[:2] for call in self.calls], [['sts', 'get-caller-identity'], ['s3api', 'get-object']])
        self.assertEqual(evidence['objects'][0]['sha256'], hashlib.sha256(PAYLOAD).hexdigest())
        self.assertFalse(evidence['objects'][0]['fullObjectServerSHA256Verified'])
        self.assertFalse(evidence['backupPayloadIntegrityValidated'])
        self.assertFalse(evidence['walIntegrityValidated'])
        self.assertFalse(evidence['databaseRestored'])
        self.assertTrue(evidence['readOnlyContainerMountStillRequired'])
        self.assertTrue((self.destination / 'transfer-complete.json').is_file())

    def test_only_matching_full_object_server_sha256_is_verified(self):
        self.response_change = {'ChecksumType': 'FULL_OBJECT', 'ChecksumSHA256': base64.b64encode(hashlib.sha256(PAYLOAD).digest()).decode()}
        self.assertTrue(self.run_copy()['objects'][0]['fullObjectServerSHA256Verified'])

    def test_wrong_version_metadata_or_checksum_never_commits_a_transfer(self):
        for change in [{'VersionId': 'wrong'}, {'ContentLength': len(PAYLOAD) + 1}, {'ETag': '"wrong"'},
                       {'LastModified': '2026-01-01T00:00:00Z'},
                       {'ChecksumType': 'FULL_OBJECT', 'ChecksumSHA256': base64.b64encode(b'x' * 32).decode()}]:
            with self.subTest(change=change):
                self.destination = self.parent / f'failed-{len(self.calls)}'
                self.response_change = change
                with self.assertRaises(ValueError):
                    self.run_copy()
                self.assertFalse((self.destination / 'transfer-complete.json').exists())
                self.assertTrue((self.destination / 'transfer-failed.json').is_file())

    def test_existing_destination_is_preserved_without_any_aws_request(self):
        self.destination.mkdir()
        sentinel = self.destination / 'keep'
        sentinel.write_bytes(b'existing data')
        with self.assertRaises(ValueError):
            self.run_copy()
        self.assertEqual(sentinel.read_bytes(), b'existing data')
        self.assertEqual(self.calls, [])

    def test_root_runtime_and_foreign_account_are_refused_before_s3(self):
        for arn in [f'arn:aws:iam::{copy_source.ACCOUNT}:root',
                    f'arn:aws:sts::{copy_source.ACCOUNT}:assumed-role/chico-dev-runtime/session',
                    'arn:aws:sts::000000000000:assumed-role/chico-dev-restore/session']:
            self.identity = {'Account': copy_source.ACCOUNT, 'Arn': arn}
            with self.assertRaises(ValueError):
                self.run_copy()
            self.assertFalse(self.destination.exists())
        self.assertTrue(all(call == ['sts', 'get-caller-identity'] for call in self.calls))

    def test_expired_or_overlong_lease_never_reads_source(self):
        for start, end in [('2026-10-25T00:00:00Z', '2026-10-26T00:00:00Z'),
                           ('2026-10-28T00:00:00Z', '2026-11-01T00:00:00Z')]:
            with self.assertRaises(ValueError):
                copy_source.copy_selection(validated(selection()), self.destination, self.aws, start, end, now=lambda: NOW)
        self.assertEqual(self.calls, [])

    def test_expiry_during_copy_refuses_completion_even_when_all_bytes_arrived(self):
        moments = iter([NOW, NOW, datetime(2026, 10, 29, tzinfo=timezone.utc)])
        with self.assertRaises(ValueError):
            self.run_copy(now=lambda: next(moments))
        self.assertFalse((self.destination / 'transfer-complete.json').exists())

    def test_changed_manifest_unsafe_paths_duplicates_and_current_versions_are_rejected(self):
        for key in [copy_source.PREFIX + '../escape', copy_source.PREFIX + 'back\\slash', copy_source.PREFIX + 'file:stream', 'outside/metadata']:
            item = selection()
            item['objects'][0]['key'] = key
            with self.assertRaises(ValueError):
                validated(item)
        for version in ['null', '', 'unsafe\nversion']:
            item = selection()
            item['objects'][0]['versionId'] = version
            with self.assertRaises(ValueError):
                validated(item)
        duplicate = selection()
        duplicate['objects'] *= 2
        duplicate['objectCount'] = 2
        with self.assertRaises(ValueError):
            validated(duplicate)
        with self.assertRaises(ValueError):
            copy_source.validate_selection(json.dumps(selection()).encode(), '0' * 64)


if __name__ == '__main__':
    unittest.main()
