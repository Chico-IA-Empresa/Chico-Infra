# Sourced by chico-dev-logs after task_instance is obtained via IMDSv2.
send_proxy_events() (
  set -euo pipefail
  umask 077
  task_proxy_file=/srv/chico/tls/access.log
  test -f "$task_proxy_file" || exit 0
  task_proxy_work=$(mktemp -d)
  trap 'rm -rf -- "$task_proxy_work"' EXIT
  python3 /usr/local/lib/chico/proxy-events.py "$task_proxy_file" /var/lib/chico/proxy.cursor.json > "$task_proxy_work/batch.json"
  test "$(jq '.events | length' "$task_proxy_work/batch.json")" -gt 0 || exit 0
  jq '.events' "$task_proxy_work/batch.json" > "$task_proxy_work/events.json"
  task_exists=$(aws logs describe-log-streams --region sa-east-1 --log-group-name /chico/dev/proxy --log-stream-name-prefix "$task_instance" --query 'logStreams[].logStreamName' --output text)
  if ! printf '%s\n' "$task_exists" | tr '\t' '\n' | grep -qx "$task_instance"; then
    aws logs create-log-stream --region sa-east-1 --log-group-name /chico/dev/proxy --log-stream-name "$task_instance"
  fi
  aws logs put-log-events --region sa-east-1 --log-group-name /chico/dev/proxy --log-stream-name "$task_instance" --log-events "file://$task_proxy_work/events.json" > "$task_proxy_work/result.json"
  jq -e 'has("rejectedLogEventsInfo") | not' "$task_proxy_work/result.json" >/dev/null
  # Commit cursor only after successful delivery of the sanitized events.
  jq '.cursor' "$task_proxy_work/batch.json" > /var/lib/chico/proxy.cursor.json.next
  mv -f /var/lib/chico/proxy.cursor.json.next /var/lib/chico/proxy.cursor.json
)
send_proxy_events
