#!/usr/bin/env python3
"""Unit tests for github_issues.py: a GitHub account's Projects v2 project
answering --wi-list/--wi-detail/--wi-state/--wi-edit.

No network: the client's fetch answers GraphQL by a word in the query and
REST by method + path prefix, and records every call.
"""

import contextlib
import importlib.util
import io
import json
import os
import unittest
from datetime import date

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_github_issues_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()
gh = ac.github()
gi = ac.github_issues()

TODAY = date(2026, 10, 14)
API = "https://api.github.com"


def field(fid, name, options):
    return {"__typename": "ProjectV2SingleSelectField", "id": fid, "name": name,
            "options": [{"id": oid, "name": n} for oid, n in options]}


STATUS = field("F_S", "Status", [("O_T", "Todo"), ("O_P", "In Progress"), ("O_D", "Done")])
PRIORITY = field("F_P", "Priority", [("P_0", "P0"), ("P_1", "P1"), ("P_2", "P2")])
ITERATION = {"__typename": "ProjectV2IterationField", "id": "F_I", "name": "Iteration", "configuration": {
    "completedIterations": [{"id": "it0", "title": "Sprint 0", "startDate": "2026-09-09", "duration": 14},
                            {"id": "it1", "title": "Sprint 1", "startDate": "2026-09-23", "duration": 14}],
    "iterations": [{"id": "it3", "title": "Sprint 3", "startDate": "2026-10-21", "duration": 14},
                   {"id": "it2", "title": "Sprint 2", "startDate": "2026-10-07", "duration": 14}]}}


def project(fields=(STATUS, PRIORITY, ITERATION), repos=(("o", "r"),)):
    return {"id": "PRJ", "number": 3, "title": "Board", "url": "https://github.com/orgs/o/projects/3",
            "owner": {"login": "o"},
            "repositories": {"nodes": [{"name": r, "owner": {"login": o}} for o, r in repos]},
            "fields": {"nodes": [{"__typename": "ProjectV2Field", "id": "F_T", "name": "Title"}] + list(fields)}}


def issue(number, repo="r", state="OPEN", assignees=("me",), **kw):
    node = {"__typename": "Issue", "id": "I_%s_%d" % (repo, number), "databaseId": 1000 + number, "number": number,
            "title": "Issue  %d" % number, "url": "https://github.com/o/%s/issues/%d" % (repo, number),
            "state": state, "stateReason": None, "createdAt": "2026-10-01T00:00:00Z",
            "updatedAt": "2026-10-13T00:00:00Z", "repository": {"name": repo, "owner": {"login": "o"}},
            "assignees": {"nodes": [{"login": a} for a in assignees]}, "labels": {"nodes": []},
            "milestone": None, "closedByPullRequestsReferences": {"nodes": []},
            "issueType": None, "parent": None, "subIssues": {"nodes": []}}
    node.update(kw)
    return node


def values(status=None, iteration=None, priority=None):
    nodes = []
    if status:
        nodes.append({"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": status, "field": {"id": "F_S"}})
    if priority:
        nodes.append({"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": priority, "field": {"id": "F_P"}})
    if iteration:
        nodes.append({"__typename": "ProjectV2ItemFieldIterationValue", "iterationId": iteration,
                      "title": "Sprint", "field": {"id": "F_I"}})
    return {"nodes": nodes}


def item(content, fv=None, archived=False, iid=None):
    return {"id": iid or "ITEM_%s" % content.get("number", "x"), "isArchived": archived,
            "fieldValues": fv or {"nodes": []}, "content": content}


def in_project(node, fv):
    node = dict(node)
    node["projectItems"] = {"nodes": [{"id": "ITEM_%d" % node["number"], "project": {"id": "PRJ"},
                                       "fieldValues": fv}]}
    return node


class Fake(gh.Client):
    """GraphQL answered from `graphql` (a word in the query -> data, or a
    function of the variables), REST from `rest` ((method, path prefix) ->
    body); every call is kept in `calls`."""

    def __init__(self, graphql=None, rest=None):
        gh.Client.__init__(self, API, "t")
        self.calls = []
        answers = {"viewer": {"viewer": {"login": "me"}}, "projectV2(number": {"repositoryOwner": {
            "projectV2": project()}}, "issueTypes": {"repository": {"issueTypes": {"nodes": []}}}}
        answers.update(graphql or {})
        rest = rest or {}

        def fetch(method, url, token, data=None):
            path = url[len(API):]
            self.calls.append((method, path, data))
            if path == "/graphql":
                for word, ans in answers.items():
                    if word in data["query"]:
                        if isinstance(ans, Exception):
                            raise ans
                        return {"data": ans(data.get("variables") or {}) if callable(ans) else ans}
                raise AssertionError("unexpected query: " + data["query"][:120])
            for (m, prefix), ans in rest.items():
                if m == method and path.startswith(prefix):
                    return ans
            return {}
        self.fetch = fetch

    def gql(self, word):
        """The variables of every GraphQL call whose query has `word`."""
        return [d["variables"] for m, p, d in self.calls if p == "/graphql" and word in d["query"]]

    def rest_calls(self, method=None):
        return [(m, p, d) for m, p, d in self.calls if p != "/graphql" and (method is None or m == method)]


def account(**issues):
    issues.setdefault("project", "3")
    return ac.AccountConfig(host="github", owner="o", issues=issues)


def run(client, flag, *rest, env=None, **issues):
    acts = gi.IssueActions(account(**issues), env or {}, client, today=TODAY)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = acts.run(flag, list(rest))
    return code, out.getvalue(), err.getvalue()


def lines(out):
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def items_answer(*items):
    return {"node": {"items": {"pageInfo": {"hasNextPage": False}, "nodes": list(items)}}}


class Base(unittest.TestCase):
    def setUp(self):
        gi._project_cache.clear()


class SprintTests(Base):
    def test_sprints_from_the_iteration_field(self):
        c = Fake({"issueTypes": {"repository": {"issueTypes": {"nodes": [{"name": "Task"}, {"name": "Bug"}]}}}})
        code, out, _ = run(c, "--wi-list", "sprints")
        self.assertEqual(code, 0)
        s = lines(out)[0]
        self.assertTrue(s["_sprints"])
        self.assertEqual([x["path"] for x in s["sprints"]], ["it0", "it1", "it2", "it3"])
        self.assertEqual(s["currentIndex"], 3)
        cur = s["sprints"][2]
        self.assertEqual((cur["current"], cur["timeframe"]), (True, "current"))
        self.assertEqual((cur["start"], cur["finish"]), ("2026-10-07T00:00:00Z", "2026-10-20T00:00:00Z"))
        self.assertEqual(s["sprints"][0]["timeframe"], "past")
        self.assertEqual(s["states"], ["Todo", "In Progress", "Done", "Closed"])
        self.assertEqual(s["types"], ["Task", "Bug"])
        self.assertEqual(s["quarter"], "Board")

    def test_only_the_last_few_finished_iterations_are_tabs(self):
        many = dict(ITERATION, configuration={"iterations": [], "completedIterations": [
            {"id": "c%d" % i, "title": "C%d" % i, "startDate": "2026-0%d-01" % (i + 1), "duration": 7}
            for i in range(6)]})
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(fields=(STATUS, many))}}})
        s = lines(run(c, "--wi-list", "sprints")[1])[0]
        self.assertEqual([x["path"] for x in s["sprints"]], ["c3", "c4", "c5"])
        self.assertEqual(s["currentIndex"], 3)  # between iterations: the last one

    def test_milestones_without_an_iteration_field(self):
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(fields=(STATUS,))}}},
                 rest={("GET", "/repos/o/r/milestones"): [
                     {"number": 4, "title": "v1", "due_on": "2026-11-01T00:00:00Z", "created_at": "x"},
                     {"number": 6, "title": "v2", "due_on": None, "created_at": "y"}]})
        s = lines(run(c, "--wi-list", "sprints")[1])[0]
        self.assertEqual([x["path"] for x in s["sprints"]], ["milestone/4", "milestone/6"])
        self.assertTrue(s["sprints"][0]["current"])
        self.assertEqual(s["types"], ["Issue"])

    def test_the_whole_project_when_there_are_no_sprints(self):
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(fields=(STATUS,))}}},
                 rest={("GET", "/repos/o/r/milestones"): []})
        s = lines(run(c, "--wi-list", "sprints")[1])[0]
        self.assertEqual([x["path"] for x in s["sprints"]], ["*"])

    def test_a_project_by_title_on_the_viewer(self):
        c = Fake({"projectsV2(": {"repositoryOwner": {"projectsV2": {"nodes": [
            dict(project(), title="Other"), dict(project(), title="Road Map")]}}}})
        acts = gi.IssueActions(ac.AccountConfig(host="github", issues={"project": "road map"}), {}, c, today=TODAY)
        self.assertEqual(acts.project().title, "Road Map")
        self.assertEqual(c.gql("projectsV2(")[0]["login"], "me")

    def test_a_missing_project_says_where_to_fix_it(self):
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": None}}})
        code, _, err = run(c, "--wi-list", "sprints")
        self.assertEqual(code, 1)
        self.assertIn("issues: project:", err)


class ListTests(Base):
    def board(self, *items):
        return Fake({"items(first": items_answer(*items)})

    def test_current_is_my_items_in_the_current_iteration(self):
        c = self.board(
            item(issue(1), values("In Progress", "it2", "P1")),
            item(issue(2, assignees=("bob",)), values("Todo", "it2")),
            item(issue(3, state="CLOSED"), values("Done", "it2")),
            item(issue(4), values("Todo", "it3")),
            item(issue(5), values("Todo", "it2"), archived=True),
            item({"__typename": "DraftIssue", "title": "draft"}, values("Todo", "it2")),
            item({"__typename": "PullRequest", "number": 9}, values("Todo", "it2")))
        code, out, _ = run(c, "--wi-list", "current")
        self.assertEqual(code, 0)
        meta, *recs = lines(out)
        self.assertEqual((meta["_meta"], meta["timeframe"], meta["sprintPath"], meta["nextSprintPath"]),
                         (True, "current", "it2", "it3"))
        self.assertEqual(meta["states"][-1], "Closed")
        self.assertEqual([r["id"] for r in recs], [1, 3])
        self.assertEqual(recs[1]["state"], "Closed")

    def test_scope_all_shows_everyone_s(self):
        c = self.board(item(issue(1, assignees=()), values(None, "it2")),
                       item(issue(2, assignees=("bob",)), values("Todo", "it2")))
        recs = lines(run(c, "--wi-list", "current", scope="all")[1])[1:]
        self.assertEqual([(r["id"], r["state"]) for r in recs], [(1, "No Status"), (2, "Todo")])

    def test_next(self):
        c = self.board(item(issue(4), values("Todo", "it3")))
        meta, rec = lines(run(c, "--wi-list", "next")[1])
        self.assertEqual((meta["timeframe"], meta["sprintPath"]), ("next", "it3"))
        self.assertEqual(rec["id"], 4)

    def test_record_fields(self):
        node = issue(7, labels={"nodes": [{"name": "bug"}, {"name": "ui"}]}, issueType={"name": "Bug"},
                     parent={"number": 2, "repository": {"name": "r", "owner": {"login": "o"}}},
                     subIssues={"nodes": [{"number": 8}, {"number": 9}]},
                     closedByPullRequestsReferences={"nodes": [{"number": 30, "repository": {"name": "r"}}]})
        c = self.board(item(node, values("In Progress", "it2", "P2")))
        rec = lines(run(c, "--wi-list", "items", "it2")[1])[0]
        self.assertEqual(rec["type"], "Bug")
        self.assertEqual(rec["title"], "Issue 7")
        self.assertEqual(rec["state"], "In Progress")
        self.assertEqual(rec["priority"], 3)
        self.assertEqual(rec["tags"], "bug; ui")
        self.assertEqual((rec["parentId"], rec["childIds"]), (2, [8, 9]))
        self.assertEqual(rec["pullRequests"], [{"id": 30, "repo": "r"}])
        self.assertEqual((rec["repo"], rec["key"]), ("r", "o~r~7"))
        self.assertEqual(rec["assignedTo"], "me")

    def test_milestone_items(self):
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(fields=(STATUS,))}},
                  "items(first": items_answer(item(issue(1, milestone={"number": 4, "title": "v1"}), values("Todo")),
                                              item(issue(2), values("Todo")))})
        recs = lines(run(c, "--wi-list", "items", "milestone/4")[1])
        self.assertEqual([r["id"] for r in recs], [1])

    def test_items_are_paged(self):
        pages = [{"node": {"items": {"pageInfo": {"hasNextPage": True, "endCursor": "c1"},
                                     "nodes": [item(issue(1), values("Todo", "it2"))]}}},
                 {"node": {"items": {"pageInfo": {"hasNextPage": False},
                                     "nodes": [item(issue(2), values("Todo", "it2"))]}}}]
        c = Fake({"items(first": lambda v: pages[0] if not v.get("after") else pages[1]})
        recs = lines(run(c, "--wi-list", "items", "it2")[1])
        self.assertEqual([r["id"] for r in recs], [1, 2])

    def test_members_are_logins(self):
        c = Fake({"assignableUsers": {"repository": {"assignableUsers": {"nodes": [
            {"login": "me", "name": "Me"}, {"login": "bob", "name": None}]}}}})
        self.assertEqual(lines(run(c, "--wi-list", "members")[1]), [{"name": "me", "email": ""},
                                                                     {"name": "bob", "email": ""}])

    def test_tree_follows_sub_issues(self):
        r = {"name": "r", "owner": {"login": "o"}}
        nodes = {1: issue(1, subIssues={"nodes": [{"number": 2, "repository": r}]}),
                 2: issue(2, subIssues={"nodes": [{"number": 3, "repository": r}]}, parent={"number": 1}),
                 3: issue(3, parent={"number": 2})}
        c = Fake({"issue(number": lambda v: {"repository": {"issue": in_project(nodes[v["number"]], values("Todo"))}}})
        recs = lines(run(c, "--wi-list", "tree", "o/r#1")[1])
        self.assertEqual([(x["id"], x["parentId"]) for x in recs], [(2, 1), (3, 2)])

    def test_old_servers_without_sub_issues(self):
        # The full query (it asks for subIssues) fails; the lite one answers.
        c = Fake({"subIssues": RuntimeError("GitHub GraphQL: Field 'subIssues' doesn't exist on type 'Issue'"),
                  "items(first": items_answer(item(issue(1), values("Todo", "it2")))})
        code, out, _ = run(c, "--wi-list", "items", "it2")
        self.assertEqual(code, 0)
        self.assertEqual([r["id"] for r in lines(out)], [1])
        self.assertEqual(len(c.gql("items(first")), 2)


class IdTests(Base):
    def test_a_number_two_repos_share_is_refused(self):
        c = Fake({"items(first": items_answer(item(issue(5, repo="a"), values("Todo")),
                                              item(issue(5, repo="b"), values("Todo")))},
                 rest={})
        code, _, err = run(c, "--wi-edit", "comment", "5", "hi")
        self.assertEqual(code, 1)
        self.assertIn("o/a#5, o/b#5", err)
        self.assertEqual(c.rest_calls(), [])

    def test_owner_repo_number_and_key_are_taken_as_they_are(self):
        c = Fake(rest={("POST", "/repos/o/b/issues/5/comments"): {"id": 77}})
        self.assertEqual(run(c, "--wi-edit", "comment", "o/b#5", "hi")[0], 0)
        self.assertEqual(run(c, "--wi-edit", "comment", "o~b~5", "hi")[1].strip(), '{"id": 77}')
        self.assertEqual(c.gql("items(first"), [])

    def test_a_number_not_in_the_project_goes_to_the_default_repo(self):
        c = Fake({"items(first": items_answer()}, rest={("POST", "/repos/o/r/issues/12/comments"): {"id": 1}})
        self.assertEqual(run(c, "--wi-edit", "comment", "12", "hi")[0], 0)


class DetailTests(Base):
    def test_detail(self):
        r = {"name": "r", "owner": {"login": "o"}}
        node = in_project(issue(7, body="**Hi**\n\n- a", author={"login": "alice"}, stateReason=None,
                                parent={"number": 2, "title": "Epic", "state": "OPEN", "repository": r,
                                        "assignees": {"nodes": []}, "issueType": {"name": "Feature"},
                                        "projectItems": {"nodes": [{"project": {"id": "PRJ"},
                                                                    "fieldValues": values("In Progress")}]}},
                                subIssues={"nodes": [{"number": 8, "title": "Child", "state": "CLOSED",
                                                      "repository": r, "assignees": {"nodes": [{"login": "bob"}]},
                                                      "projectItems": {"nodes": []}}]},
                                comments={"nodes": [{"databaseId": 5, "body": "c1", "createdAt": "t",
                                                     "author": {"login": "bob"}}]},
                                closedByPullRequestsReferences={"nodes": [
                                    {"number": 30, "title": "Fix", "url": "u", "state": "OPEN", "isDraft": True,
                                     "headRefName": "f", "baseRefName": "main", "author": {"login": "me"},
                                     "repository": r}]}),
                         values("In Progress", "it2", "P0"))
        c = Fake({"issue(number": {"repository": {"issue": node}}})
        code, out, _ = run(c, "--wi-detail", "o/r#7")
        self.assertEqual(code, 0)
        d = json.loads(out)
        self.assertEqual(d["item"]["description"], "**Hi**\n\n- a")
        self.assertEqual((d["item"]["state"], d["item"]["priority"], d["item"]["iterationPath"]),
                         ("In Progress", 1, "Sprint"))
        self.assertEqual(d["item"]["createdBy"], "alice")
        self.assertEqual(d["parent"], {"id": 2, "type": "Feature", "state": "In Progress", "title": "Epic",
                                       "assignedTo": ""})
        self.assertEqual(d["children"][0]["state"], "Closed")
        self.assertEqual(d["comments"], [{"id": 5, "author": "bob", "date": "t", "text": "c1"}])
        self.assertEqual(d["item"]["pullRequests"][0], {"id": 30, "title": "Fix", "status": "active", "isDraft": True,
                                                        "repo": "r", "source": "f", "target": "main",
                                                        "author": "me", "url": "u"})
        self.assertFalse(d["commentsUnsupported"])


class StateTests(Base):
    def test_states_transitions_reasons(self):
        c = Fake()
        self.assertEqual(run(c, "--wi-state", "states", "Issue")[1].splitlines(),
                         ["Todo\tProposed", "In Progress\tInProgress", "Done\tCompleted", "Closed\tCompleted"])
        self.assertEqual(run(c, "--wi-state", "transitions", "Issue", "Todo")[1].splitlines(),
                         ["In Progress", "Done", "Closed"])
        self.assertEqual(run(c, "--wi-state", "reasons", "Issue", "Closed")[1].splitlines(),
                         ["completed", "not planned"])
        self.assertEqual(run(c, "--wi-state", "reasons", "Issue", "Done")[1], "")

    def issue_client(self, node):
        return Fake({"issue(number": {"repository": {"issue": node}},
                     "updateProjectV2ItemFieldValue": {}, "closeIssue": {}, "reopenIssue": {},
                     "addProjectV2ItemById": {"addProjectV2ItemById": {"item": {"id": "NEW_ITEM"}}}})

    def test_a_status_option_sets_the_field_and_reopens(self):
        c = self.issue_client(in_project(issue(4, state="CLOSED"), values("Done")))
        code, out, _ = run(c, "--wi-state", "set", "o/r#4", "In Progress")
        self.assertEqual((code, out.strip()), (0, "In Progress"))
        self.assertEqual(c.gql("updateProjectV2ItemFieldValue"), [
            {"project": "PRJ", "item": "ITEM_4", "field": "F_S", "value": {"singleSelectOptionId": "O_P"}}])
        self.assertEqual(c.gql("reopenIssue"), [{"id": "I_r_4"}])
        self.assertEqual(c.gql("closeIssue"), [])

    def test_an_issue_outside_the_project_is_added_first(self):
        c = self.issue_client(dict(issue(4), projectItems={"nodes": []}))
        run(c, "--wi-state", "set", "o/r#4", "Todo")
        self.assertEqual(c.gql("addProjectV2ItemById"), [{"project": "PRJ", "content": "I_r_4"}])
        self.assertEqual(c.gql("updateProjectV2ItemFieldValue")[0]["item"], "NEW_ITEM")

    def test_done_does_not_close(self):
        c = self.issue_client(in_project(issue(4), values("In Progress")))
        run(c, "--wi-state", "set", "o/r#4", "Done")
        self.assertEqual(c.gql("closeIssue"), [])

    def test_closed_closes_with_its_reason(self):
        c = self.issue_client(in_project(issue(4), values("Todo")))
        code, out, _ = run(c, "--wi-state", "set", "o/r#4", "Closed", "not planned")
        self.assertEqual((code, out.strip()), (0, "Closed"))
        self.assertEqual(c.gql("closeIssue"), [{"id": "I_r_4", "reason": "NOT_PLANNED"}])
        run(c, "--wi-state", "set", "o/r#4", "Closed")
        self.assertEqual(c.gql("closeIssue")[-1]["reason"], "COMPLETED")

    def test_an_unknown_state_is_refused(self):
        c = self.issue_client(in_project(issue(4), values("Todo")))
        code, _, err = run(c, "--wi-state", "set", "o/r#4", "Active")
        self.assertEqual(code, 1)
        self.assertIn("Todo, In Progress, Done, Closed", err)

    def test_validate_only_writes_nothing(self):
        c = self.issue_client(in_project(issue(4), values("Todo")))
        code, out, _ = run(c, "--wi-state", "set", "o/r#4", "Done", env={"AZVICLI_WI_VALIDATE_ONLY": "1"})
        self.assertEqual((code, out.strip()), (0, "Done"))
        self.assertEqual(c.gql("updateProjectV2ItemFieldValue"), [])


class EditTests(Base):
    def test_create(self):
        c = Fake({"issueTypes": {"repository": {"issueTypes": {"nodes": [{"name": "Task"}, {"name": "Bug"}]}}},
                  "addProjectV2ItemById": {"addProjectV2ItemById": {"item": {"id": "ITEM_NEW"}}},
                  "updateProjectV2ItemFieldValue": {}},
                 rest={("POST", "/repos/o/r/issues/2/sub_issues"): {},
                       ("POST", "/repos/o/r/issues"): {"number": 40, "id": 9040, "node_id": "I_40", "title": "New"}})
        code, out, _ = run(c, "--wi-edit", "create", "Task", "New", "o/r#2", "it3")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"id": 40, "title": "New", "key": "o~r~40"})
        posts = c.rest_calls("POST")
        self.assertEqual(posts[0], ("POST", "/repos/o/r/issues", {"title": "New", "assignees": ["me"], "type": "Task"}))
        self.assertEqual(posts[1], ("POST", "/repos/o/r/issues/2/sub_issues", {"sub_issue_id": 9040}))
        self.assertEqual(c.gql("addProjectV2ItemById"), [{"project": "PRJ", "content": "I_40"}])
        self.assertEqual(c.gql("updateProjectV2ItemFieldValue")[0]["value"], {"iterationId": "it3"})

    def test_create_without_issue_types_sends_none(self):
        c = Fake({"addProjectV2ItemById": {"addProjectV2ItemById": {"item": {"id": "X"}}}},
                 rest={("POST", "/repos/o/r/issues"): {"number": 41, "id": 1, "node_id": "I_41", "title": "T"}})
        run(c, "--wi-edit", "create", "Issue", "T")
        self.assertNotIn("type", c.rest_calls("POST")[0][2])

    def test_create_needs_a_repo_when_the_project_has_several(self):
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(repos=(("o", "a"), ("o", "b")))}}})
        code, _, err = run(c, "--wi-edit", "create", "Issue", "T")
        self.assertEqual(code, 1)
        self.assertIn("issues: repo:", err)
        self.assertEqual(c.rest_calls("POST"), [])
        c2 = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(repos=(("o", "a"), ("o", "b")))}},
                   "addProjectV2ItemById": {"addProjectV2ItemById": {"item": {"id": "X"}}}},
                  rest={("POST", "/repos/o/b/issues"): {"number": 1, "id": 1, "node_id": "N", "title": "T"}})
        self.assertEqual(run(c2, "--wi-edit", "create", "Issue", "T", repo="b")[0], 0)

    def test_a_failure_after_creating_says_the_issue_exists(self):
        c = Fake({"addProjectV2ItemById": RuntimeError("GitHub GraphQL: Resource not accessible")},
                 rest={("POST", "/repos/o/r/issues"): {"number": 42, "id": 1, "node_id": "N", "title": "T"}})
        code, out, _ = run(c, "--wi-edit", "create", "Issue", "T")
        self.assertEqual(code, 0)
        self.assertIn("created o/r#42, but", json.loads(out)["warning"])

    def test_set_fields(self):
        node = in_project(issue(4), values("Todo"))
        c = Fake({"issue(number": {"repository": {"issue": node}}, "updateProjectV2ItemFieldValue": {},
                  "clearProjectV2ItemFieldValue": {}})
        out = lambda *a: json.loads(run(c, "--wi-edit", "set", "o/r#4", *a)[1])  # noqa: E731
        self.assertEqual(out("title", "T2")["value"], "T2")
        self.assertEqual(out("assignedTo", "")["value"], "me")
        self.assertEqual(out("tags", "bug; ui")["value"], "bug; ui")
        self.assertEqual(out("description", "body")["value"], "body")
        self.assertEqual(out("priority", "2")["value"], 2)
        self.assertEqual(out("iteration", "it3")["field"], "iteration")
        out("iteration", "")
        self.assertEqual([d for _, _, d in c.rest_calls("PATCH")],
                         [{"title": "T2"}, {"assignees": ["me"]}, {"labels": ["bug", "ui"]}, {"body": "body"}])
        self.assertEqual([v["value"] for v in c.gql("updateProjectV2ItemFieldValue")],
                         [{"singleSelectOptionId": "P_1"}, {"iterationId": "it3"}])
        self.assertEqual(c.gql("clearProjectV2ItemFieldValue"), [{"project": "PRJ", "item": "ITEM_4", "field": "F_I"}])

    def test_iteration_is_a_milestone_without_an_iteration_field(self):
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(fields=(STATUS,))}},
                  "issue(number": {"repository": {"issue": in_project(issue(4), values("Todo"))}}})
        run(c, "--wi-edit", "set", "o/r#4", "iteration", "milestone/6")
        self.assertEqual(c.rest_calls("PATCH"), [("PATCH", "/repos/o/r/issues/4", {"milestone": 6})])

    def test_unknown_field(self):
        code, _, err = run(Fake(), "--wi-edit", "set", "o/r#4", "areaPath", "x")
        self.assertEqual(code, 1)
        self.assertIn("unknown field", err)

    def test_not_on_github_yet(self):
        for cmd in ("link-pr", "unlink-pr", "create-branch", "delete-branch"):
            code, _, err = run(Fake(), "--wi-edit", cmd, "1")
            self.assertEqual(code, 1)
            self.assertIn("isn't supported for GitHub issues yet", err)

    def test_a_missing_project_scope_says_how_to_add_it(self):
        c = Fake({"projectV2(number": RuntimeError(
            "GitHub GraphQL: Your token has not been granted the required scopes: ['read:project']")})
        code, _, err = run(c, "--wi-list", "sprints")
        self.assertEqual(code, 2)
        self.assertIn("gh auth refresh -s project", err)


class DoctorTests(Base):
    def test_the_doctor_line_names_the_fields(self):
        self.assertEqual(gi.check_project(account(), Fake()),
                         (True, "project 'Board' (#3): Status, Iteration, Priority"))
        gi._project_cache.clear()
        c = Fake({"projectV2(number": {"repositoryOwner": {"projectV2": project(fields=(STATUS,))}}})
        self.assertIn("no Iteration field (milestones are the sprints)", gi.check_project(account(), c)[1])


class ConfigTests(unittest.TestCase):
    def test_inline_and_block_issues(self):
        cfg = ac.Config.from_string("accounts:\n  - host: github\n    owner: o\n    issues: { project: 3, scope: all }\n"
                                    "  - host: github\n    owner: p\n    issues:\n      project: Road Map\n")
        self.assertEqual(cfg.accounts[0].issues, {"project": "3", "scope": "all"})
        self.assertEqual(cfg.accounts[1].issues, {"project": "Road Map"})
        self.assertEqual(cfg.problems(), [])

    def test_issues_problems(self):
        cfg = ac.Config.from_dict({"accounts": [
            {"host": "github", "issues": {"scope": "team"}},
            {"project_name": "P", "org_url": "https://dev.azure.com/x", "pat": "t", "issues": {"project": 1}}]})
        problems = " | ".join(cfg.problems())
        self.assertIn("needs project:", problems)
        self.assertIn("scope: must be mine or all", problems)
        self.assertIn("issues: is for a GitHub account", problems)

    def test_which_account_answers(self):
        cfg = ac.Config.from_dict({"accounts": [
            {"project_name": "P", "org_url": "https://dev.azure.com/x", "pat": "t", "work_items": {"team": "T"}},
            {"host": "github", "owner": "a"},
            {"host": "github", "owner": "b", "issues": {"project": 1}},
            {"host": "github", "owner": "c", "issues": {"project": 2}}]})
        self.assertEqual(ac._wi_select_account(cfg, {}).project, "P")
        # Without AZVICLI_WI_HOST, a GitHub account is never the answer.
        self.assertIsNone(ac._wi_select_account(cfg, {"AZVICLI_WI_ACCOUNT": "b"}))
        gh_only = ac.Config.from_dict({"accounts": [{"host": "github", "owner": "b", "issues": {"project": 1}}]})
        self.assertIsNone(ac._wi_select_account(gh_only, {}))
        self.assertEqual(ac._wi_select_github_account(cfg, {}).owner, "b")
        self.assertEqual(ac._wi_select_github_account(cfg, {"AZVICLI_WI_ACCOUNT": "C"}).owner, "c")
        self.assertIsNone(ac._wi_select_github_account(cfg, {"AZVICLI_WI_ACCOUNT": "a"}))
        azure_only = ac.Config.from_dict({"accounts": [{"project_name": "P", "org_url": "https://x", "pat": "t"}]})
        self.assertIsNone(ac._wi_select_github_account(azure_only, {}))

    def test_the_issues_tab_without_an_issues_block(self):
        env = {"AZVICLI_WI_HOST": "github"}
        cfg = ac.Config.from_dict({"accounts": [{"project_name": "P", "org_url": "https://x", "pat": "t"}]})
        err = io.StringIO()
        orig = (ac.Config.validate_exists, ac.get_cached_config)
        ac.Config.validate_exists = staticmethod(lambda: True)
        ac.get_cached_config = lambda: cfg
        try:
            with contextlib.redirect_stderr(err):
                code = ac.cmd_wi_action("--wi-list", ["sprints"], env)
        finally:
            ac.Config.validate_exists, ac.get_cached_config = staticmethod(orig[0]), orig[1]
        self.assertEqual(code, 1)
        self.assertIn("No GitHub account has an issues: block", err.getvalue())


if __name__ == "__main__":
    unittest.main()
