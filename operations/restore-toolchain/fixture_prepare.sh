#!/usr/bin/env bash
# Linux container only; synthetic repository under a fresh /work mount.
set -euo pipefail
umask 077
test "$(id -u)" != 0
test ! -e /work/pg/PG_VERSION
test ! -e /work/repo/backup
mkdir -p /work/pg /work/repo /tmp/pgbackrest /tmp/socket
python3 - <<'PY'
import secrets
from pathlib import Path
secret = secrets.token_urlsafe(48)
Path('/work/cipher-fixture-only').write_text(secret)
Path('/tmp/fixture.conf').write_text('''[global]
repo1-path=/work/repo
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=''' + secret + '''
repo1-retention-full=2
repo1-bundle=n
repo1-block=n
compress-type=gz
process-max=2
log-level-console=off
log-level-file=off
lock-path=/tmp/pgbackrest
spool-path=/tmp/pgbackrest
[fixture]
pg1-path=/work/pg
pg1-socket-path=/tmp/socket
''')
PY
initdb --no-locale --encoding=UTF8 --auth-local=trust --auth-host=reject -D /work/pg > /work/initdb.log 2>&1
cat >> /work/pg/postgresql.conf <<'CONF'
listen_addresses = ''
unix_socket_directories = '/tmp/socket'
archive_mode = on
archive_command = 'pgbackrest --config=/tmp/fixture.conf --stanza=fixture archive-push %p'
wal_level = replica
max_wal_senders = 0
CONF
pg_ctl -D /work/pg -l /work/postgres.log -w start > /work/start.log 2>&1
cleanup() { pg_ctl -D /work/pg -m fast -w stop >> /work/stop.log 2>&1 || true; }
trap cleanup EXIT
psql -h /tmp/socket -d postgres -v ON_ERROR_STOP=1 -c 'CREATE TABLE fixture(id integer PRIMARY KEY, value text NOT NULL); INSERT INTO fixture VALUES (1, '\''synthetic-a'\''), (2, '\''synthetic-b'\'');' > /work/sql.log 2>&1
pgbackrest --config=/tmp/fixture.conf --stanza=fixture stanza-create > /work/stanza.log 2>&1
pgbackrest --config=/tmp/fixture.conf --stanza=fixture --type=full backup > /work/full.log 2>&1
sleep 2
psql -h /tmp/socket -d postgres -v ON_ERROR_STOP=1 -c 'INSERT INTO fixture VALUES (3, '\''synthetic-c'\'');' >> /work/sql.log 2>&1
pgbackrest --config=/tmp/fixture.conf --stanza=fixture --type=diff backup > /work/diff.log 2>&1
pgbackrest --config=/tmp/fixture.conf --stanza=fixture --output=json info > /work/info.json
python3 - <<'PY'
import json
from pathlib import Path
info = json.loads(Path('/work/info.json').read_text())[0]
backups = info['backup']
assert len(backups) == 2 and [b['type'] for b in backups] == ['full', 'diff']
Path('/work/labels.json').write_text(json.dumps([b['label'] for b in backups]))
PY
