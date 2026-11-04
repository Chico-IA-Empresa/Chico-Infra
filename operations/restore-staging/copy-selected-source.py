"""Copy frozen S3 versions to fresh private staging. Never write to AWS or declare a valid database."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

PREFIX = 'pgbackrest/sofascore-postgres/'
ACCOUNT = '306915830875'


def utc(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('Timezone required')
    return parsed.astimezone(timezone.utc)


def validate_selection(raw, expected_sha256):
    if not re.fullmatch(r'[a-f0-9]{64}', expected_sha256) or hashlib.sha256(raw).hexdigest() != expected_sha256:
        raise ValueError('Source manifest differs from reviewed hash')
    manifest = json.loads(raw.decode('utf-8-sig'))
    if (manifest.get('schema') != 1 or manifest.get('bucket') != 'chico-backup' or
            manifest.get('account') != ACCOUNT or manifest.get('region') != 'sa-east-1' or
            manifest.get('sourceReadOnly') is not True or manifest.get('allSelectedPrefixListingsNotTruncated') is not True or
            manifest.get('inspectedMetadataVersionsUnchanged') is not True or manifest.get('stanza') != 'main' or
            not isinstance(manifest.get('objects'), list) or not manifest['objects'] or
            manifest.get('objectCount') != len(manifest['objects'])):
        raise ValueError('Incomplete frozen selection')
    seen = set()
    for item in manifest['objects']:
        key, version, size = item.get('key'), item.get('versionId'), item.get('bytes')
        if (not isinstance(key, str) or not key.startswith(PREFIX) or
                re.search(r'[*?\\:\x00-\x1f\x7f]', key) or
                any(part in {'', '.', '..'} for part in key.split('/')) or key in seen or
                not isinstance(version, str) or version == 'null' or not re.fullmatch(r'[A-Za-z0-9._~+/=-]+', version) or
                type(size) is not int or size < 1 or not isinstance(item.get('etag'), str)):
            raise ValueError('Unsafe or duplicate selected object')
        utc(item['lastModified'])
        seen.add(key)
    return manifest


def aws_environment():
    # The reviewed staging instance profile is the only credential source.
    # Ignore endpoint/profile/process/container/web-identity/static credentials,
    # including legacy boto files, without changing the parent environment.
    excluded = {'BOTO_CONFIG', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
                'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR'}
    env = {key: value for key, value in os.environ.items()
           if not key.upper().startswith('AWS_') and key.upper() not in excluded}
    env.update({'AWS_REGION': 'sa-east-1', 'AWS_DEFAULT_REGION': 'sa-east-1',
                'AWS_PAGER': '', 'AWS_CLI_AUTO_PROMPT': 'off',
                'AWS_CONFIG_FILE': '/dev/null', 'AWS_SHARED_CREDENTIALS_FILE': '/dev/null',
                'BOTO_CONFIG': '/dev/null', 'AWS_IGNORE_CONFIGURED_ENDPOINT_URLS': 'true',
                'AWS_RETRY_MODE': 'standard', 'AWS_MAX_ATTEMPTS': '1',
                'AWS_EC2_METADATA_DISABLED': 'false', 'AWS_EC2_METADATA_V1_DISABLED': 'true',
                'AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE': 'IPv4',
                'AWS_EC2_METADATA_SERVICE_ENDPOINT': 'http://169.254.169.254',
                'NO_PROXY': '169.254.169.254'})
    return env


def aws_json(arguments, *, expires_at, now=None):
    # get-object always writes its body to a private file, never stdout. This
    # transport permits only these two read APIs; no sync, list/latest or write.
    if arguments == ['sts', 'get-caller-identity']:
        operation = ['sts', 'get-caller-identity']
    elif (len(arguments) == 13 and arguments[:7] ==
          ['s3api', 'get-object', '--bucket', 'chico-backup', '--expected-bucket-owner', ACCOUNT, '--key'] and
          arguments[8] == '--version-id' and arguments[10:12] == ['--checksum-mode', 'ENABLED'] and
          isinstance(arguments[7], str) and arguments[7].startswith(PREFIX) and
          isinstance(arguments[9], str) and arguments[9] not in {'', 'null'} and
          isinstance(arguments[12], str) and arguments[12].startswith('/srv/chico-restore/')):
        # Encode reviewed metadata as JSON, so a VersionId beginning with '-'
        # cannot become an AWS CLI flag. No user-provided flags are forwarded.
        payload = {'Bucket': 'chico-backup', 'ExpectedBucketOwner': ACCOUNT,
                   'Key': arguments[7], 'VersionId': arguments[9], 'ChecksumMode': 'ENABLED'}
        operation = ['s3api', 'get-object', '--cli-input-json', json.dumps(payload), arguments[12]]
    else:
        raise ValueError('Read-only transport API required')
    remaining = (utc(expires_at) - (now or (lambda: datetime.now(timezone.utc)))()).total_seconds()
    if remaining <= 0:
        raise ValueError('AWS read lease expired')
    # 60 seconds is the AWS CLI's documented default connection/read-inactivity
    # timeout. The total process deadline is derived solely from the fixed lease.
    inactivity = str(max(1, min(60, math.ceil(remaining))))
    try:
        result = subprocess.run(['/usr/bin/aws', '--region', 'sa-east-1', '--no-cli-pager', '--output', 'json',
                                 '--cli-connect-timeout', inactivity, '--cli-read-timeout', inactivity, *operation],
                                env=aws_environment(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=False, timeout=remaining)
    except subprocess.TimeoutExpired:
        raise RuntimeError('AWS read exceeded the reviewed lease; partial data remains private') from None
    if result.returncode:
        raise RuntimeError('Private AWS read failed; no response contents emitted')
    return json.loads(result.stdout)


def write_record(path, value):
    with path.open('x', encoding='utf-8') as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, indent=2)
        stream.write('\n')


def copy_selection(manifest, destination, call, not_before, expires_at, *, expected_instance_id, now=None):
    clock = now or (lambda: datetime.now(timezone.utc))
    start, end = utc(not_before), utc(expires_at)
    if not 0 < (end - start).total_seconds() <= 48 * 3600 or not start <= clock() < end:
        raise ValueError('Current reviewed lease of at most48h required')
    if not isinstance(expected_instance_id, str) or not re.fullmatch(r'i-[a-f0-9]{17}', expected_instance_id):
        raise ValueError('Exact reviewed staging instance required')
    if os.path.lexists(destination):
        raise ValueError('Fresh destination required; no overwrite or implicit resume')
    identity = call(['sts', 'get-caller-identity'])
    if (identity.get('Account') != ACCOUNT or identity.get('Arn') !=
            f'arn:aws:sts::{ACCOUNT}:assumed-role/chico-dev-restore/{expected_instance_id}'):
        raise ValueError('Exact temporary restore role and staging instance session required')
    if shutil.disk_usage(destination.parent).free < sum(item['bytes'] for item in manifest['objects']) + 1024 ** 3:
        raise ValueError('Insufficient copy workspace; no capacity change or deletion authorized')
    destination.mkdir(mode=0o700)
    os.chmod(destination, 0o700)
    repository = destination / 'repo'
    repository.mkdir(mode=0o700)
    records = []
    try:
        for item in manifest['objects']:
            if not start <= clock() < end:
                raise ValueError('Copy lease expired')
            target = repository.joinpath(*item['key'][len(PREFIX):].split('/'))
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            partial = target.with_name(target.name + '.partial')
            if os.path.lexists(target) or os.path.lexists(partial):
                raise ValueError('Destination collision')
            response = call(['s3api', 'get-object', '--bucket', 'chico-backup', '--expected-bucket-owner', ACCOUNT,
                             '--key', item['key'], '--version-id', item['versionId'], '--checksum-mode', 'ENABLED', str(partial)])
            if (response.get('VersionId') != item['versionId'] or response.get('ContentLength') != item['bytes'] or
                    response.get('ETag') != item['etag'] or utc(response['LastModified']) != utc(item['lastModified']) or
                    partial.is_symlink() or not partial.is_file() or partial.stat().st_size != item['bytes']):
                raise ValueError('Downloaded version metadata/size differs from selection')
            digest = hashlib.sha256()
            with partial.open('rb') as stream:
                for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
                    if not start <= clock() < end:
                        raise ValueError('Copy lease expired during local checksum')
                    digest.update(block)
            full_sha = response.get('ChecksumSHA256') if response.get('ChecksumType') == 'FULL_OBJECT' else None
            if full_sha and base64.b64decode(full_sha, validate=True) != digest.digest():
                raise ValueError('Full-object server checksum mismatch')
            os.chmod(partial, 0o444)
            partial.rename(target)
            records.append({'key': item['key'], 'versionId': item['versionId'], 'bytes': item['bytes'],
                            'sha256': digest.hexdigest(), 'fullObjectServerSHA256Verified': bool(full_sha)})
        if not start <= clock() < end:
            raise ValueError('Copy lease expired before completion record')
        # Ciphertext only. Private parent0700 protects host access. A read-only
        # bind mount is additionally required: chmod is not an immutable mount.
        for directory, _, _ in os.walk(repository, topdown=False):
            os.chmod(directory, 0o555)
        evidence = {'account': ACCOUNT, 'sourceBucket': 'chico-backup', 'sourceWrites': False,
                    'sourceManifestSHA256': manifest['_reviewedSHA256'], 'objects': records,
                    'objectCount': len(records), 'copiedBytes': sum(item['bytes'] for item in records),
                    'backupPayloadIntegrityValidated': False, 'walIntegrityValidated': False, 'databaseRestored': False,
                    'readOnlyContainerMountStillRequired': True}
        write_record(destination / 'transfer-complete.json', evidence)
        return evidence
    except Exception as error:
        write_record(destination / 'transfer-failed.json', {'errorType': type(error).__name__, 'completedObjects': len(records),
                                                           'databaseRestored': False, 'noImplicitCleanupOrResume': True})
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--not-before', required=True)
    parser.add_argument('--expires-at', required=True)
    parser.add_argument('--instance-id', required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise ValueError('Reviewed Linux staging executor required')
    os.umask(0o077)
    original = args.destination
    destination = original.resolve()
    allowed = Path('/srv/chico-restore').resolve()
    if (not original.is_absolute() or original != destination or not destination.is_relative_to(allowed) or
            destination == allowed or not destination.parent.is_dir()):
        raise ValueError('Fresh absolute destination under staging root required')
    manifest = validate_selection(args.manifest.read_bytes(), args.manifest_sha256)
    manifest['_reviewedSHA256'] = args.manifest_sha256
    result = copy_selection(manifest, destination,
                            lambda arguments: aws_json(arguments, expires_at=args.expires_at),
                            args.not_before, args.expires_at, expected_instance_id=args.instance_id)
    print(json.dumps({'copiedObjects': result['objectCount'], 'copiedBytes': result['copiedBytes'],
                      'sourceWrites': False, 'databaseRestored': False, 'evidencePrivate': True}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(f'Selected-source copy failed: {type(error).__name__}; no payload or credentials emitted') from None
