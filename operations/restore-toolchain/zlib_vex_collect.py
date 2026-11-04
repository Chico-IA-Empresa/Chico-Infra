"""Benign CI fact collection; no scan exception, VEX approval or restore execution.

Only fixed, read-only commands run inside the current image. Public Debian
metadata is verified with the archive keyring from the pinned public base.
"""
import argparse
import datetime as dt
import email.utils
import importlib.util
import json
import lzma
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request
import uuid

spec = importlib.util.spec_from_file_location('zlib_review', Path(__file__).with_name('zlib_vex_review.py'))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
Rejected = review.EvidenceRejected
BASE = 'postgres@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d'
ROOT = 'https://deb.debian.org/debian/'
RELEASE_URL = ROOT + 'dists/bookworm/InRelease'
INDEX_PATH = 'main/binary-amd64/Packages.xz'
INDEX_URL = ROOT + 'dists/bookworm/' + INDEX_PATH
DEB_URL = ROOT + review.DEB_FILENAME
DEB_SIZE = 86684
CAP = 128 * 1024 * 1024
IMAGE_RE = r'sha256:[a-f0-9]{64}'


def run(argv, cap=4 * 1024 * 1024):
    """No shell, bounded wall time/files, no raw stderr in failure messages."""
    import resource  # CLI is Linux-only; unit tests inject a runner.
    def limits():
        resource.setrlimit(resource.RLIMIT_FSIZE, (CAP, CAP))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            completed = subprocess.run(argv, stdout=out, stderr=err, timeout=120,
                                       check=False, preexec_fn=limits)
        except (OSError, subprocess.TimeoutExpired):
            raise Rejected('collector_command_failed_or_timed_out') from None
        if completed.returncode:
            raise Rejected('collector_command_nonzero')
        out.seek(0)
        data = out.read(cap + 1)
        if len(data) > cap:
            raise Rejected('collector_output_limit')
        return data


def docker_read(image, command, runner=run, cap=4 * 1024 * 1024):
    # No host binds/env/socket, inherited data VOLUME is replaced by bounded tmpfs.
    name = 'chico-zlib-evidence-' + uuid.uuid4().hex
    try:
        return runner(['docker', 'run', '--name=' + name, '--rm', '--pull=never', '--network=none',
                   '--read-only', '--user=999:999', '--cap-drop=ALL',
                   '--security-opt=no-new-privileges', '--pids-limit=32',
                   '--memory=128m', '--cpus=1',
                   '--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777',
                   '--tmpfs=/run:rw,noexec,nosuid,nodev,size=1m,mode=755',
                   '--tmpfs=/var/lib/postgresql/data:rw,noexec,nosuid,nodev,size=1m,mode=700,uid=999,gid=999',
                       '--entrypoint=' + command[0], image, *command[1:]], cap=cap)
    except Rejected:
        # Killing the client on timeout does not necessarily stop its container.
        # Remove only this unique collector-owned name, never another job's name.
        try:
            runner(['docker', 'rm', '--force', name], cap=1024)
        except Rejected:
            pass  # Already absent or daemon failure; original failure is preserved.
        raise


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Rejected('public_metadata_redirect_rejected')


def fetch(url, cap):
    if url not in {RELEASE_URL, INDEX_URL, DEB_URL}:
        raise Rejected('fixed_public_url_required')
    try:
        with urllib.request.build_opener(NoRedirect()).open(url, timeout=30) as response:
            if response.status != 200:
                raise Rejected('public_metadata_http_status')
            data = response.read(cap + 1)
    except (OSError, ValueError):
        raise Rejected('public_metadata_unavailable') from None
    if len(data) > cap:
        raise Rejected('public_metadata_size_limit')
    return data


def fields(text):
    result = {}
    key = None
    for line in text.splitlines():
        if line.startswith((' ', '\t')) and key:
            result[key] += '\n' + line
        else:
            key, separator, value = line.partition(':')
            if not separator or key in result:
                raise Rejected('duplicate_or_invalid_debian_field')
            result[key] = value.strip()
    return result


def verify_signature(inrelease, keyring, runner=run):
    if not inrelease or len(inrelease) > 1024 * 1024 or not keyring or len(keyring) > 4 * 1024 * 1024:
        raise Rejected('signature_inputs_out_of_bounds')
    # gpgv produces the authenticated cleartext; never parse unauthenticated armor.
    with tempfile.TemporaryDirectory(prefix='chico-zlib-signature-') as name:
        directory = Path(name)
        key = directory / 'debian.gpg'
        signed = directory / 'InRelease'
        clear = directory / 'Release'
        key.write_bytes(keyring)
        signed.write_bytes(inrelease)
        status = runner(['/usr/bin/gpgv', '--homedir', name, '--keyring', str(key),
                         '--status-fd=1', '--output', str(clear), str(signed)], cap=1024 * 1024).decode('ascii')
        fingerprints = []
        for line in status.splitlines():
            tokens = line.split()
            if len(tokens) >= 2 and tokens[0] == '[GNUPG:]':
                if tokens[1] in {'BADSIG', 'ERRSIG', 'NO_PUBKEY', 'EXPSIG', 'EXPKEYSIG', 'REVKEYSIG', 'FAILURE', 'NODATA'}:
                    raise Rejected('debian_signature_status_rejected')
                if tokens[1] == 'VALIDSIG':
                    # VALIDSIG fingerprint,date,timestamp,expiry,version,reserved,pubalgo,hashalgo,class.
                    if len(tokens) < 11 or not re.fullmatch(r'[A-F0-9]{40,64}', tokens[2]) or tokens[9] not in {'8', '9', '10', '11'}:
                        raise Rejected('strong_signature_status_required')
                    fingerprints.append(tokens[2])
        if not fingerprints or not clear.is_file() or clear.stat().st_size > 1024 * 1024:
            raise Rejected('verified_release_output_required')
        return clear.read_bytes(), sorted(set(fingerprints))


def repository_facts(release_bytes, index_bytes, deb_bytes, now):
    metadata = fields(release_bytes.decode('utf-8'))
    if any(metadata.get(k) != v for k, v in {'Origin': 'Debian', 'Label': 'Debian', 'Codename': 'bookworm'}.items()):
        raise Rejected('signed_release_identity_differs')
    if 'amd64' not in metadata.get('Architectures', '').split() or 'main' not in metadata.get('Components', '').split():
        raise Rejected('signed_release_scope_differs')
    try:
        date = email.utils.parsedate_to_datetime(metadata['Date'])
        if date.tzinfo is None or date > now:
            raise ValueError()
        expiry = email.utils.parsedate_to_datetime(metadata['Valid-Until']) if 'Valid-Until' in metadata else None
        if expiry is not None and (expiry.tzinfo is None or expiry <= now or expiry <= date):
            raise ValueError()
    except (ValueError, KeyError, TypeError, OverflowError):
        raise Rejected('signed_release_date_or_expiry_invalid') from None
    index_rows = [line.split() for line in metadata.get('SHA256', '').splitlines() if line.strip()]
    matches = [row for row in index_rows if len(row) == 3 and row[2] == INDEX_PATH]
    if len(matches) != 1 or matches[0][:2] != [review.sha(index_bytes), str(len(index_bytes))]:
        raise Rejected('signed_packages_hash_or_size_differs')
    try:
        decompressor = lzma.LZMADecompressor(memlimit=128 * 1024 * 1024)
        plain = decompressor.decompress(index_bytes, max_length=CAP + 1)
        if len(plain) > CAP or not decompressor.eof or decompressor.unused_data:
            raise ValueError()
        stanzas = [fields(stanza) for stanza in plain.decode('utf-8').strip().split('\n\n')]
    except (ValueError, UnicodeError, lzma.LZMAError):
        raise Rejected('bounded_packages_xz_required') from None
    packages = [item for item in stanzas if item.get('Package') == 'zlib1g' and item.get('Architecture') == 'amd64']
    expected = {'Package': 'zlib1g', 'Version': review.VERSION, 'Architecture': 'amd64',
                'Source': 'zlib', 'Filename': review.DEB_FILENAME, 'Size': str(DEB_SIZE), 'SHA256': review.OFFICIAL_DEB_SHA256}
    if len(packages) != 1 or any(packages[0].get(k) != v for k, v in expected.items()):
        raise Rejected('signed_package_stanza_differs')
    if len(deb_bytes) != DEB_SIZE or review.sha(deb_bytes) != review.OFFICIAL_DEB_SHA256:
        raise Rejected('signed_deb_hash_or_size_differs')
    return {'repositorySignatureVerified': True, 'releaseSHA256': review.sha(release_bytes),
            'packagesXzSHA256': review.sha(index_bytes), 'packageSHA256': review.sha(deb_bytes),
            'releaseDate': date.isoformat(), 'validUntil': expiry.isoformat() if expiry else None,
            'repositoryFreshnessVerified': expiry is not None,
            'freshnessLimitation': None if expiry else 'bookworm_main_release_has_no_signed_valid_until'}


def inspect(image, runner):
    raw = runner(['docker', 'image', 'inspect', '--format', '{{json .Id}} {{json .Architecture}} {{json .Os}}', image], cap=1024)
    if raw.decode('ascii').strip() != json.dumps(image) + ' "amd64" "linux"':
        raise Rejected('current_image_inspect_binding_differs')


def collect(image, raw, context, runner=run, fetcher=fetch, verifier=verify_signature, now=None):
    if not re.fullmatch(IMAGE_RE, image):
        raise Rejected('immutable_image_id_required')
    if len(raw) > 64 * 1024 * 1024:
        raise Rejected('raw_scan_size_limit')
    inspect(image, runner)
    os_bytes = docker_read(image, ['/bin/cat', '/etc/os-release'], runner)
    os_values = {}
    for line in os_bytes.decode('utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if not sep or key in os_values:
            raise Rejected('invalid_os_release')
        os_values[key] = value.strip('"')
    # Validate scan binding before network/package processing.
    review.scan_finding(raw, image, os_values)
    inventory = docker_read(image, ['/usr/bin/dpkg-query', '-W', '-f=${Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n'], runner).decode('utf-8')
    package_files = docker_read(image, ['/usr/bin/dpkg', '-L', 'zlib1g'], runner).decode('utf-8')
    owner = docker_read(image, ['/usr/bin/dpkg-query', '-S', '/' + review.LIBRARY], runner).decode('utf-8').strip()
    if owner not in {'zlib1g:amd64: /' + review.LIBRARY, 'zlib1g: /' + review.LIBRARY}:
        raise Rejected('installed_library_package_ownership_differs')
    binary = docker_read(image, ['/bin/cat', '/' + review.LIBRARY], runner, cap=review.MAX_ARCHIVE)
    keyring = docker_read(BASE, ['/bin/cat', '/usr/share/keyrings/debian-archive-keyring.gpg'], runner)
    signed = fetcher(RELEASE_URL, 1024 * 1024)
    clear, fingerprints = verifier(signed, keyring, runner)
    index = fetcher(INDEX_URL, 16 * 1024 * 1024)
    deb = fetcher(DEB_URL, DEB_SIZE)
    provenance = repository_facts(clear, index, deb, now or dt.datetime.now(dt.timezone.utc))
    result = review.review_facts(image_id=image, raw_scan_bytes=raw, os_release=os_values,
                                 package_inventory=inventory, package_files=package_files,
                                 installed_library_bytes=binary, deb_bytes=deb,
                                 reviewed_deb_sha256=review.OFFICIAL_DEB_SHA256)
    inspect(image, runner)
    provenance.update({'keyringBase': BASE, 'keyringSHA256': review.sha(keyring),
                       'inReleaseSHA256': review.sha(signed), 'signatureFingerprints': fingerprints,
                       'packageOwnershipSHA256': review.sha(owner.encode()),
                       'collectorSHA256': review.sha(Path(__file__).read_bytes()),
                       'validatorSHA256': review.sha(Path(review.__file__).read_bytes()),
                       'imageInspectBeforeAndAfterMatched': True,
                       'collectedAtUTC': (now or dt.datetime.now(dt.timezone.utc)).isoformat(),
                       'signatureVerifier': '/usr/bin/gpgv',
                       'signatureVerifierSHA256': review.sha(Path('/usr/bin/gpgv').read_bytes()) if sys.platform == 'linux' else None})
    return {'schemaVersion': 1, 'kind': 'fresh-package-evidence-collection',
            'status': 'pending_technical_review', 'context': context, 'provenance': provenance,
            'review': result, 'rawScanSHA256': review.sha(raw), 'imageId': image,
            'rawScanModified': False, 'gateOverrideApplied': False, 'riskAccepted': False,
            'severityDowngraded': False, 'realRestoreApproved': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image-id', required=True)
    parser.add_argument('--scan', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise Rejected('linux_github_ci_only_no_local_docker_start')
    context = {name: os.environ.get(name, '') for name in ('GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_WORKFLOW_REF')}
    if (not re.fullmatch(r'[a-f0-9]{40}', context['GITHUB_SHA']) or
            not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', context['GITHUB_REPOSITORY']) or
            not all(re.fullmatch(r'[1-9][0-9]*', context[key]) for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')) or
            not context['GITHUB_WORKFLOW_REF'].startswith(context['GITHUB_REPOSITORY'] + '/.github/workflows/')):
        raise Rejected('complete_ci_run_context_required')
    if args.scan.is_symlink() or not args.scan.is_file() or args.scan.stat().st_size > 64 * 1024 * 1024:
        raise Rejected('bounded_regular_raw_scan_required')
    if args.evidence.exists() or args.evidence.is_symlink() or args.evidence.resolve() == args.scan.resolve():
        raise Rejected('new_distinct_evidence_file_required')
    raw = args.scan.read_bytes()
    result = collect(args.image_id, raw, context)
    if args.scan.read_bytes() != raw:
        raise Rejected('raw_scan_changed_during_collection')
    # Exclusive creation, no overwrite; output contains hashes/metadata, no raw image environment.
    descriptor = os.open(args.evidence, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print('Package evidence collected; technical review pending; scan gate unchanged.')


if __name__ == '__main__':
    try:
        main()
    except (Rejected, UnicodeError, OSError, ValueError):
        print('Package evidence collection failed; scan gate unchanged.', file=sys.stderr)
        sys.exit(1)
