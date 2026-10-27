#!/bin/bash
# Download a fixture into a new isolated database, never overwrite fixture source.
set -euo pipefail
umask 077
test "${CHICO_SYNTHETIC_ONLY:-}" = true
[[ "${BACKUP_BUCKET:-}" =~ ^chico-dev-[a-z0-9-]+$ ]]
[[ "${BACKUP_PREFIX:-}" =~ ^dev/fixtures/[0-9]{8}T[0-9]{6}Z-[a-f0-9-]+$ ]]
[[ "${POSTGRES_IMAGE:-}" =~ @sha256:[a-f0-9]{64}$ ]]
task_work=$(mktemp -d)
task_container="chico-dev-restore-$(date +%s)-$$"
task_started=$(date +%s)
cleanup() {
  docker rm -f "$task_container" >/dev/null 2>&1 || true
  rm -rf -- "$task_work"
}
trap cleanup EXIT
for task_file in fixture.dump durable.txt SHA256SUMS; do
  aws s3api get-object --region sa-east-1 --bucket "$BACKUP_BUCKET" --key "$BACKUP_PREFIX/$task_file" "$task_work/$task_file" >/dev/null
done
(cd "$task_work" && sha256sum --check SHA256SUMS)
# Random synthetic credential file never printed; container has no network or ports.
head -c 32 /dev/urandom | base64 > "$task_work/password"
docker run -d --name "$task_container" --network none --tmpfs /var/lib/postgresql/data \
  --mount "type=bind,src=$task_work/password,dst=/run/fixture-password,readonly" \
  -e POSTGRES_USER=fixture -e POSTGRES_DB=fixture -e POSTGRES_PASSWORD_FILE=/run/fixture-password "$POSTGRES_IMAGE" >/dev/null
task_ready=false
for task_attempt in $(seq 1 60); do
  if docker exec "$task_container" pg_isready -U fixture -d fixture >/dev/null 2>&1; then task_ready=true; break; fi
  sleep 2
done
test "$task_ready" = true
docker exec -i "$task_container" pg_restore -U fixture -d fixture --exit-on-error < "$task_work/fixture.dump"
task_count=$(docker exec "$task_container" psql -U fixture -d fixture -Atc 'SELECT count(*) FROM synthetic_records')
test "$task_count" = 3
test "$(cat "$task_work/durable.txt")" = chico-dev-synthetic-file-v1
printf 'synthetic restore verified rows=%s duration_seconds=%s\n' "$task_count" "$(( $(date +%s)-task_started ))"
