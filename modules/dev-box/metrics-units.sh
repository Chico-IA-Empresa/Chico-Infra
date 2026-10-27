cat > /etc/systemd/system/chico-dev-metrics.service <<'EOF'
[Unit]
Description=Chico Dev memory, disk and backup freshness
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/chico-dev-metrics
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/chico
EOF
cat > /etc/systemd/system/chico-dev-metrics.timer <<'EOF'
[Unit]
Description=Chico Dev five minute telemetry
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
install -d -m 0700 /var/lib/chico
systemctl daemon-reload
systemctl enable --now chico-dev-metrics.timer
cat > /etc/systemd/system/chico-dev-logs.service <<'EOF'
[Unit]
Description=Chico Dev sanitized operational logs
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/chico-dev-logs
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/chico
EOF
cat > /etc/systemd/system/chico-dev-logs.timer <<'EOF'
[Unit]
Description=Chico Dev independent five minute log delivery
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now chico-dev-logs.timer
