#!/bin/bash
# Disposable CI data only. No source bucket, AWS, network or existing PGDATA.
set -Eeuo pipefail
umask 077
test "$(id -u)" = 999
test ! -e /work/primary && test ! -e /work/standby
mkdir -m 0700 /tmp/source-socket /tmp/standby-socket
printf '%s\n' initdb > /work/stage
/usr/lib/postgresql/16/bin/initdb -D /work/primary --auth=trust --no-locale > /work/initdb-private.log 2>&1
printf '%s\n' primary-start > /work/stage
/usr/lib/postgresql/16/bin/pg_ctl -D /work/primary -l /work/primary-private.log -w start \
  -o '-p 5432 -c listen_addresses= -c unix_socket_directories=/tmp/source-socket -c shared_buffers=16MB -c max_connections=20 -c max_wal_senders=2 -c max_replication_slots=2' >/dev/null
printf '%s\n' fixture-create > /work/stage
/usr/lib/postgresql/16/bin/createdb -h /tmp/source-socket -U postgres synthetic_fixture
/usr/lib/postgresql/16/bin/psql -X -q -w -h /tmp/source-socket -U postgres -d synthetic_fixture -v ON_ERROR_STOP=1 <<'SQL' > /work/fixture-private.log 2>&1
CREATE SCHEMA synthetic_private;
CREATE TABLE synthetic_private.records (id integer PRIMARY KEY, private_note text DEFAULT 'CHICO_CATALOGUE_CANARY_NO_REAL_DATA');
INSERT INTO synthetic_private.records VALUES (1, 'CHICO_CATALOGUE_CANARY_NO_REAL_DATA');
COMMENT ON TABLE synthetic_private.records IS 'CHICO_CATALOGUE_CANARY_NO_REAL_DATA';
CREATE FUNCTION synthetic_private.hidden_body() RETURNS text LANGUAGE sql AS $$ SELECT 'CHICO_CATALOGUE_CANARY_NO_REAL_DATA'::text $$;
CREATE VIEW synthetic_private.hidden_view AS SELECT 'CHICO_CATALOGUE_CANARY_NO_REAL_DATA'::text AS private_note;
ANALYZE synthetic_private.records;
SQL
printf '%s\n' synthetic-basebackup > /work/stage
/usr/lib/postgresql/16/bin/pg_basebackup --checkpoint=fast -D /work/standby -h /tmp/source-socket -p 5432 -U postgres -w -X stream -R > /work/basebackup-private.log 2>&1
printf '%s\n' standby-start > /work/stage
/usr/lib/postgresql/16/bin/pg_ctl -D /work/standby -l /work/standby-private.log -w start \
  -o '-p 5433 -c listen_addresses= -c unix_socket_directories=/tmp/standby-socket -c shared_buffers=16MB -c max_connections=20 -c max_wal_senders=2 -c max_replication_slots=2 -c hot_standby=on' >/dev/null
printf '%s\n' pause-request > /work/stage
/usr/lib/postgresql/16/bin/psql -X -qAt -w -h /tmp/standby-socket -p 5433 -U postgres -d synthetic_fixture -v ON_ERROR_STOP=1 -c 'SELECT pg_catalog.pg_wal_replay_pause();' > /work/pause-private.log 2>&1
printf '%s\n' pause-wait > /work/stage
for task_attempt in $(seq 1 30); do
  task_state=$(/usr/lib/postgresql/16/bin/psql -X -qAt -w -h /tmp/standby-socket -p 5433 -U postgres -d synthetic_fixture -v ON_ERROR_STOP=1 -c 'SELECT pg_catalog.pg_get_wal_replay_pause_state();')
  if test "$task_state" = paused; then
    printf 'synthetic_ready=true\n' > /work/ready
    exec /bin/sleep infinity
  fi
  sleep 1
done
exit 1
