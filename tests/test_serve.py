#!/usr/bin/env python3
"""Unit tests for azure-cli.py's --serve daemon: dispatch()'s in-process
request runner (used by both --serve and, for a single one-shot CLI call,
main() itself) and serve()'s stdin/stdout request loop.

Run standalone with `python3 -m unittest tests/test_serve.py` or via
`bash tests/run.sh`.

dispatch()'s own tests drive it directly with fake argv/env dicts - no
stdin/stdout plumbing needed, since dispatch() takes argv/env as plain
arguments and returns (code, stdout_text, stderr_text). serve()'s tests
drive the real request loop with a fake sys.stdin (an object whose
`.buffer` is an io.BytesIO pre-loaded with the request lines - serve()
only ever reads it, no live pipe needed since every line is available
up front) and a fake sys.stdout (a plain io.StringIO), which is enough to
exercise the loop end to end including real concurrency (the
ThreadPoolExecutor still runs each request on its own worker thread; only
stdin/stdout are faked).
"""

import importlib.util
import io
import json
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_serve", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()


class _FakeStdin:
    """Stands in for sys.stdin: only `.buffer` is ever read (see serve()'s
    `for raw_line in sys.stdin.buffer:`), pre-loaded with every request line
    - there's nothing live to feed since the whole point of these tests is
    to check the loop's own behaviour, not real I/O timing.
    """

    def __init__(self, lines):
        data = ("\n".join(lines) + "\n").encode("utf-8") if lines else b""
        self.buffer = io.BytesIO(data)


def run_serve_sync(lines):
    """Runs a real ac.serve() call against `lines` (already-JSON request
    strings) with sys.stdin/sys.stdout faked, and returns (exit_code,
    response_lines) - each response_lines entry is the decoded JSON object
    from one response line, in the order they were written.
    """
    fake_stdout = io.StringIO()
    with mock.patch.object(ac.sys, "stdin", _FakeStdin(lines)), \
         mock.patch.object(ac.sys, "stdout", fake_stdout):
        code = ac.serve()
    responses = [json.loads(l) for l in fake_stdout.getvalue().splitlines() if l.strip()]
    return code, responses


# ---------------------------------------------------------------------------
# dispatch()
# ---------------------------------------------------------------------------


class DispatchTests(unittest.TestCase):
    def test_ping(self):
        self.assertEqual(ac.dispatch(["--ping"], {}), (0, "pong\n", ""))

    def test_missing_config_returns_1_instead_of_exiting_the_process(self):
        # Config.validate_exists() used to sys.exit(1) directly; dispatch()
        # must never let that (or anything else) escape as a real
        # SystemExit/process exit - every handler returns a code instead.
        with tempfile.TemporaryDirectory() as td:
            missing = os.path.join(td, "nope", "azure-cli.yml")
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: missing)):
                code, out, err = ac.dispatch(["--list"], {})
        self.assertEqual(code, 1)

    def test_unhandled_exception_in_a_handler_is_caught_not_raised(self):
        with mock.patch.object(ac, "cmd_pr_action", side_effect=RuntimeError("boom")):
            code, out, err = ac.dispatch(
                ["--threads"],
                {"AZVICLI_ORG": "x", "AZVICLI_PROJECT": "y", "AZVICLI_REPO": "r", "AZVICLI_PR": "1"},
            )
        self.assertEqual(code, 1)
        self.assertIn("boom", err)

    def test_env_is_threaded_through_not_read_from_os_environ(self):
        # An AZVICLI_ORG only present in the env dict passed to dispatch()
        # (never in real os.environ) must still reach the handler - proves
        # cmd_pr_action's env parameter, not a bare os.environ read, is
        # what's actually used under dispatch().
        seen = {}

        def fake_cmd_pr_action(flag, rest, env=None):
            seen["org"] = (env or {}).get("AZVICLI_ORG")
            return 0

        with mock.patch.object(ac, "cmd_pr_action", side_effect=fake_cmd_pr_action), \
             mock.patch.dict(ac.os.environ, {}, clear=False):
            ac.os.environ.pop("AZVICLI_ORG", None)
            ac.dispatch(["--threads"], {"AZVICLI_ORG": "https://dev.azure.com/only-in-request"})
        self.assertEqual(seen["org"], "https://dev.azure.com/only-in-request")

    def test_a_monkeypatched_handler_returns_known_captured_output(self):
        def fake_cmd_list(config, env=None):
            print("fake output line")
            print("fake error line", file=ac.sys.stderr)
            return 3

        with mock.patch.object(ac.Config, "validate_exists", return_value=True), \
             mock.patch.object(ac, "get_cached_config", return_value=object()), \
             mock.patch.object(ac, "cmd_list", side_effect=fake_cmd_list):
            code, out, err = ac.dispatch(["--list"], {})
        self.assertEqual(code, 3)
        self.assertEqual(out, "fake output line\n")
        self.assertEqual(err, "fake error line\n")

    def test_concurrent_dispatch_calls_dont_cross_talk(self):
        # Two dispatch() calls on different threads, each printing text
        # that includes its own env value - if the per-thread stdout/stderr
        # capture in _captured_output leaked across threads, one thread's
        # output could end up attributed to the other's result.
        results = {}

        def fake_cmd_list(config, env=None):
            print(ac.threading.current_thread().name)
            return 0

        def worker(name):
            results[name] = ac.dispatch(["--list"], {})

        # The mock.patch context managers themselves are not thread-safe to
        # enter/exit concurrently (each save/restores a shared module
        # attribute), so they're applied ONCE here, around every worker
        # thread's run - only the mocked callables are actually invoked
        # concurrently, which is what this test means to exercise.
        with mock.patch.object(ac.Config, "validate_exists", return_value=True), \
             mock.patch.object(ac, "get_cached_config", return_value=object()), \
             mock.patch.object(ac, "cmd_list", side_effect=fake_cmd_list):
            threads = [threading.Thread(target=worker, args=("t{0}".format(i),), name="t{0}".format(i))
                       for i in range(6)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        for name, (code, out, err) in results.items():
            self.assertEqual(code, 0)
            self.assertEqual(out.strip(), name, "each thread's captured stdout must be its own, not another's")


# ---------------------------------------------------------------------------
# serve()
# ---------------------------------------------------------------------------


class ServeLoopTests(unittest.TestCase):
    def test_ping_end_to_end(self):
        code, responses = run_serve_sync(['{"id": 7, "argv": ["--ping"]}'])
        self.assertEqual(code, 0)
        self.assertEqual(responses, [{"id": 7, "code": 0, "stdout": "pong\n", "stderr": ""}])

    def test_eof_drains_and_exits_cleanly(self):
        code, responses = run_serve_sync([])
        self.assertEqual(code, 0)
        self.assertEqual(responses, [])

    def test_malformed_line_gets_an_id_null_error_response(self):
        code, responses = run_serve_sync(["not valid json{{{"])
        self.assertEqual(code, 0)
        self.assertEqual(len(responses), 1)
        self.assertIsNone(responses[0]["id"])
        self.assertEqual(responses[0]["code"], 1)
        self.assertIn("malformed", responses[0]["stderr"])

    def test_non_object_json_line_gets_an_id_null_error_response(self):
        code, responses = run_serve_sync(["[1, 2, 3]"])
        self.assertEqual(len(responses), 1)
        self.assertIsNone(responses[0]["id"])
        self.assertEqual(responses[0]["code"], 1)

    def test_missing_argv_field_gets_an_error_response_with_that_ids_id(self):
        code, responses = run_serve_sync(['{"id": 5}'])
        self.assertEqual(len(responses), 1)
        self.assertEqual(responses[0]["id"], 5)
        self.assertEqual(responses[0]["code"], 1)

    def test_concurrent_requests_complete_out_of_order_and_are_still_matched_by_id(self):
        # id 1 is deliberately the slow one - real concurrency (separate
        # ThreadPoolExecutor workers) means id 2's response is written
        # first, and each response must still carry the right id/stdout
        # pairing despite that.
        def fake_dispatch(argv, env):
            if argv == ["--slow"]:
                time.sleep(0.15)
                return (0, "slow-done\n", "")
            time.sleep(0.01)
            return (0, "fast-done\n", "")

        lines = [
            json.dumps({"id": 1, "argv": ["--slow"]}),
            json.dumps({"id": 2, "argv": ["--fast"]}),
        ]
        with mock.patch.object(ac, "dispatch", side_effect=fake_dispatch):
            code, responses = run_serve_sync(lines)
        self.assertEqual(code, 0)
        self.assertEqual(len(responses), 2)
        # Out-of-order arrival: the fast request's response was written first.
        self.assertEqual([r["id"] for r in responses], [2, 1])
        by_id = {r["id"]: r for r in responses}
        self.assertEqual(by_id[1]["stdout"], "slow-done\n")
        self.assertEqual(by_id[2]["stdout"], "fast-done\n")

    def test_request_env_overrides_are_seen_by_dispatch(self):
        seen = {}

        def fake_dispatch(argv, env):
            seen["env"] = env
            return (0, "", "")

        with mock.patch.object(ac, "dispatch", side_effect=fake_dispatch):
            run_serve_sync([json.dumps({"id": 1, "argv": ["--threads"],
                                         "env": {"AZVICLI_ORG": "https://x", "AZVICLI_PR": "42"}})])
        self.assertEqual(seen["env"]["AZVICLI_ORG"], "https://x")
        self.assertEqual(seen["env"]["AZVICLI_PR"], "42")
        # Merged over the daemon's own environ, not replacing it outright.
        self.assertIn("PATH", seen["env"])


# ---------------------------------------------------------------------------
# Config reload on mtime change
# ---------------------------------------------------------------------------


class ConfigReloadTests(unittest.TestCase):
    def _write(self, path, pat):
        with open(path, "w", encoding="utf-8") as f:
            f.write("accounts:\n  - project_name: p\n    org_url: https://x\n    pat: {0}\n".format(pat))

    def test_reparses_only_when_mtime_changes(self):
        with tempfile.TemporaryDirectory() as td:
            cfg_path = os.path.join(td, "azure-cli.yml")
            self._write(cfg_path, "first")
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: cfg_path)):
                ac._config_cache.update({"path": None, "mtime": None, "config": None})
                cfg1 = ac.get_cached_config()
                self.assertEqual(cfg1.accounts[0].pat, "first")

                # Same mtime: must reuse the cached Config object (not just
                # an equal one) - proves it isn't re-reading the file.
                cfg1_again = ac.get_cached_config()
                self.assertIs(cfg1_again, cfg1)

                # gO-style edit: new content AND a bumped mtime (nudged
                # explicitly - some filesystems only have 1s mtime
                # resolution, so a real edit within the same test can land
                # on an identical mtime).
                self._write(cfg_path, "second")
                bumped = os.path.getmtime(cfg_path) + 5
                os.utime(cfg_path, (bumped, bumped))

                cfg2 = ac.get_cached_config()
                self.assertEqual(cfg2.accounts[0].pat, "second")
                self.assertIsNot(cfg2, cfg1)


# ---------------------------------------------------------------------------
# .userid cache: atomic write (temp + rename)
# ---------------------------------------------------------------------------


class UserIdCacheAtomicWriteTests(unittest.TestCase):
    def test_current_user_id_writes_the_cache_with_no_leftover_temp_file(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = ac.Config()
            cfg.accounts = [ac.AccountConfig(project="p", org_url="https://x", pat="tok")]
            actions = ac.PrActions(cfg, {
                "AZVICLI_ORG": "https://x", "AZVICLI_PROJECT": "p",
                "AZVICLI_REPO": "r", "AZVICLI_PR": "1", "AZVICLI_PREFETCH_DIR": td,
            })
            actions.pat = "tok"
            actions.fetch = lambda *a, **k: {"authenticatedUser": {"id": "abc-123"}}

            uid = actions.current_user_id()

            self.assertEqual(uid, "abc-123")
            self.assertEqual(os.listdir(td), [".userid"], "no leftover .userid.<tmp> file")
            with open(os.path.join(td, ".userid"), encoding="utf-8") as f:
                self.assertEqual(f.read(), "abc-123")


if __name__ == "__main__":
    unittest.main()
