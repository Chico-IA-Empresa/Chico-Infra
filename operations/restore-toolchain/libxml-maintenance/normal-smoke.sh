#!/bin/bash
# Only bounded ordinary XML/SQLXML and a new offline local backup/restore.
set -euo pipefail
task_stage=library-linkage
trap 'task_failure=$?; printf "ordinary_stage_failed=%s\n" "$task_stage" >&2; exit "$task_failure"' ERR
export LD_LIBRARY_PATH=/opt/chico-libxml-candidate/lib
ldd /usr/lib/postgresql/16/bin/postgres > /work/postgres-selected-ldd.txt
ldd /usr/local/bin/pgbackrest > /work/pgbackrest-selected-ldd.txt
for task_link in /work/postgres-selected-ldd.txt /work/pgbackrest-selected-ldd.txt; do
  grep -F 'libxml2.so.2 => /opt/chico-libxml-candidate/lib/libxml2.so.2 ' "$task_link" >/dev/null
  ! grep -q 'not found' "$task_link"
done
task_stage=xml-probe
/opt/chico-libxml-candidate/xml-normal-probe
task_stage=postgres-versions
test "$(pgbackrest version)" = 'pgBackRest 2.57.0'
postgres --version | grep -E '^postgres \(PostgreSQL\) 16\.13([ .]|$)'
task_data=/work/pgdata
task_restored=/work/restored
task_log=/work/postgres.log
test ! -e "$task_data" && test ! -e "$task_restored" && test ! -e /work/repo
task_stage=initdb
initdb -D "$task_data" --encoding=UTF8 --no-locale --auth-local=trust --auth-host=reject > /work/initdb.log
task_running=''
cleanup() {
  task_status=$?
  if test -n "$task_running"; then pg_ctl -D "$task_running" -m immediate -w stop >/dev/null 2>&1 || true; fi
  exit "$task_status"
}
trap cleanup EXIT
start() {
  pg_ctl -D "$1" -l "$task_log" -o '-c listen_addresses= -c unix_socket_directories=/run -c shared_preload_libraries= -c ssl=off -c archive_mode=off -c logging_collector=off' -w start >/dev/null
  task_running=$1
}
sql() { psql -X -h /run -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc "$1"; }
check_sqlxml() {
  test "$(sql "SELECT count(*)=3 AND bool_and(xpath_exists('/root/item',payload)) FROM xml_fixture")" = t
  test "$(sql "SELECT sum(x.item_id)=9 FROM xml_fixture, XMLTABLE('/root/item' PASSING payload COLUMNS item_id int PATH '@id') x")" = t
  test "$(sql "SELECT bool_and(length(xmlserialize(CONTENT payload AS text))>0) FROM xml_fixture")" = t
}
task_stage=source-start
start "$task_data"
task_stage=source-schema
sql 'CREATE TABLE xml_fixture(id integer PRIMARY KEY, payload xml)' >/dev/null
sql "INSERT INTO xml_fixture SELECT n, XMLPARSE(DOCUMENT '<root><item id=\"1\">alpha</item><item id=\"2\">beta</item></root>') FROM generate_series(1,3) n" >/dev/null
task_stage=source-sqlxml
check_sqlxml
task_stage=source-stop
pg_ctl -D "$task_data" -m fast -w stop >/dev/null
task_running=''
task_options=(--config=/dev/null --stanza=fixture --repo1-type=posix --repo1-path=/work/repo --log-level-console=error --log-level-file=off)
task_stage=stanza-create
pgbackrest "${task_options[@]}" --pg1-path="$task_data" --no-online stanza-create
task_stage=offline-backup
pgbackrest "${task_options[@]}" --pg1-path="$task_data" --no-online --no-archive-check --type=full backup
task_stage=backup-label
mapfile -t task_labels < <(find /work/repo/backup/fixture -mindepth 1 -maxdepth 1 -type d -name '*F' -printf '%f\n')
test "${#task_labels[@]}" = 1
[[ "${task_labels[0]}" =~ ^[0-9]{8}-[0-9]{6}F$ ]]
task_stage=offline-restore
pgbackrest "${task_options[@]}" --pg1-path="$task_restored" --set="${task_labels[0]}" --type=none restore
task_stage=restored-start
start "$task_restored"
task_stage=restored-sqlxml
check_sqlxml
task_stage=restored-stop
pg_ctl -D "$task_restored" -m fast -w stop >/dev/null
task_running=''
printf '%s\n' 'ordinary_xml_sqlxml_offline_backup_restore_passed' > /work/normal-smoke-passed.txt
