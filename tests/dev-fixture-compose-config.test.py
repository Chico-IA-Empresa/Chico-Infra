"""Exercise the fixed SSM Compose context with no inherited image variables.

Only Compose configuration is evaluated. No engine, pull, container or AWS call.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'fixtures/dev/create-compose-config.py'
PINS = {
    'POSTGRES_IMAGE': 'docker.io/library/postgres@sha256:' + 'a' * 64,
    'STATIC_IMAGE': 'docker.io/library/busybox@sha256:' + 'b' * 64,
    'CADDY_IMAGE': 'docker.io/library/caddy@sha256:' + 'c' * 64,
}


def load_helper():
    spec = importlib.util.spec_from_file_location('fixture_compose_config', HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FixtureComposeConfigTests(unittest.TestCase):
    def test_fixed_status_context_resolves_project_pins_without_inherited_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            project, elsewhere = base / 'fixture', base / 'unrelated-working-directory'
            shutil.copytree(ROOT / 'fixtures/dev', project)
            elsewhere.mkdir()
            env = {key: value for key, value in os.environ.items()
                   if key not in PINS and not key.startswith('COMPOSE_') and
                   key not in {'DEV_HOSTNAME', 'ACME_DIRECTORY', 'DOCKER_DEFAULT_PLATFORM'}}
            command = ['docker', 'compose', '-f', str(project / 'compose.yaml'),
                       'config', '--format', 'json']
            missing = subprocess.run(command, cwd=elsewhere, env=env, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(missing.returncode, 0, 'Must reproduce missing-pin status context')
            self.assertRegex(missing.stderr, r'(POSTGRES|STATIC|CADDY)_IMAGE')
            load_helper().write_project_environment(project, PINS)
            configured = subprocess.run(command, cwd=elsewhere, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(configured.returncode, 0, configured.stderr)
            model = json.loads(configured.stdout)
            self.assertEqual(set(model['services']), {'postgres', 'static', 'proxy-local'})
            self.assertEqual(model['services']['postgres']['image'], PINS['POSTGRES_IMAGE'])
            self.assertEqual(model['services']['static']['image'], PINS['STATIC_IMAGE'])
            self.assertEqual(model['services']['proxy-local']['image'], PINS['CADDY_IMAGE'])
            self.assertFalse(model['services']['postgres'].get('ports'))
            self.assertEqual(sorted(int(p['published']) for service in model['services'].values()
                                    for p in service.get('ports', [])), [80, 443])
            self.assertTrue(model['networks']['isolated']['internal'])

    def test_only_three_digest_pins_and_local_profile_are_rendered(self):
        result = load_helper().render_project_environment(PINS)
        lines = dict(line.split('=', 1) for line in result.decode('ascii').splitlines())
        self.assertEqual(lines, {**PINS, 'COMPOSE_PROFILES': 'local'})

    def test_missing_extra_mutable_and_injected_values_are_rejected(self):
        helper = load_helper()
        for values in ({}, {**PINS, 'PASSWORD': 'must-not-be-written'},
                       {**PINS, 'POSTGRES_IMAGE': 'postgres:16'},
                       {**PINS, 'STATIC_IMAGE': PINS['STATIC_IMAGE'] + '\nSECRET=bad'},
                       {**PINS, 'CADDY_IMAGE': '${UNREVIEWED_IMAGE}'},
                       {**PINS, 'CADDY_IMAGE': '../caddy@sha256:' + 'c' * 64}):
            with self.subTest(keys=sorted(values)):
                with self.assertRaises(ValueError):
                    helper.render_project_environment(values)

    def test_existing_configuration_is_preserved_without_overwrite(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / 'compose.yaml').write_text('name: test\n')
            helper.write_project_environment(project, PINS)
            before = (project / '.env').read_bytes()
            with self.assertRaises(FileExistsError):
                helper.write_project_environment(project, {**PINS, 'STATIC_IMAGE': PINS['POSTGRES_IMAGE']})
            self.assertEqual((project / '.env').read_bytes(), before)

    def test_missing_compose_is_refused_before_file_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                load_helper().write_project_environment(Path(directory), PINS)
            self.assertFalse((Path(directory) / '.env').exists())


if __name__ == '__main__':
    unittest.main()
