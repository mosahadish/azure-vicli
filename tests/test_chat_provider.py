"""Unit tests for the provider side of the chat panel: `--wi-edit
create-branch` (WorkItemActions._wi_create_branch, against a fake fetch) and
the `--mcp` relay (mcp_handle / mcp_serve against a fake bridge, plus one
real TCP round trip through _bridge_call)."""
import io
import json
import socket
import threading
import unittest
from io import StringIO
from unittest import mock

from test_work_items import FakeFetch, ac, make_actions

REPO = "https://dev.azure.com/org/proj/_apis/git/repositories/widgets"
REFS = REPO + "/refs?filter=heads/develop"
WI = "https://dev.azure.com/example-org/_apis/wit/workitems/3001"
SHA = "a" * 40


def branch_fetch(created=True):
    return FakeFetch(responses={
        REPO: {"id": "repo-guid", "project": {"id": "proj-guid"}},
        REFS: {"value": [{"name": "refs/heads/develop-old", "objectId": "b" * 40},
                         {"name": "refs/heads/develop", "objectId": SHA}]},
        REPO + "/refs": {"value": [{"name": "refs/heads/feature/3001-x", "success": created,
                                    "updateStatus": "succeeded" if created else "createBranchPermissionRequired"}]},
        WI: {"fields": {}},
    })


class CreateBranchTests(unittest.TestCase):
    def run_edit(self, args, fetch):
        actions = make_actions()
        actions.fetch = fetch
        out, err = StringIO(), StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            rc = actions.cmd_wi_edit(args)
        return rc, out.getvalue(), err.getvalue()

    def test_creates_from_the_exact_branch_and_links_it(self):
        fetch = branch_fetch()
        rc, out, _ = self.run_edit(["create-branch", "3001", "https://dev.azure.com/org", "proj", "widgets",
                                    "develop", "refs/heads/feature/3001-x"], fetch)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out), {"branch": "feature/3001-x", "objectId": SHA, "linked": 3001})
        post = next(c for c in fetch.calls if c["method"] == "POST")
        self.assertEqual(post["url"], REPO + "/refs")
        # Not develop-old: filter= is a prefix match, the exact name wins.
        self.assertEqual(post["data"], [{"name": "refs/heads/feature/3001-x", "oldObjectId": "0" * 40, "newObjectId": SHA}])
        patch = fetch.calls[-1]
        self.assertEqual(patch["method"], "PATCH")
        self.assertEqual(patch["content_type"], "application/json-patch+json")
        rel = patch["data"][0]["value"]
        self.assertEqual(rel, {"rel": "ArtifactLink", "attributes": {"name": "Branch"},
                               "url": "vstfs:///Git/Ref/proj-guid%2Frepo-guid%2FGBfeature%2F3001-x"})

    def test_no_work_item_means_no_link(self):
        fetch = branch_fetch()
        rc, out, _ = self.run_edit(["create-branch", "0", "https://dev.azure.com/org", "proj", "widgets",
                                    "develop", "feature/3001-x"], fetch)
        self.assertEqual(rc, 0)
        self.assertIsNone(json.loads(out)["linked"])
        self.assertFalse(any(c["method"] == "PATCH" for c in fetch.calls))

    def test_unknown_source_branch(self):
        fetch = branch_fetch()
        fetch.responses[REFS] = {"value": [{"name": "refs/heads/develop-old", "objectId": "b" * 40}]}
        rc, _, err = self.run_edit(["create-branch", "3001", "https://dev.azure.com/org", "proj", "widgets",
                                    "develop", "feature/3001-x"], fetch)
        self.assertEqual(rc, 1)
        self.assertIn("branch 'develop' not found in widgets", err)

    def test_a_rejected_update_is_reported(self):
        rc, _, err = self.run_edit(["create-branch", "3001", "https://dev.azure.com/org", "proj", "widgets",
                                    "develop", "feature/3001-x"], branch_fetch(created=False))
        self.assertEqual(rc, 1)
        self.assertIn("createBranchPermissionRequired", err)

    def test_a_failed_link_still_reports_the_branch(self):
        fetch = branch_fetch()
        fetch.raise_for[WI] = ac.AdoHttpError(400, WI, b'{"message": "nope"}')
        rc, out, _ = self.run_edit(["create-branch", "3001", "https://dev.azure.com/org", "proj", "widgets",
                                    "develop", "feature/3001-x"], fetch)
        self.assertEqual(rc, 0)
        res = json.loads(out)
        self.assertEqual(res["branch"], "feature/3001-x")
        self.assertIsNone(res["linked"])
        self.assertTrue(res["linkError"])

    def test_needs_every_argument(self):
        rc, _, err = self.run_edit(["create-branch", "3001", "https://dev.azure.com/org", "proj", "widgets", "", "x"],
                                   branch_fetch())
        self.assertEqual(rc, 1)
        self.assertIn("create-branch needs", err)


class McpHandleTests(unittest.TestCase):
    def setUp(self):
        self.sent = []

        def bridge(payload):
            self.sent.append(payload)
            if payload["method"] == "list":
                return {"tools": [{"name": "current_view", "description": "d", "inputSchema": {"type": "object"}}]}
            if payload["name"] == "boom":
                return {"text": "it broke", "error": True}
            return {"text": json.dumps({"screen": "PR dashboard"})}
        self.bridge = bridge

    def handle(self, msg):
        return ac.mcp_handle(msg, self.bridge)

    def test_initialize_echoes_the_protocol_version(self):
        r = self.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}})
        self.assertEqual(r["id"], 1)
        self.assertEqual(r["result"]["protocolVersion"], "2024-11-05")
        self.assertEqual(r["result"]["serverInfo"]["name"], "azure-vicli")
        self.assertIn("tools", r["result"]["capabilities"])

    def test_notifications_get_no_answer(self):
        self.assertIsNone(self.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_tools_list_and_call_are_relayed(self):
        r = self.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual(r["result"]["tools"][0]["name"], "current_view")
        r = self.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                         "params": {"name": "current_view", "arguments": {"x": 1}}})
        self.assertEqual(self.sent[-1], {"method": "call", "name": "current_view", "arguments": {"x": 1}})
        self.assertEqual(r["result"]["content"], [{"type": "text", "text": '{"screen": "PR dashboard"}'}])
        self.assertFalse(r["result"]["isError"])

    def test_a_tool_error_is_a_tool_result_not_a_protocol_error(self):
        r = self.handle({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "boom"}})
        self.assertTrue(r["result"]["isError"])
        self.assertEqual(r["result"]["content"][0]["text"], "it broke")

    def test_an_unreachable_bridge(self):
        def down(_):
            raise OSError("connection refused")
        r = ac.mcp_handle({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "x"}}, down)
        self.assertTrue(r["result"]["isError"])
        self.assertIn("not reachable", r["result"]["content"][0]["text"])
        r = ac.mcp_handle({"jsonrpc": "2.0", "id": 6, "method": "tools/list"}, down)
        self.assertEqual(r["error"]["code"], -32000)

    def test_unknown_method_and_bad_messages(self):
        self.assertEqual(self.handle({"jsonrpc": "2.0", "id": 7, "method": "nope"})["error"]["code"], -32601)
        self.assertEqual(self.handle({"id": 8, "method": "ping"})["error"]["code"], -32600)
        self.assertEqual(self.handle({"jsonrpc": "2.0", "id": 9, "method": "ping"})["result"], {})

    def test_serve_answers_each_line(self):
        stdin = io.BytesIO(b'{"jsonrpc":"2.0","id":1,"method":"ping"}\n\nnot json\n'
                           b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
                           b'{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n')
        out = StringIO()
        self.assertEqual(ac.mcp_serve(stdin, out, self.bridge), 0)
        answers = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertEqual(sorted(str(a.get("id")) for a in answers), ["1", "2", "None"])
        self.assertTrue(any(a.get("error", {}).get("code") == -32700 for a in answers))


class BridgeCallTests(unittest.TestCase):
    def test_round_trip_with_the_token(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        got = {}

        def serve_one():
            conn, _ = srv.accept()
            data = b""
            while not data.endswith(b"\n"):
                data += conn.recv(4096)
            got.update(json.loads(data))
            conn.sendall(b'{"text": "hi"}\n')
            conn.close()
        t = threading.Thread(target=serve_one)
        t.start()
        res = ac._bridge_call({"method": "list"}, env={"AZVICLI_CHAT_BRIDGE": "127.0.0.1:{0}".format(port),
                                                     "AZVICLI_CHAT_TOKEN": "secret"})
        t.join()
        srv.close()
        self.assertEqual(res, {"text": "hi"})
        self.assertEqual(got, {"method": "list", "token": "secret"})

    def test_no_bridge_configured(self):
        with self.assertRaises(OSError):
            ac._bridge_call({"method": "list"}, env={})


if __name__ == "__main__":
    unittest.main()
