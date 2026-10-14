"""Unit tests for the phone dashboard's server (#97): `--web-dashboard`
(web_page_json, web_bind_allowed, web_dashboard_serve) - what the page JSON
keeps, which binds are refused, and the server's token, cookie, GET-only and
header rules over real HTTP."""
import base64
import hashlib
import http.client
import json
import os
import re
import socket
import stat
import threading
import unittest
from io import StringIO

from test_work_items import ac

TOKEN = "t0ken-for-the-tests_abcdefghijklmnopqrstuv"


def snapshot():
    return {
        "items": [
            {"header": "Needs you (1)"},
            {"label": "#3002", "title": "<script>alert(1)</script>", "state": "● plan waits for you",
             "group": 1, "ago": "3m", "cost": "$0.42", "detail": "ctx 27% · start_story",
             "key": "wi-3002", "target": {"work_item_id": 3002}, "plan": "SECRET PLAN TEXT",
             "path": "/home/me/.cache/nvim/azure-cli/fix-worktrees/x", "token": "ghp_x"},
            {"header": "Working (1)"},
            {"label": "#3001", "title": "Throttle logins", "state": "working", "group": 2, "ago": "12s",
             "cost": "", "detail": ""},
        ],
        "totals": "1 working · max 3 · $0.42 so far",
        "hidden": 2, "finished_days": 7, "conversations": [{"entries": ["x"]}],
    }


class WebPageJsonTests(unittest.TestCase):
    def test_keeps_only_what_the_agents_screen_shows(self):
        page = ac.web_page_json(snapshot())
        self.assertEqual(set(page), {"items", "totals", "hidden", "finished_days"})
        self.assertEqual(page["items"][0], {"header": "Needs you (1)"})
        row = page["items"][1]
        self.assertEqual(set(row), {"label", "title", "state", "group", "ago", "cost", "detail"})
        self.assertEqual(row["label"], "#3002")
        self.assertEqual(row["group"], 1)
        self.assertEqual(page["totals"], "1 working · max 3 · $0.42 so far")
        self.assertEqual(page["hidden"], 2)
        text = json.dumps(page)
        for secret in ("SECRET PLAN TEXT", "fix-worktrees", "ghp_x", "wi-3002", "conversations"):
            self.assertNotIn(secret, text)

    def test_bad_input_is_an_empty_page(self):
        for bad in (None, [], "x", {"items": "x"}, {"items": {}}):
            page = ac.web_page_json(bad)
            self.assertEqual(page["items"], [])
            self.assertEqual(page["totals"], "")

    def test_group_and_text_are_coerced(self):
        page = ac.web_page_json({"items": [{"label": {"a": 1}, "title": "t" * 1000, "group": True},
                                           {"label": 3, "group": 9}, "not a row"], "hidden": -1})
        self.assertEqual(len(page["items"]), 2)
        self.assertEqual(page["items"][0]["label"], "")
        self.assertEqual(len(page["items"][0]["title"]), 300)
        self.assertEqual(page["items"][0]["group"], 3)
        self.assertEqual(page["items"][1]["label"], "3")
        self.assertEqual(page["items"][1]["group"], 3)
        self.assertEqual(page["hidden"], 0)


class WebBindTests(unittest.TestCase):
    def test_every_interface_is_refused(self):
        for bind in ("", " ", "*", "0.0.0.0", "::", "[::]", "0:0:0:0:0:0:0:0"):
            self.assertFalse(ac.web_bind_allowed(bind), bind)
        for bind in ("127.0.0.1", "::1", "[::1]", "100.101.102.103", "192.168.1.20", "localhost"):
            self.assertTrue(ac.web_bind_allowed(bind), bind)

    def test_serve_refuses_to_start_on_every_interface(self):
        out, err = StringIO(), StringIO()
        self.assertEqual(ac.web_dashboard_serve("0.0.0.0", 0, stdin=iter(()), stdout=out, stderr=err), 2)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("every interface", err.getvalue())


class WebServerTests(unittest.TestCase):
    bind = "127.0.0.1"

    def setUp(self):
        r, w = socket.socketpair()
        self.stdin_r, self.stdin_w = r, w
        self.reader = r.makefile("rb")
        self.out, self.err = StringIO(), StringIO()
        self.rc = []
        self.thread = threading.Thread(target=lambda: self.rc.append(ac.web_dashboard_serve(
            self.bind, 0, stdin=self.reader, stdout=self.out, stderr=self.err, token=TOKEN)))
        self.thread.start()
        for _ in range(300):
            if self.out.getvalue().endswith("\n") or not self.thread.is_alive():
                break
            threading.Event().wait(0.01)
        first = json.loads(self.out.getvalue().splitlines()[0])
        self.port = first["port"]
        self.assertEqual(first["token"], TOKEN)

    def tearDown(self):
        self.stdin_w.close()
        self.thread.join(5)
        self.reader.close()
        self.stdin_r.close()
        self.assertFalse(self.thread.is_alive(), "closing stdin should stop the server")
        self.assertEqual(self.rc, [0])
        self.assertNotIn(TOKEN, self.err.getvalue())

    def request(self, method, path, cookie=None, host=None):
        conn = http.client.HTTPConnection(host or self.bind, self.port, timeout=5)
        headers = {"Cookie": cookie} if cookie else {}
        conn.request(method, path, headers=headers)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp, body

    def cookie(self):
        return "other=1; azvicli_web=" + TOKEN

    def send_snapshot(self, snap):
        self.stdin_w.sendall((json.dumps(snap) + "\n").encode("utf-8"))
        for _ in range(300):
            _, body = self.request("GET", "/rows.json", self.cookie())
            if json.loads(body)["items"]:
                return json.loads(body)
            threading.Event().wait(0.01)
        self.fail("the snapshot never reached /rows.json")

    def test_refused_without_or_with_a_wrong_token(self):
        for path, cookie in (("/", None), ("/rows.json", None), ("/?token=wrong", None), ("/?token=", None),
                             ("/", "azvicli_web=wrong"), ("/rows.json", "azvicli_web=" + TOKEN[:-1])):
            resp, body = self.request("GET", path, cookie)
            self.assertEqual(resp.status, 401, (path, cookie))
            self.assertNotIn(TOKEN.encode(), body)

    def test_the_token_sets_a_strict_cookie_and_redirects_it_away(self):
        resp, body = self.request("GET", "/?token=" + TOKEN)
        self.assertEqual(resp.status, 303)
        self.assertEqual(resp.getheader("Location"), "/")
        cookie = resp.getheader("Set-Cookie")
        self.assertIn("azvicli_web=" + TOKEN, cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertNotIn(TOKEN.encode(), body)

    def test_served_with_the_cookie(self):
        resp, body = self.request("GET", "/", self.cookie())
        self.assertEqual(resp.status, 200)
        self.assertTrue(resp.getheader("Content-Type").startswith("text/html"))
        self.assertIn(b"<main id=\"rows\">", body)
        self.assertNotIn(TOKEN.encode(), body)
        self.assertEqual(resp.getheader("Content-Security-Policy"), ac.WEB_CSP)
        self.assertEqual(resp.getheader("X-Content-Type-Options"), "nosniff")
        self.assertEqual(resp.getheader("Referrer-Policy"), "no-referrer")
        self.assertFalse([h for h, _ in resp.getheaders() if h.lower().startswith("access-control-")])
        resp, _ = self.request("GET", "/nothing-here", self.cookie())
        self.assertEqual(resp.status, 404)

    def test_rows_json_is_the_latest_snapshot_and_nothing_secret(self):
        page = self.send_snapshot(snapshot())
        self.assertEqual(page, ac.web_page_json(snapshot()))
        _, body = self.request("GET", "/rows.json", self.cookie())
        for secret in (TOKEN, "SECRET PLAN TEXT", "fix-worktrees", "ghp_x", "wi-3002"):
            self.assertNotIn(secret.encode(), body)
        self.stdin_w.sendall(b"not json\n")
        later = dict(snapshot(), totals="0 working")
        self.stdin_w.sendall((json.dumps(later) + "\n").encode("utf-8"))
        for _ in range(300):
            _, body = self.request("GET", "/rows.json", self.cookie())
            if json.loads(body)["totals"] == "0 working":
                break
            threading.Event().wait(0.01)
        self.assertEqual(json.loads(body)["totals"], "0 working")

    def test_only_get(self):
        for method in ("POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"):
            resp, body = self.request(method, "/?token=" + TOKEN, self.cookie())
            self.assertEqual(resp.status, 405, method)
            self.assertEqual(resp.getheader("Allow"), "GET")
            self.assertIsNone(resp.getheader("Set-Cookie"))
            self.assertNotIn(TOKEN.encode(), body)


class WebServerBindTests(WebServerTests):
    """The same server on another loopback address: it answers there and
    nowhere else."""
    bind = "127.0.0.2"

    def setUp(self):
        probe = socket.socket()
        try:
            probe.bind(("127.0.0.2", 0))
        except OSError:
            self.skipTest("127.0.0.2 isn't a local address here")
        finally:
            probe.close()
        super().setUp()

    def test_binds_only_where_configured(self):
        resp, _ = self.request("GET", "/", self.cookie())
        self.assertEqual(resp.status, 200)
        with self.assertRaises(OSError):
            self.request("GET", "/", self.cookie(), host="127.0.0.1")


class Served:
    """A web_dashboard_serve on 127.0.0.1:0 in a thread, fed through a
    socket pair: .line(n) is its n-th stdout line, .stop() closes stdin."""

    def __init__(self, **kw):
        self.r, self.w = socket.socketpair()
        self.reader = self.r.makefile("rb")
        self.out, self.err, self.rc = StringIO(), StringIO(), []
        self.thread = threading.Thread(target=lambda: self.rc.append(ac.web_dashboard_serve(
            "127.0.0.1", 0, stdin=self.reader, stdout=self.out, stderr=self.err, **kw)))
        self.thread.start()
        self.port = self.line(0)["port"]

    def line(self, n):
        for _ in range(500):
            lines = self.out.getvalue().splitlines()
            if len(lines) > n and self.out.getvalue().endswith("\n"):
                return json.loads(lines[n])
            threading.Event().wait(0.01)
        raise AssertionError("no stdout line {0}: {1!r} {2!r}".format(n, self.out.getvalue(), self.err.getvalue()))

    def send(self, obj):
        self.w.sendall((json.dumps(obj) + "\n").encode("utf-8"))

    def get(self, path, cookie=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", path, headers={"Cookie": cookie} if cookie else {})
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status

    def stop(self):
        self.w.close()
        self.thread.join(5)
        self.reader.close()
        self.r.close()
        return self.rc


class WebTokenFileTests(unittest.TestCase):
    """--token-file (#105): the token survives a restart, is stored 0600,
    and a file that can't be trusted is replaced."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "state", "azure-cli", "web-token")

    def tearDown(self):
        self.dir.cleanup()

    def serve(self):
        s = Served(token_file=self.path)
        first = s.line(0)
        self.assertEqual(s.stop(), [0])
        self.assertNotIn(first["token"], s.err.getvalue())
        return first

    def test_a_restart_keeps_the_token(self):
        one, two = self.serve(), self.serve()
        self.assertRegex(one["token"], r"^[A-Za-z0-9_-]{43}$")
        self.assertEqual(one["token"], two["token"])
        self.assertTrue(one["stored"] and two["stored"])
        self.assertNotIn("replaced", two)
        with open(self.path) as fh:
            self.assertEqual(fh.read().strip(), one["token"])

    @unittest.skipIf(os.name == "nt", "POSIX file modes")
    def test_the_file_is_born_0600_whatever_the_umask(self):
        old = os.umask(0)
        try:
            self.serve()
        finally:
            os.umask(old)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual(os.listdir(os.path.dirname(self.path)), ["web-token"])  # no temp file left

    def test_a_missing_or_malformed_file_makes_a_fresh_token(self):
        first = self.serve()["token"]
        for bad in ("", "short", first + "x", "not a token at all, with spaces in it, 43c"):
            ac.web_token_write(self.path, bad) if bad else open(self.path, "w").close()
            if os.name != "nt":
                os.chmod(self.path, 0o600)
            line = self.serve()
            self.assertRegex(line["token"], r"^[A-Za-z0-9_-]{43}$", bad)
            self.assertEqual(line["replaced"], "malformed", bad)
        os.unlink(self.path)
        line = self.serve()
        self.assertNotIn("replaced", line)
        self.assertTrue(line["stored"])

    @unittest.skipIf(os.name == "nt", "POSIX file modes")
    def test_a_file_others_can_read_is_replaced(self):
        first = self.serve()["token"]
        os.chmod(self.path, 0o644)
        line = self.serve()
        self.assertNotEqual(line["token"], first)
        self.assertEqual(line["replaced"], "permissions were 0644")
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual(self.serve()["token"], line["token"])

    @unittest.skipIf(os.name == "nt", "symlinks")
    def test_a_symlink_is_not_followed(self):
        target = os.path.join(self.dir.name, "elsewhere")
        token = "A" * 43
        fd = os.open(target, os.O_WRONLY | os.O_CREAT, 0o600)
        os.write(fd, token.encode())
        os.close(fd)
        os.makedirs(os.path.dirname(self.path))
        os.symlink(target, self.path)
        line = self.serve()
        self.assertNotEqual(line["token"], token)
        self.assertEqual(line["replaced"], "a symlink")
        self.assertFalse(os.path.islink(self.path))
        with open(target) as fh:
            self.assertEqual(fh.read(), token)  # the link's target left alone

    def test_two_starts_share_one_stored_token(self):
        token = ac.web_new_token()
        self.assertTrue(ac.web_token_create(self.path, token))
        self.assertFalse(ac.web_token_create(self.path, ac.web_new_token()))
        self.assertEqual(ac.web_token_load(self.path), (token, None))

    def test_unsavable_falls_back_to_memory(self):
        os.makedirs(os.path.dirname(self.path))
        os.mkdir(self.path)  # a directory where the file should be
        s = Served(token_file=self.path)
        first = s.line(0)
        self.assertFalse(first["stored"])
        self.assertIn("can't save the token", first["error"])
        self.assertEqual(s.get("/?token=" + first["token"]), 303)
        self.assertEqual(s.stop(), [0])


class WebRotateTests(unittest.TestCase):
    """{"control": "rotate"} (#105): a new token, saved, and the old URL
    and cookie get 401 at once."""

    def test_rotate_invalidates_the_old_token(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "web-token")
            s = Served(token_file=path)
            try:
                old = s.line(0)["token"]
                self.assertEqual(s.get("/rows.json", "azvicli_web=" + old), 200)
                s.send({"control": "rotate"})
                new = s.line(1)
                self.assertNotEqual(new["token"], old)
                self.assertEqual(new["port"], s.port)
                self.assertTrue(new["stored"])
                self.assertEqual(s.get("/rows.json", "azvicli_web=" + old), 401)
                self.assertEqual(s.get("/?token=" + old), 401)
                self.assertEqual(s.get("/rows.json", "azvicli_web=" + new["token"]), 200)
                self.assertEqual(s.get("/?token=" + new["token"]), 303)
                with open(path) as fh:
                    self.assertEqual(fh.read().strip(), new["token"])
                s.send({"items": [{"label": "#1", "title": "still fed", "group": 2}]})
            finally:
                self.assertEqual(s.stop(), [0])
            for t in (old, new["token"]):
                self.assertNotIn(t, s.err.getvalue())

    def test_rotate_without_a_token_file(self):
        s = Served()
        try:
            old = s.line(0)["token"]
            self.assertNotIn("stored", s.line(0))
            s.send({"control": "rotate"})
            new = s.line(1)["token"]
            self.assertNotEqual(new, old)
            self.assertEqual(s.get("/?token=" + old), 401)
            self.assertEqual(s.get("/?token=" + new), 303)
        finally:
            self.assertEqual(s.stop(), [0])


class WebTokenNeverExposedTests(unittest.TestCase):
    """The real `azure-cli.py --web-dashboard` process (#105): the token is
    on stdout only - not on argv (ps), stderr (:AzureCli log) or the debug
    perf log (#91)."""

    def test_not_on_argv_stderr_or_the_debug_log(self):
        import subprocess
        import sys
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state", "web-token")
            env = dict(os.environ, AZVICLI_DEBUG="1", AZVICLI_PREFETCH_DIR=os.path.join(d, "cache"))
            argv = [sys.executable, ac.__file__, "--web-dashboard", "--bind", "127.0.0.1", "--port", "0",
                    "--token-file", path]
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=env)
            try:
                token = json.loads(p.stdout.readline())["token"]
                cmdline = "/proc/{0}/cmdline".format(p.pid)
                if os.path.exists(cmdline):
                    with open(cmdline, "rb") as fh:
                        self.assertNotIn(token.encode(), fh.read())
                self.assertNotIn(token, " ".join(argv))
                p.stdin.write(b'{"control": "rotate"}\n')
                p.stdin.flush()
                rotated = json.loads(p.stdout.readline())["token"]
            finally:
                _, err = p.communicate(timeout=10)
            self.assertEqual(p.returncode, 0, err)
            logged = err
            for root, _, files in os.walk(os.path.join(d, "cache")):
                for f in files:
                    with open(os.path.join(root, f), "rb") as fh:
                        logged += fh.read()
            for t in (token, rotated):
                self.assertNotIn(t.encode(), logged)

    def test_there_is_no_token_option(self):
        import contextlib
        err = StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(ac.web_dashboard_main(["--token", "x" * 43]), 2)
        self.assertIn("--token-file <path>", err.getvalue())


class WebPageTests(unittest.TestCase):
    def test_csp_hashes_match_the_inline_script_and_style(self):
        page = ac._WEB_PAGE.decode("utf-8")
        script = re.search(r"<script>(.*)</script>", page, re.S).group(1)
        style = re.search(r"<style>(.*)</style>", page, re.S).group(1)
        for text in (script, style):
            digest = base64.b64encode(hashlib.sha256(text.encode("utf-8")).digest()).decode()
            self.assertIn("'sha256-" + digest + "'", ac.WEB_CSP)
        self.assertNotIn("unsafe-inline", ac.WEB_CSP)
        self.assertIn("default-src 'none'", ac.WEB_CSP)
        self.assertIn("connect-src 'self'", ac.WEB_CSP)

    def test_rows_are_built_as_text(self):
        script = ac._WEB_SCRIPT
        self.assertNotIn("innerHTML", script)
        self.assertNotIn("insertAdjacentHTML", script)
        self.assertNotIn("document.write", script)
        self.assertIn("textContent", script)


if __name__ == "__main__":
    unittest.main()
