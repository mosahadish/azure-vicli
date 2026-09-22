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
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import traceback
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser

# ---------------------------------------------------------------------------
# Small YAML-subset parser
# ---------------------------------------------------------------------------
#
# azure-cli.yml only ever needs: top-level scalars (repo_path),
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
    """Parses a YAML scalar value: quoted string, bool, bare string, or an
    inline flow list ("[a, b, c]") - the one sequence shape this subset
    parser understands, added for an account's work_items: types: (see
    AccountConfig.work_items below), which also accepts a plain
    comma-separated scalar instead.
    """
    s = raw.strip()
    if len(s) >= 2 and s[0] == "[" and s[-1] == "]":
        inner = s[1:-1].strip()
        if inner == "":
            return []
        return [_parse_scalar(item) for item in inner.split(",")]
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

    One extra shape beyond the flat "key: value" continuation lines
    documented above: an account may have a single nested mapping, opened
    by a "key:" line with no value (currently only "work_items:") and
    closed by the next line back at or above that opener's own indent.
    Its fields land in a plain dict under that key, same _split_kv scalar
    parsing as everything else - added for work_items: team/assignee/types
    (see AccountConfig.work_items) without generalizing this parser to
    arbitrary nesting depth, which the config file still never needs.
    """
    top = {}
    accounts = []
    current = None
    in_accounts = False
    nested_key = None      # currently-open nested mapping's key, or None
    nested_dict = None
    nested_open_indent = None  # indent of the "key:" line that opened it

    def close_nested():
        if nested_key is not None and current is not None:
            # "pat:" with nothing after it and nothing indented under it
            # (a template placeholder, its comment stripped) is a blank
            # scalar, not an empty mapping.
            current[nested_key] = nested_dict if nested_dict else None

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

        # A nested mapping is open and this line is indented under it -
        # fold it in instead of treating it as an account/top-level line.
        if nested_key is not None and indent > nested_open_indent:
            kv = _split_kv(stripped)
            if kv:
                nested_dict[kv[0]] = kv[1]
            continue
        if nested_key is not None:
            close_nested()
            nested_key = nested_dict = nested_open_indent = None

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
            if kv[1] is None and stripped.endswith(":"):
                # "key:" with nothing after it opens a nested mapping
                # rather than setting a blank scalar.
                nested_key, nested_dict, nested_open_indent = kv[0], {}, indent
            else:
                current[kv[0]] = kv[1]

    if nested_key is not None:
        close_nested()
    if current is not None:
        accounts.append(current)
    top["accounts"] = accounts
    return top


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


class AccountConfig:
    """One configured account - mirrors src/Config/AccountConfig.cs.

    `work_items` is None for an account with no work_items: block (the
    common case for every account but the one backing the work-item
    screens), else the raw nested dict parse_yaml_subset built for it -
    team: (str), assignee: (str, optional) and types: (str or list,
    optional). WorkItemActions.__init__ is what actually applies its
    fields and the WI_ACCOUNT/env-override precedence on top of them.
    """

    def __init__(self, project=None, org_url=None, pat=None, hide_ancient=None, clones_dir=None,
                 work_items=None, pat_file=None):
        self.project = project
        self.org_url = org_url
        self.pat = pat
        # pat_file: a file holding nothing but the token, as an alternative
        # to pat: - keeps the secret out of azure-cli.yml / init.lua (which
        # people put in dotfiles repos). Read lazily by token() below.
        self.pat_file = pat_file if isinstance(pat_file, str) and pat_file.strip() else None
        self._token = None
        self.hide_ancient = bool(hide_ancient) if hide_ancient is not None else None
        self.clones_dir = clones_dir
        self.work_items = work_items if isinstance(work_items, dict) else None

    def has_pat_source(self):
        """True when pat: is set or pat_file: names a file - i.e. the
        account isn't simply missing its token in the config."""
        return bool((isinstance(self.pat, str) and self.pat.strip()) or self.pat_file)

    def pat_file_path(self):
        return os.path.expanduser(self.pat_file) if self.pat_file else None

    def token(self):
        """The PAT to send: pat: verbatim (stripped), else the first
        non-blank content of pat_file (whitespace/newline stripped, read
        once and cached). None when neither yields a token - callers
        already treat "no PAT" as an error."""
        if isinstance(self.pat, str) and self.pat.strip():
            return self.pat.strip()
        if self.pat_file:
            if self._token is None:
                try:
                    with open(self.pat_file_path(), "r", encoding="utf-8") as fh:
                        self._token = fh.read().strip()
                except OSError:
                    self._token = ""
            return self._token or None
        return None

    def pat_file_problem(self):
        """Why pat_file can't supply a token right now (missing, unreadable,
        empty), or None when it can or when pat: is used instead."""
        if isinstance(self.pat, str) and self.pat.strip():
            return None
        if not self.pat_file:
            return None
        path = self.pat_file_path()
        if not os.path.isfile(path):
            return "pat_file {0} does not exist - put the personal access token in it, alone on one line".format(path)
        if not self.token():
            return "pat_file {0} is empty or unreadable".format(path)
        return None

    def pat_file_permission_problem(self):
        """A pat_file other users can read (group/other bits set) - a
        warning --doctor raises the way ssh does for a loose key; nothing
        else refuses to work over it. Windows has no such mode bits."""
        if not self.pat_file or os.name == "nt":
            return None
        path = self.pat_file_path()
        try:
            mode = os.stat(path).st_mode
        except OSError:
            return None
        if mode & 0o077:
            return "pat_file {0} is readable by other users (mode {1:o}) - run: chmod 600 {0}".format(path, mode & 0o777)
        return None


class Config:
    """Machine-wide + per-account settings - mirrors src/Config/Config.cs."""

    CONFIG_NAME = "azure-cli.yml"

    # Plugin users can hand their accounts straight to setup({accounts=...})
    # in init.lua instead of keeping azure-cli.yml at all; config.lua then
    # exports them as JSON in this variable (inherited by the --serve daemon
    # and every one-shot provider call), and it wins over the file outright.
    ACCOUNTS_ENV = "AZVICLI_ACCOUNTS_JSON"

    def __init__(self):
        self.repo_path = None
        self.accounts = []

    @staticmethod
    def accounts_json():
        """The setup({accounts=...}) JSON text, or None when the config comes
        from azure-cli.yml (the standalone launcher, or a plugin user who
        kept the file)."""
        text = os.environ.get(Config.ACCOUNTS_ENV)
        return text if text and text.strip() else None

    @staticmethod
    def source_label():
        """Where the accounts come from, for messages: the file's path, or
        the setup() call."""
        if Config.accounts_json():
            return "setup({accounts=...}) in your Neovim config"
        return Config.path()

    @staticmethod
    def is_configured():
        """A config source exists at all: setup({accounts}) or the file."""
        return bool(Config.accounts_json()) or os.path.isfile(Config.path())

    @staticmethod
    def path():
        """AZVICLI_CONFIG overrides this entirely when set (`~` expanded) -
        see lua/azure-cli/config.lua's setup() `config` option and README's
        setup() options/Environment variables sections. Otherwise, the same
        location the .NET build used: %APPDATA% on Windows, $XDG_CONFIG_HOME
        (else ~/.config) elsewhere.

        get_cached_config()'s mtime-based reload keys off whatever this
        returns (it calls Config.path() fresh on every request), so a
        setup({config=...}) call that changes AZVICLI_CONFIG before the
        --serve daemon's next request picks up the new file without
        restarting the daemon - the same "re-read on the next request" rule
        an edited azure-cli.yml already gets.
        """
        override = os.environ.get("AZVICLI_CONFIG")
        if override:
            return os.path.expanduser(override)
        if sys.platform.startswith("win"):
            appdata = os.environ.get("APPDATA") or os.path.expanduser("~")
            return os.path.join(appdata, Config.CONFIG_NAME)
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
        return os.path.join(base, Config.CONFIG_NAME)

    @staticmethod
    def validate_exists():
        """Returns True when the config file exists, else prints the same
        diagnostic the old exe printed and returns False - callers exit 1 on
        that. This used to sys.exit(1) directly; under --serve that would
        raise SystemExit out of a request handler running on a worker
        thread, killing far more than just that one request (see dispatch()
        below), so every caller now checks the return value itself. Behaves
        identically for the top-level one-shot CLI, since main() ultimately
        does sys.exit(main()) either way.
        """
        if Config.accounts_json():
            return True
        p = Config.path()
        if not os.path.isfile(p):
            # stderr: the dashboards collect a failed run's stderr for the
            # error they show (this once went to stdout and rendered as a
            # blank "Failed to load PRs (exit 1):" on a brand-new install).
            print("Configuration does not exist: {0}\n"
                  "Open the dashboard (./azure-cli, or :AzureCli in Neovim) and it writes a template "
                  "there for you to fill in; `azure-cli --init-config` does the same from a terminal. "
                  "See docs/configuration.md.".format(p), file=sys.stderr)
            return False
        return True

    def problems(self):
        """Every reason this config can't work yet, as human-readable
        lines - an account with no project_name/org_url/pat (the untouched
        install.sh template parses to exactly that), an org_url without a
        scheme, or no accounts at all. Empty when the config is usable.
        Checked up front by every command (see config_problems()) so the
        first run says which field to fill in, instead of failing deep in
        a REST call with "organization () has no configured PAT".
        """
        out = []
        if not self.accounts:
            out.append("no accounts: entries - add one with project_name, org_url and pat")
            return out
        for i, a in enumerate(self.accounts, 1):
            label = "account {0}{1}".format(i, " ({0})".format(a.project) if a.project else "")
            missing = [name for name, value in (("project_name", a.project), ("org_url", a.org_url),
                                                ("pat", "set" if a.has_pat_source() else None))
                       if not isinstance(value, str) or not value.strip()]
            if len(missing) == 3:
                out.append("{0}: project_name, org_url and pat are all empty - still the untouched "
                           "template? Fill in the TODO lines.".format(label))
                continue
            for name in missing:
                hint = ""
                if name == "pat":
                    hint = (" (a personal access token with Code and Work Items read/write scopes, "
                            "or pat_file: a file holding just the token)")
                elif name == "org_url":
                    hint = " (e.g. https://dev.azure.com/my-org)"
                out.append("{0}: {1} is missing{2}".format(label, name, hint))
            pat_problem = a.pat_file_problem()
            if pat_problem:
                out.append("{0}: {1}".format(label, pat_problem))
            if isinstance(a.org_url, str) and a.org_url.strip() and not re.match(r"^https?://", a.org_url.strip(), re.I):
                out.append("{0}: org_url must start with https:// (got '{1}')".format(label, a.org_url.strip()))
        return out

    @staticmethod
    def from_config_file():
        text = Config.accounts_json()
        if text:
            # stderr, so --list keeps stdout as pure NDJSON.
            print("Loading configuration from setup({accounts=...})", file=sys.stderr)
            return Config.from_json(text)
        p = Config.path()
        print("Loading configuration from: {0}".format(p), file=sys.stderr)
        return Config.from_file(p)

    @staticmethod
    def from_json(text):
        """setup({accounts=...}) as config.lua exports it: the same keys the
        YAML file uses ({"accounts": [{project_name, org_url, pat | pat_file,
        hide_ancient, clones_dir, work_items: {team, ...}}], "repo_path"})."""
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError("{0} must hold a JSON object".format(Config.ACCOUNTS_ENV))
        return Config.from_dict(data)

    @staticmethod
    def from_file(path):
        with open(path, "r", encoding="utf-8") as f:
            return Config.from_string(f.read())

    @staticmethod
    def from_string(text):
        return Config.from_dict(parse_yaml_subset(text))

    @staticmethod
    def from_dict(data):
        cfg = Config()
        cfg.repo_path = data.get("repo_path")
        for raw in data.get("accounts") or []:
            if not isinstance(raw, dict):
                continue
            cfg.accounts.append(
                AccountConfig(
                    project=raw.get("project_name"),
                    org_url=raw.get("org_url"),
                    pat=raw.get("pat"),
                    pat_file=raw.get("pat_file"),
                    hide_ancient=raw.get("hide_ancient"),
                    clones_dir=raw.get("clones_dir"),
                    work_items=raw.get("work_items"),
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


# A one-shot CLI invocation only ever calls Config.from_config_file() once,
# so re-parsing the YAML on every call was never a cost worth caching for.
# --serve changes that: every request run through dispatch() (PR/work-item
# actions, --list, ...) would otherwise re-read and re-parse azure-cli.yml
# from disk, even though it's the same file for the whole life of the
# daemon. get_cached_config() reads it once and reuses that Config - which
# is never mutated after construction, so sharing it read-only across the
# thread pool's worker threads (see PrActions/WorkItemActions.__init__,
# which only ever read from it) needs no lock of its own - and only
# re-parses when the file's mtime changes, so editing accounts/PATs via gO
# takes effect on the next request without restarting the daemon.
_config_cache_lock = threading.Lock()
_config_cache = {"path": None, "mtime": None, "config": None}


def config_problems(config):
    """Prints Config.problems() for `config` to stderr (headed by the
    config file's path so the user knows which file to edit) and returns
    True when there were any - the caller then returns 1. Tolerates a
    config object without problems() (tests pass stand-ins)."""
    fn = getattr(config, "problems", None)
    problems = fn() if callable(fn) else []
    if not problems:
        return False
    print("{0} is incomplete:".format(Config.source_label()), file=sys.stderr)
    for p in problems:
        print("  - " + p, file=sys.stderr)
    if Config.accounts_json():
        print("Fix the setup({accounts=...}) table in your Neovim config - see docs/configuration.md.", file=sys.stderr)
    else:
        print("Edit it (gO in the dashboard opens it) - see docs/configuration.md.", file=sys.stderr)
    return True


def get_cached_config():
    # setup({accounts=...}) wins over the file; its JSON text is the cache
    # key (a setup() re-run with different accounts changes the text).
    path = Config.accounts_json() or Config.path()
    try:
        mtime = None if Config.accounts_json() else os.path.getmtime(path)
    except OSError:
        mtime = None
    with _config_cache_lock:
        stale = (
            _config_cache["config"] is None
            or _config_cache["path"] != path
            or _config_cache["mtime"] != mtime
        )
        if stale:
            _config_cache["config"] = Config.from_config_file()
            _config_cache["path"] = path
            _config_cache["mtime"] = mtime
        return _config_cache["config"]


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
    this (see iso_epoch() in lua/azure-cli/dashboard.lua), so exact digit count doesn't
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
    PullRequestViewElement.Reviewers. Each entry also carries the
    reviewer's `id` (an IdentityRefWithVote id, the same GUID `myId` on the
    record itself is) - lua/azure-cli/editor.lua's "@" mention completion
    needs it: Azure DevOps only sends a notification for an "@<GUID>"
    mention, never a plain-text "@Display Name" one, so the editor
    translates a typed "@Display Name" to "@<id>" at submit time using
    this list.
    """
    out = []
    for r in pr.get("reviewers") or []:
        if not r or r.get("isContainer"):
            continue
        out.append({"name": r.get("displayName") or "", "id": r.get("id") or "", "vote": r.get("vote") or 0})
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


def _auth_hint(status):
    """What a 401/403/203 from Azure DevOps almost always means, in words
    the config file's owner can act on. dev.azure.com answers a bad PAT
    with a 203 + HTML sign-in page rather than a 401, so that one is
    named too."""
    if status in (401, 203):
        return ("the PAT was rejected - expired, revoked, or for a different organization? "
                "Create one with Code (read & write) and Work Items (read & write) scopes and put it in azure-cli.yml.")
    if status == 403:
        return ("the PAT is valid but lacks permission for this - check its scopes "
                "(Code read & write, Work Items read & write) and that it covers this organization.")
    return None


class AdoHttpError(Exception):
    def __init__(self, status, url, body=b""):
        self.status = status
        self.url = url
        self.body = body
        hint = _auth_hint(status)
        msg = "HTTP {0} for {1}".format(status, url)
        if hint:
            msg += " - " + hint
        super().__init__(msg)


class AdoTransportError(Exception):
    """The organization could not be reached at all (DNS, refused, TLS,
    a URL urllib can't parse) - the message says which and points at
    org_url, since that's nearly always the field to look at."""


def http_request(url, method="GET", data=None, pat=None, api_version="7.1", _retried=False, raw=False,
                  content_type="application/json"):
    """Performs one REST call against Azure DevOps, appending api-version
    to the query string. On-prem TFS instances that reject 7.1 answer with
    a 400; when that happens (and only then) this retries once against
    api-version=6.0, which every still-supported TFS/Azure DevOps Server
    release understands.

    api_version=None skips the query-string entirely - used for the one
    endpoint (ConnectionData, see PrActions.current_user_id) that some
    on-prem TFS instances reject *with* api-version on (400), matching
    review-pr.sh's bare curl call there. raw=True returns the undecoded
    response body instead of a parsed dict/list, so a PR action that just
    relays ADO's JSON straight to stdout (--threads/--iterations) can tell
    an empty body apart from a real "{}"/"[]" payload the way review-pr.sh's
    fetch_threads/fetch_iterations did (bash's `[[ -z "$body" ]]` check).

    content_type only matters when data is not None: the work-item REST API
    (unlike the PR one every other caller here talks to) requires
    "application/json-patch+json" for its JSON Patch bodies (create/set/
    link-pr/unlink-pr/state transitions) - wi-edit.sh/wi-state.sh sent that
    exact header, so WorkItemActions passes it explicitly for those calls;
    every other caller keeps the default.
    """
    if api_version is None:
        full_url = url
    else:
        sep = "&" if "?" in url else "?"
        full_url = "{0}{1}api-version={2}".format(url, sep, api_version)

    headers = {"Accept": "application/json"}
    if pat:
        token = base64.b64encode(":{0}".format(pat).encode("utf-8")).decode("ascii")
        headers["Authorization"] = "Basic {0}".format(token)

    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = content_type

    try:
        req = urllib.request.Request(full_url, data=body, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw_bytes = resp.read()
            status = getattr(resp, "status", None) or resp.getcode()
            ctype = (resp.headers.get("Content-Type") or "") if getattr(resp, "headers", None) else ""
    except urllib.error.HTTPError as e:
        if e.code == 400 and not _retried and api_version not in (None, "6.0"):
            return http_request(url, method=method, data=data, pat=pat, api_version="6.0", _retried=True, raw=raw,
                                 content_type=content_type)
        raise AdoHttpError(e.code, full_url, e.read()) from e
    except urllib.error.URLError as e:
        host = urllib.parse.urlsplit(full_url).netloc or full_url
        raise AdoTransportError("could not reach {0}: {1} - check org_url in azure-cli.yml and your network/proxy"
                                .format(host, getattr(e, "reason", e))) from e
    except ValueError as e:
        # "unknown url type" - an org_url with no scheme.
        raise AdoTransportError("{0} - org_url must be a full URL starting with https://".format(e)) from e

    # dev.azure.com answers a rejected PAT with "203 Non-Authoritative
    # Information" and an HTML sign-in page, not a 401; without this it
    # surfaced as "Expecting value: line 1 column 1" from json.loads.
    if status == 203 or (raw_bytes[:1] not in (b"{", b"[", b"") and "html" in ctype.lower()):
        raise AdoHttpError(203 if status == 203 else (status or 200), full_url, raw_bytes)

    if raw:
        return raw_bytes
    if not raw_bytes:
        return {}
    try:
        return json.loads(raw_bytes.decode("utf-8"))
    except ValueError as e:
        raise AdoTransportError("expected JSON from {0} but got {1} ({2}) - is org_url pointing at Azure DevOps?"
                                .format(full_url, ctype or "an unknown content type", e)) from e


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

    def __init__(self, config, env=None):
        self.config = config
        self.env = os.environ if env is None else env
        self.fetch = self._default_fetch
        self.fetch_bare = self._default_fetch_bare

    def _default_fetch(self, method, url, pat, data=None):
        return http_request(url, method=method, data=data, pat=pat)

    def _default_fetch_bare(self, url, pat):
        """GET with no api-version at all. ConnectionData on on-prem TFS
        answers 400 to any api-version (7.1 and the 6.0 retry alike) - the
        first live run against an on-prem TFS instance failed exactly there
        - so the identity lookup calls it bare, the way review-pr.sh always did and
        PrActions.current_user_id still does. Separate attribute so tests
        that swap `fetch` (whose fakes take method/url/pat/data) are
        untouched.
        """
        return http_request(url, method="GET", pat=pat, api_version=None)

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
        return next((a.token() for a in accounts if a.token()), None)

    # -- identity -----------------------------------------------------------

    def _whoami_for_org(self, org, pat):
        resp = self.fetch_bare(self._build_url(org, "_apis/connectionData"), pat) or {}
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

    def _hide_ancient_days(self):
        """AZVICLI_HIDE_ANCIENT_DAYS (lua/azure-cli/config.lua's
        setup({hide_ancient_days=...}), exported via provider_cmd()) instead
        of a hard-coded 30 - falls back to 30 when unset or not a positive
        integer, same as config.lua's own default.
        """
        raw = self.env.get("AZVICLI_HIDE_ANCIENT_DAYS")
        try:
            days = int(raw)
            if days > 0:
                return days
        except (TypeError, ValueError):
            pass
        return 30

    def _compute_state(self, pr, user_id, account, load_threads, source_branch_exists):
        """Mirrors AzureDevOpsPullRequestSource.ComputeState exactly,
        including the order the checks run in (a later check can only ever
        run once every earlier one has passed).
        """
        one_month_ago = datetime.now(timezone.utc) - timedelta(days=self._hide_ancient_days())

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
# PR actions - review-pr.sh ported to python
# ---------------------------------------------------------------------------
#
# One class replaces every REST helper review-pr.sh had (post_thread,
# fetch_threads, fetch_iterations, post_file_comment, post_pr_comment,
# post_inline, post_reply, set_thread_status, edit_comment, delete_comment,
# current_user_id, set_vote, complete_pr, set_auto_complete) plus its two
# branch-prefetch modes, so lua/azure-cli/review/init.lua and its review/*.lua/
# cache.lua callers can invoke this provider directly instead of
# shelling out to bash - same subcommand names, same argv shape, same
# stdout/stderr/exit-code contract, so the Lua-side parsing is unchanged.
# Every URL is api-version=6.0 (review-pr.sh never used 7.1) built by plain
# string concatenation, NOT urllib.parse.quote - matching the bash script's
# own unencoded "$ORG/$PROJECT/..." exactly, since the whole point of this
# port is byte-for-byte wire parity with what review-pr.sh sent.
#
# The PAT is always resolved from azure-cli.yml (resolve_account_pat below,
# reusing --print-pat's account-matching rule: org case-insensitively with a
# trailing slash ignored, then project) - never from an ambient
# AZURE_DEVOPS_EXT_PAT/ADO_PAT, matching review-pr.sh's own resolve-pat.sh/
# ensure_pat (which *did* also consult a PAT-table env var, as a fast path
# for the exe-launched case - this provider skips that fast path since it
# can just read the config directly, no process-spawn cost to avoid).

PR_ACTION_FLAGS = (
    "--threads", "--iterations", "--post", "--file-comment", "--pr-comment",
    "--reply", "--status", "--vote", "--complete", "--auto-complete",
    "--edit-comment", "--delete-comment",
)

# review-pr.sh's set_thread_status: most keywords pass through unchanged:
# ADO's own status enum is camelCase only for these two.
_THREAD_STATUS_MAP = {
    "active": "active", "fixed": "fixed", "closed": "closed", "pending": "pending",
    "wontfix": "wontFix", "bydesign": "byDesign",
}

_MERGE_STRATEGIES = ("squash", "noFastForward", "rebase", "rebaseMerge")
_VOTES = ("10", "5", "0", "-5", "-10")


def _is_uint(s):
    """True for a non-empty string of digits only - mirrors review-pr.sh's
    `-n "${x//[0-9]/}"` id-validity checks (thread/comment ids, line numbers).
    """
    return bool(s) and s.isdigit()


def _is_blank(s):
    """Mirrors bash's `[[ -z "${x// }" ]]` - empty once spaces are stripped,
    not just an empty string (a comment of all spaces is still "empty").
    """
    return not s or s.replace(" ", "") == ""


def _to_bool(s):
    return str(s).strip().lower() == "true"


def _clip(text, n=300):
    """Collapses whitespace (including newlines) and caps length, mirroring
    review-pr.sh's `tr '\\n' ' ' | tail -c 300` diagnostic truncation.
    """
    if isinstance(text, bytes):
        text = text.decode("utf-8", errors="replace")
    return " ".join(str(text).split())[:n]


def default_prefetch_dir():
    """AZVICLI_PREFETCH_DIR's default when unset: the platform cache
    directory's own azure-cli/ subfolder - %LOCALAPPDATA%\\azure-cli\\cache
    on Windows, $XDG_CACHE_HOME/azure-cli (default ~/.cache/azure-cli)
    elsewhere - rather than a .prefetch/ directory next to this script, so a
    packaged or read-only install (this repo cloned somewhere the running
    user can't write to) still has somewhere to write prefetch markers and
    the .userid cache. lua/azure-cli/config.lua's provider_cmd() sets
    AZVICLI_PREFETCH_DIR to Neovim's own stdpath("cache") .. "/azure-cli"
    for every provider call it builds, which is this same idea from the Lua
    side rather than a literal shared constant - the two independently land
    on "this platform's cache dir, azure-cli subfolder" instead of one
    hard-coding the other's resolution.
    """
    if sys.platform.startswith("win"):
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        return os.path.join(base, "azure-cli", "cache")
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "azure-cli")


def resolve_account_pat(config, org, project):
    """PAT lookup for a PR action: the first account whose org matches
    case-insensitively (trailing slash ignored) and, if given, whose project
    matches case-insensitively too (a blank project matches any account in
    that org) - mirrors --print-pat's own matching rule (cmd_print_pat
    above). Config only - ambient env vars are never consulted.
    """
    want_org = (org or "").rstrip("/").lower()
    want_proj = (project or "").lower()
    for account in config.accounts:
        if (account.org_url or "").rstrip("/").lower() != want_org:
            continue
        if want_proj and (account.project or "").lower() != want_proj:
            continue
        token = account.token()
        if token:
            return token
    return None


class PrActions:
    """One PR's REST actions, driven by the same AZVICLI_* environment
    variables review-pr.sh used to read. `fetch` is swappable (defaults to
    http_request above), the same pattern AzureDevOpsPullRequestSource uses,
    so tests can substitute a fake without touching the network.
    """

    def __init__(self, config, env=None):
        env = os.environ if env is None else env
        self.config = config
        self.org = env.get("AZVICLI_ORG") or ""
        self.project = env.get("AZVICLI_PROJECT") or ""
        self.repo = env.get("AZVICLI_REPO") or ""
        self.pr_id = env.get("AZVICLI_PR") or ""
        self.source = env.get("AZVICLI_SOURCE") or ""
        self.target = env.get("AZVICLI_TARGET") or ""
        self.repo_path = env.get("AZVICLI_REPO_PATH") or os.getcwd()
        self.prefetch_dir = env.get("AZVICLI_PREFETCH_DIR") or default_prefetch_dir()
        self.pat = None
        self.fetch = http_request

    # -- setup ----------------------------------------------------------

    def ensure_pat(self):
        """Resolves and caches the PAT for this PR's org/project. Prints
        review-pr.sh's own "No PAT available" diagnostic and returns False
        when nothing matches - callers exit 1 on that, same as the script.
        """
        pat = resolve_account_pat(self.config, self.org, self.project)
        if not pat:
            print("No PAT available: add 'pat:' to this account in azure-cli.yml.", file=sys.stderr)
            return False
        self.pat = pat
        return True

    def _url(self, path):
        # Deliberately unencoded (see this section's header comment).
        return "{0}/{1}/_apis/git/repositories/{2}/{3}".format(self.org, self.project, self.repo, path)

    def _pr_url(self, path=""):
        base = "{0}/{1}/_apis/git/repositories/{2}/pullRequests/{3}".format(
            self.org, self.project, self.repo, self.pr_id
        )
        return base + path if path else base

    # -- current_user_id -------------------------------------------------

    def current_user_id(self):
        """Resolves (and file-caches under PREFETCH_DIR/.userid, since it
        never changes) the authenticated user's id via the bare (no
        api-version - some on-prem TFS 400s on it) ConnectionData endpoint.
        Needed to cast a vote or set auto-complete, both keyed by reviewer
        id. Returns None on any failure - mirrors current_user_id's `|| return 1`.
        """
        cache_path = os.path.join(self.prefetch_dir, ".userid")
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                cached = f.read().strip()
            if cached:
                return cached
        except OSError:
            pass
        if not self.pat:
            return None
        try:
            resp = self.fetch("{0}/_apis/ConnectionData".format(self.org), pat=self.pat, api_version=None)
        except Exception:
            return None
        uid = ((resp or {}).get("authenticatedUser") or {}).get("id")
        if not uid:
            return None
        uid = str(uid)
        try:
            os.makedirs(self.prefetch_dir, exist_ok=True)
            # Write-to-temp-then-rename: under --serve, several requests can
            # resolve current_user_id() concurrently (a vote and an
            # auto-complete landing at the same time, say) before any of
            # them has written the cache yet - os.replace is atomic, so a
            # concurrent reader above either sees the old (missing) file or
            # a complete uid, never a torn/partial write.
            fd, tmp_path = tempfile.mkstemp(prefix=".userid.", dir=self.prefetch_dir)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(uid)
                os.replace(tmp_path, cache_path)
            except OSError:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
        except OSError:
            pass
        return uid

    # -- threads / iterations (raw passthrough for the nvim UI) ---------

    def fetch_threads(self):
        return self._fetch_raw_list(self._pr_url("/threads"), "fetch_threads")

    def fetch_iterations(self):
        return self._fetch_raw_list(self._pr_url("/iterations"), "fetch_iterations")

    def _fetch_raw_list(self, url, label):
        try:
            raw = self.fetch(url, pat=self.pat, api_version="6.0", raw=True)
        except AdoHttpError as e:
            print("{0}: HTTP {1} from {2}: {3}".format(label, e.status, e.url, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("{0}: transport error for {1}: {2}".format(label, url, e), file=sys.stderr)
            return 1
        if not raw:
            print("{0}: empty response body from {1}.".format(label, url), file=sys.stderr)
            return 1
        # Text-mode write (raw is always a JSON body, always valid UTF-8),
        # not the raw bytes .buffer.write used to get - under dispatch()/
        # --serve, sys.stdout is a per-thread capture (see
        # _install_streams below) that only its .write() goes through;
        # .buffer would bypass it and land on the daemon's real stdout,
        # corrupting the response stream. No behaviour change for the
        # one-shot CLI: the exact same bytes still reach the real terminal.
        sys.stdout.write(raw.decode("utf-8"))
        sys.stdout.flush()
        return 0

    # -- posting a new thread (--post / --file-comment / --pr-comment) --

    def post_thread(self, data):
        """POSTs `data` as a new thread. Shared by post_file_comment/
        post_pr_comment/post_inline below, mirroring post_thread() in
        review-pr.sh (which took a temp-file path; here it's just a dict).
        """
        try:
            self.fetch(self._pr_url("/threads"), method="POST", data=data, pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST post failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST post failed: {0}".format(e), file=sys.stderr)
            return 1
        print("Comment posted.")
        return 0

    def post_file_comment(self, path, text):
        if not path:
            print("No file selected.")
            return 1
        if _is_blank(text):
            print("Cancelled.")
            return 0
        data = {
            "comments": [{"parentCommentId": 0, "content": text, "commentType": 1}],
            "status": 1,
            "threadContext": {"filePath": "/" + path},
        }
        return self.post_thread(data)

    def post_pr_comment(self, text):
        if _is_blank(text):
            print("Cancelled.")
            return 0
        data = {
            "comments": [{"parentCommentId": 0, "content": text, "commentType": 1}],
            "status": 1,
        }
        return self.post_thread(data)

    def _git_show_line(self, blob, lineno):
        """The text of `blob`'s `lineno`-th line (1-based), or "" - used to
        measure a single commented line's length for the offset anchor
        below, mirroring `git show "$blob" | sed -n "${lineno}p"`.
        """
        try:
            proc = subprocess.run(
                ["git", "show", blob], cwd=self.repo_path,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30,
            )
        except (OSError, subprocess.SubprocessError):
            return ""
        if proc.returncode != 0:
            return ""
        lines = proc.stdout.decode("utf-8", errors="replace").split("\n")
        idx = lineno - 1
        return lines[idx] if 0 <= idx < len(lines) else ""

    def post_inline(self, path, side, lineno_s, text, endline_s=""):
        """Builds and posts a single-line or (start, end] range inline
        comment - mirrors review-pr.sh's post_inline exactly, including the
        999999 end-offset sentinel for a range and the git-show-measured
        end-of-line offset for a single line.
        """
        if not path or not _is_uint(lineno_s) or lineno_s == "0":
            print("Invalid line.")
            return 1
        if side not in ("R", "L"):
            print("Invalid side.")
            return 1
        lineno = int(lineno_s)
        endline = int(endline_s) if _is_uint(endline_s) else None
        file_path = "/" + path
        start_key = "rightFileStart" if side == "R" else "leftFileStart"
        end_key = "rightFileEnd" if side == "R" else "leftFileEnd"

        if endline is not None and endline > lineno:
            anchor = {start_key: {"line": lineno, "offset": 1}, end_key: {"line": endline, "offset": 999999}}
        else:
            blob = "origin/{0}:{1}".format(self.source if side == "R" else self.target, path)
            length = len(self._git_show_line(blob, lineno))
            anchor = {start_key: {"line": lineno, "offset": 1}, end_key: {"line": lineno, "offset": length + 1}}

        thread_context = {"filePath": file_path}
        thread_context.update(anchor)
        data = {
            "comments": [{"parentCommentId": 0, "content": text, "commentType": 1}],
            "status": 1,
            "threadContext": thread_context,
        }
        return self.post_thread(data)

    # -- reply / status / edit / delete on an existing thread/comment ---

    def post_reply(self, thread_id, text):
        if not _is_uint(thread_id):
            print("Invalid thread id.")
            return 1
        if _is_blank(text):
            print("Empty reply.")
            return 1
        data = {"parentCommentId": 1, "content": text, "commentType": 1}
        try:
            self.fetch(self._pr_url("/threads/{0}/comments".format(thread_id)),
                       method="POST", data=data, pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST reply failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST reply failed: {0}".format(e), file=sys.stderr)
            return 1
        print("Reply posted.")
        return 0

    def set_thread_status(self, thread_id, status):
        if not _is_uint(thread_id):
            print("Invalid thread id.")
            return 1
        mapped = _THREAD_STATUS_MAP.get(status)
        if mapped is None:
            print("Invalid status: '{0}'".format(status))
            return 1
        try:
            self.fetch(self._pr_url("/threads/{0}".format(thread_id)),
                       method="PATCH", data={"status": mapped}, pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST status update failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST status update failed: {0}".format(e), file=sys.stderr)
            return 1
        print("Thread {0} set to {1}.".format(thread_id, mapped))
        return 0

    def edit_comment(self, thread_id, comment_id, text):
        if not _is_uint(thread_id):
            print("Invalid thread id.")
            return 1
        if not _is_uint(comment_id):
            print("Invalid comment id.")
            return 1
        if _is_blank(text):
            print("Empty comment.")
            return 1
        try:
            self.fetch(self._pr_url("/threads/{0}/comments/{1}".format(thread_id, comment_id)),
                       method="PATCH", data={"content": text}, pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST edit-comment failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST edit-comment failed: {0}".format(e), file=sys.stderr)
            return 1
        print("Comment {0} (thread {1}) updated.".format(comment_id, thread_id))
        return 0

    def delete_comment(self, thread_id, comment_id):
        if not _is_uint(thread_id):
            print("Invalid thread id.")
            return 1
        if not _is_uint(comment_id):
            print("Invalid comment id.")
            return 1
        try:
            self.fetch(self._pr_url("/threads/{0}/comments/{1}".format(thread_id, comment_id)),
                       method="DELETE", pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST delete-comment failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST delete-comment failed: {0}".format(e), file=sys.stderr)
            return 1
        print("Comment {0} (thread {1}) deleted.".format(comment_id, thread_id))
        return 0

    # -- vote / complete / auto-complete ---------------------------------

    def set_vote(self, vote):
        if vote not in _VOTES:
            print("Invalid vote: '{0}'".format(vote))
            return 1
        uid = self.current_user_id()
        if not uid:
            print("Could not resolve your user id (connectionData); cannot vote.")
            return 1
        try:
            self.fetch(self._pr_url("/reviewers/{0}".format(uid)),
                       method="PUT", data={"vote": int(vote)}, pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST vote failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST vote failed: {0}".format(e), file=sys.stderr)
            return 1
        print("Vote set to {0}.".format(vote))
        return 0

    def complete_pr(self, strategy, del_branch="true", transition="true"):
        if strategy not in _MERGE_STRATEGIES:
            print("Invalid merge strategy: '{0}'".format(strategy))
            return 1
        try:
            pr = self.fetch(self._pr_url(), pat=self.pat, api_version="6.0")
        except Exception:
            print("Could not fetch PR to determine merge commit.")
            return 1
        commit = ((pr or {}).get("lastMergeSourceCommit") or {}).get("commitId")
        if not commit:
            print("Could not resolve lastMergeSourceCommit; PR may not be mergeable.")
            return 1
        data = {
            "status": "completed",
            "lastMergeSourceCommit": {"commitId": commit},
            "completionOptions": {
                "mergeStrategy": strategy,
                "deleteSourceBranch": _to_bool(del_branch),
                "transitionWorkItems": _to_bool(transition),
            },
        }
        try:
            self.fetch(self._pr_url(), method="PATCH", data=data, pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST complete failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST complete failed: {0}".format(e), file=sys.stderr)
            return 1
        print("PR #{0} completed ({1}).".format(self.pr_id, strategy))
        return 0

    def set_auto_complete(self, mode, strategy=None, del_branch="true", transition="true"):
        if mode == "off":
            data = {"autoCompleteSetBy": {"id": "00000000-0000-0000-0000-000000000000"}}
            try:
                self.fetch(self._pr_url(), method="PATCH", data=data, pat=self.pat, api_version="6.0")
            except AdoHttpError as e:
                print("REST auto-complete failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
                return 1
            except Exception as e:
                print("REST auto-complete failed: {0}".format(e), file=sys.stderr)
                return 1
            print("Auto-complete disabled for PR #{0}.".format(self.pr_id))
            return 0

        if strategy not in _MERGE_STRATEGIES:
            print("Invalid merge strategy: '{0}'".format(strategy))
            return 1
        uid = self.current_user_id()
        if not uid:
            print("Could not resolve your user id (connectionData); cannot set auto-complete.")
            return 1
        data = {
            "autoCompleteSetBy": {"id": uid},
            "completionOptions": {
                "mergeStrategy": strategy,
                "deleteSourceBranch": _to_bool(del_branch),
                "transitionWorkItems": _to_bool(transition),
            },
        }
        try:
            self.fetch(self._pr_url(), method="PATCH", data=data, pat=self.pat, api_version="6.0")
        except AdoHttpError as e:
            print("REST auto-complete failed: HTTP {0}: {1}".format(e.status, _clip(e.body)), file=sys.stderr)
            return 1
        except Exception as e:
            print("REST auto-complete failed: {0}".format(e), file=sys.stderr)
            return 1
        print("Auto-complete enabled for PR #{0} ({1}).".format(self.pr_id, strategy))
        return 0


def cmd_pr_action(flag, rest, env=None):
    """Dispatches one of PR_ACTION_FLAGS: reads the required AZVICLI_* env
    vars (same :? -> exit-1 semantics review-pr.sh's `${AZVICLI_ORG:?...}`
    had), resolves the PAT (every PR action needs the REST API, same as
    review-pr.sh's `case "${1:-}" in --*) ensure_pat || exit 1 ;; esac`),
    and runs the matching PrActions method. `env` defaults to os.environ for
    the one-shot CLI; dispatch() (--serve) always passes one explicitly -
    the per-request AZVICLI_* overrides merged over the daemon's own
    environment - since os.environ is process-wide and requests run
    concurrently on the daemon's thread pool.
    """
    env = os.environ if env is None else env
    for name in ("AZVICLI_ORG", "AZVICLI_PROJECT", "AZVICLI_REPO", "AZVICLI_PR"):
        if not env.get(name):
            print("{0} not set".format(name), file=sys.stderr)
            return 1

    if not Config.validate_exists():
        return 1
    config = get_cached_config()
    if config_problems(config):
        return 1
    actions = PrActions(config, env)
    if not actions.ensure_pat():
        return 1

    def arg(i, default=""):
        return rest[i] if i < len(rest) else default

    if flag == "--file-comment":
        return actions.post_file_comment(arg(0), arg(1))
    if flag == "--pr-comment":
        return actions.post_pr_comment(arg(0))
    if flag == "--post":
        return actions.post_inline(arg(0), arg(1), arg(2), arg(3), arg(4))
    if flag == "--threads":
        return actions.fetch_threads()
    if flag == "--iterations":
        return actions.fetch_iterations()
    if flag == "--reply":
        return actions.post_reply(arg(0), arg(1))
    if flag == "--status":
        return actions.set_thread_status(arg(0), arg(1))
    if flag == "--edit-comment":
        return actions.edit_comment(arg(0), arg(1), arg(2))
    if flag == "--delete-comment":
        return actions.delete_comment(arg(0), arg(1))
    if flag == "--vote":
        return actions.set_vote(arg(0))
    if flag == "--complete":
        return actions.complete_pr(arg(0), arg(1, "true"), arg(2, "true"))
    if flag == "--auto-complete":
        return actions.set_auto_complete(arg(0), arg(1) or None, arg(2, "true"), arg(3, "true"))

    print("Unknown PR action: {0}".format(flag), file=sys.stderr)  # unreachable via PR_ACTION_FLAGS
    return 1


# ---------------------------------------------------------------------------
# Work items - wi-list.sh/wi-detail.sh/wi-state.sh/wi-edit.sh ported to python
# ---------------------------------------------------------------------------
#
# One class (WorkItemActions) replaces every REST helper the four wi-*.sh
# scripts had, plus resolve-pat.sh's PAT lookup (now resolve_account_pat,
# reused from the PR-action port above - the wi-*.sh scripts' own
# resolve_pat_into always ended up reading the same azure-cli.yml, just
# through a PAT-table fast path or a --print-pat process spawn this
# provider doesn't need since it can read the config directly), so
# workitems/dashboard.lua/view.lua can run this provider directly instead of shelling
# out to bash. Same subcommand names as the old scripts' own (list/detail/
# state/edit collapse into --wi-list/--wi-detail/--wi-state/--wi-edit), same
# stdout NDJSON/JSON/one-per-line shapes and exit codes, so the Lua-side
# parsing is unchanged. Every URL is api-version=7.1 (matching the scripts),
# through the shared http_request() above rather than curl+`python -`.
#
# Collection/project/team/assignee/types come from the selected account's
# work_items: block in azure-cli.yml (see AccountConfig.work_items and
# _wi_select_account below) - there are no hard-coded personal defaults any
# more. AZVICLI_WI_COLLECTION/AZVICLI_WI_PROJECT/AZVICLI_WI_TEAM/
# AZVICLI_WI_ASSIGNEE/AZVICLI_WI_TYPES remain as overrides on top of that
# config, same env vars the old wi-*.sh scripts read; AZVICLI_WI_ACCOUNT
# additionally picks which account's work_items: block to use when more
# than one has one (see _wi_select_account).

# types: default when a work_items: block doesn't set one - the one piece
# of this that's still a plain constant, since it isn't personal.
WI_TYPES_DEFAULT = "User Story,Bug"

WI_ACTION_FLAGS = ("--wi-list", "--wi-detail", "--wi-state", "--wi-edit")


def _wi_select_account(config, env):
    """Picks the account whose work_items: block (org_url/project_name for
    collection/project, team/assignee/types for the rest) backs the
    work-item screens: the first account with a work_items: block, unless
    AZVICLI_WI_ACCOUNT names another account by its project_name (matched
    whether or not that account has a work_items: block of its own, so
    AZVICLI_WI_TEAM etc. can still supply the rest as pure env overrides).
    Returns None when nothing matches either way.
    """
    want = env.get("AZVICLI_WI_ACCOUNT")
    if want:
        for a in config.accounts:
            if (a.project or "") == want:
                return a
        return None
    for a in config.accounts:
        if a.work_items:
            return a
    return None


def _wi_types_to_str(v):
    """Normalizes a types: value (a YAML list, or a plain comma-separated
    scalar) to the comma-separated string the rest of WorkItemActions (the
    WIQL IN(...) clause) already works with.
    """
    if isinstance(v, list):
        return ",".join(str(t).strip() for t in v if str(t).strip())
    return v


def _wi_states_list(v):
    """Normalizes a work_items.states: value (a YAML list, or a plain
    comma-separated scalar, same two shapes types: accepts) to an ordered
    list of state names, or None when absent/empty - None is what tells the
    Lua side (workitems/dashboard.lua's states.lua) to fall back to its own
    hard-coded rank/colour tables instead of the generic position-based
    scheme, so an install that never sets work_items.states: renders exactly
    as it always has (see README's Work items section).
    """
    if isinstance(v, list):
        out = [str(s).strip() for s in v if str(s).strip()]
        return out or None
    if isinstance(v, str) and v.strip():
        out = [s.strip() for s in v.split(",") if s.strip()]
        return out or None
    return None

WI_API = "7.1"
# The discussion-comments endpoint is still preview on every ADO/TFS version
# that has it at all - matches wi-detail.sh's/wi-edit.sh's own hardcoded
# "api-version=7.1-preview.4" for GET/POST .../workItems/{id}/comments.
WI_COMMENTS_API = "7.1-preview.4"

_HTML_BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "ul", "ol", "table"}


class _HtmlTextParser(HTMLParser):
    """Flattens a work-item HTML field (description/acceptance criteria/repro
    steps) or a discussion comment's HTML body to plain text - mirrors
    wi-detail.sh's _Text/html_to_text exactly, including its block-tag
    newline insertion, so description/comment text renders cleanly in a
    scratch buffer the same way it always has.
    """

    def __init__(self):
        super().__init__()
        self.out = []

    def handle_starttag(self, tag, attrs):
        if tag == "li":
            self.out.append("\n- ")
        elif tag in _HTML_BLOCK_TAGS:
            self.out.append("\n")

    def handle_endtag(self, tag):
        if tag in _HTML_BLOCK_TAGS:
            self.out.append("\n")

    def handle_data(self, data):
        self.out.append(data)


def html_to_text(s):
    if not s:
        return ""
    p = _HtmlTextParser()
    p.feed(str(s))
    txt = "".join(p.out)
    txt = re.sub(r"[ \t]+", " ", txt)
    txt = re.sub(r"\n[ \t]+", "\n", txt)
    txt = re.sub(r"\n{3,}", "\n\n", txt)
    return txt.strip()


def _wi_assigned_str(v):
    if isinstance(v, dict):
        return v.get("displayName", "") or v.get("uniqueName", "") or ""
    return "" if v is None else str(v)


def _wi_sql_esc(s):
    return s.replace("'", "''")


def _wi_parse_iso(s):
    try:
        return datetime.fromisoformat((s or "").replace("Z", "+00:00"))
    except Exception:
        return None


def _wi_human(iso):
    """wi-list.sh's own compact "N ago" formatter - deliberately not the
    PR-side humanize() above: different bucket boundaries and text
    ("5m ago"/"3h ago"/"2d ago"/"1mo ago" vs. "5 minutes ago"), matching
    wi-list.sh's human() exactly rather than unifying the two.
    """
    try:
        dt = datetime.fromisoformat((iso or "").replace("Z", "+00:00"))
    except Exception:
        return ""
    now = datetime.now(timezone.utc)
    secs = (now - dt).total_seconds()
    if secs < 60:
        return "just now"
    if secs < 3600:
        return "{0}m ago".format(int(secs // 60))
    if secs < 86400:
        return "{0}h ago".format(int(secs // 3600))
    d = int(secs // 86400)
    return "{0}d ago".format(d) if d < 30 else "{0}mo ago".format(d // 30)


def _wi_sprint_name(it):
    if not it:
        return ""
    return it.get("name") or (it.get("path", "").split("\\")[-1])


def _wi_resolve_current_sprint(iters):
    for it in iters:
        if (it.get("attributes") or {}).get("timeFrame") == "current":
            return it
    now = datetime.now(timezone.utc)
    for it in iters:
        a = it.get("attributes") or {}
        st, fn = _wi_parse_iso(a.get("startDate")), _wi_parse_iso(a.get("finishDate"))
        if st and fn and st <= now <= fn:
            return it
    return None


def _wi_resolve_next_sprint(iters, cur):
    dated = [(_wi_parse_iso((it.get("attributes") or {}).get("startDate")), it) for it in iters]
    dated = [(d, it) for (d, it) in dated if d is not None]
    dated.sort(key=lambda x: x[0])
    for i, (_, it) in enumerate(dated):
        if it.get("path") == cur.get("path"):
            return dated[i + 1][1] if i + 1 < len(dated) else None
    fut = [it for it in iters if (it.get("attributes") or {}).get("timeFrame") == "future"]
    fut.sort(key=lambda it: (
        _wi_parse_iso((it.get("attributes") or {}).get("startDate")) is None,
        _wi_parse_iso((it.get("attributes") or {}).get("startDate")) or datetime.max.replace(tzinfo=timezone.utc),
    ))
    return fut[0] if fut else None


def _wi_list_record(wi, collection, project):
    """One --wi-list NDJSON line - mirrors wi-list.sh's per-item `rec` dict."""
    f = wi.get("fields") or {}
    parent = f.get("System.Parent")
    if not isinstance(parent, int):
        for rel in (wi.get("relations") or []):
            if rel.get("rel") == "System.LinkTypes.Hierarchy-Reverse":
                m = re.search(r"/workItems/(\d+)$", rel.get("url", ""))
                if m:
                    parent = int(m.group(1))
                    break
    changed = str(f.get("System.ChangedDate", ""))
    return {
        "id": wi.get("id"),
        "type": str(f.get("System.WorkItemType", "")),
        "state": str(f.get("System.State", "")),
        "title": re.sub(r"\s+", " ", str(f.get("System.Title", "")).strip()),
        "assignedTo": _wi_assigned_str(f.get("System.AssignedTo", "")),
        "priority": f.get("Microsoft.VSTS.Common.Priority"),
        "tags": str(f.get("System.Tags", "") or ""),
        "parentId": parent if isinstance(parent, int) else None,
        "changedIso": changed,
        "changedHuman": _wi_human(changed),
        "url": "{0}/{1}/_workitems/edit/{2}".format(collection, project, wi.get("id")),
    }


def _wi_summary(wi):
    """A parent/child summary for --wi-detail - mirrors wi-detail.sh's summary()."""
    f = wi.get("fields") or {}
    return {
        "id": wi.get("id"),
        "type": str(f.get("System.WorkItemType", "")),
        "state": str(f.get("System.State", "")),
        "title": re.sub(r"\s+", " ", str(f.get("System.Title", "")).strip()),
        "assignedTo": _wi_assigned_str(f.get("System.AssignedTo", "")),
    }


def _wi_pr_ids_from_relations(relations):
    """ArtifactLink relations to a pull request look like
    vstfs:///Git/PullRequestId/{projectGuid}%2F{repoGuid}%2F{prId} (the last
    segment after the final %2F/%2f or plain "/" is the PR id) - mirrors
    wi-detail.sh's pr_ids_from_relations() exactly.
    """
    out = []
    for rel in (relations or []):
        if rel.get("rel") != "ArtifactLink":
            continue
        url = rel.get("url", "") or ""
        if not url.startswith("vstfs:///Git/PullRequestId/"):
            continue
        m = re.search(r"(?:%2[Ff]|/)([0-9]+)$", url)
        if m:
            out.append({"id": int(m.group(1))})
    return out


class WorkItemActions:
    """Work-item REST actions for the dashboard/detail view, driven by the
    same AZVICLI_WI_* environment variables the wi-*.sh scripts used to read
    (see the defaults above). `fetch` is swappable (defaults to http_request), the
    same pattern PrActions/AzureDevOpsPullRequestSource use, so tests can
    substitute a fake without touching the network.
    """

    _FIELD_MAP = {
        "title": ("System.Title", str),
        "assignedTo": ("System.AssignedTo", str),
        "priority": ("Microsoft.VSTS.Common.Priority", int),
        "iteration": ("System.IterationPath", str),
        "tags": ("System.Tags", str),
        "description": ("System.Description", str),
    }

    def __init__(self, config, env=None):
        env = os.environ if env is None else env
        self.config = config
        account = _wi_select_account(config, env)
        wi = (account.work_items if account else None) or {}
        self.collection = env.get("AZVICLI_WI_COLLECTION") or (account.org_url if account else None) or ""
        self.project = env.get("AZVICLI_WI_PROJECT") or (account.project if account else None) or ""
        self.team = env.get("AZVICLI_WI_TEAM") or wi.get("team") or ""
        # assignee: an env override or work_items: assignee: wins outright;
        # otherwise it's resolved lazily to the authenticated user's own
        # display name by the `assignee` property below, since that needs
        # self.pat - not known until ensure_pat() runs after __init__.
        self._assignee_override = env.get("AZVICLI_WI_ASSIGNEE") or wi.get("assignee") or None
        self._assignee_cache = None
        self.types = _wi_types_to_str(env.get("AZVICLI_WI_TYPES") or wi.get("types") or WI_TYPES_DEFAULT)
        # work_items.states: an ordered list (rank = position, first = most
        # actionable) the dashboard sorts/colours by - see states.lua and
        # cmd_wi_list/_wi_list_sprints below, which carry this to the Lua
        # side on the _meta/_sprints line. None (absent) means "the current
        # hard-coded list" - states.lua's own fallback, not resolved here,
        # so this stays None rather than substituting a default.
        self.states = _wi_states_list(wi.get("states"))
        # work_items.sprint_scope: "parent" (default - today's behaviour:
        # tabs are the current sprint's siblings) or "all" (every iteration
        # the team has, ordered by start date). See _wi_list_sprints below.
        self.sprint_scope = str(wi.get("sprint_scope") or "parent").strip().lower()
        self.validate_only = env.get("AZVICLI_WI_VALIDATE_ONLY") == "1"
        self.pat = None
        self.fetch = http_request
        self.fetch_bare = self._default_fetch_bare

    def _default_fetch_bare(self, url, pat):
        """GET with no api-version at all - some on-prem TFS 400s on a
        versioned ConnectionData request. The same bare call
        AzureDevOpsPullRequestSource._whoami_for_org uses for the PR list's
        own identity lookup; a separate attribute (like `fetch`) so tests
        can substitute a fake without touching the network.
        """
        return http_request(url, method="GET", pat=pat, api_version=None)

    # -- setup ------------------------------------------------------------

    def ensure_configured(self):
        """Confirms the work-item screens are actually enabled before any
        REST call runs: `team:` (from the selected account's work_items:
        block, or AZVICLI_WI_TEAM) is what switches them on - with no
        personal defaults left in this file any more, an unconfigured
        install must fail with a message that says where to fix it rather
        than quietly querying nothing. Same print-and-return-False shape as
        ensure_pat() below, so cmd_wi_action can exit 1 on either.
        """
        if not self.team:
            print(
                "No account has a work_items: block in azure-cli.yml; add team: … "
                "under the account to enable work items",
                file=sys.stderr,
            )
            return False
        return True

    def ensure_pat(self):
        """Resolves and caches the PAT for the collection/project this
        instance resolved (config work_items: account, or the
        AZVICLI_WI_COLLECTION/AZVICLI_WI_PROJECT overrides). Prints the
        wi-*.sh scripts' own "no PAT available" diagnostic and returns
        False when nothing matches - callers exit 1 on that, same as the
        scripts.
        """
        pat = resolve_account_pat(self.config, self.collection, self.project)
        if not pat:
            print("ERROR: no PAT available - add 'pat:' to this account in azure-cli.yml", file=sys.stderr)
            return False
        self.pat = pat
        return True

    # -- assignee -----------------------------------------------------------

    @property
    def assignee(self):
        """The System.AssignedTo value the WIQL/create/edit calls compare
        against or set: AZVICLI_WI_ASSIGNEE, else work_items: assignee:
        from config, else the authenticated user's own display name - the
        same identity lookup the PR list uses
        (AzureDevOpsPullRequestSource._whoami_for_org: a bare, no-api-
        version GET on connectionData), cached on this instance since a
        single dispatch()/--serve request never needs it twice.
        """
        if self._assignee_override:
            return self._assignee_override
        if self._assignee_cache is None:
            self._assignee_cache = self._whoami_display_name()
        return self._assignee_cache

    def _whoami_display_name(self):
        """Bare connectionData GET for the authenticated user's display
        name - returns "" on any failure (no PAT yet, network error,
        unexpected shape) so a WIQL still runs (matching nothing, rather
        than crashing wi-list) instead of raising out of a property.
        """
        if not self.pat:
            return ""
        try:
            url = "{0}/_apis/connectionData".format((self.collection or "").rstrip("/"))
            resp = self.fetch_bare(url, self.pat) or {}
        except Exception:
            return ""
        user = resp.get("authenticatedUser") or {}
        return user.get("customDisplayName") or user.get("providerDisplayName") or ""

    # -- shared REST helpers ------------------------------------------------

    def _get(self, url, api_version=WI_API):
        return self.fetch(url, method="GET", pat=self.pat, api_version=api_version)

    def _post(self, url, data, api_version=WI_API, content_type="application/json"):
        return self.fetch(url, method="POST", data=data, pat=self.pat, api_version=api_version,
                           content_type=content_type)

    def _patch(self, url, data, api_version=WI_API, content_type="application/json"):
        return self.fetch(url, method="PATCH", data=data, pat=self.pat, api_version=api_version,
                           content_type=content_type)

    @staticmethod
    def _json_message(e, limit):
        """The ADO error body's "message" field when it parses as a JSON
        object with one, else the raw body capped at `limit` - mirrors
        wi-state.sh's/wi-edit.sh's own `json.loads(detail).get("message") or
        detail[:limit]` (with the same broad except-and-fall-back).
        """
        text = e.body.decode("utf-8", errors="replace") if isinstance(e.body, bytes) else str(e.body or "")
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict) and parsed.get("message"):
                return parsed.get("message")
        except Exception:
            pass
        return text[:limit]

    def _list_style_error(self, e, method):
        """wi-list.sh's/wi-detail.sh's api_request() error format: raw body,
        with the URL, capped at 400 chars.
        """
        body = e.body.decode("utf-8", errors="replace") if isinstance(e.body, bytes) else str(e.body or "")
        print("ERROR: HTTP {0} {1} {2}\n{3}".format(e.status, method, e.url, body[:400]), file=sys.stderr)
        return 2

    def _state_style_error(self, e, method):
        """wi-state.sh's request() error format: JSON "message" (or raw body)
        capped at 300 chars, no URL.
        """
        print("ERROR: HTTP {0} {1}: {2}".format(e.status, method, self._json_message(e, 300)), file=sys.stderr)
        return 2

    def _edit_style_error(self, e, method):
        """wi-edit.sh's request() error format: JSON "message" (or raw body)
        capped at 400 chars, with the URL.
        """
        print("ERROR: HTTP {0} {1} {2}\n{3}".format(e.status, method, e.url, self._json_message(e, 400)),
              file=sys.stderr)
        return 2

    # -- list (wi-list.sh) --------------------------------------------------

    def _get_iterations(self):
        team_q = urllib.parse.quote(self.team, safe="")
        url = "{0}/{1}/{2}/_apis/work/teamsettings/iterations?timeframe=all".format(
            self.collection, self.project, team_q)
        return self._get(url)

    def _get_areas(self):
        team_q = urllib.parse.quote(self.team, safe="")
        url = "{0}/{1}/{2}/_apis/work/teamsettings/teamfieldvalues".format(self.collection, self.project, team_q)
        return self._get(url)

    def cmd_wi_list(self, select, item_path=""):
        if select not in ("current", "next", "sprints", "items", "members"):
            print("ERROR: selector must be current|next|sprints|items|members, got '{0}'".format(select),
                  file=sys.stderr)
            return 1
        if select == "items" and not item_path:
            print("ERROR: 'items' needs an iteration path", file=sys.stderr)
            return 1

        if select == "sprints":
            return self._wi_list_sprints()
        if select == "members":
            return self._wi_list_members()

        if select == "items":
            sprint_path = item_path
        else:
            try:
                iters = ((self._get_iterations() or {}).get("value")) or []
            except AdoHttpError as e:
                return self._list_style_error(e, "GET")
            cur = _wi_resolve_current_sprint(iters)
            if cur is None:
                print("ERROR: could not determine current sprint", file=sys.stderr)
                return 1
            nxt = _wi_resolve_next_sprint(iters, cur)
            if select == "next":
                if nxt is None:
                    print("ERROR: could not determine next sprint", file=sys.stderr)
                    return 1
                target = nxt
                na = nxt.get("attributes") or {}
                meta = {"_meta": True, "timeframe": "next",
                        "sprintName": _wi_sprint_name(nxt), "sprintPath": nxt.get("path", ""),
                        "sprintStart": na.get("startDate", "") or "", "sprintFinish": na.get("finishDate", "") or ""}
            else:
                target = cur
                ca = cur.get("attributes") or {}
                na = (nxt.get("attributes") or {}) if nxt else {}
                meta = {"_meta": True, "timeframe": "current",
                        "sprintName": _wi_sprint_name(cur), "sprintPath": cur.get("path", ""),
                        "sprintStart": ca.get("startDate", "") or "", "sprintFinish": ca.get("finishDate", "") or "",
                        "nextSprintName": _wi_sprint_name(nxt), "nextSprintPath": (nxt.get("path", "") if nxt else ""),
                        "nextStart": na.get("startDate", "") or "", "nextFinish": na.get("finishDate", "") or ""}
            if self.states:
                # states.lua builds its rank/highlight tables from this list;
                # omitted entirely (not an empty list) when work_items.states:
                # isn't configured, so the Lua side falls back to its own
                # hard-coded tables (see states.lua's own header comment).
                meta["states"] = self.states
            sprint_path = target.get("path", "")
            # Emit the sprint metadata first so the dashboard can label its
            # tab even when the sprint has zero assigned work items.
            print(json.dumps(meta, ensure_ascii=False))

        try:
            areas_resp = self._get_areas()
        except AdoHttpError as e:
            return self._list_style_error(e, "GET")
        areas = [v.get("value") for v in ((areas_resp or {}).get("values") or []) if v.get("value")]
        if not areas:
            print("ERROR: no team areas returned", file=sys.stderr)
            return 1

        area_clause = " OR ".join("[System.AreaPath] UNDER '{0}'".format(_wi_sql_esc(a)) for a in areas)
        type_list = [t.strip() for t in self.types.split(",") if t.strip()]
        type_clause = ""
        if type_list:
            type_clause = " AND [System.WorkItemType] IN (" + ",".join(
                "'{0}'".format(_wi_sql_esc(t)) for t in type_list) + ")"

        wiql = (
            "SELECT [System.Id] FROM WorkItems\n"
            "WHERE [System.TeamProject] = '{0}'\n"
            "  AND [System.IterationPath] = '{1}'\n"
            "  AND ( {2} )\n"
            "  {3}\n"
            "  AND [System.AssignedTo] = '{4}'\n"
            "ORDER BY [System.Id]"
        ).format(_wi_sql_esc(self.project), _wi_sql_esc(sprint_path), area_clause, type_clause,
                 _wi_sql_esc(self.assignee))

        wiql_url = "{0}/{1}/_apis/wit/wiql".format(self.collection, self.project)
        try:
            resp = self._post(wiql_url, {"query": wiql})
        except AdoHttpError as e:
            return self._list_style_error(e, "POST")
        ids = [w["id"] for w in ((resp or {}).get("workItems") or [])]
        if not ids:
            return 0

        batch_url = "{0}/_apis/wit/workitemsbatch".format(self.collection)
        for i in range(0, len(ids), 200):
            chunk = ids[i:i + 200]
            try:
                r = self._post(batch_url, {"ids": chunk, "$expand": "relations"})
            except AdoHttpError as e:
                return self._list_style_error(e, "POST")
            for wi in ((r or {}).get("value") or []):
                print(json.dumps(_wi_list_record(wi, self.collection, self.project), ensure_ascii=False))
        return 0

    def _wi_list_sprints(self):
        try:
            iters = ((self._get_iterations() or {}).get("value")) or []
        except AdoHttpError as e:
            return self._list_style_error(e, "GET")
        cur = _wi_resolve_current_sprint(iters)
        if cur is None:
            print("ERROR: could not determine current sprint", file=sys.stderr)
            return 1
        cur_path = cur.get("path", "")

        # work_items.sprint_scope: "parent" (default) groups by the current
        # sprint's parent node, exactly as before - siblings under the same
        # quarter/release. "all" is every iteration the team has at all,
        # regardless of parent, ordered by start date below like the
        # "parent" group always was; there's no single parent node to label
        # the tab bar with in that case, so `quarter` comes back blank - the
        # Lua tab bar (build_tabbar) already windows around the active tab
        # when there are more than fit, so a long "all" list is handled the
        # same way a wide "parent" group already is.
        if self.sprint_scope == "all":
            quarter = ""
            group = list(iters)
        else:
            quarter = cur_path.rsplit("\\", 1)[0] if "\\" in cur_path else cur_path
            group = [it for it in iters
                     if "\\" in it.get("path", "") and it.get("path", "").rsplit("\\", 1)[0] == quarter]
        group.sort(key=lambda it: (_wi_parse_iso((it.get("attributes") or {}).get("startDate"))
                                    or datetime.max.replace(tzinfo=timezone.utc)))
        out_sprints, current_index = [], 0
        for i, it in enumerate(group):
            a = it.get("attributes") or {}
            pth = it.get("path", "")
            is_cur = (pth == cur_path)
            if is_cur:
                current_index = i + 1
            out_sprints.append({
                "name": _wi_sprint_name(it),
                "label": pth.rsplit("\\", 1)[-1] if "\\" in pth else pth,
                "path": pth,
                "start": a.get("startDate", "") or "",
                "finish": a.get("finishDate", "") or "",
                "timeframe": a.get("timeFrame", "") or "",
                "current": is_cur,
            })
        out = {"_sprints": True, "quarter": quarter, "currentIndex": current_index, "sprints": out_sprints}
        if self.states:
            out["states"] = self.states
        # The configured work-item types, so the dashboard's sections and
        # its "new item" picker follow work_items.types: instead of a
        # hard-coded User Story / Bug pair.
        out["types"] = [t.strip() for t in self.types.split(",") if t.strip()]
        print(json.dumps(out, ensure_ascii=False))
        return 0

    def _wi_list_members(self):
        """The team's members as NDJSON ({name, email}) for the assignee
        picker - typing a display name by hand was the only way before,
        and a typo only surfaced as a REST error."""
        team_q = urllib.parse.quote(self.team, safe="")
        url = "{0}/_apis/projects/{1}/teams/{2}/members".format(
            self.collection, urllib.parse.quote(self.project, safe=""), team_q)
        try:
            resp = self._get(url, api_version="6.0")
        except AdoHttpError as e:
            return self._list_style_error(e, "GET")
        seen = set()
        for m in (resp or {}).get("value") or []:
            ident = m.get("identity") or m
            name = (ident.get("displayName") or "").strip()
            if not name or name.lower() in seen:
                continue
            seen.add(name.lower())
            print(json.dumps({"name": name, "email": ident.get("uniqueName") or ""}, ensure_ascii=False))
        return 0

    # -- detail (wi-detail.sh) -----------------------------------------------

    def cmd_wi_detail(self, wid):
        try:
            full = self._get("{0}/_apis/wit/workitems/{1}?$expand=all".format(self.collection, wid))
        except AdoHttpError as e:
            return self._list_style_error(e, "GET")
        f = full.get("fields") or {}

        parent_id = None
        child_ids = []
        for rel in (full.get("relations") or []):
            r = rel.get("rel", "")
            m = re.search(r"/workItems/(\d+)$", rel.get("url", ""))
            if not m:
                continue
            if r == "System.LinkTypes.Hierarchy-Reverse":
                parent_id = int(m.group(1))
            elif r == "System.LinkTypes.Hierarchy-Forward":
                child_ids.append(int(m.group(1)))

        related = {}
        need = ([parent_id] if parent_id else []) + child_ids
        if need:
            try:
                r = self._post(
                    "{0}/_apis/wit/workitemsbatch".format(self.collection),
                    {"ids": need, "fields": ["System.Id", "System.WorkItemType", "System.State",
                                              "System.Title", "System.AssignedTo"]},
                )
            except AdoHttpError as e:
                return self._list_style_error(e, "POST")
            for wi in ((r or {}).get("value") or []):
                related[wi.get("id")] = _wi_summary(wi)

        item = {
            "id": full.get("id"),
            "type": str(f.get("System.WorkItemType", "")),
            "state": str(f.get("System.State", "")),
            "title": re.sub(r"\s+", " ", str(f.get("System.Title", "")).strip()),
            "assignedTo": _wi_assigned_str(f.get("System.AssignedTo", "")),
            "createdBy": _wi_assigned_str(f.get("System.CreatedBy", "")),
            "createdDate": str(f.get("System.CreatedDate", "")),
            "changedDate": str(f.get("System.ChangedDate", "")),
            "priority": f.get("Microsoft.VSTS.Common.Priority"),
            "areaPath": str(f.get("System.AreaPath", "")),
            "iterationPath": str(f.get("System.IterationPath", "")),
            "tags": str(f.get("System.Tags", "") or ""),
            "reason": str(f.get("System.Reason", "")),
            "description": html_to_text(f.get("System.Description", "")),
            "acceptanceCriteria": html_to_text(f.get("Microsoft.VSTS.Common.AcceptanceCriteria", "")),
            "reproSteps": html_to_text(f.get("Microsoft.VSTS.TCM.ReproSteps", "")),
            "url": "{0}/{1}/_workitems/edit/{2}".format(self.collection, self.project, full.get("id")),
            "pullRequests": _wi_pr_ids_from_relations(full.get("relations")),
        }

        try:
            comments, comments_unsupported = self._fetch_comments(wid)
        except AdoHttpError as e:
            return self._list_style_error(e, "GET")

        out = {
            "item": item,
            "parent": related.get(parent_id) if parent_id else None,
            "children": [related[c] for c in child_ids if c in related],
            "comments": comments,
            "commentsUnsupported": comments_unsupported,
        }
        print(json.dumps(out, ensure_ascii=False))
        return 0

    def _fetch_comments(self, wid):
        """GET .../workItems/{id}/comments, oldest first. Older on-prem TFS
        instances don't expose this endpoint at all: an HTTP 404/400
        degrades to an empty list plus commentsUnsupported=True instead of
        failing the whole detail fetch - mirrors wi-detail.sh's
        fetch_comments() exactly. Any other HTTP error propagates to the
        caller (cmd_wi_detail), same as the script's `sys.exit(2)`.
        """
        url = "{0}/{1}/_apis/wit/workItems/{2}/comments".format(self.collection, self.project, wid)
        try:
            d = self._get(url, api_version=WI_COMMENTS_API)
        except AdoHttpError as e:
            if e.status in (400, 404):
                return [], True
            raise
        raw = d.get("comments") if isinstance(d, dict) else None
        if raw is None:
            raw = d if isinstance(d, list) else []
        raw = sorted(raw, key=lambda c: (str(c.get("createdDate", "")), c.get("id") or 0))
        out = []
        for c in raw:
            out.append({
                "id": c.get("id"),
                "author": _wi_assigned_str(c.get("createdBy", "")),
                "date": str(c.get("createdDate", "")),
                "text": html_to_text(c.get("text", "")),
            })
        return out, False

    # -- state (wi-state.sh) --------------------------------------------------

    def cmd_wi_state(self, rest):
        cmd = rest[0] if len(rest) > 0 else ""
        a2 = rest[1] if len(rest) > 1 else ""
        a3 = rest[2] if len(rest) > 2 else ""
        a4 = rest[3] if len(rest) > 3 else ""

        if cmd == "transitions":
            return self._wi_transitions(a2, a3)
        if cmd == "reasons":
            return self._wi_reasons(a2, a3)
        if cmd == "set":
            return self._wi_set_state(a2, a3, a4)
        print("usage: --wi-state transitions <type> <currentState> | "
              "reasons <type> <toState> | set <id> <newState> [reason]", file=sys.stderr)
        return 1

    def _wi_transitions(self, wtype, cur):
        if not wtype:
            print("ERROR: transitions needs <type>", file=sys.stderr)
            return 1
        url = "{0}/{1}/_apis/wit/workitemtypes/{2}".format(self.collection, self.project, urllib.parse.quote(wtype))
        try:
            d = self._get(url)
        except AdoHttpError as e:
            return self._state_style_error(e, "GET")
        transitions = d.get("transitions") or {}
        seen = set()
        for x in (transitions.get(cur) or []):
            to = x.get("to")
            if to and to != cur and to not in seen:
                seen.add(to)
                print(to)
        return 0

    def _wi_reasons(self, wtype, state):
        if not wtype or not state:
            print("ERROR: reasons needs <type> <toState>", file=sys.stderr)
            return 1
        # ADO/on-prem TFS has no REST route for per-transition reasons;
        # derive the accepted vocabulary from work items already in the
        # target state - mirrors wi-state.sh's own comment/approach exactly.
        wiql = {"query": (
            "SELECT [System.Id] FROM WorkItems WHERE "
            "[System.WorkItemType]='{0}' AND [System.State]='{1}' "
            "ORDER BY [System.ChangedDate] DESC"
        ).format(_wi_sql_esc(wtype), _wi_sql_esc(state))}
        url = "{0}/{1}/_apis/wit/wiql?$top=200".format(self.collection, self.project)
        try:
            d = self._post(url, wiql)
        except AdoHttpError as e:
            return self._state_style_error(e, "POST")
        ids = [w["id"] for w in (d.get("workItems") or [])] if isinstance(d, dict) else []
        counts = {}
        for i in range(0, len(ids), 200):
            batch = ids[i:i + 200]
            if not batch:
                break
            idstr = ",".join(str(x) for x in batch)
            url2 = "{0}/{1}/_apis/wit/workitems?ids={2}&fields=System.Reason".format(
                self.collection, self.project, idstr)
            try:
                b = self._get(url2)
            except AdoHttpError as e:
                return self._state_style_error(e, "GET")
            for w in (b.get("value") or []):
                rv = (w.get("fields") or {}).get("System.Reason") or ""
                if rv:
                    counts[rv] = counts.get(rv, 0) + 1
        for rv, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
            print(rv)
        return 0

    def _wi_set_state(self, wid, new, reason):
        if not wid or not new:
            print("ERROR: set needs <id> <newState>", file=sys.stderr)
            return 1
        url = "{0}/{1}/_apis/wit/workitems/{2}".format(self.collection, self.project, wid)
        if self.validate_only:
            url += "?validateOnly=true"
        patch = [{"op": "add", "path": "/fields/System.State", "value": new}]
        if reason:
            patch.append({"op": "add", "path": "/fields/System.Reason", "value": reason})
        try:
            d = self._patch(url, patch, content_type="application/json-patch+json")
        except AdoHttpError as e:
            return self._state_style_error(e, "PATCH")
        fields = d.get("fields")
        if isinstance(fields, dict):
            print(fields.get("System.State", new))
            return 0
        print("ERROR: unexpected response: " + json.dumps(d)[:300], file=sys.stderr)
        return 2

    # -- edit (wi-edit.sh) -----------------------------------------------------

    def cmd_wi_edit(self, rest):
        cmd = rest[0] if len(rest) > 0 else ""
        a2 = rest[1] if len(rest) > 1 else ""
        a3 = rest[2] if len(rest) > 2 else ""
        a4 = rest[3] if len(rest) > 3 else ""
        a5 = rest[4] if len(rest) > 4 else ""
        a6 = rest[5] if len(rest) > 5 else ""

        if cmd == "create":
            return self._wi_create(a2, a3, a4, a5)
        if cmd == "set":
            return self._wi_set_field(a2, a3, a4)
        if cmd == "comment":
            return self._wi_comment(a2, a3)
        if cmd == "link-pr":
            return self._wi_link_pr(a2, a3, a4, a5, a6)
        if cmd == "unlink-pr":
            return self._wi_unlink_pr(a2, a3)
        print("usage: --wi-edit create <type> <title> [parentId] [iterationPath] | "
              "set <id> <field> <value> | comment <id> <text> | "
              "link-pr <wiId> <orgUrl> <project> <repoName> <prId> | "
              "unlink-pr <wiId> <prId>", file=sys.stderr)
        return 1

    def _wi_create(self, wtype, title, parent_id, iteration_path):
        if not wtype or not title:
            print("ERROR: create needs <type> <title>", file=sys.stderr)
            return 1

        patch = [
            {"op": "add", "path": "/fields/System.Title", "value": title},
            {"op": "add", "path": "/fields/System.AssignedTo", "value": self.assignee},
        ]

        # Default area path: the team's default area. Same endpoint
        # wi-list.sh reads team areas from (teamsettings/teamfieldvalues);
        # its "defaultValue" is the single area new work items should land
        # in, falling back to the first configured area for a team with
        # none marked default.
        team_url = "{0}/{1}/{2}/_apis/work/teamsettings/teamfieldvalues".format(
            self.collection, self.project, urllib.parse.quote(self.team))
        try:
            areas = self._get(team_url)
        except AdoHttpError as e:
            return self._edit_style_error(e, "GET")
        area_path = areas.get("defaultValue") or ""
        if not area_path:
            values = areas.get("values") or []
            area_path = (values[0].get("value") if values else "") or ""
        if area_path:
            patch.append({"op": "add", "path": "/fields/System.AreaPath", "value": area_path})

        if iteration_path:
            patch.append({"op": "add", "path": "/fields/System.IterationPath", "value": iteration_path})

        if parent_id:
            patch.append({
                "op": "add",
                "path": "/relations/-",
                "value": {
                    "rel": "System.LinkTypes.Hierarchy-Reverse",
                    "url": "{0}/_apis/wit/workItems/{1}".format(self.collection, parent_id),
                },
            })

        url = "{0}/{1}/_apis/wit/workitems/${2}".format(self.collection, self.project, urllib.parse.quote(wtype))
        try:
            d = self._post(url, patch, content_type="application/json-patch+json")
        except AdoHttpError as e:
            return self._edit_style_error(e, "POST")
        new_id = d.get("id")
        if new_id is None:
            print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
            return 2
        fields = d.get("fields") or {}
        print(json.dumps({"id": new_id, "title": fields.get("System.Title", title)}, ensure_ascii=False))
        return 0

    def _wi_set_field(self, wid, field, value):
        if not wid or not field:
            print("ERROR: set needs <id> <field> <value>", file=sys.stderr)
            return 1
        if field == "assignedTo" and not value:
            # An empty value for assignedTo means "assign to me" (the ga
            # key's own prompt: "empty = me") - resolved the same way the
            # default `assignee` is: config, else the authenticated user.
            value = self.assignee
        mapping = self._FIELD_MAP.get(field)
        if not mapping:
            print("ERROR: unknown field '" + field + "', expected one of: "
                  + ", ".join(sorted(self._FIELD_MAP)), file=sys.stderr)
            return 1
        ado_field, caster = mapping
        try:
            cast_value = caster(value)
        except (TypeError, ValueError):
            print("ERROR: invalid value for {0}: {1!r}".format(field, value), file=sys.stderr)
            return 1

        url = "{0}/_apis/wit/workitems/{1}".format(self.collection, wid)
        patch = [{"op": "add", "path": "/fields/{0}".format(ado_field), "value": cast_value}]
        try:
            d = self._patch(url, patch, content_type="application/json-patch+json")
        except AdoHttpError as e:
            return self._edit_style_error(e, "PATCH")
        fields = d.get("fields")
        if not isinstance(fields, dict):
            print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
            return 2
        print(json.dumps({"id": d.get("id"), "field": field, "value": fields.get(ado_field, cast_value)},
                          ensure_ascii=False))
        return 0

    def _wi_comment(self, wid, text):
        if not wid or not text:
            print("ERROR: comment needs <id> <text>", file=sys.stderr)
            return 1
        url = "{0}/{1}/_apis/wit/workItems/{2}/comments".format(self.collection, self.project, wid)
        try:
            d = self._post(url, {"text": text}, api_version=WI_COMMENTS_API)
        except AdoHttpError as e:
            return self._edit_style_error(e, "POST")
        cid = d.get("id")
        if cid is None:
            print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
            return 2
        print(json.dumps({"id": cid}, ensure_ascii=False))
        return 0

    def _wi_link_pr(self, wid, org_url, link_project, repo_name, pr_id):
        if not (wid and org_url and link_project and repo_name and pr_id):
            print("ERROR: link-pr needs <wiId> <orgUrl> <project> <repoName> <prId>", file=sys.stderr)
            return 1
        repo_url = "{0}/{1}/_apis/git/repositories/{2}".format(org_url, link_project, urllib.parse.quote(repo_name))
        try:
            repo = self._get(repo_url)
        except AdoHttpError as e:
            return self._edit_style_error(e, "GET")
        repo_guid = repo.get("id")
        project_guid = (repo.get("project") or {}).get("id")
        if not repo_guid or not project_guid:
            print("ERROR: could not resolve repository/project id for '" + repo_name + "'", file=sys.stderr)
            return 2
        artifact_url = "vstfs:///Git/PullRequestId/{0}%2F{1}%2F{2}".format(project_guid, repo_guid, pr_id)
        patch = [{
            "op": "add",
            "path": "/relations/-",
            "value": {"rel": "ArtifactLink", "url": artifact_url, "attributes": {"name": "Pull Request"}},
        }]
        url = "{0}/_apis/wit/workitems/{1}".format(self.collection, wid)
        try:
            d = self._patch(url, patch, content_type="application/json-patch+json")
        except AdoHttpError as e:
            return self._edit_style_error(e, "PATCH")
        if not isinstance(d.get("fields"), dict):
            print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
            return 2
        print(json.dumps({"linked": int(pr_id) if pr_id.isdigit() else pr_id}, ensure_ascii=False))
        return 0

    def _wi_unlink_pr(self, wid, pr_id):
        if not wid or not pr_id:
            print("ERROR: unlink-pr needs <wiId> <prId>", file=sys.stderr)
            return 1
        url = "{0}/_apis/wit/workitems/{1}?$expand=relations".format(self.collection, wid)
        try:
            d = self._get(url)
        except AdoHttpError as e:
            return self._edit_style_error(e, "GET")
        relations = d.get("relations") or []
        idx = None
        suffix_enc = "%2F" + str(pr_id)
        suffix_plain = "/" + str(pr_id)
        for i, rel in enumerate(relations):
            if rel.get("rel") == "ArtifactLink":
                rel_url = rel.get("url", "")
                if rel_url.lower().endswith(suffix_enc.lower()) or rel_url.endswith(suffix_plain):
                    idx = i
                    break
        if idx is None:
            print("ERROR: no linked pull request {0} found on #{1}".format(pr_id, wid), file=sys.stderr)
            return 1
        patch = [{"op": "remove", "path": "/relations/{0}".format(idx)}]
        url2 = "{0}/_apis/wit/workitems/{1}".format(self.collection, wid)
        try:
            d2 = self._patch(url2, patch, content_type="application/json-patch+json")
        except AdoHttpError as e:
            return self._edit_style_error(e, "PATCH")
        if not isinstance(d2.get("fields"), dict):
            print("ERROR: unexpected response: " + json.dumps(d2)[:400], file=sys.stderr)
            return 2
        print(json.dumps({"unlinked": int(pr_id) if pr_id.isdigit() else pr_id}, ensure_ascii=False))
        return 0


def _debug_enabled(env=None):
    """True when AZVICLI_DEBUG is set to anything but ""/"0" - gates whether
    a failed action's full traceback follows its one-line summary (see
    _fail_action below, README's Environment variables table, and
    lua/azure-cli/log.lua, which shows just the one line and keeps the rest
    reachable with :AzureCli log regardless of this). `env` defaults to
    os.environ so a caller with no per-request env handy (the one-shot CLI,
    cmd_requeue) still works.
    """
    value = (env if env is not None else os.environ).get("AZVICLI_DEBUG", "")
    return value not in ("", "0")


def _fail_action(flag, ex, env=None):
    """The one line every failed action (and dispatch()'s own catch-all)
    prints on stderr - "azure-cli <flag> failed: <message>" - with the full
    traceback appended only when AZVICLI_DEBUG=1 (see _debug_enabled). Must
    be called from inside the `except` block it's reporting on, since
    traceback.format_exc() reads the exception still in flight there.
    Keeps a provider failure from reaching the Neovim UI (or a terminal
    running --list/--requeue by hand) as a multi-line raw traceback by
    default - this used to be an unconditional second print() at every one
    of this function's call sites.
    """
    print("azure-cli {0} failed: {1}".format(flag, ex), file=sys.stderr)
    if _debug_enabled(env):
        print(traceback.format_exc(), file=sys.stderr)


def cmd_wi_action(flag, rest, env=None):
    """Dispatches one of WI_ACTION_FLAGS: loads the config, confirms the
    work-item screens are actually configured, and resolves the PAT
    unconditionally before branching on the subcommand (even an unknown
    one) - matching the wi-*.sh scripts' own unconditional resolve_pat_into
    at the top of the script, before any subcommand parsing. Never lets an
    unexpected exception (e.g. a malformed, non-JSON 200 response from a
    misconfigured on-prem TFS URL) escape as a raw traceback on stdout/mid-
    NDJSON - the specific AdoHttpError paths above already return a
    formatted message before reaching here. `env` defaults to os.environ -
    see cmd_pr_action's own comment on why dispatch() always passes one.
    """
    env = os.environ if env is None else env
    if not Config.validate_exists():
        return 1
    config = get_cached_config()
    if config_problems(config):
        return 1
    actions = WorkItemActions(config, env)
    if not actions.ensure_configured():
        return 1
    if not actions.ensure_pat():
        return 1

    try:
        if flag == "--wi-list":
            select = rest[0] if rest else "current"
            item_path = rest[1] if len(rest) > 1 else ""
            return actions.cmd_wi_list(select, item_path)
        if flag == "--wi-detail":
            if not rest or not rest[0]:
                print("ERROR: usage: --wi-detail <work-item-id>", file=sys.stderr)
                return 1
            return actions.cmd_wi_detail(rest[0])
        if flag == "--wi-state":
            return actions.cmd_wi_state(rest)
        if flag == "--wi-edit":
            return actions.cmd_wi_edit(rest)
    except Exception as ex:  # noqa: BLE001 - never leak a raw traceback for a UI-triggered action
        _fail_action(flag, ex, env)
        return 1

    print("Unknown work-item action: {0}".format(flag), file=sys.stderr)  # unreachable via WI_ACTION_FLAGS
    return 1


# ---------------------------------------------------------------------------
# Prefetch modes (AZVICLI_PREFETCH=1|all) - review-pr.sh ported to python
# ---------------------------------------------------------------------------
#
# Invoked with no CLI flags at all - dashboard.lua's ensure_warm/warm_all set
# only the AZVICLI_* env vars (AZVICLI_PREFETCH=1 for a single PR's two
# branches, AZVICLI_PREFETCH=all for a repository-wide fetch) and run the
# provider with no argv, exactly like they ran `{BASH, SCRIPT}` before. This
# is git-only - no PAT, no REST call - so it's checked in main() before any
# config is loaded, matching review-pr.sh's prefetch block never calling
# ensure_pat either.


def _prefetch_marker_key(repo_path):
    """Sanitizes repo_path into a filename-safe key - mirrors review-pr.sh's
    `${var//[!A-Za-z0-9._-]/_}` parameter expansion.
    """
    return re.sub(r"[^A-Za-z0-9._-]", "_", repo_path)


def _git_fetch(repo_path, refspecs):
    try:
        # stdin=DEVNULL matters under --serve: the daemon's own stdin is the
        # request pipe from Neovim, and a child git that inherited it could
        # swallow request lines (or block on a credential prompt) - either
        # way the dashboard would just sit there.
        proc = subprocess.run(
            ["git", "-c", "fetch.showForcedUpdates=false", "fetch", "--quiet", "--no-tags", "origin"] + list(refspecs),
            cwd=repo_path, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120,
        )
        return proc.returncode
    except (OSError, subprocess.SubprocessError):
        return 1


def _touch_marker(prefetch_dir, name):
    try:
        os.makedirs(prefetch_dir, exist_ok=True)
        with open(os.path.join(prefetch_dir, name), "w", encoding="utf-8"):
            pass
    except OSError:
        pass


def cmd_prefetch(env=None):
    env = os.environ if env is None else env
    for name in ("AZVICLI_ORG", "AZVICLI_PROJECT", "AZVICLI_REPO", "AZVICLI_PR"):
        if not env.get(name):
            print("{0} not set".format(name), file=sys.stderr)
            return 1

    mode = env.get("AZVICLI_PREFETCH") or ""
    source = env.get("AZVICLI_SOURCE") or ""
    target = env.get("AZVICLI_TARGET") or ""
    repo_path = env.get("AZVICLI_REPO_PATH") or os.getcwd()
    prefetch_dir = env.get("AZVICLI_PREFETCH_DIR") or default_prefetch_dir()

    if not os.path.isdir(os.path.join(repo_path, ".git")):
        return 0  # harmless no-op, same as review-pr.sh's prefetch abort

    key = _prefetch_marker_key(repo_path)

    if mode == "all":
        rc = _git_fetch(repo_path, [])
        if rc == 0:
            _touch_marker(prefetch_dir, "all-{0}".format(key))
        return rc

    if not source or not target:
        return 0
    rc = _git_fetch(repo_path, [
        "+refs/heads/{0}:refs/remotes/origin/{0}".format(source),
        "+refs/heads/{0}:refs/remotes/origin/{0}".format(target),
    ])
    if rc == 0:
        pr_id = env.get("AZVICLI_PR") or ""
        _touch_marker(prefetch_dir, "{0}-{1}".format(key, pr_id))
    return rc


# ---------------------------------------------------------------------------
# Headless commands
# ---------------------------------------------------------------------------


def cmd_list(config, env=None):
    try:
        source = AzureDevOpsPullRequestSource(config, env)
        for record in source.fetch_grouped_pull_requests():
            sys.stdout.write(json.dumps(record) + "\n")
        sys.stdout.flush()
        return 0
    except Exception as ex:  # noqa: BLE001 - mirrors the exe's catch-all
        _fail_action("--list", ex, env)
        return 1


def cmd_requeue(config, pull_request_id, env=None):
    try:
        source = AzureDevOpsPullRequestSource(config)
        print(source.requeue_build_validation(pull_request_id))
        return 0
    except Exception as ex:  # noqa: BLE001
        _fail_action("--requeue", ex, env)
        return 1


# ---------------------------------------------------------------------------
# First run: the config template
# ---------------------------------------------------------------------------
#
# The one copy of the azure-cli.yml starting point. Written by --init-config,
# which lua/azure-cli/firstrun.lua runs the first time the dashboard opens
# with no config file (standalone launcher and :AzureCli alike - install.sh
# only checks dependencies and never touches the config), and which a
# terminal user can run by hand. Never overwrites an existing file.

CONFIG_TEMPLATE = """\
# azure-cli configuration file.
# See docs/configuration.md for every field.
#
# Fill in org_url / pat / project_name for each account below, then
# remove any accounts you don't need. Add more accounts by copying
# the block under 'accounts:'.
#
# pat: a personal access token, created at
#   https://dev.azure.com/<your-org>/_usersSettings/tokens
#   (on-prem: <collection-url>/_usersSettings/tokens)
# with the scopes  Code: Read & write  and  Work Items: Read & write.
# It is required - there is no Azure AD fallback.
#
# When done, save this file: the dashboard opens (or run
# 'azure-cli --doctor' to check it from a terminal).

accounts:
  - project_name: # TODO: e.g. sample-project
    org_url: # TODO: e.g. https://dev.azure.com/example
    pat: # TODO: your personal access token (required - no Azure AD fallback)
    # pat_file: ~/.config/azure-cli/pat   # instead of pat: - a file holding just the token (chmod 600)
    hide_ancient: true
{clones_dir}
    # Optional - uncomment to enable the work-item screens (W key).
    # work_items:
    #   team: # TODO: e.g. My Team (required)
    #   assignee: # optional; default = your signed-in display name
    #   types: [User Story, Bug]  # optional; default shown
    #   states: [New, Active, Resolved, Closed, Removed]  # optional; order = rank
    #   sprint_scope: parent  # optional; parent (tabs under the current sprint's parent) or all

# Plugin users: timing, hide_ancient_days, python and config path are
# setup() options in Neovim, not fields here - see docs/configuration.md.
"""


def config_template(env=None):
    """CONFIG_TEMPLATE with the clones_dir line filled in: a guess of
    %USERPROFILE%\\source\\repos on Windows (Visual Studio's default), a
    commented-out placeholder elsewhere."""
    env = os.environ if env is None else env
    guess = ""
    if os.name == "nt" and env.get("USERPROFILE"):
        guess = env["USERPROFILE"].rstrip("\\/") + "\\source\\repos"
    if guess:
        line = "    clones_dir: {0}".format(guess.replace("\\", "\\\\"))
    else:
        line = "    # clones_dir: /path/to/where/repos/are/cloned"
    return CONFIG_TEMPLATE.replace("{clones_dir}", line)


def write_config_template(path, env=None):
    """Writes config_template() to `path` unless a file is already there.
    Returns True when it wrote the file, False when one already existed.
    Raises OSError when the directory can't be created or written."""
    if os.path.isfile(path):
        return False
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(config_template(env))
    return True


def cmd_init_config():
    """--init-config: make sure the config file exists (writing the template
    if not) and print its path - the one line firstrun.lua/terminal users
    read. Exit 0 whether it was just written or already there."""
    path = Config.path()
    try:
        wrote = write_config_template(path)
    except OSError as ex:
        print("azure-cli --init-config: could not write {0}: {1}".format(path, ex), file=sys.stderr)
        return 1
    print(path)
    if wrote:
        print("Wrote a config template; fill in the TODO lines.", file=sys.stderr)
    return 0


def doctor_checks(config_path=None):
    """Every setup check the provider can make, as dicts {check, ok,
    detail} in the order they should be read: the config file exists,
    parses and is complete, then one authentication check per organization
    (the same connectionData call --whoami makes), then the work-items
    block. Never raises - a failing check is a dict with ok=False. Shared
    by --doctor (a terminal / install.sh), --doctor --json (the Neovim
    :AzureCli doctor float and :checkhealth azure-cli).
    """
    checks = []
    if config_path is None and Config.accounts_json():
        checks.append({"check": "config source", "ok": True,
                       "detail": "setup({accounts=...}) in your Neovim config (azure-cli.yml not used)"})
        try:
            config = Config.from_json(Config.accounts_json())
        except Exception as ex:  # noqa: BLE001 - reported, not raised
            checks.append({"check": "config parses", "ok": False, "detail": "{0}".format(ex)})
            return checks
        return checks + _doctor_config_checks(config)
    path = config_path or Config.path()
    if not os.path.isfile(path):
        checks.append({"check": "config file", "ok": False,
                       "detail": "{0} does not exist - open the dashboard (./azure-cli or :AzureCli) to have "
                                 "a template written there, or run `azure-cli --init-config`"
                       .format(path)})
        return checks
    checks.append({"check": "config file", "ok": True, "detail": path})
    try:
        config = Config.from_file(path)
    except Exception as ex:  # noqa: BLE001 - reported, not raised
        checks.append({"check": "config parses", "ok": False, "detail": "{0}".format(ex)})
        return checks
    return checks + _doctor_config_checks(config)


def _doctor_config_checks(config):
    """The checks after a Config exists, whatever it was read from: fields,
    pat_file health/permissions, a sign-in per organization, work items."""
    checks = []
    problems = config.problems()
    if problems:
        checks.append({"check": "config fields", "ok": False, "detail": "; ".join(problems)})
        return checks
    checks.append({"check": "config fields", "ok": True,
                   "detail": "{0} account(s)".format(len(config.accounts))})

    for a in config.accounts:
        if not a.pat_file or (isinstance(a.pat, str) and a.pat.strip()):
            continue
        name = "pat_file for {0}".format(a.project or a.org_url or "?")
        loose = a.pat_file_permission_problem()
        if loose:
            checks.append({"check": name, "ok": False, "detail": loose})
        else:
            checks.append({"check": name, "ok": True, "detail": "{0} (only you can read it)".format(a.pat_file_path())})

    source = AzureDevOpsPullRequestSource(config)
    for org, accounts in config.accounts_by_org():
        projects = ", ".join(a.project or "?" for a in accounts)
        name = "sign in to {0} ({1})".format(org, projects)
        pat = source._pick_pat(accounts)
        try:
            user_id, user_name = source._whoami_for_org(org, pat)
            if not user_id:
                checks.append({"check": name, "ok": False,
                               "detail": "connected, but no authenticated user came back - " + (_auth_hint(401) or "")})
            else:
                checks.append({"check": name, "ok": True, "detail": "signed in as {0}".format(user_name or user_id)})
        except Exception as ex:  # noqa: BLE001
            checks.append({"check": name, "ok": False, "detail": "{0}".format(ex)})

    wi = next((a for a in config.accounts if a.work_items), None)
    if wi is None:
        checks.append({"check": "work items", "ok": True,
                       "detail": "not configured (optional - add a work_items: block with team: to enable W)"})
    elif not (wi.work_items.get("team") or "").strip():
        checks.append({"check": "work items", "ok": False,
                       "detail": "work_items: block on {0} has no team: - it's required".format(wi.project)})
    else:
        checks.append({"check": "work items", "ok": True,
                       "detail": "team '{0}' on {1}".format(wi.work_items.get("team"), wi.project)})
    return checks


def cmd_doctor(as_json=False):
    checks = doctor_checks()
    if as_json:
        for c in checks:
            sys.stdout.write(json.dumps(c) + "\n")
    else:
        for c in checks:
            sys.stdout.write("{0}  {1}: {2}\n".format("ok  " if c["ok"] else "FAIL", c["check"], c["detail"]))
        if all(c["ok"] for c in checks):
            sys.stdout.write("Everything checks out.\n")
        else:
            sys.stdout.write("Fix the FAIL line(s) in {0} and run this again.\n".format(Config.source_label()))
    sys.stdout.flush()
    return 0 if all(c["ok"] for c in checks) else 1


def cmd_print_pat(config, org, project):
    if not org:
        print("azure-cli --print-pat requires --org <organization-url>.", file=sys.stderr)
        return 1

    want_org = org.rstrip("/")
    for account in config.accounts:
        org_matches = (account.org_url or "").rstrip("/").lower() == want_org.lower()
        project_matches = (not project) or ((account.project or "").lower() == project.lower())
        if org_matches and project_matches:
            token = account.token()
            if not token:
                print("azure-cli --print-pat: matching account has no 'pat' (or readable 'pat_file') configured.",
                      file=sys.stderr)
                return 1
            sys.stdout.write(token)
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
# Daemon mode (--serve) - one long-lived process instead of one per action
# ---------------------------------------------------------------------------
#
# Every jobstart in the Lua UI (a PR action, a work-item call, --list, a
# branch prefetch, ...) used to mean a fresh `python azure-cli.py ...`
# process: python start-up plus re-importing/re-parsing everything, paid on
# every single click. --serve starts this file ONCE per nvim session
# (rpc.lua's daemon client) and answers every request over stdin/
# stdout instead - see rpc.lua's own header comment for the Lua side
# of this.
#
# Wire protocol: one JSON object per line, both directions.
#   -> {"id": <int>, "argv": [...], "env": {...}}
#      argv is exactly what sys.argv[1:] would have been for a one-shot
#      call (e.g. ["--threads"] or ["--wi-list", "current"]); env is that
#      request's AZVICLI_*/AZVICLI_WI_* overrides, merged over the daemon's own
#      os.environ (never mutated - each request gets its own dict, since
#      requests run concurrently and os.environ is process-wide).
#   <- {"id": <int>, "code": <int>, "stdout": "...", "stderr": "..."}
#      Responses can be written in any order - independent requests run on
#      a bounded thread pool, so a slow one (a network call) never blocks a
#      fast one (e.g. --print-pat) queued after it. A malformed line
#      answers with {"id": null, "code": 1, "stdout": "", "stderr": "..."}.
#   {"id": n, "argv": ["--ping"]} -> {"id": n, "code": 0, "stdout": "pong\n", "stderr": ""}
#      A cheap liveness check rpc.lua fires once, in the background,
#      as soon as the dashboard loads, so the daemon's start-up cost is
#      already paid by the time the first real request needs it.
#
# dispatch(argv, env) runs exactly what a one-shot `python azure-cli.py
# <argv>` invocation would for that argv/env, in-process: no os.environ
# reads inside a handler (env is threaded through explicitly - see
# cmd_pr_action/cmd_wi_action/cmd_prefetch's own `env` parameters above),
# no sys.exit (a handler that used to sys.exit - only Config.validate_exists
# did - now returns a code instead: raising SystemExit out of a
# ThreadPoolExecutor worker would fail that request in a way dispatch()
# below can still catch, but there's no reason to lean on that when a plain
# return works and matches every other handler). stdout/stderr are
# captured per request via _install_streams/_captured_output below, not
# passed as explicit parameters, so the vast majority of this file's
# existing print()/print(..., file=sys.stderr) calls needed no changes at
# all - only the one place that wrote raw bytes straight to
# sys.stdout.buffer (_fetch_raw_list, for --threads/--iterations) had to
# switch to a text sys.stdout.write, since .buffer bypasses the wrapper.


class _ThreadLocalStream:
    """Stands in for sys.stdout/sys.stderr once _install_streams below has
    replaced them: each thread gets its own destination (set by
    _captured_output while dispatch() runs on it), so concurrent --serve
    requests on different thread-pool workers never see each other's
    output. A thread that never called _captured_output - the --serve
    loop's own thread, or any code running before the first dispatch() call
    - falls through to `real` (whatever sys.stdout/sys.stderr actually was
    when this wrapper was installed), so the one-shot CLI path (and the
    daemon's own line-writing loop) behaves exactly as if this wrapper
    didn't exist.
    """

    def __init__(self, real):
        self._real = real
        self._local = threading.local()

    def write(self, s):
        return getattr(self._local, "target", self._real).write(s)

    def flush(self):
        getattr(self._local, "target", self._real).flush()

    def __getattr__(self, name):
        # isatty(), encoding, buffer, ... - anything this class doesn't
        # define itself proxies to the real stream (whichever thread asks:
        # these are read-only/introspection attributes, not per-request
        # state, so there's nothing to make thread-local about them).
        return getattr(self._real, name)


_stream_install_lock = threading.Lock()


def _install_streams():
    """Wraps sys.stdout/sys.stderr in _ThreadLocalStream, once (idempotent -
    safe to call from every dispatch()/serve()). Deliberately lazy rather
    than done at import time: a plain one-shot CLI run that never calls
    dispatch() (the bare nvim-launch path in main()) never pays for this at
    all, and it always wraps whatever sys.stdout/sys.stderr currently ARE
    (letting a test's own mock.patch("sys.stdout", ...) be what gets
    wrapped, rather than capturing a stale reference from import time).
    """
    with _stream_install_lock:
        if not isinstance(sys.stdout, _ThreadLocalStream):
            sys.stdout = _ThreadLocalStream(sys.stdout)
        if not isinstance(sys.stderr, _ThreadLocalStream):
            sys.stderr = _ThreadLocalStream(sys.stderr)
    return sys.stdout, sys.stderr


class _captured_output:
    """Context manager: for the life of the `with` block, THIS THREAD's
    sys.stdout/sys.stderr writes land in `out`/`err` (io.StringIO) instead
    of wherever they'd otherwise go - every other thread is unaffected.
    Restores this thread's previous target (nested dispatch() calls, if
    that ever happened, would nest correctly) rather than assuming there
    wasn't one.
    """

    def __init__(self, out, err):
        self._out, self._err = out, err

    def __enter__(self):
        so, se = _install_streams()
        self._so_local, self._se_local = so._local, se._local
        self._prev_out = getattr(self._so_local, "target", None)
        self._prev_err = getattr(self._se_local, "target", None)
        self._so_local.target = self._out
        self._se_local.target = self._err

    def __exit__(self, *exc_info):
        if self._prev_out is None:
            del self._so_local.target
        else:
            self._so_local.target = self._prev_out
        if self._prev_err is None:
            del self._se_local.target
        else:
            self._se_local.target = self._prev_err


def dispatch(argv, env):
    """Runs exactly what the CLI would run for `argv` with `env`, in-process.
    Never raises, never exits - returns (code, stdout_text, stderr_text).
    Used by both --serve (one call per request) and, indirectly, main()
    (see its own comment) for every headless flag.
    """
    out, err = io.StringIO(), io.StringIO()
    with _captured_output(out, err):
        try:
            code = _run_dispatch(argv, env)
        except SystemExit as ex:
            code = ex.code if isinstance(ex.code, int) else (0 if ex.code is None else 1)
        except Exception as ex:  # noqa: BLE001 - never let a handler bug kill the daemon
            # Backstop for a handler with no try/except of its own (e.g.
            # cmd_pr_action) - everything else already caught its own
            # exception and called _fail_action before this ever runs.
            _fail_action(argv[0] if argv else "<no flag>", ex, env)
            code = 1
    return code, out.getvalue(), err.getvalue()


def _run_dispatch(argv, env):
    """The flag-routing dispatch() runs - the same routing main() used to do
    directly, minus --serve itself and the bare (no flags, no
    AZVICLI_PREFETCH) nvim-launch case, which only make sense for a single
    top-level process and stay in main() (see its own comment).
    """
    if argv[:1] == ["--ping"]:
        print("pong")
        return 0
    if argv and argv[0] in PR_ACTION_FLAGS:
        return cmd_pr_action(argv[0], argv[1:], env=env)
    if argv and argv[0] in WI_ACTION_FLAGS:
        return cmd_wi_action(argv[0], argv[1:], env=env)
    if not argv and env.get("AZVICLI_PREFETCH"):
        return cmd_prefetch(env=env)

    args = parse_args(argv)
    if args.doctor:
        return cmd_doctor(as_json=args.json)
    if args.init_config:
        return cmd_init_config()
    if not Config.validate_exists():
        return 1
    config = get_cached_config()
    if (args.list or args.requeue is not None) and config_problems(config):
        return 1

    if args.list:
        return cmd_list(config, env)
    if args.requeue is not None:
        return cmd_requeue(config, args.requeue, env)
    if args.print_pat:
        return cmd_print_pat(config, args.org, args.project)
    if args.whoami:
        return cmd_whoami(config, args.org, args.project)

    print("azure-cli: no headless flag given to a --serve request "
          "(the nvim dashboard itself is never served).", file=sys.stderr)
    return 1


def serve():
    """--serve: reads one JSON request per line from stdin (sys.stdin.buffer,
    so a request's own text can be any encoding json.loads tolerates
    without this loop's own buffering getting in the way), runs each on an
    8-worker ThreadPoolExecutor (requests are independent - one PR action
    or work-item call never depends on another finishing first), and
    writes one JSON response line to stdout as soon as that request
    finishes, flushed immediately (unbuffered - a slow request already
    running must never delay an earlier-finished one's response sitting in
    a stdio buffer). EOF on stdin drains whatever's still in flight (the
    ThreadPoolExecutor context manager waits for every submitted task) and
    returns 0. Nothing but response lines ever reaches real stdout -
    dispatch() gives every request its own captured stdout/stderr (see
    _captured_output above), so a handler's own print() calls can never
    leak onto this loop's line protocol; every diagnostic of this loop's
    own goes to stderr, never stdout.
    """
    real_out, real_err = _install_streams()
    write_lock = threading.Lock()

    def write_response(resp):
        line = json.dumps(resp, ensure_ascii=False)
        with write_lock:
            real_out.write(line + "\n")
            real_out.flush()

    def handle(req):
        rid = req.get("id") if isinstance(req, dict) else None
        argv = req.get("argv") if isinstance(req, dict) else None
        if not isinstance(argv, list):
            write_response({"id": rid, "code": 1, "stdout": "",
                             "stderr": "malformed request: 'argv' must be a list"})
            return
        req_env = req.get("env")
        if req_env is None:
            req_env = {}
        if not isinstance(req_env, dict):
            write_response({"id": rid, "code": 1, "stdout": "",
                             "stderr": "malformed request: 'env' must be an object"})
            return
        # A fresh dict per request - os.environ itself is never touched, so
        # concurrent requests on other workers never see each other's
        # AZVICLI_*/AZVICLI_WI_* overrides (see this section's header comment).
        merged_env = dict(os.environ)
        merged_env.update({str(k): str(v) for k, v in req_env.items()})
        code, out, err = dispatch([str(a) for a in argv], merged_env)
        write_response({"id": rid, "code": code, "stdout": out, "stderr": err})

    with ThreadPoolExecutor(max_workers=8) as executor:
        for raw_line in sys.stdin.buffer:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception as ex:  # noqa: BLE001
                write_response({"id": None, "code": 1, "stdout": "",
                                 "stderr": "malformed request line: {0}".format(ex)})
                continue
            if not isinstance(req, dict):
                write_response({"id": None, "code": 1, "stdout": "",
                                 "stderr": "malformed request: not a JSON object"})
                continue
            executor.submit(handle, req)
        # Falling out of the for loop means EOF on stdin; the `with` block's
        # __exit__ (ThreadPoolExecutor.shutdown(wait=True)) blocks here
        # until every request already submitted above has finished and
        # written its response, so nothing in flight is ever dropped.
    return 0


# ---------------------------------------------------------------------------
# Dashboard launcher - mirrors EntryPoint.LaunchDashboard
# ---------------------------------------------------------------------------


def find_repo_root(start_dir):
    """Walks up from start_dir looking for standalone/init.lua (the
    launcher's Neovim entry point - see launch_dashboard below), so this
    still works if azure-cli.py is ever run from a packaged/copied location.
    Before the plugin restructure this looked for azure-cli.lua directly at
    the repo root; the Lua side now lives under lua/azure-cli/, plugin/ and
    standalone/, so standalone/init.lua is the new marker.
    """
    d = start_dir
    for _ in range(8):
        if d is None:
            return None
        if os.path.isfile(os.path.join(d, "standalone", "init.lua")):
            return d
        parent = os.path.dirname(d)
        d = parent if parent != d else None
    return None


def launch_dashboard(config, script_path):
    script_dir = os.path.dirname(os.path.abspath(script_path))
    repo_root = find_repo_root(script_dir)
    if repo_root is None:
        print(
            "azure-cli: could not find standalone/init.lua near {0}. Keep azure-cli.py under its repo, "
            "or use --list/--requeue/--print-pat.".format(script_dir),
            file=sys.stderr,
        )
        return 1

    # standalone/init.lua stands in for a whole init.vim/init.lua (run with
    # `nvim -u`, not `-u NONE -c luafile ...`): it puts the plugin root on
    # 'runtimepath' itself, then calls into the same require("azure-cli")
    # entry point a plugin-manager install uses, so the standalone launcher
    # and a `:AzureCli` install behave identically from here on.
    standalone_entry = os.path.join(repo_root, "standalone", "init.lua").replace("\\", "/")
    # The launcher script, not this .py file - anything that shells out
    # through AZVICLI_EXE (e.g. --print-pat run by hand) needs a single
    # executable token, and on Windows that has to be the launcher script
    # (azure-cli), not "python azure-cli.py".
    exe_path = os.path.join(repo_root, "azure-cli")

    env = os.environ.copy()
    env["AZVICLI_EXE"] = exe_path
    # AZVICLI_PY/AZVICLI_PROVIDER: what every Lua surface (the dashboard, the
    # reviewer's EXT.provider, the work-items dashboard/view) re-invokes
    # this same provider through - see README's Environment variables, and
    # lua/azure-cli/config.lua's provider_cmd(), which every one of them
    # calls instead of resolving AZVICLI_PY/AZVICLI_PROVIDER itself now.
    # The old script-path/bash/PAT-table env vars this launcher used to
    # export are all gone now: PR actions moved off review-pr.sh in an
    # earlier step and work-item actions off wi-*.sh/resolve-pat.sh in the
    # one after, so nothing left needs a bash to run under or a PAT
    # table/script path to find - a PAT is resolved straight from the
    # config by resolve_account_pat, same as every other provider call.
    env["AZVICLI_PY"] = sys.executable or "python3"
    env["AZVICLI_PROVIDER"] = os.path.abspath(script_path)

    if config is not None and getattr(config, "repo_path", None):
        env["AZVICLI_REPO_PATH"] = config.repo_path
    else:
        env.pop("AZVICLI_REPO_PATH", None)

    try:
        proc = subprocess.run(["nvim", "-u", standalone_entry], env=env)
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
    parser.add_argument(
        "--doctor", action="store_true",
        help="Check the setup: config file, its fields, sign-in per organization, work items (no TUI)",
    )
    parser.add_argument("--json", action="store_true", help="With --doctor: one JSON object per check instead of text")
    parser.add_argument(
        "--init-config", dest="init_config", action="store_true",
        help="Write the azure-cli.yml template at its platform location if there is no config file yet, "
             "print the path and exit (no TUI). What the first dashboard launch runs for you.",
    )
    # Anything else is ignored rather than rejected - none of the shell/Lua
    # callers in this repo pass anything but the flags above.
    args, _unknown = parser.parse_known_args(argv)
    return args


def main(argv=None):
    """Thin wrapper: --serve runs the daemon loop, an empty argv either
    branch-prefetches or launches the nvim dashboard (both stay here rather
    than going through dispatch() - see the comment below), and everything
    else runs through dispatch() exactly once, in-process, writing its
    captured stdout/stderr straight to the real streams and exiting with
    its code. This is also exactly what --serve's own dispatch() calls
    replicate per request, so the one-shot CLI and the daemon run the same
    code for every headless flag.
    """
    argv = sys.argv[1:] if argv is None else argv

    if argv[:1] == ["--serve"]:
        return serve()

    if not argv:
        # No flags at all: either branch-prefetch (AZVICLI_PREFETCH=1|all -
        # env-only, git-only, matching review-pr.sh's own prefetch block,
        # which never loads the config either) or launch the nvim dashboard.
        # Neither goes through dispatch(): prefetch is simple enough to call
        # directly, and launch_dashboard needs a real controlling terminal
        # (subprocess.run(["nvim", ...]) with inherited stdio) that
        # dispatch()'s in-process output capture can't give it - a --serve
        # request with an empty argv and no AZVICLI_PREFETCH (see
        # _run_dispatch) is refused rather than trying to launch a nested
        # nvim UI from inside the daemon.
        if os.environ.get("AZVICLI_PREFETCH"):
            return cmd_prefetch()
        # No config yet is not an error here: nvim opens and
        # lua/azure-cli/firstrun.lua writes the template (via --init-config)
        # and opens it for editing. Only an existing file is read.
        config = get_cached_config() if Config.is_configured() else None
        return launch_dashboard(config, __file__)

    code, out, err = dispatch(argv, dict(os.environ))
    sys.stdout.write(out)
    sys.stderr.write(err)
    return code


if __name__ == "__main__":
    sys.exit(main())
