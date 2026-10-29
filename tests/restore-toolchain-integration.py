#!/usr/bin/env python3
"""Linux/Docker synthetic-only integration. No credentials, AWS, or production mounts.

Build first; pass the local immutable image id. Errors expose only a sanitized
stage summary from this newly generated fixture, never raw private diagnostics.
Evidence consists solely of this newly created encrypted synthetic fixture.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import secrets
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "operations/restore-toolchain"
CURRENT_STAGE = "argument-validation"
SYNTHETIC_EVIDENCE = None
FAILURE_CONTEXT = {}


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("isolated_run")
report = load("verify_report")
zlib_vex = load("zlib_vex_proposal")


def execute(command, output=None, must_succeed=True):
    global FAILURE_CONTEXT
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=False, timeout=300)
    if output:
        output.write_bytes(result.stdout)
        output.with_suffix(output.suffix + ".stderr").write_bytes(result.stderr)
    if must_succeed and result.returncode:
        FAILURE_CONTEXT = {"processExitCode": result.returncode,
                           "syntheticDiagnostics": sanitized_diagnostics(result.stdout, result.stderr)}
        raise RuntimeError("Synthetic toolchain command failed; inspect synthetic runner evidence")
    return result


def sanitized_diagnostics(stdout, stderr):
    """Only our fresh synthetic harness is allowed here; never a real restore logger."""
    secret = None
    parts = [stdout.decode(errors="replace"), stderr.decode(errors="replace")]
    if SYNTHETIC_EVIDENCE is not None:
        fixture = SYNTHETIC_EVIDENCE / "fixture"
        cipher = fixture / "cipher-fixture-only"
        if cipher.is_file() and not cipher.is_symlink():
            secret = cipher.read_text()
        for name in ["initdb.log", "start.log", "postgres.log", "sql.log", "stanza.log", "full.log", "diff.log"]:
            log = fixture / name
            if log.is_file() and not log.is_symlink():
                parts.append(name + ":\n" + log.read_text(errors="replace"))
    text = "\n".join(parts)
    if secret:
        text = text.replace(secret, "<REDACTED>")
    selected = []
    for line in text.splitlines():
        if re.search(r"ERROR|FATAL|PANIC|CHICO_SYNTHETIC_STAGE|Permission denied|permission denied|not found|Read-only file system|No such file", line):
            if re.search(r"cipher|passphrase|password|secret", line, re.I):
                selected.append("<synthetic configuration diagnostic redacted>")
            else:
                selected.append(line[:500])
    return selected[-16:]


def private_directory(path, uid):
    path.mkdir(mode=0o700)
    os.chown(path, uid, uid)


def main():
    global SYNTHETIC_EVIDENCE, CURRENT_STAGE
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
    SYNTHETIC_EVIDENCE = evidence
    mounts = {"/scripts": SCRIPTS}

    def run(arguments, *, extra=None, entrypoint="/bin/bash", filename=None, check=True):
        global CURRENT_STAGE
        CURRENT_STAGE = filename or "image-identity"
        print(json.dumps({"syntheticStage": CURRENT_STAGE}), flush=True)
        return execute(runner.isolated_command(args.image, uid, {**mounts, **(extra or {})}, entrypoint, arguments),
                       evidence / filename if filename else None, check)

    identity = run(["-u"], entrypoint="/usr/bin/id")
    if identity.stdout.strip() != b"999":
        raise ValueError("Pinned image UID changed")
    provenance = run(["-ceu", "test \"$(pgbackrest version)\" = 'pgBackRest 2.57.0'; "
                      "postgres --version; pgbackrest version; "
                      "cat /opt/chico-toolchain/binaries.sha256; "
                      "cat /opt/chico-toolchain/packages.tsv; "
                      "cat /opt/chico-toolchain/chico-sqlite-*.txt; "
                      "cat /opt/chico-toolchain/postgres-ldd.txt; "
                      "cat /opt/chico-toolchain/pgbackrest-ldd.txt; "
                      "cat /opt/chico-toolchain/runner-ca.sha256; "
                      "cat /opt/chico-toolchain/build/compiler.txt; "
                      "cat /opt/chico-toolchain/build/source.sha256; "
                      "cat /opt/chico-toolchain/build/packages.tsv; "
                      "cat /opt/chico-toolchain/build/meson.txt"], filename="provenance.txt")
    if b"16.13" not in provenance.stdout:
        raise ValueError("Unexpected PostgreSQL version")

    # Technical VEX proposal only: it cannot hide or accept any raw scanner finding.
    zlib_inventory = run(["-ceu", "dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n'"],
                         filename="zlib-package-inventory.txt")
    zlib_files = run(["-ceu", "dpkg -L zlib1g"], filename="zlib-package-files.txt")
    zlib_binary = run(["-ceu", "cat /lib/x86_64-linux-gnu/libz.so.1"], filename="zlib-runtime-library.so")
    CURRENT_STAGE = "zlib-elf-proof"
    symbol_result = execute(["readelf", "--dyn-syms", "--wide", str(evidence / "zlib-runtime-library.so")])
    soname_result = execute(["readelf", "--dynamic", "--wide", str(evidence / "zlib-runtime-library.so")])
    vex = zlib_vex.proposal(image_id=args.image, package_inventory=zlib_inventory.stdout.decode(),
        package_files=zlib_files.stdout.decode(), binary=zlib_binary.stdout,
        dynamic_symbols=symbol_result.stdout.decode(), dynamic_section=soname_result.stdout.decode())
    (evidence / "zlib-vex-proposal.json").write_text(json.dumps(vex, indent=2) + "\n")

    work = evidence / "fixture"
    private_directory(work, uid)
    # Generate and parse on the trusted host; the offline container needs no Python/SQLite runtime.
    cipher = secrets.token_urlsafe(48)
    cipher_path = work / "cipher-fixture-only"
    cipher_path.write_text(cipher)
    os.chmod(cipher_path, 0o600)
    os.chown(cipher_path, uid, uid)
    prepare_config = evidence / "prepare-config"
    private_directory(prepare_config, uid)
    prepare_file = prepare_config / "pgbackrest.conf"
    prepare_file.write_text("[global]\nrepo1-path=/work/repo\nrepo1-cipher-type=aes-256-cbc\n"
        "repo1-cipher-pass=" + cipher + "\nrepo1-retention-full=2\nrepo1-bundle=n\nrepo1-block=n\n"
        "compress-type=gz\nprocess-max=2\nlog-level-console=off\nlog-level-file=off\n"
        "lock-path=/tmp/pgbackrest\nspool-path=/tmp/pgbackrest\n[fixture]\npg1-path=/work/pg\npg1-socket-path=/tmp/socket\n")
    os.chmod(prepare_file, 0o600)
    os.chown(prepare_file, uid, uid)
    run(["/scripts/fixture_prepare.sh"], extra={"/work": work, "/config": prepare_config}, filename="prepare.log")
    fixture_info = json.loads((work / "info.json").read_text())[0]
    backups = fixture_info["backup"]
    if len(backups) != 2 or [backup["type"] for backup in backups] != ["full", "diff"]:
        raise ValueError("Invalid generated backup types")
    labels = [backup["label"] for backup in backups]
    if len(labels) != 2 or any(not report.LABEL.fullmatch(label) for label in labels):
        raise ValueError("Invalid generated full/diff chain")
    config = evidence / "config"
    private_directory(config, uid)
    (config / "pgbackrest.conf").write_text("[global]\nrepo1-path=/repo\nrepo1-cipher-type=aes-256-cbc\n"
        "repo1-cipher-pass=" + cipher + "\nlog-level-console=off\nlog-level-file=off\n"
        "lock-path=/tmp\nspool-path=/tmp\nprocess-max=2\n[fixture]\npg1-path=/pgdata\npg1-socket-path=/tmp/socket\n")
    os.chmod(config / "pgbackrest.conf", 0o600)
    os.chown(config / "pgbackrest.conf", uid, uid)
    base = ["--config=/config/pgbackrest.conf", "--stanza=fixture"]
    verify_base = base + ["--log-level-stderr=detail", "--log-timestamp=n"]
    repo = work / "repo"
    verification = []
    for number, label in enumerate(labels):
        result = run(verify_base + ["--set=" + label, "--output=text", "--verbose", "verify"],
                     extra={"/repo": repo, "/config": config}, entrypoint="/usr/local/bin/pgbackrest",
                     filename=f"verify-{number}.txt")
        verification.append(report.parse_report(result.stdout.decode(), stanza="fixture", labels=[label],
                                                 diagnostics=result.stderr.decode()))

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
    negative = run(verify_base + ["--set=" + labels[0], "--output=text", "--verbose", "verify"],
                   extra={"/repo": corrupt, "/config": config}, entrypoint="/usr/local/bin/pgbackrest",
                   filename="verify-corrupt.txt", check=False)
    try:
        report.parse_report(negative.stdout.decode(), stanza="fixture", labels=[labels[0]], diagnostics=negative.stderr.decode())
    except (ValueError, UnicodeError):
        corruption_rejected = True
    else:
        raise ValueError("Real corrupted report was accepted")
    # Require a real verification failure report as well as parser rejection, not just an unrelated crash.
    if b"status: error" not in negative.stdout or not re.search(rb"(?:checksum invalid|size invalid|other): [1-9]", negative.stdout):
        raise ValueError("Corruption did not exercise repository verification failure")

    # Restore payload then exercise main/copy metadata failures independently.
    payload.write_bytes((repo / payload.relative_to(corrupt)).read_bytes())
    metadata_cases = [("backup/fixture/backup.info", labels[0]),
                      ("backup/fixture/backup.info.copy", labels[0]),
                      ("archive/fixture/archive.info", labels[0]),
                      ("archive/fixture/archive.info.copy", labels[0])]
    for label in labels:
        metadata_cases += [(f"backup/fixture/{label}/backup.manifest", label),
                           (f"backup/fixture/{label}/backup.manifest.copy", label)]
    metadata_results = []
    for case, (relative, label) in enumerate(metadata_cases):
        target = corrupt / relative
        original = target.read_bytes()
        changed = bytearray(original)
        changed[len(changed) // 2] ^= 1
        target.write_bytes(changed)
        diagnostic_result = run(verify_base + ["--set=" + label, "--output=text", "--verbose", "verify"],
                                extra={"/repo": corrupt, "/config": config}, entrypoint="/usr/local/bin/pgbackrest",
                                filename=f"metadata-negative-{case}.txt", check=False)
        target.write_bytes(original)
        # The dangerous fallback case must really emit status ok; unrelated crashes do not prove this gap closed.
        if diagnostic_result.returncode != 0 or b"status: ok" not in diagnostic_result.stdout:
            raise ValueError("Metadata fixture did not exercise successful-summary fallback")
        try:
            report.parse_report(diagnostic_result.stdout.decode(), stanza="fixture", labels=[label],
                                diagnostics=diagnostic_result.stderr.decode())
        except (ValueError, UnicodeError):
            metadata_results.append({"case": case, "summaryWasOk": True, "privateDiagnosticsRejected": True})
        else:
            raise ValueError("Metadata corruption/fallback was accepted")

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
    run(base + ["--log-level-stderr=info", "--pg1-path=/control", "--archive-async=n", "archive-get", start, "/evidence/" + start],
        extra={"/repo": repo, "/config": config, "/control": pgdata, "/evidence": wal_dir},
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
               "metadataMainAndCopyNegativeCases": metadata_results,
               "syntheticFullDiffRecoveryRows": 3, "independentSyntheticWalValidated": True,
               "walSHA256": hashlib.sha256(wal).hexdigest(), "realBackupValidated": False,
               "realDatabaseRestored": False, "restoreApproved": False}
    (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"syntheticIntegrationPassed": True, "realDatabaseRestored": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        failure = {"syntheticOnly": True, "failedStage": CURRENT_STAGE, "errorType": type(error).__name__,
                   "realDatabaseRestored": False, **FAILURE_CONTEXT}
        # Our parser raises fixed messages without including input/diagnostic lines.
        if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError):
            failure["validationReason"] = str(error)
        if SYNTHETIC_EVIDENCE is not None:
            (SYNTHETIC_EVIDENCE / "failure-summary.json").write_text(json.dumps(failure, indent=2) + "\n")
        print(json.dumps(failure), flush=True)
        raise SystemExit("Toolchain synthetic integration failed; see sanitized stage summary") from None
