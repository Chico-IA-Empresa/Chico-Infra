"""Offline tests: no imports of application bootstrap or inherited dotenv."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded

runtime = module('package_runtime', ROOT / 'backend/core/package_runtime.py')
seed = module('package_seed', ROOT / 'backend/scripts/package_seed.py')
migrator = module('package_migrate', ROOT / 'backend/scripts/package_migrate.py')


class RuntimeTests(unittest.TestCase):
    def test_migration_destination_checked_before_connection(self):
        migrator.guard_target('postgresql://chico_migrator:fake@postgres/chico_package_test', 'development')
        for url in ['postgresql://chico_migrator:fake@forbidden.invalid/chico_package_test',
                    'postgresql://chico_api:fake@postgres/chico_package_test']:
            with self.assertRaises(ValueError):
                migrator.guard_target(url, 'development')
    def test_migration_accepts_empty_and_known_but_never_orphan_or_unversioned(self):
        migrator.validate_revision_state((), {'baseline'}, set())
        migrator.validate_revision_state(('baseline',), {'baseline', 'head'}, {'users'})
        for current, tables in [(('orphan',), {'users'}), ((), {'users'}), (('baseline','orphan'), {'users'})]:
            with self.assertRaises(ValueError):
                migrator.validate_revision_state(current, {'baseline'}, tables)

    def test_consumers_cover_eleven_processes(self):
        self.assertEqual(len(set(runtime.CONSUMERS) - {'api', 'seed', 'migrator'}), 11)

    def test_missing_and_cross_consumer_rejected_without_values(self):
        with self.assertRaises(ValueError) as malformed:
            runtime.validate('api', {'private-marker-with-punctuation': 'value'})
        self.assertNotIn('private-marker', str(malformed.exception))
        for consumer in runtime.CONSUMERS:
            with self.assertRaises(ValueError) as exc:
                runtime.validate(consumer, {})
            self.assertIn('DATABASE_URL', str(exc.exception))
        with self.assertRaises(ValueError) as exc:
            runtime.validate('migrator', {'DATABASE_URL': 'private-marker', 'SECRET_KEY': 'private-marker'})
        self.assertNotIn('private-marker', str(exc.exception))
        self.assertIn('SECRET_KEY', str(exc.exception))

    def test_rotation_requires_reload_and_is_scoped(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            path = Path(tmp) / 'config.json'
            os.environ.update(CHICO_CONFIG_FILE=str(path), CHICO_CONSUMER='api')
            path.write_text(json.dumps({'DATABASE_URL': 'fixture-db', 'SECRET_KEY': 'version-one'}))
            runtime.load()
            path.write_text(json.dumps({'DATABASE_URL': 'fixture-db', 'SECRET_KEY': 'version-two'}))
            self.assertEqual(os.environ['SECRET_KEY'], 'version-one')
            runtime.load()
            self.assertEqual(os.environ['SECRET_KEY'], 'version-two')
            self.assertNotIn('DEEPSEEK_API_KEY', os.environ)
            self.assertEqual(os.environ['CHICOIA_SKIP_DOTENV'], '1')

    def test_unresolved_and_malformed_refused(self):
        with self.assertRaises(ValueError):
            runtime.validate('migrator', {'DATABASE_URL': '{{resolve:private}}'})
        with self.assertRaises(ValueError):
            runtime.validate('migrator', {'DATABASE_URL': 42})

    def test_seed_never_connects_to_disallowed_target(self):
        for url in ['postgresql://chico_seed:fake@forbidden.invalid/chico_package_test',
                    'postgresql://chico_api:fake@postgres/chico_package_test',
                    'postgresql://chico_seed:fake@postgres/other_fixture']:
            with self.assertRaises(ValueError):
                seed.guard(url, 'chico_package_test')
        seed.guard('postgresql://chico_seed:fake@postgres/chico_package_test', 'chico_package_test')


if __name__ == '__main__':
    unittest.main()
