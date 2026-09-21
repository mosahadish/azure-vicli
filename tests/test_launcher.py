#!/usr/bin/env python3
"""Unit tests for azure-cli.py's standalone launcher (launch_dashboard) and
for the AZVICLI_*/AZVICLI_WI_* environment-variable naming those provider
classes read requests through - this plugin was once called pr-dash, and
every one of these names was renamed from an old PRDASH_/WIDASH_ prefix
(see README's Environment variables section).

Run standalone with `python3 -m unittest tests/test_launcher.py` or via
`bash tests/run.sh`.
"""

import importlib.util
import os
import tempfile
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_launcher", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()


class LaunchDashboardExportsTests(unittest.TestCase):
    """launch_dashboard() is what standalone/init.lua's nvim process
    inherits its environment from - config.lua's provider_cmd() (every
    surface: dashboard, reviewer, work-items dashboard/view) resolves
    AZVICLI_PY/AZVICLI_PROVIDER to re-invoke this same provider instead of
    each one working out sys.executable/its own path independently.
    """

    def _repo_with_standalone_marker(self, td):
        # find_repo_root walks up from script_dir looking for
        # standalone/init.lua - it only checks the file exists, so an empty
        # placeholder is enough; nothing reads its contents in this test.
        os.makedirs(os.path.join(td, "standalone"), exist_ok=True)
        with open(os.path.join(td, "standalone", "init.lua"), "w", encoding="utf-8") as f:
            f.write("")

    def test_exports_azvicli_py_and_provider(self):
        with tempfile.TemporaryDirectory() as td:
            self._repo_with_standalone_marker(td)
            script_path = os.path.join(td, "azure-cli.py")
            config = ac.Config()
            config.repo_path = None

            captured = {}

            def fake_run(argv, env=None):
                captured["argv"] = argv
                captured["env"] = env
                return mock.Mock(returncode=0)

            with mock.patch.object(ac.subprocess, "run", side_effect=fake_run):
                rc = ac.launch_dashboard(config, script_path)

        self.assertEqual(rc, 0)
        self.assertEqual(captured["argv"][0], "nvim")
        env = captured["env"]
        self.assertEqual(env["AZVICLI_PY"], ac.sys.executable or "python3")
        self.assertEqual(env["AZVICLI_PROVIDER"], os.path.abspath(script_path))
        self.assertEqual(env["AZVICLI_EXE"], os.path.join(td, "azure-cli"))
        # No leftover PRDASH_*/WIDASH_* names should ever be exported again.
        self.assertFalse(any(k.startswith("PRDASH_") or k.startswith("WIDASH_") for k in env))

    def test_repo_path_only_exported_when_configured(self):
        with tempfile.TemporaryDirectory() as td:
            self._repo_with_standalone_marker(td)
            script_path = os.path.join(td, "azure-cli.py")

            captured = {}

            def fake_run(argv, env=None):
                captured["env"] = env
                return mock.Mock(returncode=0)

            with mock.patch.object(ac.subprocess, "run", side_effect=fake_run):
                config_with_path = ac.Config()
                config_with_path.repo_path = "/some/clone"
                ac.launch_dashboard(config_with_path, script_path)
                self.assertEqual(captured["env"]["AZVICLI_REPO_PATH"], "/some/clone")

                # AZVICLI_REPO_PATH must not leak from one launch into the
                # next when the second config doesn't set repo_path at all -
                # launch_dashboard pops it explicitly rather than relying on
                # a fresh os.environ.copy() to not already have it set.
                with mock.patch.dict(ac.os.environ, {"AZVICLI_REPO_PATH": "/stale/leftover"}):
                    config_without_path = ac.Config()
                    config_without_path.repo_path = None
                    ac.launch_dashboard(config_without_path, script_path)
                    self.assertNotIn("AZVICLI_REPO_PATH", captured["env"])


class RequestEnvNewNamesHonoredTests(unittest.TestCase):
    """A --serve request's `env` overrides (rpc.lua's wire protocol - see
    that file's own header comment) use the same AZVICLI_*/AZVICLI_WI_*
    names as a one-shot CLI call's os.environ; PrActions/WorkItemActions
    must honour them exactly the way they honoured the old PRDASH_*/
    WIDASH_* names before the rename.
    """

    def test_pr_actions_honors_new_env_names(self):
        actions = ac.PrActions(ac.Config(), {
            "AZVICLI_ORG": "https://dev.azure.com/org",
            "AZVICLI_PROJECT": "proj",
            "AZVICLI_REPO": "myrepo",
            "AZVICLI_PR": "42",
            "AZVICLI_SOURCE": "feature/x",
            "AZVICLI_TARGET": "main",
        })
        self.assertEqual(actions.org, "https://dev.azure.com/org")
        self.assertEqual(actions.project, "proj")
        self.assertEqual(actions.repo, "myrepo")
        self.assertEqual(actions.pr_id, "42")
        self.assertEqual(actions.source, "feature/x")
        self.assertEqual(actions.target, "main")

    def test_work_item_actions_honors_new_env_names(self):
        actions = ac.WorkItemActions(ac.Config(), {
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

    def test_cmd_pr_action_reports_new_env_names_when_missing(self):
        # cmd_pr_action's own diagnostic ("{name} not set") must name the
        # new AZVICLI_* vars, not a leftover PRDASH_* one, so a user
        # debugging a missing-env error sees a name that's actually theirs
        # to set.
        import io
        buf = io.StringIO()
        with mock.patch.object(ac.sys, "stderr", buf):
            code = ac.cmd_pr_action("--threads", [], env={"AZVICLI_ORG": "https://dev.azure.com/org"})
        self.assertEqual(code, 1)
        self.assertIn("AZVICLI_PROJECT not set", buf.getvalue())
        self.assertNotIn("PRDASH_", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
