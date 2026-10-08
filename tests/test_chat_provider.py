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
import test_pr_actions as tpa

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


class DeleteBranchTests(unittest.TestCase):
    REFS2 = REPO + "/refs?filter=heads/feature/3001-x"

    def run_edit(self, args, fetch):
        actions = make_actions()
        actions.fetch = fetch
        out, err = StringIO(), StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            rc = actions.cmd_wi_edit(args)
        return rc, out.getvalue(), err.getvalue()

    def fetch(self, tip=SHA):
        return FakeFetch(responses={
            self.REFS2: {"value": [{"name": "refs/heads/feature/3001-x", "objectId": tip}]},
            REPO + "/refs": {"value": [{"success": True, "updateStatus": "succeeded"}]},
        })

    def test_deletes_with_an_all_zero_new_object(self):
        fetch = self.fetch()
        rc, out, _ = self.run_edit(["delete-branch", "https://dev.azure.com/org", "proj", "widgets", "feature/3001-x", SHA], fetch)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out), {"deleted": "feature/3001-x"})
        post = fetch.calls[-1]
        self.assertEqual(post["data"], [{"name": "refs/heads/feature/3001-x", "oldObjectId": SHA, "newObjectId": "0" * 40}])

    def test_refuses_once_someone_pushed(self):
        rc, _, err = self.run_edit(["delete-branch", "https://dev.azure.com/org", "proj", "widgets", "feature/3001-x", SHA],
                                   self.fetch(tip="c" * 40))
        self.assertEqual(rc, 1)
        self.assertIn("has moved", err)


class ChatPrActionTests(unittest.TestCase):
    PR = "https://dev.azure.com/org/proj/_apis/git/repositories/myrepo/pullRequests/42"
    BUILD = "https://dev.azure.com/org/proj/_apis/build/builds/77"

    def run_action(self, method, *args, responses=None, raise_for=None):
        actions = tpa.make_actions()
        actions.fetch = tpa.FakeFetch(responses=responses, raise_for=raise_for)
        out, err = StringIO(), StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            rc = getattr(actions, method)(*args)
        return rc, out.getvalue(), err.getvalue(), actions.fetch

    def test_build_log_reads_failed_records_and_their_log_tails(self):
        timeline = {"records": [
            {"name": "Build", "type": "Task", "result": "succeeded", "log": {"id": 1}},
            {"name": "Test", "type": "Task", "result": "failed", "log": {"id": 2},
             "issues": [{"type": "error", "message": "boom"}, {"type": "warning", "message": "meh"}]},
            {"name": "Job", "type": "Job", "result": "failed", "issues": []},
        ]}
        log = "\n".join("line {0}".format(i) for i in range(200)).encode()
        rc, out, _, fetch = self.run_action("build_log", "77", responses={
            self.BUILD + "/timeline": timeline, self.BUILD + "/logs/2": log})
        self.assertEqual(rc, 0)
        res = json.loads(out)
        self.assertEqual([f["name"] for f in res["failed"]], ["Test", "Job"])
        self.assertEqual(res["failed"][0]["issues"], ["boom"])
        tail = res["failed"][0]["log"].splitlines()
        self.assertEqual((len(tail), tail[-1]), (120, "line 199"))
        self.assertNotIn("log", res["failed"][1])
        self.assertTrue(fetch.calls[1]["raw"])

    def test_build_log_json_lines_body(self):
        rc, out, _, _ = self.run_action("build_log", "77", responses={
            self.BUILD + "/timeline": {"records": [{"name": "T", "type": "Task", "result": "failed", "log": {"id": 3}}]},
            self.BUILD + "/logs/3": json.dumps({"count": 2, "value": ["a", "b"]}).encode()})
        self.assertEqual(json.loads(out)["failed"][0]["log"], "a\nb")

    def test_build_log_needs_a_number(self):
        self.assertEqual(self.run_action("build_log", "x")[0], 1)

    def test_add_reviewer_searches_identities_on_vssps_then_puts(self):
        ident = "https://vssps.dev.azure.com/org/_apis/identities?searchFilter=General&filterValue=Bob%20Brown&queryMembership=None"
        rc, out, _, fetch = self.run_action("add_reviewer", "Bob Brown", "true", responses={
            ident: {"value": [{"id": "bob-id", "providerDisplayName": "Bob Brown"},
                              {"id": "grp", "providerDisplayName": "[x]\\Team", "isContainer": True}]}})
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["added"], "Bob Brown")
        put = fetch.calls[-1]
        self.assertEqual((put["method"], put["url"], put["data"]), ("PUT", self.PR + "/reviewers/bob-id",
                                                                     {"vote": 0, "isRequired": True}))

    def test_add_reviewer_on_server_uses_the_collection(self):
        actions = tpa.make_actions(env_overrides={"AZVICLI_ORG": "https://tfs.example.org/tfs/Coll"})
        self.assertEqual(actions._identities_base(), "https://tfs.example.org/tfs/Coll")

    def test_add_reviewer_ambiguous(self):
        ident = "https://vssps.dev.azure.com/org/_apis/identities?searchFilter=General&filterValue=B&queryMembership=None"
        rc, _, err, _ = self.run_action("add_reviewer", "B", responses={ident: {"value": [
            {"id": "1", "providerDisplayName": "Bob"}, {"id": "2", "providerDisplayName": "Bea"}]}})
        self.assertEqual(rc, 1)
        self.assertIn("2 people match 'B': Bob, Bea", err)

    def test_set_description(self):
        rc, _, _, fetch = self.run_action("set_description", "New text")
        self.assertEqual(rc, 0)
        self.assertEqual((fetch.calls[0]["method"], fetch.calls[0]["url"], fetch.calls[0]["data"]),
                         ("PATCH", self.PR, {"description": "New text"}))

    def test_create_pr_links_work_items(self):
        url = "https://dev.azure.com/org/proj/_apis/git/repositories/myrepo/pullrequests"
        rc, out, _, fetch = self.run_action("create_pr", "feature/x", "develop", "Title", "Body", "3001, 3002,x", "true",
                                            responses={url: {"pullRequestId": 99}})
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["id"], 99)
        body = fetch.calls[0]["data"]
        self.assertEqual(body["sourceRefName"], "refs/heads/feature/x")
        self.assertEqual(body["targetRefName"], "refs/heads/develop")
        self.assertEqual(body["workItemRefs"], [{"id": "3001"}, {"id": "3002"}])
        self.assertTrue(body["isDraft"])

    def test_create_pr_needs_branches_and_a_title(self):
        self.assertEqual(self.run_action("create_pr", "a", "", "t")[0], 1)

    def test_get_pr_by_id_alone_prints_a_dashboard_record(self):
        url = "https://dev.azure.com/org/proj/_apis/git/pullrequests/42"
        pr = {"pullRequestId": 42, "title": "Fix it", "status": "active", "repository": {"name": "other-repo"},
              "sourceRefName": "refs/heads/feature/x", "targetRefName": "refs/heads/develop",
              "createdBy": {"displayName": "Bob"}, "creationDate": "2026-10-01T10:00:00Z", "reviewers": []}
        rc, out, _, fetch = self.run_action("get_pr", responses={url: pr})
        self.assertEqual(rc, 0)
        self.assertEqual(fetch.calls[0]["url"], url)
        rec = json.loads(out)
        self.assertEqual((rec["id"], rec["repo"], rec["source"], rec["target"], rec["author"], rec["state"]),
                         (42, "other-repo", "feature/x", "develop", "Bob", "active"))
        self.assertEqual((rec["org"], rec["project"]), ("https://dev.azure.com/org", "proj"))

    def test_get_pr_failure(self):
        url = "https://dev.azure.com/org/proj/_apis/git/pullrequests/42"
        rc, _, err, _ = self.run_action("get_pr", raise_for={url: ac.AdoHttpError(404, url, b"not found")})
        self.assertEqual(rc, 1)
        self.assertIn("HTTP 404", err)


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

    def test_a_non_utf8_byte_in_the_answer_is_replaced_not_fatal(self):
        # A PR comment or similar text azure-vicli only relayed can carry a
        # byte that isn't valid UTF-8 (e.g. azure-vicli #50213's
        # get_pr_threads: a lone 0x97, a Windows-1252 em dash upstream) -
        # this used to raise UnicodeDecodeError and surface as "azure-vicli
        # is not reachable" for the whole tool call instead of just that
        # one character.
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        def serve_one():
            conn, _ = srv.accept()
            data = b""
            while not data.endswith(b"\n"):
                data += conn.recv(4096)
            conn.sendall(b'{"text": "an em dash \x97 here"}\n')
            conn.close()
        t = threading.Thread(target=serve_one)
        t.start()
        res = ac._bridge_call({"method": "call"}, env={"AZVICLI_CHAT_BRIDGE": "127.0.0.1:{0}".format(port),
                                                     "AZVICLI_CHAT_TOKEN": "secret"})
        t.join()
        srv.close()
        self.assertIn("an em dash", res["text"])
        self.assertIn("\ufffd", res["text"])


if __name__ == "__main__":
    unittest.main()
