#!/usr/bin/env python3
"""Unit tests for azure-cli.py's work-item subcommands (WorkItemActions) -
the python port of wi-list.sh/wi-detail.sh/wi-state.sh/wi-edit.sh.

Run standalone with `python3 -m unittest tests/test_work_items.py` or via
`bash tests/run.sh`. HTTP is mocked the same way test_pr_actions.py mocks
it: WorkItemActions.fetch (http_request-shaped) is swapped for a FakeFetch
that records every call (url, method, data, pat, api_version, raw,
content_type) and answers from an in-memory table - no network access
needed.

Before wi-list.sh/wi-detail.sh/wi-state.sh/wi-edit.sh were deleted, they
were read in full (see git history of this branch) and every URL, WIQL
shape, JSON Patch body and stdout/stderr message format below was taken
directly from their source - the assertions on exact URLs, request bodies
and printed lines are the byte-for-byte comparison the P2 task asked for,
done by inspection rather than a live mock http.server (the scripts
embedded their own python and never shelled out to anything a mock server
could intercept transport-independently; FakeFetch intercepts at the same
seam test_pr_actions.py already established for the PR-action port).
"""

import importlib.util
import json
import os
import unittest
from io import StringIO
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_work_items", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()


def make_config(collection="https://dev.azure.com/example-org", project="ExampleProject", pat="tok",
                 team="Example Team", assignee="Jordan Doe", types="User Story,Bug",
                 states=None, sprint_scope=None):
    """One account with a work_items: block - team/assignee/types default to
    the values every URL/WIQL/patch-body assertion below was written
    against (see WorkItemActionsTests). Pass team=None (etc.) to omit that
    key from the block entirely, e.g. to test the assignee identity-lookup
    fallback or the no-team "not configured" error. states/sprint_scope are
    None (omitted) by default - the "nothing configured" case every other
    test here should be unaffected by.
    """
    cfg = ac.Config()
    work_items = {}
    if team is not None:
        work_items["team"] = team
    if assignee is not None:
        work_items["assignee"] = assignee
    if types is not None:
        work_items["types"] = types
    if states is not None:
        work_items["states"] = states
    if sprint_scope is not None:
        work_items["sprint_scope"] = sprint_scope
    cfg.accounts = [ac.AccountConfig(project=project, org_url=collection, pat=pat, work_items=work_items or None)]
    return cfg


def make_bare_config(collection="https://dev.azure.com/example-org", project="ExampleProject", pat="tok"):
    """An account with no work_items: block at all - the "not configured"
    case (_wi_select_account finds nothing, so collection/project/team all
    come from AZVICLI_WI_* overrides only, if any).
    """
    cfg = ac.Config()
    cfg.accounts = [ac.AccountConfig(project=project, org_url=collection, pat=pat)]
    return cfg


class FakeFetchBare:
    """Swapped in for WorkItemActions.fetch_bare. Records every call and
    answers `response` regardless of url/pat - the identity lookup only
    ever calls it once, on connectionData.
    """

    def __init__(self, response=None):
        self.response = response if response is not None else {}
        self.calls = []

    def __call__(self, url, pat):
        self.calls.append({"url": url, "pat": pat})
        return self.response


class FakeFetch:
    """Swapped in for WorkItemActions.fetch. Records every call and answers
    from `responses` (url -> value, or -> a list of values consumed in
    order for a url called more than once), raising from `raise_for` (url ->
    exception instance) instead when present.
    """

    def __init__(self, responses=None, raise_for=None):
        self.responses = dict(responses or {})
        self.raise_for = dict(raise_for or {})
        self.calls = []

    def __call__(self, url, method="GET", data=None, pat=None, api_version="7.1", raw=False,
                 content_type="application/json"):
        self.calls.append({
            "url": url, "method": method, "data": data, "pat": pat,
            "api_version": api_version, "raw": raw, "content_type": content_type,
        })
        if url in self.raise_for:
            raise self.raise_for[url]
        resp = self.responses.get(url)
        if isinstance(resp, list):
            return resp.pop(0)
        if resp is not None:
            return resp
        return b"" if raw else {}


def make_actions(config=None, env_overrides=None):
    env = {}
    if env_overrides:
        env.update(env_overrides)
    actions = ac.WorkItemActions(config or make_config(), env)
    actions.pat = "tok"  # ensure_pat already resolved, in every test below
    return actions


# ---------------------------------------------------------------------------
# Defaults / env overrides / PAT resolution
# ---------------------------------------------------------------------------


class DefaultsAndPatTests(unittest.TestCase):
    def test_values_resolved_from_work_items_config_block(self):
        actions = make_actions()
        self.assertEqual(actions.collection, "https://dev.azure.com/example-org")
        self.assertEqual(actions.project, "ExampleProject")
        self.assertEqual(actions.team, "Example Team")
        self.assertEqual(actions.assignee, "Jordan Doe")
        self.assertEqual(actions.types, "User Story,Bug")
        self.assertFalse(actions.validate_only)

    def test_types_list_in_config_joins_to_comma_string(self):
        cfg = make_config(types=None)
        cfg.accounts[0].work_items["types"] = ["User Story", "Bug", "Task"]
        actions = make_actions(config=cfg)
        self.assertEqual(actions.types, "User Story,Bug,Task")

    def test_types_omitted_from_config_falls_back_to_default_pair(self):
        cfg = make_config(types=None)
        actions = make_actions(config=cfg)
        self.assertEqual(actions.types, "User Story,Bug")

    def test_azvicli_wi_env_vars_override_config(self):
        actions = make_actions(env_overrides={
            "AZVICLI_WI_COLLECTION": "https://dev.azure.com/other",
            "AZVICLI_WI_PROJECT": "OtherProj",
            "AZVICLI_WI_TEAM": "Other Team",
            "AZVICLI_WI_ASSIGNEE": "Someone Else",
            "AZVICLI_WI_TYPES": "Task",
            "AZVICLI_WI_VALIDATE_ONLY": "1",
        })
        self.assertEqual(actions.collection, "https://dev.azure.com/other")
        self.assertEqual(actions.project, "OtherProj")
        self.assertEqual(actions.team, "Other Team")
        self.assertEqual(actions.assignee, "Someone Else")
        self.assertEqual(actions.types, "Task")
        self.assertTrue(actions.validate_only)

    def test_no_work_items_block_and_no_overrides_leaves_team_blank(self):
        # _wi_select_account finds nothing to pick collection/project/team
        # from, and no AZVICLI_WI_* override fills them in either -
        # ensure_configured() (tested below) is what turns this into the
        # "add team: ..." error before any REST call is attempted.
        actions = make_actions(config=make_bare_config())
        self.assertEqual(actions.team, "")

    def test_states_and_sprint_scope_default_to_none_and_parent(self):
        # Neither is configured -> states.lua's own fallback (states=None)
        # and today's sprint-tab grouping (sprint_scope="parent").
        actions = make_actions()
        self.assertIsNone(actions.states)
        self.assertEqual(actions.sprint_scope, "parent")

    def test_states_list_in_config_is_kept_as_an_ordered_list(self):
        cfg = make_config(states=["New", "Active", "Implemented", "Resolved", "Closed", "Removed"])
        actions = make_actions(config=cfg)
        self.assertEqual(actions.states, ["New", "Active", "Implemented", "Resolved", "Closed", "Removed"])

    def test_states_comma_string_in_config_splits_to_a_list(self):
        cfg = make_config(states="New, Active, Closed")
        actions = make_actions(config=cfg)
        self.assertEqual(actions.states, ["New", "Active", "Closed"])

    def test_states_empty_list_is_none(self):
        cfg = make_config(states=[])
        actions = make_actions(config=cfg)
        self.assertIsNone(actions.states)

    def test_sprint_scope_all_is_lowercased(self):
        cfg = make_config(sprint_scope="ALL")
        actions = make_actions(config=cfg)
        self.assertEqual(actions.sprint_scope, "all")

    def test_azvicli_wi_account_selects_by_project_name(self):
        cfg = ac.Config()
        cfg.accounts = [
            ac.AccountConfig(project="First", org_url="https://dev.azure.com/first", pat="tok1",
                              work_items={"team": "First Team"}),
            ac.AccountConfig(project="Second", org_url="https://dev.azure.com/second", pat="tok2",
                              work_items={"team": "Second Team"}),
        ]
        default_actions = make_actions(config=cfg)  # first account with a work_items: block wins
        self.assertEqual(default_actions.project, "First")
        self.assertEqual(default_actions.team, "First Team")

        picked = make_actions(config=cfg, env_overrides={"AZVICLI_WI_ACCOUNT": "Second"})
        self.assertEqual(picked.project, "Second")
        self.assertEqual(picked.team, "Second Team")

    def test_first_account_without_work_items_is_skipped(self):
        cfg = ac.Config()
        cfg.accounts = [
            ac.AccountConfig(project="NoWi", org_url="https://dev.azure.com/nowi", pat="tok1"),
            ac.AccountConfig(project="HasWi", org_url="https://dev.azure.com/haswi", pat="tok2",
                              work_items={"team": "The Team"}),
        ]
        actions = make_actions(config=cfg)
        self.assertEqual(actions.project, "HasWi")
        self.assertEqual(actions.team, "The Team")

    def test_assignee_falls_back_to_identity_lookup_when_not_configured(self):
        cfg = make_config(assignee=None)
        actions = make_actions(config=cfg)
        actions.fetch_bare = FakeFetchBare({"authenticatedUser": {"customDisplayName": "Signed In User"}})
        self.assertEqual(actions.assignee, "Signed In User")
        call = actions.fetch_bare.calls[0]
        self.assertEqual(call["url"], "https://dev.azure.com/example-org/_apis/connectionData")
        self.assertEqual(call["pat"], "tok")

    def test_assignee_identity_lookup_is_cached(self):
        cfg = make_config(assignee=None)
        actions = make_actions(config=cfg)
        actions.fetch_bare = FakeFetchBare({"authenticatedUser": {"customDisplayName": "Signed In User"}})
        self.assertEqual(actions.assignee, "Signed In User")
        self.assertEqual(actions.assignee, "Signed In User")
        self.assertEqual(len(actions.fetch_bare.calls), 1)

    def test_assignee_identity_lookup_falls_back_to_provider_display_name(self):
        cfg = make_config(assignee=None)
        actions = make_actions(config=cfg)
        actions.fetch_bare = FakeFetchBare({"authenticatedUser": {"providerDisplayName": "Provider Name"}})
        self.assertEqual(actions.assignee, "Provider Name")

    def test_assignee_identity_lookup_failure_is_blank_not_raised(self):
        cfg = make_config(assignee=None)
        actions = make_actions(config=cfg)

        def boom(url, pat):
            raise RuntimeError("network down")
        actions.fetch_bare = boom
        self.assertEqual(actions.assignee, "")

    def test_ensure_configured_fails_without_team(self):
        actions = make_actions(config=make_bare_config())
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            ok = actions.ensure_configured()
        self.assertFalse(ok)
        self.assertIn("No account has a work_items: block in azure-cli.yml", buf.getvalue())
        self.assertIn("add team:", buf.getvalue())

    def test_ensure_configured_passes_with_team_from_config(self):
        self.assertTrue(make_actions().ensure_configured())

    def test_ensure_configured_passes_with_team_from_env_only(self):
        actions = make_actions(config=make_bare_config(), env_overrides={"AZVICLI_WI_TEAM": "Env Team"})
        self.assertTrue(actions.ensure_configured())

    def test_ensure_pat_no_match_prints_diagnostic(self):
        cfg = make_config(collection="https://dev.azure.com/example-org")
        actions = ac.WorkItemActions(cfg, {"AZVICLI_WI_COLLECTION": "https://dev.azure.com/other-org"})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            ok = actions.ensure_pat()
        self.assertFalse(ok)
        self.assertIn("no PAT available", buf.getvalue())
        self.assertIn("azure-cli.yml", buf.getvalue())

    def test_ensure_pat_matches_config_account(self):
        cfg = make_config()
        actions = ac.WorkItemActions(cfg, {})
        self.assertTrue(actions.ensure_pat())
        self.assertEqual(actions.pat, "tok")


# ---------------------------------------------------------------------------
# Pure helpers: sprint resolution, html_to_text, pr-id extraction
# ---------------------------------------------------------------------------


def iteration(path, timeframe=None, start=None, finish=None, name=None):
    attrs = {}
    if timeframe is not None:
        attrs["timeFrame"] = timeframe
    if start is not None:
        attrs["startDate"] = start
    if finish is not None:
        attrs["finishDate"] = finish
    it = {"path": path, "attributes": attrs}
    if name is not None:
        it["name"] = name
    return it


class SprintResolutionTests(unittest.TestCase):
    def test_resolve_current_prefers_explicit_timeframe(self):
        iters = [
            iteration("Q\\S1", timeframe="past"),
            iteration("Q\\S2", timeframe="current"),
            iteration("Q\\S3", timeframe="future"),
        ]
        cur = ac._wi_resolve_current_sprint(iters)
        self.assertEqual(cur["path"], "Q\\S2")

    def test_resolve_current_falls_back_to_date_range(self):
        now = ac.datetime.now(ac.timezone.utc)
        past = (now - ac.timedelta(days=10)).isoformat()
        future = (now + ac.timedelta(days=10)).isoformat()
        iters = [iteration("Q\\S1", start=past, finish=future)]
        cur = ac._wi_resolve_current_sprint(iters)
        self.assertEqual(cur["path"], "Q\\S1")

    def test_resolve_current_none_when_nothing_matches(self):
        self.assertIsNone(ac._wi_resolve_current_sprint([]))

    def test_resolve_next_by_start_date_order(self):
        iters = [
            iteration("Q\\S1", start="2026-01-01T00:00:00Z"),
            iteration("Q\\S2", start="2026-02-01T00:00:00Z"),
            iteration("Q\\S3", start="2026-03-01T00:00:00Z"),
        ]
        cur = iters[1]
        nxt = ac._wi_resolve_next_sprint(iters, cur)
        self.assertEqual(nxt["path"], "Q\\S3")

    def test_resolve_next_none_when_current_is_last(self):
        iters = [
            iteration("Q\\S1", start="2026-01-01T00:00:00Z"),
            iteration("Q\\S2", start="2026-02-01T00:00:00Z"),
        ]
        cur = iters[1]
        self.assertIsNone(ac._wi_resolve_next_sprint(iters, cur))

    def test_resolve_next_falls_back_to_future_timeframe_when_current_undated(self):
        # cur has no startDate, so the dated-list walk never finds cur.path -
        # falls back to the earliest "future" timeframe iteration.
        iters = [
            iteration("Q\\S1"),
            iteration("Q\\S2", timeframe="future", start="2026-05-01T00:00:00Z"),
            iteration("Q\\S3", timeframe="future", start="2026-04-01T00:00:00Z"),
        ]
        cur = iters[0]
        nxt = ac._wi_resolve_next_sprint(iters, cur)
        self.assertEqual(nxt["path"], "Q\\S3")  # earliest of the two future ones

    def test_sprint_name_prefers_name_field(self):
        self.assertEqual(ac._wi_sprint_name({"name": "Sprint 3", "path": "Q\\Sprint 3"}), "Sprint 3")

    def test_sprint_name_falls_back_to_path_tail(self):
        self.assertEqual(ac._wi_sprint_name({"path": "2026\\Q3\\Sprint 3"}), "Sprint 3")

    def test_sprint_name_none_iteration_is_blank(self):
        self.assertEqual(ac._wi_sprint_name(None), "")


class HtmlToTextTests(unittest.TestCase):
    def test_empty_or_none_is_blank(self):
        self.assertEqual(ac.html_to_text(""), "")
        self.assertEqual(ac.html_to_text(None), "")

    def test_block_tags_become_newlines(self):
        # Both the start and end tag of a block element emit a newline (see
        # _HtmlTextParser), so two adjacent divs land two apart, not one -
        # matches wi-detail.sh's _Text parser exactly.
        self.assertEqual(ac.html_to_text("<div>a</div><div>b</div>"), "a\n\nb")

    def test_li_becomes_dash_bullet(self):
        out = ac.html_to_text("<ul><li>one</li><li>two</li></ul>")
        self.assertIn("- one", out)
        self.assertIn("- two", out)

    def test_collapses_runs_of_whitespace_and_blank_lines(self):
        out = ac.html_to_text("<p>a</p>\n\n\n\n<p>b</p>")
        self.assertNotIn("\n\n\n", out)

    def test_plain_text_with_no_tags(self):
        self.assertEqual(ac.html_to_text("just text"), "just text")


class PrIdsFromRelationsTests(unittest.TestCase):
    def test_extracts_encoded_pr_id(self):
        rels = [{"rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/proj%2Frepo%2F123"}]
        self.assertEqual(ac._wi_pr_ids_from_relations(rels), [{"id": 123}])

    def test_ignores_non_artifact_or_non_pr_relations(self):
        rels = [
            {"rel": "System.LinkTypes.Hierarchy-Forward", "url": "x/workItems/9"},
            {"rel": "ArtifactLink", "url": "vstfs:///Git/Commit/abc"},
        ]
        self.assertEqual(ac._wi_pr_ids_from_relations(rels), [])

    def test_none_relations_is_empty_list(self):
        self.assertEqual(ac._wi_pr_ids_from_relations(None), [])


# ---------------------------------------------------------------------------
# --wi-list
# ---------------------------------------------------------------------------


ITERS_URL = "https://dev.azure.com/example-org/ExampleProject/Example%20Team/_apis/work/teamsettings/iterations?timeframe=all"
AREAS_URL = "https://dev.azure.com/example-org/ExampleProject/Example%20Team/_apis/work/teamsettings/teamfieldvalues"
WIQL_URL = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/wiql"
BATCH_URL = "https://dev.azure.com/example-org/_apis/wit/workitemsbatch"


class WiListTests(unittest.TestCase):
    def test_invalid_selector_is_rejected(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_list("bogus")
        self.assertEqual(rc, 1)
        self.assertIn("selector must be current|next|sprints|items", buf.getvalue())

    def test_items_without_path_is_rejected(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_list("items", "")
        self.assertEqual(rc, 1)

    def test_current_emits_meta_line_then_wiql_and_batch(self):
        actions = make_actions()
        iters = {"value": [
            iteration("2026\\Q3\\S1", timeframe="current", start="2026-07-01T00:00:00Z",
                      finish="2026-07-14T00:00:00Z", name="Sprint 1"),
            iteration("2026\\Q3\\S2", timeframe="future", start="2026-07-15T00:00:00Z",
                      finish="2026-07-28T00:00:00Z", name="Sprint 2"),
        ]}
        areas = {"values": [{"value": "ExampleProject\\Example Team"}]}
        wiql_resp = {"workItems": [{"id": 101}]}
        batch_resp = {"value": [{
            "id": 101,
            "fields": {
                "System.WorkItemType": "Bug", "System.State": "Active",
                "System.Title": "  spaced   title  ", "System.AssignedTo": {"displayName": "Jamie Assignee"},
                "Microsoft.VSTS.Common.Priority": 2, "System.Tags": "a; b",
                "System.ChangedDate": "2026-07-05T10:00:00Z",
            },
            "relations": [],
        }]}
        fetch = FakeFetch(responses={
            ITERS_URL: iters, AREAS_URL: areas, WIQL_URL: wiql_resp, BATCH_URL: batch_resp,
        })
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("current")
        self.assertEqual(rc, 0)
        lines = [ln for ln in buf.getvalue().splitlines() if ln.strip()]
        self.assertEqual(len(lines), 2)
        meta = json.loads(lines[0])
        self.assertTrue(meta["_meta"])
        self.assertEqual(meta["timeframe"], "current")
        self.assertEqual(meta["sprintName"], "Sprint 1")
        self.assertEqual(meta["nextSprintName"], "Sprint 2")
        rec = json.loads(lines[1])
        self.assertEqual(rec["id"], 101)
        self.assertEqual(rec["title"], "spaced title")
        self.assertEqual(rec["assignedTo"], "Jamie Assignee")

        wiql_call = next(c for c in fetch.calls if c["url"] == WIQL_URL)
        self.assertEqual(wiql_call["method"], "POST")
        query = wiql_call["data"]["query"]
        self.assertIn("[System.IterationPath] = '2026\\Q3\\S1'", query)
        self.assertIn("[System.AssignedTo] = 'Jordan Doe'", query)
        self.assertIn("[System.AreaPath] UNDER 'ExampleProject\\Example Team'", query)
        self.assertIn("[System.WorkItemType] IN ('User Story','Bug')", query)

        batch_call = next(c for c in fetch.calls if c["url"] == BATCH_URL)
        self.assertEqual(batch_call["data"], {"ids": [101], "$expand": "relations"})

    def test_next_without_a_next_sprint_is_an_error(self):
        actions = make_actions()
        iters = {"value": [iteration("Q\\S1", timeframe="current", start="2026-07-01T00:00:00Z")]}
        actions.fetch = FakeFetch(responses={ITERS_URL: iters})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_list("next")
        self.assertEqual(rc, 1)
        self.assertIn("could not determine next sprint", buf.getvalue())

    def test_items_mode_uses_explicit_path_no_iterations_fetch(self):
        actions = make_actions()
        areas = {"values": [{"value": "ExampleProject"}]}
        fetch = FakeFetch(responses={
            AREAS_URL: areas, WIQL_URL: {"workItems": []},
        })
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("items", "2026\\Q3\\S9")
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue(), "")  # no ids -> no _meta line, no records
        self.assertFalse(any(c["url"] == ITERS_URL for c in fetch.calls))
        wiql_call = next(c for c in fetch.calls if c["url"] == WIQL_URL)
        self.assertIn("[System.IterationPath] = '2026\\Q3\\S9'", wiql_call["data"]["query"])

    def test_no_team_areas_is_an_error(self):
        actions = make_actions()
        actions.fetch = FakeFetch(responses={AREAS_URL: {"values": []}})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_list("items", "Q\\S1")
        self.assertEqual(rc, 1)
        self.assertIn("no team areas returned", buf.getvalue())

    def test_http_error_uses_list_style_message(self):
        actions = make_actions()
        actions.fetch = FakeFetch(raise_for={ITERS_URL: ac.AdoHttpError(500, ITERS_URL, b"boom")})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_list("current")
        self.assertEqual(rc, 2)
        self.assertIn("HTTP 500 GET", buf.getvalue())
        self.assertIn("boom", buf.getvalue())

    def test_sprints_mode_groups_by_quarter_and_marks_current(self):
        actions = make_actions()
        iters = {"value": [
            iteration("2026\\Q3\\S1", timeframe="past", start="2026-06-01T00:00:00Z", name="Sprint 1"),
            iteration("2026\\Q3\\S2", timeframe="current", start="2026-07-01T00:00:00Z", name="Sprint 2"),
            iteration("2026\\Q3\\S3", timeframe="future", start="2026-08-01T00:00:00Z", name="Sprint 3"),
            iteration("2026\\Q4\\S1", timeframe="future", start="2026-10-01T00:00:00Z", name="Q4 Sprint 1"),
        ]}
        actions.fetch = FakeFetch(responses={ITERS_URL: iters})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("sprints")
        self.assertEqual(rc, 0)
        d = json.loads(buf.getvalue().strip())
        self.assertTrue(d["_sprints"])
        self.assertEqual(d["quarter"], "2026\\Q3")
        self.assertEqual(len(d["sprints"]), 3)  # Q4 excluded
        self.assertEqual(d["currentIndex"], 2)  # 1-based, Sprint 2
        self.assertTrue(d["sprints"][1]["current"])
        self.assertNotIn("states", d)  # no work_items.states: configured
        # The configured types ride along so the dashboard's sections and
        # its "new item" picker follow work_items.types:.
        self.assertEqual(d["types"], ["User Story", "Bug"])

    def test_sprints_carries_configured_types(self):
        actions = make_actions(env_overrides={"AZVICLI_WI_TYPES": "Task, Feature"})
        iters = {"value": [
            iteration("2026\\Q3\\S2", timeframe="current", start="2026-07-01T00:00:00Z", name="Sprint 2"),
        ]}
        actions.fetch = FakeFetch(responses={ITERS_URL: iters})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            self.assertEqual(actions.cmd_wi_list("sprints"), 0)
        self.assertEqual(json.loads(buf.getvalue().strip())["types"], ["Task", "Feature"])

    def test_members_lists_the_team_deduplicated(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/_apis/projects/ExampleProject/teams/Example%20Team/members"
        actions.fetch = FakeFetch(responses={url: {"value": [
            {"identity": {"displayName": "Jane Doe", "uniqueName": "jane@example.com"}},
            {"identity": {"displayName": "jane doe", "uniqueName": "dup@example.com"}},
            {"identity": {"displayName": "Rick Roe", "uniqueName": "rick@example.com"}},
            {"identity": {"displayName": "", "uniqueName": "blank@example.com"}},
        ]}})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            self.assertEqual(actions.cmd_wi_list("members"), 0)
        rows = [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]
        self.assertEqual([r["name"] for r in rows], ["Jane Doe", "Rick Roe"])
        self.assertEqual(rows[0]["email"], "jane@example.com")
        self.assertEqual(actions.fetch.calls[0]["api_version"], "6.0")


    def test_sprints_scope_all_includes_every_iteration_ordered_by_start(self):
        # work_items.sprint_scope: all - every iteration the team has, not
        # just the current sprint's parent-node siblings, ordered by start
        # date with the current one still marked/indexed.
        cfg = make_config(sprint_scope="all")
        actions = make_actions(config=cfg)
        iters = {"value": [
            iteration("2026\\Q3\\S1", timeframe="past", start="2026-06-01T00:00:00Z", name="Sprint 1"),
            iteration("2026\\Q3\\S2", timeframe="current", start="2026-07-01T00:00:00Z", name="Sprint 2"),
            iteration("2026\\Q4\\S1", timeframe="future", start="2026-10-01T00:00:00Z", name="Q4 Sprint 1"),
        ]}
        actions.fetch = FakeFetch(responses={ITERS_URL: iters})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("sprints")
        self.assertEqual(rc, 0)
        d = json.loads(buf.getvalue().strip())
        self.assertEqual(d["quarter"], "")  # no single parent node in "all" scope
        self.assertEqual(len(d["sprints"]), 3)  # Q4 sprint included this time
        self.assertEqual([s["path"] for s in d["sprints"]],
                          ["2026\\Q3\\S1", "2026\\Q3\\S2", "2026\\Q4\\S1"])  # ordered by start date
        self.assertEqual(d["currentIndex"], 2)
        self.assertTrue(d["sprints"][1]["current"])

    def test_sprints_scope_all_sorts_undated_iterations_last(self):
        # An iteration with no startDate (attributes missing it entirely)
        # sorts after every dated one, in both scopes - _wi_list_sprints'
        # sort key already treats a missing/unparseable startDate as
        # datetime.max; this just confirms "all" scope (which widens the
        # candidate set beyond the current sprint's siblings) doesn't change
        # that ordering rule.
        cfg = make_config(sprint_scope="all")
        actions = make_actions(config=cfg)
        iters = {"value": [
            iteration("2026\\Q3\\S2", timeframe="current", start="2026-07-01T00:00:00Z", name="Sprint 2"),
            iteration("Backlog", name="Backlog"),  # no startDate at all
            iteration("2026\\Q3\\S1", timeframe="past", start="2026-06-01T00:00:00Z", name="Sprint 1"),
        ]}
        actions.fetch = FakeFetch(responses={ITERS_URL: iters})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("sprints")
        self.assertEqual(rc, 0)
        d = json.loads(buf.getvalue().strip())
        self.assertEqual([s["path"] for s in d["sprints"]],
                          ["2026\\Q3\\S1", "2026\\Q3\\S2", "Backlog"])
        self.assertEqual(d["currentIndex"], 2)

    def test_sprints_includes_states_when_configured(self):
        cfg = make_config(states=["New", "Active", "Closed"])
        actions = make_actions(config=cfg)
        iters = {"value": [
            iteration("2026\\Q3\\S1", timeframe="current", start="2026-07-01T00:00:00Z", name="Sprint 1"),
        ]}
        actions.fetch = FakeFetch(responses={ITERS_URL: iters})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("sprints")
        self.assertEqual(rc, 0)
        d = json.loads(buf.getvalue().strip())
        self.assertEqual(d["states"], ["New", "Active", "Closed"])

    def test_current_meta_includes_states_when_configured(self):
        cfg = make_config(states=["New", "Active", "Closed"])
        actions = make_actions(config=cfg)
        iters = {"value": [
            iteration("2026\\Q3\\S1", timeframe="current", start="2026-07-01T00:00:00Z", name="Sprint 1"),
        ]}
        actions.fetch = FakeFetch(responses={
            ITERS_URL: iters, AREAS_URL: {"values": [{"value": "ExampleProject"}]},
            WIQL_URL: {"workItems": []},
        })
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("current")
        self.assertEqual(rc, 0)
        meta = json.loads(buf.getvalue().strip())
        self.assertEqual(meta["states"], ["New", "Active", "Closed"])

    def test_current_meta_omits_states_when_not_configured(self):
        actions = make_actions()
        iters = {"value": [
            iteration("2026\\Q3\\S1", timeframe="current", start="2026-07-01T00:00:00Z", name="Sprint 1"),
        ]}
        actions.fetch = FakeFetch(responses={
            ITERS_URL: iters, AREAS_URL: {"values": [{"value": "ExampleProject"}]},
            WIQL_URL: {"workItems": []},
        })
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_list("current")
        self.assertEqual(rc, 0)
        meta = json.loads(buf.getvalue().strip())
        self.assertNotIn("states", meta)


# ---------------------------------------------------------------------------
# --wi-detail
# ---------------------------------------------------------------------------


class WiDetailTests(unittest.TestCase):
    def test_full_detail_with_parent_child_and_comments(self):
        actions = make_actions()
        item_url = "https://dev.azure.com/example-org/_apis/wit/workitems/55?$expand=all"
        comments_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workItems/55/comments"
        full = {
            "id": 55,
            "fields": {
                "System.WorkItemType": "Bug", "System.State": "Active", "System.Title": "T",
                "System.AssignedTo": {"displayName": "A"}, "System.CreatedBy": {"displayName": "B"},
                "System.CreatedDate": "2026-01-01T00:00:00Z", "System.ChangedDate": "2026-01-02T00:00:00Z",
                "Microsoft.VSTS.Common.Priority": 1, "System.AreaPath": "Area", "System.IterationPath": "Iter",
                "System.Tags": "", "System.Reason": "New",
                "System.Description": "<p>desc</p>",
                "Microsoft.VSTS.Common.AcceptanceCriteria": "<p>AC</p>",
                "Microsoft.VSTS.TCM.ReproSteps": "",
            },
            "relations": [
                {"rel": "System.LinkTypes.Hierarchy-Reverse", "url": "x/workItems/10"},
                {"rel": "System.LinkTypes.Hierarchy-Forward", "url": "x/workItems/20"},
                {"rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p%2Fr%2F999"},
            ],
        }
        batch = {"value": [
            {"id": 10, "fields": {"System.WorkItemType": "Feature", "System.State": "Active",
                                   "System.Title": "Parent", "System.AssignedTo": ""}},
            {"id": 20, "fields": {"System.WorkItemType": "Task", "System.State": "New",
                                   "System.Title": "Child", "System.AssignedTo": ""}},
        ]}
        comments = {"comments": [
            {"id": 2, "createdBy": {"displayName": "X"}, "createdDate": "2026-01-03T00:00:00Z", "text": "<p>second</p>"},
            {"id": 1, "createdBy": {"displayName": "Y"}, "createdDate": "2026-01-02T00:00:00Z", "text": "<p>first</p>"},
        ]}
        fetch = FakeFetch(responses={item_url: full, BATCH_URL: batch, comments_url: comments})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_detail("55")
        self.assertEqual(rc, 0)
        out = json.loads(buf.getvalue().strip())
        self.assertEqual(out["item"]["id"], 55)
        self.assertEqual(out["item"]["description"], "desc")
        self.assertEqual(out["item"]["pullRequests"], [{"id": 999}])
        self.assertEqual(out["parent"]["id"], 10)
        self.assertEqual([c["id"] for c in out["children"]], [20])
        self.assertFalse(out["commentsUnsupported"])
        # oldest first, regardless of response order
        self.assertEqual([c["id"] for c in out["comments"]], [1, 2])
        self.assertEqual(out["comments"][0]["text"], "first")

        batch_call = next(c for c in fetch.calls if c["url"] == BATCH_URL)
        self.assertEqual(sorted(batch_call["data"]["ids"]), [10, 20])

    def test_comments_404_degrades_to_empty_list(self):
        actions = make_actions()
        item_url = "https://dev.azure.com/example-org/_apis/wit/workitems/7?$expand=all"
        comments_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workItems/7/comments"
        full = {"id": 7, "fields": {"System.WorkItemType": "Bug", "System.State": "New", "System.Title": "t"},
                "relations": []}
        fetch = FakeFetch(responses={item_url: full},
                          raise_for={comments_url: ac.AdoHttpError(404, comments_url, b"not found")})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_detail("7")
        self.assertEqual(rc, 0)
        out = json.loads(buf.getvalue().strip())
        self.assertEqual(out["comments"], [])
        self.assertTrue(out["commentsUnsupported"])

    def test_comments_400_also_degrades(self):
        actions = make_actions()
        item_url = "https://dev.azure.com/example-org/_apis/wit/workitems/7?$expand=all"
        comments_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workItems/7/comments"
        full = {"id": 7, "fields": {}, "relations": []}
        fetch = FakeFetch(responses={item_url: full},
                          raise_for={comments_url: ac.AdoHttpError(400, comments_url, b"bad")})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_detail("7")
        self.assertEqual(rc, 0)
        out = json.loads(buf.getvalue().strip())
        self.assertTrue(out["commentsUnsupported"])

    def test_comments_other_http_error_fails_the_whole_fetch(self):
        actions = make_actions()
        item_url = "https://dev.azure.com/example-org/_apis/wit/workitems/7?$expand=all"
        comments_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workItems/7/comments"
        full = {"id": 7, "fields": {}, "relations": []}
        fetch = FakeFetch(responses={item_url: full},
                          raise_for={comments_url: ac.AdoHttpError(500, comments_url, b"boom")})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_detail("7")
        self.assertEqual(rc, 2)
        self.assertIn("HTTP 500 GET", buf.getvalue())

    def test_no_parent_or_children_skips_batch_call(self):
        actions = make_actions()
        item_url = "https://dev.azure.com/example-org/_apis/wit/workitems/7?$expand=all"
        comments_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workItems/7/comments"
        full = {"id": 7, "fields": {}, "relations": []}
        fetch = FakeFetch(responses={item_url: full, comments_url: {"comments": []}})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_detail("7")
        self.assertEqual(rc, 0)
        out = json.loads(buf.getvalue().strip())
        self.assertIsNone(out["parent"])
        self.assertEqual(out["children"], [])
        self.assertFalse(any(c["url"] == BATCH_URL for c in fetch.calls))


# ---------------------------------------------------------------------------
# --wi-state
# ---------------------------------------------------------------------------


class WiStateTransitionsReasonsTests(unittest.TestCase):
    def test_transitions_lists_unique_non_current_targets_in_order(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitemtypes/User%20Story"
        resp = {"transitions": {"Active": [{"to": "Resolved"}, {"to": "Active"}, {"to": "Closed"},
                                            {"to": "Resolved"}]}}
        actions.fetch = FakeFetch(responses={url: resp})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_state(["transitions", "User Story", "Active"])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().splitlines(), ["Resolved", "Closed"])

    def test_transitions_needs_type(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_state(["transitions", "", "Active"])
        self.assertEqual(rc, 1)

    def test_transitions_http_error_uses_state_style_message(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitemtypes/Bug"
        actions.fetch = FakeFetch(raise_for={url: ac.AdoHttpError(404, url, b'{"message":"not found"}')})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_state(["transitions", "Bug", "New"])
        self.assertEqual(rc, 2)
        self.assertIn("HTTP 404 GET: not found", buf.getvalue())
        self.assertNotIn(url, buf.getvalue())  # state-style has no URL

    def test_reasons_ranked_by_frequency_then_alpha(self):
        actions = make_actions()
        wiql_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/wiql?$top=200"
        items_url = ("https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems?ids=1,2,3"
                     "&fields=System.Reason")
        wiql_resp = {"workItems": [{"id": 1}, {"id": 2}, {"id": 3}]}
        items_resp = {"value": [
            {"fields": {"System.Reason": "Fixed"}},
            {"fields": {"System.Reason": "Duplicate"}},
            {"fields": {"System.Reason": "Fixed"}},
        ]}
        actions.fetch = FakeFetch(responses={wiql_url: wiql_resp, items_url: items_resp})
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_state(["reasons", "Bug", "Closed"])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().splitlines(), ["Fixed", "Duplicate"])

    def test_reasons_needs_type_and_state(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_state(["reasons", "Bug", ""])
        self.assertEqual(rc, 1)

    def test_set_state_prints_resulting_state(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems/42"
        fetch = FakeFetch(responses={url: {"fields": {"System.State": "Resolved"}}})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_state(["set", "42", "Resolved"])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "Resolved")
        call = fetch.calls[0]
        self.assertEqual(call["method"], "PATCH")
        self.assertEqual(call["content_type"], "application/json-patch+json")
        self.assertEqual(call["data"], [{"op": "add", "path": "/fields/System.State", "value": "Resolved"}])

    def test_set_state_with_reason_adds_second_patch_op(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems/42"
        fetch = FakeFetch(responses={url: {"fields": {"System.State": "Closed"}}})
        actions.fetch = fetch
        with mock.patch("sys.stdout", StringIO()):
            rc = actions.cmd_wi_state(["set", "42", "Closed", "Fixed"])
        self.assertEqual(rc, 0)
        self.assertEqual(fetch.calls[0]["data"], [
            {"op": "add", "path": "/fields/System.State", "value": "Closed"},
            {"op": "add", "path": "/fields/System.Reason", "value": "Fixed"},
        ])

    def test_set_state_validate_only_appends_query_param(self):
        actions = make_actions(env_overrides={"AZVICLI_WI_VALIDATE_ONLY": "1"})
        url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems/42?validateOnly=true"
        fetch = FakeFetch(responses={url: {"fields": {"System.State": "Resolved"}}})
        actions.fetch = fetch
        with mock.patch("sys.stdout", StringIO()):
            rc = actions.cmd_wi_state(["set", "42", "Resolved"])
        self.assertEqual(rc, 0)
        self.assertEqual(fetch.calls[0]["url"], url)

    def test_set_state_needs_id_and_new_state(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_state(["set", "", "Resolved"])
        self.assertEqual(rc, 1)

    def test_set_state_unexpected_response_is_an_error(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems/42"
        actions.fetch = FakeFetch(responses={url: {"no_fields_key": True}})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_state(["set", "42", "Resolved"])
        self.assertEqual(rc, 2)
        self.assertIn("unexpected response", buf.getvalue())

    def test_unknown_subcommand_prints_usage(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_state([])
        self.assertEqual(rc, 1)
        self.assertIn("usage: --wi-state", buf.getvalue())


# ---------------------------------------------------------------------------
# --wi-edit
# ---------------------------------------------------------------------------


class WiEditCreateTests(unittest.TestCase):
    def test_create_with_parent_and_iteration(self):
        actions = make_actions()
        team_url = AREAS_URL
        create_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems/$User%20Story"
        fetch = FakeFetch(responses={
            team_url: {"defaultValue": "ExampleProject\\Example Team"},
            create_url: {"id": 900, "fields": {"System.Title": "New title"}},
        })
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_edit(["create", "User Story", "New title", "10", "Q\\S1"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue().strip()), {"id": 900, "title": "New title"})
        call = fetch.calls[-1]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["content_type"], "application/json-patch+json")
        patch = call["data"]
        self.assertIn({"op": "add", "path": "/fields/System.Title", "value": "New title"}, patch)
        self.assertIn({"op": "add", "path": "/fields/System.AssignedTo", "value": "Jordan Doe"}, patch)
        self.assertIn({"op": "add", "path": "/fields/System.AreaPath", "value": "ExampleProject\\Example Team"}, patch)
        self.assertIn({"op": "add", "path": "/fields/System.IterationPath", "value": "Q\\S1"}, patch)
        rel_ops = [p for p in patch if p.get("path") == "/relations/-"]
        self.assertEqual(len(rel_ops), 1)
        self.assertEqual(rel_ops[0]["value"]["rel"], "System.LinkTypes.Hierarchy-Reverse")
        self.assertEqual(rel_ops[0]["value"]["url"], "https://dev.azure.com/example-org/_apis/wit/workItems/10")

    def test_create_falls_back_to_first_area_when_no_default(self):
        actions = make_actions()
        create_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems/$Bug"
        fetch = FakeFetch(responses={
            AREAS_URL: {"values": [{"value": "Area A"}, {"value": "Area B"}]},
            create_url: {"id": 901, "fields": {}},
        })
        actions.fetch = fetch
        with mock.patch("sys.stdout", StringIO()):
            rc = actions.cmd_wi_edit(["create", "Bug", "T"])
        self.assertEqual(rc, 0)
        patch = fetch.calls[-1]["data"]
        area_ops = [p for p in patch if p["path"] == "/fields/System.AreaPath"]
        self.assertEqual(area_ops[0]["value"], "Area A")
        # No parent/iteration given -> no relations/-  or IterationPath op.
        self.assertFalse(any(p["path"] == "/relations/-" for p in patch))
        self.assertFalse(any(p["path"] == "/fields/System.IterationPath" for p in patch))

    def test_create_needs_type_and_title(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            self.assertEqual(actions.cmd_wi_edit(["create", "", "T"]), 1)
            self.assertEqual(actions.cmd_wi_edit(["create", "Bug", ""]), 1)

    def test_create_unexpected_response_is_an_error(self):
        actions = make_actions()
        create_url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workitems/$Bug"
        fetch = FakeFetch(responses={AREAS_URL: {"values": []}, create_url: {"no_id": True}})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_edit(["create", "Bug", "T"])
        self.assertEqual(rc, 2)
        self.assertIn("unexpected response", buf.getvalue())


class WiEditSetTests(unittest.TestCase):
    def test_set_known_field_casts_and_patches_without_project_scope(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/_apis/wit/workitems/5"
        fetch = FakeFetch(responses={url: {"id": 5, "fields": {"Microsoft.VSTS.Common.Priority": 2}}})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_edit(["set", "5", "priority", "2"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue().strip()), {"id": 5, "field": "priority", "value": 2})
        call = fetch.calls[0]
        self.assertEqual(call["url"], url)  # no project segment, unlike wi-state.sh's "set"
        self.assertEqual(call["content_type"], "application/json-patch+json")
        self.assertEqual(call["data"], [{"op": "add", "path": "/fields/Microsoft.VSTS.Common.Priority", "value": 2}])

    def test_set_assigned_to_empty_value_resolves_to_assignee(self):
        # ga's "empty = me" prompt: the Lua side sends an empty string
        # through as-is now (no hard-coded personal fallback there any
        # more) and this is where it gets resolved to the real "me".
        actions = make_actions()  # config assignee: Jordan Doe
        url = "https://dev.azure.com/example-org/_apis/wit/workitems/5"
        fetch = FakeFetch(responses={url: {"id": 5, "fields": {"System.AssignedTo": "Jordan Doe"}}})
        actions.fetch = fetch
        with mock.patch("sys.stdout", StringIO()):
            rc = actions.cmd_wi_edit(["set", "5", "assignedTo", ""])
        self.assertEqual(rc, 0)
        self.assertEqual(fetch.calls[0]["data"],
                          [{"op": "add", "path": "/fields/System.AssignedTo", "value": "Jordan Doe"}])

    def test_set_unknown_field_is_rejected(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_edit(["set", "5", "bogus", "x"])
        self.assertEqual(rc, 1)
        self.assertIn("unknown field", buf.getvalue())

    def test_set_priority_invalid_int_is_rejected(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_edit(["set", "5", "priority", "not-a-number"])
        self.assertEqual(rc, 1)

    def test_set_needs_id_and_field(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_edit(["set", "", "title", "x"])
        self.assertEqual(rc, 1)


class WiEditCommentTests(unittest.TestCase):
    def test_comment_posts_plain_json_body(self):
        actions = make_actions()
        url = "https://dev.azure.com/example-org/ExampleProject/_apis/wit/workItems/5/comments"
        fetch = FakeFetch(responses={url: {"id": 77}})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_edit(["comment", "5", "a comment"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue().strip()), {"id": 77})
        call = fetch.calls[0]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["data"], {"text": "a comment"})
        self.assertEqual(call["content_type"], "application/json")  # not json-patch
        self.assertEqual(call["api_version"], ac.WI_COMMENTS_API)

    def test_comment_needs_id_and_text(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_edit(["comment", "5", ""])
        self.assertEqual(rc, 1)


class WiEditLinkUnlinkPrTests(unittest.TestCase):
    def test_link_pr_resolves_repo_then_patches_artifact_link(self):
        actions = make_actions()
        repo_url = "https://dev.azure.com/org/proj/_apis/git/repositories/myrepo"
        wi_url = "https://dev.azure.com/example-org/_apis/wit/workitems/5"
        fetch = FakeFetch(responses={
            repo_url: {"id": "repo-guid", "project": {"id": "proj-guid"}},
            wi_url: {"fields": {}},
        })
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_edit(["link-pr", "5", "https://dev.azure.com/org", "proj", "myrepo", "321"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue().strip()), {"linked": 321})
        patch_call = fetch.calls[-1]
        self.assertEqual(patch_call["content_type"], "application/json-patch+json")
        rel = patch_call["data"][0]["value"]
        self.assertEqual(rel["rel"], "ArtifactLink")
        self.assertEqual(rel["url"], "vstfs:///Git/PullRequestId/proj-guid%2Frepo-guid%2F321")
        self.assertEqual(rel["attributes"], {"name": "Pull Request"})

    def test_link_pr_missing_repo_or_project_guid_is_an_error(self):
        actions = make_actions()
        repo_url = "https://dev.azure.com/org/proj/_apis/git/repositories/myrepo"
        actions.fetch = FakeFetch(responses={repo_url: {"id": None}})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_edit(["link-pr", "5", "https://dev.azure.com/org", "proj", "myrepo", "321"])
        self.assertEqual(rc, 2)
        self.assertIn("could not resolve repository/project id", buf.getvalue())

    def test_link_pr_needs_all_five_args(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_edit(["link-pr", "5", "https://dev.azure.com/org", "proj", "myrepo", ""])
        self.assertEqual(rc, 1)

    def test_unlink_pr_finds_and_removes_by_index(self):
        actions = make_actions()
        get_url = "https://dev.azure.com/example-org/_apis/wit/workitems/5?$expand=relations"
        patch_url = "https://dev.azure.com/example-org/_apis/wit/workitems/5"
        d = {"relations": [
            {"rel": "System.LinkTypes.Hierarchy-Forward", "url": "x/workItems/1"},
            {"rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p%2Fr%2F321"},
        ]}
        fetch = FakeFetch(responses={get_url: d, patch_url: {"fields": {}}})
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.cmd_wi_edit(["unlink-pr", "5", "321"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue().strip()), {"unlinked": 321})
        patch_call = fetch.calls[-1]
        self.assertEqual(patch_call["data"], [{"op": "remove", "path": "/relations/1"}])

    def test_unlink_pr_not_found_is_an_error(self):
        actions = make_actions()
        get_url = "https://dev.azure.com/example-org/_apis/wit/workitems/5?$expand=relations"
        actions.fetch = FakeFetch(responses={get_url: {"relations": []}})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_edit(["unlink-pr", "5", "999"])
        self.assertEqual(rc, 1)
        self.assertIn("no linked pull request 999", buf.getvalue())

    def test_unlink_pr_needs_id_and_pr_id(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        with mock.patch("sys.stderr", StringIO()):
            rc = actions.cmd_wi_edit(["unlink-pr", "5", ""])
        self.assertEqual(rc, 1)


class WiEditDispatchTests(unittest.TestCase):
    def test_unknown_subcommand_prints_usage(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.cmd_wi_edit([])
        self.assertEqual(rc, 1)
        self.assertIn("usage: --wi-edit", buf.getvalue())


# ---------------------------------------------------------------------------
# cmd_wi_action dispatch
# ---------------------------------------------------------------------------


class CmdWiActionDispatchTests(unittest.TestCase):
    def test_wi_action_flags_membership(self):
        for flag in ("--wi-list", "--wi-detail", "--wi-state", "--wi-edit"):
            self.assertIn(flag, ac.WI_ACTION_FLAGS)

    def test_missing_config_pat_fails_before_dispatch(self):
        cfg_dir_backup = None
        tmp_home = None
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = os.path.join(tmp, "azure-cli.yml")
            with open(cfg_path, "w") as f:
                # No pat: on the only (work_items:-enabled) account, so
                # collection/project resolve fine (straight from this same
                # account) but resolve_account_pat still finds nothing.
                f.write("accounts:\n  - project_name: Other\n    org_url: https://dev.azure.com/nope\n"
                        "    work_items:\n      team: Some Team\n")
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: cfg_path)):
                buf = StringIO()
                with mock.patch("sys.stderr", buf):
                    rc = ac.cmd_wi_action("--wi-list", [])
                self.assertEqual(rc, 1)
                # The up-front config check (Config.problems) now names the
                # field before any account resolution runs.
                self.assertIn("pat is missing", buf.getvalue())

    def test_wi_detail_missing_id_is_an_error(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = os.path.join(tmp, "azure-cli.yml")
            with open(cfg_path, "w") as f:
                f.write("accounts:\n  - project_name: ExampleProject\n"
                        "    org_url: https://dev.azure.com/example-org\n    pat: tok\n"
                        "    work_items:\n      team: Example Team\n")
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: cfg_path)):
                buf = StringIO()
                with mock.patch("sys.stderr", buf):
                    rc = ac.cmd_wi_action("--wi-detail", [])
                self.assertEqual(rc, 1)
                self.assertIn("usage: --wi-detail", buf.getvalue())

    def test_unexpected_exception_is_caught_not_raised(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = os.path.join(tmp, "azure-cli.yml")
            with open(cfg_path, "w") as f:
                f.write("accounts:\n  - project_name: ExampleProject\n"
                        "    org_url: https://dev.azure.com/example-org\n    pat: tok\n"
                        "    work_items:\n      team: Example Team\n")
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: cfg_path)), \
                 mock.patch.object(ac.WorkItemActions, "cmd_wi_list", side_effect=ValueError("kaboom")):
                buf = StringIO()
                with mock.patch("sys.stderr", buf):
                    rc = ac.cmd_wi_action("--wi-list", [])
                self.assertEqual(rc, 1)
                self.assertIn("--wi-list failed", buf.getvalue())
                self.assertIn("kaboom", buf.getvalue())

    def test_no_work_items_block_anywhere_exits_1_with_message(self):
        # No account has a work_items: block, and no AZVICLI_WI_* override
        # supplies a team either - the "not configured" case from the
        # Configuration section of README.md: ensure_configured() must catch
        # this before any REST call (there's no pat: match to even reach
        # ensure_pat with, since collection/project are blank too).
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = os.path.join(tmp, "azure-cli.yml")
            with open(cfg_path, "w") as f:
                f.write("accounts:\n  - project_name: ExampleProject\n"
                        "    org_url: https://dev.azure.com/example-org\n    pat: tok\n")
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: cfg_path)):
                buf = StringIO()
                with mock.patch("sys.stderr", buf):
                    rc = ac.cmd_wi_action("--wi-list", [])
                self.assertEqual(rc, 1)
                # The last line is the diagnostic itself - "Loading
                # configuration from: ..." precedes it on stderr too.
                self.assertEqual(
                    buf.getvalue().strip().splitlines()[-1],
                    "No account has a work_items: block in azure-cli.yml; add team: … "
                    "under the account to enable work items",
                )


if __name__ == "__main__":
    unittest.main()
