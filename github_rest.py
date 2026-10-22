"""github_rest.py: GitHub's REST API standing in for its GraphQL API.

github_host.py reads and writes GitHub through GraphQL. Where GraphQL is
refused - a proxy that only lets REST through (a Claude Code cloud
session's, say), or AZVICLI_GITHUB_REST=1 - each query has a builder here
that makes the same answer out of REST calls: the same `data` dict, in the
same shape, so github_host.py's converters (ado_pr, ado_threads,
ado_iterations, mergeability) read it unchanged.

What REST can't give:

- a user's display name comes from /users/<login>, cached for the
  process's life; a lookup that fails leaves the login;
- whether a review thread is resolved, and resolving one, exist only in
  GraphQL. A proxy may offer them as /pulls/<n>/ccr/... routes (Claude
  Code's does); those are used when they answer, else every thread reads
  as unresolved and resolving one says why it can't;
- turning auto-merge on or off: the same, through /pulls/<n>/ccr/auto_merge;
- which checks are required (GraphQL's isRequired) and the review
  decision: left out, which mergeability() already reads as "not known";
- "closes #n" links made on github.com, not in the body: only the body's
  closing lines are read.

Node ids: mutations take GraphQL node ids. Here a node id is a "rest:"
string carrying what the REST call needs - rest:pr:<owner>/<repo>/<n>,
rest:review:<owner>/<repo>/<n>/<review id or "new">, rest:thread:<owner>/
<repo>/<n>/<first comment id> - made by the read builders and taken apart
by the write ones.
"""

import itertools
import os
import re
import subprocess
import threading
import time
import urllib.parse

host = None


def bind(github_host):
    global host
    host = github_host


PER_PAGE = 100
MAX_PAGES = 10


def _q(s):
    return urllib.parse.quote(str(s), safe="")


def _repo_path(owner, name, rest=""):
    return "/repos/{0}/{1}{2}".format(_q(owner), _q(name), rest)


def _pages(client, path, key=None, limit=None):
    """Every item of a paged REST list (`key` names the list inside an
    object answer, as search's "items"), up to `limit`."""
    out = []
    sep = "&" if "?" in path else "?"
    for page in range(1, MAX_PAGES + 1):
        got = client.rest("GET", "{0}{1}per_page={2}&page={3}".format(path, sep, PER_PAGE, page)) or []
        items = (got.get(key) or []) if key else got
        if not isinstance(items, list):
            break
        out.extend(items)
        if len(items) < PER_PAGE or (limit and len(out) >= limit):
            break
    return out[:limit] if limit else out


def _up(s):
    return (s or "").upper()


# ---------------------------------------------------------------------------
# Caches: kept for the daemon's life, like github_host's threads cache
# ---------------------------------------------------------------------------

_lock = threading.Lock()
_names = {}        # (api_url, login) -> display name or None
_repos = {}        # (api_url, owner, name) -> (time, repo)
_nodes = {}        # (api_url, owner, name, number) -> (updated_at, node minus its rollup)
_rollups = {}      # (api_url, owner, name, sha) -> (time, rollup)
REPO_TTL = 300
ROLLUP_TTL = 60


def _cached(cache, key, ttl, load):
    now = time.monotonic()
    with _lock:
        hit = cache.get(key)
    if hit and now - hit[0] < ttl:
        return hit[1]
    value = load()
    with _lock:
        cache[key] = (now, value)
    return value


def display_name(client, login):
    if not login:
        return None
    key = (client.api_url, login)
    with _lock:
        if key in _names:
            return _names[key]
    try:
        name = (client.rest("GET", "/users/" + _q(login)) or {}).get("name") or None
    except Exception:  # noqa: BLE001 - the login stands in for the name
        name = None
    with _lock:
        _names[key] = name
    return name


def actor(client, user):
    """A REST user as GraphQL's `login ... on User { name }`."""
    login = (user or {}).get("login")
    if not login:
        return None
    return {"login": login, "name": display_name(client, login)}


def repo_info(client, owner, name):
    return _cached(_repos, (client.api_url, owner, name), REPO_TTL,
                   lambda: client.rest("GET", _repo_path(owner, name)) or {})


# ---------------------------------------------------------------------------
# Viewer and owners
# ---------------------------------------------------------------------------

def viewer(client, variables=None):
    me = client.rest("GET", "/user") or {}
    return {"viewer": {"login": me.get("login") or "", "name": me.get("name")}}


def repository_owner(client, variables):
    try:
        u = client.rest("GET", "/users/" + _q(variables["login"])) or {}
    except host.GitHubHttpError as e:
        if e.status in (403, 404):  # only search reads it; listing by repository goes by the owner itself
            return {"repositoryOwner": None}
        raise
    return {"repositoryOwner": {"__typename": "Organization" if u.get("type") == "Organization" else "User"}}


# ---------------------------------------------------------------------------
# Pull requests as PR_FIELDS nodes
# ---------------------------------------------------------------------------

def _latest_reviews(client, reviews):
    """(latestOpinionatedReviews, latestReviews) nodes from a PR's reviews,
    oldest first: each reviewer's latest approval or change request (gone
    once dismissed), and each one's latest submitted review of any kind."""
    opinion, latest = {}, {}
    for r in reviews:
        login = ((r or {}).get("user") or {}).get("login")
        state = (r or {}).get("state")
        if not login or state == "PENDING":
            continue
        latest[login] = r
        if state in ("APPROVED", "CHANGES_REQUESTED"):
            opinion[login] = r
        elif state == "DISMISSED":
            opinion.pop(login, None)

    def node(r):
        return {"state": r.get("state"), "author": actor(client, r.get("user")),
                "submittedAt": r.get("submitted_at"), "commit": {"oid": r.get("commit_id")}}
    return ([node(r) for r in opinion.values()], [node(r) for r in latest.values()])


def _rollup(client, owner, name, sha):
    """The head commit's checks and statuses as GraphQL's statusCheckRollup
    {state, contexts}: FAILURE when any failed, PENDING while any runs,
    else SUCCESS; None with neither."""
    if not sha:
        return None

    def load():
        runs = (client.rest("GET", _repo_path(owner, name, "/commits/{0}/check-runs?per_page=100".format(sha)))
                or {}).get("check_runs") or []
        status = client.rest("GET", _repo_path(owner, name, "/commits/{0}/status".format(sha))) or {}
        contexts = [{"__typename": "CheckRun", "name": r.get("name") or "", "status": _up(r.get("status")),
                     "conclusion": _up(r.get("conclusion")) or None} for r in runs]
        contexts += [{"__typename": "StatusContext", "context": s.get("context") or "", "state": _up(s.get("state"))}
                     for s in status.get("statuses") or []]
        if not contexts:
            return None
        states = []
        for c in contexts:
            if c["__typename"] == "StatusContext":
                states.append({"SUCCESS": "SUCCESS", "PENDING": "PENDING"}.get(c["state"], "FAILURE"))
            elif c["status"] != "COMPLETED":
                states.append("PENDING")
            elif c["conclusion"] in host.CHECK_FAILED:
                states.append("FAILURE")
            else:
                states.append("SUCCESS")
        state = "FAILURE" if "FAILURE" in states else "PENDING" if "PENDING" in states else "SUCCESS"
        return {"state": state, "contexts": {"nodes": contexts}}
    return _cached(_rollups, (client.api_url, owner, name, sha), ROLLUP_TTL, load)


def _branch_exists(client, owner, name, branch):
    try:
        client.rest("GET", _repo_path(owner, name, "/branches/" + _q(branch)))
        return True
    except host.GitHubHttpError as e:
        if e.status == 404:
            return False
        raise


def pr_node(client, owner, name, number, updated=None, check_branch=False):
    """One PR as a PR_FIELDS node (PR_QUERY's pullRequest). The parts that
    only change with the PR (its fields, reviews) are kept until its
    updated_at moves; the checks are read again after ROLLUP_TTL."""
    key = (client.api_url, owner, name, int(number))
    with _lock:
        hit = _nodes.get(key)
    if hit and updated and hit[0] == updated:
        node = dict(hit[1])
    else:
        node = _pr_node(client, owner, name, number, check_branch)
        with _lock:
            _nodes[key] = (node.get("updatedAt"), dict(node))
    sha = node.get("headRefOid")
    node["commits"] = {"nodes": [{"commit": {"statusCheckRollup": _rollup(client, owner, name, sha)}}]}
    return node


def _pr_node(client, owner, name, number, check_branch):
    p = client.rest("GET", _repo_path(owner, name, "/pulls/{0}".format(int(number)))) or {}
    head, base = p.get("head") or {}, p.get("base") or {}
    repo = repo_info(client, owner, name)
    head_repo = (head.get("repo") or {}).get("full_name")
    cross = not head_repo or head_repo.lower() != ((base.get("repo") or {}).get("full_name") or "").lower()
    head_ref = {"name": head.get("ref")}
    if check_branch and not cross and head.get("ref") and p.get("state") == "open":
        head_ref = head_ref if _branch_exists(client, owner, name, head.get("ref")) else None
    reviews = _pages(client, _repo_path(owner, name, "/pulls/{0}/reviews".format(int(number))))
    opinion, latest = _latest_reviews(client, reviews)
    requests = [{"requestedReviewer": dict({"__typename": "User"}, **(actor(client, u) or {}))}
                for u in p.get("requested_reviewers") or [] if (u or {}).get("login")]
    requests += [{"requestedReviewer": {"__typename": "Team", "slug": t.get("slug"), "name": t.get("name")}}
                 for t in p.get("requested_teams") or [] if t]
    auto = p.get("auto_merge")
    state = "MERGED" if p.get("merged_at") or p.get("merged") else "OPEN" if p.get("state") == "open" else "CLOSED"
    mergeable = p.get("mergeable")
    return {
        "id": "rest:pr:{0}/{1}/{2}".format(owner, name, int(number)),
        "number": p.get("number"), "title": p.get("title") or "", "url": p.get("html_url") or "",
        "body": p.get("body") or "", "isDraft": bool(p.get("draft")), "createdAt": p.get("created_at"),
        "updatedAt": p.get("updated_at"), "state": state,
        "headRefName": head.get("ref") or "", "baseRefName": base.get("ref") or "",
        "headRefOid": head.get("sha") or "", "baseRefOid": base.get("sha") or "",
        "isCrossRepository": cross, "headRef": head_ref,
        "repository": {"name": name, "url": repo.get("html_url") or "https://{0}/{1}/{2}".format(
                           host.web_host(client.api_url), owner, name),
                       "owner": {"login": owner},
                       "mergeCommitAllowed": repo.get("allow_merge_commit", True),
                       "squashMergeAllowed": repo.get("allow_squash_merge", True),
                       "rebaseMergeAllowed": repo.get("allow_rebase_merge", True),
                       "autoMergeAllowed": bool(repo.get("allow_auto_merge")),
                       "deleteBranchOnMerge": bool(repo.get("delete_branch_on_merge"))},
        "author": actor(client, p.get("user")),
        "mergeable": ("CONFLICTING" if p.get("mergeable_state") == "dirty" or mergeable is False
                      else "MERGEABLE" if mergeable else "UNKNOWN"),
        # A draft is "blocked" to REST, DRAFT to GraphQL (and mergeability).
        "mergeStateStatus": "DRAFT" if p.get("draft") else _up(p.get("mergeable_state")) or "UNKNOWN",
        "autoMergeRequest": ({"enabledBy": actor(client, auto.get("enabled_by")),
                              "mergeMethod": _up(auto.get("merge_method"))} if auto else None),
        "reviewRequests": {"nodes": requests},
        "latestOpinionatedReviews": {"nodes": opinion},
        "latestReviews": {"nodes": latest},
    }


_PR_URL = re.compile(r"/repos/([^/]+)/([^/]+)/(?:pulls|issues)/(\d+)$")


def _search(client, q):
    """search(query:, type: ISSUE, first: 50)'s PRs as (owner, name,
    number, updated_at)."""
    items = _pages(client, "/search/issues?q=" + urllib.parse.quote(q), key="items", limit=50)
    out = []
    for it in items:
        m = _PR_URL.search((it or {}).get("url") or "")
        if m and (it or {}).get("pull_request") is not None:
            out.append((urllib.parse.unquote(m.group(1)), urllib.parse.unquote(m.group(2)), int(m.group(3)),
                        it.get("updated_at")))
    return out


def list_prs(client, variables):
    """LIST_QUERY: viewer plus the requested / reviewed / created searches.
    Where search is refused too (a proxy that allows only repository
    routes), each known repository's open PRs, sorted into the three."""
    data = viewer(client)
    try:
        found = {alias: _search(client, variables[alias]) for alias in ("requested", "reviewed", "created")}
    except host.GitHubHttpError as e:
        if e.status not in (403, 404, 422):
            raise
        return by_repository(client, data)
    for alias, hits in found.items():
        data[alias] = {"nodes": [pr_node(client, owner, name, number, updated, check_branch=alias != "created")
                                 for owner, name, number, updated in hits]}
    return data


def by_repository(client, data):
    login = (data["viewer"].get("login") or "").lower()
    out = {"requested": [], "reviewed": [], "created": []}
    for owner, name in known_repositories(client):
        try:
            pulls = _pages(client, _repo_path(owner, name, "/pulls?state=open"), limit=50)
        except host.GitHubHttpError:
            continue  # not reachable from here: the others still list
        for p in pulls:
            if (p.get("base") or {}).get("repo", {}).get("archived"):
                continue
            created = ((p.get("user") or {}).get("login") or "").lower() == login
            asked = any(((u or {}).get("login") or "").lower() == login for u in p.get("requested_reviewers") or [])
            node = pr_node(client, owner, name, p.get("number"), p.get("updated_at"), check_branch=not created)
            reviewed = any(((n.get("author") or {}).get("login") or "").lower() == login
                           for n in node["latestReviews"]["nodes"])
            if created:
                out["created"].append(node)
            elif asked:
                out["requested"].append(node)
            elif reviewed:
                out["reviewed"].append(node)
    for alias, nodes in out.items():
        data[alias] = {"nodes": nodes}
    return data


_REMOTE = re.compile(r"^(?:https?://(?:[^@/]+@)?|ssh://(?:[^@/]+@)?|[^@/]+@)([^/:]+)[:/]([^/]+)/([^/]+?)(?:\.git)?/?$")


def known_repositories(client):
    """The repositories to list when search can't: AZVICLI_GITHUB_REPOS
    (owner/name, comma-separated), else every clone in the account's
    clones_dir whose origin is on this host (and under its owner:)."""
    env = os.environ.get("AZVICLI_GITHUB_REPOS") or ""
    if env.strip():
        return [tuple(r.strip().split("/", 1)) for r in env.split(",") if r.count("/") == 1]
    account = getattr(client, "account", None)
    root = os.path.expanduser(getattr(account, "clones_dir", None) or "")
    if not root or not os.path.isdir(root):
        return []
    want_host = host.web_host(client.api_url).lower()
    owner = (getattr(account, "owner", None) or "").lower()
    out = []
    for entry in sorted(os.listdir(root)):
        path = os.path.join(root, entry)
        if not os.path.exists(os.path.join(path, ".git")):
            continue
        try:
            url = subprocess.run(["git", "-C", path, "config", "--get", "remote.origin.url"], capture_output=True,
                                 text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            continue
        m = _REMOTE.match(url)
        if not m or m.group(1).lower() != want_host or (owner and m.group(2).lower() != owner):
            continue
        if (m.group(2), m.group(3)) not in out:
            out.append((m.group(2), m.group(3)))
    return out


def get_pr(client, variables):
    """PR_QUERY."""
    data = viewer(client)
    node = pr_node(client, variables["owner"], variables["name"], variables["number"])
    data["repository"] = {"pullRequest": node}
    return data


def pr_id(client, variables):
    """PR_NODE_QUERY."""
    return {"repository": {"pullRequest": {"id": "rest:pr:{0}/{1}/{2}".format(
        variables["owner"], variables["name"], int(variables["number"]))}}}


# ---------------------------------------------------------------------------
# Review threads
# ---------------------------------------------------------------------------

def _ccr_threads(client, owner, name, number):
    """{first comment id: resolved} from the proxy's review-threads route,
    or None where there's no such route (GitHub itself has none). Its
    shape isn't documented, so any of the likely spellings is taken."""
    try:
        got = client.rest("GET", _repo_path(owner, name, "/pulls/{0}/ccr/review_threads".format(int(number))))
    except host.GitHubHttpError:
        return None
    if isinstance(got, dict):
        got = got.get("review_threads") or got.get("threads") or got.get("nodes") or []
    if not isinstance(got, list):
        return None
    out = {}
    for t in got:
        if not isinstance(t, dict):
            continue
        resolved = next((t[k] for k in ("isResolved", "is_resolved", "resolved") if k in t), None)
        if resolved is None and isinstance(t.get("state"), str):
            resolved = t["state"].lower() == "resolved"
        comments = t.get("comments") or t.get("comment_ids")  # Claude Code's: {resolved, comment_ids, ...}
        if isinstance(comments, dict):
            comments = comments.get("nodes")
        ids = []
        for c in comments or []:
            if isinstance(c, dict):
                ids.append(c.get("databaseId") or c.get("database_id") or c.get("id"))
            else:
                ids.append(c)
        for k in ("first_comment_id", "root_comment_id", "comment_id"):
            if t.get(k):
                ids.insert(0, t[k])
        for i in ids:
            if isinstance(i, (int, str)) and str(i).isdigit():
                out[str(i)] = bool(resolved)
                break
    return out


def _comment_node(client, c):
    return {"databaseId": c.get("id"), "body": c.get("body") or "", "createdAt": c.get("created_at"),
            "author": actor(client, c.get("user"))}


def review_threads(client, owner, name, number):
    """reviewThreads nodes: the review comments grouped by the comment
    they reply to (GitHub points every reply at its thread's first)."""
    comments = _pages(client, _repo_path(owner, name, "/pulls/{0}/comments".format(int(number))))
    roots, replies = [], {}
    for c in comments:
        parent = c.get("in_reply_to_id")
        if parent:
            replies.setdefault(parent, []).append(c)
        else:
            roots.append(c)
    resolved = _ccr_threads(client, owner, name, number) or {}
    out = []
    for r in roots:
        file_level = (r.get("subject_type") or "").lower() == "file"
        line = r.get("line") or r.get("original_line")
        out.append({
            "id": "rest:thread:{0}/{1}/{2}/{3}".format(owner, name, int(number), r.get("id")),
            "isResolved": resolved.get(str(r.get("id")), False),
            "isOutdated": not file_level and r.get("line") is None,
            "path": r.get("path"), "line": line,
            "startLine": r.get("start_line") or r.get("original_start_line"),
            "diffSide": r.get("side") or "RIGHT", "startDiffSide": r.get("start_side"),
            "subjectType": "FILE" if file_level else "LINE",
            "comments": {"nodes": [_comment_node(client, c)
                                   for c in [r] + sorted(replies.get(r.get("id"), []),
                                                         key=lambda c: c.get("created_at") or "")]},
        })
    return out


def threads(client, variables):
    """THREADS_QUERY (and THREAD_NODES_QUERY: the same ids)."""
    owner, name, number = variables["owner"], variables["name"], variables["number"]
    general = _pages(client, _repo_path(owner, name, "/issues/{0}/comments".format(int(number))))
    return {"repository": {"pullRequest": {
        "reviewThreads": {"nodes": review_threads(client, owner, name, number)},
        "comments": {"nodes": [_comment_node(client, c) for c in general]}}}}


def _ccr_post(client, method, path, data=None, what=""):
    try:
        return client.rest(method, path, data)
    except host.GitHubHttpError as e:
        if e.status in (404, 405, 501):
            raise RuntimeError("{0} needs GitHub's GraphQL API, which isn't reachable from here".format(what))
        raise


def _parse(node_id, kind, parts):
    m = re.match(r"^rest:{0}:(.+)$".format(kind), node_id or "")
    if not m:
        raise RuntimeError("not a REST {0} id: {1}".format(kind, node_id))
    bits = m.group(1).split("/")
    if len(bits) != parts:
        raise RuntimeError("not a REST {0} id: {1}".format(kind, node_id))
    return bits


def set_resolved(client, variables, resolve):
    """RESOLVE / UNRESOLVE through the proxy's route, by the thread's first
    comment."""
    owner, name, number, comment = _parse(variables["id"], "thread", 4)
    _ccr_post(client, "POST", _repo_path(owner, name, "/pulls/{0}/ccr/comments/{1}/{2}".format(
        number, comment, "resolve" if resolve else "unresolve")), {}, "Resolving a conversation")
    return {}


# ---------------------------------------------------------------------------
# Pushes and reviews (ITERATIONS_QUERY)
# ---------------------------------------------------------------------------

def iterations(client, variables):
    owner, name, number = variables["owner"], variables["name"], int(variables["number"])
    commits = _pages(client, _repo_path(owner, name, "/pulls/{0}/commits".format(number)), limit=250)
    items = [{"__typename": "PullRequestCommit",
              "commit": {"oid": c.get("sha"), "committedDate": ((c.get("commit") or {}).get("committer") or {})
                         .get("date")}} for c in commits]
    for e in _pages(client, _repo_path(owner, name, "/issues/{0}/events".format(number))):
        if (e or {}).get("event") == "head_ref_force_pushed" and e.get("commit_id"):
            items.append({"__typename": "HeadRefForcePushedEvent", "createdAt": e.get("created_at"),
                          "afterCommit": {"oid": e.get("commit_id")}})
    reviews = _pages(client, _repo_path(owner, name, "/pulls/{0}/reviews".format(number)))
    nodes = [{"state": r.get("state"), "submittedAt": r.get("submitted_at"),
              "author": {"login": (r.get("user") or {}).get("login")}, "commit": {"oid": r.get("commit_id")}}
             for r in reviews]
    data = viewer(client)
    data["repository"] = {"pullRequest": {"timelineItems": {"nodes": items}, "reviews": {"nodes": nodes},
                                          "latestReviews": {"nodes": []}}}
    return data


# ---------------------------------------------------------------------------
# A batched review (gS): REVIEW_QUERY and its mutations
# ---------------------------------------------------------------------------
#
# GraphQL builds the review up: a pending review, a thread or reply at a
# time, then submit. REST takes a review whole - its line comments go in
# the one POST that submits it - and can't put a reply or a file comment
# in one. So ADD_REVIEW only starts a list, ADD_THREAD and ADD_REPLY add to
# it, and SUBMIT_REVIEW sends it: the review with its line comments first,
# then the file comments and replies one by one. Nothing lands before the
# submit; a failure after the review went in says which of the rest didn't.

_pending = {}
_review_ids = itertools.count(1)


def review_state(client, variables):
    owner, name, number = variables["owner"], variables["name"], int(variables["number"])
    me = (viewer(client)["viewer"] or {}).get("login")
    p = client.rest("GET", _repo_path(owner, name, "/pulls/{0}".format(number))) or {}
    reviews = _pages(client, _repo_path(owner, name, "/pulls/{0}/reviews".format(number)))
    mine = [r for r in reviews if r.get("state") == "PENDING" and (r.get("user") or {}).get("login") == me]
    if mine:
        raise RuntimeError("you have a review pending on GitHub for this pull request: submit or discard it there "
                           "first (REST can't add to it)")
    return {"repository": {"pullRequest": {
        "id": "rest:pr:{0}/{1}/{2}".format(owner, name, number), "headRefOid": (p.get("head") or {}).get("sha"),
        "reviews": {"nodes": []},
        "reviewThreads": {"nodes": [{"id": t["id"], "comments": {"nodes": t["comments"]["nodes"][:1]}}
                                    for t in review_threads(client, owner, name, number)]}}}}


def add_review(client, variables):
    owner, name, number = _parse(variables["pr"], "pr", 3)
    rid = "rest:review:{0}/{1}/{2}/new{3}".format(owner, name, number, next(_review_ids))
    with _lock:
        _pending[rid] = {"oid": variables.get("oid"), "comments": [], "after": []}
    return {"addPullRequestReview": {"pullRequestReview": {"id": rid}}}


def add_thread(client, variables):
    f = variables["input"]
    with _lock:
        review = _pending[f["pullRequestReviewId"]]
    if f.get("subjectType") == "FILE":
        review["after"].append(("file", f))
    else:
        c = {"path": f["path"], "body": f["body"], "line": f["line"], "side": f.get("side") or "RIGHT"}
        if f.get("startLine"):
            c.update({"start_line": f["startLine"], "start_side": f.get("startSide") or c["side"]})
        review["comments"].append(c)
    return {}


def add_reply(client, variables):
    f = variables["input"]
    with _lock:
        _pending[f["pullRequestReviewId"]]["after"].append(("reply", f))
    return {}


def submit_review(client, variables):
    rid = variables["id"]
    owner, name, number, _ = _parse(rid, "review", 4)
    with _lock:
        review = _pending.pop(rid)
    base = _repo_path(owner, name, "/pulls/{0}".format(number))
    data = {"event": variables["event"], "comments": review["comments"]}
    if review["oid"]:
        data["commit_id"] = review["oid"]
    if variables.get("body"):
        data["body"] = variables["body"]
    elif variables["event"] == "COMMENT" and not review["comments"]:
        # GitHub refuses an empty COMMENT review: the rest go on their own.
        data = None
    if data is not None:
        client.rest("POST", base + "/reviews", data)
    failed = []
    for kind, f in review["after"]:
        try:
            if kind == "file":
                client.rest("POST", base + "/comments", {"body": f["body"], "commit_id": review["oid"],
                                                         "path": f["path"], "subject_type": "file"})
            else:
                comment = _parse(f["pullRequestReviewThreadId"], "thread", 4)[3]
                client.rest("POST", base + "/comments/{0}/replies".format(comment), {"body": f["body"]})
        except Exception as e:  # noqa: BLE001 - said below; what went in stays in
            failed.append("{0} on {1}: {2}".format("file comment" if kind == "file" else "reply",
                                                    f.get("path") or "thread", e))
    if failed:
        raise PartialReview("the review went in, but not: " + "; ".join(failed))
    return {}


class PartialReview(RuntimeError):
    """Part of a review was posted: retrying it all would post that twice,
    so github_host reports it rather than failing the queue (`posted`)."""
    posted = True


def delete_review(client, variables):
    with _lock:
        _pending.pop(variables["id"], None)
    return {}


# ---------------------------------------------------------------------------
# Reviewers, description
# ---------------------------------------------------------------------------
#
# A user's "id" here is their login and a team's its org/slug: the REST
# call that requests reviews takes those.

def reviewer_lookup(client, variables):
    owner, name, number = variables["owner"], variables["name"], int(variables["number"])
    p = client.rest("GET", _repo_path(owner, name, "/pulls/{0}".format(number))) or {}
    q = (variables.get("q") or "").lower()
    people = []
    for u in _pages(client, _repo_path(owner, name, "/assignees"), limit=300):
        login = (u or {}).get("login") or ""
        if not login:
            continue
        person = {"id": login, "login": login, "name": None}
        if q not in login.lower():
            person["name"] = display_name(client, login)
            if q not in (person["name"] or "").lower():
                continue
        people.append(person)
    people = people[:10]  # assignableUsers(first: 10)
    for person in people:
        if person["name"] is None:
            person["name"] = display_name(client, person["login"])
    return {"repository": {"pullRequest": {"id": "rest:pr:{0}/{1}/{2}".format(owner, name, number),
                                           "author": {"login": (p.get("user") or {}).get("login")}},
                           "assignableUsers": {"nodes": people}}}


def assignable_people(client, variables):
    # One page holds everyone (no cursor): names only where already known -
    # a /users call per person would make the list slow to open.
    owner, name, number = variables["owner"], variables["name"], int(variables["number"])
    p = client.rest("GET", _repo_path(owner, name, "/pulls/{0}".format(number))) or {}
    people = []
    for u in _pages(client, _repo_path(owner, name, "/assignees"), limit=500):
        login = (u or {}).get("login") or ""
        if login:
            with _lock:
                name = _names.get((client.api_url, login))
            people.append({"id": login, "login": login, "name": name})
    return {"repository": {"pullRequest": {"author": {"login": (p.get("user") or {}).get("login")}},
                           "assignableUsers": {"nodes": people, "pageInfo": {"hasNextPage": False}}}}


def user(client, variables):
    try:
        u = client.rest("GET", "/users/" + _q(variables["login"])) or {}
    except host.GitHubHttpError as e:
        if e.status == 404:
            return {"user": None}
        raise
    # /users/<login> answers for an organization too; GraphQL's user() doesn't.
    if u.get("type") == "Organization":
        return {"user": None}
    return {"user": {"id": u.get("login"), "login": u.get("login"), "name": u.get("name")}}


def team(client, variables):
    try:
        t = client.rest("GET", "/orgs/{0}/teams/{1}".format(_q(variables["org"]), _q(variables["slug"]))) or {}
    except host.GitHubHttpError as e:
        if e.status == 404:
            return {"organization": {"team": None}}
        raise
    return {"organization": {"team": {"id": t.get("slug"), "name": t.get("name"), "slug": t.get("slug")}}}


def request_reviews(client, variables):
    owner, name, number = _parse(variables["id"], "pr", 3)
    data = {}
    if variables.get("users"):
        data["reviewers"] = variables["users"]
    if variables.get("teams"):
        data["team_reviewers"] = variables["teams"]
    client.rest("POST", _repo_path(owner, name, "/pulls/{0}/requested_reviewers".format(number)), data)
    return {}


def update_pr(client, variables):
    owner, name, number = _parse(variables["id"], "pr", 3)
    data = {"body": variables.get("body") or ""}
    if variables.get("title"):
        data["title"] = variables["title"]
    client.rest("PATCH", _repo_path(owner, name, "/pulls/{0}".format(number)), data)
    return {}


# ---------------------------------------------------------------------------
# Merging
# ---------------------------------------------------------------------------

def merge_state(client, variables):
    """MERGE_STATE_QUERY: no isRequired and no reviewDecision (see the
    module comment); mergeStateStatus is REST's mergeable_state."""
    owner, name, number = variables["owner"], variables["name"], int(variables["number"])
    with _lock:  # read fresh: the merge goes by it
        _repos.pop((client.api_url, owner, name), None)
        _nodes.pop((client.api_url, owner, name, number), None)
        for k in [k for k in _rollups if k[:3] == (client.api_url, owner, name)]:
            _rollups.pop(k, None)
    node = pr_node(client, owner, name, number)
    repo = repo_info(client, owner, name)
    r = node["repository"]
    decision = None
    if any(n.get("state") == "CHANGES_REQUESTED" for n in node["latestOpinionatedReviews"]["nodes"]):
        decision = "CHANGES_REQUESTED"
    pr = dict(node, reviewDecision=decision)
    return {"repository": {
        "deleteBranchOnMerge": r["deleteBranchOnMerge"], "autoMergeAllowed": r["autoMergeAllowed"],
        "mergeCommitAllowed": r["mergeCommitAllowed"], "squashMergeAllowed": r["squashMergeAllowed"],
        "rebaseMergeAllowed": r["rebaseMergeAllowed"],
        "defaultBranchRef": {"name": repo.get("default_branch") or ""},
        "pullRequest": pr}}


def enable_auto_merge(client, variables):
    owner, name, number = _parse(variables["id"], "pr", 3)
    data = {"merge_method": (variables.get("method") or "").lower()}
    if variables.get("oid"):
        data["expected_head_oid"] = variables["oid"]
    _ccr_post(client, "PUT", _repo_path(owner, name, "/pulls/{0}/ccr/auto_merge".format(number)), data,
              "Auto-merge")
    return {}


def disable_auto_merge(client, variables):
    owner, name, number = _parse(variables["id"], "pr", 3)
    _ccr_post(client, "DELETE", _repo_path(owner, name, "/pulls/{0}/ccr/auto_merge".format(number)), None,
              "Auto-merge")
    return {}


# ---------------------------------------------------------------------------
# The issues a PR closes: its body's closing lines
# ---------------------------------------------------------------------------

_CLOSING = re.compile(r"\b{0}:?[ \t]+(?:([\w.-]+)/([\w.-]+))?#(\d+)\b".format(r"(?:close[sd]?|fix(?:e[sd])?|"
                                                                            r"resolve[sd]?)"), re.IGNORECASE)


CLOSING_MAX = 50  # closingIssuesReferences(first: 50)


def closing_issues(client, variables):
    owner, name, number = variables["owner"], variables["name"], int(variables["number"])
    p = client.rest("GET", _repo_path(owner, name, "/pulls/{0}".format(number))) or {}
    nodes, seen = [], set()
    for m in _CLOSING.finditer(p.get("body") or ""):
        io, ir, n = m.group(1) or owner, m.group(2) or name, int(m.group(3))
        if (io.lower(), ir.lower(), n) in seen:
            continue
        if len(seen) >= CLOSING_MAX:
            break
        seen.add((io.lower(), ir.lower(), n))
        try:
            i = client.rest("GET", _repo_path(io, ir, "/issues/{0}".format(n))) or {}
        except host.GitHubHttpError:
            continue
        if i.get("pull_request") is not None:
            continue
        nodes.append({"number": i.get("number"), "title": i.get("title") or "", "state": _up(i.get("state")),
                      "url": i.get("html_url") or "", "repository": {"name": ir, "owner": {"login": io}},
                      "assignees": {"nodes": [{"login": a.get("login")} for a in i.get("assignees") or []]},
                      "projectItems": {"nodes": []}})
    return {"repository": {"pullRequest": {"closingIssuesReferences": {"nodes": nodes}}}}
