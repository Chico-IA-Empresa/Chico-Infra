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
  if [[ "$task_last" =~ ^[0-9]+$ ]] && test "$task_last" -le "$task_now"; then
    task_age=$(( (task_now-task_last)/3600 ))
  fi
fi
task_data=$(mktemp)
trap 'rm -f "$task_data"' EXIT
task_fixture_age=$task_age
task_database_enabled=0
task_database_age=99999
if test -f /etc/chico/database-backup.json; then
  task_database_enabled=1
  if task_candidate=$(python3 /opt/chico-dev-database/backup.py freshness 2>/dev/null) && [[ "$task_candidate" =~ ^[0-9]+$ ]]; then
    task_database_age=$task_candidate
  fi
  if test "$task_database_age" -gt "$task_age"; then task_age=$task_database_age; fi
fi
jq -n --arg id "$task_instance" --argjson memory "$task_memory" --argjson disk "$task_disk" --argjson age "$task_age" \
  --argjson fixture_age "$task_fixture_age" --argjson database_enabled "$task_database_enabled" --argjson database_age "$task_database_age" \
  '([{MetricName:"MemoryUsedPercent",Value:$memory,Unit:"Percent"},{MetricName:"DiskUsedPercent",Value:$disk,Unit:"Percent"},{MetricName:"BackupAgeHours",Value:$age,Unit:"Count"},{MetricName:"FixtureBackupAgeHours",Value:$fixture_age,Unit:"Count"},{MetricName:"DatabaseBackupEnabled",Value:$database_enabled,Unit:"Count"}] + (if $database_enabled == 1 then [{MetricName:"DatabaseBackupAgeHours",Value:$database_age,Unit:"Count"}] else [] end)) | map(. + {Dimensions:[{Name:"InstanceId",Value:$id}]})' > "$task_data"
aws cloudwatch put-metric-data --region sa-east-1 --namespace Chico/Dev --metric-data "file://$task_data"
