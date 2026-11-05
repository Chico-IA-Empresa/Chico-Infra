#!/usr/bin/env bash
# Disposable native producer. No AWS credentials, ECR or existing data inputs.
set -Eeuo pipefail
umask 077
test "$(uname -m)" = x86_64
test -n "${RUNNER_TEMP:?}"
for task_credential in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_WEB_IDENTITY_TOKEN_FILE AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI; do
  test -z "${!task_credential:-}"
done
task_public="$RUNNER_TEMP/restore-toolchain-delivery-public"
task_work="$RUNNER_TEMP/restore-toolchain-delivery-work"
test ! -e "$task_public" && test ! -e "$task_work"
mkdir -m 0700 "$task_public" "$task_work"
task_stage=source-inputs
trap 'task_exit=$?; trap - ERR; printf "{\"stage\":\"%s\",\"exitCode\":%d,\"awsUsed\":false}\n" "$task_stage" "$task_exit" > "$task_public/failure-summary.json"; exit "$task_exit"' ERR
mkdir -m 0700 "$task_work/trivy" "$task_work/docker"
unset DOCKER_HOST DOCKER_CONTEXT
export DOCKER_CONFIG="$task_work/docker"
docker info >/dev/null
docker buildx version > "$task_public/buildx-version.txt"
docker version > "$task_public/docker-version.txt"
node --input-type=module -e 'import {guardedInputs} from "./scripts/restore-toolchain-delivery.mjs";guardedInputs(process.cwd());'
install -m 0644 /etc/ssl/certs/ca-certificates.crt operations/restore-toolchain/runner-ca.crt
sha256sum operations/restore-toolchain/runner-ca.crt > "$task_public/runner-ca.sha256"
task_stage=docker-build
docker buildx build --load --provenance=false --sbom=false --platform linux/amd64 --pull --no-cache \
  --tag chico-restore-toolchain:delivery operations/restore-toolchain > "$task_work/build-private.log" 2>&1
docker image inspect chico-restore-toolchain:delivery > "$task_public/image-inspect.json"
docker image inspect chico-restore-toolchain:delivery --format '{{.Id}}' > "$task_public/image-id.txt"
task_image=$(cat "$task_public/image-id.txt")
test "$(docker image inspect "$task_image" --format '{{.Architecture}}')" = amd64
test "$(docker image inspect "$task_image" --format '{{.Os}}')" = linux
task_stage=native-integration
sudo "$(command -v python)" tests/restore-toolchain-integration.py \
  --image "$task_image" --evidence "$task_work/synthetic"
for task_name in summary.json provenance.txt; do
  sudo install -m 0644 -o "$(id -u)" -g "$(id -g)" "$task_work/synthetic/$task_name" "$task_public/$task_name"
done
task_stage=scanner-install
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
  https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-64bit.tar.gz \
  -o "$task_work/trivy.tar.gz"
echo "c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0  $task_work/trivy.tar.gz" | sha256sum -c -
tar -xzf "$task_work/trivy.tar.gz" -C "$task_work/trivy" trivy
: > "$task_work/empty-ignore"
task_stage=complete-scan
"$task_work/trivy/trivy" image --image-src docker --platform linux/amd64 --scanners vuln \
  --db-repository ghcr.io/aquasecurity/trivy-db:2 \
  --list-all-pkgs --ignore-unfixed=false --ignorefile "$task_work/empty-ignore" --format json \
  --output "$task_public/scan.json" "$task_image"
"$task_work/trivy/trivy" version --format json > "$task_public/scanner.json"
task_stage=exact-image-evidence
node --input-type=module - "$task_public" <<'JS'
import fs from 'node:fs';import path from 'node:path';
import {scanFacts,maxImageBytes} from './scripts/restore-toolchain-delivery.mjs';
const dir=process.argv[2],read=n=>JSON.parse(fs.readFileSync(path.join(dir,n),'utf8'));
const facts=scanFacts(read('scan.json')),summary=read('summary.json'),image=read('image-inspect.json');
if(image.length!==1||image[0].Id!==facts.imageId||summary.imageId!==facts.imageId||image[0].Size>maxImageBytes||summary.syntheticSqlXmlRoundTrip!==true||summary.independentSyntheticWalValidated!==true||summary.realDatabaseRestored!==false)throw Error('Native exact-image proof incomplete');
fs.writeFileSync(path.join(dir,'package-review-facts.json'),JSON.stringify({...facts,imageBytes:image[0].Size,awsExecutionApproved:false,imagesPublished:false,hostPullApproved:false},null,2)+'\n',{flag:'wx',mode:0o600});
console.log('Fresh native synthetic build and complete final-image scan passed; no AWS operation executed');
JS
