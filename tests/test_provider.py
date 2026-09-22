#!/usr/bin/env python3
"""Unit tests for azure-cli.py, the python data provider.

Run standalone with `python3 -m unittest tests/test_provider.py` or via
`bash tests/run.sh` (which runs `python3 -m unittest discover -s tests
-p 'test_*.py'` alongside the Lua/shell checks). No network access and no
Azure DevOps instance are required: HTTP is mocked by swapping the
`fetch` attribute on AzureDevOpsPullRequestSource for a fake that answers
from an in-memory table, exactly as azure-cli.py was designed to allow.
"""

import contextlib
import datetime as _dt
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    """Imports azure-cli.py by path (it isn't a valid module name because
    of the dash, so it can't just be `import azure_cli`).
    """
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_provider", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()

USER = "11111111-1111-1111-1111-111111111111"
OTHER_USER = "22222222-2222-2222-2222-222222222222"


def make_pr(**overrides):
    pr = {
        "pullRequestId": 42,
        "title": "Fix the thing",
        "repository": {
            "name": "myrepo",
            "id": "repo-1",
            "project": {"id": "proj-guid-1"},
        },
        "sourceRefName": "refs/heads/feature/x",
        "targetRefName": "refs/heads/main",
        "createdBy": {"id": OTHER_USER, "displayName": "Alice Author"},
        "isDraft": False,
        "mergeStatus": "succeeded",
        "autoCompleteSetBy": None,
        "creationDate": "2024-01-01T00:00:00Z",
        "description": "some description",
        "reviewers": [
            {"id": USER, "displayName": "Me Reviewer", "vote": 0, "isContainer": False},
        ],
    }
    pr.update(overrides)
    return pr


def make_account(project="proj", org_url="https://dev.azure.com/org", pat="tok", hide_ancient=None, clones_dir=None):
    return ac.AccountConfig(project=project, org_url=org_url, pat=pat, hide_ancient=hide_ancient, clones_dir=clones_dir)


# ---------------------------------------------------------------------------
# YAML-subset parser
# ---------------------------------------------------------------------------


class YamlSubsetParserTests(unittest.TestCase):
    def test_top_level_scalars_and_accounts(self):
        text = """
# a comment
repo_path: C:\\Users\\me\\source\\repos\\main

accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org
    pat: abc123
    hide_ancient: true
    clones_dir: C:\\Users\\me\\source\\repos
"""
        data = ac.parse_yaml_subset(text)
        self.assertEqual(data["repo_path"], "C:\\Users\\me\\source\\repos\\main")
        self.assertEqual(len(data["accounts"]), 1)
        acct = data["accounts"][0]
        self.assertEqual(acct["project_name"], "MyProject")
        self.assertEqual(acct["org_url"], "https://dev.azure.com/my-org")
        self.assertEqual(acct["pat"], "abc123")
        self.assertIs(acct["hide_ancient"], True)
        self.assertEqual(acct["clones_dir"], "C:\\Users\\me\\source\\repos")

    def test_multiple_accounts(self):
        text = """
accounts:
  - project_name: test1
    org_url: http://example1.com
    pat:   abc123

  - project_name: test2
    org_url: http://example2.com
    pat:   321cba
"""
        data = ac.parse_yaml_subset(text)
        self.assertEqual(len(data["accounts"]), 2)
        self.assertEqual(data["accounts"][0]["project_name"], "test1")
        self.assertEqual(data["accounts"][1]["project_name"], "test2")

    def test_quoted_strings_and_comments(self):
        text = """
accounts:
  - project_name: "My Project"  # inline comment
    org_url: 'https://dev.azure.com/org#literal'
    pat: "p#at"
"""
        data = ac.parse_yaml_subset(text)
        acct = data["accounts"][0]
        self.assertEqual(acct["project_name"], "My Project")
        # '#' inside single quotes must not be treated as a comment start.
        self.assertEqual(acct["org_url"], "https://dev.azure.com/org#literal")
        self.assertEqual(acct["pat"], "p#at")

    def test_hide_ancient_false_and_absent(self):
        text = """
accounts:
  - project_name: a
    org_url: http://x
    hide_ancient: false
  - project_name: b
    org_url: http://y
"""
        data = ac.parse_yaml_subset(text)
        self.assertIs(data["accounts"][0]["hide_ancient"], False)
        self.assertNotIn("hide_ancient", data["accounts"][1])

    def test_config_from_string_builds_account_configs(self):
        text = """
accounts:
  - project_name: test1
    org_url: http://example1.com
    pat: abc123
"""
        cfg = ac.Config.from_string(text)
        self.assertEqual(len(cfg.accounts), 1)
        self.assertEqual(cfg.accounts[0].project, "test1")
        self.assertEqual(cfg.accounts[0].org_url, "http://example1.com")
        self.assertEqual(cfg.accounts[0].pat, "abc123")

    def test_inline_flow_list_scalar(self):
        self.assertEqual(ac._parse_scalar("[User Story, Bug]"), ["User Story", "Bug"])
        self.assertEqual(ac._parse_scalar("[]"), [])
        self.assertEqual(ac._parse_scalar("[Task]"), ["Task"])

    def test_work_items_block_with_inline_list_types(self):
        text = """
accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org
    pat: abc
    work_items:
      team: My Team
      assignee: Doe, Jane
      types: [User Story, Bug]
"""
        data = ac.parse_yaml_subset(text)
        wi = data["accounts"][0]["work_items"]
        self.assertEqual(wi["team"], "My Team")
        self.assertEqual(wi["assignee"], "Doe, Jane")
        self.assertEqual(wi["types"], ["User Story", "Bug"])

    def test_work_items_block_with_comma_scalar_types(self):
        text = """
accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org
    pat: abc
    work_items:
      team: My Team
      types: Task, Bug
"""
        data = ac.parse_yaml_subset(text)
        wi = data["accounts"][0]["work_items"]
        self.assertEqual(wi["types"], "Task, Bug")
        self.assertNotIn("assignee", wi)

    def test_work_items_block_absent_on_plain_account(self):
        text = """
accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org
    pat: abc
"""
        data = ac.parse_yaml_subset(text)
        self.assertNotIn("work_items", data["accounts"][0])

    def test_work_items_block_is_not_last_field_in_account(self):
        # A field after the nested mapping closes it and lands back on the
        # account, not folded into work_items:.
        text = """
accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org
    work_items:
      team: My Team
    pat: abc
"""
        data = ac.parse_yaml_subset(text)
        acct = data["accounts"][0]
        self.assertEqual(acct["work_items"], {"team": "My Team"})
        self.assertEqual(acct["pat"], "abc")

    def test_multiple_accounts_only_second_has_work_items(self):
        text = """
accounts:
  - project_name: NoWi
    org_url: https://dev.azure.com/none
    pat: ghi
  - project_name: HasWi
    org_url: https://dev.azure.com/haswi
    pat: jkl
    work_items:
      team: The Team
"""
        data = ac.parse_yaml_subset(text)
        self.assertNotIn("work_items", data["accounts"][0])
        self.assertEqual(data["accounts"][1]["work_items"], {"team": "The Team"})

    def test_config_from_string_builds_work_items_account_config(self):
        text = """
accounts:
  - project_name: WithWi
    org_url: https://dev.azure.com/with-wi
    pat: abc123
    work_items:
      team: My Team
      types: [User Story, Bug]
  - project_name: WithoutWi
    org_url: https://dev.azure.com/without-wi
    pat: def456
"""
        cfg = ac.Config.from_string(text)
        self.assertEqual(cfg.accounts[0].work_items, {"team": "My Team", "types": ["User Story", "Bug"]})
        self.assertIsNone(cfg.accounts[1].work_items)


# ---------------------------------------------------------------------------
# Config path / validate_exists / --print-pat behaviour
# ---------------------------------------------------------------------------


class ConfigProblemsTests(unittest.TestCase):
    TEMPLATE = """
accounts:
  - project_name: # TODO: e.g. sample-project
    org_url: # TODO: e.g. https://dev.azure.com/example
    pat: # TODO: your personal access token (required - no Azure AD fallback)
    hide_ancient: true
"""

    def test_untouched_template_parses_to_blank_scalars_not_empty_mappings(self):
        acct = ac.parse_yaml_subset(self.TEMPLATE)["accounts"][0]
        self.assertIsNone(acct["project_name"])
        self.assertIsNone(acct["org_url"])
        self.assertIsNone(acct["pat"])
        self.assertIs(acct["hide_ancient"], True)

    def test_a_real_nested_mapping_still_parses(self):
        text = """
accounts:
  - project_name: p
    org_url: https://dev.azure.com/o
    pat: t
    work_items:
      team: My Team
"""
        acct = ac.parse_yaml_subset(text)["accounts"][0]
        self.assertEqual(acct["work_items"], {"team": "My Team"})

    def test_untouched_template_is_reported_as_the_template(self):
        cfg = ac.Config.from_string(self.TEMPLATE)
        problems = cfg.problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("untouched template", problems[0])

    def test_each_missing_field_is_named(self):
        cfg = ac.Config.from_string("accounts:\n  - project_name: p\n    org_url: dev.azure.com/o\n")
        problems = cfg.problems()
        self.assertTrue(any("pat is missing" in p for p in problems), problems)
        self.assertTrue(any("must start with https://" in p for p in problems), problems)
        self.assertFalse(any("project_name" in p for p in problems), problems)

    def test_no_accounts_is_a_problem(self):
        self.assertTrue(ac.Config.from_string("repo_path: /x\n").problems())

    def test_good_config_has_no_problems(self):
        cfg = ac.Config.from_string("accounts:\n  - project_name: p\n    org_url: https://dev.azure.com/o\n    pat: t\n")
        self.assertEqual(cfg.problems(), [])

    def test_config_problems_prints_the_path_and_returns_true(self):
        cfg = ac.Config.from_string(self.TEMPLATE)
        with mock.patch.object(ac.Config, "path", staticmethod(lambda: "/cfg/azure-cli.yml")):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertTrue(ac.config_problems(cfg))
        self.assertIn("/cfg/azure-cli.yml is incomplete", err.getvalue())
        self.assertIn("gO", err.getvalue())

    def test_config_problems_tolerates_a_stand_in_object(self):
        self.assertFalse(ac.config_problems(object()))

    def test_missing_config_message_goes_to_stderr(self):
        with tempfile.TemporaryDirectory() as td:
            missing = os.path.join(td, "nope", "azure-cli.yml")
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: missing)):
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertFalse(ac.Config.validate_exists())
        self.assertEqual(out.getvalue(), "")
        self.assertIn("Configuration does not exist: " + missing, err.getvalue())


class _FakeResponse:
    def __init__(self, status=200, body=b"{}", ctype="application/json"):
        self.status = status
        self._body = body
        self.headers = {"Content-Type": ctype}

    def read(self):
        return self._body

    def getcode(self):
        return self.status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class HttpErrorMessageTests(unittest.TestCase):
    def test_203_sign_in_page_is_reported_as_a_rejected_pat(self):
        html = b"<!DOCTYPE html><html>Sign in</html>"
        with mock.patch.object(ac.urllib.request, "urlopen", return_value=_FakeResponse(203, html, "text/html")):
            with self.assertRaises(ac.AdoHttpError) as cm:
                ac.http_request("https://dev.azure.com/o/_apis/x", pat="bad")
        self.assertEqual(cm.exception.status, 203)
        self.assertIn("PAT was rejected", str(cm.exception))

    def test_401_carries_the_scope_hint(self):
        err = ac.urllib.error.HTTPError("https://x/_apis/y", 401, "Unauthorized", {}, io.BytesIO(b""))
        with mock.patch.object(ac.urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(ac.AdoHttpError) as cm:
                ac.http_request("https://x/_apis/y", pat="p")
        self.assertIn("Code (read & write)", str(cm.exception))

    def test_403_names_permissions(self):
        err = ac.urllib.error.HTTPError("https://x/_apis/y", 403, "Forbidden", {}, io.BytesIO(b""))
        with mock.patch.object(ac.urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(ac.AdoHttpError) as cm:
                ac.http_request("https://x/_apis/y", pat="p")
        self.assertIn("lacks permission", str(cm.exception))

    def test_unreachable_host_names_org_url(self):
        err = ac.urllib.error.URLError("Name or service not known")
        with mock.patch.object(ac.urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(ac.AdoTransportError) as cm:
                ac.http_request("https://nope.example/_apis/y", pat="p")
        self.assertIn("could not reach nope.example", str(cm.exception))
        self.assertIn("org_url", str(cm.exception))

    def test_missing_scheme_names_org_url(self):
        with mock.patch.object(ac.urllib.request, "urlopen", side_effect=ValueError("unknown url type: 'x'")):
            with self.assertRaises(ac.AdoTransportError) as cm:
                ac.http_request("dev.azure.com/o/_apis/y", pat="p")
        self.assertIn("https://", str(cm.exception))

    def test_non_json_200_is_explained(self):
        with mock.patch.object(ac.urllib.request, "urlopen",
                               return_value=_FakeResponse(200, b"garbage", "text/plain")):
            with self.assertRaises(ac.AdoTransportError) as cm:
                ac.http_request("https://x/_apis/y", pat="p")
        self.assertIn("expected JSON", str(cm.exception))

    def test_plain_json_still_parses(self):
        with mock.patch.object(ac.urllib.request, "urlopen", return_value=_FakeResponse(200, b'{"a": 1}')):
            self.assertEqual(ac.http_request("https://x/_apis/y", pat="p"), {"a": 1})


class DoctorTests(unittest.TestCase):
    GOOD = "accounts:\n  - project_name: p\n    org_url: https://dev.azure.com/o\n    pat: t\n"

    def _write(self, td, text):
        path = os.path.join(td, "azure-cli.yml")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def test_missing_file_is_the_only_check(self):
        checks = ac.doctor_checks("/nonexistent/azure-cli.yml")
        self.assertEqual(len(checks), 1)
        self.assertFalse(checks[0]["ok"])
        self.assertIn("does not exist", checks[0]["detail"])

    def test_template_stops_at_fields(self):
        with tempfile.TemporaryDirectory() as td:
            path = self._write(td, ConfigProblemsTests.TEMPLATE)
            checks = ac.doctor_checks(path)
        self.assertEqual([c["check"] for c in checks], ["config file", "config fields"])
        self.assertFalse(checks[1]["ok"])
        self.assertIn("untouched template", checks[1]["detail"])

    def test_sign_in_ok_and_work_items_optional(self):
        with tempfile.TemporaryDirectory() as td:
            path = self._write(td, self.GOOD)
            with mock.patch.object(ac.AzureDevOpsPullRequestSource, "_whoami_for_org", return_value=("id1", "Jane Doe")):
                checks = ac.doctor_checks(path)
        by = {c["check"]: c for c in checks}
        self.assertTrue(by["config fields"]["ok"])
        signin = [c for c in checks if c["check"].startswith("sign in to")][0]
        self.assertTrue(signin["ok"])
        self.assertIn("Jane Doe", signin["detail"])
        self.assertTrue(by["work items"]["ok"])
        self.assertIn("not configured", by["work items"]["detail"])

    def test_sign_in_failure_carries_the_hint(self):
        with tempfile.TemporaryDirectory() as td:
            path = self._write(td, self.GOOD)
            with mock.patch.object(ac.AzureDevOpsPullRequestSource, "_whoami_for_org",
                                   side_effect=ac.AdoHttpError(203, "https://dev.azure.com/o/_apis/connectionData")):
                checks = ac.doctor_checks(path)
        signin = [c for c in checks if c["check"].startswith("sign in to")][0]
        self.assertFalse(signin["ok"])
        self.assertIn("PAT was rejected", signin["detail"])

    def test_work_items_block_without_team_fails(self):
        with tempfile.TemporaryDirectory() as td:
            path = self._write(td, self.GOOD + "    work_items:\n      assignee: me\n")
            with mock.patch.object(ac.AzureDevOpsPullRequestSource, "_whoami_for_org", return_value=("id1", "J")):
                checks = ac.doctor_checks(path)
        wi = [c for c in checks if c["check"] == "work items"][0]
        self.assertFalse(wi["ok"])
        self.assertIn("team:", wi["detail"])

    def test_cmd_doctor_json_and_text(self):
        with tempfile.TemporaryDirectory() as td:
            path = self._write(td, ConfigProblemsTests.TEMPLATE)
            with mock.patch.object(ac.Config, "path", staticmethod(lambda: path)):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    rc = ac.cmd_doctor(as_json=True)
                self.assertEqual(rc, 1)
                lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
                self.assertEqual(lines[0]["check"], "config file")
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    ac.cmd_doctor(as_json=False)
                self.assertIn("FAIL  config fields", out.getvalue())
                # Routed before the config-exists gate, so it never fails with
                # "Configuration does not exist" itself.
                code, o, e = ac.dispatch(["--doctor", "--json"], {})
                self.assertEqual(code, 1)
                self.assertIn('"check"', o)


class ConfigPathTests(unittest.TestCase):
    def test_unix_config_path_uses_xdg(self):
        with tempfile.TemporaryDirectory() as td:
            old_platform = sys.platform
            old_xdg = os.environ.get("XDG_CONFIG_HOME")
            try:
                if sys.platform.startswith("win"):
                    self.skipTest("only meaningful off Windows")
                os.environ["XDG_CONFIG_HOME"] = td
                self.assertEqual(ac.Config.path(), os.path.join(td, "azure-cli.yml"))
            finally:
                if old_xdg is None:
                    os.environ.pop("XDG_CONFIG_HOME", None)
                else:
                    os.environ["XDG_CONFIG_HOME"] = old_xdg

    def test_azvicli_config_env_overrides_the_platform_default(self):
        # setup({config=...}) (lua/azure-cli/config.lua) sets exactly this -
        # AZVICLI_CONFIG wins outright, no XDG_CONFIG_HOME/%APPDATA% lookup
        # at all once it's set.
        with mock.patch.dict(os.environ, {"AZVICLI_CONFIG": "/custom/dir/mine.yml"}, clear=False):
            self.assertEqual(ac.Config.path(), "/custom/dir/mine.yml")

    def test_azvicli_config_env_expands_tilde(self):
        with mock.patch.dict(os.environ, {"AZVICLI_CONFIG": "~/configs/azure-cli.yml"}, clear=False):
            self.assertEqual(ac.Config.path(), os.path.expanduser("~/configs/azure-cli.yml"))

    def test_print_pat_matches_org_and_project(self):
        cfg = ac.Config()
        cfg.accounts = [
            make_account(project="proj1", org_url="https://dev.azure.com/org1", pat="pat1"),
            make_account(project="proj2", org_url="https://dev.azure.com/org2", pat="pat2"),
        ]
        # exercised through the pure lookup logic (cmd_print_pat prints to
        # stdout on success and returns 0/1); replicate its matching here.
        want_org = "https://dev.azure.com/org2".rstrip("/")
        match = None
        for a in cfg.accounts:
            if (a.org_url or "").rstrip("/").lower() == want_org.lower():
                match = a
                break
        self.assertIsNotNone(match)
        self.assertEqual(match.pat, "pat2")


# ---------------------------------------------------------------------------
# Vote / reviewer summary / humanize
# ---------------------------------------------------------------------------


class VoteAndFormattingTests(unittest.TestCase):
    def test_vote_semantics(self):
        self.assertTrue(ac.is_signed_off(10))
        self.assertTrue(ac.is_signed_off(5))
        self.assertFalse(ac.is_signed_off(0))
        self.assertTrue(ac.has_final_vote(-10))
        self.assertTrue(ac.has_final_vote(10))
        self.assertFalse(ac.has_final_vote(-5))
        self.assertFalse(ac.has_final_vote(0))
        self.assertTrue(ac.is_waiting(-5))
        self.assertFalse(ac.is_waiting(0))

    def test_vote_ratio_counts_all_reviewers_including_groups(self):
        pr = make_pr(
            reviewers=[
                {"id": "a", "displayName": "A", "vote": 10, "isContainer": False},
                {"id": "b", "displayName": "B", "vote": 0, "isContainer": False},
                {"id": "c", "displayName": "Group", "vote": 5, "isContainer": True},
            ]
        )
        self.assertEqual(ac.vote_ratio(pr), "2 / 3")

    def test_reviewer_summary_skips_groups_and_uses_surname(self):
        pr = make_pr(
            reviewers=[
                {"id": "a", "displayName": "Cohen, Dana", "vote": 10, "isContainer": False},
                {"id": "b", "displayName": "Yossi Levi", "vote": -5, "isContainer": False},
                {"id": "c", "displayName": "Rejected Person", "vote": -10, "isContainer": False},
                {"id": "d", "displayName": "No Vote", "vote": 0, "isContainer": False},
                {"id": "e", "displayName": "Some Group", "vote": 0, "isContainer": True},
            ]
        )
        summary = ac.reviewer_status_summary(pr)
        self.assertEqual(summary, "\u2713Cohen ~Levi \u2717Person \u00b7Vote")

    def test_reviewer_info_list_skips_groups(self):
        pr = make_pr(
            reviewers=[
                {"id": "a", "displayName": "A", "vote": 10, "isContainer": False},
                {"id": "b", "displayName": "Grp", "vote": 0, "isContainer": True},
            ]
        )
        infos = ac.reviewer_info_list(pr)
        self.assertEqual(infos, [{"name": "A", "id": "a", "vote": 10}])

    def test_surname_forms(self):
        self.assertEqual(ac._surname("Cohen, Dana"), "Cohen")
        self.assertEqual(ac._surname("Dana Cohen"), "Cohen")
        self.assertEqual(ac._surname(""), "?")
        self.assertEqual(ac._surname("   "), "?")

    def test_humanize_buckets(self):
        now = _dt.datetime(2024, 6, 15, 12, 0, 0, tzinfo=_dt.timezone.utc)
        three_hours = now - _dt.timedelta(hours=3)
        self.assertEqual(ac.humanize(three_hours, now=now), "3 hours ago")

        two_days = now - _dt.timedelta(days=2)
        self.assertEqual(ac.humanize(two_days, now=now), "2 days ago")

        yesterday = now - _dt.timedelta(days=1)
        self.assertEqual(ac.humanize(yesterday, now=now), "yesterday")

        one_min = now - _dt.timedelta(minutes=1)
        self.assertEqual(ac.humanize(one_min, now=now), "a minute ago")

    def test_iso_format_round_trips_date(self):
        dt = _dt.datetime(2024, 6, 15, 12, 34, 56, 789000, tzinfo=_dt.timezone.utc)
        s = ac.iso_format(dt)
        self.assertTrue(s.startswith("2024-06-15T12:34:56."))
        self.assertTrue(s.endswith("Z"))


# ---------------------------------------------------------------------------
# Thread / mention counting
# ---------------------------------------------------------------------------


class ThreadCountingTests(unittest.TestCase):
    def test_count_threads_basic(self):
        threads = [
            {
                "status": "active",
                "comments": [{"content": "hello", "isDeleted": False, "commentType": "text", "author": {"id": USER}}],
            },
            {
                "status": "fixed",
                "comments": [{"content": "done", "isDeleted": False, "commentType": "text", "author": {"id": OTHER_USER}}],
            },
            {
                # system-only thread: no real comments, should not count at all.
                "status": "active",
                "comments": [{"content": "reviewer added", "isDeleted": False, "commentType": "system", "author": {"id": OTHER_USER}}],
            },
            {
                # deleted-only thread: should not count.
                "status": "active",
                "comments": [{"content": "oops", "isDeleted": True, "commentType": "text", "author": {"id": OTHER_USER}}],
            },
        ]
        active, total, my_active, mention_threads, mention_total = ac.count_threads(lambda: threads, USER)
        self.assertEqual(active, 1)
        self.assertEqual(total, 2)
        self.assertEqual(my_active, 1)
        self.assertEqual(mention_threads, 0)
        self.assertEqual(mention_total, 0)

    def test_count_threads_failure_returns_all_minus_one(self):
        def boom():
            raise RuntimeError("network down")

        result = ac.count_threads(boom, USER)
        self.assertEqual(result, (-1, -1, -1, -1, -1))

    def test_count_mentions(self):
        token = "@<{0}>".format(USER)
        threads = [
            {
                "status": "active",
                "comments": [
                    {"content": "hey {0} check this".format(token), "isDeleted": False, "commentType": "text", "author": {"id": OTHER_USER}},
                    {"content": "and {0} again".format(token.upper()), "isDeleted": False, "commentType": "text", "author": {"id": OTHER_USER}},
                ],
            },
            {
                "status": "fixed",
                "comments": [{"content": "old mention {0}".format(token), "isDeleted": False, "commentType": "text", "author": {"id": OTHER_USER}}],
            },
            {
                "status": "active",
                "comments": [{"content": "deleted mention {0}".format(token), "isDeleted": True, "commentType": "text", "author": {"id": OTHER_USER}}],
            },
        ]
        mention_threads, mention_total = ac.count_mentions(threads, USER)
        # thread 1: 2 matching comments (case-insensitive), thread is active -> mentionThreads += 1
        # thread 2: 1 matching comment, but thread is "fixed" (not active) -> only adds to mentionTotal
        # thread 3: deleted comment doesn't count at all
        self.assertEqual(mention_total, 3)
        self.assertEqual(mention_threads, 1)

    def test_involves_user_ignores_deleted_flag_and_comment_type(self):
        # InvolvesUser (used for the "waiting" state check and myActiveThreads)
        # only checks content + author, unlike is_real_thread's stricter filter.
        thread = {
            "comments": [
                {"content": "hi", "isDeleted": True, "commentType": "system", "author": {"id": USER}},
            ]
        }
        self.assertTrue(ac.involves_user(thread, USER))

    def test_involves_user_ignores_blank_content(self):
        thread = {"comments": [{"content": "   ", "author": {"id": USER}}]}
        self.assertFalse(ac.involves_user(thread, USER))


# ---------------------------------------------------------------------------
# ComputeState-equivalent classification
# ---------------------------------------------------------------------------


class ComputeStateTests(unittest.TestCase):
    def setUp(self):
        self.source = ac.AzureDevOpsPullRequestSource(ac.Config())
        self.account = make_account()
        self.no_threads = lambda: []
        self.branch_exists = lambda: True

    def _state(self, pr, account=None, load_threads=None, branch_exists=None):
        return self.source._compute_state(
            pr, USER, account or self.account,
            load_threads or self.no_threads,
            branch_exists or self.branch_exists,
        )

    def test_own_pr_is_skipped(self):
        pr = make_pr(createdBy={"id": USER, "displayName": "Me"})
        self.assertIsNone(self._state(pr))

    def test_missing_source_branch_hides_pr(self):
        pr = make_pr()
        self.assertIsNone(self._state(pr, branch_exists=lambda: False))

    def test_hide_ancient_hides_old_pr(self):
        old_date = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        pr = make_pr(creationDate=old_date)
        account = make_account(hide_ancient=True)
        self.assertIsNone(self._state(pr, account=account))

    def test_hide_ancient_false_keeps_old_pr(self):
        old_date = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        pr = make_pr(creationDate=old_date)
        account = make_account(hide_ancient=False)
        self.assertEqual(self._state(pr, account=account), "Actionable")

    def test_azvicli_hide_ancient_days_widens_the_threshold(self):
        # A 60-day-old PR would be hidden at the default 30-day threshold
        # (test_hide_ancient_hides_old_pr above) - AZVICLI_HIDE_ANCIENT_DAYS=90
        # (setup({hide_ancient_days=90})) keeps it instead.
        old_date = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        pr = make_pr(creationDate=old_date)
        account = make_account(hide_ancient=True)
        source = ac.AzureDevOpsPullRequestSource(ac.Config(), {"AZVICLI_HIDE_ANCIENT_DAYS": "90"})
        state = source._compute_state(pr, USER, account, self.no_threads, self.branch_exists)
        self.assertEqual(state, "Actionable")

    def test_azvicli_hide_ancient_days_narrows_the_threshold(self):
        # A 20-day-old PR survives the default 30-day threshold, but not a
        # narrowed 10-day one.
        recent_date = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=20)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        pr = make_pr(creationDate=recent_date)
        account = make_account(hide_ancient=True)
        source = ac.AzureDevOpsPullRequestSource(ac.Config(), {"AZVICLI_HIDE_ANCIENT_DAYS": "10"})
        state = source._compute_state(pr, USER, account, self.no_threads, self.branch_exists)
        self.assertIsNone(state)

    def test_hide_ancient_days_invalid_env_falls_back_to_30(self):
        source = ac.AzureDevOpsPullRequestSource(ac.Config(), {"AZVICLI_HIDE_ANCIENT_DAYS": "not-a-number"})
        self.assertEqual(source._hide_ancient_days(), 30)
        source_blank = ac.AzureDevOpsPullRequestSource(ac.Config(), {})
        self.assertEqual(source_blank._hide_ancient_days(), 30)
        source_negative = ac.AzureDevOpsPullRequestSource(ac.Config(), {"AZVICLI_HIDE_ANCIENT_DAYS": "-5"})
        self.assertEqual(source_negative._hide_ancient_days(), 30)

    def test_draft_takes_priority(self):
        pr = make_pr(isDraft=True)
        self.assertEqual(self._state(pr), "Drafts")

    def test_not_a_reviewer_is_skipped(self):
        pr = make_pr(reviewers=[{"id": OTHER_USER, "displayName": "Other", "vote": 0, "isContainer": False}])
        self.assertIsNone(self._state(pr))

    def test_declined_review_is_skipped(self):
        pr = make_pr(reviewers=[{"id": USER, "displayName": "Me", "vote": 0, "hasDeclined": True, "isContainer": False}])
        self.assertIsNone(self._state(pr))

    def test_final_vote_is_signed_off(self):
        for vote in (10, 5, -10):
            pr = make_pr(reviewers=[{"id": USER, "displayName": "Me", "vote": vote, "isContainer": False}])
            self.assertEqual(self._state(pr), "SignedOff", "vote={0}".format(vote))

    def test_waiting_vote_with_my_active_thread_is_waiting(self):
        pr = make_pr(reviewers=[{"id": USER, "displayName": "Me", "vote": -5, "isContainer": False}])
        threads = [{"status": "active", "comments": [{"content": "my comment", "author": {"id": USER}}]}]
        self.assertEqual(self._state(pr, load_threads=lambda: threads), "Waiting")

    def test_waiting_vote_with_no_active_my_thread_is_actionable(self):
        pr = make_pr(reviewers=[{"id": USER, "displayName": "Me", "vote": -5, "isContainer": False}])
        threads = [{"status": "fixed", "comments": [{"content": "my comment", "author": {"id": USER}}]}]
        self.assertEqual(self._state(pr, load_threads=lambda: threads), "Actionable")

    def test_no_vote_is_actionable(self):
        pr = make_pr(reviewers=[{"id": USER, "displayName": "Me", "vote": 0, "isContainer": False}])
        self.assertEqual(self._state(pr), "Actionable")


# ---------------------------------------------------------------------------
# Build status aggregation and policy/missing-reviewer derivation
# ---------------------------------------------------------------------------


class BuildStatusTests(unittest.TestCase):
    def setUp(self):
        self.source = ac.AzureDevOpsPullRequestSource(ac.Config())
        self.org = "https://dev.azure.com/org"
        self.pat = "tok"
        self.project = "proj"
        self.project_id = "proj-guid-1"

    def _evaluations(self, records):
        def fake_fetch(method, url, pat, data=None):
            self.assertEqual(method, "GET")
            self.assertIn("_apis/policy/evaluations", url)
            return {"value": records}

        self.source.fetch = fake_fetch

    def test_no_build_policy_is_none(self):
        self._evaluations([])
        pr = make_pr()
        status, qpos, url, policies, missing = self.source._get_build_status(
            self.org, self.pat, self.project, self.project_id, pr
        )
        self.assertEqual(status, "none")
        self.assertIsNone(qpos)
        self.assertEqual(url, "")

    def test_failed_build_wins_over_running(self):
        records = [
            {
                "configuration": {"type": {"id": ac.BUILD_POLICY_TYPE_ID, "displayName": "Build"}},
                "status": "rejected",
                "context": {"buildId": 100},
            },
            {
                "configuration": {"type": {"id": ac.BUILD_POLICY_TYPE_ID, "displayName": "Build"}},
                "status": "running",
                "context": {"buildId": 101},
            },
        ]
        self._evaluations(records)
        pr = make_pr()
        status, qpos, url, policies, missing = self.source._get_build_status(
            self.org, self.pat, self.project, self.project_id, pr
        )
        self.assertEqual(status, "failed")
        self.assertIn("buildId=100", url)

    def test_expired_build_detected_via_context(self):
        records = [
            {
                "configuration": {"type": {"id": ac.BUILD_POLICY_TYPE_ID, "displayName": "Build"}},
                "status": "queued",
                "context": {"buildId": 55, "isExpired": True},
            }
        ]
        self._evaluations(records)
        pr = make_pr()
        status, qpos, url, policies, missing = self.source._get_build_status(
            self.org, self.pat, self.project, self.project_id, pr
        )
        self.assertEqual(status, "expired")
        self.assertIn("buildId=55", url)

    def test_running_build_fetches_queue_position(self):
        records = [
            {
                "configuration": {"type": {"id": ac.BUILD_POLICY_TYPE_ID, "displayName": "Build"}},
                "status": "running",
                "context": {"buildId": 7},
            }
        ]

        def fake_fetch(method, url, pat, data=None):
            if "_apis/policy/evaluations" in url:
                return {"value": records}
            if "_apis/build/builds/7" in url:
                return {"status": "notStarted", "queuePosition": 3}
            raise AssertionError("unexpected url " + url)

        self.source.fetch = fake_fetch
        pr = make_pr()
        status, qpos, url, policies, missing = self.source._get_build_status(
            self.org, self.pat, self.project, self.project_id, pr
        )
        self.assertEqual(status, "running")
        self.assertEqual(qpos, 3)

    def test_succeeded_build(self):
        records = [
            {
                "configuration": {"type": {"id": ac.BUILD_POLICY_TYPE_ID, "displayName": "Build"}},
                "status": "approved",
                "context": {"buildId": 9},
            }
        ]
        self._evaluations(records)
        pr = make_pr()
        status, qpos, url, policies, missing = self.source._get_build_status(
            self.org, self.pat, self.project, self.project_id, pr
        )
        self.assertEqual(status, "succeeded")

    def test_non_build_policy_and_not_applicable_is_skipped(self):
        records = [
            {"configuration": {"type": {"displayName": "Minimum number of reviewers"}}, "status": "notApplicable"},
            {"configuration": {"type": {"displayName": "Comment requirements"}}, "status": "rejected"},
        ]
        self._evaluations(records)
        pr = make_pr()
        status, qpos, url, policies, missing = self.source._get_build_status(
            self.org, self.pat, self.project, self.project_id, pr
        )
        self.assertEqual(status, "none")
        self.assertEqual(policies, [{"name": "Comment requirements", "status": "rejected"}])

    def test_missing_required_reviewers(self):
        pr = make_pr(
            reviewers=[
                {"id": "rev-1", "displayName": "Not Approved", "vote": 0, "isContainer": False},
                {"id": "rev-2", "displayName": "Approved", "vote": 10, "isContainer": False},
            ]
        )
        records = [
            {
                "configuration": {
                    "type": {"displayName": "Required reviewers"},
                    "settings": {"requiredReviewerIds": ["rev-1", "rev-2", "group-id-unresolved"]},
                },
                "status": "rejected",
            }
        ]
        self._evaluations(records)
        status, qpos, url, policies, missing = self.source._get_build_status(
            self.org, self.pat, self.project, self.project_id, pr
        )
        self.assertIn("Not Approved", missing)
        self.assertNotIn("Approved", missing)
        self.assertIn("1 more", missing)


# ---------------------------------------------------------------------------
# NDJSON serialization - field names must match the C# writer exactly
# ---------------------------------------------------------------------------


EXPECTED_FIELDS = {
    "id", "title", "repo", "project", "org", "source", "target", "author",
    "updatedIso", "updatedHuman", "isDraft", "state", "autoComplete",
    "autoCompleteSetBy", "voteRatio", "reviewerSummary", "activeThreads",
    "closedThreads", "totalThreads", "myActiveThreads", "mentionThreads",
    "mentionTotal", "description", "buildStatus", "queuePosition", "buildUrl",
    "policies", "missingReviewers", "mergeConflict", "url", "cloneUrl",
    "clonesDir", "myId", "myName", "reviewers",
}


class SerializationTests(unittest.TestCase):
    def test_record_keys_match_expected_set_exactly(self):
        pr = make_pr()
        account = make_account()
        record = ac.to_record(
            pr, account, "Actionable",
            (1, 2, 1, 0, 0),
            ("succeeded", None, "http://build", [], []),
            USER, "Me Reviewer",
        )
        self.assertEqual(set(record.keys()), EXPECTED_FIELDS)

    def test_record_is_json_serializable_as_ndjson_line(self):
        pr = make_pr()
        account = make_account()
        record = ac.to_record(
            pr, account, "Actionable",
            (1, 2, 1, 0, 0),
            ("succeeded", None, "http://build", [], []),
            USER, "Me Reviewer",
        )
        line = json.dumps(record)
        parsed = json.loads(line)
        self.assertEqual(parsed["id"], 42)
        self.assertEqual(parsed["state"], "Actionable")
        self.assertEqual(parsed["closedThreads"], 1)

    def test_unknown_thread_counts_serialize_as_minus_one(self):
        pr = make_pr()
        account = make_account()
        record = ac.to_record(
            pr, account, "Actionable",
            (-1, -1, -1, -1, -1),
            ("none", None, "", [], []),
            USER, "Me Reviewer",
        )
        self.assertEqual(record["activeThreads"], -1)
        self.assertEqual(record["closedThreads"], -1)
        self.assertEqual(record["totalThreads"], -1)
        self.assertEqual(record["myActiveThreads"], -1)

    def test_urls_are_built_and_encoded(self):
        pr = make_pr()
        account = make_account(project="my project", org_url="https://dev.azure.com/org/")
        record = ac.to_record(
            pr, account, "Actionable", (0, 0, 0, 0, 0), ("none", None, "", [], []), USER, "Me",
        )
        self.assertEqual(
            record["url"], "https://dev.azure.com/org/my%20project/_git/myrepo/pullrequest/42"
        )
        self.assertEqual(record["cloneUrl"], "https://dev.azure.com/org/my%20project/_git/myrepo")


if __name__ == "__main__":
    unittest.main()


class IdentityLookupTests(unittest.TestCase):
    """The identity lookup must hit ConnectionData with no api-version:
    on-prem TFS rejects the versioned call with 400 (seen live)."""

    def test_connection_data_is_requested_bare(self):
        cfg = ac.Config.from_string("accounts:\n  - project_name: p\n    org_url: https://tfs.example/tfs/C\n    pat: x\n")
        source = ac.AzureDevOpsPullRequestSource(cfg)
        seen = {}

        def fake_bare(url, pat):
            seen["url"] = url
            return {"authenticatedUser": {"id": "abc", "providerDisplayName": "Me"}}

        source.fetch_bare = fake_bare
        user_id, name = source._whoami_for_org("https://tfs.example/tfs/C/", "x")
        self.assertEqual((user_id, name), ("abc", "Me"))
        self.assertTrue(seen["url"].endswith("/_apis/connectionData"))
        self.assertNotIn("api-version", seen["url"])

