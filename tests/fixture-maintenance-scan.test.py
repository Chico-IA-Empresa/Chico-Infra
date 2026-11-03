import importlib.util
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
