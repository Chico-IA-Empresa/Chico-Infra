#!/bin/bash
# Disposable native ARM64 maintenance build. No AWS, ECR publication or host.
set -euo pipefail
umask 077
test "$(uname -m)" = aarch64
docker info >/dev/null
task_here=$(cd -- "$(dirname -- "$0")" && pwd)
task_root=$(cd -- "$task_here/../../.." && pwd)
task_work="$RUNNER_TEMP/fixture-image-maintenance-work"
task_evidence="$RUNNER_TEMP/fixture-image-maintenance-evidence"
mkdir -m 0700 "$task_work" "$task_evidence"
mkdir -m 0700 "$task_work/go" "$task_work/gosu" "$task_work/context" "$task_work/trivy" "$task_work/docker"
export DOCKER_CONFIG="$task_work/docker" GOENV=off GOTOOLCHAIN=local GOWORK=off
export GOPATH="$task_work/gopath" GOCACHE="$task_work/gocache" CGO_ENABLED=0 GOOS=linux GOARCH=arm64
export GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 https://go.dev/dl/go1.27.3.linux-arm64.tar.gz -o "$task_work/go.tar.gz"
echo "a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49  $task_work/go.tar.gz" | sha256sum -c -
tar -xzf "$task_work/go.tar.gz" --strip-components=1 -C "$task_work/go"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 https://codeload.github.com/tianon/gosu/tar.gz/29b939aa5bd4dc588af765b8248f6e39150d2565 -o "$task_work/gosu.tar.gz"
echo "2b70da8a5480fafedc16bb1fc91b572f064d03df736cbd91a616af2f1b66ab51  $task_work/gosu.tar.gz" | sha256sum -c -
tar -xzf "$task_work/gosu.tar.gz" --strip-components=1 -C "$task_work/gosu"
(cd "$task_work/gosu" && "$task_work/go/bin/go" build -mod=readonly -trimpath -ldflags '-s -w' -o "$task_work/context/gosu-arm64" .)
"$task_work/go/bin/go" version -m "$task_work/context/gosu-arm64" > "$task_evidence/gosu-build-info.txt"
sha256sum "$task_work/context/gosu-arm64" > "$task_evidence/gosu-binary.sha256"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-ARM64.tar.gz -o "$task_work/trivy.tar.gz"
echo "e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f  $task_work/trivy.tar.gz" | sha256sum -c -
tar -xzf "$task_work/trivy.tar.gz" -C "$task_work/trivy" trivy
"$task_work/trivy/trivy" --version > "$task_evidence/scanner-version.txt"
: > "$task_work/empty-ignore"
task_all_scans_passed=true
for task_name in postgres caddy; do
  task_image="chico-fixture-maintenance-$task_name:$GITHUB_SHA"
  docker build --platform linux/arm64 --pull --no-cache -f "$task_here/$task_name.Dockerfile" -t "$task_image" "$task_work/context" > "$task_work/$task_name-build-private.log" 2>&1
  docker image inspect "$task_image" > "$task_evidence/$task_name-image.json"
  jq -e 'length==1 and .[0].Architecture=="arm64" and .[0].Os=="linux" and ((.[0].Config.OnBuild//[])|length==0)' "$task_evidence/$task_name-image.json" >/dev/null
  "$task_work/trivy/trivy" image --image-src docker --platform linux/arm64 --scanners vuln --list-all-pkgs --ignorefile "$task_work/empty-ignore" --ignore-unfixed=false --format json --output "$task_evidence/$task_name-scan.json" "$task_image"
  if test "$task_name" = postgres; then
    if ! python3 "$task_root/scripts/verify-fixture-maintenance-scan.py" "$task_evidence/$task_name-scan.json" --require-gosu > "$task_evidence/$task_name-scan-summary.json"; then
      task_all_scans_passed=false
      continue
    fi
    docker run --rm --network none --read-only --cap-drop ALL --entrypoint gosu "$task_image" --version > "$task_evidence/gosu-version.txt"
    test "$(cat "$task_evidence/gosu-version.txt")" = '1.20 (go1.27.3 on linux/arm64; gc)'
    docker run --rm --network none --read-only --cap-drop ALL --user postgres --entrypoint postgres "$task_image" --version > "$task_evidence/postgres-version.txt"
    docker run --rm --network none --entrypoint gosu "$task_image" nobody true
  else
    if ! python3 "$task_root/scripts/verify-fixture-maintenance-scan.py" "$task_evidence/$task_name-scan.json" > "$task_evidence/$task_name-scan-summary.json"; then
      task_all_scans_passed=false
      continue
    fi
    docker run --rm --network none --read-only --cap-drop ALL --entrypoint caddy "$task_image" version > "$task_evidence/caddy-version.txt"
  fi
done
test "$task_all_scans_passed" = true
printf '{"nativeArm64":true,"scansPassed":true,"imagesPublished":false,"hostPullApproved":false,"fixtureInstalled":false}\n' > "$task_evidence/summary.json"
