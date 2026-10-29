"""Offline parser/argv boundary tests; actual binary integration is separate."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "operations/restore-toolchain" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify = load("verify_report")
runner = load("isolated_run")
LABEL = "20261028-000000F"
# Grammar comes from pinned verify.c. This sample is not claimed as binary output.
SAMPLE = f"""stanza: fixture
status: ok
  archiveId: 16-1, total WAL checked: 2, total valid WAL: 2
    missing: 0, checksum invalid: 0, size invalid: 0, other: 0
  backup: {LABEL}, status: valid, total files checked: 123, total valid files: 123
    missing: 0, checksum invalid: 0, size invalid: 0, other: 0
"""


def diagnostic(report=SAMPLE, detail=None):
    return (f"INFO: verify command begin 2.57.0: --log-level-stderr=detail --log-level-console=off --output=text --verbose --set={LABEL}\n"
            + (detail or "DETAIL: archiveId: 16-1, wal start: 000000010000000000000001, wal stop: 000000010000000000000002")
            + "\nINFO: " + report.rstrip().replace("\n", "\n      ")
            + "\nINFO: verify command end: completed successfully (123ms)\n")


class ReportTests(unittest.TestCase):
    def parse(self, report=SAMPLE, labels=None):
        return verify.parse_report(report, stanza="fixture", labels=labels or [LABEL], diagnostics=diagnostic(report))

    def test_complete_report_is_only_one_gate(self):
        result = self.parse()
        self.assertTrue(result["reportAccepted"])
        self.assertFalse(result["restoreApproved"])
        self.assertFalse(result["independentWalValidated"])

    def test_all_corruption_classes_rejected(self):
        for error in ["missing", "checksum invalid", "size invalid", "other"]:
            with self.subTest(error=error), self.assertRaises(ValueError):
                self.parse(SAMPLE.replace(error + ": 0", error + ": 1", 1))

    def test_status_empty_counts_truncation_and_unknown_lines_rejected(self):
        changes = [SAMPLE.replace("status: ok", "status: error"),
                   SAMPLE.replace("status: valid", "status: invalid"),
                   SAMPLE.replace("WAL checked: 2", "WAL checked: 0"),
                   SAMPLE.replace("valid WAL: 2", "valid WAL: 1"),
                   SAMPLE.replace("valid files: 123", "valid files: 122"),
                   "\n".join(SAMPLE.splitlines()[:-1]), SAMPLE + "unrecognized\n",
                   SAMPLE.replace("stanza: fixture", "stanza: other"),
                   SAMPLE.replace("16-1", "15-1"),
                   SAMPLE.replace("missing: 0, checksum invalid: 0, size invalid: 0, other: 0", "missing: 0", 1)]
        for report in changes:
            with self.subTest(report=report), self.assertRaises(ValueError):
                self.parse(report)

    def test_expected_labels_must_match_exactly(self):
        for labels in [[LABEL, LABEL], ["latest"], ["20261027-000000F"]]:
            with self.subTest(labels=labels), self.assertRaises(ValueError):
                self.parse(labels=labels)

    def test_duplicate_section_rejected(self):
        with self.assertRaises(ValueError):
            self.parse(SAMPLE + "\n".join(SAMPLE.splitlines()[4:]) + "\n")

    def test_successful_report_does_not_hide_metadata_fallback(self):
        details = ["DETAIL: unable to open missing backup.info",
                   "DETAIL: backup.info.copy does not match backup.info",
                   "DETAIL: backup manifest is missing or unusable, using copy",
                   "DETAIL: archive.info.copy does not match archive.info",
                   "DETAIL: unknown message", "WARN: file missing"]
        for detail in details:
            with self.subTest(detail=detail), self.assertRaises(ValueError):
                verify.parse_report(SAMPLE, stanza="fixture", labels=[LABEL], diagnostics=diagnostic(detail=detail))

    def test_missing_or_changed_diagnostic_binding_rejected(self):
        for diag in ["", diagnostic().replace("2.57.0", "2.58.0"),
                     diagnostic().replace("--log-level-stderr=detail", "--log-level-stderr=off"),
                     diagnostic().replace("--set=" + LABEL, "--set=20261027-000000F"),
                     diagnostic().replace("total valid files: 123", "total valid files: 122"),
                     "\n".join(diagnostic().splitlines()[:-1])]:
            with self.subTest(diag=diag), self.assertRaises(ValueError):
                verify.parse_report(SAMPLE, stanza="fixture", labels=[LABEL], diagnostics=diag)

    def test_upstream_command_statistics_are_parsed_as_counters(self):
        diag = diagnostic().replace("INFO: verify command end", 'DETAIL: statistics: {"storage":{"read":10}}\nINFO: verify command end')
        self.assertTrue(verify.parse_report(SAMPLE, stanza="fixture", labels=[LABEL], diagnostics=diag)["privateDiagnosticsAccepted"])
        for value in ['{"secret":"arbitrary"}', '{"storage":-1}', 'not-json']:
            bad = diagnostic().replace("INFO: verify command end", 'DETAIL: statistics: ' + value + '\nINFO: verify command end')
            with self.subTest(value=value), self.assertRaises(ValueError):
                verify.parse_report(SAMPLE, stanza="fixture", labels=[LABEL], diagnostics=bad)


class IsolationTests(unittest.TestCase):
    def test_required_runtime_isolation_and_volume_cover(self):
        with tempfile.TemporaryDirectory() as directory:
            command = runner.isolated_command("sha256:" + "a" * 64, 999,
                                               {"/repo": Path(directory).resolve()},
                                               "/usr/local/bin/pgbackrest", ["version"])
        for flag in ["--network=none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges"]:
            self.assertIn(flag, command)
        self.assertTrue(any(x.startswith("/var/lib/postgresql/data:rw,") for x in command))
        self.assertTrue(any(x.endswith("dst=/repo,readonly") for x in command))
        self.assertNotIn("--privileged", command)

    def test_mutable_images_root_and_socket_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            for image, uid, mounts in [("postgres:16", 999, {}), ("sha256:" + "a" * 64, 0, {}),
                                       ("sha256:" + "a" * 64, 999, {"/var/run/docker.sock": Path(directory)})]:
                with self.subTest(image=image, uid=uid), self.assertRaises(ValueError):
                    runner.isolated_command(image, uid, mounts, "/bin/bash", [])


class SyntheticDiagnosticsTests(unittest.TestCase):
    def test_known_fixture_cipher_is_removed_from_errors_and_log_files(self):
        spec = importlib.util.spec_from_file_location("restore_integration", ROOT / "tests/restore-toolchain-integration.py")
        integration = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(integration)
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            fixture = evidence / "fixture"
            fixture.mkdir()
            token = "unit-only-sensitive-random-token"
            (fixture / "cipher-fixture-only").write_text(token)
            (fixture / "full.log").write_text("ERROR: authentication failed for " + token + "\n")
            integration.SYNTHETIC_EVIDENCE = evidence
            diagnostic = integration.sanitized_diagnostics(
                b"CHICO_SYNTHETIC_STAGE=full-backup\n",
                ("ERROR: connection failed for " + token + "\nERROR: repo1-cipher-pass=" + token).encode())
        joined = "\n".join(diagnostic)
        self.assertNotIn(token, joined)
        self.assertIn("<REDACTED>", joined)
        self.assertIn("CHICO_SYNTHETIC_STAGE=full-backup", joined)
        self.assertIn("configuration diagnostic redacted", joined)


if __name__ == "__main__":
    unittest.main()
