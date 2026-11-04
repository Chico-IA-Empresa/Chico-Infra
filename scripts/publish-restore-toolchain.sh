#!/usr/bin/env bash
# Reviewed, first-attempt publication to one EXISTING repository; no deployment.
set -Eeuo pipefail
umask 077
test "${GITHUB_EVENT_NAME:?}" = workflow_dispatch
test "${GITHUB_REF:?}" = refs/heads/main
test "${GITHUB_RUN_ATTEMPT:?}" = 1
task_public="$RUNNER_TEMP/restore-toolchain-delivery-public"
task_work=$(mktemp -d "$RUNNER_TEMP/restore-toolchain-publish.XXXXXX")
task_stage=initial-gates
task_push_attempted=false
case "$task_work" in "$RUNNER_TEMP"/restore-toolchain-publish.*) ;; *) exit 1 ;; esac
cleanup() {
  task_exit=$?
  trap - EXIT
  if test "$task_exit" -ne 0 && test -d "$task_public"; then printf '{"stage":"%s","exitCode":%d,"pushAttempted":%s,"stagingPullApproved":false}\n' "$task_stage" "$task_exit" "$task_push_attempted" > "$task_public/publication-failure-summary.json" || true; fi
  case "$task_work" in "$RUNNER_TEMP"/restore-toolchain-publish.*) rm -rf -- "$task_work" ;; *) exit 1 ;; esac
  if test "$task_exit" -ne 0; then echo 'Publication stopped; reconcile consumed/partial artifacts and obtain a new reviewed release before another attempt.' >&2; fi
  exit "$task_exit"
}
trap cleanup EXIT
mkdir -m 0700 "$task_work/docker"
unset DOCKER_HOST DOCKER_CONTEXT AWS_PROFILE AWS_DEFAULT_PROFILE AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
unset AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_DATA_PATH
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy AWS_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
for task_key in ${!AWS_ENDPOINT_URL@}; do unset "$task_key"; done
export DOCKER_CONFIG="$task_work/docker" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export BOTO_CONFIG=/dev/null AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard
aws_read() {
  node scripts/restore-toolchain-delivery.mjs gate >/dev/null
  aws --region sa-east-1 --no-cli-pager --output json --cli-connect-timeout 10 --cli-read-timeout 10 "$@"
}
current_main() {
  test "$(gh api repos/Chico-IA-Empresa/Chico-Infra/git/ref/heads/main --jq .object.sha)" = "$GITHUB_SHA"
  node scripts/github-readiness.mjs apply >/dev/null
}
snapshot() {
  aws_read sts get-caller-identity > "$task_work/identity.json" 2> "$task_work/identity-error.log"
  aws_read ecr describe-repositories --registry-id 306915830875 --repository-names chico-workers > "$task_work/repository.json" 2> "$task_work/repository-error.log"
  aws_read ecr get-registry-scanning-configuration > "$task_work/scanning.json" 2> "$task_work/scanning-error.log"
  aws_read ecr describe-images --registry-id 306915830875 --repository-name chico-workers > "$task_work/images.json" 2> "$task_work/images-error.log"
  node scripts/restore-toolchain-delivery.mjs aws-context "$task_work/identity.json" "$task_work/repository.json" "$task_work/scanning.json" "$task_work/images.json"
}
current_main
node scripts/restore-toolchain-delivery.mjs publication-gate >/dev/null
node scripts/restore-toolchain-delivery.mjs evidence "$task_public"
task_stage=repository-context
snapshot
task_image=$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).imageId' "$task_public/prepublication-review.json")
task_tag="restore-$GITHUB_SHA-$GITHUB_RUN_ID"
task_registry=306915830875.dkr.ecr.sa-east-1.amazonaws.com
task_uri="$task_registry/chico-workers:$task_tag"
current_main
snapshot
node scripts/restore-toolchain-delivery.mjs publication-gate >/dev/null
task_stage=registry-login
aws_read ecr get-login-password 2> "$task_work/token-error-private.log" | docker login --username AWS --password-stdin "$task_registry" > "$task_work/login-private.log" 2>&1
docker tag "$task_image" "$task_uri"
current_main
node scripts/restore-toolchain-delivery.mjs publication-gate >/dev/null
task_stage=registry-push
task_push_attempted=true
timeout 600s docker push "$task_uri" > "$task_work/push-private.log" 2>&1
task_stage=published-manifest
aws_read ecr batch-get-image --registry-id 306915830875 --repository-name chico-workers --image-ids "imageTag=$task_tag" \
  --accepted-media-types application/vnd.docker.distribution.manifest.v2+json application/vnd.oci.image.manifest.v1+json > "$task_work/manifest.json" 2> "$task_work/manifest-error.log"
aws_read ecr describe-images --registry-id 306915830875 --repository-name chico-workers --image-ids "imageTag=$task_tag" > "$task_work/published.json" 2> "$task_work/published-error.log"
node scripts/restore-toolchain-delivery.mjs manifest "$task_public/prepublication-review.json" "$task_work/manifest.json" "$task_work/published.json" "$task_public/published-manifest.json"
task_digest=$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).manifestDigest' "$task_public/published-manifest.json")
task_deadline=$((SECONDS + 600))
task_stage=exact-digest-ecr-scan
while true; do
  node scripts/restore-toolchain-delivery.mjs gate >/dev/null
  if aws_read ecr describe-image-scan-findings --registry-id 306915830875 --repository-name chico-workers --image-id "imageDigest=$task_digest" > "$task_work/ecr-scan.json" 2> "$task_work/scan-error-private.log"; then
    task_status=$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).imageScanStatus?.status ?? "UNKNOWN"' "$task_work/ecr-scan.json")
    if test "$task_status" = COMPLETE; then break; fi
    case "$task_status" in IN_PROGRESS|PENDING) ;; *) echo 'ECR scan failed or unknown; no pull or deployment approved' >&2; exit 1 ;; esac
  else
    grep -Eq 'An error occurred \(ScanNotFoundException\) when calling the DescribeImageScanFindings operation' "$task_work/scan-error-private.log" || exit 1
  fi
  test "$SECONDS" -lt "$task_deadline"
  sleep 10
done
node scripts/restore-toolchain-delivery.mjs ecr-scan "$task_public/published-manifest.json" "$task_work/ecr-scan.json" "$task_public/delivery.json"
docker logout "$task_registry" > /dev/null 2>&1 || true
echo 'Bound image published and exact ECR scan recorded; staging/host pull and real restore remain unapproved.'
