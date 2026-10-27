import ast
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('configuration_audit', Path(__file__).parents[1] / 'scripts/package-config-audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class ConfigurationAuditTests(unittest.TestCase):
    def test_records_names_not_literal_defaults(self):
        source = ast.parse('''
value = os.getenv("EXAMPLE_TOKEN", "private-default-do-not-export")
other = os.environ.get("EXAMPLE_HOST", "private-host-do-not-export")
flag = _env_flag("EXAMPLE_ENABLED")
direct = os.environ["EXAMPLE_DIRECT"]
''')
        names = audit.environment_names(source)
        self.assertEqual(names, {'EXAMPLE_TOKEN', 'EXAMPLE_HOST', 'EXAMPLE_ENABLED', 'EXAMPLE_DIRECT'})
        self.assertNotIn('private-', json.dumps(sorted(names)))

    def test_graph_resolves_static_local_modules(self):
        self.assertEqual(audit.source('core.config'), audit.BACKEND / 'core/config.py')
        self.assertIsNone(audit.source('external_dependency_does_not_exist'))
        tree = ast.parse('from .client import Example\nimport core.config')
        imports = set(audit.imports(tree, audit.BACKEND / 'services/sofascore/example.py'))
        self.assertIn('services.sofascore.client', imports)
        self.assertIn('core.config', imports)
        package_imports = set(audit.imports(ast.parse('from .client import Example'), audit.BACKEND / 'services/sofascore/__init__.py'))
        self.assertIn('services.sofascore.client', package_imports)

    def test_report_covers_all_entrypoints_and_keeps_financial_names_excluded(self):
        report = audit.audit()
        self.assertEqual(len(report['consumers']), 14)
        self.assertTrue(any(row['name'] == 'BSD_INGEST_LEAGUE_IDS' and row['sources']
                            for row in report['consumers']['odds-bsd']['variables']))
        for consumer in report['consumers'].values():
            for row in consumer['variables']:
                self.assertNotIn('value', row)
                if audit.FINANCIAL.search(row['name']):
                    self.assertEqual(row['policy'], 'excluded-financial')


if __name__ == '__main__':
    unittest.main()
