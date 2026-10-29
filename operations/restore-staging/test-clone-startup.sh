#!/usr/bin/env bash
# CI-only fresh synthetic PG16 cluster. Never run against recovered/real PGDATA.
set -euo pipefail
umask 077
export PATH=/usr/lib/postgresql/16/bin:/usr/bin:/bin
test "$(id -u)" = 999
test "$(id -un)" = postgres
test ! -e /pgdata/PG_VERSION
test -z "$(find /pgdata -mindepth 1 -maxdepth 1 -print -quit)"
/usr/lib/postgresql/16/bin/postgres --version | grep -Eq 'PostgreSQL\) 16\.'
mkdir -p /tmp/socket /tmp/pgbackrest /evidence/audit
initdb --no-locale --encoding=UTF8 --auth-local=trust --auth-host=reject -D /pgdata > /evidence/initdb.log 2>&1
# Main restored config is deliberately unsuitable. It must never be loaded by
# the safe external template, even though postgresql.auto.conf still is loaded.
printf "include '/scripts/untrusted.conf'\n" > /pgdata/postgresql.conf
printf "shared_preload_libraries = 'synthetic_missing_shared_preload'\n" > /pgdata/postgresql.auto.conf
test "$(postgres -D /pgdata -c config_file=/scripts/clone/postgresql.conf -C shared_preload_libraries 2>/evidence/config-probe.log)" = synthetic_missing_shared_preload
mv -- /pgdata/postgresql.auto.conf /evidence/audit/postgresql.auto.conf
cp -- /pgdata/postgresql.conf /evidence/audit/postgresql.conf
: > /pgdata/postgresql.auto.conf
chmod 0600 /pgdata/postgresql.auto.conf
# No recovery.signal: this proves GUC precedence/startup, not backup/WAL recovery.
test ! -e /pgdata/recovery.signal
test ! -e /pgdata/standby.signal
pg_ctl -D /pgdata -l /evidence/postgres.log -o '-c config_file=/scripts/clone/postgresql.conf' -w start > /evidence/start.log 2>&1
cleanup() { pg_ctl -D /pgdata -m fast -w stop > /evidence/stop.log 2>&1 || true; }
trap cleanup EXIT
task_client_options='-c session_preload_libraries= -c local_preload_libraries= -c search_path=pg_catalog -c default_transaction_read_only=on'
test "$(env -i PATH="$PATH" HOME=/tmp PGOPTIONS="$task_client_options" psql -X -h /tmp/socket -U postgres -d postgres -At -v ON_ERROR_STOP=1 -c "SELECT pg_catalog.current_setting('listen_addresses') = '' AND pg_catalog.current_setting('shared_preload_libraries') = '' AND pg_catalog.current_setting('default_transaction_read_only') = 'on'")" = t
# A synthetic role-default payload proves that client-side startup options are
# needed too. These writes touch only this new disposable CI database.
env -i PATH="$PATH" HOME=/tmp PGOPTIONS='-c default_transaction_read_only=off' psql -X -h /tmp/socket -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER ROLE postgres SET session_preload_libraries='synthetic_missing_session_preload'; ALTER ROLE postgres SET local_preload_libraries='synthetic_missing_local_preload';" > /evidence/role-defaults.log 2>&1
if env -i PATH="$PATH" HOME=/tmp psql -X -h /tmp/socket -U postgres -d postgres -At -c 'SELECT 1' > /evidence/unsafe-client.log 2>&1; then
  echo 'unsafe synthetic client unexpectedly accepted' >&2
  exit 1
fi
test "$(env -i PATH="$PATH" HOME=/tmp PGOPTIONS="$task_client_options" psql -X -h /tmp/socket -U postgres -d postgres -At -v ON_ERROR_STOP=1 -c "SELECT pg_catalog.current_setting('session_preload_libraries') = '' AND pg_catalog.current_setting('local_preload_libraries') = '' AND pg_catalog.current_setting('default_transaction_read_only') = 'on'")" = t
sha256sum /usr/lib/postgresql/16/bin/postgres > /evidence/postgres-binary.sha256
printf '{"schema":1,"pg16TemplatesAccepted":true,"autoConfPrecedenceDemonstrated":true,"rolePreloadsSuppressed":true,"physicalRecoveryValidated":false,"realDataUsed":false}\n' > /evidence/summary.json
