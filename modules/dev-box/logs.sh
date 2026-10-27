#!/bin/bash
# Forward only operator-owned synthetic/bootstrap logs; never SSM command payloads.
set -euo pipefail
umask 077
task_token=$(curl --fail --silent --max-time 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
task_instance=$(curl --fail --silent --max-time 5 -H "X-aws-ec2-metadata-token: $task_token" http://169.254.169.254/latest/meta-data/instance-id)
for task_kind in bootstrap backup; do
  task_file="/var/log/chico-$task_kind.log"
  test -f "$task_file" || continue
  task_cursor="/var/lib/chico/$task_kind.offset"
  task_previous=0
  test ! -f "$task_cursor" || task_previous=$(cat "$task_cursor")
  task_size=$(stat -c %s "$task_file")
  if test "$task_size" -lt "$task_previous"; then task_previous=0; fi
  test "$task_size" -gt "$task_previous" || continue
  # Bound batch to 64 KiB; advance cursor only after successful delivery.
  task_bytes=$((task_size-task_previous))
  test "$task_bytes" -le 65536 || task_bytes=65536
  task_batch=$(mktemp)
  task_content=$(dd if="$task_file" bs=1 skip="$task_previous" count="$task_bytes" status=none)
  jq -n --arg message "$task_content" --argjson time "$(date +%s)000" '[{timestamp:$time,message:$message}]' > "$task_batch"
  # Describe then create: a failed create is not swallowed as successful delivery.
  task_exists=$(aws logs describe-log-streams --region sa-east-1 --log-group-name "/chico/dev/$task_kind" --log-stream-name-prefix "$task_instance" --query 'logStreams[].logStreamName' --output text)
  if ! printf '%s\n' "$task_exists" | tr '\t' '\n' | grep -qx "$task_instance"; then
    aws logs create-log-stream --region sa-east-1 --log-group-name "/chico/dev/$task_kind" --log-stream-name "$task_instance"
  fi
  if aws logs put-log-events --region sa-east-1 --log-group-name "/chico/dev/$task_kind" --log-stream-name "$task_instance" --log-events "file://$task_batch" >/dev/null; then
    printf '%s\n' "$((task_previous+task_bytes))" > "$task_cursor"
  else
    rm -f "$task_batch"
    exit 1
  fi
  rm -f "$task_batch"
done
source /usr/local/lib/chico/proxy-logs.sh
