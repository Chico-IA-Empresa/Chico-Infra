#!/usr/bin/env python3
"""Linux/Docker synthetic-only integration. No credentials, AWS, or production mounts.

Build first; pass the local immutable image id. Errors never echo process output.
Evidence consists solely of this newly created encrypted synthetic fixture.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "operations/restore-toolchain"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("isolated_run")
report = load("verify_report")


def execute(command, output=None, must_succeed=True):
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=False, timeout=300)
    if output:
        output.write_bytes(result.stdout)
        output.with_suffix(output.suffix + ".stderr").write_bytes(result.stderr)
    if must_succeed and result.returncode:
        raise RuntimeError("Synthetic toolchain command failed; inspect synthetic runner evidence")
    return result


def private_directory(path, uid):
    path.mkdir(mode=0o700)
    os.chown(path, uid, uid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() != 0:
        raise ValueError("Linux runner with permission to allocate fixture-owned empty directories required")
    evidence = args.evidence.absolute()
    # Never accept existing inputs, inherited data, or arbitrary fixture repositories.
    if evidence.exists() or evidence.resolve() != evidence or not evidence.parent.is_dir():
        raise ValueError("Fresh canonical evidence directory required")
    uid = 999  # Pinned Debian postgres image contract, verified below before creating PGDATA.
    private_directory(evidence, uid)
    mounts = {"/scripts": SCRIPTS}

    def run(arguments, *, extra=None, entrypoint="/bin/bash", filename=None, check=True):
        return execute(runner.isolated_command(args.image, uid, {**mounts, **(extra or {})}, entrypoint, arguments),
                       evidence / filename if filename else None, check)

    identity = run(["-u"], entrypoint="/usr/bin/id")
    if identity.stdout.strip() != b"999":
        raise ValueError("Pinned image UID changed")
    provenance = run(["-ceu", "test \"$(pgbackrest version)\" = 'pgBackRest 2.57.0'; "
                      "postgres --version; pgbackrest version; "
                      "cat /opt/chico-toolchain/binaries.sha256; "
                      "cat /opt/chico-toolchain/packages.tsv; "
                      "cat /opt/chico-toolchain/build/compiler.txt; "
                      "cat /opt/chico-toolchain/build/source.sha256; "
                      "cat /opt/chico-toolchain/build/packages.tsv; "
                      "cat /opt/chico-toolchain/build/meson.txt"], filename="provenance.txt")
    if b"16.13" not in provenance.stdout:
        raise ValueError("Unexpected PostgreSQL version")

    work = evidence / "fixture"
    private_directory(work, uid)
    run(["/scripts/fixture_prepare.sh"], extra={"/work": work}, filename="prepare.log")
    labels = json.loads((work / "labels.json").read_text())
    if len(labels) != 2 or any(not report.LABEL.fullmatch(label) for label in labels):
        raise ValueError("Invalid generated full/diff chain")
    config = evidence / "config"
    private_directory(config, uid)
    cipher = (work / "cipher-fixture-only").read_text()
    (config / "pgbackrest.conf").write_text("[global]\nrepo1-path=/repo\nrepo1-cipher-type=aes-256-cbc\n"
        "repo1-cipher-pass=" + cipher + "\nlog-level-console=off\nlog-level-file=off\n"
        "lock-path=/tmp\nspool-path=/tmp\nprocess-max=2\n[fixture]\npg1-path=/pgdata\npg1-socket-path=/tmp/socket\n")
    os.chmod(config / "pgbackrest.conf", 0o600)
    os.chown(config / "pgbackrest.conf", uid, uid)
    base = ["--config=/config/pgbackrest.conf", "--stanza=fixture"]
    repo = work / "repo"
    verification = []
    for number, label in enumerate(labels):
        result = run(base + ["--set=" + label, "--output=text", "--verbose", "verify"],
                     extra={"/repo": repo, "/config": config}, entrypoint="/usr/local/bin/pgbackrest",
                     filename=f"verify-{number}.txt")
        verification.append(report.parse_report(result.stdout.decode(), stanza="fixture", labels=[label]))

    # Copy only our fresh synthetic repo. Corrupt an existing encrypted backup payload.
    corrupt = evidence / "corrupt-repo"
    shutil.copytree(repo, corrupt)
    for directory, dirs, files in os.walk(corrupt):
        os.chown(directory, uid, uid)
        for name in files:
            os.chown(Path(directory) / name, uid, uid)
    candidates = sorted((corrupt / "backup/fixture" / labels[0] / "pg_data/base").rglob("*.gz"))
    if not candidates:
        raise ValueError("No synthetic backup payload selected for corruption")
    payload = candidates[0]
    data = bytearray(payload.read_bytes())
    data[len(data) // 2] ^= 1
    payload.write_bytes(data)
    negative = run(base + ["--set=" + labels[0], "--output=text", "--verbose", "verify"],
                   extra={"/repo": corrupt, "/config": config}, entrypoint="/usr/local/bin/pgbackrest",
                   filename="verify-corrupt.txt", check=False)
    try:
        report.parse_report(negative.stdout.decode(), stanza="fixture", labels=[labels[0]])
    except (ValueError, UnicodeError):
        corruption_rejected = True
    else:
        raise ValueError("Real corrupted report was accepted")
    # Require a real verification failure report as well as parser rejection, not just an unrelated crash.
    if b"status: error" not in negative.stdout or not re.search(rb"(?:checksum invalid|size invalid|other): [1-9]", negative.stdout):
        raise ValueError("Corruption did not exercise repository verification failure")

    pgdata = evidence / "recovered"
    private_directory(pgdata, uid)
    run(base + ["--set=" + labels[1], "--type=immediate", "--target-action=promote", "restore"],
        extra={"/repo": repo, "/config": config, "/pgdata": pgdata},
        entrypoint="/usr/local/bin/pgbackrest", filename="restore.txt")
    # Independent archive-get and PG16 WAL header/record validation, separate from verify's incomplete reconciliation.
    info = json.loads((work / "info.json").read_text())[0]
    selected = info["backup"][1]
    start, stop = selected["archive"]["start"], selected["archive"]["stop"]
    if not re.fullmatch("[0-9A-F]{24}", start) or not re.fullmatch("[0-9A-F]{24}", stop):
        raise ValueError("Invalid fixture WAL metadata")
    # This fixture intentionally spans a single backup WAL segment; real ranges need reviewed enumeration.
    if start != stop:
        raise ValueError("Fixture WAL range changed; do not silently skip coverage")
    wal_dir = evidence / "wal"
    private_directory(wal_dir, uid)
    run(base + ["--archive-async=n", "archive-get", start, "/evidence/" + start],
        extra={"/repo": repo, "/config": config, "/evidence": wal_dir},
        entrypoint="/usr/local/bin/pgbackrest", filename="archive-get.txt")
    control = run(["-ceu", "pg_controldata /pgdata"], extra={"/pgdata": pgdata}, filename="control.txt")
    system = re.search(rb"Database system identifier:\s+([0-9]+)", control.stdout)
    if not system:
        raise ValueError("PostgreSQL16 control identity missing")
    wal = (wal_dir / start).read_bytes()
    system_id, segment_size, block_size = struct.unpack_from("<QII", wal, 24)
    if system_id != int(system[1]) or segment_size != len(wal) or segment_size != 16 * 1024 * 1024 or block_size != 8192:
        raise ValueError("Independent WAL header/control check failed")
    run(["-ceu", "pg_waldump --quiet --path=/evidence " + start],
        extra={"/evidence": wal_dir}, filename="waldump.txt")

    recovered_script = """set -euo pipefail
mkdir -p /tmp/socket
cat >> /pgdata/postgresql.auto.conf <<'CONF'
listen_addresses = ''
unix_socket_directories = '/tmp/socket'
archive_mode = off
archive_command = ''
primary_conninfo = ''
primary_slot_name = ''
shared_preload_libraries = ''
session_preload_libraries = ''
local_preload_libraries = ''
ssl = off
logging_collector = off
CONF
pg_ctl -D /pgdata -l /evidence/postgres-recovered.log -w start > /evidence/start.log 2>&1
trap 'pg_ctl -D /pgdata -m fast -w stop >> /evidence/stop.log 2>&1' EXIT
test "$(psql -h /tmp/socket -d postgres -At -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM fixture')" = 3
"""
    recovered_logs = evidence / "recovered-logs"
    private_directory(recovered_logs, uid)
    run(["-ceu", recovered_script], extra={"/repo": repo, "/config": config, "/pgdata": pgdata,
                                           "/evidence": recovered_logs}, filename="query-check.txt")
    summary = {"schemaVersion": 1, "syntheticOnly": True, "imageId": args.image,
               "baseAmd64Digest": "sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d",
               "pgBackRestSourceCommit": "d9773a31c97077761ee8e7d06e073b0b0734e26f",
               "reports": verification, "realBinaryCorruptionRejected": corruption_rejected,
               "corruptionProcessExitCode": negative.returncode,
               "syntheticFullDiffRecoveryRows": 3, "independentSyntheticWalValidated": True,
               "walSHA256": hashlib.sha256(wal).hexdigest(), "realBackupValidated": False,
               "realDatabaseRestored": False, "restoreApproved": False}
    (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"syntheticIntegrationPassed": True, "realDatabaseRestored": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(f"Toolchain integration failed: {type(error).__name__}; inspect synthetic evidence") from None
