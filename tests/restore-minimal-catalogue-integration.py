"""Native disposable PG16 catalogue proof. No AWS, ECR push or real-data adapter."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / 'operations/restore-staging/catalogue'
sys.path.insert(0, str(MODULES))
import minimal_catalogue as catalogue
from psql_catalogue_session import PsqlSession


def run(argv, *, timeout=30):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=timeout, env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'}).stdout


def inspect(container):
    value = json.loads(run(['/usr/bin/docker', 'inspect', container]))
    if len(value) != 1:
        raise ValueError('Unexpected synthetic inspection')
    return value[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True)
    parser.add_argument('--scan', required=True, type=Path)
    parser.add_argument('--private-evidence', required=True, type=Path)
    parser.add_argument('--summary', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0 or os.environ.get('CHICO_CATALOGUE_SYNTHETIC') != 'true':
        raise ValueError('Explicit native synthetic opt-in required')
    if not re.fullmatch('sha256:[a-f0-9]{64}', args.image):
        raise ValueError('Immutable local image required')
    scan_raw = args.scan.read_bytes()
    scan = json.loads(scan_raw)
    # Reuse the already reviewed native PG16/XML/PCRE2 + complete scan/zeroC gate.
    # HIGH findings remain visible and do not approve operational image delivery.
    spec = importlib.util.spec_from_file_location('clone_scan_gate', ROOT / 'tests/restore-private-config-integration.py')
    prior = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prior)
    prior.validate_scan(scan, args.image)
    packages = [p for result in scan['Results'] if result.get('Class') == 'os-pkgs' for p in result.get('Packages', [])]
    for name in ('apt', 'libapt-pkg6.0t64'):
        found = [p for p in packages if p.get('Name') == name]
        if len(found) != 1 or found[0].get('Version') != '2.8.4ubuntu0.1':
            raise ValueError('Fixed native APT inventory required')
    root = args.private_evidence
    if not root.is_absolute() or root.resolve() != root or os.path.lexists(root) or os.path.lexists(args.summary):
        raise ValueError('Fresh canonical evidence paths required')
    os.umask(0o077)
    root.mkdir(mode=0o700)
    name = 'chico-catalogue-ci-' + uuid.uuid4().hex
    container = None
    session = None
    primary_rejected = False
    command = ['/usr/bin/docker', 'run', '--detach', '--rm', '--pull=never', '--platform=linux/amd64',
               '--name', name, '--label', 'org.chico.synthetic=' + name, '--network=none', '--read-only',
               '--cap-drop=ALL', '--security-opt=no-new-privileges', '--user=999:999',
               '--pids-limit=256', '--memory=1536m', '--cpus=2']
    for target, size in (('/work', '512m'), ('/tmp', '128m'), ('/run', '128m'), ('/var/lib/postgresql/data', '128m')):
        command += ['--tmpfs', f'{target}:rw,noexec,nosuid,nodev,uid=999,gid=999,mode=0700,size={size}']
    command += ['--mount', f'type=bind,src={MODULES},dst=/scripts,readonly',
                '--entrypoint=/bin/bash', args.image, '/scripts/catalogue_fixture.sh']
    try:
        container = run(command).decode().strip()
        if not re.fullmatch('[a-f0-9]{64}', container):
            raise ValueError('Unexpected created-container identity')
        for _ in range(60):
            state = inspect(container)
            if not state['State']['Running']:
                raise ValueError('Synthetic container terminated')
            ready = subprocess.run(['/usr/bin/docker','exec',container,'/usr/bin/test','-f','/work/ready'],
                                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5).returncode == 0
            if ready:
                break
            time.sleep(1)
        else:
            raise ValueError('Synthetic readiness timeout')
        session = PsqlSession(container, 'synthetic_fixture', '/tmp/source-socket', root / 'primary-errors-private.log')
        session.execute(catalogue.TRANSACTION)
        primary_gate = catalogue.decode(session.query(catalogue.GATE_SQL, catalogue.MAX_RESPONSE_BYTES))
        session.execute('ROLLBACK;')
        session.close()
        context = {'sourceManifestSHA256': catalogue.SOURCE_SHA256, 'queryPlanSHA256': catalogue.query_plan_sha256(),
                   'database': 'synthetic_fixture', 'systemIdentifier': primary_gate['systemIdentifier'],
                   'serverVersionNum': primary_gate['version']}
        session = PsqlSession(container, 'synthetic_fixture', '/tmp/source-socket', root / 'primary-reject-errors-private.log')
        try:
            catalogue.collect(session, root / 'primary-rejected', context)
        except catalogue.CatalogueError:
            primary_rejected = not (root / 'primary-rejected/manifest-private.json').exists()
        finally:
            session.close()
        if not primary_rejected:
            raise ValueError('Actual primary gate was not refused')
        session = PsqlSession(container, 'synthetic_fixture', '/tmp/standby-socket', root / 'standby-errors-private.log')
        result = catalogue.collect(session, root / 'paused-private', context)
        session.close()
        session = None
        if result != {'catalogueComplete': True, 'fixedQueriesCompleted': 7, 'privateOutputOnly': True}:
            raise ValueError('Incomplete synthetic catalogue')
        canary = b'CHICO_CATALOGUE_CANARY_NO_REAL_DATA'
        if any(canary in file.read_bytes() for file in (root / 'paused-private').iterdir() if file.is_file()):
            raise ValueError('Forbidden source surface escaped the catalogue allowlist')
        columns = json.loads((root / 'paused-private/C4.json').read_bytes())
        if not any(row['name'] == 'private_note' and row['hasdefault'] is True for row in columns):
            raise ValueError('Expected synthetic column/default flag missing')
        summary = {'schema': 1, 'syntheticOnly': True, 'nativePG16QuerySyntaxValidated': True,
                   'actualPrimaryRejected': True, 'actualPausedStandbyCollected': True,
                   'actualReadOnlyTransactionUsed': True, 'canaryExcluded': True, 'fixedQueries': 7,
                   'queryPlanSHA256': catalogue.query_plan_sha256(), 'imageId': args.image,
                   'scanSHA256': hashlib.sha256(scan_raw).hexdigest(), 'realDataUsed': False,
                   'sourcePayloadAccessApproved': False, 'operationalSourceAdapterValidated': False,
                   'imageDeliveryApproved': False}
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        with args.summary.open('x') as stream:
            json.dump(summary, stream)
            stream.write('\n')
        print('Native synthetic catalogue proof completed; private identifiers/output omitted')
    finally:
        if session is not None:
            session.close()
        if container is not None and re.fullmatch('[a-f0-9]{64}', container):
            # Remove only this invocation's disposable CI container, never host data.
            state = inspect(container)
            if state['Id'] != container or state['Name'] != '/' + name or state['Config']['Labels'].get('org.chico.synthetic') != name:
                raise ValueError('Synthetic cleanup identity differs')
            run(['/usr/bin/docker','rm','--force',container])


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Native catalogue proof failed; private synthetic diagnostics omitted', file=sys.stderr)
        sys.exit(1)
