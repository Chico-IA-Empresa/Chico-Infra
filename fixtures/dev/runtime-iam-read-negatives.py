#!/usr/bin/env python3
"""Prepared only; coordinator reviews source/hash/funding before any SSM dispatch."""
import json
import argparse
import datetime
import hashlib
import os
import pathlib
import re
import stat
import subprocess
import sys

# Same fixed resource metadata as the CI candidate; no object/secret bodies.
PROBES = json.loads(r'''[
{"id":"state-current-head","service":"s3api","operation":"head-object","input":{"Bucket":"chico-tfstate-306915830875-sa-east-1","Key":"dev/terraform.tfstate","ExpectedBucketOwner":"306915830875"},"region":"sa-east-1"},
{"id":"state-version-head","service":"s3api","operation":"head-object","input":{"Bucket":"chico-tfstate-306915830875-sa-east-1","Key":"dev/terraform.tfstate","VersionId":"QJ9Ge81k1PAdRbVIjRPCzFi_.wapbeBK","ExpectedBucketOwner":"306915830875"},"region":"sa-east-1"},
{"id":"review-version-head","service":"s3api","operation":"head-object","input":{"Bucket":"chico-infra-review-306915830875-sa-east-1","Key":"dev/3fef20f0b7e485fdd13da6e0b9adaa89a735b2b7/41657962157/review.tfplan","VersionId":"XfJZwBDuAMKse.wEAioiXxwAEOAc5xHY","ExpectedBucketOwner":"306915830875"},"region":"sa-east-1"},
{"id":"state-prefix-list","service":"s3api","operation":"list-objects-v2","input":{"Bucket":"chico-tfstate-306915830875-sa-east-1","Prefix":"dev/terraform.tfstate","MaxKeys":1,"ExpectedBucketOwner":"306915830875"},"region":"sa-east-1"},
{"id":"shared-log-metadata","service":"logs","operation":"describe-log-streams","input":{"logGroupName":"/chico/shared/audit","limit":1},"region":"sa-east-1"}
]''')

def probe_hash():
    return hashlib.sha256(json.dumps(PROBES, separators=(",", ":")).encode()).hexdigest()

def validate_review(raw, expected_hash, source_commit, script_hash, valid_until, approved, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if approved != "true" or not re.fullmatch(r"[a-f0-9]{64}", expected_hash or "") or hashlib.sha256(raw).hexdigest() != expected_hash:
        raise ValueError("review hash or approval invalid")
    if not re.fullmatch(r"[a-f0-9]{40}", source_commit or "") or not re.fullmatch(r"[a-f0-9]{64}", script_hash or ""):
        raise ValueError("source hash invalid")
    value = json.loads(raw)
    if not isinstance(value, dict) or set(value) != {"account_id", "provision_enabled", "credit_approval", "proof"}:
        raise ValueError("minimal review required")
    credit, proof = value["credit_approval"], value["proof"]
    if not isinstance(credit, dict) or set(credit) != {"account_id", "all_charges_covered", "shutdown_reserve_confirmed", "evidence_reference", "reviewed_on", "expires_on"}:
        raise ValueError("minimal funding required")
    if not isinstance(proof, dict) or set(proof) != {"scope", "operation", "role", "source_commit", "script_sha256", "probe_set_sha256", "inventory_reference", "inventory_checked_at_utc"}:
        raise ValueError("minimal proof required")
    def stamp(text):
        if not isinstance(text, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z", text):
            raise ValueError("UTC timestamp required")
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    def date(text):
        if not isinstance(text, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            raise ValueError("UTC date required")
        return datetime.datetime.combine(datetime.date.fromisoformat(text), datetime.time(), datetime.timezone.utc)
    if value["account_id"] != "306915830875" or value["provision_enabled"] is not True or credit["account_id"] != "306915830875" or credit["all_charges_covered"] is not True or credit["shutdown_reserve_confirmed"] is not True or not isinstance(credit["evidence_reference"], str) or not credit["evidence_reference"].strip():
        raise ValueError("funding invalid")
    if date(credit["reviewed_on"]) > now or date(credit["expires_on"]) <= now or stamp(valid_until) <= now:
        raise ValueError("funding expired")
    observed = stamp(proof["inventory_checked_at_utc"])
    if observed > now or now - observed >= datetime.timedelta(hours=8) or not isinstance(proof["inventory_reference"], str) or not proof["inventory_reference"].strip() or len(proof["inventory_reference"]) > 200:
        raise ValueError("fresh real inventory required")
    if proof["scope"] != "synthetic-dev-infra" or proof["operation"] != "iam-read-negatives" or proof["role"] != "runtime" or proof["source_commit"] != source_commit or proof["script_sha256"] != script_hash or proof["probe_set_sha256"] != probe_hash():
        raise ValueError("source script or probes differ")
    return True

def read_private_file(filename, suffix):
    if suffix not in ("json", "py") or not re.fullmatch(r"/run/chico/[A-Za-z0-9/_-]+\." + suffix, filename or ""):
        raise ValueError("private runtime review path required")
    path = pathlib.Path(filename)
    # Refuse symlinks in any component, not just the final file.
    for component in [path, *path.parents]:
        if component.is_symlink():
            raise ValueError("review path symlink refused")
    info = path.stat()
    size_limit = {"json": 8192, "py": 32768}[suffix]
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > size_limit:
        raise ValueError("private root0600 regular metadata required")
    mounts = []
    for line in pathlib.Path("/proc/self/mountinfo").read_text().splitlines():
        before, after = line.split(" - ", 1)
        mountpoint = before.split()[4]
        if filename == mountpoint or filename.startswith(mountpoint.rstrip("/") + "/"):
            mounts.append((len(mountpoint), after.split()[0]))
    if not mounts or max(mounts)[1] != "tmpfs":
        raise ValueError("tmpfs review required")
    return path.read_bytes()

def read_private_review(filename):
    return read_private_file(filename, "json")

def runtime_environment():
    # Standard instance-profile chain only; no caller/root/static/endpoint profile.
    env = {k: v for k, v in os.environ.items() if not k.startswith("AWS_")}
    env.update(AWS_CONFIG_FILE="/dev/null", AWS_SHARED_CREDENTIALS_FILE="/dev/null",
               AWS_DEFAULT_REGION="sa-east-1", AWS_PAGER="", AWS_MAX_ATTEMPTS="1",
               AWS_RETRY_MODE="standard", AWS_EC2_METADATA_V1_DISABLED="true",
               AWS_IGNORE_CONFIGURED_ENDPOINT_URLS="true")
    return env

def call(service, operation, parameters, region):
    return subprocess.run(["aws", service, operation, "--cli-input-json", json.dumps(parameters),
                           "--region", region, "--no-cli-pager", "--output", "json",
                           "--cli-connect-timeout", "5", "--cli-read-timeout", "10"],
                          env=runtime_environment(), stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)

def denied(response, probe):
    if response.returncode == 0:
        return False
    text = response.stderr.decode("utf-8", errors="replace")
    match = re.search(r"An error occurred \(([A-Za-z0-9]+)\) when calling", text)
    code = match.group(1) if match else None
    return code in ("AccessDenied", "AccessDeniedException") or (
        code == "403" and probe["service"] == "s3api" and probe["operation"] == "head-object"
        and re.search(r"An error occurred \(403\) when calling the HeadObject operation(?: \(reached max retries: 0\))?: Forbidden\s*$", text) is not None
    )

def run(aws=call, before_each=lambda: None):
    before_each()
    identity_response = aws("sts", "get-caller-identity", {}, "sa-east-1")
    if identity_response.returncode != 0:
        raise ValueError("identity unavailable")
    identity = json.loads(identity_response.stdout)
    if identity.get("Account") != "306915830875" or identity.get("Arn") != "arn:aws:sts::306915830875:assumed-role/chico-dev-runtime/i-03b97e256bbba039c":
        raise ValueError("wrong live role")
    results = []
    for probe in PROBES:
        before_each()
        if not denied(aws(probe["service"], probe["operation"], probe["input"], probe["region"]), probe):
            raise ValueError("unexpected allow or inconclusive result")
        results.append({"id": probe["id"], "result": "authorization-denied"})
    return {"role": "runtime", "probes": len(results), "results": results}

if __name__ == "__main__":
    try:
        class SilentParser(argparse.ArgumentParser):
            def error(self, message):
                raise ValueError("invalid runtime review arguments")
        parser = SilentParser(add_help=False, exit_on_error=False)
        parser.add_argument("--review", required=True)
        parser.add_argument("--review-sha256", required=True)
        parser.add_argument("--source-commit", required=True)
        parser.add_argument("--funding-valid-until", required=True)
        parser.add_argument("--approved", required=True)
        args = parser.parse_args()
        script_hash = hashlib.sha256(read_private_file(str(pathlib.Path(__file__).absolute()), "py")).hexdigest()
        def revalidate():
            return validate_review(read_private_review(args.review), args.review_sha256, args.source_commit, script_hash, args.funding_valid_until, args.approved)
        print(json.dumps(run(before_each=revalidate), separators=(",", ":")))
    except Exception:
        # Never print captured response, traceback, credential chain or errors.
        print("Runtime read-only IAM proof blocked or failed; no raw response emitted", file=sys.stderr)
        sys.exit(1)
