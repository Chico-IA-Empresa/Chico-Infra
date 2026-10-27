import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("events", pathlib.Path(__file__).parents[1] / "modules/dev-box/proxy-events.py")
events = importlib.util.module_from_spec(spec)
spec.loader.exec_module(events)


class ProxyEventsTest(unittest.TestCase):
    def test_allowlist_removes_payload_identity_headers_and_urls(self):
        record = {"status": 200, "duration": 0.1, "size": 12, "request": {"method": "GET", "uri": "/?token=secret-token", "remote_ip": "192.0.2.1", "headers": {"Authorization": ["secret-token"], "Cookie": ["secret-cookie"]}}, "user_id": "personal-id"}
        text = json.dumps(events.sanitize(record))
        self.assertEqual(set(json.loads(text)), {"type", "method", "status", "duration", "size"})
        for forbidden in ("secret-token", "secret-cookie", "personal-id", "192.0.2.1", "uri", "headers"):
            self.assertNotIn(forbidden, text)

    def test_invalid_fields_never_echo_attacker_controlled_strings(self):
        for record in ({"status": "secret-token"}, [], {"status": 200, "duration": float("nan"), "size": 1}):
            self.assertEqual(events.sanitize(record), {"type": "proxy_record_rejected"})

    def test_partial_records_cursor_and_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "proxy.log"
            first = b'{"status":200,"duration":0.1,"size":1}\n'
            path.write_bytes(first + b'{"status":')
            result = events.read_events(path, now_ms=1)
            self.assertEqual(len(result["events"]), 1)
            self.assertEqual(result["cursor"]["offset"], len(first))
            with path.open("ab") as stream:
                stream.write(b'201,"duration":0,"size":2}\n')
            following = events.read_events(path, result["cursor"], now_ms=2)
            self.assertEqual(json.loads(following["events"][0]["message"])["status"], 201)
            path.unlink()
            path.write_bytes(first)
            self.assertEqual(len(events.read_events(path, following["cursor"])["events"]), 1)

    def test_oversize_and_malformed_records_cannot_stall_or_leak(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "proxy.log"
            path.write_bytes(b"secret-token" * 6000 + b"\nnot-json\n")
            result = events.read_events(path)
            self.assertEqual(result["cursor"]["offset"], path.stat().st_size)
            self.assertNotIn("secret-token", json.dumps(result))
            self.assertTrue(all(json.loads(e["message"])["type"] == "proxy_record_rejected" for e in result["events"]))


if __name__ == "__main__":
    unittest.main()
