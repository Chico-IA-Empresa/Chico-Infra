"""Repeatable offline checks; no containers, AWS, secrets or full application boot.

Run with the backend venv Python. Outputs only statuses/counts/exit codes.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import date

ROOT = Path(__file__).resolve().parents[2]


def main():
    environment = {k: v for k, v in os.environ.items() if k.upper() in {
        'SYSTEMROOT', 'WINDIR', 'PATH', 'TEMP', 'TMP', 'COMSPEC', 'PATHEXT', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
        'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMW6432', 'ALLUSERSPROFILE', 'HOME'}}
    environment['CHICOIA_SKIP_DOTENV'] = '1'
    environment.update(API_IMAGE='chico-api:local-fixture', WORKERS_IMAGE='chico-workers:local-fixture',
                       FRONTEND_IMAGE='chico-frontend:local-fixture', PACKAGE_CONFIG_ROOT=str(ROOT.parent / 'chico-package-private-config'),
                       PACKAGE_DATA_ROOT=str(ROOT.parent / 'chico-package-isolated-data'))
    results = []
    commands = [
        ('configuration-import-audit', [sys.executable, 'chico-infra/scripts/package-config-audit.py']),
        ('configuration-audit-tests', [sys.executable, 'chico-infra/tests/package-config-audit.test.py']),
        ('runtime-and-migration-guards', [sys.executable, 'chico-infra/tests/package-runtime.test.py']),
        ('compose-contract', [sys.executable, 'chico-infra/tests/package-compose.test.py']),
        ('node-infra', ['node', '--test', *[str(p.relative_to(ROOT)) for p in sorted((ROOT/'chico-infra/tests').glob('*.test.mjs'))]]),
        ('compose-render', ['docker', 'compose', '-f', 'chico-infra/package/compose.yaml', 'config', '--quiet']),
        ('synthetic-bundle', ['node', 'chico-infra/scripts/package-bundle.mjs']),
        ('synthetic-validation', ['node', 'chico-infra/scripts/package-manifest.mjs', 'chico-infra/package/manifest.synthetic.json']),
    ]
    for name, args in commands:
        try:
            run = subprocess.run(args, cwd=ROOT, env=environment, capture_output=True, timeout=60)
            result = {'check':name, 'exitCode':run.returncode, 'passed':run.returncode == 0}
            # Keep no raw stdout/stderr: arbitrary tool errors may contain local material.
        except (OSError, subprocess.TimeoutExpired) as exc:
            result = {'check':name, 'passed':False, 'errorType':type(exc).__name__}
        results.append(result)
        print(json.dumps(result))
    sources = [Path(__file__), ROOT/'backend/core/package_runtime.py', *sorted((ROOT/'backend/scripts').glob('package_*.py')),
               *sorted((ROOT/'chico-infra/scripts').glob('package-*.py'))]
    for path in sources:
        compile(path.read_text(encoding='utf-8'), str(path), 'exec')
    results.append({'check':'python-syntax', 'files':len(sources), 'passed':True})
    today = date.today().isoformat()
    report = {'date':today, 'scope':'offline only; no application/container/ARM64/AWS acceptance',
              'results':results, 'passed':all(r['passed'] for r in results)}
    (ROOT/f'chico-infra/reports/package-offline-validation-{today.replace("-", "")}.json').write_text(json.dumps(report,indent=2)+'\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
