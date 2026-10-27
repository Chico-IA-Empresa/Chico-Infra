"""Offline orchestration contract; does not assert that containers ran."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class ComposeTests(unittest.TestCase):
    def setUp(self):
        self.config = yaml.safe_load((ROOT / 'package/compose.yaml').read_text())

    def test_network_and_ports_are_isolated(self):
        self.assertTrue(self.config['networks']['isolated']['internal'])
        services = self.config['services']
        for name, service in services.items():
            self.assertEqual(service['platform'], 'linux/arm64')
            self.assertNotIn('network_mode', service)
            if name != 'proxy':
                self.assertNotIn('ports', service)
        self.assertTrue(services['proxy']['ports'][0].startswith('127.0.0.1:'))

    def test_maintenance_failure_blocks_application(self):
        services = self.config['services']
        self.assertEqual(len(services['migrate']['tmpfs']), 2)
        self.assertTrue(all(mount.startswith('/') for mount in services['migrate']['tmpfs']))
        self.assertEqual(services['migrate']['image'], services['api']['image'])
        self.assertEqual(services['migrate']['restart'], 'no')
        self.assertEqual(services['seed']['depends_on']['migrate']['condition'], 'service_completed_successfully')
        self.assertEqual(services['api']['depends_on']['seed']['condition'], 'service_completed_successfully')
        self.assertEqual(services['web']['depends_on']['api']['condition'], 'service_healthy')

    def test_scoped_secrets_no_global_env(self):
        for name, service in self.config['services'].items():
            self.assertNotIn('env_file', service)
            self.assertNotIn('DATABASE_URL', service.get('environment', {}))
            if name in {'api','migrate','seed'}:
                self.assertEqual(len(service['secrets']), 1)
        self.assertNotIn('secrets', self.config['services']['web'])

    def test_business_topology_stays_disabled(self):
        topology = self.config['x-business-topology']
        self.assertEqual(len(topology), 11)
        self.assertTrue(all(p['enabled'] is False for p in topology.values()))
        self.assertEqual(self.config['services']['workers-harness']['profiles'], ['mock-workers'])
        for p in topology.values():
            module = ROOT.parent / 'backend' / (p['module'].replace('.', '/') + '.py')
            self.assertTrue(module.is_file(), str(module))


if __name__ == '__main__':
    unittest.main()
