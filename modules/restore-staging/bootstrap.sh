# No database, source transfer, credentials or business process is started here.
set -euo pipefail
umask 077
exec >>/var/log/chico-restore-bootstrap.log 2>&1
trap 'echo "restore staging bootstrap failed at line $LINENO"' ERR
test "$(uname -m)" = x86_64
source /etc/os-release
test "$ID" = amzn && test "$VERSION_ID" = 2023

# Persistent absolute timer survives reboot. It stops, never terminates, the
# host. IAM independently refuses S3 after expiry; storage still costs money.
task_expiry=$(date -u -d "$CHICO_STAGE_EXPIRES_UTC" '+%Y-%m-%d %H:%M:%S UTC')
cat > /etc/systemd/system/chico-restore-expiry.service <<'EOF'
[Unit]
Description=Stop temporary restore compute at the reviewed deadline
[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -P now
EOF
cat > /etc/systemd/system/chico-restore-expiry.timer <<EOF
[Unit]
Description=Absolute temporary restore deadline
[Timer]
OnCalendar=$task_expiry
Persistent=true
AccuracySec=1min
Unit=chico-restore-expiry.service
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now chico-restore-expiry.timer
if test "$(date -u +%s)" -ge "$(date -u -d "$CHICO_STAGE_EXPIRES_UTC" +%s)"; then
  shutdown -P now
  exit 1
fi

task_try=0
until dnf install -y docker curl jq python3 awscli2 amazon-ssm-agent zstd openssl; do
  task_try=$((task_try + 1))
  test "$task_try" -lt 10
  sleep 15
done
systemctl enable --now docker amazon-ssm-agent
if test -d /srv/chico-restore && test -n "$(find /srv/chico-restore -mindepth 1 -print -quit)"; then
  echo 'nonempty staging directory requires explicit review'
  exit 1
fi
install -d -m 0700 /srv/chico-restore /run/chico-restore
cat > /etc/tmpfiles.d/chico-restore.conf <<'EOF'
d /run/chico-restore 0700 root root -
EOF
echo 'restore staging OS ready; source transfer and PostgreSQL remain separate reviewed steps'
