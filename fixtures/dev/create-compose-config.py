"""Prepare only nonsecret Compose interpolation for the synthetic fixture.

No container, AWS, secret, installation, scan or operational approval is implied.
Image provenance, ARM64, scan and release gates remain external requirements.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

KEYS = ('POSTGRES_IMAGE', 'STATIC_IMAGE', 'CADDY_IMAGE')
PIN = re.compile(r'[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*@sha256:[a-f0-9]{64}')


def render_project_environment(images):
    if not isinstance(images, dict) or set(images) != set(KEYS):
        raise ValueError('Exactly three reviewed image digest pins required')
    if any(not isinstance(images[key], str) or not PIN.fullmatch(images[key]) for key in KEYS):
        raise ValueError('Immutable image references required; no variables, tags or extra lines')
    # Status SSM has neither inherited image variables nor --env-file/profile.
    # Compose reads this project-local file even from an unrelated working dir.
    return (''.join(f'{key}={images[key]}\n' for key in KEYS) + 'COMPOSE_PROFILES=local\n').encode('ascii')


def write_project_environment(project, images):
    content = render_project_environment(images)
    project = Path(project).absolute()
    if project != project.resolve() or not project.is_dir() or not (project / 'compose.yaml').is_file():
        raise ValueError('Existing nonsymlink fixture project directory required')
    destination = project / '.env'
    # O_EXCL rejects existing regular files, symlinks and incomplete old writes.
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    return {'configurationPrepared': True, 'configurationSHA256': hashlib.sha256(content).hexdigest(),
            'fixtureInstalled': False, 'imagesApproved': False, 'awsCalls': False,
            'containersStarted': False, 'secretValuesWritten': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-directory', required=True, type=Path)
    parser.add_argument('--postgres-image', required=True)
    parser.add_argument('--static-image', required=True)
    parser.add_argument('--caddy-image', required=True)
    args = parser.parse_args()
    try:
        result = write_project_environment(args.project_directory,
                                          dict(zip(KEYS, (args.postgres_image, args.static_image, args.caddy_image))))
    except (OSError, ValueError):
        # Never echo rejected configuration or filesystem contents.
        print(json.dumps({'configurationPrepared': False, 'fixtureInstalled': False,
                          'error': 'Nonsecret fixture configuration refused'}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
