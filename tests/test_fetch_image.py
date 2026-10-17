#!/usr/bin/env python3
"""Tests for --fetch-image (#134): an image in a PR's description or a
comment is downloaded with the PAT or token only from the PR's own server,
never sends the credential to another host (directly or through a
redirect), never logs it, and lands in a 0600 file named from its
Content-Type. Against two real HTTP servers on 127.0.0.1 - "own" and
"foreign", different ports, so different origins - never the network.
"""

import contextlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import stat
import tempfile
import threading
import types
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_image_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()
gh = ac.github()

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.seen.append((self.path, self.headers.get("Authorization")))
        if self.path.startswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", self.server.redirect_to)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        ctype, body, status = "image/png", PNG, 200
        if self.path.startswith("/page"):
            ctype, body = "text/html; charset=utf-8", b"<html>sign in</html>"
        elif self.path.startswith("/signin"):
            ctype, body, status = "image/png", PNG, 203
        elif self.path.startswith("/vector"):
            ctype, body = "image/svg+xml", b"<svg/>"
        elif self.path.startswith("/big"):
            body = PNG * 64
        elif self.path.startswith("/missing"):
            ctype, body, status = "text/plain", b"no", 404
        elif self.path.startswith("/photo"):
            ctype = "image/jpeg; q=1"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class _Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        http.server.ThreadingHTTPServer.__init__(self, ("127.0.0.1", 0), _Handler)
        self.seen = []
        self.redirect_to = ""
        threading.Thread(target=self.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()

    def handle_error(self, request, client_address):
        pass  # a refused download closes its connection mid-body - expected here

    @property
    def base(self):
        return "http://127.0.0.1:{0}".format(self.server_address[1])

    def url(self, path):
        return self.base + path

    def stop(self):
        self.shutdown()
        self.server_close()


def _env_without_proxies():
    return {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}


class FetchTestCase(unittest.TestCase):
    def setUp(self):
        ac._pool_close_all()
        self.own = _Server()
        self.foreign = _Server()
        self.dir = tempfile.mkdtemp()
        with mock.patch.dict(os.environ, _env_without_proxies(), clear=True):
            opener = ac.pooled_opener()
        patcher = mock.patch.object(ac.urllib.request, "urlopen", opener.open)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        ac._pool_close_all()
        self.own.stop()
        self.foreign.stop()
        shutil.rmtree(self.dir, ignore_errors=True)

    def stem(self, name="img"):
        return os.path.join(self.dir, name)

    def ado(self):
        actions = ac.PrActions(None, {"AZVICLI_ORG": self.own.url("/tfs/Coll"), "AZVICLI_PROJECT": "P",
                                      "AZVICLI_REPO": "r", "AZVICLI_PR": "1"})
        actions.pat = "s3cret-pat"
        return actions

    def run_action(self, fn, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fn(*args)
        return code, out.getvalue(), err.getvalue()


class AdoTests(FetchTestCase):
    def test_own_host_downloads_with_the_pat(self):
        code, out, _err = self.run_action(self.ado().fetch_image, self.own.url("/tfs/Coll/_apis/a/img.png"), self.stem())
        self.assertEqual(code, 0)
        res = json.loads(out)
        self.assertEqual(res["path"], self.stem() + ".png")
        self.assertEqual(res["contentType"], "image/png")
        with open(res["path"], "rb") as f:
            self.assertEqual(f.read(), PNG)
        auth = self.own.seen[0][1]
        self.assertTrue(auth.startswith("Basic "))
        self.assertNotIn("s3cret-pat", out)

    @unittest.skipIf(os.name == "nt", "POSIX modes")
    def test_the_file_is_private(self):
        _code, out, _err = self.run_action(self.ado().fetch_image, self.own.url("/a.png"), self.stem())
        mode = stat.S_IMODE(os.stat(json.loads(out)["path"]).st_mode)
        self.assertEqual(mode & 0o077, 0)

    def test_a_foreign_host_gets_no_request_and_no_pat(self):
        code, out, err = self.run_action(self.ado().fetch_image, self.foreign.url("/a.png"), self.stem())
        self.assertEqual(code, ac.FETCH_IMAGE_FOREIGN)
        self.assertEqual(out, "")
        self.assertIn("not this PR's host", err)
        self.assertEqual(self.foreign.seen, [])
        self.assertEqual(self.own.seen, [])
        self.assertFalse(os.listdir(self.dir))

    def test_a_redirect_to_another_host_carries_no_pat(self):
        self.own.redirect_to = self.foreign.url("/a.png")
        code, _out, _err = self.run_action(self.ado().fetch_image, self.own.url("/redirect"), self.stem())
        self.assertEqual(code, 0)
        self.assertTrue(self.own.seen[0][1].startswith("Basic "))
        self.assertEqual(self.foreign.seen, [("/a.png", None)])

    def test_a_redirect_on_the_same_host_carries_no_pat_either(self):
        self.own.redirect_to = self.own.url("/a.png")
        self.run_action(self.ado().fetch_image, self.own.url("/redirect"), self.stem())
        self.assertEqual(self.own.seen[1], ("/a.png", None))

    def test_the_pat_never_reaches_the_perf_log(self):
        env = {"AZVICLI_DEBUG": "1", "AZVICLI_PREFETCH_DIR": self.dir}
        run = ac._perf_start("--fetch-image", env)
        try:
            self.run_action(self.ado().fetch_image, self.own.url("/a.png?sig=abc"), self.stem())
        finally:
            ac._perf_finish(run)
        with open(os.path.join(self.dir, "perf.log"), encoding="utf-8") as f:
            text = f.read()
        self.assertIn('"kind": "req"', text)
        self.assertNotIn("s3cret-pat", text)
        self.assertNotIn("Basic", text)
        self.assertNotIn("abc", text)


class RefusalTests(FetchTestCase):
    def fetch(self, path, **kw):
        return ac.fetch_image_to(self.own.url(path), self.stem(), "Basic x", **kw)

    def assertRefused(self, path, **kw):
        with self.assertRaises(ac.ImageFetchError):
            self.fetch(path, **kw)
        self.assertFalse(os.listdir(self.dir), "a refused download left a file behind")

    def test_html_is_refused(self):
        self.assertRefused("/page")

    def test_a_203_sign_in_answer_is_refused(self):
        self.assertRefused("/signin")

    def test_svg_is_refused(self):
        with self.assertRaises(ac.ImageFetchError) as cm:
            self.fetch("/vector")
        self.assertIn("SVG", str(cm.exception))

    def test_too_big_is_refused(self):
        self.assertRefused("/big", max_bytes=len(PNG) * 2)

    def test_http_errors_name_the_host_only(self):
        with self.assertRaises(ac.ImageFetchError) as cm:
            ac.fetch_image_to(self.own.url("/missing?sig=abc"), self.stem(), "Basic x")
        self.assertIn("HTTP 404", str(cm.exception))
        self.assertNotIn("abc", str(cm.exception))

    def test_the_extension_comes_from_the_content_type(self):
        path, ctype, _n = ac.fetch_image_to(self.own.url("/photo.png"), self.stem(), None)
        self.assertEqual((path, ctype), (self.stem() + ".jpg", "image/jpeg"))

    def test_an_existing_file_is_never_overwritten(self):
        with open(self.stem() + ".png", "wb") as f:
            f.write(b"mine")
        with self.assertRaises(ac.ImageFetchError):
            self.fetch("/a.png")
        with open(self.stem() + ".png", "rb") as f:
            self.assertEqual(f.read(), b"mine")

    @unittest.skipIf(not hasattr(os, "symlink") or os.name == "nt", "symlinks")
    def test_a_planted_symlink_is_not_followed(self):
        target = os.path.join(self.dir, "target")
        os.symlink(target, self.stem() + ".png")
        with self.assertRaises(ac.ImageFetchError):
            self.fetch("/a.png")
        self.assertFalse(os.path.exists(target))

    def test_a_relative_or_missing_destination_is_refused(self):
        with self.assertRaises(ac.ImageFetchError):
            ac.fetch_image_to(self.own.url("/a.png"), "img", None)
        with self.assertRaises(ac.ImageFetchError):
            ac.fetch_image_to(self.own.url("/a.png"), os.path.join(self.dir, "nope", "img"), None)
        self.assertEqual(self.own.seen, [])


class GitHubTests(FetchTestCase):
    def actions(self, api_url):
        account = types.SimpleNamespace(api_url=api_url)
        return gh.Actions(account, {"AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "1"},
                          client=gh.Client(api_url, "ghp_token"))

    def test_enterprise_host_downloads_with_the_token(self):
        a = self.actions(self.own.url("/api/v3"))
        code, _out, _err = self.run_action(a.fetch_image, self.own.url("/user-attachments/assets/x"), self.stem())
        self.assertEqual(code, 0)
        self.assertEqual(self.own.seen[0][1], "Bearer ghp_token")

    def test_a_foreign_host_gets_no_token(self):
        a = self.actions(self.own.url("/api/v3"))
        code, _out, _err = self.run_action(a.fetch_image, self.foreign.url("/x.png"), self.stem())
        self.assertEqual(code, ac.FETCH_IMAGE_FOREIGN)
        self.assertEqual(self.foreign.seen, [])

    def test_a_redirect_to_the_signed_url_carries_no_token(self):
        self.own.redirect_to = self.foreign.url("/signed.png?jwt=abc")
        a = self.actions(self.own.url("/api/v3"))
        code, _out, _err = self.run_action(a.fetch_image, self.own.url("/redirect"), self.stem())
        self.assertEqual(code, 0)
        self.assertEqual(self.foreign.seen, [("/signed.png?jwt=abc", None)])

    def test_github_com_origins(self):
        origins = gh.image_origins("https://api.github.com")
        on = lambda u: ac.image_url_on(u, origins)  # noqa: E731
        self.assertTrue(on("https://github.com/user-attachments/assets/1"))
        self.assertTrue(on("https://raw.githubusercontent.com/o/r/main/a.png"))
        self.assertFalse(on("https://private-user-images.githubusercontent.com/1/a.png?jwt=x"))
        self.assertFalse(on("http://github.com/a.png"))
        self.assertFalse(on("https://github.com.evil.example/a.png"))
        self.assertTrue(ac.image_url_on("https://ghe.corp/a.png", gh.image_origins("https://ghe.corp/api/v3")))
        self.assertFalse(ac.image_url_on("https://github.com/a.png", gh.image_origins("https://ghe.corp/api/v3")))


class OriginTests(unittest.TestCase):
    def test_exact_origin(self):
        own = ["https://tfs.example.org/tfs/Coll"]
        self.assertTrue(ac.image_url_on("https://TFS.example.org:443/tfs/Coll/_apis/x.png", own))
        self.assertFalse(ac.image_url_on("http://tfs.example.org/tfs/Coll/x.png", own))
        self.assertFalse(ac.image_url_on("https://tfs.example.org:8443/x.png", own))
        self.assertFalse(ac.image_url_on("https://tfs.example.org.evil.example/x.png", own))
        self.assertFalse(ac.image_url_on("https://user:pw@tfs.example.org/x.png", own))
        self.assertFalse(ac.image_url_on("file:///etc/passwd", own))
        self.assertFalse(ac.image_url_on("not a url", own))

    def test_dev_azure_com_needs_the_org(self):
        own = ["https://dev.azure.com/myorg"]
        self.assertTrue(ac.image_url_on("https://dev.azure.com/myorg/p/_apis/git/x.png", own))
        self.assertTrue(ac.image_url_on("https://dev.azure.com/MyOrg/p/x.png", own))
        self.assertFalse(ac.image_url_on("https://dev.azure.com/otherorg/p/x.png", own))
        self.assertFalse(ac.image_url_on("https://dev.azure.com/myorg/../otherorg/x.png", own))
        self.assertFalse(ac.image_url_on("https://dev.azure.com/myorg/%2e%2e/otherorg/x.png", own))
        self.assertFalse(ac.image_url_on("https://dev.azure.com/myorg", own))

    def test_dot_segments_are_refused(self):
        self.assertFalse(ac.image_url_on("https://tfs.example.org/a/../b.png", ["https://tfs.example.org"]))


if __name__ == "__main__":
    unittest.main()
