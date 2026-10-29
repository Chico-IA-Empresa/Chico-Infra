"""Make a leased pgBackRest config in private tmpfs; never emit its contents."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys

spec = importlib.util.spec_from_file_location('restore_cipher', Path(__file__).with_name('cipher-envelope.py'))
cipher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cipher)


def read_private(path, limit):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError('Canonical private file required')
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('Private regular file required')
        if os.name == 'posix' and (info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError('Root-owned0600 file required')
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('Private file too large')
        return data


def pinned_json(raw, digest):
    if not re.fullmatch(r'[a-f0-9]{64}', digest) or hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError('Private review hash differs')
    result = json.loads(raw)
    if not isinstance(result, dict):
        raise ValueError('Object metadata required')
    return result


def validate_bindings(directory, metadata, transfer, recipient, source_sha256, instance_id, now):
    if (set(metadata) != {'algorithm', 'context', 'ciphertextSHA256'} or
            metadata['algorithm'] != 'RSA3072-OAEP-SHA256-MGF1SHA256' or
            not isinstance(metadata['ciphertextSHA256'], str) or not re.fullmatch(r'[a-f0-9]{64}', metadata['ciphertextSHA256'])):
        raise ValueError('Reviewed cipher metadata required')
    context = metadata['context']
    cipher.validate_context(context, now)
    if (not re.fullmatch(r'[a-f0-9]{64}', source_sha256) or context['sourceManifestSHA256'] != source_sha256 or
            context['instanceId'] != instance_id or directory.name != context['importId']):
        raise ValueError('Source, host or import binding differs')
    expected_recipient = {'importId', 'notBeforeUTC', 'expiresAtUTC', 'recipientPublicKeySHA256'}
    if set(recipient) != expected_recipient or any(recipient[key] != context[key] for key in expected_recipient):
        raise ValueError('Recipient lease binding differs')
    objects = transfer.get('objects')
    if (transfer.get('account') != context['account'] or transfer.get('sourceBucket') != 'chico-backup' or
            transfer.get('sourceWrites') is not False or transfer.get('sourceManifestSHA256') != source_sha256 or
            not isinstance(objects, list) or not objects or type(transfer.get('objectCount')) is not int or
            transfer['objectCount'] != len(objects) or transfer.get('databaseRestored') is not False or
            transfer.get('readOnlyContainerMountStillRequired') is not True):
        raise ValueError('Versioned source transfer is incomplete')
    seen = set()
    for item in objects:
        key, version, size, digest = (item.get(name) for name in ('key', 'versionId', 'bytes', 'sha256'))
        if (not isinstance(key, str) or key in seen or not key.startswith('pgbackrest/sofascore-postgres/') or
                any(part in {'', '.', '..'} for part in key.split('/')) or re.search(r'[*?\\:\x00-\x1f\x7f]', key) or
                not isinstance(version, str) or version == 'null' or not re.fullmatch(r'[A-Za-z0-9._~+/=-]+', version) or
                type(size) is not int or size < 1 or not isinstance(digest, str) or not re.fullmatch(r'[a-f0-9]{64}', digest)):
            raise ValueError('Invalid transfer item')
        seen.add(key)
    if type(transfer.get('copiedBytes')) is not int or transfer['copiedBytes'] != sum(item['bytes'] for item in objects):
        raise ValueError('Transfer size differs')
    return context


def render_config(secret):
    cipher.validate_secret(secret)
    # pgBackRest2.57 INI non-strict parsing trims values and does not unquote.
    # Preserve bytes exactly, or refuse; do not add shell/JSON/INI quoting.
    if secret.strip() != secret or any(value < 32 or value == 127 for value in secret):
        raise ValueError('Unsupported INI cipher bytes')
    secret.decode('utf-8')
    return (b'[global]\nrepo1-type=posix\nrepo1-path=/repo\nrepo1-cipher-type=aes-256-cbc\nrepo1-cipher-pass=' + secret +
            b'\narchive-async=n\nprocess-max=2\nlog-level-console=off\nlog-level-stderr=off\nlog-level-file=off\n'
            b'lock-path=/tmp/pgbackrest\nspool-path=/tmp/pgbackrest\n[main]\npg1-path=/pgdata\npg1-socket-path=/tmp/socket\n')


def write_config(path, contents, uid, gid):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(contents)
            stream.flush()
            if os.name == 'posix':
                os.fchown(stream.fileno(), uid, gid)
                os.fchmod(stream.fileno(), 0o600)
            os.fsync(stream.fileno())
    except BaseException:
        Path(path).unlink(missing_ok=True)  # Only this newly created output.
        raise


def prepare(directory, metadata_raw, metadata_sha256, transfer_raw, transfer_sha256,
            source_sha256, instance_id, uid, gid, image, now=None):
    directory = Path(directory)
    cipher.require_private_tmpfs(directory)
    if (type(uid) is not int or type(gid) is not int or not 0 < uid < 2 ** 31 or not 0 < gid < 2 ** 31 or
            not re.fullmatch(r'(?:[a-zA-Z0-9./:_-]+@)?sha256:[a-f0-9]{64}', image)):
        raise ValueError('Reviewed nonroot toolchain identity/digest required')
    output = directory / 'pgbackrest.conf'
    if os.path.lexists(output):
        raise ValueError('Existing consumer config refused')
    clock = now or (lambda: datetime.now(timezone.utc))
    metadata = pinned_json(metadata_raw, metadata_sha256)
    transfer = pinned_json(transfer_raw, transfer_sha256)
    recipient = json.loads(read_private(directory / 'recipient-lease.json', 16384))
    context = validate_bindings(directory, metadata, transfer, recipient, source_sha256, instance_id, clock())
    secret = read_private(directory / 'repo.pass', 318)
    contents = render_config(secret)
    # Validate lease again before and after the one write; expiration never
    # authorizes continuing with a config merely because it already exists.
    cipher.lease(context['notBeforeUTC'], context['expiresAtUTC'], clock())
    write_config(output, contents, uid, gid)
    secret = contents = None  # Not a guaranteed cryptographic memory wipe.
    try:
        cipher.lease(context['notBeforeUTC'], context['expiresAtUTC'], clock())
    except Exception:
        output.unlink()  # This invocation created it; key/pass/source stay intact.
        raise
    return {'configReadyInPrivateTmpfsFile': True, 'credentialsEmitted': False, 'databaseRestored': False,
            'sourcePayloadIntegrityValidated': False, 'consumerUID': uid, 'consumerGID': gid, 'toolchainImage': image}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('directory', 'metadata', 'transfer-record'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('metadata-sha256', 'transfer-sha256', 'source-manifest-sha256', 'instance-id', 'image'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--gid', type=int, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise ValueError('Reviewed Linux staging root required')
    os.umask(0o077)
    cipher.require_private_tmpfs(args.directory)
    if args.metadata != args.directory / 'envelope.json' or args.transfer_record != Path('/srv/chico-restore') / args.directory.name / 'transfer-complete.json':
        raise ValueError('Exact reviewed import paths required')
    result = prepare(args.directory, read_private(args.metadata, 65536), args.metadata_sha256,
                     read_private(args.transfer_record, 1024 * 1024), args.transfer_sha256,
                     args.source_manifest_sha256, args.instance_id, args.uid, args.gid, args.image)
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(f'Private restore config failed: {type(error).__name__}; secret material omitted') from None
