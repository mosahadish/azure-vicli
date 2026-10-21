#!/usr/bin/env python3
"""Unit tests for github_rest.py: github_host.py's queries answered from
GitHub's REST API where GraphQL is refused.

No network: Client.fetch is swapped for a fake that turns GraphQL away the
way a REST-only proxy does and answers REST paths from a route table.
"""

import contextlib
import importlib.util
import io
import json
import os
import re
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_github_rest_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()
gh = ac.github()
rest = gh.rest()

API = "https://api.github.com"
REFUSED = json.dumps({"message": "GitHub GraphQL is not available from Claude Code sessions; use the REST API"})


class RestClient(gh.Client):
    """GraphQL answers 403 (`graphql_error` to change that); REST answers
    from `routes`: (method, path regex) -> answer, or a callable taking
    (match, data) - an exception it returns is raised."""

    def __init__(self, routes, graphql_error=(403, REFUSED)):
        gh.Client.__init__(self, API, "t")
        self.routes = routes
        self.calls = []

        def fetch(method, url, token, data):
            self.calls.append((method, url[len(API):], data))
            if url.endswith("/graphql"):
                raise gh.GitHubHttpError(graphql_error[0], url, graphql_error[1])
            path = url[len(API):]
            for (m, pat), ans in self.routes.items():
                hit = re.match(pat + r"(?:[?&].*)?$", path)
                if m == method and hit:
                    out = ans(hit, data) if callable(ans) else ans
                    if isinstance(out, Exception):
                        raise out
                    return out
            raise AssertionError("unexpected {0} {1}".format(method, path))
        self.fetch = fetch

    def sent(self, method, pat):
        return [d for m, p, d in self.calls if m == method and re.match(pat + r"(?:[?&].*)?$", p)]


def http_error(status, body="{}"):
    return gh.GitHubHttpError(status, API, body)


def pull(number=7, **kw):
    p = {"number": number, "title": "PR %d" % number, "html_url": "https://github.com/o/r/pull/%d" % number,
         "body": "", "draft": False, "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-02T00:00:00Z",
         "state": "open", "merged_at": None, "mergeable": True, "mergeable_state": "clean",
         "head": {"ref": "feature", "sha": "abc", "repo": {"full_name": "o/r"}},
         "base": {"ref": "main", "repo": {"full_name": "o/r"}},
         "user": {"login": "alice"}, "requested_reviewers": [], "requested_teams": [], "auto_merge": None}
    p.update(kw)
    return p


REPO = {"html_url": "https://github.com/o/r", "allow_merge_commit": True, "allow_squash_merge": True,
        "allow_rebase_merge": False, "allow_auto_merge": True, "delete_branch_on_merge": False,
        "default_branch": "main"}


def base_routes(extra=None):
    routes = {
        ("GET", r"/user"): {"login": "me", "name": "Me"},
        ("GET", r"/users/(\w+)"): lambda m, d: {"login": m.group(1), "name": m.group(1).title() + " Person",
                                                "type": "User"},
        ("GET", r"/repos/o/r"): REPO,
        ("GET", r"/repos/o/r/pulls/7"): pull(),
        ("GET", r"/repos/o/r/pulls/7/reviews"): [],
        ("GET", r"/repos/o/r/commits/abc/check-runs"): {"check_runs": [
            {"name": "ci", "status": "completed", "conclusion": "success"}]},
        ("GET", r"/repos/o/r/commits/abc/status"): {"statuses": []},
        ("GET", r"/repos/o/r/branches/feature"): {"name": "feature"},
    }
    routes.update(extra or {})
    return routes


def env(**kw):
    e = {"AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "7"}
    e.update(kw)
    return e


def run(fn, *args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = fn(*args)
    return code, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        gh._rest_hosts.clear()
        for cache in (rest._names, rest._repos, rest._nodes, rest._rollups, rest._pending):
            cache.clear()
        gh._threads_cache.clear()
        patcher = mock.patch.dict(os.environ, {}, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)
        for k in ("AZVICLI_GITHUB_REST", "AZVICLI_GITHUB_REPOS"):
            os.environ.pop(k, None)


class SwitchTests(Base):
    def test_a_refused_graphql_switches_the_host_to_rest(self):
        c = RestClient(base_routes())
        self.assertEqual(c.graphql("query { viewer { login name } }")["viewer"]["login"], "me")
        self.assertTrue(gh.rest_only(API))
        c.calls.clear()
        c.graphql("query { viewer { login name } }")
        self.assertFalse(any(p.endswith("/graphql") for _, p, _ in c.calls), "GraphQL isn't asked again")

    def test_a_rate_limit_or_bad_token_is_not_a_refusal(self):
        for status, body in ((403, '{"message": "API rate limit exceeded (graphql)"}'),
                             (401, '{"message": "Bad credentials"}')):
            gh._rest_hosts.clear()
            c = RestClient(base_routes(), graphql_error=(status, body))
            with self.assertRaises(gh.GitHubHttpError):
                c.graphql("query { viewer { login name } }")
            self.assertFalse(gh.rest_only(API))

    def test_the_env_var_starts_in_rest(self):
        os.environ["AZVICLI_GITHUB_REST"] = "1"
        c = RestClient(base_routes())
        c.graphql("query { viewer { login name } }")
        self.assertFalse(any(p.endswith("/graphql") for _, p, _ in c.calls))

    def test_a_query_without_a_builder_says_graphql_is_needed(self):
        c = RestClient(base_routes())
        with self.assertRaises(gh.GraphQLUnavailable):
            c.graphql("query { viewer { projectsV2(first: 1) { nodes { id } } } }")


class ListTests(Base):
    def test_search_hits_become_pr_nodes_with_reviewers_votes_and_checks(self):
        p = pull(requested_reviewers=[{"login": "bob"}], requested_teams=[{"slug": "core", "name": "Core"}],
                 user={"login": "alice"}, mergeable=False, mergeable_state="dirty")
        routes = base_routes({
            ("GET", r"/search/issues"): lambda m, d: {"items": [
                {"url": API + "/repos/o/r/issues/7", "pull_request": {}, "updated_at": "u1"}]},
            ("GET", r"/repos/o/r/pulls/7"): p,
            ("GET", r"/repos/o/r/pulls/7/reviews"): [
                {"user": {"login": "carol"}, "state": "APPROVED", "commit_id": "abc"},
                {"user": {"login": "dave"}, "state": "CHANGES_REQUESTED"},
                {"user": {"login": "dave"}, "state": "DISMISSED"}],
        })
        c = RestClient(routes)
        data = c.graphql(gh.LIST_QUERY, gh.search_queries(""))
        node = data["requested"]["nodes"][0]
        ado = gh.ado_pr(node)
        votes = {r["id"]: r["vote"] for r in ado["reviewers"]}
        self.assertEqual(votes, {"team:core": 0, "bob": 0, "carol": 10, "dave": 0})
        self.assertEqual(ado["mergeStatus"], "conflicts")
        self.assertEqual(ado["createdBy"], {"id": "alice", "displayName": "Alice Person"})
        self.assertEqual(node["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["state"], "SUCCESS")
        self.assertEqual(gh.merge_methods(node["repository"])[-1]["key"], "merge")

    def test_a_gone_branch_has_no_head_ref_but_a_fork_is_left_alone(self):
        routes = base_routes({("GET", r"/repos/o/r/branches/feature"): http_error(404)})
        c = RestClient(routes)
        self.assertIsNone(rest.pr_node(c, "o", "r", 7, check_branch=True)["headRef"])
        rest._nodes.clear()
        routes[("GET", r"/repos/o/r/pulls/7")] = pull(head={"ref": "main", "sha": "abc",
                                                            "repo": {"full_name": "fork/r"}})
        node = rest.pr_node(c, "o", "r", 7, check_branch=True)
        self.assertTrue(node["isCrossRepository"])
        self.assertEqual(node["headRef"], {"name": "main"})

    def test_search_refused_lists_each_known_repository(self):
        os.environ["AZVICLI_GITHUB_REPOS"] = "o/r"
        routes = base_routes({
            ("GET", r"/search/issues"): http_error(403, '{"message": "not available"}'),
            ("GET", r"/repos/o/r/pulls"): [pull(7, user={"login": "me"}),
                                           pull(8, requested_reviewers=[{"login": "me"}]),
                                           pull(9), pull(10)],
            ("GET", r"/repos/o/r/pulls/(8|9|10)"): lambda m, d: pull(int(m.group(1))),
            ("GET", r"/repos/o/r/pulls/(8|10)/reviews"): [],
            ("GET", r"/repos/o/r/pulls/9/reviews"): [{"user": {"login": "me"}, "state": "COMMENTED"}],
        })
        c = RestClient(routes)
        data = c.graphql(gh.LIST_QUERY, gh.search_queries(""))
        got = {a: [n["number"] for n in data[a]["nodes"]] for a in ("requested", "reviewed", "created")}
        self.assertEqual(got, {"requested": [8], "reviewed": [9], "created": [7]})

    def test_known_repositories_are_the_clones_on_this_host_under_the_owner(self):
        import tempfile
        import subprocess
        with tempfile.TemporaryDirectory() as root:
            for name, url in (("a", "https://github.com/o/a.git"), ("b", "git@github.com:other/b.git"),
                              ("c", "https://ghe.example.com/o/c"), ("d", "ssh://git@github.com/O/d")):
                subprocess.run(["git", "init", "-q", os.path.join(root, name)], check=True)
                subprocess.run(["git", "-C", os.path.join(root, name), "remote", "add", "origin", url], check=True)
            c = RestClient(base_routes())
            c.account = mock.Mock(clones_dir=root, owner="o")
            self.assertEqual(rest.known_repositories(c), [("o", "a"), ("O", "d")])

    def test_list_records_reads_the_rest_answer_like_the_graphql_one(self):
        os.environ["AZVICLI_GITHUB_REPOS"] = "o/r"
        routes = base_routes({
            ("GET", r"/search/issues"): http_error(403, '{"message": "not available"}'),
            ("GET", r"/repos/o/r/pulls"): [pull(7, user={"login": "me"})],
            ("GET", r"/repos/o/r/pulls/7/comments"): [],
            ("GET", r"/repos/o/r/pulls/7/ccr/review_threads"): [],
            ("GET", r"/repos/o/r/issues/7/comments"): [],
        })
        c = RestClient(routes)
        recs = gh.list_records(ac.AccountConfig(host="github", owner="o"), env={}, client=c)
        self.assertEqual([(r["key"], r["state"], r["buildStatus"]) for r in recs],
                         [("o~r~7", "Created", "succeeded")])


class ThreadTests(Base):
    COMMENTS = [
        {"id": 1, "path": "a.py", "line": 5, "start_line": 3, "side": "RIGHT", "body": "first",
         "user": {"login": "bob"}, "created_at": "t1"},
        {"id": 2, "in_reply_to_id": 1, "path": "a.py", "body": "reply", "user": {"login": "me"},
         "created_at": "t2"},
        {"id": 3, "path": "b.py", "line": None, "original_line": 9, "side": "LEFT", "body": "old",
         "user": {"login": "bob"}, "created_at": "t3"},
        {"id": 4, "path": "c.py", "subject_type": "file", "line": None, "body": "file", "user": {"login": "bob"},
         "created_at": "t4"},
    ]

    def routes(self, ccr):
        return base_routes({
            ("GET", r"/repos/o/r/pulls/7/comments"): self.COMMENTS,
            ("GET", r"/repos/o/r/pulls/7/ccr/review_threads"): ccr,
            ("GET", r"/repos/o/r/issues/7/comments"): [{"id": 9, "body": "hi", "user": {"login": "bob"},
                                                        "created_at": "t0"}],
        })

    def test_review_comments_group_into_threads_with_the_conversation_last(self):
        c = RestClient(self.routes([{"isResolved": True, "comments": [{"id": 3}]}]))
        out = gh.fetch_threads(c, "o", "r", 7)
        first, old, file_, conv = out
        self.assertEqual((first["id"], [x["content"] for x in first["comments"]]), (1, ["first", "reply"]))
        self.assertEqual(first["threadContext"]["rightFileStart"]["line"], 3)
        self.assertEqual((first["status"], first["isOutdated"]), ("active", False))
        self.assertEqual((old["status"], old["isOutdated"]), ("fixed", True))
        self.assertIn("leftFileEnd", old["threadContext"])
        self.assertEqual(file_["threadContext"], {"filePath": "/c.py"})
        self.assertTrue(conv["conversation"])

    def test_the_proxy_routes_real_shape_marks_resolved_threads(self):
        # As Claude Code's proxy answers it (seen live on #138).
        c = RestClient(self.routes([{"resolved": True, "outdated": False, "path": "a.py", "line": 5,
                                     "comment_ids": [1, 2]},
                                    {"resolved": False, "outdated": True, "path": "b.py", "line": 9,
                                     "comment_ids": [3]}]))
        self.assertEqual([t["status"] for t in gh.fetch_threads(c, "o", "r", 7)],
                         ["fixed", "active", "active", "active"])

    def test_without_the_proxy_route_every_thread_reads_unresolved(self):
        c = RestClient(self.routes(http_error(404)))
        self.assertEqual({t["status"] for t in gh.fetch_threads(c, "o", "r", 7)}, {"active"})

    def test_resolving_goes_through_the_proxy_route_by_first_comment(self):
        routes = self.routes([])
        routes[("POST", r"/repos/o/r/pulls/7/ccr/comments/1/resolve")] = {}
        c = RestClient(routes)
        code, out, _ = run(gh.Actions(None, env(), c).set_thread_status, "1", "fixed")
        self.assertEqual((code, out.strip()), (0, "Thread 1 set to fixed."))

    def test_resolving_without_the_route_says_graphql_is_needed(self):
        routes = self.routes([])
        routes[("POST", r"/repos/o/r/pulls/7/ccr/comments/1/unresolve")] = http_error(404)
        c = RestClient(routes)
        with self.assertRaisesRegex(RuntimeError, "needs GitHub's GraphQL API"):
            gh.Actions(None, env(), c).set_thread_status("1", "active")


class IterationTests(Base):
    def test_commits_and_force_pushes_in_order_and_my_last_reviewed_commit(self):
        routes = base_routes({
            ("GET", r"/repos/o/r/pulls/7/commits"): [
                {"sha": "c1", "commit": {"committer": {"date": "2026-01-01"}}},
                {"sha": "c2", "commit": {"committer": {"date": "2026-01-03"}}}],
            ("GET", r"/repos/o/r/issues/7/events"): [
                {"event": "head_ref_force_pushed", "commit_id": "f1", "created_at": "2026-01-02"},
                {"event": "labeled"}],
            ("GET", r"/repos/o/r/pulls/7/reviews"): [
                {"user": {"login": "me"}, "state": "COMMENTED", "commit_id": "c1", "submitted_at": "2026-01-01"},
                {"user": {"login": "me"}, "state": "PENDING", "commit_id": "c2"}],
        })
        c = RestClient(routes)
        code, out, _ = run(gh.Actions(None, env(), c).iterations)
        got = json.loads(out)
        self.assertEqual([v["sourceRefCommit"]["commitId"] for v in got["value"]], ["c1", "f1", "c2"])
        self.assertEqual(got["myLastReviewSha"], "c1")


class ReviewTests(Base):
    def routes(self, extra=None):
        r = base_routes({
            ("GET", r"/repos/o/r/pulls/7/comments"): [{"id": 1, "path": "a.py", "line": 2, "body": "x",
                                                        "user": {"login": "bob"}}],
            ("GET", r"/repos/o/r/pulls/7/ccr/review_threads"): [],
            ("POST", r"/repos/o/r/pulls/7/reviews"): {"id": 50},
            ("POST", r"/repos/o/r/pulls/7/comments/1/replies"): {"id": 51},
            ("POST", r"/repos/o/r/pulls/7/comments"): {"id": 52},
        })
        r.update(extra or {})
        return r

    PAYLOAD = json.dumps({"event": "10", "body": "LGTM", "items": [
        ["--post", "a.py", "R", "3", "line note", "5"],
        ["--reply", "1", "agreed"],
        ["--file-comment", "b.py", "file note"]]})

    def test_line_comments_go_in_the_review_then_replies_and_file_comments(self):
        c = RestClient(self.routes())
        code, out, _ = run(gh.Actions(None, env(), c).submit_review, self.PAYLOAD)
        self.assertEqual((code, out.strip()), (0, "Review submitted (3 comments)."))
        review = c.sent("POST", r"/repos/o/r/pulls/7/reviews")[0]
        self.assertEqual((review["event"], review["body"], review["commit_id"]), ("APPROVE", "LGTM", "abc"))
        self.assertEqual(review["comments"], [{"path": "a.py", "body": "line note", "line": 5, "side": "RIGHT",
                                               "start_line": 3, "start_side": "RIGHT"}])
        self.assertEqual(c.sent("POST", r"/repos/o/r/pulls/7/comments/1/replies"), [{"body": "agreed"}])
        self.assertEqual(c.sent("POST", r"/repos/o/r/pulls/7/comments")[0]["subject_type"], "file")

    def test_nothing_is_posted_when_the_review_itself_fails(self):
        c = RestClient(self.routes({("POST", r"/repos/o/r/pulls/7/reviews"): http_error(422)}))
        with self.assertRaises(gh.GitHubHttpError):
            run(gh.Actions(None, env(), c).submit_review, self.PAYLOAD)
        self.assertEqual(c.sent("POST", r"/repos/o/r/pulls/7/comments/1/replies"), [])
        self.assertEqual(rest._pending, {})

    def test_a_reply_failing_after_the_review_is_reported_not_retried(self):
        c = RestClient(self.routes({("POST", r"/repos/o/r/pulls/7/comments/1/replies"): http_error(500)}))
        code, out, _ = run(gh.Actions(None, env(), c).submit_review, self.PAYLOAD)
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("Review submitted, but the review went in, but not: reply"), out)

    def test_a_pending_review_of_mine_on_github_is_refused(self):
        c = RestClient(self.routes({("GET", r"/repos/o/r/pulls/7/reviews"): [
            {"id": 3, "state": "PENDING", "user": {"login": "me"}}]}))
        with self.assertRaisesRegex(RuntimeError, "pending on GitHub"):
            run(gh.Actions(None, env(), c).submit_review, self.PAYLOAD)


class WriteTests(Base):
    def test_find_people_lists_the_assignees_but_the_author(self):
        c = RestClient(base_routes({
            ("GET", r"/repos/o/r/assignees"): [{"login": "alice"}, {"login": "bob"}],
        }))
        code, out, _ = run(gh.Actions(None, env(), c).find_people, "")
        self.assertEqual(code, 0)
        self.assertEqual([p["login"] for p in json.loads(out)], ["bob"])

    def test_an_organization_is_no_user(self):
        c = RestClient(base_routes({
            ("GET", r"/repos/o/r/assignees"): [],
            ("GET", r"/users/(\w+)"): lambda m, d: {"login": m.group(1), "name": "Acme Inc", "type": "Organization"},
        }))
        code, out, _ = run(gh.Actions(None, env(), c).find_people, "acme")
        self.assertEqual((code, json.loads(out)), (0, []))

    def test_add_reviewer_requests_by_login(self):
        routes = base_routes({
            ("GET", r"/repos/o/r/assignees"): [{"login": "bob"}, {"login": "carol"}],
            ("POST", r"/repos/o/r/pulls/7/requested_reviewers"): {},
        })
        c = RestClient(routes)
        code, out, _ = run(gh.Actions(None, env(), c).add_reviewer, "bob")
        self.assertEqual(json.loads(out), {"added": "Bob Person (bob)", "id": "bob"})
        self.assertEqual(c.sent("POST", r"/repos/o/r/pulls/7/requested_reviewers"), [{"reviewers": ["bob"]}])

    def test_add_reviewer_finds_a_team(self):
        routes = base_routes({
            ("GET", r"/repos/o/r/assignees"): [],
            ("GET", r"/orgs/o/teams/core"): {"slug": "core", "name": "Core"},
            ("POST", r"/repos/o/r/pulls/7/requested_reviewers"): {},
        })
        c = RestClient(routes)
        run(gh.Actions(None, env(), c).add_reviewer, "@o/core")
        self.assertEqual(c.sent("POST", r"/repos/o/r/pulls/7/requested_reviewers"), [{"team_reviewers": ["core"]}])

    def test_set_description_patches_body_and_title(self):
        routes = base_routes({("PATCH", r"/repos/o/r/pulls/7"): {}})
        c = RestClient(routes)
        code, out, _ = run(gh.Actions(None, env(), c).set_description, "new body", "New title")
        self.assertEqual(out.strip(), "Description updated.")
        self.assertEqual(c.sent("PATCH", r"/repos/o/r/pulls/7"), [{"body": "new body", "title": "New title"}])

    def test_work_items_are_the_bodys_closing_lines(self):
        routes = base_routes({
            ("GET", r"/repos/o/r/pulls/7"): pull(body="Fixes #3\ncloses other/x#4\nCloses #3\nmentions #5"),
            ("GET", r"/repos/o/r/issues/3"): {"number": 3, "title": "Bug", "state": "open",
                                              "html_url": "u3", "assignees": [{"login": "bob"}]},
            ("GET", r"/repos/other/x/issues/4"): {"number": 4, "title": "Other", "state": "closed",
                                                  "html_url": "u4", "assignees": []},
        })
        c = RestClient(routes)
        code, out, _ = run(gh.Actions(None, env(), c).work_items)
        got = [json.loads(l) for l in out.splitlines()]
        self.assertEqual([(g["key"], g["state"], g["assignedTo"]) for g in got],
                         [("o~r~3", "No Status", "bob"), ("other~x~4", "Closed", "")])


class MergeTests(Base):
    def test_merge_state_feeds_mergeability(self):
        routes = base_routes({("GET", r"/repos/o/r/pulls/7"): pull(mergeable_state="blocked"),
                                ("GET", r"/repos/o/r/commits/abc/check-runs"): {"check_runs": [
                                    {"name": "ci", "status": "completed", "conclusion": "failure"}]}})
        c = RestClient(routes)
        state = gh.mergeability(*gh.Actions(None, env(), c).merge_state(retry=False))
        self.assertEqual(state["blockers"], ["check `ci` failed"])
        self.assertEqual((state["autoMergeAllowed"], state["defaultBranch"]), (True, "main"))

    def test_a_draft_is_draft_not_blocked(self):
        routes = base_routes({("GET", r"/repos/o/r/pulls/7"): pull(draft=True, mergeable_state="blocked")})
        c = RestClient(routes)
        state = gh.mergeability(*gh.Actions(None, env(), c).merge_state(retry=False))
        self.assertEqual(state["blockers"], ["it's a draft"])

    def test_auto_merge_goes_through_the_proxy_route(self):
        routes = base_routes({("PUT", r"/repos/o/r/pulls/7/ccr/auto_merge"): {},
                                ("GET", r"/repos/o/r/pulls/7"): pull(mergeable_state="blocked")})
        c = RestClient(routes)
        code, out, _ = run(gh.Actions(None, env(), c).auto_merge, "on", "squash")
        self.assertEqual(code, 0)
        self.assertEqual(c.sent("PUT", r"/repos/o/r/pulls/7/ccr/auto_merge"),
                         [{"merge_method": "squash", "expected_head_oid": "abc"}])


if __name__ == "__main__":
    unittest.main()
