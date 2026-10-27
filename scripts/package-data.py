"""Prepare NEW fixture directories only; never repairs existing application data."""
import os
import sys
from pathlib import Path


def prepare(root):
    root = Path(root).absolute()
    # Fail if any parent is a symlink rather than following it outside fixture.
    if any(p.is_symlink() for p in (root, *root.parents)):
        raise ValueError('Symlink refused')
    root.mkdir(mode=0o700, exist_ok=False)
    for name, uid in {'postgres': 999, 'redis': 999, 'files': 10001, 'tls': 101}.items():
        path = root / name
        path.mkdir(mode=0o700)
        if hasattr(os, 'chown'):
            os.chown(path, uid, uid)
    print('New fixture data directories prepared; existing paths untouched')


if __name__ == '__main__':
    try:
        prepare(sys.argv[1])
    except Exception as exc:
        print('Fixture directories failed: ' + type(exc).__name__, file=sys.stderr)
        sys.exit(1)
