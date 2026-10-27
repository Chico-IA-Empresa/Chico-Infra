#!/bin/bash
# Build identity only. Host pull/run is a separate positive test under runtime role.
set -euo pipefail
umask 077
test "${CHICO_SYNTHETIC_ONLY:-}" = true
[[ "${AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]]
[[ "${FIXTURE_BASE:-}" =~ ^[a-zA-Z0-9./_-]+@sha256:[a-f0-9]{64}$ ]]
[[ "${FIXTURE_TAG:-}" =~ ^fixture-[a-f0-9]{40}$ ]]
test "$(aws sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT_ID"
test "$(aws ecr get-registry-scanning-configuration --region sa-east-1 --query scanningConfiguration.scanType --output text)" = BASIC
task_registry="$AWS_ACCOUNT_ID.dkr.ecr.sa-east-1.amazonaws.com"
task_docker_config=$(mktemp -d)
export DOCKER_CONFIG="$task_docker_config"
trap 'rm -rf -- "$task_docker_config"' EXIT
aws ecr get-login-password --region sa-east-1 | docker login --username AWS --password-stdin "$task_registry" >/dev/null 2>&1
task_here=$(cd -- "$(dirname -- "$0")" && pwd)
for task_repo in chico-api chico-workers chico-frontend; do
  test "$(aws ecr describe-repositories --region sa-east-1 --repository-names "$task_repo" --query 'repositories[0].imageTagMutability' --output text)" = IMMUTABLE
  task_image="$task_registry/$task_repo:$FIXTURE_TAG"
  docker buildx build --platform linux/arm64 --provenance=false --build-arg "FIXTURE_BASE=$FIXTURE_BASE" -t "$task_image" --push "$task_here" > "$task_docker_config/build.log" 2>&1
  task_digest=$(aws ecr describe-images --region sa-east-1 --repository-name "$task_repo" --image-ids "imageTag=$FIXTURE_TAG" --query 'imageDetails[0].imageDigest' --output text)
  [[ "$task_digest" =~ ^sha256:[a-f0-9]{64}$ ]]
  task_accepted=false
  for task_attempt in $(seq 1 24); do
    if aws ecr describe-image-scan-findings --region sa-east-1 --repository-name "$task_repo" --image-id "imageDigest=$task_digest" > "$task_docker_config/scan.json" 2>/dev/null; then
      task_status=$(jq -r .imageScanStatus.status "$task_docker_config/scan.json")
      if test "$task_status" = COMPLETE; then
        jq -e '.imageScanFindings.findingSeverityCounts | type == "object"' "$task_docker_config/scan.json" >/dev/null
        test "$(jq '.imageScanFindings.findingSeverityCounts.CRITICAL // 0' "$task_docker_config/scan.json")" = 0
        task_accepted=true
        break
      fi
      test "$task_status" = IN_PROGRESS || test "$task_status" = PENDING || exit 1
    fi
    sleep 10
  done
  test "$task_accepted" = true
  printf 'synthetic scan accepted repo=%s digest=%s\n' "$task_repo" "$task_digest"
done
