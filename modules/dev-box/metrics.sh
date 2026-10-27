#!/bin/bash
set -euo pipefail
umask 077
task_instance=$(curl --fail --silent --max-time 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
task_instance=$(curl --fail --silent --max-time 5 -H "X-aws-ec2-metadata-token: $task_instance" http://169.254.169.254/latest/meta-data/instance-id)
task_memory=$(awk '/MemTotal:/{total=$2} /MemAvailable:/{available=$2} END{printf "%.2f", (total-available)*100/total}' /proc/meminfo)
task_disk=$(df -P /srv/chico | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
task_now=$(date +%s)
# Missing successful backup is deliberately outside the alert threshold.
task_age=99999
if test -f /var/lib/chico/last-backup-success; then
  task_last=$(cat /var/lib/chico/last-backup-success)
  [[ "$task_last" =~ ^[0-9]+$ ]]
  task_age=$(( (task_now-task_last)/3600 ))
fi
task_data=$(mktemp)
trap 'rm -f "$task_data"' EXIT
jq -n --arg id "$task_instance" --argjson memory "$task_memory" --argjson disk "$task_disk" --argjson age "$task_age" \
  '[{MetricName:"MemoryUsedPercent",Value:$memory,Unit:"Percent"},{MetricName:"DiskUsedPercent",Value:$disk,Unit:"Percent"},{MetricName:"BackupAgeHours",Value:$age,Unit:"Count"}] | map(. + {Dimensions:[{Name:"InstanceId",Value:$id}]})' > "$task_data"
aws cloudwatch put-metric-data --region sa-east-1 --namespace Chico/Dev --metric-data "file://$task_data"
