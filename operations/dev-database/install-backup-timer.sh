#!/bin/bash
# Run only on the reviewed Dev host after the first real backup and recovery proof.
set -euo pipefail
umask 077
test "$(id -u)" = 0
test "${CHICO_DEV_DATABASE_APPROVED:-}" = true
test -f /opt/chico-dev-database/backup.py
test -f /etc/chico/database-backup.json
test -f /var/lib/chico/database-last-backup.json
test -f /var/lib/chico/database-last-restore-proof.json
python3 - <<'PY'
import json
from pathlib import Path
state = Path('/var/lib/chico')
backup = json.loads((state/'database-last-backup.json').read_text())
proof = json.loads((state/'database-last-restore-proof.json').read_text())
assert proof['verified'] is True and backup['bucket'] == proof['bucket']
assert backup['commit']['key'] == proof['prefix'] + '/commit.json'
assert backup['commit'] == proof['commit']
assert proof['businessWritersStarted'] is False
PY
cat > /etc/systemd/system/chico-dev-database-backup.service <<'EOF'
[Unit]
Description=Backup of restored Chico Dev PostgreSQL (separate from fixtures)
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/chico-dev-database/backup.py backup --config /etc/chico/database-backup.json
UMask=0077
TimeoutStartSec=3h
Nice=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/srv/chico/backups/database /var/lib/chico
StandardOutput=append:/var/log/chico-backup.log
StandardError=append:/var/log/chico-backup.log
EOF
cat > /etc/systemd/system/chico-dev-database-backup.timer <<'EOF'
[Unit]
Description=Nightly restored Dev database backup at 00:15 Brasilia
[Timer]
OnCalendar=*-*-* 03:15:00 UTC
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
EOF
install -d -m 0700 /srv/chico/backups/database
systemctl daemon-reload
systemctl enable --now chico-dev-database-backup.timer
