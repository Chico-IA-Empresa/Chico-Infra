"""Opt-in Linux synthetic PG16 startup test; no AWS or existing data paths."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('startup_templates', ROOT / 'operations/restore-staging/clone-startup-templates.py')
clone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clone)


def image_id(value):
    if not isinstance(value, str) or not re.fullmatch(r'sha256:[a-f0-9]{64}', value):
        raise ValueError('Locally built immutable image ID required')
    return value


def validate_scan(report, image):
    image_id(image)
    if (report.get('SchemaVersion') != 2 or report.get('Metadata', {}).get('ImageID') != image or
            report.get('Metadata', {}).get('OS', {}).get('Family') != 'ubuntu' or
            report['Metadata']['OS'].get('Name') != '24.04' or
            report['Metadata'].get('ImageConfig', {}).get('architecture') != 'amd64' or
            report['Metadata']['ImageConfig'].get('os') != 'linux' or not report.get('Results')):
        raise ValueError('Complete scan of the exact native Noble image required')
    os_reports = [r for r in report['Results'] if r.get('Class') == 'os-pkgs' and r.get('Type') == 'ubuntu']
    packages = [p for result in os_reports for p in result.get('Packages', [])]
    # Trivy dpkg inventory separates the upstream version and Debian revision.
    required = {'postgresql-16': ('16.15', '0ubuntu0.24.04.1'),
                'libxml2': ('2.9.14+dfsg', '1.3ubuntu3.10'),
                'libpcre2-8-0': ('10.42', '4ubuntu2.2')}
    if len(os_reports) != 1 or not packages or any(not any(
            p.get('Name') == name and (p.get('Version'), p.get('Release')) == version and
            p.get('Arch') == 'amd64' and p.get('Epoch', 0) in (None, 0) for p in packages)
            for name, version in required.items()):
        raise ValueError('Pinned PostgreSQL/XML/PCRE2 inventory missing')
    if any(v.get('Severity') == 'CRITICAL' for r in report['Results'] for v in r.get('Vulnerabilities', [])):
        raise ValueError('Critical findings block synthetic startup')


def command(scripts, pgdata, evidence, image):
    image_id(image)
    argv = ['docker', 'run', '--rm', '--pull=never', '--platform=linux/amd64', '--network=none', '--read-only',
            '--cap-drop=ALL', '--security-opt=no-new-privileges', '--user=999:999',
            '--pids-limit=256', '--memory=1536m', '--cpus=2']
    for target in ('/tmp', '/run', '/var/lib/postgresql/data'):
        argv += ['--tmpfs', f'{target}:rw,noexec,nosuid,nodev,uid=999,gid=999,mode=0700,size=128m']
    for source, target, readonly in ((scripts, '/scripts', True), (pgdata, '/pgdata', False), (evidence, '/evidence', False)):
        source = Path(source)
        if not source.is_absolute() or source.resolve() != source or ',' in str(source) or '\n' in str(source):
            raise ValueError('Canonical fresh synthetic mount required')
        argv += ['--mount', f'type=bind,src={source},dst={target}' + (',readonly' if readonly else '')]
    return argv + ['--entrypoint=/bin/bash', image, '/scripts/test-clone-startup.sh']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--scan', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0 or os.environ.get('CHICO_CLONE_INTEGRATION') != 'true':
        raise ValueError('Explicit synthetic Linux CI root opt-in required')
    scan_bytes = args.scan.read_bytes()
    validate_scan(json.loads(scan_bytes), args.image)
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
        result = subprocess.run(command(scripts, pgdata, evidence, args.image), stdin=subprocess.DEVNULL,
                                stdout=log, stderr=log, check=False, timeout=300)
    if result.returncode:
        raise ValueError('Synthetic PG16 startup failed; logs remain private')
    summary = json.loads((evidence / 'summary.json').read_bytes())
    expected = {'schema': 1, 'pg16TemplatesAccepted': True, 'autoConfPrecedenceDemonstrated': True,
                'rolePreloadsSuppressed': True, 'physicalRecoveryValidated': False, 'realDataUsed': False}
    if summary != expected:
        raise ValueError('Synthetic proof incomplete')
    output = {**expected, 'image': args.image, 'exactImageScanPassed': True,
              'scanSHA256': hashlib.sha256(scan_bytes).hexdigest(),
              'toolchainDockerfileSHA256': hashlib.sha256((ROOT / 'operations/restore-toolchain/Dockerfile').read_bytes()).hexdigest()}
    (root / 'summary.json').write_text(json.dumps(output) + '\n')
    print(json.dumps(output))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(f'Synthetic clone integration failed: {type(error).__name__}; private outputs omitted') from None
