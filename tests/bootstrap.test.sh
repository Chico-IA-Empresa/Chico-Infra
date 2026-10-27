#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../modules/dev-box/bootstrap-lib.sh"
task_temp=$(mktemp -d)
trap 'rm -rf -- "$task_temp"' EXIT
task_attempts=0
sleep() { :; }
eventual_connectivity() { task_attempts=$((task_attempts+1)); test "$task_attempts" -ge 3; }
retry eventual_connectivity
test "$task_attempts" = 3
task_attempts=0
failed_connectivity() { task_attempts=$((task_attempts+1)); return 1; }
if retry failed_connectivity; then echo 'unbounded/incorrect retry'; exit 1; fi
test "$task_attempts" = 24
prepare_data_directories "$task_temp/data"
printf 'synthetic durable record\n' > "$task_temp/data/postgres/record"
task_checksum=$(sha256sum "$task_temp/data/postgres/record")
prepare_data_directories "$task_temp/data"
test "$task_checksum" = "$(sha256sum "$task_temp/data/postgres/record")"
echo 'PASS: eventual connectivity, bounded failure and nonempty data preservation'
