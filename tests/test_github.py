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


class ActionTests(unittest.TestCase):
    def test_writes_are_not_there_yet(self):
        cfg = ac.Config.from_dict({"accounts": [{"host": "github", "pat": "t"}]})
        env = {"AZVICLI_ORG": "https://api.github.com", "AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r",
               "AZVICLI_PR": "5"}
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = ac._github_pr_action("--vote", ["10"], cfg.accounts[0], env)
        self.assertEqual(code, 1)
        self.assertIn("isn't available for GitHub", err.getvalue())

    def test_threads_print_an_ado_list(self):
        client = FakeClient({"reviewThreads": {"repository": {"pullRequest": {
            "reviewThreads": {"nodes": []}, "comments": {"nodes": [
                {"databaseId": 1, "body": "x", "createdAt": iso(), "author": user("bob")}]}}}}})
        a = gh.Actions(account(), {"AZVICLI_PROJECT": "o", "AZVICLI_REPO": "r", "AZVICLI_PR": "5"}, client)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(a.threads(), 0)
        self.assertEqual(json.loads(out.getvalue())["value"][0]["id"], 0)


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
