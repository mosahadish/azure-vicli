#!/usr/bin/env python3
"""Unit tests for github_host.py, azure-cli.py's GitHub backend.

No network: Client.fetch is swapped for a fake that answers GraphQL by the
query's first field, the way test_provider.py fakes Azure DevOps.
"""

import contextlib
import importlib.util
import io
import json
import os
import unittest
from datetime import datetime, timedelta, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_github_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()
gh = ac.github()

NOW = datetime.now(timezone.utc)


def iso(days_ago=0):
    return (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def user(login, name=None):
    return {"login": login, "name": name}


def pr_node(number, **kw):
    node = {
        "number": number, "title": "PR %d" % number, "url": "https://github.com/o/r/pull/%d" % number,
        "body": "", "isDraft": False, "createdAt": iso(1), "updatedAt": iso(0), "state": "OPEN",
        "headRefName": "feature-%d" % number, "baseRefName": "main", "headRefOid": "abc",
        "isCrossRepository": False, "headRef": {"name": "feature-%d" % number},
        "repository": {"name": "r", "url": "https://github.com/o/r", "owner": {"login": "o"},
                       "mergeCommitAllowed": True, "squashMergeAllowed": True, "rebaseMergeAllowed": False,
                       "autoMergeAllowed": True},
        "author": user("alice", "Alice A"), "mergeable": "MERGEABLE", "autoMergeRequest": None,
        "reviewRequests": {"nodes": []}, "latestOpinionatedReviews": {"nodes": []},
        "latestReviews": {"nodes": []},
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]},
    }
    node.update(kw)
    return node


def requested(login, name=None):
    return {"nodes": [{"requestedReviewer": {"__typename": "User", "login": login, "name": name}}]}


def reviews(*pairs):
    return {"nodes": [{"state": s, "author": user(l)} for l, s in pairs]}


class FakeClient(gh.Client):
    """Answers each GraphQL query from `answers`, keyed by a word in it."""

    def __init__(self, answers):
        gh.Client.__init__(self, "https://api.github.com", "t")
        self.answers = answers
        self.queries = []

        def fetch(method, url, token, data):
            q = data["query"]
            self.queries.append((q, data.get("variables")))
            for word, ans in self.answers.items():
                if word in q:
                    return {"data": ans(data.get("variables")) if callable(ans) else ans}
            raise AssertionError("unexpected query: " + q[:80])
        self.fetch = fetch


def account(**kw):
    return ac.AccountConfig(host="github", **kw)


class UrlTests(unittest.TestCase):
    def test_graphql_url_for_github_com_and_enterprise(self):
        self.assertEqual(gh.graphql_url(None), "https://api.github.com/graphql")
        self.assertEqual(gh.graphql_url("https://ghe.example.com/api/v3/"), "https://ghe.example.com/api/graphql")

    def test_web_host_names_the_gh_login(self):
        self.assertEqual(gh.web_host("https://api.github.com"), "github.com")
        self.assertEqual(gh.web_host("https://ghe.example.com/api/v3"), "ghe.example.com")


class AdoPrTests(unittest.TestCase):
    def test_votes_from_reviews(self):
        node = pr_node(1, latestOpinionatedReviews=reviews(("bob", "APPROVED"), ("carol", "CHANGES_REQUESTED")))
        votes = {r["id"]: r["vote"] for r in gh.ado_pr(node)["reviewers"]}
        self.assertEqual(votes, {"bob": 10, "carol": -5})

    def test_a_reviewer_asked_again_is_waited_on_again(self):
        node = pr_node(1, reviewRequests=requested("bob"),
                       latestOpinionatedReviews=reviews(("bob", "APPROVED")))
        self.assertEqual(gh.ado_pr(node)["reviewers"][0]["vote"], 0)

    def test_a_comment_after_an_approval_keeps_the_approval(self):
        node = pr_node(1, latestOpinionatedReviews=reviews(("bob", "APPROVED")),
                       latestReviews=reviews(("bob", "COMMENTED")))
        self.assertEqual(gh.ado_pr(node)["reviewers"][0]["vote"], 10)

    def test_the_author_is_no_reviewer_and_teams_are_containers(self):
        node = pr_node(1, latestReviews=reviews(("alice", "COMMENTED")),
                       reviewRequests={"nodes": [{"requestedReviewer": {"__typename": "Team", "slug": "core",
                                                                        "name": "Core"}}]})
        rs = gh.ado_pr(node)["reviewers"]
        self.assertEqual([(r["id"], r["isContainer"]) for r in rs], [("team:core", True)])

    def test_a_fork_pr_is_sourced_from_refs_pull(self):
        node = pr_node(7, isCrossRepository=True, headRefName="main")
        self.assertEqual(gh.ado_pr(node)["sourceRefName"], "refs/heads/pull/7/head")

    def test_conflicts_and_auto_merge(self):
        node = pr_node(1, mergeable="CONFLICTING", autoMergeRequest={"enabledBy": user("bob", "Bob B")})
        ado = gh.ado_pr(node)
        self.assertEqual(ado["mergeStatus"], "conflicts")
        self.assertEqual(ado["autoCompleteSetBy"], {"displayName": "Bob B"})


class ThreadTests(unittest.TestCase):
    def comment(self, cid, login="bob", body="hi"):
        return {"databaseId": cid, "body": body, "createdAt": iso(), "author": user(login)}

    def test_line_file_and_conversation_threads(self):
        pr = {"reviewThreads": {"nodes": [
            {"id": "T1", "isResolved": False, "isOutdated": False, "path": "a.go", "line": 12, "startLine": 10,
             "diffSide": "RIGHT", "subjectType": "LINE", "comments": {"nodes": [self.comment(5), self.comment(6)]}},
            {"id": "T2", "isResolved": True, "isOutdated": False, "path": "b.go", "line": 3, "startLine": None,
             "diffSide": "LEFT", "subjectType": "LINE", "comments": {"nodes": [self.comment(7)]}},
            {"id": "T3", "isResolved": False, "isOutdated": True, "path": "c.go", "line": None, "startLine": None,
             "diffSide": "RIGHT", "subjectType": "LINE", "comments": {"nodes": [self.comment(8)]}},
            {"id": "T4", "isResolved": False, "path": "d.go", "subjectType": "FILE",
             "comments": {"nodes": [self.comment(9)]}},
        ]}, "comments": {"nodes": [self.comment(100, "carol"), self.comment(101)]}}
        t = gh.ado_threads(pr)
        self.assertEqual([x["id"] for x in t], [5, 7, 8, 9, 0])
        self.assertEqual(t[0]["status"], "active")
        self.assertEqual(t[0]["threadContext"], {"filePath": "/a.go", "rightFileStart": {"line": 10, "offset": 1},
                                                 "rightFileEnd": {"line": 12, "offset": 1}})
        self.assertEqual(t[1]["status"], "fixed")
        self.assertIn("leftFileStart", t[1]["threadContext"])
        self.assertEqual(t[2]["threadContext"], {"filePath": "/c.go"})  # outdated: file-level
        self.assertTrue(t[2]["isOutdated"])
        self.assertEqual(t[3]["threadContext"], {"filePath": "/d.go"})
        self.assertTrue(t[4]["conversation"])
        self.assertEqual(len(t[4]["comments"]), 2)
        self.assertEqual(t[0]["comments"][0]["author"], {"id": "bob", "displayName": "bob"})

    def test_mentions_by_login(self):
        threads = [{"status": "active", "comments": [{"content": "@me look, @mehdi no"}]},
                   {"status": "fixed", "comments": [{"content": "thanks @Me"}]},
                   {"status": "active", "conversation": True, "comments": [{"content": "@me"}]}]
        self.assertEqual(gh.mention_counts(threads, "me"), (1, 3))


class IterationTests(unittest.TestCase):
    def test_commits_and_force_pushes_in_order(self):
        pr = {"timelineItems": {"nodes": [
            {"__typename": "PullRequestCommit", "commit": {"oid": "a", "committedDate": "2026-01-01T00:00:00Z"}},
            {"__typename": "HeadRefForcePushedEvent", "createdAt": "2026-01-03T00:00:00Z",
             "afterCommit": {"oid": "c"}},
            {"__typename": "PullRequestCommit", "commit": {"oid": "b", "committedDate": "2026-01-02T00:00:00Z"}},
            {"__typename": "PullRequestCommit", "commit": {"oid": "c", "committedDate": "2026-01-02T12:00:00Z"}},
        ]}, "latestReviews": {"nodes": [{"author": {"login": "me"}, "commit": {"oid": "b"}}]}}
        out = gh.ado_iterations(pr, "me")
        self.assertEqual([v["sourceRefCommit"]["commitId"] for v in out["value"]], ["a", "b", "c"])
        self.assertEqual(out["count"], 3)
        self.assertEqual(out["myLastReviewSha"], "b")

    # myLastReviewSha (#99): latestReviews can leave a COMMENTED review out
    # (HollowThorn/Wtile#9), so the viewer's own nodes in reviews count too.
    def my_sha(self, latest=(), reviews=()):
        def nodes(rs):
            return {"nodes": [{"state": s, "submittedAt": at, "author": {"login": who}, "commit": {"oid": oid}}
                              for who, s, oid, at in rs]}
        return gh.ado_iterations({"latestReviews": nodes(latest), "reviews": nodes(reviews)}, "me").get(
            "myLastReviewSha")

    def test_comment_only_review_missing_from_latest_reviews(self):
        self.assertEqual(self.my_sha(reviews=[("bob", "CHANGES_REQUESTED", "a", "2026-01-01T00:00:00Z"),
                                              ("me", "COMMENTED", "b", "2026-01-02T00:00:00Z")]), "b")

    def test_approved_review(self):
        mine = [("me", "APPROVED", "b", "2026-01-02T00:00:00Z")]
        self.assertEqual(self.my_sha(latest=mine, reviews=mine), "b")

    def test_no_review_of_mine(self):
        self.assertIsNone(self.my_sha())
        bob = [("bob", "COMMENTED", "a", "2026-01-01T00:00:00Z")]
        self.assertIsNone(self.my_sha(latest=bob, reviews=bob))

    def test_pending_review_is_ignored(self):
        self.assertEqual(self.my_sha(reviews=[("me", "COMMENTED", "a", "2026-01-01T00:00:00Z"),
                                              ("me", "PENDING", "c", None)]), "a")
        self.assertIsNone(self.my_sha(reviews=[("me", "PENDING", "c", None)]))

    def test_newest_review_wins(self):
        self.assertEqual(self.my_sha(latest=[("me", "APPROVED", "a", "2026-01-01T00:00:00Z")],
                                     reviews=[("me", "APPROVED", "a", "2026-01-01T00:00:00Z"),
                                              ("me", "COMMENTED", "b", "2026-01-02T00:00:00Z")]), "b")
        # On a tie latestReviews' answer stands.
        self.assertEqual(self.my_sha(latest=[("me", "COMMENTED", "a", "2026-01-01T00:00:00Z")],
                                     reviews=[("me", "COMMENTED", "b", "2026-01-01T00:00:00Z")]), "a")


class ListTests(unittest.TestCase):
    def run_list(self, requested_nodes=(), reviewed_nodes=(), created_nodes=(), threads=None, acct=None):
        def threads_answer(v):
            pr = {"reviewThreads": {"nodes": []}, "comments": {"nodes": []}}
            if threads:
                pr = threads(v)
            return {"repository": {"pullRequest": pr}}
        client = FakeClient({
            "repositoryOwner": {"repositoryOwner": {"__typename": "Organization"}},
            "requested:": {"viewer": user("me", "Me Myself"), "requested": {"nodes": list(requested_nodes)},
                           "reviewed": {"nodes": list(reviewed_nodes)}, "created": {"nodes": list(created_nodes)}},
            "reviewThreads": threads_answer,
        })
        recs = gh.list_records(acct or account(owner="o"), env={}, client=client)
        return recs, client

    def test_sections_like_azure(self):
        recs, _ = self.run_list(
            requested_nodes=[pr_node(1, reviewRequests=requested("me")),
                             pr_node(2, isDraft=True, reviewRequests=requested("me"))],
            reviewed_nodes=[pr_node(3, latestOpinionatedReviews=reviews(("me", "APPROVED"))),
                            pr_node(1, reviewRequests=requested("me"))],
            created_nodes=[pr_node(4, author=user("me"))])
        self.assertEqual([(r["id"], r["state"]) for r in recs],
                         [(1, "Actionable"), (2, "Drafts"), (3, "SignedOff"), (4, "Created")])

    def test_a_pr_whose_branch_is_gone_is_dropped(self):
        recs, _ = self.run_list(requested_nodes=[pr_node(1, headRef=None, reviewRequests=requested("me"))])
        self.assertEqual(recs, [])

    def test_owner_filter_and_search_words(self):
        _, client = self.run_list()
        variables = [v for q, v in client.queries if "requested:" in q][0]
        self.assertEqual(variables["requested"], "is:pr is:open archived:false org:o review-requested:@me")
        self.assertEqual(variables["created"], "is:pr is:open archived:false org:o author:@me")

    def test_no_owner_searches_everything(self):
        _, client = self.run_list(acct=account())
        self.assertFalse(any("repositoryOwner" in q for q, _ in client.queries))

    def test_record_fields(self):
        def threads(v):
            return {"reviewThreads": {"nodes": [
                {"id": "T", "isResolved": False, "path": "a", "line": 1, "diffSide": "RIGHT", "subjectType": "LINE",
                 "comments": {"nodes": [{"databaseId": 9, "body": "@me why", "createdAt": iso(),
                                         "author": user("bob")}]}}]},
                    "comments": {"nodes": [{"databaseId": 10, "body": "lgtm", "createdAt": iso(),
                                            "author": user("carol")}]}}
        recs, _ = self.run_list(requested_nodes=[pr_node(5, reviewRequests=requested("me"))], threads=threads)
        r = recs[0]
        self.assertEqual((r["host"], r["key"], r["org"], r["project"], r["repo"]),
                         ("github", "o~r~5", "https://api.github.com", "o", "r"))
        self.assertEqual(r["url"], "https://github.com/o/r/pull/5")
        self.assertEqual(r["cloneUrl"], "https://github.com/o/r.git")
        self.assertEqual((r["source"], r["target"]), ("feature-5", "main"))
        self.assertEqual((r["myId"], r["myName"]), ("me", "Me Myself"))
        self.assertEqual(r["buildStatus"], "succeeded")
        self.assertEqual(r["buildUrl"], "https://github.com/o/r/pull/5/checks")
        # The Conversation tab isn't a thread anyone resolves: counted for
        # unread comments, not as an active thread.
        self.assertEqual((r["activeThreads"], r["totalThreads"]), (1, 1))
        self.assertEqual(r["othersComments"], 2)
        self.assertEqual((r["mentionThreads"], r["mentionTotal"]), (1, 1))
        self.assertEqual([m["key"] for m in r["caps"]["merge_methods"]], ["squash", "merge"])
        self.assertTrue(r["caps"]["auto_complete"])

    def test_threads_are_refetched_only_when_the_pr_moved(self):
        gh._threads_cache.clear()
        node = pr_node(6, reviewRequests=requested("me"))
        _, client = self.run_list(requested_nodes=[node])
        _, client2 = self.run_list(requested_nodes=[node])
        self.assertTrue(any("reviewThreads" in q for q, _ in client.queries))
        self.assertFalse(any("reviewThreads" in q for q, _ in client2.queries))


class ConfigTests(unittest.TestCase):
    def test_a_github_account_needs_no_org_or_project(self):
        cfg = ac.Config.from_string("accounts:\n  - host: github\n    owner: o\n")
        self.assertEqual(cfg.problems(), [])
        self.assertEqual(cfg.accounts_by_org(), [])
        self.assertEqual(cfg.github_accounts()[0].api_url, "https://api.github.com")

    def test_clones_dir_expands_the_home_folder(self):
        cfg = ac.Config.from_string("accounts:\n  - host: github\n    clones_dir: ~/src\n")
        self.assertEqual(cfg.accounts[0].clones_dir, os.path.expanduser("~/src"))

    def test_unknown_host_and_work_items_on_github(self):
        cfg = ac.Config.from_dict({"accounts": [{"host": "gitlab"},
                                                {"host": "github", "work_items": {"team": "x"}}]})
        problems = cfg.problems()
        self.assertTrue(any("host must be azure or github" in p for p in problems))
        self.assertTrue(any("work_items" in p for p in problems))

    def test_account_for_an_action(self):
        cfg = ac.Config.from_dict({"accounts": [
            {"project_name": "P", "org_url": "https://dev.azure.com/x", "pat": "t"},
            {"host": "github"}, {"host": "github", "owner": "o"},
            {"host": "github", "api_url": "https://ghe.example.com/api/v3"}]})
        self.assertIsNone(cfg.github_account_for("https://dev.azure.com/x", "P"))
        self.assertEqual(cfg.github_account_for("https://api.github.com", "o").owner, "o")
        self.assertIsNone(cfg.github_account_for("https://api.github.com", "zz").owner)
        self.assertEqual(cfg.github_account_for("https://ghe.example.com/api/v3", "q").api_url,
                         "https://ghe.example.com/api/v3")


class RestClient(gh.Client):
    """Records REST calls and answers them from `answers` (by method +
    path prefix); GraphQL by a word in the query, like FakeClient."""

    def __init__(self, answers=None, graphql=None):
        gh.Client.__init__(self, "https://api.github.com", "t")
        self.calls = []
        answers = answers or {}
        graphql = graphql or {}

        def fetch(method, url, token, data=None):
            path = url[len("https://api.github.com"):]
            self.calls.append((method, path, data))
            if path == "/graphql":
                for word, ans in graphql.items():
                    if word in data["query"]:
                        return {"data": ans}
                raise AssertionError("unexpected query")
            for (m, prefix), ans in answers.items():
                if m == method and path.startswith(prefix):
                    return ans
            return {}
        self.fetch = fetch

    def writes(self):
        return [c for c in self.calls if c[0] != "GET" and c[1] != "/graphql"]


HEAD = {("GET", "/repos/o/r/pulls/5"): {"head": {"sha": "HEADSHA"}}}


def actions(client):
    return gh.Actions(account(), {"AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "5"}, client)


def quiet(fn, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = fn(*args)
    return code, out.getvalue().strip()


class WriteTests(unittest.TestCase):
    def test_a_line_comment(self):
        c = RestClient(HEAD)
        self.assertEqual(quiet(actions(c).post_inline, "a.go", "R", "12", "why?"), (0, "Comment posted."))
        self.assertEqual(c.writes(), [("POST", "/repos/o/r/pulls/5/comments",
                                       {"body": "why?", "commit_id": "HEADSHA", "path": "a.go", "side": "RIGHT",
                                        "line": 12})])

    def test_a_line_outside_the_hunks_says_why(self):
        c = RestClient(HEAD)

        def refuse(method, url, token, data=None):
            if method == "POST":
                raise gh.GitHubHttpError(422, url, json.dumps({
                    "message": "Validation Failed",
                    "errors": ["pull_request_review_thread.line must be part of the diff"]}))
            return {"head": {"sha": "HEADSHA"}}
        c.fetch = refuse
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(quiet(actions(c).post_inline, "a.go", "R", "400", "x")[0], 1)
        self.assertIn("outside the diff's hunks", err.getvalue())

    def test_a_range_on_the_left(self):
        c = RestClient(HEAD)
        quiet(actions(c).post_inline, "a.go", "L", "3", "x", "7")
        self.assertEqual(c.writes()[0][2], {"body": "x", "commit_id": "HEADSHA", "path": "a.go", "side": "LEFT",
                                            "start_line": 3, "start_side": "LEFT", "line": 7})

    def test_bad_input_and_blank_text(self):
        c = RestClient(HEAD)
        self.assertEqual(quiet(actions(c).post_inline, "a.go", "X", "3", "x")[0], 1)
        self.assertEqual(quiet(actions(c).post_inline, "a.go", "R", "0", "x")[0], 1)
        self.assertEqual(quiet(actions(c).post_inline, "a.go", "R", "3", "  "), (0, "Cancelled."))
        self.assertEqual(c.writes(), [])

    def test_file_and_pr_comments(self):
        c = RestClient(HEAD)
        quiet(actions(c).post_file_comment, "b.go", "file note")
        quiet(actions(c).post_pr_comment, "overall")
        self.assertEqual(c.writes(), [
            ("POST", "/repos/o/r/pulls/5/comments",
             {"body": "file note", "commit_id": "HEADSHA", "path": "b.go", "subject_type": "file"}),
            ("POST", "/repos/o/r/issues/5/comments", {"body": "overall"})])

    def test_replies_in_a_thread_and_in_the_conversation(self):
        c = RestClient()
        self.assertEqual(quiet(actions(c).post_reply, "77", "yes"), (0, "Reply posted."))
        quiet(actions(c).post_reply, "0", "general")
        self.assertEqual(c.writes(), [("POST", "/repos/o/r/pulls/5/comments/77/replies", {"body": "yes"}),
                                      ("POST", "/repos/o/r/issues/5/comments", {"body": "general"})])

    def test_edit_and_delete_pick_review_or_issue_comments(self):
        c = RestClient()
        self.assertEqual(quiet(actions(c).edit_comment, "77", "78", "new"), (0, "Comment 78 (thread 77) updated."))
        quiet(actions(c).edit_comment, "0", "90", "new")
        self.assertEqual(quiet(actions(c).delete_comment, "77", "78"), (0, "Comment 78 (thread 77) deleted."))
        self.assertEqual([(m, p) for m, p, _ in c.writes()], [
            ("PATCH", "/repos/o/r/pulls/comments/78"), ("PATCH", "/repos/o/r/issues/comments/90"),
            ("DELETE", "/repos/o/r/pulls/comments/78")])

    def threads(self):
        return {"reviewThreads": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
            {"id": "PRRT_a", "comments": {"nodes": [{"databaseId": 77}]}}]}}}},
            "resolveReviewThread": {"resolveReviewThread": {}},
            "unresolveReviewThread": {"unresolveReviewThread": {}}}

    def test_resolve_and_reopen(self):
        c = RestClient(graphql=self.threads())
        self.assertEqual(quiet(actions(c).set_thread_status, "77", "fixed"), (0, "Thread 77 set to fixed."))
        self.assertEqual(quiet(actions(c).set_thread_status, "77", "active"), (0, "Thread 77 set to active."))
        muts = [d for m, p, d in c.calls if p == "/graphql" and d["query"].startswith("mutation")]
        self.assertIn("resolveReviewThread", muts[0]["query"])
        self.assertIn("unresolveReviewThread", muts[1]["query"])
        self.assertEqual(muts[0]["variables"], {"id": "PRRT_a"})

    def test_unknown_thread_and_the_conversation_have_no_status(self):
        c = RestClient(graphql=self.threads())
        self.assertEqual(quiet(actions(c).set_thread_status, "12", "fixed")[0], 1)
        self.assertEqual(quiet(actions(c).set_thread_status, "0", "fixed")[0], 1)

    def test_votes_are_reviews(self):
        c = RestClient(HEAD)
        self.assertEqual(quiet(actions(c).set_vote, "10"), (0, "Vote set to 10."))
        quiet(actions(c).set_vote, "-5")
        quiet(actions(c).set_vote, "-5", "rename it")
        self.assertEqual([d for _, _, d in c.writes()], [
            {"event": "APPROVE", "commit_id": "HEADSHA"},
            {"event": "REQUEST_CHANGES", "commit_id": "HEADSHA", "body": "Changes requested."},
            {"event": "REQUEST_CHANGES", "commit_id": "HEADSHA", "body": "rename it"}])
        self.assertEqual(quiet(actions(c).set_vote, "5")[0], 1)

    def test_reset_dismisses_my_latest_review(self):
        c = RestClient({("GET", "/user"): {"login": "me"},
                        ("GET", "/repos/o/r/pulls/5/reviews"): [
                            {"id": 1, "user": {"login": "me"}, "state": "APPROVED"},
                            {"id": 2, "user": {"login": "bob"}, "state": "APPROVED"},
                            {"id": 3, "user": {"login": "me"}, "state": "COMMENTED"}]})
        self.assertEqual(quiet(actions(c).set_vote, "0"), (0, "Vote set to 0."))
        self.assertEqual(c.writes(), [("PUT", "/repos/o/r/pulls/5/reviews/1/dismissals",
                                       {"message": "Dismissed by its author.", "event": "DISMISS"})])

    def test_error_text_is_github_s_message(self):
        e = gh.GitHubHttpError(422, "u", json.dumps({"message": "Validation Failed",
                                                     "errors": [{"message": "line must be part of the diff"}]}))
        self.assertEqual(str(e), "HTTP 422: Validation Failed: line must be part of the diff")


class ReviewTests(unittest.TestCase):
    def client(self, pending=None, fail_on=None):
        answers = {
            "reviews(states: PENDING": {"repository": {"pullRequest": {
                "id": "PR_n", "headRefOid": "HEADSHA",
                "reviews": {"nodes": [{"id": pending, "viewerDidAuthor": True}] if pending else []},
                "reviewThreads": {"nodes": [{"id": "PRRT_77", "comments": {"nodes": [{"databaseId": 77}]}}]}}}},
            "addPullRequestReview(": {"addPullRequestReview": {"pullRequestReview": {"id": "PRR_new"}}},
            "addPullRequestReviewThread(": {"addPullRequestReviewThread": {"thread": {"id": "t"}}},
            "addPullRequestReviewThreadReply(": {"addPullRequestReviewThreadReply": {"comment": {"id": "c"}}},
            "submitPullRequestReview(": {"submitPullRequestReview": {}},
            "deletePullRequestReview(": {"deletePullRequestReview": {}},
        }
        c = RestClient(graphql={})
        c.mutations = []

        def fetch(method, url, token, data=None):
            q = data["query"]
            for word, ans in answers.items():
                if word in q:
                    c.mutations.append((word, data.get("variables")))
                    if fail_on and fail_on in q:
                        raise gh.GitHubHttpError(422, url, json.dumps({"message": "nope"}))
                    return {"data": ans}
            raise AssertionError("unexpected query: " + q[:60])
        c.fetch = fetch
        return c

    def payload(self, **kw):
        p = {"event": "10", "body": "overall", "items": [
            ["--post", "a.go", "R", "3", "line note", "5"],
            ["--file-comment", "b.go", "file note"],
            ["--reply", "77", "agreed"]]}
        p.update(kw)
        return json.dumps(p)

    def test_one_review_with_every_comment(self):
        c = self.client()
        self.assertEqual(quiet(actions(c).submit_review, self.payload()), (0, "Review submitted (3 comments)."))
        words = [w for w, _ in c.mutations]
        self.assertEqual(words, ["reviews(states: PENDING", "addPullRequestReview(", "addPullRequestReviewThread(",
                                 "addPullRequestReviewThread(", "addPullRequestReviewThreadReply(",
                                 "submitPullRequestReview("])
        v = [v for _, v in c.mutations]
        self.assertEqual(v[1], {"pr": "PR_n", "oid": "HEADSHA"})
        self.assertEqual(v[2]["input"], {"path": "a.go", "body": "line note", "line": 5, "side": "RIGHT",
                                         "subjectType": "LINE", "startLine": 3, "startSide": "RIGHT",
                                         "pullRequestReviewId": "PRR_new"})
        self.assertEqual(v[3]["input"]["subjectType"], "FILE")
        self.assertEqual(v[4]["input"], {"pullRequestReviewThreadId": "PRRT_77", "body": "agreed",
                                         "pullRequestReviewId": "PRR_new"})
        self.assertEqual(v[5], {"id": "PRR_new", "event": "APPROVE", "body": "overall"})

    def test_verdicts(self):
        for event, want in (("-5", "REQUEST_CHANGES"), ("comment", "COMMENT")):
            c = self.client()
            quiet(actions(c).submit_review, self.payload(event=event, body=""))
            sub = [v for w, v in c.mutations if w == "submitPullRequestReview("][0]
            self.assertEqual(sub["event"], want)
        self.assertEqual(sub["body"], None)

    def test_changes_requested_gets_a_reason(self):
        c = self.client()
        quiet(actions(c).submit_review, self.payload(event="-5", body=""))
        sub = [v for w, v in c.mutations if w == "submitPullRequestReview("][0]
        self.assertEqual(sub["body"], "Changes requested.")

    def test_a_pending_review_of_mine_is_joined(self):
        c = self.client(pending="PRR_mine")
        quiet(actions(c).submit_review, self.payload())
        self.assertNotIn("addPullRequestReview(", [w for w, _ in c.mutations])
        self.assertEqual([v for w, v in c.mutations if w == "submitPullRequestReview("][0]["id"], "PRR_mine")

    def test_a_failure_deletes_the_pending_review(self):
        c = self.client(fail_on="addPullRequestReviewThreadReply(")
        with self.assertRaises(gh.GitHubHttpError):
            quiet(actions(c).submit_review, self.payload())
        words = [w for w, _ in c.mutations]
        self.assertEqual(words[-1], "deletePullRequestReview(")
        self.assertNotIn("submitPullRequestReview(", words)

    def test_bad_items_send_nothing(self):
        c = self.client()
        self.assertEqual(quiet(actions(c).submit_review, self.payload(items=[["--reply", "12", "x"]]))[0], 1)
        self.assertEqual(quiet(actions(c).submit_review, self.payload(items=[["--vote", "10"]]))[0], 1)
        self.assertEqual(quiet(actions(c).submit_review, "not json")[0], 1)
        self.assertNotIn("addPullRequestReview(", [w for w, _ in c.mutations])


def merge_pr(**kw):
    """MERGE_STATE_QUERY's pullRequest: open, clean, into a branch that
    isn't the default (like feature/30 -> github-host)."""
    pr = {"id": "PR_5", "number": 5, "state": "OPEN", "isDraft": False, "headRefName": "feature/x",
          "headRefOid": "HEADSHA", "baseRefName": "github-host", "isCrossRepository": False,
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": None, "autoMergeRequest": None,
          "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {"nodes": []}}}}]}}
    pr.update(kw)
    return pr


def merge_repo(pr=None, **kw):
    repo = {"deleteBranchOnMerge": False, "autoMergeAllowed": True, "mergeCommitAllowed": True,
            "squashMergeAllowed": True, "rebaseMergeAllowed": False, "defaultBranchRef": {"name": "master"},
            "pullRequest": pr or merge_pr()}
    repo.update(kw)
    return {"repository": repo}


def checks(*nodes):
    return {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE", "contexts": {"nodes": list(nodes)}}}}]}


def run(name, conclusion="SUCCESS", required=True, status="COMPLETED"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion,
            "isRequired": required}


def loud(fn, *args):
    """(exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = fn(*args)
    return code, out.getvalue().strip(), err.getvalue().strip()


class MergeabilityTests(unittest.TestCase):
    def state(self, **kw):
        return gh.mergeability(merge_repo()["repository"], merge_pr(**kw))

    def test_clean_has_no_blockers(self):
        s = self.state()
        self.assertEqual((s["status"], s["blockers"], s["warnings"], s["conflict"]), ("CLEAN", [], [], False))
        self.assertEqual((s["base"], s["defaultBranch"]), ("github-host", "master"))

    def test_each_status_says_why(self):
        self.assertEqual(self.state(mergeStateStatus="DIRTY", mergeable="CONFLICTING")["blockers"],
                         ["merge conflict with github-host"])
        self.assertTrue(self.state(mergeStateStatus="DIRTY")["conflict"])
        self.assertEqual(self.state(mergeStateStatus="DRAFT", isDraft=True)["blockers"], ["it's a draft"])
        self.assertIn("brought up to date", self.state(mergeStateStatus="BEHIND")["blockers"][0])
        self.assertIn("hasn't worked out", self.state(mergeStateStatus="UNKNOWN")["blockers"][0])
        self.assertEqual(self.state(state="MERGED")["blockers"], ["it's already merged"])

    def test_blocked_names_required_checks_and_reviews(self):
        s = self.state(mergeStateStatus="BLOCKED", reviewDecision="REVIEW_REQUIRED", commits=checks(
            run("ci / test", "FAILURE"), run("lint", status="IN_PROGRESS", conclusion=None),
            run("docs", "FAILURE", required=False), run("build"),
            {"__typename": "StatusContext", "context": "legacy", "state": "PENDING", "isRequired": False}))
        self.assertEqual(s["blockers"], ["required check `ci / test` failed", "required check `lint` hasn't finished",
                                         "needs an approving review"])
        self.assertEqual(s["warnings"], ["check `docs` failed (not required)"])
        self.assertEqual([(c["name"], c["state"]) for c in s["checks"]],
                         [("ci / test", "failed"), ("lint", "pending"), ("docs", "failed"), ("build", "ok"),
                          ("legacy", "pending")])

    def test_blocked_without_a_known_reason(self):
        s = self.state(mergeStateStatus="BLOCKED")
        self.assertIn("github-host's branch protection", s["blockers"][0])
        self.assertEqual(self.state(mergeStateStatus="BLOCKED", reviewDecision="CHANGES_REQUESTED")["blockers"],
                         ["changes requested"])

    def test_without_isRequired_failing_checks_still_explain_a_block(self):
        s = self.state(mergeStateStatus="BLOCKED", commits=checks(run("ci", "FAILURE", required=None)))
        self.assertEqual(s["blockers"], ["check `ci` failed"])

    def test_unstable_merges_with_a_warning(self):
        s = self.state(mergeStateStatus="UNSTABLE", commits=checks(run("flaky", "FAILURE", required=False)))
        self.assertEqual((s["blockers"], s["warnings"]), ([], ["check `flaky` failed (not required)"]))


class MergeTests(unittest.TestCase):
    def client(self, state=None, rest=None, fail=None):
        """GraphQL answers MERGE_STATE_QUERY with `state` (a list: one per
        call, the last repeating), the auto-merge mutations with {}; REST
        records calls and raises `fail[(method, path prefix)]`."""
        states = list(state or [merge_repo()])
        c = RestClient(rest or {})
        c.gql = []
        inner = c.fetch

        def fetch(method, url, token, data=None):
            path = url[len("https://api.github.com"):]
            if path == "/graphql":
                q = data["query"]
                c.gql.append((q, data.get("variables")))
                if "mergeStateStatus" in q:
                    return {"data": states.pop(0) if len(states) > 1 else states[0]}
                if "AutoMerge(" in q:
                    if fail and "graphql" in fail:
                        return {"errors": [{"message": fail["graphql"]}]}
                    return {"data": {}}
                raise AssertionError("unexpected query: " + q[:60])
            for (m, prefix), err in (fail or {}).items():
                if m == method and path.startswith(prefix):
                    c.calls.append((method, path, data))
                    raise err
            return inner(method, url, token, data)
        c.fetch = fetch
        return c

    def actions(self, c):
        a = actions(c)
        a.sleep = lambda s: None
        return a

    def test_merges_into_a_base_that_is_not_the_default_and_deletes_the_head(self):
        c = self.client()
        code, out, _ = loud(self.actions(c).complete, "squash", "true")
        self.assertEqual((code, out), (0, "PR #5 merged (squash); branch feature/x deleted."))
        self.assertEqual(c.writes(), [("PUT", "/repos/o/r/pulls/5/merge", {"merge_method": "squash", "sha": "HEADSHA"}),
                                      ("DELETE", "/repos/o/r/git/refs/heads/feature/x", None)])

    def test_keeping_the_branch(self):
        c = self.client()
        self.assertEqual(loud(self.actions(c).complete, "merge", "false")[:2], (0, "PR #5 merged (merge)."))
        self.assertEqual([m for m, _, _ in c.writes()], ["PUT"])

    def test_a_disallowed_method_is_refused_without_a_call(self):
        c = self.client()
        code, _, err = loud(self.actions(c).complete, "rebase", "true")
        self.assertEqual(code, 1)
        self.assertIn("rebase isn't allowed on o/r: squash, merge", err)
        self.assertEqual(c.writes(), [])

    def test_blocked_says_why_and_merges_nothing(self):
        c = self.client([merge_repo(merge_pr(mergeStateStatus="BLOCKED", commits=checks(run("ci / test", "FAILURE"))))])
        code, _, err = loud(self.actions(c).complete, "squash", "true")
        self.assertEqual(code, 1)
        self.assertEqual(err, "Can't merge PR #5: required check `ci / test` failed.")
        self.assertEqual(c.writes(), [])

    def test_unknown_is_asked_again(self):
        c = self.client([merge_repo(merge_pr(mergeStateStatus="UNKNOWN")), merge_repo()])
        self.assertEqual(loud(self.actions(c).complete, "squash", "false")[0], 0)
        self.assertEqual(len([q for q, _ in c.gql if "mergeStateStatus" in q]), 2)

    def test_a_fork_branch_stays(self):
        c = self.client([merge_repo(merge_pr(isCrossRepository=True))])
        self.assertEqual(loud(self.actions(c).complete, "squash", "true")[1],
                         "PR #5 merged (squash); its branch is in a fork, so it stays.")
        self.assertEqual([m for m, _, _ in c.writes()], ["PUT"])

    def test_a_branch_already_gone_is_deleted(self):
        gone = gh.GitHubHttpError(422, "u", json.dumps({"message": "Reference does not exist"}))
        c = self.client(fail={("DELETE", "/repos/o/r/git/refs"): gone})
        self.assertEqual(loud(self.actions(c).complete, "squash", "true")[:2],
                         (0, "PR #5 merged (squash); branch feature/x deleted."))

    def test_a_failed_delete_keeps_the_merge(self):
        denied = gh.GitHubHttpError(403, "u", json.dumps({"message": "Forbidden"}))
        c = self.client(fail={("DELETE", "/repos/o/r/git/refs"): denied})
        code, out, _ = loud(self.actions(c).complete, "squash", "true")
        self.assertEqual(code, 0)
        self.assertIn("merged (squash), but its branch feature/x couldn't be deleted", out)

    def test_merge_refusals_are_one_line(self):
        for status, want in ((409, "branch moved since it was checked"), (405, "GitHub won't merge PR #5: nope")):
            c = self.client(fail={("PUT", "/repos/o/r/pulls/5/merge"):
                                  gh.GitHubHttpError(status, "u", json.dumps({"message": "nope"}))})
            code, _, err = loud(self.actions(c).complete, "squash", "true")
            self.assertEqual(code, 1)
            self.assertIn(want, err)
            self.assertNotIn("DELETE", [m for m, _, _ in c.calls])

    def test_auto_merge_on_and_off(self):
        c = self.client()
        code, out, _ = loud(self.actions(c).auto_merge, "on", "squash")
        self.assertEqual(code, 0)
        self.assertIn("Auto-merge enabled for PR #5 (squash)", out)
        self.assertIn("which is off", out)
        q, v = c.gql[-1]
        self.assertIn("enablePullRequestAutoMerge", q)
        self.assertEqual(v, {"id": "PR_5", "method": "SQUASH", "oid": "HEADSHA"})
        c = self.client([merge_repo(merge_pr(autoMergeRequest={"mergeMethod": "SQUASH"}))])
        self.assertEqual(loud(self.actions(c).auto_merge, "off")[:2], (0, "Auto-merge disabled for PR #5."))
        self.assertIn("disablePullRequestAutoMerge", c.gql[-1][0])
        self.assertEqual(c.gql[-1][1], {"id": "PR_5"})

    def test_auto_merge_defaults_to_an_allowed_method(self):
        c = self.client([merge_repo(squashMergeAllowed=False)])
        self.assertEqual(loud(self.actions(c).auto_merge, "on", "")[0], 0)
        self.assertEqual(c.gql[-1][1]["method"], "MERGE")

    def test_auto_merge_refusals(self):
        c = self.client(fail={"graphql": "Pull request Pull request is in clean status"})
        code, _, err = loud(self.actions(c).auto_merge, "on", "squash")
        self.assertEqual(code, 1)
        self.assertIn("can be merged now", err)
        c = self.client([merge_repo(autoMergeAllowed=False)])
        self.assertIn("isn't allowed on o/r", loud(self.actions(c).auto_merge, "on", "squash")[2])
        c = self.client([merge_repo(merge_pr(mergeStateStatus="DIRTY", mergeable="CONFLICTING"))])
        self.assertIn("merge conflict", loud(self.actions(c).auto_merge, "on", "squash")[2])
        self.assertFalse([q for q, _ in c.gql if "AutoMerge(" in q])

    def test_without_isRequired_the_query_is_asked_again(self):
        c = self.client()
        inner = c.fetch
        asked = []

        def fetch(method, url, token, data=None):
            if url.endswith("/graphql") and "isRequired" in data["query"]:
                asked.append(1)
                return {"errors": [{"message": "Field 'isRequired' doesn't accept argument 'pullRequestNumber'"}]}
            return inner(method, url, token, data)
        c.fetch = fetch
        self.assertEqual(loud(self.actions(c).complete, "squash", "false")[0], 0)
        self.assertEqual(asked, [1])

    def test_dispatch(self):
        called = []

        class Fake(object):
            def complete(self, *a):
                called.append(("complete",) + a)
                return 0

            def auto_merge(self, *a):
                called.append(("auto",) + a)
                return 0
        ac._GITHUB_ACTIONS["--complete"](Fake(), lambda i, d="": ["rebase", "false", "true"][i] if i < 3 else d)
        ac._GITHUB_ACTIONS["--auto-complete"](Fake(), lambda i, d="": ["on", "merge"][i] if i < 2 else d)
        self.assertEqual(called, [("complete", "rebase", "false"), ("auto", "on", "merge")])


class ActionTests(unittest.TestCase):
    def test_get_pr_carries_mergeability(self):
        blocked = merge_repo(merge_pr(mergeStateStatus="BLOCKED", commits=checks(run("ci / test", "FAILURE"))))
        client = FakeClient({"mergeStateStatus": blocked,
                             "viewer": {"viewer": user("me"), "repository": {"pullRequest": pr_node(5)}}})
        a = gh.Actions(account(), {"AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "5"}, client)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(a.get_pr(), 0)
        rec = json.loads(out.getvalue())
        self.assertEqual(rec["mergeability"]["blockers"], ["required check `ci / test` failed"])
        self.assertEqual(rec["mergeability"]["base"], "github-host")

    def test_threads_print_an_ado_list(self):
        client = FakeClient({"reviewThreads": {"repository": {"pullRequest": {
            "reviewThreads": {"nodes": []}, "comments": {"nodes": [
                {"databaseId": 1, "body": "x", "createdAt": iso(), "author": user("bob")}]}}}}})
        a = gh.Actions(account(), {"AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "5"}, client)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(a.threads(), 0)
        self.assertEqual(json.loads(out.getvalue())["value"][0]["id"], 0)

    def test_iterations_take_my_comment_only_review(self):
        client = FakeClient({"timelineItems": {"viewer": {"login": "me"}, "repository": {"pullRequest": {
            "timelineItems": {"nodes": [{"__typename": "PullRequestCommit",
                                         "commit": {"oid": "a", "committedDate": iso()}}]},
            "latestReviews": {"nodes": []},
            "reviews": {"nodes": [{"state": "COMMENTED", "submittedAt": iso(), "author": {"login": "me"},
                                   "commit": {"oid": "a"}}]}}}}})
        a = gh.Actions(account(), {"AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "5"}, client)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(a.iterations(), 0)
        self.assertEqual(json.loads(out.getvalue())["myLastReviewSha"], "a")
        self.assertIn("reviews(last: 100)", client.queries[0][0])


class IssueLinkTests(unittest.TestCase):
    """--work-items and --create-pr (phase 6 stage 3): a PR's issues are
    its closing references."""

    def test_work_items_are_the_closing_issues(self):
        c = RestClient(graphql={"closingIssuesReferences": {"repository": {"pullRequest": {
            "closingIssuesReferences": {"nodes": [
                {"number": 21, "title": "Issues", "state": "OPEN", "url": "u",
                 "repository": {"name": "r", "owner": {"login": "o"}},
                 "assignees": {"nodes": [{"login": "me"}]},
                 "projectItems": {"nodes": [{"fieldValueByName": None},
                                            {"fieldValueByName": {"name": "In Progress"}}]}},
                {"number": 3, "title": "Old", "state": "CLOSED", "url": "v",
                 "repository": {"name": "web", "owner": {"login": "o"}},
                 "assignees": {"nodes": []}, "projectItems": {"nodes": []}}]}}}}})
        code, out = quiet(actions(c).work_items)
        recs = [json.loads(l) for l in out.splitlines()]
        self.assertEqual(code, 0)
        self.assertEqual(recs[0], {"id": 21, "type": "Issue", "state": "In Progress", "title": "Issues",
                                   "assignedTo": "me", "url": "u", "repo": "r", "key": "o~r~21", "host": "github"})
        self.assertEqual((recs[1]["state"], recs[1]["key"]), ("Closed", "o~web~3"))

    def test_create_pr_closes_its_issues(self):
        c = RestClient({("POST", "/repos/o/r/pulls"): {
            "number": 17, "html_url": "https://github.com/o/r/pull/17",
            "base": {"ref": "main", "repo": {"default_branch": "main"}}}})
        code, out = quiet(actions(c).create_pr, "refs/heads/feature/21-x", "main", "T", "Body.\n\nCloses #4",
                          "21,4,o/web#2,o~web~3", "true")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"id": 17, "url": "https://github.com/o/r/pull/17", "key": "o~r~17"})
        self.assertEqual(c.writes(), [("POST", "/repos/o/r/pulls", {
            "title": "T", "head": "feature/21-x", "base": "main", "draft": True,
            "body": "Body.\n\nCloses #4\n\nCloses #21\nCloses o/web#2\nCloses o/web#3"})])

    def test_create_pr_into_another_branch_has_a_note(self):
        c = RestClient({("POST", "/repos/o/r/pulls"): {
            "number": 18, "html_url": "x", "base": {"ref": "github-host", "repo": {"default_branch": "master"}}}})
        code, out = quiet(actions(c).create_pr, "b", "github-host", "T", "", "21", "false")
        self.assertIn("only from pull requests into master", json.loads(out)["note"])
        self.assertEqual(c.writes()[0][2]["body"], "Closes #21")

    def test_both_are_dispatched(self):
        self.assertIn("--work-items", ac._GITHUB_ACTIONS)
        self.assertIn("--create-pr", ac._GITHUB_ACTIONS)


class PrefetchTests(unittest.TestCase):
    def test_a_fork_source_is_fetched_from_refs_pull(self):
        calls = []
        orig = ac._git_fetch
        ac._git_fetch = lambda path, specs: calls.append(specs) or 0
        try:
            with __import__("tempfile").TemporaryDirectory() as d:
                os.mkdir(os.path.join(d, ".git"))
                ac.cmd_prefetch({"AZVICLI_ORG": "x", "AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "7",
                                 "AZVICLI_SOURCE": "pull/7/head", "AZVICLI_TARGET": "main",
                                 "AZVICLI_PREFETCH": "1", "AZVICLI_REPO_PATH": d, "AZVICLI_PREFETCH_DIR": d})
        finally:
            ac._git_fetch = orig
        self.assertEqual(calls[0][0], "+refs/pull/7/head:refs/remotes/origin/pull/7/head")
        self.assertEqual(calls[0][1], "+refs/heads/main:refs/remotes/origin/main")


if __name__ == "__main__":
    unittest.main()
