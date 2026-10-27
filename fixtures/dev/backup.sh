#!/bin/bash
# Synthetic fixture only. Never discovers application containers or databases.
set -euo pipefail
umask 077
test "${CHICO_SYNTHETIC_ONLY:-}" = true
[[ "${BACKUP_BUCKET:-}" =~ ^chico-dev-[a-z0-9-]+$ ]]
task_here=$(cd -- "$(dirname -- "$0")" && pwd)
task_work=$(mktemp -d)
trap 'rm -rf -- "$task_work"' EXIT
task_compose=(docker compose -p chico-dev-fixture -f "$task_here/compose.yaml")
test "$("${task_compose[@]}" exec -T postgres psql -U fixture -d fixture -Atc 'SHOW server_version_num')" -ge 160000
test "$("${task_compose[@]}" exec -T postgres psql -U fixture -d fixture -Atc 'SHOW server_version_num')" -lt 170000
"${task_compose[@]}" exec -T postgres pg_dump -U fixture -d fixture -Fc > "$task_work/fixture.dump"
printf 'chico-dev-synthetic-file-v1\n' > "$task_work/durable.txt"
(cd "$task_work" && sha256sum fixture.dump durable.txt > SHA256SUMS)
task_prefix="dev/fixtures/$(date -u +%Y%m%dT%H%M%SZ)-$(cat /proc/sys/kernel/random/uuid)"
for task_file in fixture.dump durable.txt SHA256SUMS; do
  aws s3api put-object --region sa-east-1 --bucket "$BACKUP_BUCKET" --key "$task_prefix/$task_file" --body "$task_work/$task_file" --server-side-encryption AES256 >/dev/null
done
install -d -m 0700 /var/lib/chico
date +%s > /var/lib/chico/last-backup-success
printf 'synthetic backup uploaded prefix=%s\n' "$task_prefix"
