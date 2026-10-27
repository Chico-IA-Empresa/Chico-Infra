# Amazon Linux 2023 ARM64. No application or business process is started.
set -euo pipefail
umask 027
exec > >(tee -a /var/log/chico-bootstrap.log) 2>&1
trap 'echo "chico-bootstrap failed at line $LINENO"' ERR
test "$(uname -m)" = aarch64
source /etc/os-release
test "$ID" = amzn && test "$VERSION_ID" = 2023
[[ "$COMPOSE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$COMPOSE_SHA256" =~ ^[a-f0-9]{64}$ ]]

# EIP is associated after RunInstances. Bound the wait; cloud-init failure is visible.
retry dnf install -y docker curl jq python3 awscli2 amazon-ssm-agent
systemctl enable --now amazon-ssm-agent docker
install -d -m 0755 /usr/local/lib/docker/cli-plugins
task_download=$(mktemp)
trap 'rm -f "$task_download"' EXIT
retry curl --fail --location --connect-timeout 10 --max-time 120 \
  "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-aarch64" -o "$task_download"
printf '%s  %s\n' "$COMPOSE_SHA256" "$task_download" | sha256sum --check --status
install -m 0755 "$task_download" /usr/local/lib/docker/cli-plugins/docker-compose

# Retained root gp3: directories only. Never mkfs, repartition, chown recursively,
# or delete existing data. PostgreSQL UID/GID is verified against the pinned image
# before the later application deployment sets ownership of an EMPTY path.
prepare_data_directories /srv/chico
install -d -m 0700 /etc/chico /run/chico
cat > /etc/tmpfiles.d/chico.conf <<'EOF'
d /run/chico 0700 root root -
EOF
docker --version
docker compose version
systemctl is-active amazon-ssm-agent docker
echo 'chico-bootstrap ready; application remains stopped'
