"""Create NEW local random credentials only. Does not fetch secrets or contact AWS."""
import json
import os
import secrets
import sys
from pathlib import Path
from urllib.parse import quote


def create(destination):
    destination = Path(destination).absolute()
    if any(p.is_symlink() for p in (destination, *destination.parents)):
        raise ValueError('Symlink refused')
    # Refuse reuse: no accidental overwrite or rotation of a running DB.
    destination.mkdir(mode=0o700, parents=False, exist_ok=False)
    passwords = {k: secrets.token_urlsafe(32) for k in ("postgres", "api", "workers", "migrator", "seed")}
    def private(name, value, uid=0):
        path = destination / name
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
        with os.fdopen(fd, 'w') as stream:
            stream.write(value)
        if hasattr(os, 'chown'):
            os.chown(path, uid, uid)
    for k, password in passwords.items():
        # Official PostgreSQL entrypoint executes initdb.d as UID 999, after
        # dropping root. Root-only files would silently yield empty psql vars.
        private(k + '_password', password, uid=999)
    for consumer in ('api', 'workers', 'migrator', 'seed'):
        values = {'ENVIRONMENT': 'development', 'DATABASE_URL':
                  f'postgresql://chico_{consumer}:{quote(passwords[consumer])}@postgres:5432/chico_package_test'}
        if consumer in ('api', 'workers'):
            values['REDIS_URL'] = 'redis://redis:6379/0'
        if consumer == 'api':
            values.update(SECRET_KEY=secrets.token_urlsafe(48), CORS_ALLOWED_ORIGINS='http://127.0.0.1:18080,http://localhost:18081', SESSION_COOKIE_DOMAIN='')
        if consumer == 'seed':
            values.update(DEV_SEED_TARGET='chico_package_test', DEV_SEED_PASSWORD=secrets.token_urlsafe(24))
        private(consumer + '.json', json.dumps(values), uid=10001)
    print('Created private synthetic configuration; no values displayed')


if __name__ == '__main__':
    try:
        create(sys.argv[1])
    except Exception as exc:
        print('Fixture configuration failed: ' + type(exc).__name__, file=sys.stderr)
        sys.exit(1)
