import importlib.util
import contextlib
import hashlib
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("consumer", pathlib.Path(__file__).parents[1] / "fixtures/dev/config-consumer.py")
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)


class SyntheticConfigTest(unittest.TestCase):
    def test_launch_files_are_immutable_and_unresolved_reference_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = pathlib.Path(temp) / "api/launch-a/synthetic_token"
            consumer.consume("synthetic-v1", destination)
            self.assertEqual(destination.read_text(), "synthetic-v1")
            with self.assertRaises(FileExistsError):
                consumer.consume("synthetic-v2", destination)
            self.assertEqual(destination.read_text(), "synthetic-v1")
            with self.assertRaises(ValueError):
                consumer.consume("{{resolve:secretsmanager:/chico/dev/api/SYNTHETIC_TOKEN}}", destination)
            self.assertEqual(destination.read_text(), "synthetic-v1")

    def test_empty_secret_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = pathlib.Path(temp) / "api/synthetic_token"
            with self.assertRaises(ValueError):
                consumer.consume("", destination)
            self.assertFalse(destination.exists())

    def test_old_consumer_keeps_a_and_new_consumer_loads_b(self):
        with tempfile.TemporaryDirectory() as temp:
            old = pathlib.Path(temp) / "a/token"
            new = pathlib.Path(temp) / "b/token"
            consumer.consume("synthetic-A", old)
            first = consumer.PersistentConsumer(old)
            consumer.consume("synthetic-B", new)
            second = consumer.PersistentConsumer(new)
            old.unlink()  # The running consumer never needs to reopen its file.
            self.assertTrue(first.matches("synthetic-A"))
            self.assertFalse(first.matches("synthetic-B"))
            self.assertFalse(second.matches("synthetic-A"))
            self.assertTrue(second.matches("synthetic-B"))

    def test_protocol_only_returns_booleans_and_never_echoes_candidate(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "a/token"
            consumer.consume("private-synthetic-A", path)
            requests = io.StringIO('{"candidate":"private-synthetic-A"}\n{"candidate":"private-synthetic-B"}\n')
            output = io.StringIO()
            consumer.serve(path, requests, output)
            self.assertEqual([json.loads(s) for s in output.getvalue().splitlines()],
                             [{"ready": True}, {"matches": True}, {"matches": False}])
            self.assertNotIn("private-synthetic", output.getvalue())

    def test_subprocess_never_receives_secret_in_arguments_or_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "launch/token"
            value = "synth-only-" + "a" * 64
            consumer.consume(value, path)
            args = [sys.executable, str(pathlib.Path(consumer.__file__)), "serve", "--token-file", str(path)]
            self.assertNotIn(value, " ".join(args))
            self.assertFalse(any(value in s for s in os.environ.values()))
            result = subprocess.run(args, input=json.dumps({"candidate": value}) + "\n", text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual([json.loads(s) for s in result.stdout.splitlines()], [{"ready": True}, {"matches": True}])
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_bad_protocol_is_rejected_without_echo(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "launch/token"
            consumer.consume("synthetic-A", path)
            args = [sys.executable, str(pathlib.Path(consumer.__file__)), "serve", "--token-file", str(path)]
            for data in ('{"candidate":"do-not-echo","extra":1}\n', 'do-not-echo\n', '{"candidate":"do-not-echo"}', 'x' * 32769 + '\n'):
                result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("do-not-echo", result.stdout + result.stderr)
                self.assertIn("synthetic_configuration_failed", result.stderr)

    def test_invalid_values_never_create_file(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = pathlib.Path(temp) / "api/token"
            for value in (None, 123, "", "x\x00y", "x" * 4097, "prefix{{resolve:anything}}"):
                with self.assertRaises(ValueError):
                    consumer.consume(value, destination)
                self.assertFalse(destination.exists())

    @unittest.skipUnless(os.name == "posix", "POSIX permissions and links")
    def test_symlinks_hardlinks_and_public_files_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "a/token"
            consumer.consume("synthetic-A", path)
            os.chmod(path, 0o644)
            with self.assertRaises(ValueError):
                consumer.read_private(path)
            os.chmod(path, 0o600)
            alias = pathlib.Path(temp) / "alias"
            os.link(path, alias)
            with self.assertRaises(ValueError):
                consumer.read_private(path)
            alias.unlink()
            alias.symlink_to(path)
            with self.assertRaises(OSError):
                consumer.read_private(alias)
            link = pathlib.Path(temp) / "directory-link"
            link.symlink_to(path.parent, target_is_directory=True)
            with self.assertRaises(ValueError):
                consumer.consume("synthetic-B", link / "other")

    def test_reviewed_resolver_hash_and_interface_without_network(self):
        source = b'def resolve_string(reference):\n    return "synthetic-offline"\n'
        safe = SimpleNamespace(st_mode=stat.S_IFREG | 0o755, st_uid=0)
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "asm-exec"
            path.write_bytes(source)
            with patch.object(pathlib.Path, "lstat", return_value=safe), patch.object(consumer, "RESOLVER_SHA256", hashlib.sha256(source).hexdigest()):
                resolver = consumer.load_resolver(path)
                self.assertEqual(resolver(consumer.REFERENCE), "synthetic-offline")
            with patch.object(pathlib.Path, "lstat", return_value=safe):
                with self.assertRaises(ValueError):
                    consumer.load_resolver(path)

    def test_resolver_refuses_writable_or_symlink_source_path(self):
        for mode, owner in ((stat.S_IFREG | 0o777, 0), (stat.S_IFLNK | 0o755, 0), (stat.S_IFREG | 0o755, 1001)):
            with patch.object(pathlib.Path, "lstat", return_value=SimpleNamespace(st_mode=mode, st_uid=owner)):
                with self.assertRaises(ValueError):
                    consumer.load_resolver("/synthetic/asm-exec")

    def test_delivery_refuses_endpoint_override_before_loading_resolver(self):
        for key in ("ASM_EXEC_MCP_ENDPOINT", "AWS_SECRETS_MANAGER_AGENT_ENDPOINT"):
            with patch.object(consumer.sys, "platform", "linux"), patch.object(consumer.os, "geteuid", return_value=0, create=True), patch.dict(os.environ, {"CHICO_SYNTHETIC_ONLY": "true", "AWS_REGION": "sa-east-1", key: "https://example.invalid"}, clear=True), patch.object(consumer, "load_resolver") as resolver:
                with self.assertRaises(ValueError):
                    consumer.deliver("c" * 32)
                resolver.assert_not_called()

    def test_tmpfs_selection_uses_deepest_mount(self):
        mounts = "1 0 0:1 / / rw - ext4 root rw\n2 1 0:2 / /run rw - tmpfs tmpfs rw\n3 2 0:3 / /run/chico/api rw - ext4 disk rw\n"
        with patch.object(pathlib.Path, "read_text", return_value=mounts):
            with self.assertRaises(ValueError):
                consumer.require_tmpfs("/run/chico/api/token")
        with patch.object(pathlib.Path, "read_text", return_value=mounts.split("3 2")[0]):
            consumer.require_tmpfs("/run/chico/api/token")

    def test_tmpfs_same_path_stacked_mounts_are_rejected_in_both_orders(self):
        base = "1 0 0:1 / / rw - ext4 root rw\n"
        entries = ["2 1 0:2 / /run rw - tmpfs tmpfs rw\n", "3 1 0:3 / /run rw - ext4 disk rw\n"]
        for ordered in (entries, entries[::-1]):
            with patch.object(pathlib.Path, "read_text", return_value=base + "".join(ordered)):
                with self.assertRaises(ValueError):
                    consumer.require_tmpfs("/run/chico/api/token")

    def test_tmpfs_hidden_descendant_does_not_override_visible_ancestor(self):
        # Mount2 existed below the original root. Mount3 covers /run later;
        # /run/chico/api from mount2 is hidden despite its longer path.
        mounts = "1 0 0:1 / / rw - ext4 root rw\n2 1 0:2 / /run/chico/api rw - tmpfs tmpfs rw\n3 1 0:3 / /run rw - ext4 disk rw\n"
        with patch.object(pathlib.Path, "read_text", return_value=mounts):
            with self.assertRaises(ValueError):
                consumer.require_tmpfs("/run/chico/api/token")

    def test_tmpfs_nested_visible_mount_uses_actual_parent_chain(self):
        mounts = "1 0 0:1 / / rw - ext4 root rw\n2 1 0:2 / /run rw - ext4 disk rw\n3 2 0:3 / /run/chico/api rw - tmpfs tmpfs rw\n"
        with patch.object(pathlib.Path, "read_text", return_value=mounts):
            consumer.require_tmpfs("/run/chico/api/token")

    def test_tmpfs_namespace_root_self_parent_terminates_valid_chain(self):
        mounts = "1 1 0:1 / / rw - ext4 root rw\n2 1 0:2 / /run rw - tmpfs tmpfs rw\n"
        with patch.object(pathlib.Path, "read_text", return_value=mounts):
            consumer.require_tmpfs("/run/chico/api/token")

    def test_tmpfs_nonroot_self_parent_is_still_rejected(self):
        mounts = "1 1 0:1 / / rw - ext4 root rw\n2 2 0:2 / /run rw - tmpfs tmpfs rw\n"
        with patch.object(pathlib.Path, "read_text", return_value=mounts):
            with self.assertRaises(ValueError):
                consumer.require_tmpfs("/run/chico/api/token")

    def test_tmpfs_duplicate_ids_and_parent_cycles_are_rejected(self):
        examples = (
            "1 0 0:1 / / rw - ext4 root rw\n1 1 0:2 / /run rw - tmpfs tmpfs rw\n",
            "1 2 0:1 / / rw - ext4 root rw\n2 1 0:2 / /run rw - tmpfs tmpfs rw\n",
        )
        for mounts in examples:
            with patch.object(pathlib.Path, "read_text", return_value=mounts):
                with self.assertRaises(ValueError):
                    consumer.require_tmpfs("/run/chico/api/token")

    def test_delivery_rejects_existing_launch_before_resolver(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp) / "api"
            root.mkdir(mode=0o700)
            launch = "a" * 32
            (root / launch).mkdir(mode=0o700)
            with patch.object(consumer.sys, "platform", "linux"), patch.object(consumer.os, "geteuid", return_value=0, create=True), patch.dict(os.environ, {"CHICO_SYNTHETIC_ONLY": "true", "AWS_REGION": "sa-east-1"}, clear=True), patch.object(consumer, "DELIVERY_ROOT", root), patch.object(consumer, "require_tmpfs"), patch.object(consumer, "private_directory"), patch.object(consumer, "load_resolver") as resolver:
                with self.assertRaises(ValueError):
                    consumer.deliver(launch)
                resolver.assert_not_called()

    def test_delivery_resolves_only_fixed_reference_in_memory_and_suppresses_diagnostics(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp) / "api"
            root.mkdir(mode=0o700)
            launch = "b" * 32
            output = io.StringIO()
            def resolve(reference):
                self.assertEqual(reference, consumer.REFERENCE)
                print("synthetic-private-diagnostic")
                return "synthetic-private-token"
            with patch.object(consumer.sys, "platform", "linux"), patch.object(consumer.os, "geteuid", return_value=0, create=True), patch.dict(os.environ, {"CHICO_SYNTHETIC_ONLY": "true", "AWS_REGION": "sa-east-1"}, clear=True), patch.object(consumer, "DELIVERY_ROOT", root), patch.object(consumer, "require_tmpfs"), patch.object(consumer, "private_directory", side_effect=lambda directory: pathlib.Path(directory).mkdir(mode=0o700, parents=True, exist_ok=True)), patch.object(consumer, "load_resolver", return_value=resolve), contextlib.redirect_stdout(output):
                # Keep real file creation; directory verification was separately tested.
                consumer.deliver(launch)
            self.assertEqual((root / launch / "synthetic_token").read_text(), "synthetic-private-token")
            self.assertEqual(json.loads(output.getvalue()), {"delivered": True, "launchId": launch})
            self.assertNotIn("synthetic-private", output.getvalue())


if __name__ == "__main__":
    unittest.main()
