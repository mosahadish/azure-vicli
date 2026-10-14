"""github_host.py: GitHub as azure-cli.py's second code host.

An account with `host: github` in azure-cli.yml lists its pull requests
through here. Everything this module hands back is in the shapes the Azure
DevOps code already uses, so the Lua side reads a GitHub PR the way it reads
an Azure one:

- a PR becomes an ADO-shaped pull request dict (ado_pr), which azure-cli.py's
  own to_record / _compute_state / count_* turn into the dashboard record;
- review threads become ADO comment threads (ado_threads): an unresolved
  conversation is "active", a resolved one "fixed", and every comment on the
  Conversation tab goes in one flat thread with id 0 (`conversation: true`);
- pushes become ADO iterations (ado_iterations): one per commit, plus one
  per force push.

The environment contract stays the same: for a GitHub PR AZVICLI_ORG is the
account's api_url, AZVICLI_PROJECT the repository's owner, AZVICLI_REPO its
name and AZVICLI_PR the PR number. Votes keep Azure's numbers as the
currency between the two sides: an approval is 10, changes requested -5
(GitHub's "wait for author"), anything else 0.

azure-cli.py hands its own module in as `core` (bind()), for the helpers it
reuses; nothing here imports it.
"""

import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API = "https://api.github.com"

core = None


def bind(module):
    global core
    core = module


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class GitHubHttpError(Exception):
    def __init__(self, status, url, body):
        Exception.__init__(self, "HTTP {0}: {1}".format(status, _error_text(body)))
        self.status = status
        self.url = url
        self.body = body


def _error_text(body):
    """GitHub's error JSON as one line: its message plus each error's own
    ("Validation Failed: line must be part of the diff")."""
    try:
        data = json.loads(body or "")
    except ValueError:
        return (body or "")[:300]
    if not isinstance(data, dict):
        return (body or "")[:300]
    parts = [str(data.get("message") or "")]
    for e in data.get("errors") or []:
        if isinstance(e, dict):
            parts.append(str(e.get("message") or e.get("code") or ""))
        elif e:
            parts.append(str(e))
    return ": ".join(p for p in parts if p)[:300]


def api_base(api_url):
    return (api_url or DEFAULT_API).rstrip("/")


def graphql_url(api_url):
    """GitHub.com's GraphQL endpoint sits beside its REST root; Enterprise
    Server's REST root is <host>/api/v3 and its GraphQL <host>/api/graphql."""
    base = api_base(api_url)
    if base.endswith("/api/v3"):
        return base[:-len("/v3")] + "/graphql"
    return base + "/graphql"


def web_host(api_url):
    """The host `gh` knows the account by: github.com for the public API,
    the server's own name for Enterprise Server."""
    netloc = urllib.parse.urlparse(api_base(api_url)).netloc
    return "github.com" if netloc in ("api.github.com", "") else netloc


def _graphql_read(url, data):
    """A GraphQL POST that only reads - no mutation or subscription anywhere
    in it - which azure-cli.py's connection pool may retry once on a stale
    connection, like a GET. Anything unsure counts as a write."""
    if not url.endswith("/graphql") or not isinstance(data, dict):
        return False
    query = data.get("query")
    return isinstance(query, str) and not re.search(r"\b(mutation|subscription)\b", query)


def http(method, url, token, data=None):
    body = None if data is None else json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, method=method)
    if _graphql_read(url, data):
        req.azvicli_read_only = True
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "azure-vicli")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    # The perf log (AZVICLI_DEBUG): one line per request - azure-cli.py's
    # perf_record, given the method, the URL and numbers, never the headers.
    perf = core is not None and core._perf_current() is not None
    t0 = time.monotonic() if perf else 0.0
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            status = getattr(resp, "status", None) or 200
    except urllib.error.HTTPError as e:
        err_body = e.read()
        if perf:
            core.perf_record(method, url, e.code, len(err_body or b""), t0, conn=core._last_conn())
        raise GitHubHttpError(e.code, url, err_body.decode("utf-8", "replace"))
    except (urllib.error.URLError, ValueError):
        if perf:
            core.perf_record(method, url, 0, 0, t0, conn=core._last_conn())
        raise
    if perf:
        core.perf_record(method, url, status, len(raw or b""), t0, conn=core._last_conn())
    if not raw:
        return {}
    return json.loads(raw.decode("utf-8"))


_gh_tokens = {}
_gh_lock = threading.Lock()


def gh_token(api_url):
    """`gh auth token` for the account's host, cached for the process's
    life (the daemon's: a fresh `gh auth login` reaches it after a restart).
    None when gh isn't installed or isn't signed in there."""
    host = web_host(api_url)
    with _gh_lock:
        if host in _gh_tokens:
            return _gh_tokens[host]
    try:
        out = subprocess.run(["gh", "auth", "token", "--hostname", host], capture_output=True, text=True,
                             timeout=20)
        token = out.stdout.strip() if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        token = None
    with _gh_lock:
        _gh_tokens[host] = token or None
    return token or None


def account_token(account):
    """pat: / pat_file: first, then `gh auth token`."""
    return account.token() or gh_token(account.api_url)


class Client:
    """One account's connection. `fetch(method, url, token, data)` is
    swappable for tests, like PrActions.fetch."""

    def __init__(self, api_url, token, fetch=None):
        self.api_url = api_base(api_url)
        self.token = token
        self.fetch = fetch or http

    def graphql(self, query, variables=None):
        out = self.fetch("POST", graphql_url(self.api_url), self.token, {"query": query, "variables": variables or {}})
        errors = (out or {}).get("errors")
        if errors:
            raise RuntimeError("GitHub GraphQL: " + "; ".join(str((e or {}).get("message") or e) for e in errors))
        return (out or {}).get("data") or {}

    def rest(self, method, path, data=None):
        return self.fetch(method, self.api_url + path, self.token, data)


# ---------------------------------------------------------------------------
# GitHub -> Azure DevOps shapes
# ---------------------------------------------------------------------------

ACTOR = "login ... on User { name }"

PR_FIELDS = """
fragment PR on PullRequest {
  number title url body isDraft createdAt updatedAt state
  headRefName baseRefName headRefOid isCrossRepository
  headRef { name }
  repository { name url owner { login }
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed autoMergeAllowed deleteBranchOnMerge }
  author { %(a)s }
  mergeable
  autoMergeRequest { enabledBy { %(a)s } }
  reviewRequests(first: 20) { nodes { requestedReviewer {
    __typename ... on User { login name } ... on Team { slug name } ... on Mannequin { login } } } }
  latestOpinionatedReviews(first: 30) { nodes { state author { %(a)s } } }
  latestReviews(first: 30) { nodes { state author { %(a)s } } }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}
""" % {"a": ACTOR}

LIST_QUERY = """
query($requested: String!, $reviewed: String!, $created: String!) {
  viewer { login name }
  requested: search(query: $requested, type: ISSUE, first: 50) { nodes { ...PR } }
  reviewed: search(query: $reviewed, type: ISSUE, first: 50) { nodes { ...PR } }
  created: search(query: $created, type: ISSUE, first: 50) { nodes { ...PR } }
}
""" + PR_FIELDS

PR_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  viewer { login name }
  repository(owner: $owner, name: $name) { pullRequest(number: $number) { ...PR } }
}
""" + PR_FIELDS

THREADS_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    reviewThreads(first: 100) { nodes {
      id isResolved isOutdated path line startLine diffSide startDiffSide subjectType
      comments(first: 100) { nodes { databaseId body createdAt author { %(a)s } } } } }
    comments(first: 100) { nodes { databaseId body createdAt author { %(a)s } } }
  } }
}
""" % {"a": ACTOR}

ITERATIONS_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    timelineItems(first: 250, itemTypes: [PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT]) { nodes {
      __typename
      ... on PullRequestCommit { commit { oid committedDate } }
      ... on HeadRefForcePushedEvent { createdAt afterCommit { oid } } } }
    latestReviews(first: 50) { nodes { submittedAt author { login } commit { oid } } }
  } }
}
"""

OWNER_QUERY = "query($login: String!) { repositoryOwner(login: $login) { __typename } }"

# A reviewer's latest opinion as an Azure vote: see the module comment.
VOTES = {"APPROVED": 10, "CHANGES_REQUESTED": -5}

BUILD = {"SUCCESS": "succeeded", "FAILURE": "failed", "ERROR": "failed", "PENDING": "running",
         "EXPECTED": "running"}

# What a fork PR's source branch is called here: GitHub keeps every PR's
# head at refs/pull/<n>/head in the base repository, so a fork's branch -
# which may well be called the same as the target ("main") - is fetched
# under that name instead (cmd_prefetch reads it back).
FORK_SOURCE = "pull/{0}/head"
FORK_SOURCE_RE = re.compile(r"^pull/(\d+)/head$")


def _name(actor):
    actor = actor or {}
    return actor.get("name") or actor.get("login") or ""


def pr_key(owner, repo, number):
    """The PR's key on the Lua side (lua/azure-cli/hosts.lua): unique
    across repositories, and safe in a file name ("~" never appears in a
    GitHub owner or repository name)."""
    return "{0}~{1}~{2}".format(owner, repo, number)


def source_branch(node):
    if node.get("isCrossRepository"):
        return FORK_SOURCE.format(node.get("number"))
    return node.get("headRefName") or ""


def ado_pr(node):
    """A GraphQL PullRequest as the Azure DevOps pull-request dict
    to_record and _compute_state read."""
    author = node.get("author") or {}
    author_login = author.get("login") or ""
    reviewers, by_login, pending = [], {}, set()

    def put(login, name, vote, container=False):
        if not login or login == author_login:
            return
        r = by_login.get(login)
        if r is None:
            r = {"id": login, "displayName": name or login, "vote": vote, "isContainer": container}
            by_login[login] = r
            reviewers.append(r)
        elif vote and not r["vote"] and login not in pending:
            r["vote"] = vote

    # A reviewer asked again after their review is waited on again: their
    # old verdict doesn't stand.
    for n in ((node.get("reviewRequests") or {}).get("nodes") or []):
        rr = (n or {}).get("requestedReviewer") or {}
        if rr.get("__typename") == "Team":
            put("team:" + (rr.get("slug") or ""), rr.get("name") or rr.get("slug"), 0, True)
        elif rr.get("login"):
            pending.add(rr["login"])
            put(rr["login"], rr.get("name"), 0)
    for key in ("latestOpinionatedReviews", "latestReviews"):
        for n in ((node.get(key) or {}).get("nodes") or []):
            a = (n or {}).get("author") or {}
            put(a.get("login"), _name(a), VOTES.get((n or {}).get("state"), 0))

    auto = node.get("autoMergeRequest")
    return {
        "pullRequestId": node.get("number"),
        "title": node.get("title") or "",
        "description": node.get("body") or "",
        "isDraft": bool(node.get("isDraft")),
        "repository": {"name": (node.get("repository") or {}).get("name") or "",
                       "id": "{0}/{1}".format(((node.get("repository") or {}).get("owner") or {}).get("login") or "",
                                              (node.get("repository") or {}).get("name") or "")},
        "createdBy": {"id": author_login, "displayName": _name(author)},
        "sourceRefName": "refs/heads/" + source_branch(node),
        "targetRefName": "refs/heads/" + (node.get("baseRefName") or ""),
        "creationDate": node.get("createdAt"),
        "reviewers": reviewers,
        "autoCompleteSetBy": {"displayName": _name((auto or {}).get("enabledBy"))} if auto else None,
        "mergeStatus": "conflicts" if node.get("mergeable") == "CONFLICTING" else "succeeded",
    }


def _comment(c):
    a = (c or {}).get("author") or {}
    return {"id": (c or {}).get("databaseId"), "content": (c or {}).get("body") or "", "commentType": "text",
            "isDeleted": False, "author": {"id": a.get("login") or "", "displayName": _name(a)},
            "publishedDate": (c or {}).get("createdAt")}


def ado_threads(pr):
    """A PullRequest's reviewThreads + Conversation comments as ADO threads
    (see the module comment). A thread's id is its first comment's id - a
    number, like an Azure thread's, and the one a reply is posted against."""
    out = []
    for t in ((pr.get("reviewThreads") or {}).get("nodes") or []):
        comments = [_comment(c) for c in ((t.get("comments") or {}).get("nodes") or [])]
        if not comments:
            continue
        ctx = {"filePath": "/" + (t.get("path") or "")}
        line = t.get("line")
        if t.get("subjectType") != "FILE" and line:
            side = "right" if t.get("diffSide") != "LEFT" else "left"
            ctx[side + "FileStart"] = {"line": t.get("startLine") or line, "offset": 1}
            ctx[side + "FileEnd"] = {"line": line, "offset": 1}
        out.append({"id": comments[0]["id"], "status": "fixed" if t.get("isResolved") else "active",
                    "isDeleted": False, "threadContext": ctx, "comments": comments,
                    "nodeId": t.get("id"), "isOutdated": bool(t.get("isOutdated"))})
    general = [_comment(c) for c in ((pr.get("comments") or {}).get("nodes") or [])]
    if general:
        out.append({"id": 0, "status": "active", "isDeleted": False, "conversation": True, "comments": general})
    return out


def ado_iterations(pr, viewer_login=None):
    """The PR's pushes as ADO iterations ({id, createdDate,
    sourceRefCommit.commitId}), oldest first, plus myLastReviewSha: the
    commit my latest review was made on."""
    points = []
    for n in ((pr.get("timelineItems") or {}).get("nodes") or []):
        n = n or {}
        if n.get("__typename") == "PullRequestCommit":
            c = n.get("commit") or {}
            points.append((c.get("committedDate") or "", c.get("oid")))
        elif n.get("__typename") == "HeadRefForcePushedEvent":
            points.append((n.get("createdAt") or "", (n.get("afterCommit") or {}).get("oid")))
    points.sort(key=lambda p: p[0])
    value, seen = [], set()
    for date, oid in points:
        if not oid or oid in seen:
            continue
        seen.add(oid)
        value.append({"id": len(value) + 1, "createdDate": date, "sourceRefCommit": {"commitId": oid}})
    mine = None
    for r in ((pr.get("latestReviews") or {}).get("nodes") or []):
        if viewer_login and ((r or {}).get("author") or {}).get("login") == viewer_login:
            mine = ((r or {}).get("commit") or {}).get("oid")
    out = {"count": len(value), "value": value}
    if mine:
        out["myLastReviewSha"] = mine
    return out


def merge_methods(repo):
    out = []
    if repo.get("squashMergeAllowed", True):
        out.append({"key": "squash", "label": "Squash and merge"})
    if repo.get("mergeCommitAllowed", True):
        out.append({"key": "merge", "label": "Create a merge commit"})
    if repo.get("rebaseMergeAllowed", True):
        out.append({"key": "rebase", "label": "Rebase and merge"})
    return out


def mention_counts(threads, login):
    """(threads with an @login mention that are still active, mentions in
    all) - count_mentions for GitHub's plain "@login" form."""
    if not login:
        return (0, 0)
    pat = re.compile(r"(?<![\w-])@" + re.escape(login) + r"(?![\w-])", re.I)
    in_threads = total = 0
    for t in threads:
        hit = False
        for c in t.get("comments") or []:
            n = len(pat.findall(c.get("content") or ""))
            total += n
            hit = hit or n > 0
        if hit and t.get("status") == "active" and not t.get("conversation"):
            in_threads += 1
    return (in_threads, total)


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------

# Threads per PR, kept for the daemon's life and refetched only when the
# PR's updatedAt moves (a comment or a push does that): --list runs every
# 30 s, and GitHub's rate limit is per hour.
_threads_cache = {}
_threads_lock = threading.Lock()


def fetch_threads(client, owner, repo, number, updated=None):
    key = (client.api_url, owner, repo, int(number))
    if updated:
        with _threads_lock:
            hit = _threads_cache.get(key)
        if hit and hit[0] == updated:
            return hit[1]
    data = client.graphql(THREADS_QUERY, {"owner": owner, "name": repo, "number": int(number)})
    pr = ((data.get("repository") or {}).get("pullRequest")) or {}
    threads = ado_threads(pr)
    if updated:
        with _threads_lock:
            _threads_cache[key] = (updated, threads)
    return threads


def search_queries(owner_filter):
    base = "is:pr is:open archived:false"
    if owner_filter:
        base += " " + owner_filter
    return {"requested": base + " review-requested:@me", "reviewed": base + " reviewed-by:@me",
            "created": base + " author:@me"}


class _Acct(object):
    def __init__(self, api_url, owner, clones_dir, hide_ancient):
        self.org_url = api_url
        self.project = owner
        self.clones_dir = clones_dir
        self.hide_ancient = hide_ancient


def build_record(client, node, account, state, viewer, threads):
    """The dashboard record for one PR node, built by azure-cli.py's own
    to_record, with GitHub's own location fields over it."""
    repo = node.get("repository") or {}
    owner = (repo.get("owner") or {}).get("login") or ""
    name = repo.get("name") or ""
    ado = ado_pr(node)
    login, me = viewer.get("login") or "", _name(viewer)
    if threads is None:
        counts, others = (None, None, None, None, None), (-1, -1)
    else:
        countable = [t for t in threads if not t.get("conversation")]
        active, total, my_active, _, _ = core.count_threads(lambda: countable, login)
        m_threads, m_total = mention_counts(threads, login)
        counts = (active, total, my_active, m_threads, m_total)
        others = core.count_others_comments(lambda: threads, login)
    rollup = ((((node.get("commits") or {}).get("nodes") or [{}])[0] or {}).get("commit") or {}).get(
        "statusCheckRollup") or {}
    missing = [r["displayName"] for r in ado["reviewers"] if not r["vote"]]
    build = (BUILD.get(rollup.get("state"), "none"), None, (node.get("url") or "") + "/checks", [], missing)
    acct = _Acct(client.api_url, owner, getattr(account, "clones_dir", None), None)
    rec = core.to_record(ado, acct, state, counts, build, login, me)
    rec["othersComments"], rec["othersCommentsInMyThreads"] = others
    # Changes requested reads as a cross here, as on GitHub (Azure's -5 is
    # a "~", waiting for the author) - the same marks hosts.lua draws.
    rec["reviewerSummary"] = " ".join(
        {10: "✓", -5: "✗"}.get(r["vote"], "·") + core._surname(r["displayName"])
        for r in ado["reviewers"] if not r.get("isContainer"))
    rec.update({
        "host": "github",
        "key": pr_key(owner, name, node.get("number")),
        "org": client.api_url,
        "project": owner,
        "repo": name,
        "url": node.get("url") or "",
        "cloneUrl": (repo.get("url") or "") + ".git",
        "queuePosition": -1,
        "caps": {"merge_methods": merge_methods(repo),
                 "auto_complete": bool(repo.get("autoMergeAllowed")),
                 "delete_branch_on_merge": bool(repo.get("deleteBranchOnMerge"))},
    })
    return rec


def owner_filter(client, owner):
    if not owner:
        return ""
    data = client.graphql(OWNER_QUERY, {"login": owner})
    kind = ((data.get("repositoryOwner") or {}).get("__typename")) or "User"
    return ("org:" if kind == "Organization" else "user:") + owner


def list_records(account, env=None, client=None):
    """One GitHub account's dashboard records: PRs I'm asked to review or
    have reviewed (state worked out exactly as for Azure), then my own."""
    env = os.environ if env is None else env
    if client is None:
        token = account_token(account)
        if not token:
            raise RuntimeError("GitHub account {0} has no token: set pat_file, or sign in with `gh auth login`"
                               .format(account.label()))
        client = Client(account.api_url, token)
    data = client.graphql(LIST_QUERY, search_queries(owner_filter(client, account.owner)))
    viewer = data.get("viewer") or {}
    login = viewer.get("login") or ""
    source = core.AzureDevOpsPullRequestSource.__new__(core.AzureDevOpsPullRequestSource)
    source.env = env
    seen, records = set(), []

    def nodes(alias):
        return [n for n in ((data.get(alias) or {}).get("nodes") or []) if n and n.get("number")]

    def add(node, state, threads):
        records.append(build_record(client, node, account, state, viewer, threads))

    def thread_loader(node):
        holder = {}

        def load():
            if "v" not in holder:
                repo = node.get("repository") or {}
                holder["v"] = fetch_threads(client, (repo.get("owner") or {}).get("login"), repo.get("name"),
                                            node["number"], node.get("updatedAt"))
            return holder["v"]
        return load

    for node in nodes("requested") + nodes("reviewed"):
        k = (node.get("url"))
        if k in seen:
            continue
        seen.add(k)
        if not node.get("headRef") and not node.get("isCrossRepository"):
            continue  # its branch is gone: no diff to show
        load = thread_loader(node)
        state = source._compute_state(ado_pr(node), login, account, load, lambda: True)
        if state is None:
            continue
        add(node, state, _safe(load))
    for node in nodes("created"):
        if node.get("url") in seen:
            continue
        seen.add(node.get("url"))
        add(node, "Created", _safe(thread_loader(node)))
    return records


def _safe(load):
    try:
        return load()
    except Exception:  # noqa: BLE001 - counts show as unknown, like Azure's
        return None


def whoami(client):
    v = client.graphql("query { viewer { login name } }").get("viewer") or {}
    return v.get("login"), _name(v)


STATUS = {"OPEN": "active", "MERGED": "completed", "CLOSED": "abandoned"}


THREAD_NODES_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    reviewThreads(first: 100) { nodes { id comments(first: 1) { nodes { databaseId } } } } } }
}
"""

RESOLVE = "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }"
UNRESOLVE = "mutation($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { id } } }"

# Review events by vote (see the module comment); 0 dismisses my review.
REVIEW_EVENTS = {"10": "APPROVE", "-5": "REQUEST_CHANGES"}

REVIEW_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    id headRefOid
    reviews(states: PENDING, first: 5) { nodes { id viewerDidAuthor } }
    reviewThreads(first: 100) { nodes { id comments(first: 1) { nodes { databaseId } } } } } }
}
"""

ADD_REVIEW = """mutation($pr: ID!, $oid: GitObjectID!) {
  addPullRequestReview(input: {pullRequestId: $pr, commitOID: $oid}) { pullRequestReview { id } } }"""
ADD_THREAD = """mutation($input: AddPullRequestReviewThreadInput!) {
  addPullRequestReviewThread(input: $input) { thread { id } } }"""
ADD_REPLY = """mutation($input: AddPullRequestReviewThreadReplyInput!) {
  addPullRequestReviewThreadReply(input: $input) { comment { id } } }"""
SUBMIT_REVIEW = """mutation($id: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: {pullRequestReviewId: $id, event: $event, body: $body}) {
    pullRequestReview { id } } }"""
DELETE_REVIEW = """mutation($id: ID!) {
  deletePullRequestReview(input: {pullRequestReviewId: $id}) { pullRequestReview { id } } }"""

# Statuses that leave a conversation open; anything else resolves it.
OPEN_STATUSES = ("active", "pending")


# ---------------------------------------------------------------------------
# Merging: what stands in the way, read fresh just before gm and --complete
# ---------------------------------------------------------------------------
#
# The list's search can't ask each check whether it's required (isRequired
# wants the PR's number), and mergeStateStatus goes stale within minutes,
# so --get-pr, --complete and --auto-complete each read it here.

MERGE_STATE_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    deleteBranchOnMerge autoMergeAllowed mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
    defaultBranchRef { name }
    pullRequest(number: $number) {
      id number state isDraft headRefName headRefOid baseRefName isCrossRepository
      mergeable mergeStateStatus reviewDecision
      autoMergeRequest { mergeMethod }
      commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { name status conclusion %(req)s }
        ... on StatusContext { context state %(req)s } } } } } } } } }
}
"""

# Some Enterprise Server versions don't know isRequired(pullRequestNumber:):
# without it the checks are shown, just not which of them are required.
_REQUIRED = "isRequired(pullRequestNumber: $number)"

CHECK_OK = ("SUCCESS", "NEUTRAL", "SKIPPED")
CHECK_FAILED = ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE")

MERGE_METHOD_ENUM = {"squash": "SQUASH", "merge": "MERGE", "rebase": "REBASE"}

ENABLE_AUTO_MERGE = """mutation($id: ID!, $method: PullRequestMergeMethod!, $oid: GitObjectID) {
  enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method, expectedHeadOid: $oid}) {
    pullRequest { id } } }"""
DISABLE_AUTO_MERGE = """mutation($id: ID!) {
  disablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { id } } }"""


def _check(node):
    """One rollup context as {name, state: ok|failed|pending, required}
    (required None when GitHub wasn't asked)."""
    node = node or {}
    if node.get("__typename") == "StatusContext":
        name, s = node.get("context") or "", node.get("state") or ""
        state = "ok" if s == "SUCCESS" else "failed" if s in ("FAILURE", "ERROR") else "pending"
    else:
        name = node.get("name") or ""
        if node.get("status") != "COMPLETED":
            state = "pending"
        else:
            c = node.get("conclusion") or ""
            state = "ok" if c in CHECK_OK else "failed" if c in CHECK_FAILED else "pending"
    return {"name": name, "state": state, "required": node.get("isRequired")}


def mergeability(repo, pr):
    """What the merge dialog and --complete go by, from MERGE_STATE_QUERY's
    repository and pullRequest: {status, blockers, warnings, checks,
    conflict, deleteBranchOnMerge, autoMergeAllowed, autoMerge, base,
    defaultBranch}. Blockers are reasons GitHub would refuse the merge, in
    words; warnings don't stop it (a failing check nobody requires)."""
    repo, pr = repo or {}, pr or {}
    status = pr.get("mergeStateStatus") or "UNKNOWN"
    base = pr.get("baseRefName") or ""
    rollup = ((((pr.get("commits") or {}).get("nodes") or [{}])[0] or {}).get("commit") or {}).get(
        "statusCheckRollup") or {}
    checks = [_check(n) for n in ((rollup.get("contexts") or {}).get("nodes") or []) if n]
    blockers, warnings = [], []
    conflict = status == "DIRTY" or pr.get("mergeable") == "CONFLICTING"
    if pr.get("state") and pr.get("state") != "OPEN":
        blockers.append("it's already {0}".format("merged" if pr.get("state") == "MERGED" else "closed"))
    if conflict:
        blockers.append("merge conflict with {0}".format(base))
    if status == "DRAFT" or pr.get("isDraft"):
        blockers.append("it's a draft")
    if status == "BEHIND":
        blockers.append("{0} has moved on; the branch must be brought up to date first".format(base))
    if status == "UNKNOWN" and not blockers:
        blockers.append("GitHub hasn't worked out mergeability yet, try again in a moment")
    if status == "BLOCKED":
        known = any(c["required"] is not None for c in checks)
        why = []
        for c in checks:
            if c["state"] == "ok" or (known and not c["required"]):
                continue
            word = "required check" if c["required"] else "check"
            why.append("{0} `{1}` {2}".format(word, c["name"], "failed" if c["state"] == "failed" else
                                              "hasn't finished"))
        decision = pr.get("reviewDecision")
        if decision == "REVIEW_REQUIRED":
            why.append("needs an approving review")
        elif decision == "CHANGES_REQUESTED":
            why.append("changes requested")
        blockers.extend(why or ["blocked by {0}'s branch protection (e.g. unresolved conversations, signed "
                                "commits)".format(base)])
    for c in checks:
        if c["state"] == "failed" and c["required"] is False:
            warnings.append("check `{0}` failed (not required)".format(c["name"]))
    if status == "UNSTABLE" and not warnings:
        warnings.append("some checks failed (not required)")
    return {
        "status": status, "blockers": blockers, "warnings": warnings, "checks": checks, "conflict": conflict,
        "deleteBranchOnMerge": bool(repo.get("deleteBranchOnMerge")),
        "autoMergeAllowed": bool(repo.get("autoMergeAllowed")),
        "autoMerge": bool(pr.get("autoMergeRequest")),
        "base": base, "defaultBranch": ((repo.get("defaultBranchRef") or {}).get("name")) or "",
    }


def _blank(text):
    return text is None or not str(text).strip()


def _uint(s):
    return isinstance(s, str) and s.isdigit()


# ---------------------------------------------------------------------------
# Closing keywords: how a PR links an issue
# ---------------------------------------------------------------------------
#
# GitHub has no call that links an existing PR to an issue; a closing
# keyword in the PR's body does (and closes the issue when the PR merges
# into the default branch). github_issues.py's link-pr/unlink-pr and
# --create-pr's work items all write and read these lines.

CLOSING_WORDS = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"


def _issue_ref(io, ir, n, po, pr):
    """How PR po/pr's body names issue io/ir#n: #n in the same repository."""
    same = (io or "").lower() == (po or "").lower() and (ir or "").lower() == (pr or "").lower()
    return "#{0}".format(n) if same else "{0}/{1}#{2}".format(io, ir, n)


def _closing_re(io, ir, n, po, pr):
    refs = {re.escape(_issue_ref(io, ir, n, po, pr)), re.escape("{0}/{1}#{2}".format(io, ir, n))}
    return re.compile(r"^[ \t]*{0}:?[ \t]+(?:{1})[ \t]*\.?[ \t]*$".format(CLOSING_WORDS, "|".join(refs)),
                      re.IGNORECASE | re.MULTILINE)


def closing_line(io, ir, n, po, pr):
    return "Closes " + _issue_ref(io, ir, n, po, pr)


def closes(body, io, ir, n, po, pr):
    """Whether `body` already has a closing line for the issue."""
    return bool(_closing_re(io, ir, n, po, pr).search(body or ""))


def without_closing(body, io, ir, n, po, pr):
    """`body` minus its closing lines for the issue (and the blank lines
    that only led up to them at the end)."""
    out = _closing_re(io, ir, n, po, pr).sub("", body or "")
    out = re.sub(r"\n{3,}", "\n\n", out)
    return out.rstrip() if out.strip() else ""


def default_branch_note(pull):
    """A REST pull's note when GitHub won't honour its closing keywords:
    it isn't into the repository's default branch."""
    base = pull.get("base") or {}
    default = ((base.get("repo") or {}).get("default_branch")) or ""
    if default and base.get("ref") and base.get("ref") != default:
        return ("GitHub links (and closes) issues only from pull requests into {0}; this one is into {1}, so the "
                "Closes line won't link it until it is retargeted").format(default, base.get("ref"))
    return ""


CLOSING_ISSUES_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    closingIssuesReferences(first: 50) { nodes {
      number title state url repository { name owner { login } }
      assignees(first: 10) { nodes { login } }
      projectItems(first: 5) { nodes { fieldValueByName(name: "Status") {
        ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } } }
}
"""


class Actions(object):
    """The PR actions for a GitHub PR, answering azure-cli.py's PR_ACTION
    flags with the same output (the same one-line messages on success)."""

    def __init__(self, account, env, client=None):
        self.account = account
        self.owner = env.get("AZVICLI_PROJECT") or ""
        self.repo = env.get("AZVICLI_REPO") or ""
        self.pr = env.get("AZVICLI_PR") or ""
        self.client = client
        self.sleep = time.sleep  # merge_state's wait for GitHub to finish computing (tests swap it)

    def ensure_client(self):
        if self.client is None:
            token = account_token(self.account)
            if not token:
                import sys
                print("No GitHub token: set pat_file on the account, or sign in with `gh auth login`.",
                      file=sys.stderr)
                return False
            self.client = Client(self.account.api_url, token)
        return True

    def _vars(self):
        return {"owner": self.owner, "name": self.repo, "number": int(self.pr)}

    def threads(self):
        print(json.dumps({"count": 0, "value": fetch_threads(self.client, self.owner, self.repo, self.pr)},
                         ensure_ascii=False))
        return 0

    def iterations(self):
        data = self.client.graphql(ITERATIONS_QUERY, self._vars())
        pr = ((data.get("repository") or {}).get("pullRequest")) or {}
        print(json.dumps(ado_iterations(pr, (data.get("viewer") or {}).get("login")), ensure_ascii=False))
        return 0

    # -- writes ----------------------------------------------------------

    def _repo(self, path):
        return "/repos/{0}/{1}{2}".format(urllib.parse.quote(self.owner, safe=""),
                                          urllib.parse.quote(self.repo, safe=""), path)

    def _head(self):
        return ((self.client.rest("GET", self._repo("/pulls/" + self.pr)) or {}).get("head") or {}).get("sha")

    def post_inline(self, path, side, line_s, text, end_s=""):
        """A comment on one line, or on lines line..end, of the right (new)
        or left (old) side. GitHub takes these only on lines in the diff's
        hunks; elsewhere it answers 422, passed on as the error."""
        if not path or not _uint(line_s) or line_s == "0":
            print("Invalid line.")
            return 1
        if side not in ("R", "L"):
            print("Invalid side.")
            return 1
        if _blank(text):
            print("Cancelled.")
            return 0
        line = int(line_s)
        end = int(end_s) if _uint(end_s) else None
        gh_side = "RIGHT" if side == "R" else "LEFT"
        data = {"body": text, "commit_id": self._head(), "path": path, "side": gh_side}
        if end is not None and end > line:
            data.update({"start_line": line, "start_side": gh_side, "line": end})
        else:
            data["line"] = line
        try:
            self.client.rest("POST", self._repo("/pulls/{0}/comments".format(self.pr)), data)
        except GitHubHttpError as e:
            if e.status == 422 and "part of the diff" in str(e):
                import sys
                print("GitHub takes a line comment only on a changed line or the few lines around one - "
                      "that line is outside the diff's hunks. A file comment (on the file list) works anywhere.",
                      file=sys.stderr)
                return 1
            raise
        print("Comment posted.")
        return 0

    def post_file_comment(self, path, text):
        if not path:
            print("No file selected.")
            return 1
        if _blank(text):
            print("Cancelled.")
            return 0
        self.client.rest("POST", self._repo("/pulls/{0}/comments".format(self.pr)),
                         {"body": text, "commit_id": self._head(), "path": path, "subject_type": "file"})
        print("Comment posted.")
        return 0

    def post_pr_comment(self, text):
        if _blank(text):
            print("Cancelled.")
            return 0
        self.client.rest("POST", self._repo("/issues/{0}/comments".format(self.pr)), {"body": text})
        print("Comment posted.")
        return 0

    def post_reply(self, thread_id, text):
        """A reply in a review thread (its id is its first comment's), or -
        thread 0, the Conversation tab - a new comment there."""
        if not _uint(thread_id):
            print("Invalid thread id: '{0}'".format(thread_id))
            return 1
        if _blank(text):
            print("Cancelled.")
            return 0
        if thread_id == "0":
            self.client.rest("POST", self._repo("/issues/{0}/comments".format(self.pr)), {"body": text})
        else:
            self.client.rest("POST", self._repo("/pulls/{0}/comments/{1}/replies".format(self.pr, thread_id)),
                             {"body": text})
        print("Reply posted.")
        return 0

    def _comment_path(self, thread_id, comment_id):
        kind = "issues" if thread_id == "0" else "pulls"
        return self._repo("/{0}/comments/{1}".format(kind, comment_id))

    def edit_comment(self, thread_id, comment_id, text):
        if not _uint(thread_id) or not _uint(comment_id):
            print("Invalid thread/comment id.")
            return 1
        if _blank(text):
            print("Cancelled.")
            return 0
        self.client.rest("PATCH", self._comment_path(thread_id, comment_id), {"body": text})
        print("Comment {0} (thread {1}) updated.".format(comment_id, thread_id))
        return 0

    def delete_comment(self, thread_id, comment_id):
        if not _uint(thread_id) or not _uint(comment_id):
            print("Invalid thread/comment id.")
            return 1
        self.client.rest("DELETE", self._comment_path(thread_id, comment_id))
        print("Comment {0} (thread {1}) deleted.".format(comment_id, thread_id))
        return 0

    def set_thread_status(self, thread_id, status):
        """Resolves the conversation, or (active/pending) opens it again."""
        if not _uint(thread_id):
            print("Invalid thread id: '{0}'".format(thread_id))
            return 1
        if thread_id == "0":
            print("The Conversation tab isn't a thread anyone resolves.")
            return 1
        data = self.client.graphql(THREAD_NODES_QUERY, self._vars())
        nodes = (((data.get("repository") or {}).get("pullRequest") or {}).get("reviewThreads") or {}).get(
            "nodes") or []
        node = next((n.get("id") for n in nodes
                     if str((((n.get("comments") or {}).get("nodes") or [{}])[0] or {}).get("databaseId")) == thread_id),
                    None)
        if not node:
            print("Thread {0} isn't on this pull request.".format(thread_id))
            return 1
        reopen = (status or "").lower() in OPEN_STATUSES
        self.client.graphql(UNRESOLVE if reopen else RESOLVE, {"id": node})
        print("Thread {0} set to {1}.".format(thread_id, "active" if reopen else "fixed"))
        return 0

    def set_vote(self, vote, body=""):
        """10 approves, -5 requests changes (GitHub wants a reason: `body`,
        else a stock one), 0 dismisses my latest approving/requesting
        review - which GitHub allows only with write access to the repo."""
        if vote == "0":
            return self._dismiss_my_review()
        event = REVIEW_EVENTS.get(vote)
        if not event:
            print("Invalid vote for GitHub: '{0}' (10 approve, -5 request changes, 0 dismiss)".format(vote))
            return 1
        data = {"event": event, "commit_id": self._head()}
        if not _blank(body):
            data["body"] = body
        elif event == "REQUEST_CHANGES":
            data["body"] = "Changes requested."
        self.client.rest("POST", self._repo("/pulls/{0}/reviews".format(self.pr)), data)
        print("Vote set to {0}.".format(vote))
        return 0

    def _dismiss_my_review(self):
        me = (self.client.rest("GET", "/user") or {}).get("login")
        reviews = self.client.rest("GET", self._repo("/pulls/{0}/reviews?per_page=100".format(self.pr))) or []
        mine = [r for r in reviews if ((r or {}).get("user") or {}).get("login") == me
                and (r or {}).get("state") in ("APPROVED", "CHANGES_REQUESTED")]
        if not mine:
            print("Vote set to 0.")  # nothing of mine stands: already "no vote"
            return 0
        self.client.rest("PUT", self._repo("/pulls/{0}/reviews/{1}/dismissals".format(self.pr, mine[-1]["id"])),
                         {"message": "Dismissed by its author.", "event": "DISMISS"})
        print("Vote set to 0.")
        return 0

    def submit_review(self, payload_json):
        """--submit-review: gS's whole queue as one GitHub review -
        payload {event: "10" | "-5" | "comment", body, items: [argv, ...]}
        (review/batch.lua's review_payload), each item the --post /
        --file-comment / --reply argv it would have gone out as alone. A
        pending review gets every comment, then is submitted with the
        verdict; when any step fails the pending review is deleted, so the
        queue stays whole on the Lua side and nothing has half-landed."""
        try:
            payload = json.loads(payload_json or "")
        except ValueError:
            print("--submit-review needs a JSON payload")
            return 1
        event = {"10": "APPROVE", "-5": "REQUEST_CHANGES"}.get(str(payload.get("event")), "COMMENT")
        body = payload.get("body") or ""
        if event == "REQUEST_CHANGES" and _blank(body):
            body = "Changes requested."
        data = self.client.graphql(REVIEW_QUERY, self._vars())
        pr = ((data.get("repository") or {}).get("pullRequest")) or {}
        threads = {}
        for n in ((pr.get("reviewThreads") or {}).get("nodes") or []):
            first = (((n.get("comments") or {}).get("nodes") or [{}])[0] or {}).get("databaseId")
            threads[str(first)] = n.get("id")
        inputs = []
        for args in payload.get("items") or []:
            step = self._review_step(args, threads)
            if isinstance(step, str):
                print(step)
                return 1
            inputs.append(step)
        # A review of mine already pending (started on github.com, say) is
        # the one these join - GitHub allows one per person per PR.
        mine = next((n.get("id") for n in ((pr.get("reviews") or {}).get("nodes") or []) if n.get("viewerDidAuthor")),
                    None)
        review = mine or ((self.client.graphql(ADD_REVIEW, {"pr": pr.get("id"), "oid": pr.get("headRefOid")})
                           .get("addPullRequestReview") or {}).get("pullRequestReview") or {}).get("id")
        try:
            for mutation, fields in inputs:
                fields["pullRequestReviewId"] = review
                self.client.graphql(mutation, {"input": fields})
            self.client.graphql(SUBMIT_REVIEW, {"id": review, "event": event, "body": body or None})
        except Exception:
            if not mine:
                try:
                    self.client.graphql(DELETE_REVIEW, {"id": review})
                except Exception:  # noqa: BLE001 - the original error is the one to report
                    pass
            raise
        n = len(inputs)
        print("Review submitted ({0} comment{1}).".format(n, "" if n == 1 else "s"))
        return 0

    def _review_step(self, args, threads):
        """(mutation, input fields) for one queued argv, or an error string."""
        if not args:
            return "Empty review item."
        flag = args[0]
        a = list(args[1:]) + [""] * 5
        if flag == "--post":
            path, side, line_s, text, end_s = a[0], a[1], a[2], a[3], a[4]
            if not path or not _uint(line_s) or side not in ("R", "L"):
                return "Invalid line comment in the review: {0}".format(json.dumps(args))
            gh_side = "RIGHT" if side == "R" else "LEFT"
            fields = {"path": path, "body": text, "line": int(line_s), "side": gh_side, "subjectType": "LINE"}
            if _uint(end_s) and int(end_s) > int(line_s):
                fields.update({"startLine": int(line_s), "startSide": gh_side, "line": int(end_s)})
            return (ADD_THREAD, fields)
        if flag == "--file-comment":
            return (ADD_THREAD, {"path": a[0], "body": a[1], "subjectType": "FILE"})
        if flag == "--reply":
            node = threads.get(a[0])
            if not node:
                return "Thread {0} isn't on this pull request.".format(a[0])
            return (ADD_REPLY, {"pullRequestReviewThreadId": node, "body": a[1]})
        return "{0} can't be part of a review.".format(flag)

    def work_items(self):
        """--work-items: the issues this PR closes (its closing keywords and
        the links made on github.com), one NDJSON line each in the Azure
        record's shape plus key/repo/host - the PR's badge and gW."""
        data = self.client.graphql(CLOSING_ISSUES_QUERY, self._vars())
        pr = ((data.get("repository") or {}).get("pullRequest")) or {}
        for n in ((pr.get("closingIssuesReferences") or {}).get("nodes") or []):
            if not n:
                continue
            r = n.get("repository") or {}
            owner, name = (r.get("owner") or {}).get("login") or "", r.get("name") or ""
            status = next((((i or {}).get("fieldValueByName") or {}).get("name")
                           for i in ((n.get("projectItems") or {}).get("nodes") or [])
                           if ((i or {}).get("fieldValueByName") or {}).get("name")), None)
            state = "Closed" if n.get("state") == "CLOSED" else (status or "No Status")
            print(json.dumps({"id": n.get("number"), "type": "Issue", "state": state, "title": n.get("title") or "",
                              "assignedTo": ", ".join((a or {}).get("login") or ""
                                                      for a in ((n.get("assignees") or {}).get("nodes") or [])),
                              "url": n.get("url") or "", "repo": name, "key": pr_key(owner, name, n.get("number")),
                              "host": "github"}, ensure_ascii=False))
        return 0

    def create_pr(self, source, target, title, description="", work_items="", draft="false"):
        """--create-pr: opens a PR from `source` into `target` in this
        repository (AZVICLI_REPO under AZVICLI_PROJECT), its body ending in a
        "Closes #n" line per issue in `work_items` (comma-separated numbers,
        owner/repo#n or owner~repo~n). Prints {"id", "url", "key"} plus
        "note" when GitHub won't honour those lines (not the default
        branch)."""
        import sys
        if not source or not target or _blank(title):
            print("create-pr needs <source> <target> <title>", file=sys.stderr)
            return 1
        strip = lambda b: b[len("refs/heads/"):] if b.startswith("refs/heads/") else b  # noqa: E731
        body = (description or "").rstrip()
        lines = []
        for w in (work_items or "").split(","):
            w = w.strip().lstrip("#")
            m = re.match(r"^(?:([^/~\s]+)[/~]([^#~\s]+)[#~])?(\d+)$", w)
            if not m:
                continue
            io, ir = (m.group(1), m.group(2)) if m.group(1) else (self.owner, self.repo)
            if not closes(body, io, ir, m.group(3), self.owner, self.repo):
                lines.append(closing_line(io, ir, m.group(3), self.owner, self.repo))
        if lines:
            body = (body + "\n\n" if body else "") + "\n".join(lines)
        made = self.client.rest("POST", self._repo("/pulls"), {
            "title": title, "head": strip(source), "base": strip(target), "body": body,
            "draft": str(draft).lower() == "true"}) or {}
        number = made.get("number")
        if number is None:
            print("unexpected response: " + json.dumps(made)[:400], file=sys.stderr)
            return 2
        out = {"id": number, "url": made.get("html_url") or "", "key": pr_key(self.owner, self.repo, number)}
        note = default_branch_note(made) if lines else ""
        if note:
            out["note"] = note
        print(json.dumps(out, ensure_ascii=False))
        return 0

    def get_pr(self):
        data = self.client.graphql(PR_QUERY, self._vars())
        node = ((data.get("repository") or {}).get("pullRequest")) or {}
        rec = build_record(self.client, node, self.account, STATUS.get(node.get("state"), "active"),
                           data.get("viewer") or {}, None)
        # What gm shows and goes by; without it gm falls back to the record.
        state = _safe(lambda: self.merge_state(retry=False))
        if state is not None:
            rec["mergeability"] = mergeability(*state)
        print(json.dumps(rec, ensure_ascii=False))
        return 0

    # -- merging ---------------------------------------------------------

    def merge_state(self, retry=True):
        """(repository, pullRequest) from MERGE_STATE_QUERY. While GitHub
        is still computing (UNKNOWN) it's asked once more, `retry`ing."""
        def ask():
            try:
                data = self.client.graphql(MERGE_STATE_QUERY % {"req": _REQUIRED}, self._vars())
            except RuntimeError as e:
                if "isRequired" not in str(e):
                    raise
                data = self.client.graphql(MERGE_STATE_QUERY % {"req": ""}, self._vars())
            repo = data.get("repository") or {}
            return repo, repo.get("pullRequest") or {}
        repo, pr = ask()
        if retry and (pr.get("mergeStateStatus") or "UNKNOWN") == "UNKNOWN":
            self.sleep(2)
            repo, pr = ask()
        return repo, pr

    def _allowed(self, repo, method):
        """None when the repo allows `method`, else the refusal."""
        keys = [m["key"] for m in merge_methods(repo)]
        if method in keys:
            return None
        return "{0} isn't allowed on {1}/{2}: {3}".format(method or "(none)", self.owner, self.repo,
                                                          ", ".join(keys) or "no merge method")

    def complete(self, method, delete_branch="true"):
        """--complete <squash|merge|rebase> [delete]: merges the PR as it was
        seen (sha = its head, so a push in between isn't merged unseen) into
        whatever its base is, then deletes the head branch if asked and it's
        in this repository. Refuses, saying why, when GitHub would."""
        import sys
        repo, pr = self.merge_state()
        refusal = self._allowed(repo, method)
        if refusal:
            print(refusal + ".", file=sys.stderr)
            return 1
        state = mergeability(repo, pr)
        if state["blockers"]:
            print("Can't merge PR #{0}: {1}.".format(self.pr, "; ".join(state["blockers"])), file=sys.stderr)
            return 1
        try:
            self.client.rest("PUT", self._repo("/pulls/{0}/merge".format(self.pr)),
                             {"merge_method": method, "sha": pr.get("headRefOid")})
        except GitHubHttpError as e:
            if e.status == 409:
                print("PR #{0}'s branch moved since it was checked; reopen gm to see the new head.".format(self.pr),
                      file=sys.stderr)
                return 1
            if e.status == 405:
                print("GitHub won't merge PR #{0}: {1}".format(self.pr, _error_text(e.body)), file=sys.stderr)
                return 1
            raise
        done = "PR #{0} merged ({1})".format(self.pr, method)
        head = pr.get("headRefName") or ""
        if str(delete_branch).lower() != "true" or not head:
            print(done + ".")
            return 0
        if pr.get("isCrossRepository"):
            print(done + "; its branch is in a fork, so it stays.")
            return 0
        try:
            self.client.rest("DELETE", self._repo("/git/refs/heads/" + urllib.parse.quote(head, safe="/")))
        except GitHubHttpError as e:
            # The repo's own "delete head branches" got there first.
            if not (e.status == 422 and "does not exist" in str(e)):
                print("{0}, but its branch {1} couldn't be deleted: {2}".format(done, head, e))
                return 0
        except Exception as e:  # noqa: BLE001 - the merge stands; say what didn't happen
            print("{0}, but its branch {1} couldn't be deleted: {2}".format(done, head, e))
            return 0
        print("{0}; branch {1} deleted.".format(done, head))
        return 0

    def auto_merge(self, mode, method=""):
        """--auto-complete on <method> | off. GitHub has no per-PR branch
        deletion for auto-merge: the repository's "Automatically delete head
        branches" decides, and the answer says which way it's set."""
        import sys
        repo, pr = self.merge_state(retry=False)
        if (mode or "").lower() == "off":
            if not pr.get("autoMergeRequest"):
                print("Auto-merge wasn't on for PR #{0}.".format(self.pr))
                return 0
            self.client.graphql(DISABLE_AUTO_MERGE, {"id": pr.get("id")})
            print("Auto-merge disabled for PR #{0}.".format(self.pr))
            return 0
        if (mode or "").lower() != "on":
            print("--auto-complete takes on or off.", file=sys.stderr)
            return 1
        if not repo.get("autoMergeAllowed"):
            print("Auto-merge isn't allowed on {0}/{1} (its settings).".format(self.owner, self.repo), file=sys.stderr)
            return 1
        keys = [m["key"] for m in merge_methods(repo)]
        method = method or ("squash" if "squash" in keys else (keys or [""])[0])
        refusal = self._allowed(repo, method)
        if refusal:
            print(refusal + ".", file=sys.stderr)
            return 1
        if mergeability(repo, pr)["conflict"]:
            print("Can't set auto-merge on PR #{0}: merge conflict with {1}.".format(self.pr, pr.get("baseRefName")),
                  file=sys.stderr)
            return 1
        try:
            self.client.graphql(ENABLE_AUTO_MERGE, {"id": pr.get("id"), "method": MERGE_METHOD_ENUM[method],
                                                    "oid": pr.get("headRefOid")})
        except RuntimeError as e:
            text = str(e)
            if "clean status" in text:
                print("PR #{0} can be merged now, there's nothing to wait for: merge it instead.".format(self.pr),
                      file=sys.stderr)
                return 1
            if "protected branch rules" in text or "branch protection" in text:
                print("Auto-merge needs {0} to require checks or reviews (branch protection); merge it instead."
                      .format(pr.get("baseRefName")), file=sys.stderr)
                return 1
            raise
        print("Auto-merge enabled for PR #{0} ({1}); the branch is deleted on merge only by the repository's own "
              "setting, which is {2}.".format(self.pr, method, "on" if repo.get("deleteBranchOnMerge") else "off"))
        return 0
