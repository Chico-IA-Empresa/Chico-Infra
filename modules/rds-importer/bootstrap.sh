# No source copy, SQL import, secret resolution or container startup occurs here.
set -euo pipefail
umask 077
exec >>/var/log/chico-import-bootstrap.log 2>&1
trap 'echo "importer bootstrap failed at line $LINENO"' ERR
test "$(uname -m)" = x86_64
source /etc/os-release
test "$ID" = amzn && test "$VERSION_ID" = 2023

# Stop, never terminate or delete data. Configure this before package access.
task_expiry=$(date -u -d "$CHICO_IMPORT_EXPIRES_UTC" '+%Y-%m-%d %H:%M:%S UTC')
cat > /etc/systemd/system/chico-import-expiry.service <<'EOF'
[Unit]
Description=Stop temporary RDS importer at reviewed deadline
[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -P now
EOF
cat > /etc/systemd/system/chico-import-expiry.timer <<EOF
[Unit]
Description=Absolute RDS importer deadline
[Timer]
OnCalendar=$task_expiry
Persistent=true
AccuracySec=1min
Unit=chico-import-expiry.service
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now chico-import-expiry.timer
if test "$(date -u +%s)" -ge "$(date -u -d "$CHICO_IMPORT_EXPIRES_UTC" +%s)"; then
  shutdown -P now
  exit 1
fi
dnf install -y docker curl-minimal jq python3 awscli-2 amazon-ssm-agent openssl
[[ "$(/usr/bin/aws --version 2>&1)" == aws-cli/2.* ]]
systemctl enable --now docker amazon-ssm-agent
install -d -m 0700 /srv/chico-import /run/chico-import
cat > /etc/tmpfiles.d/chico-import.conf <<'EOF'
d /run/chico-import 0700 root root -
EOF
echo 'Importer OS prepared; image, dump, credentials, TLS and SQL remain separately gated'
