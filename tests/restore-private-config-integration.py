"""Opt-in Linux synthetic PG16 startup test; no AWS or existing data paths."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'postgres@sha256:472efd9a66f2b2f1a5aeb18b28de74332e6ef88c2b93a1a5d812fb6db67a5f60'
spec = importlib.util.spec_from_file_location('startup_templates', ROOT / 'operations/restore-staging/clone-startup-templates.py')
clone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clone)


def command(scripts, pgdata, evidence):
    argv = ['docker', 'run', '--rm', '--platform=linux/amd64', '--network=none', '--read-only',
            '--cap-drop=ALL', '--security-opt=no-new-privileges', '--user=999:999',
            '--pids-limit=256', '--memory=1536m', '--cpus=2']
    for target in ('/tmp', '/run', '/var/lib/postgresql/data'):
        argv += ['--tmpfs', f'{target}:rw,noexec,nosuid,nodev,uid=999,gid=999,mode=0700,size=128m']
    for source, target, readonly in ((scripts, '/scripts', True), (pgdata, '/pgdata', False), (evidence, '/evidence', False)):
        source = Path(source)
        if not source.is_absolute() or source.resolve() != source or ',' in str(source) or '\n' in str(source):
            raise ValueError('Canonical fresh synthetic mount required')
        argv += ['--mount', f'type=bind,src={source},dst={target}' + (',readonly' if readonly else '')]
    return argv + ['--entrypoint=/bin/bash', IMAGE, '/scripts/test-clone-startup.sh']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0 or os.environ.get('CHICO_CLONE_INTEGRATION') != 'true':
        raise ValueError('Explicit synthetic Linux CI root opt-in required')
    root = args.evidence
    if not root.is_absolute() or root.resolve() != root or os.path.lexists(root):
        raise ValueError('Fresh canonical synthetic evidence directory required')
    os.umask(0o077)
    root.mkdir(mode=0o700)
    scripts, pgdata, evidence = (root / name for name in ('scripts', 'pgdata', 'private'))
    for directory in (scripts, pgdata, evidence, scripts / 'clone'):
        directory.mkdir(mode=0o700)
        os.chown(directory, 999, 999)
    control = {'schema': 1, 'postgresMajor': 16, 'systemIdentifier': '1234567890123456789',
               'sourceManifestSHA256': 'a' * 64, 'settings': {'max_connections': 100,
               'max_worker_processes': 8, 'max_wal_senders': 10, 'max_prepared_transactions': 0,
               'max_locks_per_transaction': 64}}
    for name, contents in clone.render(control, 'a' * 64).items():
        path = scripts / 'clone' / name
        path.write_bytes(contents)
        path.chmod(0o400)
        os.chown(path, 999, 999)
    test_script = scripts / 'test-clone-startup.sh'
    shutil.copyfile(ROOT / 'operations/restore-staging/test-clone-startup.sh', test_script)
    test_script.chmod(0o400)
    os.chown(test_script, 999, 999)
    malicious = scripts / 'untrusted.conf'
    malicious.write_text("shared_preload_libraries='synthetic_missing_main_preload'\n")
    malicious.chmod(0o400)
    os.chown(malicious, 999, 999)
    with (root / 'private-runner.log').open('xb') as log:
        result = subprocess.run(command(scripts, pgdata, evidence), stdin=subprocess.DEVNULL,
                                stdout=log, stderr=log, check=False, timeout=300)
    if result.returncode:
        raise ValueError('Synthetic PG16 startup failed; logs remain private')
    summary = json.loads((evidence / 'summary.json').read_bytes())
    expected = {'schema': 1, 'pg16TemplatesAccepted': True, 'autoConfPrecedenceDemonstrated': True,
                'rolePreloadsSuppressed': True, 'physicalRecoveryValidated': False, 'realDataUsed': False}
    if summary != expected:
        raise ValueError('Synthetic proof incomplete')
    output = {**expected, 'image': IMAGE}
    (root / 'summary.json').write_text(json.dumps(output) + '\n')
    print(json.dumps(output))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(f'Synthetic clone integration failed: {type(error).__name__}; private outputs omitted') from None
