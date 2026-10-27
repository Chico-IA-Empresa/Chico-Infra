#!/bin/bash
set -euo pipefail
test "${CHICO_SYNTHETIC_ONLY:-}" = true
test "$(id -u)" = 0
test -f /opt/chico-dev-fixture/compose.yaml
test -f /etc/chico/fixture.env
# fixture.env: nonsecret pinned images, hostname and Dev bucket only.
cat > /etc/systemd/system/chico-dev-fixture-backup.service <<'EOF'
[Unit]
Description=Nightly synthetic fixture backup (no application database)
After=docker.service network-online.target
[Service]
Type=oneshot
EnvironmentFile=/etc/chico/fixture.env
Environment=CHICO_SYNTHETIC_ONLY=true
ExecStart=/bin/bash /opt/chico-dev-fixture/backup.sh
StandardOutput=append:/var/log/chico-backup.log
StandardError=append:/var/log/chico-backup.log
UMask=0077
EOF
cat > /etc/systemd/system/chico-dev-fixture-backup.timer <<'EOF'
[Unit]
Description=Nightly synthetic Dev backup
[Timer]
OnCalendar=*-*-* 03:00:00 UTC
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now chico-dev-fixture-backup.timer
