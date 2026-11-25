#!/bin/bash
set -euo pipefail
umask 077
test "${CHICO_SYNTHETIC_ONLY:-}" = true
test "$(id -u)" = 0
test -x /usr/local/bin/asm-exec
test "$#" = 1
[[ "$1" =~ ^[a-f0-9]{32}$ ]]
export AWS_REGION=sa-east-1
# The supplied asm-exec main resolves argv only, despite its env documentation.
# The adapter pins/imports its resolver in-process: no plaintext argv, Docker env,
# stdout, or rewrite of an earlier launch's mounted file.
exec python3 /opt/chico-dev-fixture/config-consumer.py deliver --launch-id "$1"
