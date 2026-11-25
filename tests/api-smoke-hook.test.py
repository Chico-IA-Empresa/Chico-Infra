import importlib.util
import io
import json
import os
import pathlib
import unittest
import urllib.error
from unittest import mock

ROOT = pathlib.Path(__file__).parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = load("smoke_handler", ROOT / "modules/api-deploy/smoke/handler.py")
builder = load("build_smoke_hook", ROOT / "scripts/build-smoke-hook.py")


class FakeResponse(io.BytesIO):
    def __init__(self, status, body):
        super().__init__(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def responder(table):
    """table[url] = (status, body) ou uma exceção; registra os headers enviados."""
    seen = []

    def urlopen(request, timeout):
        seen.append((request.full_url, dict(request.header_items())))
        outcome = table[request.full_url]
        if isinstance(outcome, Exception):
            raise outcome
        return FakeResponse(*outcome)

    return urlopen, seen


API = "https://api.uat.example.com/health/ready/release"
WEB = "https://uat.example.com/"
ENV = {"SMOKE_URLS": json.dumps([API, WEB]), "TEST_HEADER": "x-chico-deploy-test", "ATTEMPTS": "3"}


class SmokeHookTest(unittest.TestCase):
    def run_hook(self, table):
        urlopen, seen = responder(table)
        sleeps = []
        with mock.patch.dict(os.environ, ENV, clear=False), mock.patch.object(smoke.urllib.request, "urlopen", urlopen):
            result = smoke.handler({}, None, sleep=sleeps.append)
        return result, seen, sleeps

    def test_ready_candidate_succeeds_through_the_test_header(self):
        result, seen, _ = self.run_hook({API: (200, b'{"status": "ready"}'), WEB: (200, b"<html>")})
        self.assertEqual(result, {"hookStatus": "SUCCEEDED"})
        # Só quem manda o header cai na cor nova (regra de teste do ALB).
        self.assertTrue(all(headers.get("X-chico-deploy-test") == "1" for _, headers in seen))

    def test_not_ready_release_gate_fails_the_deploy(self):
        table = {API: urllib.error.HTTPError(API, 503, "not ready", {}, io.BytesIO(b'{"status": "not_ready"}')), WEB: (200, b"")}
        result, seen, sleeps = self.run_hook(table)
        self.assertEqual(result, {"hookStatus": "FAILED"})
        self.assertEqual(len([url for url, _ in seen if url == API]), 3)  # tentou 3 vezes
        self.assertEqual(len(sleeps), 2)  # sem espera depois da última

    def test_200_without_ready_status_is_not_promotable(self):
        result, _, _ = self.run_hook({API: (200, b'{"status": "degraded"}'), WEB: (200, b"")})
        self.assertEqual(result, {"hookStatus": "FAILED"})

    def test_network_error_fails(self):
        result, _, _ = self.run_hook({API: OSError("connection refused"), WEB: (200, b"")})
        self.assertEqual(result, {"hookStatus": "FAILED"})

    def test_transient_failure_then_ready_succeeds(self):
        calls = {"n": 0}
        urlopen_ok, _ = responder({WEB: (200, b"")})

        def flaky(request, timeout):
            if request.full_url == API:
                calls["n"] += 1
                if calls["n"] == 1:
                    raise OSError("reset")
                return FakeResponse(200, b'{"status": "ready"}')
            return urlopen_ok(request, timeout)

        with mock.patch.dict(os.environ, ENV, clear=False), mock.patch.object(smoke.urllib.request, "urlopen", flaky):
            result = smoke.handler({}, None, sleep=lambda _: None)
        self.assertEqual(result, {"hookStatus": "SUCCEEDED"})


class PackageTest(unittest.TestCase):
    def test_committed_zip_matches_the_source(self):
        committed = (ROOT / "modules/api-deploy/smoke.zip").read_bytes()
        self.assertEqual(committed, builder.build(), "rode python scripts/build-smoke-hook.py")

    def test_build_is_deterministic(self):
        self.assertEqual(builder.build(), builder.build())


if __name__ == "__main__":
    unittest.main()
