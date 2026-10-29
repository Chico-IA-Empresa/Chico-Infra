"""Linux CI only; fresh synthetic ordinary inputs, no security reproductions."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'operations/restore-toolchain'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if (sys.platform != 'linux' or os.geteuid() != 0 or os.environ.get('CHICO_LIBXML_MAINTENANCE') != 'true' or
            not re.fullmatch(r'sha256:[a-f0-9]{64}', args.image)):
        raise ValueError('Explicit Linux synthetic CI and immutable image required')
    evidence = args.evidence.absolute()
    if evidence.exists() or evidence.resolve() != evidence or not evidence.parent.is_dir():
        raise ValueError('Fresh canonical evidence directory required')
    evidence.mkdir(mode=0o700)
    os.chown(evidence, 999, 999)
    runner = load('isolated', SCRIPTS / 'isolated_run.py')
    command = runner.isolated_command(args.image, 999,
        {'/scripts': SCRIPTS / 'libxml-maintenance', '/work': evidence}, '/bin/bash',
        ['-ceu', 'cp /opt/chico-libxml-candidate/evidence/* /work/; bash /scripts/normal-smoke.sh'])
    name = 'chico-libxml-normal-' + uuid.uuid4().hex
    command.insert(2, '--name=' + name)
    # Complete outputs stay in the fresh private synthetic directory, never stdout.
    try:
        with (evidence / 'normal-smoke.log').open('wb') as output:
            result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, timeout=300, check=False)
    finally:
        # Client timeout alone does not guarantee its container stopped.
        subprocess.run(['docker', 'rm', '--force', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
    if result.returncode:
        raise ValueError('Ordinary compatibility test failed; inspect private synthetic evidence')
    assessor = load('assessor', SCRIPTS / 'libxml-maintenance/assess.py')
    report = assessor.assess(evidence)
    report.update({'imageId': args.image, 'baselineSourceCommit': '45909f8b2c2f239cc148bc8e5b94a6dcaefeb7c9',
                   'ciContext': {key: os.environ.get(key) for key in ('GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')}})
    (evidence / 'libxml-maintenance-review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'ordinarySmokePassed': report['ordinarySmokePassed'], 'status': report['status'], 'realRestoreApproved': False}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Benign compatibility collection failed; candidate remains blocked.', file=sys.stderr)
        sys.exit(1)
