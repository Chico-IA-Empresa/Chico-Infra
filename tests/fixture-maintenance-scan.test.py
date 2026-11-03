import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('scan', Path(__file__).resolve().parents[1] / 'scripts' / 'verify-fixture-maintenance-scan.py')
scan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scan)


class ScanGateTests(unittest.TestCase):
    def report(self):
        return {'SchemaVersion': 2, 'Metadata': {'OS': {'Family': 'alpine'}},
                'Results': [{'Target': 'usr/local/bin/gosu', 'Type': 'gobinary',
                             'Packages': [{'Name': 'stdlib', 'Version': 'v1.27.3'}]},
                            {'Class': 'os-pkgs', 'Type': 'alpine',
                             'Packages': [{'Name': 'musl', 'Version': '1.2.5-r0'}]}]}

    def test_complete_inventory_passes_without_host_promotion(self):
        result = scan.verify(self.report(), True)
        self.assertEqual(result['critical'], 0)
        self.assertFalse(result['hostPullApproved'])

    def test_no_language_inventory_is_not_a_clean_gosu_scan(self):
        report = self.report()
        report['Results'] = [{'Type': 'alpine', 'Target': 'alpine'}]
        with self.assertRaises(ValueError):
            scan.verify(report, True)

    def test_old_go_stdlib_cannot_pass_rebuild_gate(self):
        report = self.report()
        report['Results'][0]['Packages'][0]['Version'] = 'v1.24.6'
        with self.assertRaises(ValueError):
            scan.verify(report, True)

    def test_critical_blocks_even_with_fixed_gosu(self):
        report = self.report()
        report['Results'][0]['Vulnerabilities'] = [{'Severity': 'CRITICAL'}]
        with self.assertRaises(ValueError):
            scan.verify(report, True)

    def test_other_findings_remain_pending_review(self):
        report = self.report()
        report['Results'][0]['Vulnerabilities'] = [{'Severity': 'HIGH'}]
        result = scan.verify(report, True)
        self.assertTrue(result['noncriticalReviewPending'])
        self.assertEqual(result['counts'], {'HIGH': 1})

    def test_incomplete_report_refused(self):
        for report in [{}, {'SchemaVersion': 2, 'Results': []}]:
            with self.assertRaises(ValueError):
                scan.verify(report)

    def test_os_metadata_without_os_packages_refused(self):
        report = self.report()
        report['Results'] = report['Results'][:1]
        with self.assertRaises(ValueError):
            scan.verify(report, True)

    def test_exact_brotli_inventory_passes(self):
        report = self.report()
        report['Results'][1]['Packages'].append({'Name': 'brotli-libs', 'Version': '1.2.1-r0'})
        self.assertEqual(scan.verify(report, require_brotli=True)['critical'], 0)

    def test_missing_or_different_brotli_version_refused(self):
        for version in [None, '1.2.0-r0', '1.2.1-r1']:
            report = self.report()
            if version:
                report['Results'][1]['Packages'].append({'Name': 'brotli-libs', 'Version': version})
            with self.subTest(version=version):
                with self.assertRaises(ValueError):
                    scan.verify(report, require_brotli=True)

    def test_failed_probe_preserves_only_stage_metadata(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'fixtures/dev/image-maintenance/review.sh').read_text()
        start = source.index('task_name=setup\n')
        end = source.index('trap record_failure ERR\n', start) + len('trap record_failure ERR\n')
        harness = ('set -Eeuo pipefail\n'
                   'task_evidence="$CHICO_STAGE_TEST_DIRECTORY"\n' + source[start:end] +
                   'stage_event postgres gosu-user-drop\nfalse\n')
        bash = str(Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/bin/bash.exe') if os.name == 'nt' else shutil.which('bash')
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, CHICO_STAGE_TEST_DIRECTORY=directory.replace('\\', '/'))
            environment.pop('BASH_ENV', None)
            result = subprocess.run([bash, '--noprofile', '--norc', '-c', harness], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertEqual(result.stderr, '')
            evidence = Path(directory)
            self.assertEqual(json.loads((evidence / 'failure-summary.json').read_text()),
                             {'image': 'postgres', 'stage': 'gosu-user-drop', 'exitCode': 1})
            self.assertEqual(json.loads((evidence / 'progress.jsonl').read_text()),
                             {'image': 'postgres', 'stage': 'gosu-user-drop'})


if __name__ == '__main__':
    unittest.main()
