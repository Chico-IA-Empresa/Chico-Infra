import json
import pathlib
import types
import unittest
import datetime
import hashlib
import stat
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "fixtures/dev/runtime-iam-read-negatives.py"
namespace = {"__name__": "runtime_negative_test_module"}
exec(compile(SOURCE.read_text(encoding="utf-8"), str(SOURCE), "exec"), namespace)

class RuntimeNegativeTests(unittest.TestCase):
    def review(self):
        return {"account_id": "306915830875", "provision_enabled": True, "credit_approval": {
            "account_id": "306915830875", "all_charges_covered": True, "shutdown_reserve_confirmed": True,
            "evidence_reference": "TEST-ONLY-not-release", "reviewed_on": "2026-11-03", "expires_on": "2026-11-04"},
            "proof": {"scope": "synthetic-dev-infra", "operation": "iam-read-negatives", "role": "runtime",
                "source_commit": "a" * 40, "script_sha256": "b" * 64, "probe_set_sha256": namespace["probe_hash"](),
                "inventory_reference": "TEST-ONLY-inventory", "inventory_checked_at_utc": "2026-11-03T16:00:00.000Z"}}

    def gate(self, value, now=None, script_hash="b" * 64, source="a" * 40, valid="2026-11-03T20:00:00Z"):
        raw = json.dumps(value).encode()
        return namespace["validate_review"](raw, hashlib.sha256(raw).hexdigest(), source, script_hash, valid, "true",
            now=now or datetime.datetime(2026, 11, 3, 16, 30, tzinfo=datetime.timezone.utc))

    def response(self, code=0, out=b"{}", err=b""):
        return types.SimpleNamespace(returncode=code, stdout=out, stderr=err)

    def identity(self, arn="arn:aws:sts::306915830875:assumed-role/chico-dev-runtime/i-03b97e256bbba039c"):
        return self.response(out=json.dumps({"Account": "306915830875", "Arn": arn}).encode())

    def test_exact_identity_and_all_five_calls(self):
        calls = []
        def fake(*args):
            calls.append(args)
            return self.identity() if len(calls) == 1 else self.response(255, err=b"An error occurred (AccessDenied) when calling the Test operation: denied")
        result = namespace["run"](fake)
        self.assertEqual(result["probes"], 5)
        self.assertEqual(len(calls), 6)
        for call, probe in zip(calls[1:], namespace["PROBES"]):
            self.assertEqual(call, (probe["service"], probe["operation"], probe["input"], probe["region"]))

    def test_unexpected_allow_aborts_before_later_probe_and_hides_metadata(self):
        calls = []
        def fake(*args):
            calls.append(args)
            return self.identity() if len(calls) == 1 else self.response(out=b'{"SENTINEL":"private"}')
        with self.assertRaisesRegex(ValueError, "unexpected allow"):
            namespace["run"](fake)
        self.assertEqual(len(calls), 2)

    def test_wrong_identity_stops_before_resource_access(self):
        calls = []
        def fake(*args):
            calls.append(args)
            return self.identity("arn:aws:iam::306915830875:root")
        with self.assertRaisesRegex(ValueError, "wrong live role"):
            namespace["run"](fake)
        self.assertEqual(len(calls), 1)

    def test_error_classification_never_treats_validation_or_missing_as_iam_pass(self):
        probe = namespace["PROBES"][0]
        for code in ("404", "NoSuchKey", "InvalidParameter", "ResourceNotFoundException", "Forbidden"):
            error = f"An error occurred ({code}) when calling the HeadObject operation: error".encode()
            self.assertFalse(namespace["denied"](self.response(255, err=error), probe))
        self.assertTrue(namespace["denied"](self.response(255, err=b"An error occurred (403) when calling the HeadObject operation: Forbidden\n"), probe))

    def test_sdk_maxattempts1_head403_decoration_is_accepted_only_for_exact_forbidden_head(self):
        probe = namespace["PROBES"][0]
        decorated = b"An error occurred (403) when calling the HeadObject operation (reached max retries: 0): Forbidden\n"
        self.assertTrue(namespace["denied"](self.response(254, err=decorated), probe))
        for error in (
            b"403 Forbidden",
            b"An error occurred (403) when calling the HeadObject operation (reached max retries: 0): Network Error",
            b"An error occurred (404) when calling the HeadObject operation (reached max retries: 0): Forbidden",
            b"An error occurred (403) when calling the GetObject operation (reached max retries: 0): Forbidden",
            b"An error occurred (403) when calling the HeadObject operation (reached max retries: 1): Forbidden",
            b"An error occurred (403) when calling the HeadObject operation: Forbidden private-extra",
        ):
            self.assertFalse(namespace["denied"](self.response(254, err=error), probe))
        wrong_probe = {**probe, "operation": "get-object"}
        self.assertFalse(namespace["denied"](self.response(254, err=decorated), wrong_probe))

    def test_runtime_environment_removes_caller_credentials_and_profiles(self):
        env = namespace["runtime_environment"]()
        for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ENDPOINT_URL", "AWS_CONTAINER_CREDENTIALS_FULL_URI"):
            self.assertNotIn(name, env)
        self.assertEqual(env["AWS_CONFIG_FILE"], "/dev/null")
        self.assertEqual(env["AWS_EC2_METADATA_V1_DISABLED"], "true")

    def test_runtime_release_exact_source_script_inventory_and_funding(self):
        self.assertTrue(self.gate(self.review()))
        for kwargs in ({"script_hash": "c" * 64}, {"source": "d" * 40}, {"valid": "2026-11-03T16:30:00Z"}):
            with self.assertRaises(ValueError):
                self.gate(self.review(), **kwargs)

    def test_runtime_release_unknown_keys_and_wrong_role_rejected(self):
        for key, value in (("role", "build"), ("source_commit", "c" * 40), ("script_sha256", "d" * 64), ("probe_set_sha256", "e" * 64),
                           ("inventory_checked_at_utc", "2026-11-03T08:00:00Z"), ("inventory_checked_at_utc", "2026-11-03T17:00:00Z")):
            review = self.review(); review["proof"][key] = value
            with self.assertRaises(ValueError):
                self.gate(review)
        review = self.review(); review["proof"]["extra"] = True
        with self.assertRaises(ValueError):
            self.gate(review)

    def test_review_hash_binds_bytes_and_no_caller_file_is_accepted(self):
        raw = json.dumps(self.review()).encode()
        with self.assertRaises(ValueError):
            namespace["validate_review"](raw+b"\n", hashlib.sha256(raw).hexdigest(), "a"*40, "b"*64, "2026-11-03T20:00:00Z", "true")
        for path in ("/tmp/review.json", "/run/chico/../review.json", "C:/review.json", "/run/chico/review.json/extra"):
            with self.assertRaises(ValueError):
                namespace["read_private_review"](path)

    def test_expiry_recheck_stops_before_next_network_call(self):
        calls, checks = [], []
        def fake(*args):
            calls.append(args)
            return self.identity() if len(calls) == 1 else self.response(255, err=b"An error occurred (AccessDenied) when calling the Test operation: denied")
        def recheck():
            checks.append(True)
            if len(checks) == 3:
                raise ValueError("expired")
        with self.assertRaisesRegex(ValueError, "expired"):
            namespace["run"](fake, recheck)
        self.assertEqual(len(calls), 2)

    def test_review_guard_root0600_tmpfs_and_regular_file(self):
        regular = types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_size=40)
        with mock.patch.object(pathlib.Path, "is_symlink", return_value=False), mock.patch.object(pathlib.Path, "stat", return_value=regular), \
             mock.patch.object(pathlib.Path, "read_text", return_value="7 1 0:2 / /run/chico rw - tmpfs tmpfs rw\n"), \
             mock.patch.object(pathlib.Path, "read_bytes", return_value=b"review"):
            self.assertEqual(namespace["read_private_review"]("/run/chico/unique/review.json"), b"review")
            self.assertEqual(namespace["read_private_file"]("/run/chico/unique/probe.py", "py"), b"review")
            for delta in ({"st_uid": 1}, {"st_mode": stat.S_IFREG | 0o644}, {"st_mode": stat.S_IFDIR | 0o600}, {"st_size": 9000}):
                info = types.SimpleNamespace(**{**regular.__dict__, **delta})
                with mock.patch.object(pathlib.Path, "stat", return_value=info), self.assertRaises(ValueError):
                    namespace["read_private_review"]("/run/chico/unique/review.json")

    def test_review_guard_rejects_symlink_and_nontmpfs(self):
        with mock.patch.object(pathlib.Path, "is_symlink", return_value=True), self.assertRaises(ValueError):
            namespace["read_private_review"]("/run/chico/unique/review.json")
        info = types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_size=40)
        with mock.patch.object(pathlib.Path, "is_symlink", return_value=False), mock.patch.object(pathlib.Path, "stat", return_value=info), \
             mock.patch.object(pathlib.Path, "read_text", return_value="7 1 0:2 / /run rw - ext4 /dev/test rw\n"), self.assertRaises(ValueError):
            namespace["read_private_review"]("/run/chico/unique/review.json")

    def test_actual_script_size_is_accepted_and_json_python_boundaries_are_distinct(self):
        script_bytes = SOURCE.read_bytes()
        actual_size = len(script_bytes)
        # Exercise the actual delivered artifact size, not a tiny fictitious script.
        self.assertGreater(actual_size, 8192)
        self.assertLessEqual(actual_size, 32768)
        def checked(size, suffix, payload):
            info = types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_size=size)
            with mock.patch.object(pathlib.Path, "is_symlink", return_value=False), mock.patch.object(pathlib.Path, "stat", return_value=info), \
                 mock.patch.object(pathlib.Path, "read_text", return_value="7 1 0:2 / /run/chico rw - tmpfs tmpfs rw\n"), \
                 mock.patch.object(pathlib.Path, "read_bytes", return_value=payload):
                return namespace["read_private_file"]("/run/chico/unique/file." + suffix, suffix)
        self.assertEqual(checked(actual_size, "py", script_bytes), script_bytes)
        self.assertEqual(checked(8192, "json", b"metadata"), b"metadata")
        self.assertEqual(checked(32768, "py", b"script"), b"script")
        with self.assertRaises(ValueError):
            checked(8193, "json", b"metadata")
        with self.assertRaises(ValueError):
            checked(32769, "py", b"script")

if __name__ == "__main__":
    unittest.main()
