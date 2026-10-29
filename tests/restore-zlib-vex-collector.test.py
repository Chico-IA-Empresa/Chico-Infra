"""Offline collector tests: synthetic package/ELF, mocked Docker/network/gpgv."""
import datetime as dt
import importlib.util
import json
import lzma
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector = load('collector', ROOT / 'operations/restore-toolchain/zlib_vex_collect.py')
fixture = load('fixture', ROOT / 'tests/restore-zlib-vex.test.py')
NOW = dt.datetime(2026, 10, 29, tzinfo=dt.timezone.utc)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.context = fixture.ZlibReviewTests().context()
        self.deb = self.context['deb_bytes']
        self.digest = collector.review.sha(self.deb)
        self.index = lzma.compress(('Package: zlib1g\nVersion: ' + collector.review.VERSION +
            '\nArchitecture: amd64\nSource: zlib\nFilename: ' + collector.review.DEB_FILENAME +
            '\nSize: ' + str(len(self.deb)) + '\nSHA256: ' + self.digest + '\n').encode())
        self.release = self.make_release()
        self.calls = []

    def make_release(self, expiry='Fri, 30 Oct 2026 00:00:00 UTC'):
        return ('Origin: Debian\nLabel: Debian\nCodename: bookworm\nArchitectures: amd64 all\nComponents: main\n'
                'Date: Wed, 28 Oct 2026 00:00:00 UTC\n' +
                ('Valid-Until: ' + expiry + '\n' if expiry else '') +
                'SHA256:\n ' + collector.review.sha(self.index) + ' ' + str(len(self.index)) + ' ' + collector.INDEX_PATH + '\n').encode()

    def pins(self):
        return patch.multiple(collector.review, OFFICIAL_DEB_SHA256=self.digest)

    def repo(self, release=None, index=None, deb=None):
        with self.pins(), patch.object(collector, 'DEB_SIZE', len(self.deb)):
            return collector.repository_facts(release or self.release, self.index if index is None else index,
                                               self.deb if deb is None else deb, NOW)

    def runner(self, argv, cap):
        self.calls.append(argv)
        if argv[:3] == ['docker', 'image', 'inspect']:
            return (json.dumps(fixture.IMAGE) + ' "amd64" "linux"\n').encode()
        image_index = next(i for i, value in enumerate(argv) if value.startswith('--entrypoint=')) + 1
        image, command = argv[image_index], argv[image_index + 1:]
        if image == collector.BASE:
            return b'public-keyring-placeholder'
        if command == ['/etc/os-release']:
            return b'ID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n'
        if '-W' in command:
            return self.context['package_inventory'].encode()
        if '-L' in command:
            return self.context['package_files'].encode()
        if '-S' in command:
            return ('zlib1g:amd64: /' + collector.review.LIBRARY + '\n').encode()
        if command == ['/' + collector.review.LIBRARY]:
            return self.context['installed_library_bytes']
        self.fail('unexpected command')

    def collect(self, runner=None, raw=None):
        data = {collector.RELEASE_URL: b'signed-placeholder', collector.INDEX_URL: self.index, collector.DEB_URL: self.deb}
        def fetch(url, cap):
            self.assertLessEqual(len(data[url]), cap)
            return data[url]
        def verify(signed, keyring, runner):
            self.assertEqual(signed, b'signed-placeholder')
            self.assertEqual(keyring, b'public-keyring-placeholder')
            return self.release, ['A' * 40]
        with self.pins(), patch.object(collector, 'DEB_SIZE', len(self.deb)):
            return collector.collect(fixture.IMAGE, raw or self.context['raw_scan_bytes'], {'run': 'synthetic'},
                                     runner or self.runner, fetch, verify, NOW)

    def test_complete_benign_collection_keeps_raw_scan_severity_and_pending(self):
        raw = self.context['raw_scan_bytes']
        result = self.collect()
        self.assertEqual(result['status'], 'pending_technical_review')
        self.assertTrue(result['provenance']['repositorySignatureVerified'])
        self.assertTrue(result['provenance']['imageInspectBeforeAndAfterMatched'])
        self.assertEqual(result['review']['rawFindingSeverity'], 'CRITICAL')
        self.assertEqual(raw, self.context['raw_scan_bytes'])
        for key in ('rawScanModified', 'gateOverrideApplied', 'riskAccepted', 'severityDowngraded', 'realRestoreApproved'):
            self.assertFalse(result[key])
        self.assertFalse(result['review']['ciCollectorProvenanceVerified'])
        commands = [argv for argv in self.calls if argv[:2] == ['docker', 'run']]
        self.assertEqual(len(commands), 6)
        for argv in commands:
            for required in ('--network=none', '--read-only', '--user=999:999', '--cap-drop=ALL', '--pull=never', '--security-opt=no-new-privileges'):
                self.assertIn(required, argv)
            self.assertTrue(any(value.startswith('--tmpfs=/var/lib/postgresql/data:') for value in argv))
            self.assertFalse(any(value in argv for value in ('--privileged', '-v', '--mount', '-e', '--env')))

    def test_missing_valid_until_is_recorded_not_invented(self):
        self.release = self.make_release(expiry=None)
        result = self.collect()
        self.assertIsNone(result['provenance']['validUntil'])
        self.assertFalse(result['provenance']['repositoryFreshnessVerified'])
        self.assertEqual(result['status'], 'pending_technical_review')

    def test_expired_future_or_wrong_identity_signed_metadata_rejected(self):
        for release in (self.make_release('Tue, 27 Oct 2026 00:00:00 UTC'),
                        self.release.replace(b'28 Oct 2026', b'28 Oct 2027'),
                        self.release.replace(b'Codename: bookworm', b'Codename: trixie')):
            with self.subTest(release=release[:30]), self.assertRaises(collector.Rejected):
                self.repo(release=release)

    def test_index_hash_size_duplicate_fields_and_package_identity_are_bound(self):
        for index in (self.index + b'junk', lzma.compress(b'Package: evil\n')):
            with self.assertRaises(collector.Rejected):
                self.repo(index=index)
        for release in (self.release + b'Origin: Debian\n', self.release.replace(str(len(self.index)).encode(), b'1')):
            with self.assertRaises(collector.Rejected):
                self.repo(release=release)
        self.index = lzma.compress(lzma.decompress(self.index).replace(b'Architecture: amd64', b'Architecture: arm64'))
        self.release = self.make_release()
        with self.assertRaises(collector.Rejected):
            self.repo()

    def test_index_decompression_and_deb_tampering_fail_closed(self):
        with self.assertRaises(collector.Rejected):
            self.repo(deb=self.deb + b'x')
        self.index = lzma.compress(b'A' * 4096)
        self.release = self.make_release()
        with patch.object(collector, 'CAP', 1024), self.assertRaises(collector.Rejected):
            self.repo()

    def test_wrong_image_scan_and_ownership_fail(self):
        raw = json.dumps(fixture.scan()).replace('a' * 64, 'b' * 64).encode()
        with self.assertRaises(collector.Rejected):
            self.collect(raw=raw)
        self.assertEqual(len(self.calls), 2)  # inspect + OS; no network or package bytes.
        def owner_runner(argv, cap):
            if '-S' in argv:
                return b'other: /lib/x86_64-linux-gnu/libz.so.1.2.13\n'
            return self.runner(argv, cap)
        with self.assertRaises(collector.Rejected):
            self.collect(runner=owner_runner)

    def test_final_inspect_detects_drift(self):
        count = 0
        def runner(argv, cap):
            nonlocal count
            if argv[:3] == ['docker', 'image', 'inspect']:
                count += 1
                if count == 2:
                    return b'"sha256:changed" "amd64" "linux"'
            return self.runner(argv, cap)
        with self.assertRaises(collector.Rejected):
            self.collect(runner=runner)

    def test_failed_read_removes_only_its_unique_container(self):
        calls = []
        def runner(argv, cap):
            calls.append(argv)
            if argv[:2] == ['docker', 'run']:
                raise collector.Rejected('synthetic_timeout')
            return b''
        with self.assertRaises(collector.Rejected):
            collector.docker_read(fixture.IMAGE, ['/bin/cat', '/etc/os-release'], runner)
        name = next(value.split('=', 1)[1] for value in calls[0] if value.startswith('--name='))
        self.assertRegex(name, r'^chico-zlib-evidence-[a-f0-9]{32}$')
        self.assertEqual(calls[1], ['docker', 'rm', '--force', name])

    def test_gpgv_requires_authenticated_cleartext_strong_validsig_and_no_bad_status(self):
        def runner(status, write=True):
            def execute(argv, cap):
                self.assertEqual(argv[0], '/usr/bin/gpgv')
                self.assertIn('--keyring', argv)
                if write:
                    Path(argv[argv.index('--output') + 1]).write_bytes(self.release)
                return status
            return execute
        good = ('[GNUPG:] VALIDSIG ' + 'A' * 40 + ' 2026-10-28 1793145600 0 4 0 1 8 01\n').encode()
        clear, fingerprints = collector.verify_signature(b'signed', b'keyring', runner(good))
        self.assertEqual(clear, self.release)
        self.assertEqual(fingerprints, ['A' * 40])
        for status, write in ((b'', True), (good + b'[GNUPG:] BADSIG x\n', True),
                              (good.replace(b' 8 01', b' 2 01'), True), (good, False)):
            with self.assertRaises(collector.Rejected):
                collector.verify_signature(b'signed', b'keyring', runner(status, write))

    def test_no_caller_url_or_redirect_allowed(self):
        with self.assertRaises(collector.Rejected):
            collector.fetch('http://localhost/secrets', 1)
        with self.assertRaises(collector.Rejected):
            collector.NoRedirect().redirect_request(None, None, 302, None, {}, 'https://evil.invalid/')

    def test_cli_refuses_local_run_incomplete_context_overwrite_and_scan_change(self):
        with tempfile.TemporaryDirectory() as directory:
            scan = Path(directory) / 'scan.json'
            evidence = Path(directory) / 'evidence.json'
            scan.write_bytes(self.context['raw_scan_bytes'])
            argv = ['collector', '--image-id', fixture.IMAGE, '--scan', str(scan), '--evidence', str(evidence)]
            env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'test/repo', 'GITHUB_SHA': 'c' * 40,
                   'GITHUB_RUN_ID': '1', 'GITHUB_RUN_ATTEMPT': '1',
                   'GITHUB_WORKFLOW_REF': 'test/repo/.github/workflows/check.yml@refs/heads/main'}
            with patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'win32'), patch.dict(collector.os.environ, env, clear=True), self.assertRaises(collector.Rejected):
                collector.main()
            with patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'linux'), patch.dict(collector.os.environ, {'GITHUB_ACTIONS': 'true'}, clear=True), self.assertRaises(collector.Rejected):
                collector.main()
            evidence.write_bytes(b'do not replace')
            with patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'linux'), patch.dict(collector.os.environ, env, clear=True), self.assertRaises(collector.Rejected):
                collector.main()
            self.assertEqual(evidence.read_bytes(), b'do not replace')
            evidence.unlink()
            def changed(*args):
                scan.write_bytes(b'changed concurrently')
                return {'fake': True}
            with patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'linux'), patch.dict(collector.os.environ, env, clear=True), patch.object(collector, 'collect', changed), self.assertRaises(collector.Rejected):
                collector.main()
            self.assertFalse(evidence.exists())


if __name__ == '__main__':
    unittest.main()
