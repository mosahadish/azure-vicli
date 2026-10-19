#!/usr/bin/env python3
"""Tests for --list's concurrent listings (#95): accounts (and orgs, and
GitHub accounts) listed at once on the run's pool of 8, records in the same
order as a serial run, one account's error or timeout reported for that
account only, and connectionData still fetched once per org - including
the retry-once after a stale cached identity. Fake fetches that sleep - no
network.
"""

import contextlib
import importlib.util
import io
import os
import socket
import threading
import time
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_list_parallel", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()

ORG = "https://dev.azure.com/o"
TFS = "https://tfs.example/tfs/Coll"
PAT = "pat-SECRET-123"
ME = {"authenticatedUser": {"id": "uid-1", "providerDisplayName": "Me"}}
DELAY = 0.2


class FakeBare:
    """fetch_bare: records every connectionData call."""

    def __init__(self):
        self.calls = []
        self._lock = threading.Lock()

    def __call__(self, url, pat):
        with self._lock:
            self.calls.append(url)
        return ME


class FakeFetch:
    """fetch: one PR per listing, named <project>-<assigned|created>, after
    sleeping delays[project]; errors[project] are raised first, one per
    call."""

    def __init__(self, delays=None, errors=None):
        self.delays = delays or {}
        self.errors = {k: list(v) for k, v in (errors or {}).items()}
        self.calls = []
        self._lock = threading.Lock()

    def __call__(self, method, url, pat, data=None, api_version="7.1"):
        project = url.split("/_apis/")[0].rsplit("/", 1)[-1]
        kind = "assigned" if "reviewerId" in url else "created"
        with self._lock:
            self.calls.append(url)
            queued = self.errors.get(project) or []
            error = queued.pop(0) if queued else None
        time.sleep(self.delays.get(project, 0))
        if error is not None:
            raise error
        return {"value": [{"pullRequestId": 1, "id": "{0}-{1}".format(project, kind)}]}


def process(self, org, pat, account, pr, *rest):
    return ("Actionable", {"id": pr["id"]})


def config(*accounts):
    return ac.Config.from_string("accounts:\n" + "".join(
        "  - project_name: {0}\n    org_url: {1}\n    pat: {2}\n".format(project, org, PAT)
        for project, org in accounts))


class ListTestCase(unittest.TestCase):
    """Outside the daemon (no connectionData cache) unless a test turns it on."""

    def setUp(self):
        saved = dict(ac._config_cache)
        ac._config_cache.update({"config": None, "serving": False})
        self.addCleanup(lambda: (ac._config_cache.clear(), ac._config_cache.update(saved)))
        cache = mock.patch.object(ac, "_conn_data_cache", ac.ConnectionDataCache())
        cache.start()
        self.addCleanup(cache.stop)
        self.bare = FakeBare()
        self.fetch = FakeFetch()
        # cmd_list builds its own source: patch the class, so it gets these.
        for name, value in (("_default_fetch", lambda s, *a, **kw: self.fetch(*a, **kw)),
                            ("_default_fetch_bare", lambda s, url, pat: self.bare(url, pat)),
                            ("_process_assigned", process), ("_process_created", process)):
            patcher = mock.patch.object(ac.AzureDevOpsPullRequestSource, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def ids(self, cfg, workers=None):
        src = ac.AzureDevOpsPullRequestSource(cfg, {})
        if workers:
            src.MAX_CONCURRENT_PULL_REQUESTS = workers
        return [r["id"] for r in src.fetch_grouped_pull_requests()]

    def run_list(self, cfg):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = ac.cmd_list(cfg, {})
        return code, out.getvalue(), err.getvalue()


class ConcurrencyTests(ListTestCase):
    def assert_overlaps(self, cfg):
        self.fetch.delays = {"a": DELAY, "b": DELAY}
        started = time.monotonic()
        self.ids(cfg)
        wall = time.monotonic() - started
        # Serially: 2 accounts x 2 listings = 4 x DELAY. At once: 2 x DELAY.
        self.assertLess(wall, 3 * DELAY, wall)

    def test_two_accounts_of_one_org_overlap(self):
        self.assert_overlaps(config(("a", ORG), ("b", ORG)))

    def test_two_orgs_overlap(self):
        self.assert_overlaps(config(("a", ORG), ("b", TFS)))


class OrderTests(ListTestCase):
    def test_order_is_config_then_assigned_then_created(self):
        self.fetch.delays = {"a": DELAY, "b": 0}
        cfg = config(("a", ORG), ("b", TFS), ("c", ORG))
        want = ["a-assigned", "a-created", "c-assigned", "c-created", "b-assigned", "b-created"]
        self.assertEqual(self.ids(cfg), want)

    def test_same_as_a_serial_run(self):
        self.fetch.delays = {"a": DELAY, "b": DELAY / 4}
        cfg = config(("a", ORG), ("b", ORG), ("c", TFS))
        self.assertEqual(self.ids(cfg), self.ids(cfg, workers=1))


class ErrorTests(ListTestCase):
    def test_one_account_failing_keeps_the_others(self):
        self.fetch.errors = {"b": [ac.AdoHttpError(500, ORG + "/b/_apis/git/pullrequests")]}
        code, out, err = self.run_list(config(("a", ORG), ("b", ORG), ("c", TFS)))
        self.assertEqual(code, 0)
        self.assertEqual([l for l in out.splitlines() if l],
                         ['{"id": "a-assigned"}', '{"id": "a-created"}', '{"id": "c-assigned"}', '{"id": "c-created"}'])
        msg = str(ac.AdoHttpError(500, ORG + "/b/_apis/git/pullrequests"))
        self.assertEqual(err, "azure-cli --list failed for b: {0}\n".format(msg))

    def test_a_timeout_is_that_accounts_error(self):
        self.fetch.errors = {"a": [socket.timeout("timed out")]}
        code, out, err = self.run_list(config(("a", ORG), ("b", TFS)))
        self.assertEqual(code, 0)
        self.assertIn('"b-assigned"', out)
        self.assertNotIn('"a-', out)
        self.assertEqual(err, "azure-cli --list failed for a: timed out\n")

    def test_every_account_failing_is_todays_failure(self):
        self.fetch.errors = {"a": [ac.AdoHttpError(500, ORG)], "b": [ac.AdoHttpError(503, TFS)]}
        code, out, err = self.run_list(config(("a", ORG), ("b", TFS)))
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(err, "azure-cli --list failed: {0}\n".format(ac.AdoHttpError(500, ORG)))

    def test_a_missing_pat_fails_only_its_org(self):
        cfg = config(("a", ORG), ("b", TFS))
        cfg.accounts[1].pat = None
        code, out, err = self.run_list(cfg)
        self.assertEqual(code, 0)
        self.assertIn('"a-created"', out)
        self.assertTrue(err.startswith("azure-cli --list failed for b: The configured organization"), err)

    def test_fetch_grouped_pull_requests_still_raises(self):
        self.fetch.errors = {"b": [ac.AdoHttpError(500, ORG)]}
        with self.assertRaises(ac.AdoHttpError):
            self.ids(config(("a", ORG), ("b", ORG)))


class ConnectionDataTests(ListTestCase):
    def test_once_per_org_outside_the_daemon(self):
        self.ids(config(("a", ORG), ("b", ORG), ("c", TFS)))
        self.assertEqual(sorted(self.bare.calls), sorted([ORG + "/_apis/connectionData", TFS + "/_apis/connectionData"]))

    def test_once_per_org_in_the_daemon(self):
        ac._config_cache["serving"] = True
        self.ids(config(("a", ORG), ("b", ORG)))
        self.ids(config(("a", ORG), ("b", ORG)))
        self.assertEqual(self.bare.calls, [ORG + "/_apis/connectionData"])

    def test_stale_identity_refetched_once_for_the_org(self):
        ac._config_cache["serving"] = True
        cfg = config(("a", ORG), ("b", ORG))
        self.ids(cfg)
        self.fetch.errors = {"a": [ac.AdoHttpError(401, ORG)], "b": [ac.AdoHttpError(401, ORG)]}
        self.assertEqual(self.ids(cfg), ["a-assigned", "a-created", "b-assigned", "b-created"])
        self.assertEqual(len(self.bare.calls), 2)


class GitHubTests(ListTestCase):
    def test_github_accounts_list_at_once_in_order_one_failing(self):
        accounts = [mock.Mock(label=mock.Mock(return_value="GitHub ({0})".format(n))) for n in ("g1", "g2", "g3")]

        def list_records(account, env):
            if account is accounts[1]:
                raise RuntimeError("no token")
            time.sleep(DELAY)
            return [{"id": account.label()}]

        cfg = config(("a", ORG))
        cfg.accounts.extend(accounts)
        for account in accounts:
            account.is_github.return_value = True
        self.fetch.delays = {"a": DELAY / 2}
        fake_gh = mock.Mock(list_records=mock.Mock(side_effect=list_records))
        started = time.monotonic()
        with mock.patch.object(ac, "github", return_value=fake_gh):
            code, out, err = self.run_list(cfg)
        wall = time.monotonic() - started
        self.assertEqual(code, 0)
        self.assertEqual([l for l in out.splitlines() if l],
                         ['{"id": "a-assigned"}', '{"id": "a-created"}', '{"id": "GitHub (g1)"}', '{"id": "GitHub (g3)"}'])
        self.assertEqual(err, "azure-cli --list failed for GitHub (g2): no token\n")
        self.assertLess(wall, 2 * DELAY, wall)


if __name__ == "__main__":
    unittest.main()
