"""Unit tests for the phone dashboard's server (#97): `--web-dashboard`
(web_page_json, web_bind_allowed, web_dashboard_serve) - what the page JSON
keeps, which binds are refused, and the server's token, cookie, GET-only and
header rules over real HTTP."""
import base64
import hashlib
import http.client
import json
import re
import socket
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
