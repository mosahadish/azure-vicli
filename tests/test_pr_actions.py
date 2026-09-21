#!/usr/bin/env python3
"""Unit tests for azure-cli.py's PR-action subcommands (PrActions) and the
branch-prefetch modes (cmd_prefetch) - the python port of review-pr.sh's
REST helpers and its two AZVICLI_PREFETCH modes.

Run standalone with `python3 -m unittest tests/test_pr_actions.py` or via
`bash tests/run.sh`. HTTP is mocked the same way test_provider.py mocks it:
PrActions.fetch (like AzureDevOpsPullRequestSource.fetch) is swapped for a
FakeFetch that records every call (url, method, data, pat, api_version, raw)
and answers from an in-memory table - no network access needed. git is
exercised for real (a tiny scratch repo, same style the Lua tests use for
git-backed fixtures) for post_inline's git-show line-length lookup, and
mocked (subprocess.run) for the prefetch modes' git fetch argv.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from io import StringIO
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_pr_actions", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()


def make_config(org="https://dev.azure.com/org", project="proj", pat="tok"):
    cfg = ac.Config()
    cfg.accounts = [ac.AccountConfig(project=project, org_url=org, pat=pat)]
    return cfg


class FakeFetch:
    """Swapped in for PrActions.fetch (and http_request-shaped enough for
    current_user_id's bare-ConnectionData call). Records every call and
    answers from `responses` (url -> value, or -> a list of values consumed
    in order for a url called more than once), raising from `raise_for`
    (url -> exception instance) instead when present.
    """

    def __init__(self, responses=None, raise_for=None):
        self.responses = dict(responses or {})
        self.raise_for = dict(raise_for or {})
        self.calls = []

    def __call__(self, url, method="GET", data=None, pat=None, api_version="7.1", raw=False):
        self.calls.append(
            {"url": url, "method": method, "data": data, "pat": pat, "api_version": api_version, "raw": raw}
        )
        if url in self.raise_for:
            raise self.raise_for[url]
        resp = self.responses.get(url)
        if isinstance(resp, list):
            return resp.pop(0)
        if resp is not None:
            return resp
        return b"" if raw else {}


def make_actions(config=None, env_overrides=None, tmp_dir=None):
    env = {
        "AZVICLI_ORG": "https://dev.azure.com/org",
        "AZVICLI_PROJECT": "proj",
        "AZVICLI_REPO": "myrepo",
        "AZVICLI_PR": "42",
        "AZVICLI_SOURCE": "feature/x",
        "AZVICLI_TARGET": "main",
        "AZVICLI_REPO_PATH": tmp_dir or os.getcwd(),
    }
    if tmp_dir:
        env["AZVICLI_PREFETCH_DIR"] = os.path.join(tmp_dir, ".prefetch")
    if env_overrides:
        env.update(env_overrides)
    actions = ac.PrActions(config or make_config(), env)
    actions.pat = "tok"  # ensure_pat already resolved, in every test below
    return actions


# ---------------------------------------------------------------------------
# resolve_account_pat
# ---------------------------------------------------------------------------


class ResolveAccountPatTests(unittest.TestCase):
    def test_matches_org_case_insensitively_and_trailing_slash(self):
        cfg = make_config(org="https://dev.azure.com/Org/", project="proj", pat="secret")
        self.assertEqual(ac.resolve_account_pat(cfg, "https://dev.azure.com/org", "proj"), "secret")
        self.assertEqual(ac.resolve_account_pat(cfg, "HTTPS://DEV.AZURE.COM/ORG", "PROJ"), "secret")

    def test_blank_project_matches_any_account_in_org(self):
        cfg = make_config(org="https://dev.azure.com/org", project="proj", pat="secret")
        self.assertEqual(ac.resolve_account_pat(cfg, "https://dev.azure.com/org", ""), "secret")

    def test_no_match_returns_none(self):
        cfg = make_config(org="https://dev.azure.com/org", project="proj", pat="secret")
        self.assertIsNone(ac.resolve_account_pat(cfg, "https://dev.azure.com/other", "proj"))
        self.assertIsNone(ac.resolve_account_pat(cfg, "https://dev.azure.com/org", "otherproj"))

    def test_account_with_no_pat_is_skipped(self):
        cfg = ac.Config()
        cfg.accounts = [
            ac.AccountConfig(project="proj", org_url="https://dev.azure.com/org", pat=None),
            ac.AccountConfig(project="proj", org_url="https://dev.azure.com/org", pat="secret2"),
        ]
        self.assertEqual(ac.resolve_account_pat(cfg, "https://dev.azure.com/org", "proj"), "secret2")


class EnsurePatTests(unittest.TestCase):
    def test_no_matching_account_prints_diagnostic_and_returns_false(self):
        cfg = make_config(org="https://dev.azure.com/org", project="proj", pat="secret")
        actions = ac.PrActions(cfg, {"AZVICLI_ORG": "https://dev.azure.com/nope", "AZVICLI_PROJECT": "proj",
                                      "AZVICLI_REPO": "r", "AZVICLI_PR": "1"})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            ok = actions.ensure_pat()
        self.assertFalse(ok)
        self.assertIn("No PAT available", buf.getvalue())
        self.assertIn("azure-cli.yml", buf.getvalue())

    def test_matching_account_sets_pat(self):
        cfg = make_config(org="https://dev.azure.com/org", project="proj", pat="secret")
        actions = ac.PrActions(cfg, {"AZVICLI_ORG": "https://dev.azure.com/org", "AZVICLI_PROJECT": "proj",
                                      "AZVICLI_REPO": "r", "AZVICLI_PR": "1"})
        self.assertTrue(actions.ensure_pat())
        self.assertEqual(actions.pat, "secret")


# ---------------------------------------------------------------------------
# --threads / --iterations
# ---------------------------------------------------------------------------


class ThreadsIterationsTests(unittest.TestCase):
    def test_threads_url_method_and_raw_passthrough(self):
        actions = make_actions()
        url = actions._pr_url("/threads")
        fetch = FakeFetch(responses={url: b'{"value":[{"id":1}]}'})
        actions.fetch = fetch
        with mock.patch("sys.stdout") as stdout:
            rc = actions.fetch_threads()
        self.assertEqual(rc, 0)
        call = fetch.calls[0]
        self.assertEqual(call["url"], "https://dev.azure.com/org/proj/_apis/git/repositories/myrepo/pullRequests/42/threads")
        self.assertEqual(call["method"], "GET")
        self.assertEqual(call["api_version"], "6.0")
        self.assertTrue(call["raw"])
        # Text-mode write, not stdout.buffer - see _fetch_raw_list's own
        # comment: this keeps --threads/--iterations output going through
        # sys.stdout.write() so dispatch()/--serve's per-thread capture
        # (which only wraps .write, not .buffer.write) can see it.
        stdout.write.assert_called_once_with('{"value":[{"id":1}]}')

    def test_iterations_empty_body_is_a_failure(self):
        actions = make_actions()
        url = actions._pr_url("/iterations")
        actions.fetch = FakeFetch(responses={url: b""})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.fetch_iterations()
        self.assertEqual(rc, 1)
        self.assertIn("fetch_iterations", buf.getvalue())
        self.assertIn("empty response body", buf.getvalue())

    def test_threads_http_error_reports_status_and_body(self):
        actions = make_actions()
        url = actions._pr_url("/threads")
        actions.fetch = FakeFetch(raise_for={url: ac.AdoHttpError(503, url, b"server down")})
        buf = StringIO()
        with mock.patch("sys.stderr", buf):
            rc = actions.fetch_threads()
        self.assertEqual(rc, 1)
        self.assertIn("HTTP 503", buf.getvalue())
        self.assertIn("server down", buf.getvalue())


# ---------------------------------------------------------------------------
# --post / --file-comment / --pr-comment (thread bodies)
# ---------------------------------------------------------------------------


class PostThreadTests(unittest.TestCase):
    def test_pr_comment_body_has_no_thread_context(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.post_pr_comment("hello")
        self.assertEqual(rc, 0)
        self.assertIn("Comment posted.", buf.getvalue())
        call = fetch.calls[0]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["url"], actions._pr_url("/threads"))
        self.assertEqual(
            call["data"],
            {"comments": [{"parentCommentId": 0, "content": "hello", "commentType": 1}], "status": 1},
        )

    def test_pr_comment_blank_text_cancels_without_a_request(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        buf = StringIO()
        with mock.patch("sys.stdout", buf):
            rc = actions.post_pr_comment("   ")
        self.assertEqual(rc, 0)
        self.assertIn("Cancelled.", buf.getvalue())
        self.assertEqual(fetch.calls, [])

    def test_file_comment_body_has_file_path_only(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.post_file_comment("src/foo.py", "needs a docstring")
        self.assertEqual(rc, 0)
        self.assertEqual(
            fetch.calls[0]["data"],
            {
                "comments": [{"parentCommentId": 0, "content": "needs a docstring", "commentType": 1}],
                "status": 1,
                "threadContext": {"filePath": "/src/foo.py"},
            },
        )

    def test_file_comment_no_path_is_an_error(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        rc = actions.post_file_comment("", "text")
        self.assertEqual(rc, 1)


class PostInlineTests(unittest.TestCase):
    """post_inline's single-line anchor measures the line's length with
    `git show <blob>` (piped through `sed -n Np` in review-pr.sh) - exercised
    against a real scratch git repo the same way the Lua prefetch/split
    tests are, rather than mocked, since the offset math is the whole point.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self._git("init", "-q", ".")
        self._git("config", "user.email", "t@example.com")
        self._git("config", "user.name", "tester")
        self._git("checkout", "-q", "-b", "main")
        self._write("f.txt", "one\ntwo\nthree\n")
        self._git("add", "-A")
        self._git("commit", "-q", "-m", "main")
        self._git("checkout", "-q", "-b", "feature/x")
        self._write("f.txt", "one\nTWOTWO\nthree\n")
        self._git("add", "-A")
        self._git("commit", "-q", "-m", "feature")
        self._git("update-ref", "refs/remotes/origin/main", "main")
        self._git("update-ref", "refs/remotes/origin/feature/x", "feature/x")

    def tearDown(self):
        self.tmp.cleanup()

    def _git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, check=True,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _write(self, name, content):
        with open(os.path.join(self.repo, name), "w") as f:
            f.write(content)

    def test_single_line_offset_from_git_show(self):
        actions = make_actions(tmp_dir=self.repo)
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.post_inline("f.txt", "R", "2", "comment text", "")
        self.assertEqual(rc, 0)
        data = fetch.calls[0]["data"]
        # "TWOTWO" is 6 characters -> end offset is length + 1.
        self.assertEqual(
            data["threadContext"],
            {"filePath": "/f.txt", "rightFileStart": {"line": 2, "offset": 1},
             "rightFileEnd": {"line": 2, "offset": 7}},
        )

    def test_left_side_reads_the_target_branch_blob(self):
        actions = make_actions(tmp_dir=self.repo)
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.post_inline("f.txt", "L", "2", "comment text", "")
        self.assertEqual(rc, 0)
        data = fetch.calls[0]["data"]
        # "two" (target/main's copy) is 3 characters -> end offset 4.
        self.assertEqual(
            data["threadContext"],
            {"filePath": "/f.txt", "leftFileStart": {"line": 2, "offset": 1},
             "leftFileEnd": {"line": 2, "offset": 4}},
        )

    def test_range_uses_the_999999_sentinel_offset_not_git_show(self):
        actions = make_actions(tmp_dir=self.repo)
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.post_inline("f.txt", "R", "1", "range comment", "3")
        self.assertEqual(rc, 0)
        data = fetch.calls[0]["data"]
        self.assertEqual(
            data["threadContext"],
            {"filePath": "/f.txt", "rightFileStart": {"line": 1, "offset": 1},
             "rightFileEnd": {"line": 3, "offset": 999999}},
        )

    def test_single_line_selection_equal_to_start_is_not_a_range(self):
        actions = make_actions(tmp_dir=self.repo)
        fetch = FakeFetch()
        actions.fetch = fetch
        actions.post_inline("f.txt", "R", "2", "text", "2")
        data = fetch.calls[0]["data"]
        self.assertIn("rightFileEnd", data["threadContext"])
        self.assertEqual(data["threadContext"]["rightFileEnd"]["offset"], 7)  # measured, not 999999

    def test_invalid_line_is_rejected(self):
        actions = make_actions(tmp_dir=self.repo)
        actions.fetch = FakeFetch()
        self.assertEqual(actions.post_inline("f.txt", "R", "0", "text"), 1)
        self.assertEqual(actions.post_inline("f.txt", "R", "abc", "text"), 1)
        self.assertEqual(actions.post_inline("", "R", "1", "text"), 1)

    def test_invalid_side_is_rejected(self):
        actions = make_actions(tmp_dir=self.repo)
        actions.fetch = FakeFetch()
        self.assertEqual(actions.post_inline("f.txt", "X", "1", "text"), 1)


# ---------------------------------------------------------------------------
# --reply / --status / --edit-comment / --delete-comment
# ---------------------------------------------------------------------------


class ReplyStatusEditDeleteTests(unittest.TestCase):
    def test_reply_url_and_body(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.post_reply("7", "a reply")
        self.assertEqual(rc, 0)
        call = fetch.calls[0]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["url"], actions._pr_url("/threads/7/comments"))
        self.assertEqual(call["data"], {"parentCommentId": 1, "content": "a reply", "commentType": 1})

    def test_reply_invalid_thread_id(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        self.assertEqual(actions.post_reply("abc", "text"), 1)

    def test_reply_blank_text(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        self.assertEqual(actions.post_reply("7", "   "), 1)

    def test_status_maps_wontfix_and_bydesign_to_camel_case(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        actions.set_thread_status("7", "wontfix")
        self.assertEqual(fetch.calls[-1]["data"], {"status": "wontFix"})
        actions.set_thread_status("7", "bydesign")
        self.assertEqual(fetch.calls[-1]["data"], {"status": "byDesign"})
        actions.set_thread_status("7", "fixed")
        self.assertEqual(fetch.calls[-1]["data"], {"status": "fixed"})

    def test_status_invalid_keyword(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        self.assertEqual(actions.set_thread_status("7", "bogus"), 1)

    def test_edit_comment_url_and_body(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.edit_comment("7", "9", "updated text")
        self.assertEqual(rc, 0)
        call = fetch.calls[0]
        self.assertEqual(call["method"], "PATCH")
        self.assertEqual(call["url"], actions._pr_url("/threads/7/comments/9"))
        self.assertEqual(call["data"], {"content": "updated text"})

    def test_delete_comment_url_and_method_no_body(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.delete_comment("7", "9")
        self.assertEqual(rc, 0)
        call = fetch.calls[0]
        self.assertEqual(call["method"], "DELETE")
        self.assertEqual(call["url"], actions._pr_url("/threads/7/comments/9"))
        self.assertIsNone(call["data"])

    def test_edit_delete_invalid_ids(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        self.assertEqual(actions.edit_comment("x", "9", "t"), 1)
        self.assertEqual(actions.edit_comment("7", "x", "t"), 1)
        self.assertEqual(actions.delete_comment("x", "9"), 1)
        self.assertEqual(actions.delete_comment("7", "x"), 1)


# ---------------------------------------------------------------------------
# current_user_id / --vote
# ---------------------------------------------------------------------------


class CurrentUserIdVoteTests(unittest.TestCase):
    def test_current_user_id_hits_connection_data_bare_and_caches(self):
        with tempfile.TemporaryDirectory() as tmp:
            actions = make_actions(tmp_dir=tmp)
            cd_url = "https://dev.azure.com/org/_apis/ConnectionData"
            fetch = FakeFetch(responses={cd_url: {"authenticatedUser": {"id": "uid-1"}}})
            actions.fetch = fetch
            uid = actions.current_user_id()
            self.assertEqual(uid, "uid-1")
            call = fetch.calls[0]
            self.assertEqual(call["url"], cd_url)
            self.assertIsNone(call["api_version"])  # bare - no api-version query param
            # Second call reads the cache file, no second HTTP request.
            uid2 = actions.current_user_id()
            self.assertEqual(uid2, "uid-1")
            self.assertEqual(len(fetch.calls), 1)

    def test_current_user_id_failure_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            actions = make_actions(tmp_dir=tmp)
            actions.fetch = FakeFetch(raise_for={"https://dev.azure.com/org/_apis/ConnectionData": ac.AdoHttpError(400, "x")})
            self.assertIsNone(actions.current_user_id())

    def test_vote_puts_to_reviewers_uid_keyed_by_current_user(self):
        with tempfile.TemporaryDirectory() as tmp:
            actions = make_actions(tmp_dir=tmp)
            cd_url = "https://dev.azure.com/org/_apis/ConnectionData"
            fetch = FakeFetch(responses={cd_url: {"authenticatedUser": {"id": "uid-1"}}})
            actions.fetch = fetch
            rc = actions.set_vote("10")
            self.assertEqual(rc, 0)
            vote_call = fetch.calls[-1]
            self.assertEqual(vote_call["method"], "PUT")
            self.assertEqual(vote_call["url"], actions._pr_url("/reviewers/uid-1"))
            self.assertEqual(vote_call["data"], {"vote": 10})

    def test_vote_invalid_value(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        self.assertEqual(actions.set_vote("7"), 1)

    def test_vote_without_resolvable_user_id_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            actions = make_actions(tmp_dir=tmp)
            actions.fetch = FakeFetch(raise_for={"https://dev.azure.com/org/_apis/ConnectionData": ac.AdoHttpError(400, "x")})
            self.assertEqual(actions.set_vote("10"), 1)


# ---------------------------------------------------------------------------
# --complete / --auto-complete
# ---------------------------------------------------------------------------


class CompleteAutoCompleteTests(unittest.TestCase):
    def test_complete_fetches_commit_then_patches_completion_options(self):
        actions = make_actions()
        pr_url = actions._pr_url()
        fetch = FakeFetch(responses={pr_url: [{"lastMergeSourceCommit": {"commitId": "abc123"}}, {}]})
        actions.fetch = fetch
        rc = actions.complete_pr("squash", "true", "false")
        self.assertEqual(rc, 0)
        get_call, patch_call = fetch.calls
        self.assertEqual(get_call["method"], "GET")
        self.assertEqual(patch_call["method"], "PATCH")
        self.assertEqual(
            patch_call["data"],
            {
                "status": "completed",
                "lastMergeSourceCommit": {"commitId": "abc123"},
                "completionOptions": {
                    "mergeStrategy": "squash",
                    "deleteSourceBranch": True,
                    "transitionWorkItems": False,
                },
            },
        )

    def test_complete_invalid_strategy(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        self.assertEqual(actions.complete_pr("bogus"), 1)

    def test_complete_missing_merge_commit_fails(self):
        actions = make_actions()
        pr_url = actions._pr_url()
        actions.fetch = FakeFetch(responses={pr_url: {}})
        self.assertEqual(actions.complete_pr("squash"), 1)

    def test_auto_complete_off_uses_empty_guid(self):
        actions = make_actions()
        fetch = FakeFetch()
        actions.fetch = fetch
        rc = actions.set_auto_complete("off")
        self.assertEqual(rc, 0)
        self.assertEqual(
            fetch.calls[0]["data"],
            {"autoCompleteSetBy": {"id": "00000000-0000-0000-0000-000000000000"}},
        )

    def test_auto_complete_on_uses_current_user_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            actions = make_actions(tmp_dir=tmp)
            cd_url = "https://dev.azure.com/org/_apis/ConnectionData"
            fetch = FakeFetch(responses={cd_url: {"authenticatedUser": {"id": "uid-9"}}})
            actions.fetch = fetch
            rc = actions.set_auto_complete("on", "rebase", "false", "true")
            self.assertEqual(rc, 0)
            patch_call = fetch.calls[-1]
            self.assertEqual(
                patch_call["data"],
                {
                    "autoCompleteSetBy": {"id": "uid-9"},
                    "completionOptions": {
                        "mergeStrategy": "rebase",
                        "deleteSourceBranch": False,
                        "transitionWorkItems": True,
                    },
                },
            )

    def test_auto_complete_on_invalid_strategy(self):
        actions = make_actions()
        actions.fetch = FakeFetch()
        self.assertEqual(actions.set_auto_complete("on", "bogus"), 1)


# ---------------------------------------------------------------------------
# cmd_pr_action dispatch (env var validation)
# ---------------------------------------------------------------------------


class CmdPrActionDispatchTests(unittest.TestCase):
    def test_pr_action_flags_membership(self):
        for flag in ("--threads", "--iterations", "--post", "--file-comment", "--pr-comment",
                     "--reply", "--status", "--vote", "--complete", "--auto-complete",
                     "--edit-comment", "--delete-comment"):
            self.assertIn(flag, ac.PR_ACTION_FLAGS)

    def test_missing_required_env_var_fails_before_touching_config(self):
        env_backup = dict(os.environ)
        try:
            for name in ("AZVICLI_ORG", "AZVICLI_PROJECT", "AZVICLI_REPO", "AZVICLI_PR"):
                os.environ.pop(name, None)
            os.environ["AZVICLI_ORG"] = "https://dev.azure.com/org"
            # AZVICLI_PROJECT/REPO/ID left unset.
            buf = StringIO()
            with mock.patch("sys.stderr", buf):
                rc = ac.cmd_pr_action("--threads", [])
            self.assertEqual(rc, 1)
            self.assertIn("AZVICLI_PROJECT not set", buf.getvalue())
        finally:
            os.environ.clear()
            os.environ.update(env_backup)


# ---------------------------------------------------------------------------
# Prefetch modes (AZVICLI_PREFETCH=1|all)
# ---------------------------------------------------------------------------


class DefaultPrefetchDirTests(unittest.TestCase):
    """default_prefetch_dir() - AZVICLI_PREFETCH_DIR's fallback when unset,
    both platforms, plus the two call sites (PrActions.__init__,
    cmd_prefetch) actually using it instead of a .prefetch/ next to this
    script.
    """

    def test_windows_uses_localappdata(self):
        with mock.patch.object(ac.sys, "platform", "win32"), \
             mock.patch.dict(os.environ, {"LOCALAPPDATA": "C:\\Users\\me\\AppData\\Local"}, clear=False):
            self.assertEqual(ac.default_prefetch_dir(), os.path.join(
                "C:\\Users\\me\\AppData\\Local", "azure-cli", "cache"))

    def test_windows_falls_back_to_home_without_localappdata(self):
        env = dict(os.environ)
        env.pop("LOCALAPPDATA", None)
        with mock.patch.object(ac.sys, "platform", "win32"), \
             mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(ac.default_prefetch_dir(),
                              os.path.join(os.path.expanduser("~"), "azure-cli", "cache"))

    def test_linux_uses_xdg_cache_home(self):
        with mock.patch.object(ac.sys, "platform", "linux"), \
             mock.patch.dict(os.environ, {"XDG_CACHE_HOME": "/home/me/.cache"}, clear=False):
            self.assertEqual(ac.default_prefetch_dir(), os.path.join("/home/me/.cache", "azure-cli"))

    def test_linux_falls_back_to_dot_cache_without_xdg(self):
        env = dict(os.environ)
        env.pop("XDG_CACHE_HOME", None)
        with mock.patch.object(ac.sys, "platform", "linux"), \
             mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(ac.default_prefetch_dir(),
                              os.path.join(os.path.expanduser("~"), ".cache", "azure-cli"))

    def test_pr_actions_prefetch_dir_defaults_to_platform_cache_dir(self):
        # No AZVICLI_PREFETCH_DIR in env at all - PrActions.__init__ falls
        # back to default_prefetch_dir(), not a .prefetch/ next to the script.
        env = {
            "AZVICLI_ORG": "https://dev.azure.com/org", "AZVICLI_PROJECT": "proj",
            "AZVICLI_REPO": "myrepo", "AZVICLI_PR": "42",
            "AZVICLI_SOURCE": "feature/x", "AZVICLI_TARGET": "main",
        }
        actions = ac.PrActions(make_config(), env)
        self.assertEqual(actions.prefetch_dir, ac.default_prefetch_dir())
        self.assertNotIn(".prefetch", actions.prefetch_dir)

    def test_cmd_prefetch_uses_default_prefetch_dir_when_unset(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, ".git"))
            cache_dir = os.path.join(tmp, "cache-elsewhere")
            env = {
                "AZVICLI_ORG": "https://dev.azure.com/org", "AZVICLI_PROJECT": "proj",
                "AZVICLI_REPO": "myrepo", "AZVICLI_PR": "42",
                "AZVICLI_SOURCE": "feature/x", "AZVICLI_TARGET": "main",
                "AZVICLI_REPO_PATH": tmp, "AZVICLI_PREFETCH": "1",
                # AZVICLI_PREFETCH_DIR deliberately absent.
            }
            with mock.patch.dict(os.environ, env, clear=False), \
                 mock.patch.object(ac, "default_prefetch_dir", return_value=cache_dir), \
                 mock.patch.object(ac.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess(args=[], returncode=0)
                rc = ac.cmd_prefetch()
            self.assertEqual(rc, 0)
            marker = os.path.join(cache_dir, "{0}-42".format(ac._prefetch_marker_key(tmp)))
            self.assertTrue(os.path.isfile(marker))


class PrefetchTests(unittest.TestCase):
    def _env(self, tmp, **overrides):
        env = {
            "AZVICLI_ORG": "https://dev.azure.com/org", "AZVICLI_PROJECT": "proj",
            "AZVICLI_REPO": "myrepo", "AZVICLI_PR": "42",
            "AZVICLI_SOURCE": "feature/x", "AZVICLI_TARGET": "main",
            "AZVICLI_REPO_PATH": tmp, "AZVICLI_PREFETCH_DIR": os.path.join(tmp, ".prefetch"),
        }
        env.update(overrides)
        return env

    def test_per_pr_prefetch_git_argv_and_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, ".git"))
            env = self._env(tmp, AZVICLI_PREFETCH="1")
            with mock.patch.dict(os.environ, env, clear=False), \
                 mock.patch.object(ac.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess(args=[], returncode=0)
                rc = ac.cmd_prefetch()
            self.assertEqual(rc, 0)
            argv, kwargs = run.call_args
            git_argv = argv[0]
            self.assertEqual(git_argv[:5], ["git", "-c", "fetch.showForcedUpdates=false", "fetch", "--quiet"])
            self.assertIn("--no-tags", git_argv)
            self.assertIn("origin", git_argv)
            self.assertIn("+refs/heads/feature/x:refs/remotes/origin/feature/x", git_argv)
            self.assertIn("+refs/heads/main:refs/remotes/origin/main", git_argv)
            self.assertEqual(kwargs["cwd"], tmp)
            marker = os.path.join(tmp, ".prefetch", "{0}-42".format(ac._prefetch_marker_key(tmp)))
            self.assertTrue(os.path.isfile(marker))

    def test_repo_wide_prefetch_fetches_origin_with_no_refspecs(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, ".git"))
            env = self._env(tmp, AZVICLI_PREFETCH="all")
            with mock.patch.dict(os.environ, env, clear=False), \
                 mock.patch.object(ac.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess(args=[], returncode=0)
                rc = ac.cmd_prefetch()
            self.assertEqual(rc, 0)
            git_argv = run.call_args[0][0]
            self.assertEqual(git_argv, ["git", "-c", "fetch.showForcedUpdates=false", "fetch", "--quiet", "--no-tags", "origin"])
            marker = os.path.join(tmp, ".prefetch", "all-{0}".format(ac._prefetch_marker_key(tmp)))
            self.assertTrue(os.path.isfile(marker))

    def test_prefetch_failed_fetch_writes_no_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, ".git"))
            env = self._env(tmp, AZVICLI_PREFETCH="1")
            with mock.patch.dict(os.environ, env, clear=False), \
                 mock.patch.object(ac.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess(args=[], returncode=1)
                rc = ac.cmd_prefetch()
            self.assertEqual(rc, 1)
            self.assertFalse(os.path.isdir(os.path.join(tmp, ".prefetch")))

    def test_prefetch_non_git_repo_is_a_silent_no_op(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self._env(tmp, AZVICLI_PREFETCH="1")  # no .git dir created
            with mock.patch.dict(os.environ, env, clear=False), \
                 mock.patch.object(ac.subprocess, "run") as run:
                rc = ac.cmd_prefetch()
            self.assertEqual(rc, 0)
            run.assert_not_called()

    def test_prefetch_missing_source_or_target_is_a_no_op(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, ".git"))
            env = self._env(tmp, AZVICLI_PREFETCH="1", AZVICLI_SOURCE="", AZVICLI_TARGET="")
            with mock.patch.dict(os.environ, env, clear=False), \
                 mock.patch.object(ac.subprocess, "run") as run:
                rc = ac.cmd_prefetch()
            self.assertEqual(rc, 0)
            run.assert_not_called()

    def test_prefetch_missing_env_var_fails(self):
        env_backup = dict(os.environ)
        try:
            for name in ("AZVICLI_ORG", "AZVICLI_PROJECT", "AZVICLI_REPO", "AZVICLI_PR"):
                os.environ.pop(name, None)
            buf = StringIO()
            with mock.patch("sys.stderr", buf):
                rc = ac.cmd_prefetch()
            self.assertEqual(rc, 1)
        finally:
            os.environ.clear()
            os.environ.update(env_backup)


if __name__ == "__main__":
    unittest.main()
