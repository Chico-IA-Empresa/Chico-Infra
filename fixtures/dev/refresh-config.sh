#!/bin/bash
set -euo pipefail
umask 077
test "${CHICO_SYNTHETIC_ONLY:-}" = true
test "$(id -u)" = 0
command -v asm-exec >/dev/null
# Runtime wrapper resolves this fixed synthetic Dev reference. Never print output.
# Host helper owns 0600 tmpfs file; only the intended synthetic consumer gets a bind.
asm-exec -- python3 /opt/chico-dev-fixture/config-consumer.py \
  '{{resolve:secretsmanager:/chico/dev/api/SYNTHETIC_TOKEN}}'
