"""Offline metadata/build contract tests; no Docker or XML parser execution."""
import datetime as dt
import importlib.util
import json
import lzma
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HERE = ROOT / 'operations/restore-toolchain/libxml-maintenance'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


source = load('source_acquisition', HERE / 'acquire.py')
assessor = load('abi_assessor', HERE / 'assess.py')
context = load('context_composer', HERE / 'prepare_context.py')
runner = load('isolated_runner', HERE.parent / 'isolated_run.py')
integration = load('normal_integration', ROOT / 'tests/restore-libxml-maintenance-integration.py')
NOW = dt.datetime(2026, 10, 29, tzinfo=dt.timezone.utc)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.payloads = {name: ('synthetic-complete-file-' + name).encode() for name in source.PINS['files']}
        self.pins = {**source.PINS, 'files': {name: {'size': len(data), 'sha256': source.collector.review.sha(data)} for name, data in self.payloads.items()}}
        stanza = ('Package: libxml2\nVersion: ' + self.pins['version'] + '\nDirectory: ' + self.pins['directory'] + '\nChecksums-Sha256:\n' +
                  ''.join(' ' + pin['sha256'] + ' ' + str(pin['size']) + ' ' + name + '\n' for name, pin in self.pins['files'].items()))
        self.index = lzma.compress(stanza.encode())
        self.release = self.make_release()

    def make_release(self):
        return ('Origin: Ubuntu\nLabel: Ubuntu\nSuite: noble-security\nCodename: noble\nDate: Wed, 28 Oct 2026 00:00:00 UTC\nSHA256:\n ' +
                source.collector.review.sha(self.index) + ' ' + str(len(self.index)) + ' ' + source.INDEX_PATH + '\n').encode()

    def verify(self, signed, keyring):
        self.assertEqual(signed, b'signed-placeholder')
        self.assertEqual(keyring, b'trusted-runner-keyring-placeholder')
        return self.release, ['A' * 40]

    def fetch(self, url, cap):
        data = b'signed-placeholder' if url == source.RELEASE else self.index if url == source.INDEX else self.payloads[url.rsplit('/', 1)[1]]
        self.assertLessEqual(len(data), cap)
        return data

    def acquire(self, destination, **changes):
        with patch.object(source, 'PINS', self.pins):
            return source.acquire(destination, changes.get('fetcher', self.fetch), changes.get('verifier', self.verify),
                                  b'trusted-runner-keyring-placeholder', NOW)

    def test_complete_authenticated_source_keeps_candidate_unapproved(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp).resolve() / 'new'
            facts = self.acquire(destination)
            self.assertTrue(facts['repositorySignatureVerified'])
            self.assertFalse(facts['signedValidUntilPresent'])
            self.assertEqual(facts['dateFreshnessPolicyDays'], 7)
            self.assertEqual(set(path.name for path in destination.iterdir()), {*self.payloads, 'provenance.json'})
            for name, payload in self.payloads.items():
                self.assertEqual((destination / name).read_bytes(), payload)
            for flag in ('realRestoreApproved', 'gateOverrideApplied', 'rawScanModified'):
                self.assertFalse(facts[flag])

    def test_bad_signature_or_source_bytes_create_no_source_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp).resolve() / 'new'
            def bad_signature(*args):
                raise source.Rejected('synthetic_bad_signature')
            with self.assertRaises(source.Rejected):
                self.acquire(destination, verifier=bad_signature)
            self.assertFalse(destination.exists())
            name = next(iter(self.payloads))
            self.payloads[name] = self.payloads[name][:-1] + b'x'
            with self.assertRaises(source.Rejected):
                self.acquire(destination)
            self.assertFalse(destination.exists())

    def test_metadata_identity_date_hash_and_pins_fail_closed(self):
        with patch.object(source, 'PINS', self.pins):
            for release in (self.release.replace(b'Ubuntu', b'Other', 1),
                            self.release.replace(b'noble-security', b'noble'),
                            self.release.replace(b'28 Oct 2026', b'28 Oct 2027'),
                            self.release.replace(b'28 Oct 2026', b'01 Oct 2026'),
                            self.release.replace(source.collector.review.sha(self.index).encode(), b'0' * 64),
                            self.release + b'Valid-Until: Tue, 27 Oct 2026 00:00:00 UTC\n'):
                with self.assertRaises(ValueError):
                    source.check_metadata(release, self.index, NOW)
            changed = {**self.pins, 'version': 'not-the-reviewed-source'}
            with patch.object(source, 'PINS', changed), self.assertRaises(ValueError):
                source.check_metadata(self.release, self.index, NOW)

    def test_existing_destination_and_caller_urls_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(source.Rejected):
                self.acquire(Path(temp).resolve())
        with self.assertRaises(source.Rejected):
            source.fetch('http://localhost/arbitrary', 1)


class ABIAndBuildTests(unittest.TestCase):
    def metadata(self, directory):
        layout = '\n'.join(f'{name}=32' for name in sorted(assessor.LAYOUT_NAMES)) + '\n'
        symbols = '\n'.join('xmlNormal' + str(i) for i in range(120)) + '\n'
        dynamic = '0 (SONAME) Library soname: [libxml2.so.2]\n1 (NEEDED) Shared library: [libc.so.6]\n'
        headers = ''.join('a' * 64 + f' header{i}.h\n' for i in range(12))
        for name, text in {'layout-before.txt': layout, 'layout-after.txt': layout,
                           'symbols-before.txt': symbols, 'symbols-after.txt': symbols,
                           'dynamic-before.txt': dynamic, 'dynamic-after.txt': dynamic,
                           'baseline-libc-versions.txt': 'Name: GLIBC_2.2.5\nName: GLIBC_2.36\n',
                           'candidate-versions.txt': 'Name: GLIBC_2.2.5\n',
                           'headers-before.sha256': headers, 'headers-after.sha256': headers,
                           'source-provenance.json': json.dumps({'repositorySignatureVerified': True, 'sourceVersion': source.PINS['version']}),
                           'normal-smoke-passed.txt': 'ordinary_xml_sqlxml_offline_backup_restore_passed\n'}.items():
            (directory / name).write_text(text)

    def test_equal_sample_metadata_and_smoke_never_approve_full_abi_or_scan(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.metadata(directory)
            result = assessor.assess(directory)
            self.assertTrue(result['ordinarySmokePassed'])
            self.assertTrue(result['sampledHeaderLayoutsEqual'])
            for flag in ('fullABICompatibilityProven', 'defaultLibraryReplaced', 'packageVersionChanged', 'riskAccepted', 'realRestoreApproved', 'gateOverrideApplied', 'rawScanModified'):
                self.assertFalse(result[flag])
            self.assertEqual(result['status'], 'blocked_pending_abi_and_scan_review')

    def test_layout_symbol_dependency_changes_are_reported_and_stay_blocked(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.metadata(directory)
            path = directory / 'layout-after.txt'
            path.write_text(path.read_text().replace('xmlEntity=32', 'xmlEntity=40'))
            path = directory / 'symbols-after.txt'
            path.write_text(path.read_text().replace('xmlNormal0\n', ''))
            path = directory / 'dynamic-after.txt'
            path.write_text(path.read_text() + '2 (NEEDED) Shared library: [libextra.so.1]\n')
            result = assessor.assess(directory)
            self.assertEqual(result['publicLayoutChanges'], ['xmlEntity'])
            self.assertEqual(result['removedVersionedSymbols'], ['xmlNormal0'])
            self.assertFalse(result['dependencySetEqual'])
            self.assertFalse(result['fullABICompatibilityProven'])

    def test_new_glibc_requirement_is_never_accepted_as_available(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.metadata(directory)
            (directory / 'candidate-versions.txt').write_text('Name: GLIBC_2.39\n')
            result = assessor.assess(directory)
            self.assertFalse(result['candidateGLIBCRequirementsAvailableInBaseline'])
            self.assertFalse(result['fullABICompatibilityProven'])

    def test_incomplete_unsigned_or_wrong_soname_evidence_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name, text in [('symbols-after.txt', 'incomplete'), ('dynamic-after.txt', 'no-soname'),
                               ('source-provenance.json', '{}'), ('layout-after.txt', 'empty=1')]:
                self.metadata(directory)
                (directory / name).write_text(text)
                with self.assertRaises(ValueError):
                    assessor.assess(directory)

    def test_composition_preserves_exact_pinned_baseline_and_rejects_any_delta(self):
        baseline = (HERE.parent / 'Dockerfile').read_bytes()
        candidate = (HERE / 'Dockerfile').read_bytes()
        result = context.compose(baseline, candidate)
        prefix = result[:-len(candidate)].decode().replace(context.BASE_FROM + ' AS baseline\n', context.BASE_FROM + '\n', 1)
        self.assertEqual(prefix, baseline.decode() + '\n')
        with self.assertRaises(ValueError):
            context.compose(baseline + b'# different source\n', candidate)
        self.assertIn(b'FROM baseline AS libxmlcompiler', result)

    def test_library_only_build_and_fixed_ordinary_isolated_smoke(self):
        build = (HERE / 'build.sh').read_text()
        commands = [line.strip() for line in build.splitlines() if line.strip() and not line.lstrip().startswith('#')]
        self.assertIn('make -j2 libxml2.la', commands)
        self.assertFalse(any(line.startswith(('make check', 'make test', 'make runtest', 'make fuzz', 'make all')) for line in commands))
        dockerfile = (HERE / 'Dockerfile').read_text()
        self.assertNotIn('ENV LD_LIBRARY_PATH', dockerfile)
        self.assertNotIn('ldconfig', '\n'.join(line for line in dockerfile.splitlines() if not line.startswith('#')))
        self.assertNotIn('dpkg -i', dockerfile)
        xml = (HERE / 'xml-normal.c').read_text()
        self.assertNotIn('<!DOCTYPE', xml)
        self.assertNotIn('<!ENTITY', xml)
        with tempfile.TemporaryDirectory() as temp:
            command = runner.isolated_command('sha256:' + 'a' * 64, 999,
                {'/scripts': HERE, '/work': Path(temp).resolve()}, '/bin/bash', ['-ceu', 'bash /scripts/normal-smoke.sh'])
        for flag in ('--network=none', '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges'):
            self.assertIn(flag, command)
        self.assertTrue(any('/var/lib/postgresql/data:rw,' in part for part in command))
        self.assertFalse(any('docker.sock' in part for part in command))


class FailureMetadataTests(unittest.TestCase):
    def test_failure_summary_never_exports_input_text(self):
        raw = b'PRIVATE_SENTINEL user@example.invalid SQL VALUES SECRET\nPermission denied\nERROR: [056]\nordinary_stage_failed=source-start\n'
        report = integration.failure_summary(raw, 1)
        self.assertEqual(report['stage'], 'source-start')
        self.assertEqual(report['errorClasses'], ['permission-denied'])
        self.assertEqual(report['pgBackRestErrorCodes'], ['056'])
        self.assertNotIn('PRIVATE_SENTINEL', json.dumps(report))
        self.assertNotIn('example.invalid', json.dumps(report))
        self.assertFalse(report['ordinarySmokePassed'])

    def test_unknown_stage_and_large_logs_stay_bounded(self):
        report = integration.failure_summary(b'ordinary_stage_failed=private-secret', 2)
        self.assertEqual(report['stage'], 'container-setup-or-unreported-stage')
        self.assertNotIn('private-secret', json.dumps(report))
        report = integration.failure_summary(b'x' * 1048577, 1)
        self.assertEqual(report['stage'], 'unavailable-or-oversize')


if __name__ == '__main__':
    unittest.main()
