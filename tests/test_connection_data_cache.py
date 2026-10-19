#!/usr/bin/env python3
"""Tests for the --serve daemon's ConnectionData cache (#94): one
connectionData request per org/collection and PAT within CONN_DATA_TTL,
refetched after the TTL, a 401/403/203, a PAT change, a config load or a
daemon start; one request for concurrent workers; a retry-once when a
cached identity fails; off outside the daemon, for --doctor/--whoami and
for GitHub. Fake fetches and a mocked urlopen - no network.
"""

import importlib.util
import json
import os
import shutil
import tempfile
import threading
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_module():
    path = os.path.join(REPO_ROOT, "azure-cli.py")
    spec = importlib.util.spec_from_file_location("azure_cli_conn_data_cache", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ac = _load_module()

ORG = "https://dev.azure.com/o"
TFS = "https://tfs.example/tfs/Coll"
PAT = "pat-SECRET-123"
ME = {"authenticatedUser": {"id": "uid-1", "providerDisplayName": "Me"}}


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class FakeBare:
    """fetch_bare: records every call, answers `response`."""

    def __init__(self, response=None, wait=None):
        self.response = ME if response is None else response
        self.wait = wait
        self.calls = []
        self._lock = threading.Lock()

    def __call__(self, url, pat):
        with self._lock:
            self.calls.append(url)
        if self.wait is not None:
            self.wait()
        return self.response


class FakeSourceFetch:
    """AzureDevOpsPullRequestSource.fetch: empty PR listings, raising the
    queued errors first."""

    def __init__(self, errors=None):
        self.errors = list(errors or [])
        self.calls = []

    def __call__(self, method, url, pat, data=None, api_version="7.1"):
        self.calls.append(url)
        if self.errors:
            raise self.errors.pop(0)
        return {"value": []}


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


def two_orgs_config():
    return ac.Config.from_string(
        "accounts:\n"
        "  - project_name: p\n    org_url: {0}\n    pat: {2}\n"
        "  - project_name: q\n    org_url: {1}/\n    pat: {2}\n".format(ORG, TFS, PAT))


class CacheTestCase(unittest.TestCase):
    """Daemon mode on, a fresh cache with a fake clock, put back after."""

    def setUp(self):
        self.saved_config_cache = dict(ac._config_cache)
        ac._config_cache.update({"config": None, "serving": True})
        self.clock = FakeClock()
        self.cache = ac.ConnectionDataCache(clock=self.clock)
        patcher = mock.patch.object(ac, "_conn_data_cache", self.cache)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        ac._config_cache.clear()
        ac._config_cache.update(self.saved_config_cache)

    def source(self, config=None, bare=None, fetch=None):
        src = ac.AzureDevOpsPullRequestSource(config or two_orgs_config(), {})
        src.fetch_bare = bare or FakeBare()
        src.fetch = fetch or FakeSourceFetch()
        return src

    def wi_actions(self, bare, fetch=None):
        cfg = ac.Config()
        cfg.accounts = [ac.AccountConfig(project="P", org_url=ORG, pat=PAT, work_items={"team": "T"})]
        actions = ac.WorkItemActions(cfg, {})
        actions.pat = PAT
        actions.fetch_bare = bare
        if fetch is not None:
            actions.fetch = fetch
        return actions


class HitMissTests(CacheTestCase):
    def test_two_list_runs_for_one_org_fetch_once(self):
        cfg = ac.Config.from_string("accounts:\n  - project_name: p\n    org_url: {0}\n    pat: {1}\n".format(ORG, PAT))
        bare = FakeBare()
        self.source(cfg, bare).fetch_grouped_pull_requests()
        self.source(cfg, bare).fetch_grouped_pull_requests()
        self.assertEqual(bare.calls, [ORG + "/_apis/connectionData"])

    def test_two_orgs_fetch_once_each(self):
        bare = FakeBare()
        for _ in range(3):
            self.source(bare=bare).fetch_grouped_pull_requests()
        self.assertEqual(sorted(bare.calls), sorted([ORG + "/_apis/connectionData", TFS + "/_apis/connectionData"]))

    def test_trailing_slash_and_case_share_an_entry(self):
        bare = FakeBare()
        src = self.source(bare=bare)
        src._whoami_for_org(TFS + "/", PAT)
        src._whoami_for_org(TFS.upper(), PAT)
        self.assertEqual(len(bare.calls), 1)

    def test_wi_list_assignee_and_list_share_the_org_entry(self):
        bare = FakeBare()
        self.source(ac.Config.from_string(
            "accounts:\n  - project_name: p\n    org_url: {0}\n    pat: {1}\n".format(ORG, PAT)), bare).fetch_grouped_pull_requests()
        self.assertEqual(self.wi_actions(bare).assignee, "Me")
        self.assertEqual(len(bare.calls), 1)

    def test_no_authenticated_user_is_not_kept(self):
        bare = FakeBare(response={})
        src = self.source(bare=bare)
        src._whoami_for_org(ORG, PAT)
        src._whoami_for_org(ORG, PAT)
        self.assertEqual(len(bare.calls), 2)

    def test_a_failed_fetch_is_not_kept(self):
        src = self.source()

        def boom(url, pat):
            raise ac.AdoHttpError(500, url)

        src.fetch_bare = boom
        with self.assertRaises(ac.AdoHttpError):
            src._whoami_for_org(ORG, PAT)
        bare = FakeBare()
        src.fetch_bare = bare
        self.assertEqual(src._whoami_for_org(ORG, PAT), ("uid-1", "Me"))
        self.assertEqual(len(bare.calls), 1)


class InvalidationTests(CacheTestCase):
    def test_ttl_refetches(self):
        bare = FakeBare()
        src = self.source(bare=bare)
        src._whoami_for_org(ORG, PAT)
        self.clock.now += ac.CONN_DATA_TTL - 1
        src._whoami_for_org(ORG, PAT)
        self.assertEqual(len(bare.calls), 1)
        self.clock.now += 2
        src._whoami_for_org(ORG, PAT)
        self.assertEqual(len(bare.calls), 2)

    def _auth_failure_refetches(self, urlopen_side_effect):
        bare = FakeBare()
        src = self.source(bare=bare)
        src._whoami_for_org(TFS, PAT)
        src._whoami_for_org(ORG, PAT)
        with mock.patch.object(ac.urllib.request, "urlopen", side_effect=urlopen_side_effect):
            with self.assertRaises(ac.AdoHttpError):
                ac.http_request(ORG + "/p/_apis/git/pullrequests?x=1", pat=PAT)
        src._whoami_for_org(ORG, PAT)
        src._whoami_for_org(TFS, PAT)
        # The failing org refetched; the other one kept its entry.
        self.assertEqual(bare.calls.count(ORG + "/_apis/connectionData"), 2)
        self.assertEqual(bare.calls.count(TFS + "/_apis/connectionData"), 1)

    def _http_error(self, code):
        def raise_it(req, timeout=None):
            raise ac.urllib.error.HTTPError(req.full_url, code, "x", {}, None)
        return raise_it

    def test_401_refetches(self):
        self._auth_failure_refetches(self._http_error(401))

    def test_403_refetches(self):
        self._auth_failure_refetches(self._http_error(403))

    def test_203_refetches(self):
        self._auth_failure_refetches(lambda req, timeout=None: _FakeResponse(203, b"<html>", "text/html"))

    def test_other_errors_keep_the_entry(self):
        bare = FakeBare()
        src = self.source(bare=bare)
        src._whoami_for_org(ORG, PAT)
        with mock.patch.object(ac.urllib.request, "urlopen", side_effect=self._http_error(404)):
            with self.assertRaises(ac.AdoHttpError):
                ac.http_request(ORG + "/p/_apis/git/pullrequests/1", pat=PAT)
        src._whoami_for_org(ORG, PAT)
        self.assertEqual(len(bare.calls), 1)

    def test_another_pat_is_a_miss(self):
        bare = FakeBare()
        src = self.source(bare=bare)
        src._whoami_for_org(ORG, PAT)
        src._whoami_for_org(ORG, "rotated-pat")
        src._whoami_for_org(ORG, PAT)
        self.assertEqual(len(bare.calls), 2)

    def test_config_load_clears(self):
        bare = FakeBare()
        src = self.source(bare=bare)
        src._whoami_for_org(ORG, PAT)
        with mock.patch.object(ac.Config, "from_config_file", staticmethod(two_orgs_config)):
            ac.get_cached_config()
        src._whoami_for_org(ORG, PAT)
        self.assertEqual(len(bare.calls), 2)

    def test_daemon_start_clears(self):
        bare = FakeBare()
        self.source(bare=bare)._whoami_for_org(ORG, PAT)
        self.assertEqual(len(self.cache._entries), 1)
        with mock.patch.object(ac.Config, "is_configured", staticmethod(lambda: False)), \
                mock.patch.object(ac, "_install_streams", return_value=(mock.Mock(), mock.Mock())), \
                mock.patch.object(ac.sys, "stdin", mock.Mock(buffer=[])):
            self.assertEqual(ac.serve(), 0)
        self.assertEqual(self.cache._entries, {})


class RetryOnceTests(CacheTestCase):
    def config(self):
        return ac.Config.from_string("accounts:\n  - project_name: p\n    org_url: {0}\n    pat: {1}\n".format(ORG, PAT))

    def test_list_retries_once_with_a_fresh_identity(self):
        bare = FakeBare()
        self.source(self.config(), bare).fetch_grouped_pull_requests()
        fetch = FakeSourceFetch(errors=[ac.AdoHttpError(401, ORG)])
        self.source(self.config(), bare, fetch).fetch_grouped_pull_requests()
        self.assertEqual(len(bare.calls), 2)
        self.assertEqual(len(fetch.calls), 3)  # the failed listing, then both again

    def test_list_raises_the_second_failure(self):
        bare = FakeBare()
        self.source(self.config(), bare).fetch_grouped_pull_requests()
        fetch = FakeSourceFetch(errors=[ac.AdoHttpError(401, ORG), ac.AdoHttpError(401, ORG)])
        with self.assertRaises(ac.AdoHttpError):
            self.source(self.config(), bare, fetch).fetch_grouped_pull_requests()
        self.assertEqual(len(bare.calls), 2)

    def test_list_does_not_retry_a_fresh_identity(self):
        bare = FakeBare()
        fetch = FakeSourceFetch(errors=[ac.AdoHttpError(401, ORG)])
        with self.assertRaises(ac.AdoHttpError):
            self.source(self.config(), bare, fetch).fetch_grouped_pull_requests()
        self.assertEqual(len(bare.calls), 1)
        self.assertEqual(len(fetch.calls), 1)

    def test_wi_list_wiql_retries_once_with_a_fresh_identity(self):
        bare = FakeBare()
        self.assertEqual(self.wi_actions(bare).assignee, "Me")
        wiql_url = "{0}/P/_apis/wit/wiql".format(ORG)
        calls = []

        def fetch(url, method="GET", data=None, pat=None, api_version="7.1", raw=False,
                  content_type="application/json"):
            calls.append(url)
            if url == wiql_url and calls.count(wiql_url) == 1:
                raise ac.AdoHttpError(401, url)
            return {"values": [{"value": "P"}]}  # the team's areas; no work items

        actions = self.wi_actions(bare, fetch)
        with mock.patch.object(ac.sys, "stdout"):
            rc = actions.cmd_wi_list("items", "P\\Sprint 1")
        self.assertEqual(rc, 0)
        self.assertEqual(calls.count(wiql_url), 2)
        self.assertEqual(len(bare.calls), 2)


class ConcurrencyTests(CacheTestCase):
    def test_concurrent_workers_fetch_once(self):
        gate = threading.Event()
        bare = FakeBare(wait=lambda: gate.wait(5))
        results = []
        barrier = threading.Barrier(8)

        def worker():
            actions = self.wi_actions(bare)
            barrier.wait(5)
            results.append(actions.assignee)

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        threading.Timer(0.2, gate.set).start()
        for t in threads:
            t.join(10)
        self.assertEqual(results, ["Me"] * 8)
        self.assertEqual(len(bare.calls), 1)


class BypassTests(CacheTestCase):
    def test_off_outside_the_daemon(self):
        ac._config_cache["serving"] = False
        bare = FakeBare()
        src = self.source(bare=bare)
        src._whoami_for_org(ORG, PAT)
        src._whoami_for_org(ORG, PAT)
        self.assertEqual(len(bare.calls), 2)
        self.assertEqual(self.cache._entries, {})

    def test_doctor_always_signs_in_live(self):
        bare = FakeBare()
        self.source(bare=bare)._whoami_for_org(ORG, PAT)
        with mock.patch.object(ac.AzureDevOpsPullRequestSource, "_default_fetch_bare", side_effect=bare):
            ac._doctor_config_checks(two_orgs_config())
            ac._doctor_config_checks(two_orgs_config())
        self.assertEqual(bare.calls.count(ORG + "/_apis/connectionData"), 3)

    def test_whoami_always_signs_in_live(self):
        bare = FakeBare()
        self.source(bare=bare)._whoami_for_org(ORG, PAT)
        with mock.patch.object(ac.AzureDevOpsPullRequestSource, "_default_fetch_bare", side_effect=bare), \
                mock.patch.object(ac.sys, "stdout"):
            self.assertEqual(ac.cmd_whoami(two_orgs_config(), ORG, "p"), 0)
            self.assertEqual(ac.cmd_whoami(two_orgs_config(), ORG, "p"), 0)
        self.assertEqual(len(bare.calls), 3)

    def test_github_list_does_not_touch_the_cache(self):
        account = object()
        config = mock.Mock()
        config.accounts_by_org.return_value = []
        config.github_accounts.return_value = [account]
        fake_gh = mock.Mock()
        fake_gh.list_records.return_value = [{"id": 1}]
        with mock.patch.object(ac, "github", return_value=fake_gh), \
                mock.patch.object(self.cache, "get", side_effect=AssertionError("cache used")), \
                mock.patch.object(ac.sys, "stdout"):
            self.assertEqual(ac.cmd_list(config, {}), 0)
        fake_gh.list_records.assert_called_once_with(account, {})
        self.assertEqual(self.cache._entries, {})


class PerfLogTests(CacheTestCase):
    def setUp(self):
        super().setUp()
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.env = {"AZVICLI_DEBUG": "1", "AZVICLI_PREFETCH_DIR": self.dir}

    def test_hits_misses_and_invalidations_are_logged_without_secrets(self):
        bare = FakeBare()
        src = self.source(bare=bare)
        run = ac._perf_start("--list", self.env)
        try:
            src._whoami_for_org(ORG, PAT)
            src._whoami_for_org(ORG, PAT)
            ac.conn_data_invalidate(ORG + "/p/_apis/git/pullrequests", PAT)
        finally:
            ac._perf_finish(run)
        with open(os.path.join(self.dir, "perf.log"), encoding="utf-8") as f:
            text = f.read()
        lines = [json.loads(l) for l in text.splitlines()]
        cache = [l for l in lines if l["kind"] == "cache"]
        self.assertEqual([l["result"] for l in cache], ["miss", "hit", "invalidate"])
        self.assertEqual({l["host"] for l in cache}, {"dev.azure.com"})
        self.assertEqual({l["what"] for l in cache}, {"connectionData"})
        self.assertNotIn(PAT, text)
        self.assertNotIn(ac.ConnectionDataCache.key(ORG, PAT)[1], text)


if __name__ == "__main__":
    unittest.main()
