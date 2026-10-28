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


def parse_report(text, *, stanza, labels):
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
    return {"schemaVersion": 1, "pgBackRestVersion": "2.57.0", "stanza": stanza,
            "backupFilesChecked": backups, "walFilesChecked": archives,
            "reportAccepted": True, "independentWalValidated": False,
            "realDatabaseRestored": False, "restoreApproved": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--stanza", required=True)
    parser.add_argument("--label", action="append", required=True)
    args = parser.parse_args()
    # Never echo rejected input: real reports may contain private paths/metadata.
    try:
        result = parse_report(args.report.read_text(encoding="utf-8"), stanza=args.stanza, labels=args.label)
    except (OSError, UnicodeError, ValueError):
        raise SystemExit("Verification report rejected; private detail omitted") from None
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
