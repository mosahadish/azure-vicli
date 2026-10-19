#!/usr/bin/env python3
"""Tests for azure-cli.py's perf log (#91): with AZVICLI_DEBUG on, one line
per provider HTTP request (http_request and github_host.http) and one total
per command in <AZVICLI_PREFETCH_DIR>/perf.log - never a header, PAT or
token; with it off, nothing written. urlopen is mocked, so no network.
"""

import base64
import importlib.util
import io
import json
import os
import shutil
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_perf_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()
gh = ac.github()

PAT = "pat-SECRET-123"
GH_TOKEN = "ghp_SECRETTOKEN0123456789"


class _FakeResponse:
    def __init__(self, status=200, body=b'{"value": []}'):
        self.status = status
        self._body = body
        self.headers = {"Content-Type": "application/json"}

    def read(self):
        return self._body

    def getcode(self):
        return self.status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class _FakeServer:
    """Stands in for urlopen: answers every request with `response` (or
    raises `error`) and keeps the Request objects, so a test can check the
    secret really was sent - and still never reached the log."""

    def __init__(self, response=None, error=None):
        self.response = response
        self.error = error
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        if self.error is not None:
            raise self.error
        return self.response or _FakeResponse()


class PerfLogTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.env = {"AZVICLI_DEBUG": "1", "AZVICLI_PREFETCH_DIR": self.dir}
        self.log = os.path.join(self.dir, "perf.log")

    def tearDown(self):
        if ac._perf_current() is not None:
            del ac._perf_local.run
        shutil.rmtree(self.dir, ignore_errors=True)

    def lines(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as f:
            return [json.loads(l) for l in f if l.strip()]

    def raw_log(self):
        if not os.path.exists(self.log):
            return ""
        with open(self.log, encoding="utf-8") as f:
            return f.read()

    def run_cmd(self, cmd, fn, env=None):
        run = ac._perf_start(cmd, self.env if env is None else env)
        try:
            return fn()
        finally:
            ac._perf_finish(run)

    def assert_no_secrets(self, *secrets):
        text = self.raw_log()
        for s in secrets:
            self.assertNotIn(s, text)
        self.assertNotIn("Authorization", text)
        self.assertNotIn("Bearer", text)
        self.assertNotIn("Basic", text)

    def test_azure_request_logs_one_line_with_the_fields_and_no_pat(self):
        server = _FakeServer(_FakeResponse(200, b'{"value": [1, 2]}'))
        with mock.patch.object(ac.urllib.request, "urlopen", server):
            self.run_cmd("--list", lambda: ac.http_request(
                "https://dev.azure.com/org/proj/_apis/git/pullrequests?searchCriteria.status=active&x=secret",
                pat=PAT))
        basic = base64.b64encode(":{0}".format(PAT).encode("utf-8")).decode("ascii")
        # The PAT really went out, as a Basic header...
        self.assertEqual(server.requests[0].get_header("Authorization"), "Basic " + basic)
        reqs = [e for e in self.lines() if e["kind"] == "req"]
        self.assertEqual(len(reqs), 1)
        e = reqs[0]
        self.assertEqual(e["cmd"], "--list")
        self.assertEqual(e["method"], "GET")
        self.assertEqual(e["host"], "dev.azure.com")
        self.assertEqual(e["path"], "/org/proj/_apis/git/pullrequests?searchCriteria.status&x&api-version")
        self.assertEqual(e["status"], 200)
        self.assertEqual(e["bytes"], len(b'{"value": [1, 2]}'))
        self.assertGreaterEqual(e["ms"], 0)
        self.assertEqual(e["conn"], "new")
        # ...and never reached the log, nor did the query's values.
        self.assert_no_secrets(PAT, basic, "secret", "api-version=", "status=active")

    def test_github_request_logs_one_line_and_no_token(self):
        server = _FakeServer(_FakeResponse(200, b'{"data": {}}'))
        with mock.patch.object(gh.urllib.request, "urlopen", server):
            self.run_cmd("--wi-list", lambda: gh.http("POST", "https://api.github.com/graphql", GH_TOKEN,
                                                      {"query": "{ viewer { login } }"}),
                         env=dict(self.env, AZVICLI_WI_HOST="github"))
        self.assertEqual(server.requests[0].get_header("Authorization"), "Bearer " + GH_TOKEN)
        lines = self.lines()
        reqs = [e for e in lines if e["kind"] == "req"]
        self.assertEqual(len(reqs), 1)
        self.assertEqual((reqs[0]["method"], reqs[0]["host"], reqs[0]["path"], reqs[0]["status"]),
                         ("POST", "api.github.com", "/graphql", 200))
        self.assertEqual(reqs[0]["bytes"], len(b'{"data": {}}'))
        total = [e for e in lines if e["kind"] == "total"]
        self.assertEqual(total[0]["board"], "github")
        self.assert_no_secrets(GH_TOKEN, "viewer")

    def test_http_errors_are_logged_with_their_status(self):
        err = ac.urllib.error.HTTPError("https://dev.azure.com/org/_apis/y", 404, "Not Found", {},
                                        io.BytesIO(b"nope"))
        with mock.patch.object(ac.urllib.request, "urlopen", _FakeServer(error=err)):
            with self.assertRaises(ac.AdoHttpError):
                self.run_cmd("--threads", lambda: ac.http_request("https://dev.azure.com/org/_apis/y", pat=PAT))
        reqs = [e for e in self.lines() if e["kind"] == "req"]
        self.assertEqual([(e["status"], e["bytes"]) for e in reqs], [(404, 4)])
        self.assert_no_secrets(PAT)

    def test_the_api_version_retry_logs_both_requests(self):
        calls = []

        def urlopen(req, timeout=None):
            calls.append(req)
            if len(calls) == 1:
                raise ac.urllib.error.HTTPError(req.full_url, 400, "Bad Request", {}, io.BytesIO(b""))
            return _FakeResponse()
        with mock.patch.object(ac.urllib.request, "urlopen", urlopen):
            self.run_cmd("--list", lambda: ac.http_request("https://tfs.local/coll/_apis/projects", pat=PAT))
        reqs = [e for e in self.lines() if e["kind"] == "req"]
        self.assertEqual([e["status"] for e in reqs], [400, 200])
        total = [e for e in self.lines() if e["kind"] == "total"]
        self.assertEqual(total[0]["requests"], 2)

    def test_a_transport_error_is_logged_as_status_0(self):
        err = ac.urllib.error.URLError("Name or service not known")
        with mock.patch.object(ac.urllib.request, "urlopen", _FakeServer(error=err)):
            with self.assertRaises(ac.AdoTransportError):
                self.run_cmd("--list", lambda: ac.http_request("https://nowhere.example/_apis/x", pat=PAT))
        self.assertEqual([e["status"] for e in self.lines() if e["kind"] == "req"], [0])

    def test_dispatch_writes_the_commands_total(self):
        def fake_run_dispatch(argv, env):
            ac.http_request("https://dev.azure.com/org/_apis/a", pat=PAT)
            ac.http_request("https://dev.azure.com/org/_apis/b", pat=PAT)
            return 0
        with mock.patch.object(ac.urllib.request, "urlopen", _FakeServer()), \
                mock.patch.object(ac, "_run_dispatch", fake_run_dispatch):
            code, _out, _err = ac.dispatch(["--list"], dict(self.env))
        self.assertEqual(code, 0)
        lines = self.lines()
        self.assertEqual([e["kind"] for e in lines], ["req", "req", "total"])
        total = lines[-1]
        self.assertEqual((total["cmd"], total["requests"]), ("--list", 2))
        self.assertGreaterEqual(total["wall_ms"], 0)
        self.assertIsNone(ac._perf_current(), "the run outlived its command")

    def test_ping_writes_nothing(self):
        ac.dispatch(["--ping"], dict(self.env))
        self.assertFalse(os.path.exists(self.log))

    def test_perf_bind_carries_the_run_onto_a_pool(self):
        with mock.patch.object(ac.urllib.request, "urlopen", _FakeServer()):
            def fan_out():
                with ThreadPoolExecutor(max_workers=2) as ex:
                    futs = [ex.submit(ac._perf_bind(ac.http_request), "https://dev.azure.com/o/_apis/{0}".format(i),
                                      pat=PAT) for i in range(3)]
                    for f in futs:
                        f.result()
            self.run_cmd("--list", fan_out)
        total = [e for e in self.lines() if e["kind"] == "total"]
        self.assertEqual(total[0]["requests"], 3)
        self.assertEqual(len([e for e in self.lines() if e["kind"] == "req"]), 3)

    def test_concurrent_commands_keep_their_own_counts(self):
        barrier = threading.Barrier(2)

        def command(cmd, n):
            def body():
                barrier.wait()
                for i in range(n):
                    ac.http_request("https://dev.azure.com/o/_apis/{0}/{1}".format(cmd, i), pat=PAT)
            self.run_cmd(cmd, body)
        with mock.patch.object(ac.urllib.request, "urlopen", _FakeServer()):
            threads = [threading.Thread(target=command, args=("--list", 3)),
                       threading.Thread(target=command, args=("--threads", 5))]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        totals = {e["cmd"]: e["requests"] for e in self.lines() if e["kind"] == "total"}
        self.assertEqual(totals, {"--list": 3, "--threads": 5})

    def test_the_log_rotates_past_its_cap(self):
        with mock.patch.object(ac, "PERF_LOG_MAX_BYTES", 200), \
                mock.patch.object(ac.urllib.request, "urlopen", _FakeServer()):
            self.run_cmd("--list", lambda: [ac.http_request("https://dev.azure.com/o/_apis/x", pat=PAT)
                                            for _ in range(6)])
        self.assertTrue(os.path.exists(self.log + ".1"))
        self.assertLess(os.path.getsize(self.log), 600)

    def test_debug_off_logs_nothing_and_binds_nothing(self):
        for value in (None, "", "0"):
            env = {"AZVICLI_PREFETCH_DIR": self.dir}
            if value is not None:
                env["AZVICLI_DEBUG"] = value
            with mock.patch.object(ac.urllib.request, "urlopen", _FakeServer()), \
                    mock.patch.object(gh.urllib.request, "urlopen", _FakeServer()):
                self.assertIsNone(ac._perf_start("--list", env))
                ac.http_request("https://dev.azure.com/o/_apis/x", pat=PAT)
                gh.http("GET", "https://api.github.com/user", GH_TOKEN)

                def fake_run_dispatch(argv, env):
                    ac.http_request("https://dev.azure.com/o/_apis/y", pat=PAT)
                    return 0
                with mock.patch.object(ac, "_run_dispatch", fake_run_dispatch):
                    ac.dispatch(["--list"], env)
            self.assertFalse(os.path.exists(self.log), "AZVICLI_DEBUG={0!r} wrote a perf log".format(value))
            fn = ac.http_request
            self.assertIs(ac._perf_bind(fn), fn)


if __name__ == "__main__":
    unittest.main()
