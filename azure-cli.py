#!/usr/bin/env python3
"""azure-cli.py - headless Azure DevOps data provider + nvim launcher.

This is a drop-in replacement for the old .NET `azure-cli.exe`: same
command-line interface, same NDJSON shape for `--list`, same config file.
It talks to Azure DevOps over plain REST (urllib) instead of the ADO .NET
SDK, so the only runtime dependency is python 3.8+ itself - no .NET, no
third-party packages.

Headless flags (see README.md):
    --list                                   NDJSON PR list on stdout
    --requeue <id>                           re-queue expired/failed builds
    --print-pat --org <url> [--project <p>]  print the configured PAT
    --whoami --org <url> [--project <p>]     print the signed-in identity
    (no flags)                               launch the nvim dashboard

stdout is reserved for the data the flags above print (pure NDJSON for
--list, so the Lua side can decode it line by line); every diagnostic,
including the "Loading configuration from: ..." banner, goes to stderr.

Difference from the old C# provider: there is no Azure AD fallback here
(that relied on a Windows-only API), so every account that `--list`,
`--whoami` or `--requeue` touches needs a `pat:` in azure-cli.yml. This
was already required on non-Windows platforms; it is now required
everywhere. `--list`'s NDJSON output is otherwise unchanged, so nothing
on the Lua side needs to change to consume it.
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import traceback
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Small YAML-subset parser
# ---------------------------------------------------------------------------
#
# azure-cli.yml only ever needs: top-level scalars (bash_path, repo_path),
# an "accounts:" list of mappings with scalar values, "#" comments, and
# quoted strings. Pulling in PyYAML for that would mean a third-party
# dependency for a handful of lines of a well-known, narrow format, so this
# is a small hand-written parser instead of a general YAML implementation -
# it will happily misparse anything fancier (anchors, multi-line strings,
# nested sequences, ...), which the config file has never used.


def _strip_comment(line):
    """Removes a trailing "# ..." comment, ignoring "#" inside quotes."""
    in_single = in_double = False
    for i, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:i]
    return line


def _parse_scalar(raw):
    """Parses a YAML scalar value: quoted string, bool, or bare string."""
    s = raw.strip()
    if len(s) >= 2 and ((s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'")):
        return s[1:-1]
    if s == "":
        return None
    if s.lower() == "true":
        return True
    if s.lower() == "false":
        return False
    return s


def _split_kv(content):
    """Splits "key: value" into (key, parsed value), or None if not a kv line."""
    idx = content.find(":")
    if idx == -1:
        return None
    key = content[:idx].strip()
    if key == "":
        return None
    return key, _parse_scalar(content[idx + 1 :])


def parse_yaml_subset(text):
    """Parses the azure-cli.yml subset described above into a plain dict
    with a top-level "accounts" key holding a list of dicts.
    """
    top = {}
    accounts = []
    current = None
    in_accounts = False

    for raw_line in text.splitlines():
        line = _strip_comment(raw_line)
        stripped = line.strip()
        if stripped == "":
            continue
        indent = len(line) - len(line.lstrip(" "))

        if not in_accounts:
            if stripped == "accounts:" and indent == 0:
                in_accounts = True
                continue
            kv = _split_kv(stripped)
            if kv:
                top[kv[0]] = kv[1]
            continue

        # Inside the accounts: sequence.
        if indent == 0:
            # A top-level line ends the sequence (the config never actually
            # does this - accounts: is always last - but handle it anyway).
            in_accounts = False
            if current is not None:
                accounts.append(current)
                current = None
            kv = _split_kv(stripped)
            if kv:
                top[kv[0]] = kv[1]
            continue

        if stripped.startswith("- "):
            if current is not None:
                accounts.append(current)
            current = {}
            rest = stripped[2:].strip()
            if rest:
                kv = _split_kv(rest)
                if kv:
                    current[kv[0]] = kv[1]
            continue

        if stripped == "-":
            if current is not None:
                accounts.append(current)
            current = {}
            continue

        # A continuation line ("    org_url: ...") of the current account.
        if current is None:
            continue
        kv = _split_kv(stripped)
        if kv:
            current[kv[0]] = kv[1]

    if current is not None:
        accounts.append(current)
    top["accounts"] = accounts
    return top


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


class AccountConfig:
    """One configured account - mirrors src/Config/AccountConfig.cs."""

    def __init__(self, project=None, org_url=None, pat=None, hide_ancient=None, clones_dir=None):
        self.project = project
        self.org_url = org_url
        self.pat = pat
        self.hide_ancient = bool(hide_ancient) if hide_ancient is not None else None
        self.clones_dir = clones_dir


class Config:
    """Machine-wide + per-account settings - mirrors src/Config/Config.cs."""

    CONFIG_NAME = "azure-cli.yml"

    def __init__(self):
        self.bash_path = None
        self.repo_path = None
        self.accounts = []

    @staticmethod
    def path():
        """Same location the .NET build used: %APPDATA% on Windows,
        $XDG_CONFIG_HOME (else ~/.config) elsewhere.
        """
        if sys.platform.startswith("win"):
            appdata = os.environ.get("APPDATA") or os.path.expanduser("~")
            return os.path.join(appdata, Config.CONFIG_NAME)
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
        return os.path.join(base, Config.CONFIG_NAME)

    @staticmethod
    def validate_exists():
        p = Config.path()
        if not os.path.isfile(p):
            # stdout, exactly like the exe's Console.WriteLine - this is the
            # one startup message that isn't a diagnostic, it's the whole
            # output of the run.
            print("Configuration does not exist: {0}".format(p))
            sys.exit(1)

    @staticmethod
    def from_config_file():
        p = Config.path()
        # stderr, so --list keeps stdout as pure NDJSON.
        print("Loading configuration from: {0}".format(p), file=sys.stderr)
        return Config.from_file(p)

    @staticmethod
    def from_file(path):
        with open(path, "r", encoding="utf-8") as f:
            return Config.from_string(f.read())

    @staticmethod
    def from_string(text):
        data = parse_yaml_subset(text)
        cfg = Config()
        cfg.bash_path = data.get("bash_path")
        cfg.repo_path = data.get("repo_path")
        for raw in data.get("accounts") or []:
            cfg.accounts.append(
                AccountConfig(
                    project=raw.get("project_name"),
                    org_url=raw.get("org_url"),
                    pat=raw.get("pat"),
                    hide_ancient=raw.get("hide_ancient"),
                    clones_dir=raw.get("clones_dir"),
                )
            )
        return cfg

    def accounts_by_org(self):
        """Groups accounts by organization URL (case-insensitive, trailing
        slash ignored - the same equivalence the exe's Uri-keyed dictionary
        gave for free), preserving first-seen order. Returns a list of
        (org_url, [AccountConfig, ...]) using the first-seen spelling of
        the org URL for each group.
        """
        order = []
        groups = {}
        for a in self.accounts:
            raw = a.org_url or ""
            key = raw.rstrip("/").lower()
            if key not in groups:
                groups[key] = {"org": raw, "accounts": []}
                order.append(key)
            groups[key]["accounts"].append(a)
        return [(groups[k]["org"], groups[k]["accounts"]) for k in order]


# ---------------------------------------------------------------------------
# Date/time helpers
# ---------------------------------------------------------------------------

_ISO_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"
)


def parse_ado_datetime(s):
    """Parses an Azure DevOps REST timestamp (ISO 8601, e.g.
    "2024-05-01T12:34:56.789Z") into an aware UTC datetime. Returns None on
    anything unparseable - callers fall back to another source, same as the
    C# LatestCommitDate falling back to CreationDate.
    """
    if not s:
        return None
    s = s.strip()
    m = _ISO_RE.match(s)
    if not m:
        return None
    base, frac, tz = m.groups()
    micros = (frac[1:7].ljust(6, "0") if frac else "000000")
    if tz in (None, "Z"):
        tz = "+00:00"
    try:
        dt = datetime.strptime("{0}.{1}{2}".format(base, micros, tz), "%Y-%m-%dT%H:%M:%S.%f%z")
    except ValueError:
        return None
    return dt.astimezone(timezone.utc)


def iso_format(dt):
    """Formats a datetime close to .NET's round-trip "o" format
    (yyyy-MM-ddTHH:mm:ss.fffffffZ) - 7 fractional digits, always UTC. The
    Lua side only regex-matches the leading "yyyy-MM-ddTHH:mm:ss" out of
    this (see iso_epoch() in azure-cli.lua), so exact digit count doesn't
    matter for correctness, only for looking like what the old exe printed.
    """
    if dt is None:
        return ""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    dt = dt.astimezone(timezone.utc)
    ticks_fraction = dt.microsecond * 10  # 1 microsecond == 10 ticks (100ns units)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + ".{0:07d}Z".format(ticks_fraction)


def humanize(dt, now=None):
    """A compact "N units ago" formatter approximating Humanizer's
    DateTime.Humanize() (the C# side used Humanizer; keeping an exact port
    of its locale tables wasn't worth a dependency, so this uses the same
    bucket boundaries in spirit: seconds/minutes/hours, "yesterday"/
    "tomorrow" for +-1 day, then days/months/years).
    """
    now = now or datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    delta = (now - dt).total_seconds()
    future = delta < 0
    secs = abs(delta)

    if secs < 5:
        return "now"
    if secs < 60:
        n = max(1, round(secs))
        phrase = "a second" if n == 1 else "{0} seconds".format(n)
    elif secs < 60 * 60:
        n = max(1, round(secs / 60))
        phrase = "a minute" if n == 1 else "{0} minutes".format(n)
    elif secs < 60 * 60 * 24:
        n = max(1, round(secs / 3600))
        phrase = "an hour" if n == 1 else "{0} hours".format(n)
    elif secs < 60 * 60 * 24 * 1.5:
        return "tomorrow" if future else "yesterday"
    elif secs < 60 * 60 * 24 * 30:
        n = max(1, round(secs / 86400))
        phrase = "{0} days".format(n)
    elif secs < 60 * 60 * 24 * 365:
        n = max(1, round(secs / (86400 * 30)))
        phrase = "a month" if n == 1 else "{0} months".format(n)
    else:
        n = max(1, round(secs / (86400 * 365)))
        phrase = "a year" if n == 1 else "{0} years".format(n)

    return phrase + (" from now" if future else " ago")


# ---------------------------------------------------------------------------
# Pull request field helpers - mirror src/DataSource/*Extensions.cs
# ---------------------------------------------------------------------------

BUILD_POLICY_TYPE_ID = "0609b952-1397-4640-95ec-e00a01b2c241"


def strip_refs_heads(ref_name):
    prefix = "refs/heads/"
    if ref_name and ref_name.startswith(prefix):
        return ref_name[len(prefix) :]
    return ref_name or ""


def is_signed_off(vote):
    return vote == 10 or vote == 5  # approved / approved with suggestions


def has_final_vote(vote):
    return is_signed_off(vote) or vote == -10  # ... or rejected


def is_waiting(vote):
    return vote == -5  # waiting for author


def latest_commit_date(pr):
    """Mirrors GitPullRequestExtensions.LatestCommitDate: the newest commit
    committer date, or the PR's creation date when no commits are known.

    In practice this is *always* the creation date, for the exact same
    reason it was in the C# build: the pull-request-list REST call (and the
    SDK method it used, GetPullRequestsByProjectAsync) never returns each
    PR's commit list - that needs a separate, per-PR request. The old code
    read pr.Commits, which was consequently always empty for anything
    FetchGroupedPullRequests fetched, so it always fell through to
    CreationDate too. `pr["commits"]` is handled below only so a future,
    richer fetch (or a hand-built test PR) that does supply commits keeps
    working - --list itself never spends an extra request per PR fetching
    them, matching the old provider's performance exactly.
    """
    commits = pr.get("commits")
    if commits:
        dates = []
        for c in commits:
            d = parse_ado_datetime(((c or {}).get("committer") or {}).get("date"))
            if d:
                dates.append(d)
        if dates:
            return max(dates)
    return parse_ado_datetime(pr.get("creationDate")) or datetime.now(timezone.utc)


def vote_ratio(pr):
    """"signedOff / total" - counts *every* reviewer, groups included,
    matching GitPullRequestExtensions.VoteRatio (which doesn't filter
    IsContainer, unlike the reviewer summary below).
    """
    reviewers = pr.get("reviewers") or []
    total = len(reviewers)
    signed = sum(1 for r in reviewers if is_signed_off((r or {}).get("vote") or 0))
    return "{0} / {1}".format(signed, total)


def _vote_glyph(vote):
    if is_signed_off(vote):
        return "\u2713"  # check mark - approved / approved with suggestions
    if vote == -10:
        return "\u2717"  # ballot X - rejected
    if vote == -5:
        return "~"  # waiting for author
    return "\u00b7"  # middle dot - no vote yet


def _surname(display_name):
    if not display_name or not display_name.strip():
        return "?"
    comma = display_name.find(",")
    if comma > 0:
        return display_name[:comma].strip()
    tokens = [t for t in display_name.split(" ") if t]
    return tokens[-1] if tokens else display_name


def reviewer_status_summary(pr):
    """Compact "glyph+surname" summary, e.g. "checkCohen waitLevi", skipping
    group/team reviewers - mirrors GitPullRequestExtensions.ReviewerStatusSummary.
    """
    reviewers = pr.get("reviewers") or []
    parts = []
    for r in reviewers:
        if not r or r.get("isContainer"):
            continue
        parts.append(_vote_glyph(r.get("vote") or 0) + _surname(r.get("displayName") or ""))
    return " ".join(parts)


def reviewer_info_list(pr):
    """Individual (non-group) reviewers and their votes, matching
    PullRequestViewElement.Reviewers.
    """
    out = []
    for r in pr.get("reviewers") or []:
        if not r or r.get("isContainer"):
            continue
        out.append({"name": r.get("displayName") or "", "vote": r.get("vote") or 0})
    return out


def find_reviewer(pr, user_id):
    want = str(user_id).lower()
    for r in pr.get("reviewers") or []:
        if r and str(r.get("id") or "").lower() == want:
            return r
    return None


def build_pr_url(org, project, repo, pr_id):
    org = (org or "").rstrip("/")
    proj = urllib.parse.quote(project or "", safe="")
    r = urllib.parse.quote(repo or "", safe="")
    return "{0}/{1}/_git/{2}/pullrequest/{3}".format(org, proj, r, pr_id)


def build_clone_url(org, project, repo):
    """Mirrors PullRequestListWriter.BuildCloneUrl exactly, including its
    null-vs-empty-string distinction: an *empty* project/repo still builds
    a (slightly odd) URL, only a missing (None) one short-circuits to "".
    """
    org = (org or "").rstrip("/")
    if len(org) == 0 or project is None or repo is None:
        return ""
    proj = urllib.parse.quote(project, safe="")
    r = urllib.parse.quote(repo, safe="")
    return "{0}/{1}/_git/{2}".format(org, proj, r)


def is_text_comment(comment):
    # ADO omits commentType for plain text comments on some API versions
    # and sends "text" explicitly on others; both count.
    ct = (comment.get("commentType") or "text").lower()
    return ct == "text"


def is_real_thread(thread):
    """A thread with at least one non-deleted, human-authored comment -
    mirrors the "real" filter inside AzureDevOpsPullRequestSource.CountThreads.
    """
    comments = thread.get("comments")
    if not comments:
        return False
    return any((not c.get("isDeleted")) and is_text_comment(c) for c in comments)


def involves_user(thread, user_id):
    """Mirrors GitPullRequestCommentThreadExtensions.InvolvesUser: any
    comment with non-blank content authored by user_id, *not* filtered by
    IsDeleted or CommentType (unlike is_real_thread above - this is
    intentionally looser, matching the C# extension method exactly).
    """
    want = str(user_id).lower()
    for c in thread.get("comments") or []:
        content = c.get("content")
        if content and content.strip():
            if str((c.get("author") or {}).get("id") or "").lower() == want:
                return True
    return False


def count_threads(load_threads, user_id):
    """Mirrors AzureDevOpsPullRequestSource.CountThreads: (active, total,
    myActive, mentionThreads, mentionTotal), or all -1 on failure.
    `load_threads` is a zero-arg callable so a failure fetching threads
    (network error, etc.) is caught here exactly like the C# awaiting
    threadsTask inside its own try/catch.
    """
    try:
        threads = load_threads()
        real = [t for t in threads if is_real_thread(t)]
        active = sum(1 for t in real if t.get("status") == "active")
        my_active = sum(1 for t in real if t.get("status") == "active" and involves_user(t, user_id))
        mention_threads, mention_total = count_mentions(threads, user_id)
        return (active, len(real), my_active, mention_threads, mention_total)
    except Exception:
        return (-1, -1, -1, -1, -1)


def count_mentions(threads, user_id):
    """Mirrors AzureDevOpsPullRequestSource.CountMentions: counts the
    literal "@<GUID>" token ADO stores for a mention, case-insensitively,
    over non-deleted text comments only.
    """
    token = "@<{0}>".format(user_id).lower()
    mention_threads = 0
    mention_total = 0
    for t in threads:
        comments = t.get("comments")
        if not comments:
            continue
        thread_has_mention = False
        for c in comments:
            if c.get("isDeleted") or not is_text_comment(c):
                continue
            content = c.get("content")
            if not content:
                continue
            if token in content.lower():
                mention_total += 1
                thread_has_mention = True
        if thread_has_mention and t.get("status") == "active":
            mention_threads += 1
    return (mention_threads, mention_total)


def is_build_policy(record):
    ptype = ((record.get("configuration") or {}).get("type")) or {}
    if str(ptype.get("id") or "").lower() == BUILD_POLICY_TYPE_ID.lower():
        return True
    return (ptype.get("displayName") or "").lower() == "build"


def get_build_id(record):
    ctx = record.get("context") or {}
    bid = ctx.get("buildId")
    return bid if isinstance(bid, int) else None


def is_expired_build(record):
    ctx = record.get("context") or {}
    return ctx.get("isExpired") is True


def add_policy_info(record, policies):
    """Mirrors AzureDevOpsPullRequestSource.AddPolicyInfo."""
    status = record.get("status")
    if status is None or status == "notApplicable":
        return
    name = ((record.get("configuration") or {}).get("type") or {}).get("displayName") or ""
    if name == "":
        return
    policies.append({"name": name, "status": str(status).lower()})


def collect_missing_reviewers(record, pr, missing_names, missing_seen, unresolved_ids, unresolved_seen):
    """Mirrors AzureDevOpsPullRequestSource.CollectMissingReviewers. Never
    raises: a missing/malformed configuration just contributes nothing.
    `missing_names`/`unresolved_ids` are lists appended in first-seen order
    with `missing_seen`/`unresolved_seen` sets deduping them (the C# used a
    HashSet<string> for the same purpose).
    """
    try:
        type_name = ((record.get("configuration") or {}).get("type") or {}).get("displayName")
        if (type_name or "").lower() != "required reviewers":
            return
        status = record.get("status")
        if status is None or status == "notApplicable":
            return
        ids = ((record.get("configuration") or {}).get("settings") or {}).get("requiredReviewerIds")
        if not isinstance(ids, list):
            return
        for raw_id in ids:
            if not raw_id:
                continue
            id_str = str(raw_id)
            reviewer = next(
                (r for r in (pr.get("reviewers") or []) if r and str(r.get("id") or "").lower() == id_str.lower()),
                None,
            )
            if reviewer is None:
                key = id_str.lower()
                if key not in unresolved_seen:
                    unresolved_seen.add(key)
                    unresolved_ids.append(id_str)
            elif (reviewer.get("vote") or 0) < 5:
                name = reviewer.get("displayName") or id_str
                if name not in missing_seen:
                    missing_seen.add(name)
                    missing_names.append(name)
    except Exception:
        pass


def to_record(pr, account, state, thread_counts, build_info, user_id, user_name):
    """Builds the exact NDJSON record PullRequestListWriter.Serialize
    produces, field for field.
    """
    active, total, my_active, mention_threads, mention_total = thread_counts
    build_status, queue_position, build_url, policies, missing_reviewers = build_info

    closed = (
        total - active
        if (active is not None and total is not None and active >= 0 and total >= 0)
        else -1
    )

    org = account.org_url or ""
    project = account.project or ""
    repo = (pr.get("repository") or {}).get("name") or ""
    updated = latest_commit_date(pr)

    return {
        "id": pr.get("pullRequestId"),
        "title": pr.get("title") or "",
        "repo": repo,
        "project": project,
        "org": org,
        "source": strip_refs_heads(pr.get("sourceRefName")),
        "target": strip_refs_heads(pr.get("targetRefName")),
        "author": ((pr.get("createdBy") or {}).get("displayName")) or "",
        "updatedIso": iso_format(updated),
        "updatedHuman": humanize(updated),
        "isDraft": bool(pr.get("isDraft") or False),
        "state": state,
        "autoComplete": pr.get("autoCompleteSetBy") is not None,
        "autoCompleteSetBy": ((pr.get("autoCompleteSetBy") or {}).get("displayName")) or "",
        "voteRatio": vote_ratio(pr),
        "reviewerSummary": reviewer_status_summary(pr),
        "activeThreads": active if active is not None else -1,
        "closedThreads": closed,
        "totalThreads": total if total is not None else -1,
        "myActiveThreads": my_active if my_active is not None else -1,
        "mentionThreads": mention_threads if mention_threads is not None else -1,
        "mentionTotal": mention_total if mention_total is not None else -1,
        "description": pr.get("description") or "",
        "buildStatus": build_status or "none",
        "queuePosition": queue_position if queue_position is not None else -1,
        "buildUrl": build_url or "",
        "policies": policies,
        "missingReviewers": missing_reviewers,
        "mergeConflict": pr.get("mergeStatus") == "conflicts",
        "url": build_pr_url(org, project, repo, pr.get("pullRequestId")),
        "cloneUrl": build_clone_url(org, project, repo),
        "clonesDir": account.clones_dir or "",
        "myId": str(user_id) if user_id else "",
        "myName": user_name or "",
        "reviewers": reviewer_info_list(pr),
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


class AdoHttpError(Exception):
    def __init__(self, status, url, body=b""):
        self.status = status
        self.url = url
        self.body = body
        super().__init__("HTTP {0} for {1}".format(status, url))


def http_request(url, method="GET", data=None, pat=None, api_version="7.1", _retried=False):
    """Performs one REST call against Azure DevOps, appending api-version
    to the query string. On-prem TFS instances that reject 7.1 answer with
    a 400; when that happens (and only then) this retries once against
    api-version=6.0, which every still-supported TFS/Azure DevOps Server
    release understands.
    """
    sep = "&" if "?" in url else "?"
    full_url = "{0}{1}api-version={2}".format(url, sep, api_version)

    headers = {"Accept": "application/json"}
    if pat:
        token = base64.b64encode(":{0}".format(pat).encode("utf-8")).decode("ascii")
        headers["Authorization"] = "Basic {0}".format(token)

    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(full_url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        if e.code == 400 and not _retried and api_version != "6.0":
            return http_request(url, method=method, data=data, pat=pat, api_version="6.0", _retried=True)
        raise AdoHttpError(e.code, full_url, e.read()) from e

    if not raw:
        return {}
    return json.loads(raw.decode("utf-8"))


class RepoBranchCache:
    """Per-repository cache of existing "refs/heads/..." names, populated
    on demand and shared across concurrently-processed pull requests of the
    same repo (a per-repo lock dedupes concurrent fetches, the way the C#
    build's Lazy<Task<...>> did). Mirrors m_repoBranches/SourceBranchExists.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._entries = {}

    def exists(self, repo_id, source_ref, loader):
        if not source_ref:
            return False
        with self._lock:
            entry = self._entries.get(repo_id)
            if entry is None:
                entry = {"lock": threading.Lock(), "loaded": False, "branches": None}
                self._entries[repo_id] = entry
        with entry["lock"]:
            if not entry["loaded"]:
                entry["branches"] = loader()
                entry["loaded"] = True
        branches = entry["branches"]
        if branches is None:
            # The lookup failed; never hide a PR on uncertainty.
            return True
        return source_ref in branches


# ---------------------------------------------------------------------------
# Azure DevOps pull request source
# ---------------------------------------------------------------------------


class AzureDevOpsPullRequestSource:
    """Fetches and classifies pull requests from Azure DevOps. `self.fetch`
    is a swappable attribute - `fetch(method, url, pat, data=None) -> dict`
    - so tests can substitute a fake without touching the network; it
    defaults to `http_request` above.
    """

    MAX_CONCURRENT_PULL_REQUESTS = 8

    def __init__(self, config):
        self.config = config
        self.fetch = self._default_fetch

    def _default_fetch(self, method, url, pat, data=None):
        return http_request(url, method=method, data=data, pat=pat)

    # -- low-level REST helpers -------------------------------------------------

    @staticmethod
    def _build_url(org, path, params=None):
        base = "{0}/{1}".format((org or "").rstrip("/"), path)
        if params:
            return "{0}?{1}".format(base, urllib.parse.urlencode(params))
        return base

    def _get(self, org, pat, path, params=None):
        return self.fetch("GET", self._build_url(org, path, params), pat)

    def _post(self, org, pat, path, params=None, data=None):
        return self.fetch("POST", self._build_url(org, path, params), pat, data)

    @staticmethod
    def _pick_pat(accounts):
        return next((a.pat for a in accounts if a.pat), None)

    # -- identity -----------------------------------------------------------

    def _whoami_for_org(self, org, pat):
        resp = self._get(org, pat, "_apis/connectionData") or {}
        user = resp.get("authenticatedUser") or {}
        name = user.get("customDisplayName") or user.get("providerDisplayName") or ""
        return user.get("id"), name

    def whoami(self, organization_url, project):
        """Mirrors AzureDevOpsPullRequestSource.WhoAmIAsync: matches an
        account group by org (and, if given, project - matched against any
        account in that org's group), connects, and returns (id, name), or
        None when nothing matches.
        """
        want_org = (organization_url or "").rstrip("/").lower()
        for org, accounts in self.config.accounts_by_org():
            if org.rstrip("/").lower() != want_org:
                continue
            if project and not any((a.project or "").lower() == project.lower() for a in accounts):
                continue
            pat = self._pick_pat(accounts)
            if not pat:
                raise RuntimeError(
                    "The configured organization ({0}) has no configured PAT; a PAT is required "
                    "(no Azure AD fallback in this build).".format(org)
                )
            return self._whoami_for_org(org, pat)
        return None

    # -- listing --------------------------------------------------------------

    def _list_prs(self, org, pat, project, reviewer_id=None, creator_id=None):
        params = {"searchCriteria.status": "active"}
        if reviewer_id:
            params["searchCriteria.reviewerId"] = reviewer_id
        if creator_id:
            params["searchCriteria.creatorId"] = creator_id
        resp = self._get(org, pat, "{0}/_apis/git/pullrequests".format(urllib.parse.quote(project or "", safe="")), params)
        return (resp or {}).get("value") or []

    def _load_repo_branches(self, org, pat, repo_id):
        try:
            resp = self._get(org, pat, "_apis/git/repositories/{0}/refs".format(repo_id), {"filter": "heads/"})
            branches = set()
            for r in (resp or {}).get("value") or []:
                name = r.get("name")
                if name:
                    branches.add(name)
            return branches
        except Exception:
            return None

    def _fetch_threads(self, org, pat, pr):
        repo_id = (pr.get("repository") or {}).get("id")
        resp = self._get(
            org, pat, "_apis/git/repositories/{0}/pullRequests/{1}/threads".format(repo_id, pr.get("pullRequestId"))
        )
        return (resp or {}).get("value") or []

    def _compute_state(self, pr, user_id, account, load_threads, source_branch_exists):
        """Mirrors AzureDevOpsPullRequestSource.ComputeState exactly,
        including the order the checks run in (a later check can only ever
        run once every earlier one has passed).
        """
        one_month_ago = datetime.now(timezone.utc) - timedelta(days=30)

        # Don't show PRs we created ourselves in the assigned listing.
        if str((pr.get("createdBy") or {}).get("id") or "").lower() == str(user_id).lower():
            return None

        # Hide PRs whose source branch is gone - their diff can't be computed.
        if not source_branch_exists():
            return None

        if account.hide_ancient and latest_commit_date(pr) < one_month_ago:
            return None

        if pr.get("isDraft"):
            return "Drafts"

        reviewer = find_reviewer(pr, user_id)
        if reviewer is None:
            return None

        if reviewer.get("hasDeclined"):
            return None

        vote = reviewer.get("vote") or 0
        if has_final_vote(vote):
            return "SignedOff"

        if is_waiting(vote):
            threads = load_threads()
            if any(t.get("status") == "active" and involves_user(t, user_id) for t in threads):
                return "Waiting"
            return "Actionable"

        return "Actionable"

    def _get_build_status(self, org, pat, project, project_id, pr):
        """Mirrors AzureDevOpsPullRequestSource.GetBuildStatus."""
        policies = []
        missing_reviewers = []
        try:
            if not project or not project_id:
                return ("none", None, "", policies, missing_reviewers)

            artifact_id = "vstfs:///CodeReview/CodeReviewId/{0}/{1}".format(project_id, pr.get("pullRequestId"))
            resp = self._get(
                org, pat, "{0}/_apis/policy/evaluations".format(urllib.parse.quote(project, safe="")),
                {"artifactId": artifact_id},
            )
            evaluations = (resp or {}).get("value") or []

            any_build = any_failed = any_expired = any_running = any_pending = False
            failed_id = expired_id = running_id = succeeded_id = None
            missing_names, missing_seen = [], set()
            unresolved_ids, unresolved_seen = [], set()

            for record in evaluations:
                if is_build_policy(record):
                    any_build = True
                    status = (record.get("status") or "").lower()
                    if status in ("rejected", "broken"):
                        any_failed = True
                        if failed_id is None:
                            failed_id = get_build_id(record)
                    elif status in ("running", "queued"):
                        if is_expired_build(record):
                            any_expired = True
                            if expired_id is None:
                                expired_id = get_build_id(record)
                        else:
                            any_running = True
                            if running_id is None:
                                running_id = get_build_id(record)
                    elif status == "approved":
                        if succeeded_id is None:
                            succeeded_id = get_build_id(record)
                    else:
                        any_pending = True
                    continue

                add_policy_info(record, policies)
                collect_missing_reviewers(record, pr, missing_names, missing_seen, unresolved_ids, unresolved_seen)

            missing_reviewers.extend(missing_names)
            if unresolved_ids:
                missing_reviewers.append("{0} more".format(len(unresolved_ids)))

            if not any_build:
                return ("none", None, "", policies, missing_reviewers)

            org_trim = (org or "").rstrip("/")
            encoded_project = urllib.parse.quote(project, safe="")

            def build_url_for(bid):
                if bid is not None and len(org_trim) > 0:
                    return "{0}/{1}/_build/results?buildId={2}".format(org_trim, encoded_project, bid)
                return ""

            if any_failed:
                return ("failed", None, build_url_for(failed_id), policies, missing_reviewers)
            if any_expired:
                return ("expired", None, build_url_for(expired_id), policies, missing_reviewers)
            if any_running or any_pending:
                queue_position = self._get_queue_position(org, pat, project, running_id) if running_id else None
                return ("running", queue_position, build_url_for(running_id), policies, missing_reviewers)
            return ("succeeded", None, build_url_for(succeeded_id), policies, missing_reviewers)
        except Exception:
            return ("none", None, "", policies, missing_reviewers)

    def _get_queue_position(self, org, pat, project, build_id):
        try:
            resp = self._get(org, pat, "{0}/_apis/build/builds/{1}".format(urllib.parse.quote(project, safe=""), build_id))
            if resp and resp.get("status") == "notStarted" and resp.get("queuePosition") is not None:
                return resp.get("queuePosition")
            return None
        except Exception:
            return None

    def _build_element(self, org, pat, account, pr, state, load_threads, user_id, user_name):
        project = account.project
        project_id = ((pr.get("repository") or {}).get("project") or {}).get("id")
        build_info = self._get_build_status(org, pat, project, project_id, pr)
        thread_counts = count_threads(load_threads, user_id)
        return to_record(pr, account, state, thread_counts, build_info, user_id, user_name)

    def _process_assigned(self, org, pat, account, pr, user_id, user_name, repo_cache):
        holder = {}

        def load_threads():
            if "v" not in holder:
                holder["v"] = self._fetch_threads(org, pat, pr)
            return holder["v"]

        def branch_exists():
            repo = pr.get("repository") or {}
            repo_id = repo.get("id")
            return repo_cache.exists(repo_id, pr.get("sourceRefName"), lambda: self._load_repo_branches(org, pat, repo_id))

        state = self._compute_state(pr, user_id, account, load_threads, branch_exists)
        if state is None:
            return (None, None)
        element = self._build_element(org, pat, account, pr, state, load_threads, user_id, user_name)
        return (state, element)

    def _process_created(self, org, pat, account, pr, user_id, user_name):
        holder = {}

        def load_threads():
            if "v" not in holder:
                holder["v"] = self._fetch_threads(org, pat, pr)
            return holder["v"]

        element = self._build_element(org, pat, account, pr, "Created", load_threads, user_id, user_name)
        return ("Created", element)

    def fetch_grouped_pull_requests(self):
        """Mirrors AzureDevOpsPullRequestSource.FetchGroupedPullRequests:
        one connection per organization, assigned + created listings
        requested together, each PR's follow-up work (threads, build
        status) run concurrently bounded by a shared pool of 8 - matching
        the C# build's single, run-lifetime SemaphoreSlim(8) - and drained
        in listing order (assigned first, then created) so the output never
        reshuffles between refreshes.
        """
        records = []
        executor = ThreadPoolExecutor(max_workers=self.MAX_CONCURRENT_PULL_REQUESTS)
        try:
            for org, accounts in self.config.accounts_by_org():
                pat = self._pick_pat(accounts)
                if not pat:
                    raise RuntimeError(
                        "The configured organization ({0}) has no configured PAT; a PAT is required "
                        "(no Azure AD fallback in this build).".format(org)
                    )
                user_id, user_name = self._whoami_for_org(org, pat)
                repo_cache = RepoBranchCache()

                for account in accounts:
                    assigned = self._list_prs(org, pat, account.project, reviewer_id=user_id)
                    created = self._list_prs(org, pat, account.project, creator_id=user_id)

                    futures = []
                    for pr in assigned:
                        futures.append(
                            executor.submit(self._process_assigned, org, pat, account, pr, user_id, user_name, repo_cache)
                        )
                    for pr in created:
                        futures.append(
                            executor.submit(self._process_created, org, pat, account, pr, user_id, user_name)
                        )

                    for fut in futures:
                        _state, element = fut.result()
                        if element is not None:
                            records.append(element)
        finally:
            executor.shutdown(wait=True)
        return records

    def requeue_build_validation(self, pull_request_id):
        """Mirrors AzureDevOpsPullRequestSource.RequeueBuildValidationAsync."""
        for org, accounts in self.config.accounts_by_org():
            pat = self._pick_pat(accounts)
            if not pat:
                raise RuntimeError(
                    "The configured organization ({0}) has no configured PAT; a PAT is required "
                    "(no Azure AD fallback in this build).".format(org)
                )

            try:
                pr = self._get(org, pat, "_apis/git/pullrequests/{0}".format(pull_request_id))
            except Exception:
                continue  # Not found in this organization; try the next one.

            project_id = ((pr.get("repository") or {}).get("project") or {}).get("id")
            if not project_id:
                continue

            artifact_id = "vstfs:///CodeReview/CodeReviewId/{0}/{1}".format(project_id, pull_request_id)
            resp = self._get(org, pat, "{0}/_apis/policy/evaluations".format(project_id), {"artifactId": artifact_id})
            evaluations = (resp or {}).get("value") or []

            requeued = 0
            for record in evaluations:
                eval_id = record.get("evaluationId")
                if not is_build_policy(record) or not eval_id or eval_id == "00000000-0000-0000-0000-000000000000":
                    continue
                status = (record.get("status") or "").lower()
                failed = status in ("rejected", "broken")
                if not failed and not is_expired_build(record):
                    continue
                self._post(org, pat, "{0}/_apis/policy/evaluations/{1}".format(project_id, eval_id))
                requeued += 1

            if requeued == 0:
                return "No expired or failed build validation to re-queue for PR {0}.".format(pull_request_id)
            return "Re-queued {0} build validation(s) for PR {1}.".format(requeued, pull_request_id)

        return "PR {0} was not found in any configured account.".format(pull_request_id)


# ---------------------------------------------------------------------------
# Headless commands
# ---------------------------------------------------------------------------


def cmd_list(config):
    try:
        source = AzureDevOpsPullRequestSource(config)
        for record in source.fetch_grouped_pull_requests():
            sys.stdout.write(json.dumps(record) + "\n")
        sys.stdout.flush()
        return 0
    except Exception as ex:  # noqa: BLE001 - mirrors the exe's catch-all
        print("azure-cli --list failed: {0}".format(ex), file=sys.stderr)
        print(traceback.format_exc(), file=sys.stderr)
        return 1


def cmd_requeue(config, pull_request_id):
    try:
        source = AzureDevOpsPullRequestSource(config)
        print(source.requeue_build_validation(pull_request_id))
        return 0
    except Exception as ex:  # noqa: BLE001
        print("azure-cli --requeue failed: {0}".format(ex), file=sys.stderr)
        print(traceback.format_exc(), file=sys.stderr)
        return 1


def cmd_print_pat(config, org, project):
    if not org:
        print("azure-cli --print-pat requires --org <organization-url>.", file=sys.stderr)
        return 1

    want_org = org.rstrip("/")
    for account in config.accounts:
        org_matches = (account.org_url or "").rstrip("/").lower() == want_org.lower()
        project_matches = (not project) or ((account.project or "").lower() == project.lower())
        if org_matches and project_matches:
            if not account.pat:
                print("azure-cli --print-pat: matching account has no 'pat' configured.", file=sys.stderr)
                return 1
            sys.stdout.write(account.pat)
            return 0

    suffix = "." if not project else " and project '{0}'.".format(project)
    print("azure-cli --print-pat: no account matches org '{0}'{1}".format(org, suffix), file=sys.stderr)
    return 1


def cmd_whoami(config, org, project):
    if not org:
        print("azure-cli --whoami requires --org <organization-url>.", file=sys.stderr)
        return 1
    try:
        source = AzureDevOpsPullRequestSource(config)
        result = source.whoami(org, project)
        if result is None:
            suffix = "." if not project else " and project '{0}'.".format(project)
            print("azure-cli --whoami: no account matches org '{0}'{1}".format(org, suffix), file=sys.stderr)
            return 1
        user_id, display_name = result
        print(json.dumps({"id": user_id, "displayName": display_name}))
        return 0
    except Exception as ex:  # noqa: BLE001
        print("azure-cli --whoami failed: {0}".format(ex), file=sys.stderr)
        return 1


# ---------------------------------------------------------------------------
# Dashboard launcher - mirrors EntryPoint.LaunchDashboard
# ---------------------------------------------------------------------------


def find_repo_root(start_dir):
    """Walks up from start_dir looking for azure-cli.lua, so this still
    works if azure-cli.py is ever run from a packaged/copied location.
    """
    d = start_dir
    for _ in range(8):
        if d is None:
            return None
        if os.path.isfile(os.path.join(d, "azure-cli.lua")):
            return d
        parent = os.path.dirname(d)
        d = parent if parent != d else None
    return None


def resolve_bash_path(config):
    """Resolves a git-bash-compatible bash: the configured bash_path, then
    the same well-known Git-for-Windows locations the exe probed, then (new
    here, since it costs nothing and `shutil` is already in the toolbox) a
    plain PATH lookup - which is what actually makes `azure-cli` with no
    arguments launch the dashboard out of the box on Linux/macOS, where the
    exe's Windows-only candidate list never found anything.
    """
    candidates = [
        config.bash_path,
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
    ]
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        candidates.append(os.path.join(local_app_data, "Programs", "Git", "bin", "bash.exe"))

    for c in candidates:
        if c and os.path.isfile(c):
            return c

    return shutil.which("bash")


def build_pat_table(config):
    """One "org<TAB>project<TAB>pat" line per account with a PAT - mirrors
    EntryPoint.BuildPatTable, read by resolve-pat.sh via PRDASH_PATS.
    """
    lines = []
    for account in config.accounts:
        if not account.pat or not account.org_url:
            continue
        org = account.org_url.rstrip("/")
        lines.append("{0}\t{1}\t{2}".format(org, account.project or "", account.pat))
    return "\n".join(lines)


def launch_dashboard(config, script_path):
    script_dir = os.path.dirname(os.path.abspath(script_path))
    repo_root = find_repo_root(script_dir)
    if repo_root is None:
        print(
            "azure-cli: could not find azure-cli.lua near {0}. Keep azure-cli.py under its repo, "
            "or use --list/--requeue/--print-pat.".format(script_dir),
            file=sys.stderr,
        )
        return 1

    lua_entry = os.path.join(repo_root, "azure-cli.lua").replace("\\", "/")
    review_script = os.path.join(repo_root, "review-pr.sh")
    wi_list = os.path.join(repo_root, "wi-list.sh")
    wi_detail = os.path.join(repo_root, "wi-detail.sh")
    # The launcher script, not this .py file - git-bash (and everything
    # that shells out through PRDASH_EXE, like resolve-pat.sh) needs a
    # single executable token, and on Windows that has to be the bash
    # script (azure-cli), not "python azure-cli.py".
    exe_path = os.path.join(repo_root, "azure-cli")

    bash_path = resolve_bash_path(config)
    if bash_path is None:
        print(
            "azure-cli: could not find a bash for review-pr.sh/wi-*.sh to run under. "
            "Add 'bash_path: C:\\Path\\To\\Git\\bin\\bash.exe' to the config file.",
            file=sys.stderr,
        )
        return 1

    env = os.environ.copy()
    env["PRDASH_EXE"] = exe_path
    env["PRDASH_SCRIPT"] = review_script
    env["PRDASH_BASH"] = bash_path
    env["WIDASH_LIST"] = wi_list
    env["WIDASH_DETAIL"] = wi_detail

    pat_table = build_pat_table(config)
    if pat_table:
        env["PRDASH_PATS"] = pat_table
    else:
        env.pop("PRDASH_PATS", None)

    if config.repo_path:
        env["PRDASH_REPO_PATH"] = config.repo_path
    else:
        env.pop("PRDASH_REPO_PATH", None)

    try:
        proc = subprocess.run(["nvim", "-u", "NONE", "-c", "luafile {0}".format(lua_entry)], env=env)
        return proc.returncode
    except (FileNotFoundError, OSError) as ex:
        print("azure-cli: failed to launch nvim (is it on PATH?): {0}".format(ex), file=sys.stderr)
        return 1


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="azure-cli", add_help=True)
    parser.add_argument("--list", action="store_true", help="Print pull requests as NDJSON and exit (no TUI)")
    parser.add_argument(
        "--requeue", type=int, default=None, metavar="ID",
        help="Re-queue build validation for the given pull request id and exit (no TUI)",
    )
    parser.add_argument(
        "--print-pat", dest="print_pat", action="store_true",
        help="Print the configured PAT for --org/--project and exit (no TUI)",
    )
    parser.add_argument("--org", default=None, help="Organization URL to match when resolving --print-pat/--whoami")
    parser.add_argument("--project", default=None, help="Project name to match when resolving --print-pat/--whoami")
    parser.add_argument(
        "--whoami", action="store_true",
        help="Print the authenticated identity for --org/--project as JSON and exit (no TUI)",
    )
    # Anything else is ignored rather than rejected - none of the shell/Lua
    # callers in this repo pass anything but the flags above.
    args, _unknown = parser.parse_known_args(argv)
    return args


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    args = parse_args(argv)

    Config.validate_exists()
    config = Config.from_config_file()

    if args.list:
        return cmd_list(config)
    if args.requeue is not None:
        return cmd_requeue(config, args.requeue)
    if args.print_pat:
        return cmd_print_pat(config, args.org, args.project)
    if args.whoami:
        return cmd_whoami(config, args.org, args.project)

    return launch_dashboard(config, __file__)


if __name__ == "__main__":
    sys.exit(main())
