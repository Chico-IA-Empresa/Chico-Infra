"""Ephemeral RSA-OAEP envelope. Secret bytes never enter command arguments or stdout."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

OAEP = ['-pkeyopt', 'rsa_padding_mode:oaep', '-pkeyopt', 'rsa_oaep_md:sha256',
        '-pkeyopt', 'rsa_mgf1_md:sha256']


def command(openssl, arguments, data=None):
    result = subprocess.run([str(openssl), *arguments], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False, timeout=60)
    if result.returncode:
        raise ValueError('Private cryptographic operation failed')
    return result.stdout


def utc(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value):
        raise ValueError('Explicit UTC timestamp required')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def lease(start, end, now=None):
    beginning, ending = utc(start), utc(end)
    if not 0 < (ending - beginning).total_seconds() <= 48 * 3600 or not beginning <= (now or datetime.now(timezone.utc)) < ending:
        raise ValueError('Current reviewed lease required')


def canonical(context):
    return json.dumps(context, sort_keys=True, separators=(',', ':')).encode('utf-8')


def validate_context(context, now=None):
    fields = {'schema', 'account', 'region', 'sourceManifestSHA256', 'instanceId', 'importId',
              'recipientPublicKeySHA256', 'ssmCommandId', 'notBeforeUTC', 'expiresAtUTC'}
    if (set(context) != fields or context.get('schema') != 1 or context.get('account') != '306915830875' or
            context.get('region') != 'sa-east-1' or
            not re.fullmatch(r'[a-f0-9]{64}', context.get('sourceManifestSHA256', '')) or
            not re.fullmatch(r'[a-f0-9]{64}', context.get('recipientPublicKeySHA256', '')) or
            not re.fullmatch(r'i-[a-f0-9]{17}', context.get('instanceId', '')) or
            not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', context.get('importId', '')) or
            not re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', context.get('ssmCommandId', ''))):
        raise ValueError('Incomplete or foreign envelope context')
    lease(context['notBeforeUTC'], context['expiresAtUTC'], now)


def public_fingerprint(openssl, public_key):
    text = command(openssl, ['rsa', '-pubin', '-in', str(public_key), '-text', '-noout']).decode('ascii')
    if not re.search(r'Public-Key:\s*\(3072 bit\)', text) or not re.search(r'Exponent:\s*65537\s', text):
        raise ValueError('RSA3072 with exponent65537 required')
    der = command(openssl, ['pkey', '-pubin', '-in', str(public_key), '-outform', 'DER'])
    return hashlib.sha256(der).hexdigest()


def write_private(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(data)


def recipient_command(script_sha256, import_id, start, end, now=None):
    lease(start, end, now)
    if not re.fullmatch(r'[a-f0-9]{64}', script_sha256) or not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', import_id):
        raise ValueError('Exact reviewed script and import ID required')
    path = '/usr/local/lib/chico/restore-cipher-envelope.py'
    return '\n'.join([
        'set +x', 'set -eu', 'umask 077',
        f'test "$(/usr/bin/sha256sum {path} | /usr/bin/cut -d\' \' -f1)" = "{script_sha256}"',
        f'exec /usr/bin/python3 {path} --openssl /usr/bin/openssl recipient --directory /run/chico-restore/{import_id} --not-before {start} --expires-at {end}',
    ])


def recipient(openssl, directory, start, end, now=None):
    lease(start, end, now)
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', directory.name):
        raise ValueError('Reviewed import ID required')
    if os.path.lexists(directory):
        raise ValueError('Fresh key directory required')
    directory.mkdir(mode=0o700)
    os.chmod(directory, 0o700)
    private_key, public_key = directory / 'recipient-private.pem', directory / 'recipient-public.pem'
    command(openssl, ['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072', '-out', str(private_key)])
    os.chmod(private_key, 0o600)
    command(openssl, ['pkey', '-in', str(private_key), '-pubout', '-out', str(public_key)])
    fingerprint = public_fingerprint(openssl, public_key)
    lease(start, end, now)
    record = {'importId': directory.name, 'notBeforeUTC': start, 'expiresAtUTC': end, 'recipientPublicKeySHA256': fingerprint}
    write_private(directory / 'recipient-lease.json', canonical(record))
    return {'publicKeyPEM': public_key.read_text(encoding='ascii'), **record}


def validate_secret(secret):
    # RSA3072 OAEP/SHA256 maximum plaintext is384-2*32-2=318 bytes.
    if not isinstance(secret, bytes) or not 1 <= len(secret) <= 318 or any(value in secret for value in [b'\x00', b'\r', b'\n']):
        raise ValueError('Unsupported private cipher input')


def seal(openssl, secret, public_key, context, now=None):
    validate_context(context, now)
    validate_secret(secret)
    if public_fingerprint(openssl, public_key) != context['recipientPublicKeySHA256']:
        raise ValueError('Recipient differs from authenticated SSM public key')
    label = hashlib.sha256(canonical(context)).hexdigest()
    ciphertext = command(openssl, ['pkeyutl', '-encrypt', '-pubin', '-inkey', str(public_key),
                                   *OAEP, '-pkeyopt', f'rsa_oaep_label:{label}'], secret)
    if len(ciphertext) != 384:
        raise ValueError('Unexpected envelope length')
    return ciphertext, {'algorithm': 'RSA3072-OAEP-SHA256-MGF1SHA256', 'context': context,
                        'ciphertextSHA256': hashlib.sha256(ciphertext).hexdigest()}


def open_envelope(openssl, directory, metadata_bytes, expected_metadata_sha256, ciphertext, now=None):
    if hashlib.sha256(metadata_bytes).hexdigest() != expected_metadata_sha256:
        raise ValueError('Envelope metadata differs from private review')
    metadata = json.loads(metadata_bytes)
    if set(metadata) != {'algorithm', 'context', 'ciphertextSHA256'} or metadata['algorithm'] != 'RSA3072-OAEP-SHA256-MGF1SHA256':
        raise ValueError('Unsupported envelope')
    context = metadata['context']
    validate_context(context, now)
    recorded = json.loads((directory / 'recipient-lease.json').read_bytes())
    if set(recorded) != {'importId', 'notBeforeUTC', 'expiresAtUTC', 'recipientPublicKeySHA256'}:
        raise ValueError('Incomplete recipient binding')
    if directory.name != context['importId'] or any(recorded.get(key) != context[key] for key in recorded):
        raise ValueError('Recipient lease/import binding changed')
    if public_fingerprint(openssl, directory / 'recipient-public.pem') != context['recipientPublicKeySHA256']:
        raise ValueError('Recipient key binding changed')
    if len(ciphertext) != 384 or hashlib.sha256(ciphertext).hexdigest() != metadata['ciphertextSHA256']:
        raise ValueError('Ciphertext differs from pinned envelope')
    output = directory / 'repo.pass'
    if os.path.lexists(output):
        raise ValueError('No overwrite of decrypted cipher material')
    label = hashlib.sha256(canonical(context)).hexdigest()
    secret = command(openssl, ['pkeyutl', '-decrypt', '-inkey', str(directory / 'recipient-private.pem'),
                               *OAEP, '-pkeyopt', f'rsa_oaep_label:{label}'], ciphertext)
    validate_secret(secret)
    lease(context['notBeforeUTC'], context['expiresAtUTC'], now)
    write_private(output, secret)
    secret = None  # Process memory cleanup is not a guaranteed cryptographic wipe.
    return {'cipherReadyInPrivateTmpfsFile': True, 'credentialsEmitted': False, 'databaseRestored': False}


def require_private_tmpfs(directory):
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise ValueError('Reviewed Linux staging executor required')
    root = Path('/run/chico-restore')
    if (not directory.is_absolute() or directory.resolve() != directory or root.resolve() != root or
            not directory.is_relative_to(root) or directory == root or not directory.parent.is_dir()):
        raise ValueError('Private staging tmpfs path required')
    parent = directory if directory.exists() else directory.parent
    stat = parent.stat()
    if stat.st_uid != 0 or stat.st_mode & 0o077:
        raise ValueError('Private root-owned directory required')
    mount = subprocess.run(['findmnt', '-n', '-o', 'FSTYPE', '-T', str(parent)], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if mount.returncode or mount.stdout.strip() != b'tmpfs':
        raise ValueError('Persistent filesystem refused for key/cipher material')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openssl', default='openssl')
    commands = parser.add_subparsers(dest='operation', required=True)
    create = commands.add_parser('recipient')
    create.add_argument('--directory', required=True, type=Path)
    create.add_argument('--not-before', required=True)
    create.add_argument('--expires-at', required=True)
    decrypt = commands.add_parser('open')
    decrypt.add_argument('--directory', required=True, type=Path)
    decrypt.add_argument('--metadata', required=True, type=Path)
    decrypt.add_argument('--metadata-sha256', required=True)
    decrypt.add_argument('--ciphertext', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    require_private_tmpfs(args.directory)
    if args.operation == 'recipient':
        result = recipient(args.openssl, args.directory, args.not_before, args.expires_at)
    else:
        result = open_envelope(args.openssl, args.directory, args.metadata.read_bytes(), args.metadata_sha256, args.ciphertext.read_bytes())
    print(json.dumps(result))  # Public key/control metadata only, never private key/passphrase.


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(f'Cipher envelope failed: {type(error).__name__}; secret material omitted') from None
