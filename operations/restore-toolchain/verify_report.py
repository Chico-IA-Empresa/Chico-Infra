#!/usr/bin/env python3
"""Fail-closed parser for pgBackRest 2.57.0 --output=text --verbose, console=off.

This validates the report, not WAL completeness, recovered SQL, or restore approval.
The Linux integration must exercise this parser against the compiled binary.
"""
import argparse
import json
import re
from pathlib import Path

LABEL = re.compile(r"[0-9]{8}-[0-9]{6}F(?:_[0-9]{8}-[0-9]{6}[DI])?")
ARCHIVE = re.compile(r"  archiveId: (16-[1-9][0-9]*), total WAL checked: ([0-9]+), total valid WAL: ([0-9]+)")
BACKUP = re.compile(r"  backup: (\S+), status: (valid), total files checked: ([0-9]+), total valid files: ([0-9]+)")
ERRORS = re.compile(r"    missing: ([0-9]+), checksum invalid: ([0-9]+), size invalid: ([0-9]+), other: ([0-9]+)")


def validate_diagnostics(text, report_text, labels):
    """Reject fallback/missing metadata diagnostics hidden by a successful summary.

    Source: pinned verify.c and common/log.c. stderr omits timestamp/PID; only
    command begin, healthy WAL range DETAILs, the exact summary, and successful
    command end are accepted. Never return private diagnostic lines on failure.
    """
    lines = text.splitlines()
    if len(lines) < 4 or not lines[0].startswith("INFO: verify command begin 2.57.0: "):
        raise ValueError("Version-bound detailed diagnostics required")
    begin = lines[0]
    if any(option not in begin for option in ["--log-level-stderr=detail", "--log-level-console=off", "--output=text", "--verbose"]):
        raise ValueError("Incomplete diagnostic capture")
    if len(labels) != 1 or not re.search(r"(?:^| )--set=" + re.escape(labels[0]) + r"(?: |$)", begin):
        raise ValueError("Diagnostic label differs from reviewed command")
    if not re.fullmatch(r"INFO: verify command end: completed successfully(?: \([0-9]+ms\))?", lines[-1]):
        raise ValueError("Unsuccessful or incomplete diagnostic footer")
    expected = ("INFO: " + report_text.rstrip("\r\n").replace("\r\n", "\n").replace("\n", "\n      ")).splitlines()
    summary_indexes = [index for index, line in enumerate(lines) if line == expected[0]]
    if len(summary_indexes) != 1:
        raise ValueError("Exactly one diagnostic summary required")
    summary_start = summary_indexes[0]
    summary_end = summary_start + len(expected)
    if summary_start <= 1 or lines[summary_start:summary_end] != expected:
        raise ValueError("Diagnostic summary differs from stdout")
    healthy = re.compile(r"DETAIL: archiveId: 16-[1-9][0-9]*, wal start: [0-9A-F]{24}, wal stop: [0-9A-F]{24}")
    details = lines[1:summary_start] + lines[summary_end:-1]
    wal_ranges = 0
    for line in details:
        if healthy.fullmatch(line):
            wal_ranges += 1
        elif line.startswith("DETAIL: statistics: "):
            # command.c emits nonnegative counters after the report, before command end.
            try:
                statistics = json.loads(line.removeprefix("DETAIL: statistics: "))
            except json.JSONDecodeError:
                raise ValueError("Unrecognized private statistics") from None

            def counters(value):
                return ((type(value) is int and value >= 0) or
                        (isinstance(value, dict) and value and all(
                            isinstance(key, str) and re.fullmatch(r"[A-Za-z0-9_. -]+", key) and counters(child)
                            for key, child in value.items())))

            if not isinstance(statistics, dict) or not counters(statistics):
                raise ValueError("Unrecognized private statistics")
        else:
            raise ValueError("Private metadata/fallback or unknown diagnostic rejected")
    if not wal_ranges:
        raise ValueError("Detailed WAL diagnostics required")
    return True


def parse_report(text, *, stanza, labels, diagnostics):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", stanza):
        raise ValueError("Invalid expected stanza")
    if not labels or len(set(labels)) != len(labels) or any(not LABEL.fullmatch(x) for x in labels):
        raise ValueError("Explicit unique backup labels required")
    lines = text.splitlines()
    if len(lines) < 6 or lines[:2] != [f"stanza: {stanza}", "status: ok"]:
        raise ValueError("Missing exact successful verbose header")
    archives, backups = {}, {}
    index = 2
    while index < len(lines):
        line = lines[index]
        archive, backup = ARCHIVE.fullmatch(line), BACKUP.fullmatch(line)
        if archive:
            name, checked, valid = archive.groups()
            destination = archives
        elif backup:
            name, _, checked, valid = backup.groups()
            if not LABEL.fullmatch(name):
                raise ValueError("Invalid backup label in report")
            destination = backups
        else:
            raise ValueError("Unrecognized, incomplete, or failed report section")
        if name in destination or int(checked) <= 0 or checked != valid:
            raise ValueError("Duplicate, empty, or invalid section counts")
        index += 1
        if index >= len(lines) or not (errors := ERRORS.fullmatch(lines[index])):
            raise ValueError("Complete verbose error counts required")
        if any(int(value) for value in errors.groups()):
            raise ValueError("Repository verification errors")
        destination[name] = int(checked)
        index += 1
    if set(backups) != set(labels) or not archives:
        raise ValueError("Expected complete set and verified WAL required")
    validate_diagnostics(diagnostics, text, labels)
    return {"schemaVersion": 1, "pgBackRestVersion": "2.57.0", "stanza": stanza,
            "backupFilesChecked": backups, "walFilesChecked": archives,
            "reportAccepted": True, "privateDiagnosticsAccepted": True, "independentWalValidated": False,
            "realDatabaseRestored": False, "restoreApproved": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--stanza", required=True)
    parser.add_argument("--label", action="append", required=True)
    parser.add_argument("--diagnostics", type=Path, required=True)
    args = parser.parse_args()
    # Never echo rejected input: real reports may contain private paths/metadata.
    try:
        result = parse_report(args.report.read_text(encoding="utf-8"), stanza=args.stanza, labels=args.label,
                              diagnostics=args.diagnostics.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        raise SystemExit("Verification report rejected; private detail omitted") from None
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
