#!/usr/bin/env python3
"""Tests for azure-cli.py's keep-alive connection pool (#92): requests to one
host share a connection, a stale one is retried once for a read and never
for a write, proxies (HTTPS_PROXY's CONNECT tunnel, HTTP_PROXY, NO_PROXY)
still apply, and the perf log says new/reused. Against real sockets on
127.0.0.1 - a local HTTP/1.1 server and a local proxy - never the network.
"""

import base64
import http.server
import importlib.util
import json
import os
import shutil
import socket
import tempfile
import threading
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_pool_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()
gh = ac.github()


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _reply(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.server.seen.append((self.command, self.path))
        status = 404 if self.path.startswith("/missing") else 200
        body = json.dumps({"path": self.path}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if self.path.startswith("/close"):
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PATCH = _reply


class _Server(http.server.ThreadingHTTPServer):
    """Keep-alive HTTP/1.1 on 127.0.0.1 that counts the connections it
    accepted and the requests it answered (as a proxy too: an absolute URI
    shows up as the path)."""

    daemon_threads = True

    def __init__(self):
        http.server.ThreadingHTTPServer.__init__(self, ("127.0.0.1", 0), _Handler)
        self.seen = []
        self.socks = []
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def connections(self):
        return len(self.socks)

    def get_request(self):
        sock, addr = http.server.ThreadingHTTPServer.get_request(self)
        self.socks.append(sock)
        return sock, addr

    def drop_connections(self):
        """Closes every accepted connection from the server's side - what an
        idle timeout on the real server does."""
        for s in self.socks:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def url(self, path):
        return "http://127.0.0.1:{0}{1}".format(self.server_address[1], path)

    def stop(self):
        self.shutdown()
        self.server_close()


class _ConnectProxy(object):
    """Answers one CONNECT with 403 after recording its request line and
    headers - enough to see an https request was tunnelled, and with what."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.request = None
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        conn, _addr = self.sock.accept()
        with conn:
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            self.request = data.decode("latin-1")
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")

    def close(self):
        self.sock.close()


def _env_without_proxies(**extra):
    env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
    env.update(extra)
    return env


class PoolTestCase(unittest.TestCase):
    def setUp(self):
        ac._pool_close_all()
        vars(ac._http_local).pop("conn", None)
        self.server = _Server()
        with mock.patch.dict(os.environ, _env_without_proxies(), clear=True):
            self.opener = ac.pooled_opener()

    def tearDown(self):
        ac._pool_close_all()
        self.server.stop()

    def get(self, path, method="GET", data=None, opener=None):
        req = ac.urllib.request.Request(self.server.url(path), data=data, method=method)
        with (opener or self.opener).open(req, timeout=10) as resp:
            return resp.read()


class ReuseTests(PoolTestCase):
    def test_two_gets_to_one_host_share_one_connection(self):
        self.get("/a")
        self.assertEqual(ac._last_conn(), "new")
        self.get("/b")
        self.assertEqual(ac._last_conn(), "reused")
        self.assertEqual(self.server.connections, 1)
        self.assertEqual([p for _m, p in self.server.seen], ["/a", "/b"])

    def test_an_http_error_body_read_gives_the_connection_back(self):
        with self.assertRaises(ac.urllib.error.HTTPError) as cm:
            self.get("/missing")
        cm.exception.read()
        self.get("/b")
        self.assertEqual(self.server.connections, 1)

    def test_connection_close_is_not_pooled(self):
        self.get("/close")
        self.get("/b")
        self.assertEqual(ac._last_conn(), "new")
        self.assertEqual(self.server.connections, 2)

    def test_a_connection_the_server_closed_is_not_reused(self):
        self.get("/a")
        self.server.drop_connections()
        self.get("/b")
        self.assertEqual(ac._last_conn(), "new")
        self.assertEqual(self.server.connections, 2)

    def test_eight_threads_never_share_a_connection_at_once(self):
        errors = []

        def worker(n):
            try:
                for i in range(5):
                    body = json.loads(self.get("/t{0}-{1}".format(n, i)).decode("utf-8"))
                    if body["path"] != "/t{0}-{1}".format(n, i):
                        errors.append(body)
            except Exception as e:  # noqa: BLE001 - reported below
                errors.append(e)
        threads = [threading.Thread(target=worker, args=(n,)) for n in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        self.assertEqual(len(self.server.seen), 40)
        self.assertLessEqual(self.server.connections, 8)


class StaleRetryTests(PoolTestCase):
    """The server drops the idle connection and the liveness probe is
    bypassed, so the request really goes out on the dead socket."""

    def stale(self):
        self.get("/warm")
        self.server.drop_connections()
        return mock.patch.object(ac, "_conn_alive", lambda conn: True)

    def test_a_get_is_retried_once_on_a_fresh_connection(self):
        with self.stale():
            self.get("/again")
        self.assertEqual(ac._last_conn(), "new")
        self.assertEqual(self.server.connections, 2)
        self.assertEqual(self.server.seen, [("GET", "/warm"), ("GET", "/again")])

    def test_a_patch_is_never_retried(self):
        with self.stale(), self.assertRaises(ac.urllib.error.URLError):
            self.get("/wi", method="PATCH", data=b"[]")
        self.assertEqual(self.server.connections, 1)
        self.assertEqual(self.server.seen, [("GET", "/warm")])

    def test_a_post_is_never_retried(self):
        with self.stale(), self.assertRaises(ac.urllib.error.URLError):
            self.get("/comments", method="POST", data=b"{}")
        self.assertEqual(self.server.seen, [("GET", "/warm")])

    def test_a_graphql_query_is_retried_but_a_mutation_is_not(self):
        with mock.patch.object(gh.urllib.request, "urlopen", self.opener.open):
            with self.stale():
                gh.http("POST", self.server.url("/graphql"), "tok", {"query": "{ viewer { login } }"})
            self.assertEqual(self.server.seen[-1], ("POST", "/graphql"))
            self.server.drop_connections()
            with mock.patch.object(ac, "_conn_alive", lambda conn: True), \
                    self.assertRaises(ac.urllib.error.URLError):
                gh.http("POST", self.server.url("/graphql"), "tok",
                        {"query": "mutation { addComment(input: {}) { clientMutationId } }"})
        self.assertEqual([m for m, _p in self.server.seen], ["GET", "POST"])

    def test_graphql_read_detection(self):
        self.assertTrue(gh._graphql_read("https://api.github.com/graphql", {"query": "query { viewer { id } }"}))
        self.assertFalse(gh._graphql_read("https://api.github.com/graphql", {"query": "mutation M { x }"}))
        self.assertFalse(gh._graphql_read("https://api.github.com/graphql",
                                          {"query": "query A { x } mutation B { y }"}))
        self.assertFalse(gh._graphql_read("https://api.github.com/repos/o/r/issues", {"title": "query"}))


class ProxyTests(PoolTestCase):
    def test_https_goes_through_the_proxy_as_a_connect_tunnel_with_its_credentials(self):
        proxy = _ConnectProxy()
        try:
            env = _env_without_proxies(HTTPS_PROXY="http://user:pw@127.0.0.1:{0}".format(proxy.port))
            with mock.patch.dict(os.environ, env, clear=True):
                opener = ac.pooled_opener()
            with self.assertRaises(ac.urllib.error.URLError):
                opener.open("https://dev.azure.example/org/_apis/x", timeout=10)
        finally:
            proxy.close()
        lines = proxy.request.split("\r\n")
        self.assertEqual(lines[0], "CONNECT dev.azure.example:443 HTTP/1.1")
        auth = "Basic " + base64.b64encode(b"user:pw").decode("ascii")
        self.assertIn("Proxy-Authorization: " + auth, lines)

    def test_http_goes_through_the_proxy_and_no_proxy_bypasses_it(self):
        proxy = _Server()
        try:
            proxy_url = "http://127.0.0.1:{0}".format(proxy.server_address[1])
            with mock.patch.dict(os.environ, _env_without_proxies(HTTP_PROXY=proxy_url), clear=True):
                opener = ac.pooled_opener()
                self.get("/via", opener=opener)
            self.assertEqual(proxy.seen, [("GET", self.server.url("/via"))])
            self.assertEqual(self.server.seen, [])

            # NO_PROXY is read per request (urllib's proxy_bypass), not when
            # the opener is built.
            with mock.patch.dict(os.environ, _env_without_proxies(HTTP_PROXY=proxy_url, NO_PROXY="127.0.0.1"),
                                 clear=True):
                opener = ac.pooled_opener()
                self.get("/direct", opener=opener)
            self.assertEqual(len(proxy.seen), 1)
            self.assertEqual(self.server.seen, [("GET", "/direct")])
        finally:
            proxy.stop()


class InstallTests(unittest.TestCase):
    def test_no_pool_keeps_the_stock_opener(self):
        with mock.patch.object(ac.urllib.request, "install_opener") as install:
            self.assertFalse(ac.install_http_pool({"AZVICLI_NO_POOL": "1"}))
            install.assert_not_called()
            self.assertTrue(ac.install_http_pool({"AZVICLI_NO_POOL": "0"}))
            opener = install.call_args[0][0]
        kinds = [type(h) for h in opener.handlers]
        self.assertIn(ac.KeepAliveHTTPHandler, kinds)
        self.assertIn(ac.KeepAliveHTTPSHandler, kinds)
        self.assertNotIn(ac.urllib.request.HTTPHandler, kinds)
        self.assertNotIn(ac.urllib.request.HTTPSHandler, kinds)


class PerfTests(PoolTestCase):
    def test_perf_log_says_new_then_reused(self):
        log_dir = tempfile.mkdtemp()
        try:
            env = {"AZVICLI_DEBUG": "1", "AZVICLI_PREFETCH_DIR": log_dir}
            with mock.patch.object(ac.urllib.request, "urlopen", self.opener.open):
                run = ac._perf_start("--list", env)
                try:
                    ac.http_request(self.server.url("/org/_apis/a"), pat="p")
                    ac.http_request(self.server.url("/org/_apis/b"), pat="p")
                finally:
                    ac._perf_finish(run)
            with open(os.path.join(log_dir, "perf.log"), encoding="utf-8") as f:
                reqs = [e for e in (json.loads(l) for l in f if l.strip()) if e["kind"] == "req"]
            self.assertEqual([e["conn"] for e in reqs], ["new", "reused"])
        finally:
            shutil.rmtree(log_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
