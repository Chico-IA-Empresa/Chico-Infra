#!/usr/bin/env bash
# Linux container only; synthetic repository under a fresh /work mount.
set -euo pipefail
umask 077
test "$(id -u)" != 0
test ! -e /work/pg/PG_VERSION
test ! -e /work/repo/backup
mkdir -p /work/pg /work/repo /tmp/pgbackrest /tmp/socket
echo CHICO_SYNTHETIC_STAGE=configuration
test -s /config/pgbackrest.conf
echo CHICO_SYNTHETIC_STAGE=initdb
initdb --no-locale --encoding=UTF8 --auth-local=trust --auth-host=reject -D /work/pg > /work/initdb.log 2>&1
cat >> /work/pg/postgresql.conf <<'CONF'
listen_addresses = ''
unix_socket_directories = '/tmp/socket'
archive_mode = on
archive_command = 'pgbackrest --config=/config/pgbackrest.conf --stanza=fixture archive-push %p'
wal_level = replica
max_wal_senders = 0
CONF
echo CHICO_SYNTHETIC_STAGE=postgres-start
pg_ctl -D /work/pg -l /work/postgres.log -w start > /work/start.log 2>&1
cleanup() { pg_ctl -D /work/pg -m fast -w stop >> /work/stop.log 2>&1 || true; }
trap cleanup EXIT
echo CHICO_SYNTHETIC_STAGE=sql-before-full
psql -h /tmp/socket -d postgres -v ON_ERROR_STOP=1 -c 'CREATE TABLE fixture(id integer PRIMARY KEY, value text NOT NULL); INSERT INTO fixture VALUES (1, '\''synthetic-a'\''), (2, '\''synthetic-b'\'');' > /work/sql.log 2>&1
echo CHICO_SYNTHETIC_STAGE=stanza-create
pgbackrest --config=/config/pgbackrest.conf --stanza=fixture --log-level-stderr=info stanza-create > /work/stanza.log 2>&1
echo CHICO_SYNTHETIC_STAGE=full-backup
pgbackrest --config=/config/pgbackrest.conf --stanza=fixture --log-level-stderr=info --type=full backup > /work/full.log 2>&1
sleep 2
echo CHICO_SYNTHETIC_STAGE=sql-before-diff
psql -h /tmp/socket -d postgres -v ON_ERROR_STOP=1 -c 'INSERT INTO fixture VALUES (3, '\''synthetic-c'\'');' >> /work/sql.log 2>&1
echo CHICO_SYNTHETIC_STAGE=diff-backup
pgbackrest --config=/config/pgbackrest.conf --stanza=fixture --log-level-stderr=info --type=diff backup > /work/diff.log 2>&1
echo CHICO_SYNTHETIC_STAGE=info
pgbackrest --config=/config/pgbackrest.conf --stanza=fixture --output=json info > /work/info.json
