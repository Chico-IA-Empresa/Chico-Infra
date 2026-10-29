"""Acquire only pinned official complete sources; never run upstream test cases."""
import argparse
import datetime as dt
import email.utils
import importlib.util
import json
import lzma
import os
from pathlib import Path
import sys
import urllib.request

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('package_collector', HERE.parent / 'zlib_vex_collect.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
Rejected = collector.Rejected
PINS = json.loads((HERE / 'source-pins.json').read_text())
ROOT = 'https://security.ubuntu.com/ubuntu/'
RELEASE = ROOT + 'dists/noble-security/InRelease'
INDEX_PATH = 'main/source/Sources.xz'
INDEX = ROOT + 'dists/noble-security/' + INDEX_PATH
KEYRING = Path('/usr/share/keyrings/ubuntu-archive-keyring.gpg')
URLS = {RELEASE, INDEX, *(ROOT + PINS['directory'] + '/' + name for name in PINS['files'])}


def fetch(url, cap):
    if url not in URLS:
        raise Rejected('fixed_official_source_url_required')
    with urllib.request.build_opener(collector.NoRedirect()).open(url, timeout=30) as response:
        if response.status != 200:
            raise Rejected('official_source_http_failure')
        data = response.read(cap + 1)
    if len(data) > cap:
        raise Rejected('official_source_size_limit')
    return data


def check_metadata(release, compressed, now):
    fields = collector.fields(release.decode('utf-8'))
    expected = {'Origin': 'Ubuntu', 'Label': 'Ubuntu', 'Suite': PINS['suite'], 'Codename': 'noble'}
    if any(fields.get(k) != v for k, v in expected.items()):
        raise Rejected('ubuntu_release_identity_differs')
    date = email.utils.parsedate_to_datetime(fields['Date'])
    if date.tzinfo is None or not dt.timedelta(0) <= now - date <= dt.timedelta(days=7):
        raise Rejected('source_release_date_outside_seven_day_window')
    expiry = email.utils.parsedate_to_datetime(fields['Valid-Until']) if 'Valid-Until' in fields else None
    if expiry is not None and (expiry.tzinfo is None or expiry <= now or expiry <= date):
        raise Rejected('source_release_expired')
    rows = [line.split() for line in fields.get('SHA256', '').splitlines() if line.strip()]
    rows = [row for row in rows if len(row) == 3 and row[2] == INDEX_PATH]
    if len(rows) != 1 or rows[0][:2] != [collector.review.sha(compressed), str(len(compressed))]:
        raise Rejected('authenticated_source_index_hash_or_size_differs')
    decoder = lzma.LZMADecompressor(memlimit=128 * 1024 * 1024)
    clear = decoder.decompress(compressed, max_length=64 * 1024 * 1024 + 1)
    if len(clear) > 64 * 1024 * 1024 or not decoder.eof or decoder.unused_data:
        raise Rejected('bounded_single_source_index_required')
    stanzas = [collector.fields(item) for item in clear.decode().strip().split('\n\n')]
    matches = [item for item in stanzas if item.get('Package') == PINS['source']]
    if len(matches) != 1 or matches[0].get('Version') != PINS['version'] or matches[0].get('Directory') != PINS['directory']:
        raise Rejected('exact_pinned_vendor_source_required')
    rows = [line.split() for line in matches[0].get('Checksums-Sha256', '').splitlines() if line.strip()]
    if len(rows) != len(PINS['files']) or len({row[2] for row in rows if len(row) == 3}) != len(rows):
        raise Rejected('unique_complete_source_file_set_required')
    actual = {row[2]: {'sha256': row[0], 'size': int(row[1])} for row in rows}
    if actual != PINS['files']:
        raise Rejected('vendor_source_pins_differ_from_signed_index')
    return {'releaseDate': date.isoformat(), 'validUntil': expiry.isoformat() if expiry else None,
            'dateFreshnessPolicyDays': 7, 'signedValidUntilPresent': expiry is not None,
            'sourceVersion': PINS['version'], 'sourceIndexSHA256': collector.review.sha(compressed)}


def acquire(destination, fetcher=fetch, verifier=collector.verify_signature, keyring=None, now=None):
    if destination.exists() or destination.absolute() != destination.resolve() or not destination.parent.is_dir():
        raise Rejected('new_canonical_source_directory_required')
    keyring = KEYRING.read_bytes() if keyring is None else keyring
    signed = fetcher(RELEASE, 1024 * 1024)
    release, fingerprints = verifier(signed, keyring)
    index = fetcher(INDEX, 8 * 1024 * 1024)
    facts = check_metadata(release, index, now or dt.datetime.now(dt.timezone.utc))
    # Authenticate every archive before writing any source directory.
    archives = {}
    for name, pin in PINS['files'].items():
        data = fetcher(ROOT + PINS['directory'] + '/' + name, pin['size'])
        if len(data) != pin['size'] or collector.review.sha(data) != pin['sha256']:
            raise Rejected('complete_source_archive_hash_or_size_differs')
        archives[name] = data
    facts.update({'status': 'pending_compatibility_and_technical_review', 'repositorySignatureVerified': True,
                  'keyringPath': str(KEYRING), 'keyringSHA256': collector.review.sha(keyring),
                  'signatureFingerprints': fingerprints, 'inReleaseSHA256': collector.review.sha(signed),
                  'sourcePinsSHA256': collector.review.sha((HERE / 'source-pins.json').read_bytes()),
                  'collectorSHA256': collector.review.sha(Path(__file__).read_bytes()),
                  'signatureHelperSHA256': collector.review.sha(Path(collector.__file__).read_bytes()),
                  'ciContext': {key: os.environ.get(key) for key in ('GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')},
                  'gateOverrideApplied': False, 'rawScanModified': False, 'realRestoreApproved': False})
    destination.mkdir(mode=0o700)
    for name, data in archives.items():
        (destination / name).write_bytes(data)
    (destination / 'provenance.json').write_text(json.dumps(facts, indent=2, sort_keys=True) + '\n')
    return facts


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    try:
        if sys.platform != 'linux' or os.environ.get('GITHUB_ACTIONS') != 'true':
            raise Rejected('trusted_ubuntu_ci_keyring_required')
        os.umask(0o077)
        acquire(args.destination)
        print('Official complete source acquired; candidate and restore remain unapproved.')
    except Exception:
        print('Official source acquisition failed; no compatibility or remediation claim.', file=sys.stderr)
        sys.exit(1)
