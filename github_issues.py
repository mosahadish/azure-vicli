"""github_issues.py: GitHub Issues and a Projects v2 project as the
work-items backend.

A GitHub account with an `issues:` block in azure-cli.yml

    - host: github
      owner: my-org
      issues: { project: 3 }        # a Projects v2 number or title
                                    # repo: where new issues go (optional)
                                    # scope: mine (default) | all

answers --wi-list / --wi-detail / --wi-state / --wi-edit from that project
when the caller sets AZVICLI_WI_HOST=github (azure-cli.py's cmd_wi_action).
The output is the same NDJSON/JSON/plain lines WorkItemActions prints for
Azure, so the work-items screens read a GitHub issue the way they read a
work item:

- sprints are the project's Iteration field (path = the iteration's id),
  else the default repository's open milestones (path = "milestone/<n>"),
  else one "whole project" tab (path = "*");
- a state is the project's Status option; a closed issue is "Closed" and
  an open one with no Status "No Status". `--wi-state set <id> Closed
  [completed|not planned]` closes the issue, any Status option sets the
  field (and reopens a closed issue). Status "Done" doesn't close anything
  by itself: that's the project's own workflow's job, as on github.com;
- an id is the issue number. Every <id> argument also takes
  owner/repo#n (or the owner~repo~n key records carry), and a bare number
  that two of the project's issues share is refused rather than guessed.

Branches and PRs (stage 3):

- create-branch makes the branch with createLinkedBranch, so it shows in
  the issue's Development section (a plain ref when no issue is given, or
  when linking fails - then with linkError); delete-branch (the chat's
  undo) deletes it only while its tip is still the commit it was made at;
- GitHub links a PR to an issue only through a closing keyword in the
  PR's body, so link-pr adds a "Closes #n" line (owner/repo#n across
  repositories) and unlink-pr removes the closing lines for that issue.
  GitHub honours them only on PRs into the default branch: the answer's
  "note" says so for any other.

azure-cli.py hands in its own module (`core`, for _wi_human and friends)
and github_host.py (`host`, for Client, tokens and errors) through bind().
"""

import json
import re
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timedelta, timezone

core = None
host = None


def bind(module, github_host):
    global core, host
    core = module
    host = github_host


# ---------------------------------------------------------------------------
# GraphQL
# ---------------------------------------------------------------------------

PROJECT_FIELDS = """
fragment P on ProjectV2 {
  id number title url
  owner { ... on Organization { login } ... on User { login } }
  repositories(first: 20) { nodes { name owner { login } } }
  fields(first: 50) { nodes {
    __typename
    ... on ProjectV2FieldCommon { id name }
    ... on ProjectV2SingleSelectField { options { id name } }
    ... on ProjectV2IterationField { configuration {
      iterations { id title startDate duration }
      completedIterations { id title startDate duration } } } } }
}
"""

PROJECT_BY_NUMBER = """
query($login: String!, $number: Int!) { repositoryOwner(login: $login) {
  ... on Organization { projectV2(number: $number) { ...P } }
  ... on User { projectV2(number: $number) { ...P } } } }
""" + PROJECT_FIELDS

PROJECT_BY_TITLE = """
query($login: String!, $q: String!) { repositoryOwner(login: $login) {
  ... on Organization { projectsV2(first: 20, query: $q) { nodes { ...P } } }
  ... on User { projectsV2(first: 20, query: $q) { nodes { ...P } } } } }
""" + PROJECT_FIELDS

VIEWER = "query { viewer { login } }"

FIELD_VALUES = """fieldValues(first: 30) { nodes { __typename
  ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { id } } }
  ... on ProjectV2ItemFieldIterationValue { iterationId title field { ... on ProjectV2FieldCommon { id } } } } }"""

REPO = "repository { name owner { login } }"

# Sub-issues and issue types are newer than some Enterprise Servers: when
# the server says a field doesn't exist, the same query runs without them
# (lite) and the tree is flat, every issue an "Issue".
NEW_FIELDS_RE = re.compile(r"Field '(issueType|parent|subIssues|linkedBranches)' doesn't exist")


def issue_fields(full, detail=False):
    """The Issue fields a record (or, detail=True, the detail view) is built
    from; `full` False leaves out what NEW_FIELDS_RE names."""
    parts = ["id databaseId number title url state stateReason createdAt updatedAt", REPO,
             "assignees(first: 10) { nodes { login name } }",
             "labels(first: 30) { nodes { name } }",
             "milestone { number title }"]
    if detail:
        parts.append("body author { login ... on User { name } }")
        parts.append("closedByPullRequestsReferences(first: 20, includeClosedPrs: true) { nodes {"
                     " number title url state isDraft headRefName baseRefName author { login } " + REPO + " } }")
        parts.append("comments(last: 100) { nodes { databaseId body createdAt author { login } } }")
    else:
        parts.append("closedByPullRequestsReferences(first: 20, includeClosedPrs: true) { nodes { number "
                     + REPO + " } }")
    if full:
        parts.append("issueType { name }")
        parts.append("parent { number " + REPO + " }")
        parts.append("subIssues(first: 50) { nodes { number " + REPO + " } }")
        if detail:
            parts.append("linkedBranches(first: 20) { nodes { ref { name " + REPO + " } } }")
    return "\n".join(parts)


def summary_fields(full):
    """A parent's or child's fields in the detail view."""
    parts = ["number title state " + REPO, "assignees(first: 10) { nodes { login } }",
             "projectItems(first: 10) { nodes { project { id } " + FIELD_VALUES + " } }"]
    if full:
        parts.append("issueType { name }")
    return " ".join(parts)


def items_query(full):
    return """
query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 {
  items(first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes {
    id isArchived %s
    content { __typename ... on Issue { %s } } } } } } }
""" % (FIELD_VALUES, issue_fields(full))


def issue_query(full, detail=False):
    extra = ""
    if detail and full:
        extra = "parent { %s } subIssues(first: 50) { nodes { %s } }" % (summary_fields(full), summary_fields(full))
    return """
query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) {
  issue(number: $number) { %s %s projectItems(first: 10) { nodes { id project { id } %s } } } } }
""" % (issue_fields(full, detail), extra, FIELD_VALUES)


ISSUE_TYPES = """
query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
  issueTypes(first: 25) { nodes { name } } } }
"""

ASSIGNABLE = """
query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
  assignableUsers(first: 100) { nodes { login name } } } }
"""

ADD_ITEM = """mutation($project: ID!, $content: ID!) {
  addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } } }"""
UPDATE_FIELD = """mutation($project: ID!, $item: ID!, $field: ID!, $value: ProjectV2FieldValue!) {
  updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field, value: $value}) {
    projectV2Item { id } } }"""
CLEAR_FIELD = """mutation($project: ID!, $item: ID!, $field: ID!) {
  clearProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field}) {
    projectV2Item { id } } }"""
CLOSE_ISSUE = """mutation($id: ID!, $reason: IssueClosedStateReason!) {
  closeIssue(input: {issueId: $id, stateReason: $reason}) { issue { id } } }"""
REOPEN_ISSUE = """mutation($id: ID!) { reopenIssue(input: {issueId: $id}) { issue { id } } }"""
REPO_REF = """query($owner: String!, $name: String!, $ref: String!) { repository(owner: $owner, name: $name) {
  id ref(qualifiedName: $ref) { target { oid } } } }"""
CREATE_LINKED_BRANCH = """mutation($issue: ID!, $repo: ID!, $oid: GitObjectID!, $name: String!) {
  createLinkedBranch(input: {issueId: $issue, repositoryId: $repo, oid: $oid, name: $name}) {
    linkedBranch { id } } }"""

CLOSED = "Closed"
NO_STATUS = "No Status"
CLOSE_REASONS = {"completed": "COMPLETED", "not planned": "NOT_PLANNED"}
ALL = "*"
MILESTONE = "milestone/"
# How many finished iterations the tab bar keeps, before the active ones.
COMPLETED_TABS = 3
MAX_PAGES = 20


class IssueError(Exception):
    """A refusal with a message for the user (an ambiguous id, no Status
    field, ...): printed as "ERROR: <message>", exit 1."""


# ---------------------------------------------------------------------------
# The project
# ---------------------------------------------------------------------------

# Project metadata (fields, options, iterations) per account and project,
# for a few minutes: --wi-list runs on every dashboard refresh, and the
# project's fields change rarely.
_project_cache = {}
_project_lock = threading.Lock()
PROJECT_TTL = 300


class Project(object):
    """A Projects v2 project's metadata, from the P fragment."""

    def __init__(self, node):
        self.id = node.get("id")
        self.number = node.get("number")
        self.title = node.get("title") or ""
        self.url = node.get("url") or ""
        self.owner = ((node.get("owner") or {}).get("login")) or ""
        self.repos = [((r.get("owner") or {}).get("login") or "", r.get("name") or "")
                      for r in ((node.get("repositories") or {}).get("nodes") or []) if r]
        self.status = self.priority = self.iteration = None
        for f in ((node.get("fields") or {}).get("nodes") or []):
            f = f or {}
            name = (f.get("name") or "").strip().lower()
            if f.get("__typename") == "ProjectV2SingleSelectField":
                if name == "status" and self.status is None:
                    self.status = f
                elif name == "priority" and self.priority is None:
                    self.priority = f
            elif f.get("__typename") == "ProjectV2IterationField" and self.iteration is None:
                self.iteration = f

    def status_options(self):
        return [o.get("name") for o in ((self.status or {}).get("options") or []) if o.get("name")]

    def priority_options(self):
        return [o.get("name") for o in ((self.priority or {}).get("options") or []) if o.get("name")]

    def iterations(self):
        """(completed, active) iterations, each sorted by start date."""
        conf = (self.iteration or {}).get("configuration") or {}
        key = lambda it: it.get("startDate") or ""  # noqa: E731
        return (sorted(conf.get("completedIterations") or [], key=key),
                sorted(conf.get("iterations") or [], key=key))


def _parse_project_ref(value):
    """issues.project as (number, None) or (None, title)."""
    s = str(value if value is not None else "").strip()
    if s.startswith("#"):
        s = s[1:]
    if s.isdigit():
        return int(s), None
    return None, s


def _iso_day(d):
    return d.strftime("%Y-%m-%dT00:00:00Z")


def _iteration_span(it):
    """(first day, day after the last) of an iteration, or (None, None)."""
    try:
        start = datetime.strptime(it.get("startDate") or "", "%Y-%m-%d").date()
    except ValueError:
        return None, None
    return start, start + timedelta(days=int(it.get("duration") or 0))


def _sprint(it, today, is_current):
    start, end = _iteration_span(it)
    if start is None:
        frame = ""
    elif end <= today:
        frame = "past"
    elif start <= today:
        frame = "current"
    else:
        frame = "future"
    title = it.get("title") or ""
    return {"name": title, "label": title, "path": it.get("id") or "",
            "start": _iso_day(start) if start else "",
            # Azure's finishDate is the sprint's last day.
            "finish": _iso_day(end - timedelta(days=1)) if start else "",
            "timeframe": frame, "current": is_current}


def _milestone_sprint(m, is_current):
    title = m.get("title") or ""
    return {"name": title, "label": title, "path": MILESTONE + str(m.get("number")),
            "start": m.get("created_at") or "", "finish": m.get("due_on") or "",
            "timeframe": "current" if is_current else "future", "current": is_current}


# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

def _repo_of(node):
    r = (node or {}).get("repository") or {}
    return ((r.get("owner") or {}).get("login") or "", r.get("name") or "")


def _values(field_values):
    """{field id: value node} of an item's fieldValues."""
    out = {}
    for v in ((field_values or {}).get("nodes") or []):
        fid = ((v or {}).get("field") or {}).get("id")
        if fid:
            out[fid] = v
    return out


def _flat(s):
    return re.sub(r"\s+", " ", str(s or "").strip())


class Board(object):
    """What turns an issue (plus its item's field values) into the
    work-items screens' shapes, for one project."""

    def __init__(self, project):
        self.project = project

    def item_values(self, issue):
        """The issue's field values in this project, from its projectItems:
        (item id, {field id: value}), or (None, {}) when it isn't in it."""
        for n in (((issue or {}).get("projectItems") or {}).get("nodes") or []):
            if ((n or {}).get("project") or {}).get("id") == self.project.id:
                return n.get("id"), _values(n.get("fieldValues"))
        return None, {}

    def state(self, issue, values):
        if (issue or {}).get("state") == "CLOSED":
            return CLOSED
        status = self.project.status
        v = values.get((status or {}).get("id")) if status else None
        return (v or {}).get("name") or NO_STATUS

    def priority(self, values):
        field = self.project.priority
        v = values.get((field or {}).get("id")) if field else None
        if not v:
            return None
        names = self.project.priority_options()
        return names.index(v.get("name")) + 1 if v.get("name") in names else None

    def iteration(self, values):
        field = self.project.iteration
        v = values.get((field or {}).get("id")) if field else None
        return v or {}

    def record(self, issue, values):
        """One --wi-list NDJSON line (see azure-cli.py's _wi_list_record)."""
        owner, repo = _repo_of(issue)
        parent = issue.get("parent") or None
        changed = issue.get("updatedAt") or ""
        return {
            "id": issue.get("number"),
            "type": ((issue.get("issueType") or {}).get("name")) or "Issue",
            "state": self.state(issue, values),
            "title": _flat(issue.get("title")),
            "assignedTo": ", ".join(a.get("login") or "" for a in
                                    ((issue.get("assignees") or {}).get("nodes") or []) if a),
            "priority": self.priority(values),
            "tags": "; ".join(l.get("name") or "" for l in ((issue.get("labels") or {}).get("nodes") or []) if l),
            "parentId": (parent or {}).get("number"),
            "pullRequests": [{"id": p.get("number"), "repo": _repo_of(p)[1]} for p in
                             ((issue.get("closedByPullRequestsReferences") or {}).get("nodes") or []) if p],
            "childIds": [c.get("number") for c in ((issue.get("subIssues") or {}).get("nodes") or []) if c],
            "changedIso": changed,
            "changedHuman": core._wi_human(changed),
            "url": issue.get("url") or "",
            "repo": repo,
            "key": host.pr_key(owner, repo, issue.get("number")),
            # What `set <id> iteration` takes back (the chat's undo, a
            # child's iteration): the iteration's id, else milestone/<n>.
            "iteration": self.iteration(values).get("iterationId") or (
                MILESTONE + str(issue["milestone"]["number"]) if (issue.get("milestone") or {}).get("number") else ""),
            # Its name, for people and the chat's list_work_items.
            "iterationPath": self.iteration(values).get("title") or ((issue.get("milestone") or {}).get("title")) or "",
        }

    def summary(self, issue):
        """A parent/child line for --wi-detail (see _wi_summary)."""
        _, values = self.item_values(issue)
        return {
            "id": issue.get("number"),
            "type": ((issue.get("issueType") or {}).get("name")) or "Issue",
            "state": self.state(issue, values),
            "title": _flat(issue.get("title")),
            "assignedTo": ", ".join(a.get("login") or "" for a in
                                    ((issue.get("assignees") or {}).get("nodes") or []) if a),
        }


def _pr_summary(p):
    """A linked PR for the detail view (see _wi_pr_summary)."""
    status = {"OPEN": "active", "MERGED": "completed", "CLOSED": "abandoned"}.get(p.get("state"), "")
    return {"id": p.get("number"), "title": _flat(p.get("title")), "status": status,
            "isDraft": bool(p.get("isDraft")), "repo": _repo_of(p)[1], "source": p.get("headRefName") or "",
            "target": p.get("baseRefName") or "", "author": ((p.get("author") or {}).get("login")) or "",
            "url": p.get("url") or ""}


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

REF_RE = re.compile(r"^(?:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+))?#?(\d+)$")
KEY_RE = re.compile(r"^([^~]+)~([^~]+)~(\d+)$")


def _error(msg):
    print("ERROR: " + msg, file=sys.stderr)


def _scope_hint(msg):
    m = str(msg)
    if "scope" in m.lower() and "project" in m.lower():
        return m + " - the token needs the project scope: run `gh auth refresh -s project`"
    return m


class IssueActions(object):
    """--wi-list/--wi-detail/--wi-state/--wi-edit for one GitHub account's
    project, with WorkItemActions' outputs and exit codes. `client` is a
    github_host.Client (tests pass a fake); `today` is swappable too."""

    def __init__(self, account, env, client=None, today=None):
        self.account = account
        self.env = env
        self.client = client
        self.today = today or datetime.now(timezone.utc).date()
        issues = getattr(account, "issues", None) or {}
        self.project_ref = issues.get("project")
        self.repo_setting = str(issues.get("repo") or "").strip()
        self.scope = str(issues.get("scope") or "mine").strip().lower()
        self.validate_only = env.get("AZVICLI_WI_VALIDATE_ONLY") == "1"
        self._project = None
        self._viewer = None
        self._full = True
        self._items = None
        self._types = None

    # -- setup ------------------------------------------------------------

    def ensure_client(self):
        if self.client is None:
            token = host.account_token(self.account)
            if not token:
                _error("no GitHub token for {0}: set pat_file, or sign in with `gh auth login`"
                       .format(self.account.label()))
                return False
            self.client = host.Client(self.account.api_url, token)
        return True

    def gql(self, query_fn, variables):
        """Runs query_fn(full) and, when the server lacks sub-issues/issue
        types, query_fn(False) from then on."""
        if self._full:
            try:
                return self.client.graphql(query_fn(True), variables)
            except RuntimeError as e:
                if not NEW_FIELDS_RE.search(str(e)):
                    raise
                self._full = False
        return self.client.graphql(query_fn(False), variables)

    def viewer(self):
        if self._viewer is None:
            self._viewer = ((self.client.graphql(VIEWER).get("viewer") or {}).get("login")) or ""
        return self._viewer

    def assignee(self):
        """Whose items "mine" means: AZVICLI_WI_ASSIGNEE, else me."""
        return self.env.get("AZVICLI_WI_ASSIGNEE") or self.viewer()

    def project(self):
        if self._project is not None:
            return self._project
        login = self.account.owner or self.viewer()
        number, title = _parse_project_ref(self.project_ref)
        key = (self.client.api_url, login.lower(), number, title)
        with _project_lock:
            hit = _project_cache.get(key)
        if hit and time.monotonic() - hit[0] < PROJECT_TTL:
            self._project = hit[1]
            return self._project
        if number is not None:
            data = self.client.graphql(PROJECT_BY_NUMBER, {"login": login, "number": number})
            node = ((data.get("repositoryOwner") or {}).get("projectV2")) or None
        else:
            data = self.client.graphql(PROJECT_BY_TITLE, {"login": login, "q": title})
            nodes = (((data.get("repositoryOwner") or {}).get("projectsV2") or {}).get("nodes") or [])
            node = next((n for n in nodes if n and (n.get("title") or "").strip().lower() == title.lower()), None)
        if not node:
            raise IssueError("no project {0} on {1} - check issues: project: in azure-cli.yml".format(
                "#{0}".format(number) if number is not None else "titled '{0}'".format(title), login))
        self._project = Project(node)
        with _project_lock:
            _project_cache[key] = (time.monotonic(), self._project)
        return self._project

    def board(self):
        return Board(self.project())

    def default_repo(self):
        """Where new issues (and milestones) live: issues: repo:, else the
        project's one linked repository; None when that's ambiguous."""
        p = self.project()
        if self.repo_setting:
            if "/" in self.repo_setting:
                o, r = self.repo_setting.split("/", 1)
                return o, r
            return (self.account.owner or p.owner), self.repo_setting
        return p.repos[0] if len(p.repos) == 1 else None

    def need_default_repo(self):
        repo = self.default_repo()
        if repo is None:
            p = self.project()
            linked = ", ".join("{0}/{1}".format(o, r) for o, r in p.repos) or "none"
            raise IssueError("project '{0}' has {1} linked repositories ({2}) - set issues: repo: in azure-cli.yml "
                             "to say where new issues go".format(p.title, len(p.repos), linked))
        return repo

    # -- the project's items ---------------------------------------------

    def items(self):
        """Every issue in the project, unarchived: [(issue, {field: value})]."""
        if self._items is not None:
            return self._items
        out, after = [], None
        for _ in range(MAX_PAGES):
            data = self.gql(items_query, {"id": self.project().id, "after": after})
            conn = ((data.get("node") or {}).get("items")) or {}
            for n in conn.get("nodes") or []:
                n = n or {}
                content = n.get("content") or {}
                if n.get("isArchived") or content.get("__typename") != "Issue":
                    continue  # draft issues and pull requests aren't work items here
                content["projectItems"] = {"nodes": [{"id": n.get("id"), "project": {"id": self.project().id},
                                                      "fieldValues": n.get("fieldValues")}]}
                out.append((content, _values(n.get("fieldValues"))))
            page = conn.get("pageInfo") or {}
            if not page.get("hasNextPage"):
                break
            after = page.get("endCursor")
        self._items = out
        return out

    def resolve(self, ref):
        """(owner, repo, number) for an <id> argument: n, #n, owner/repo#n
        or owner~repo~n."""
        s = str(ref or "").strip()
        m = KEY_RE.match(s)
        if m:
            return m.group(1), m.group(2), int(m.group(3))
        m = REF_RE.match(s)
        if not m:
            raise IssueError("'{0}' isn't an issue: give its number or owner/repo#number".format(s))
        number = int(m.group(3))
        if m.group(1):
            return m.group(1), m.group(2), number
        hits = sorted({_repo_of(issue) for issue, _ in self.items() if issue.get("number") == number})
        if len(hits) == 1:
            return hits[0][0], hits[0][1], number
        if len(hits) > 1:
            raise IssueError("#{0} is more than one issue in project '{1}': {2} - say which with owner/repo#{0}"
                             .format(number, self.project().title,
                                     ", ".join("{0}/{1}#{2}".format(o, r, number) for o, r in hits)))
        repo = self.default_repo()
        if repo is None:
            raise IssueError("#{0} isn't in project '{1}' - say which repository with owner/repo#{0}"
                             .format(number, self.project().title))
        return repo[0], repo[1], number

    def issue(self, ref, detail=False):
        owner, repo, number = self.resolve(ref)
        data = self.gql(lambda full: issue_query(full, detail), {"owner": owner, "name": repo, "number": number})
        node = ((data.get("repository") or {}).get("issue")) or None
        if not node:
            raise IssueError("no issue {0}/{1}#{2}".format(owner, repo, number))
        return node

    def _rest_repo(self, owner, repo, path):
        return "/repos/{0}/{1}{2}".format(urllib.parse.quote(owner, safe=""), urllib.parse.quote(repo, safe=""), path)

    # -- dispatch -----------------------------------------------------------

    def run(self, flag, rest):
        """One WI flag; exit code. Errors print one "ERROR: ..." line."""
        if not self.ensure_client():
            return 1
        try:
            if flag == "--wi-list":
                return self.cmd_wi_list(rest[0] if rest else "current", rest[1] if len(rest) > 1 else "")
            if flag == "--wi-detail":
                if not rest or not rest[0]:
                    _error("usage: --wi-detail <issue>")
                    return 1
                return self.cmd_wi_detail(rest[0])
            if flag == "--wi-state":
                return self.cmd_wi_state(rest)
            if flag == "--wi-edit":
                return self.cmd_wi_edit(rest)
        except IssueError as e:
            _error(str(e))
            return 1
        except host.GitHubHttpError as e:
            _error("HTTP {0}: {1}".format(e.status, _scope_hint(e)))
            return 2
        except RuntimeError as e:
            _error(_scope_hint(e))
            return 2
        _error("unknown work-item action: " + flag)
        return 1

    # -- list -------------------------------------------------------------

    def sprints(self):
        """(sprints, index of the current one) - see the module comment."""
        p = self.project()
        if p.iteration:
            completed, active = p.iterations()
            its = completed[-COMPLETED_TABS:] + active
            cur = next((i for i, it in enumerate(its)
                        if _iteration_span(it)[0] and _iteration_span(it)[0] <= self.today < _iteration_span(it)[1]),
                       None)
            if cur is None:
                # Between iterations: the next one, else the last.
                cur = next((i for i, it in enumerate(its)
                            if _iteration_span(it)[0] and _iteration_span(it)[0] > self.today), len(its) - 1)
            if its:
                return [_sprint(it, self.today, i == cur) for i, it in enumerate(its)], cur
        repo = self.default_repo()
        if repo and not p.iteration:
            ms = self.client.rest("GET", self._rest_repo(repo[0], repo[1],
                                                         "/milestones?state=open&sort=due_on&direction=asc")) or []
            ms = [m for m in ms if isinstance(m, dict)]
            if ms:
                return [_milestone_sprint(m, i == 0) for i, m in enumerate(ms)], 0
        return [{"name": p.title, "label": p.title, "path": ALL, "start": "", "finish": "",
                 "timeframe": "current", "current": True}], 0

    def states(self):
        return self.project().status_options() + [CLOSED]

    def types(self):
        if self._types is None:
            names = []
            repo = self.default_repo() if self._full else None
            if repo:
                try:
                    data = self.client.graphql(ISSUE_TYPES, {"owner": repo[0], "name": repo[1]})
                    names = [n.get("name") for n in
                             (((data.get("repository") or {}).get("issueTypes") or {}).get("nodes") or [])
                             if n and n.get("name")]
                except RuntimeError:
                    names = []
            self._types = names or ["Issue"]
        return self._types

    def cmd_wi_list(self, select, arg=""):
        if select not in ("current", "next", "sprints", "items", "members", "ids", "tree"):
            _error("selector must be current|next|sprints|items|members|ids|tree, got '{0}'".format(select))
            return 1
        if select == "items" and not arg:
            _error("'items' needs an iteration path")
            return 1
        if select == "sprints":
            sprints, cur = self.sprints()
            print(json.dumps({"_sprints": True, "quarter": self.project().title, "currentIndex": cur + 1,
                              "sprints": sprints, "states": self.states(), "types": self.types()},
                             ensure_ascii=False))
            return 0
        if select == "members":
            return self._members()
        if select == "ids":
            return self._ids(arg)
        if select == "tree":
            return self._tree(arg)
        if select == "items":
            path = arg
        else:
            sprints, cur = self.sprints()
            nxt = sprints[cur + 1] if cur + 1 < len(sprints) else None
            if select == "next":
                if nxt is None:
                    _error("could not determine next sprint")
                    return 1
                target = nxt
                meta = {"_meta": True, "timeframe": "next", "sprintName": nxt["name"], "sprintPath": nxt["path"],
                        "sprintStart": nxt["start"], "sprintFinish": nxt["finish"]}
            else:
                target = sprints[cur]
                meta = {"_meta": True, "timeframe": "current", "sprintName": target["name"],
                        "sprintPath": target["path"], "sprintStart": target["start"],
                        "sprintFinish": target["finish"],
                        "nextSprintName": (nxt or {}).get("name", ""), "nextSprintPath": (nxt or {}).get("path", ""),
                        "nextStart": (nxt or {}).get("start", ""), "nextFinish": (nxt or {}).get("finish", "")}
            meta["states"] = self.states()
            path = target["path"]
            print(json.dumps(meta, ensure_ascii=False))
        board = self.board()
        me = self.assignee().lower() if self.scope != "all" else None
        for issue, values in self.items():
            if not self._in_sprint(board, issue, values, path):
                continue
            if me is not None and me not in [((a or {}).get("login") or "").lower()
                                             for a in ((issue.get("assignees") or {}).get("nodes") or [])]:
                continue
            print(json.dumps(board.record(issue, values), ensure_ascii=False))
        return 0

    def _in_sprint(self, board, issue, values, path):
        if path == ALL:
            return issue.get("state") != "CLOSED"
        if path.startswith(MILESTONE):
            repo = self.default_repo()
            return (str((issue.get("milestone") or {}).get("number")) == path[len(MILESTONE):]
                    and (repo is None or _repo_of(issue) == repo))
        return board.iteration(values).get("iterationId") == path

    def _members(self):
        p = self.project()
        repos = [self.default_repo()] if self.default_repo() else p.repos
        seen = set()
        for owner, repo in repos:
            data = self.client.graphql(ASSIGNABLE, {"owner": owner, "name": repo})
            for u in (((data.get("repository") or {}).get("assignableUsers") or {}).get("nodes") or []):
                login = (u or {}).get("login") or ""
                if login and login.lower() not in seen:
                    seen.add(login.lower())
                    # name is what `set assignedTo` takes back: the login.
                    print(json.dumps({"name": login, "email": ""}, ensure_ascii=False))
        return 0

    def _refs(self, arg, what):
        refs = [x.strip() for x in (arg or "").split(",") if x.strip()]
        if not refs:
            raise IssueError("'{0}' needs a comma-separated list of issues".format(what))
        return refs

    def _ids(self, arg):
        board = self.board()
        for ref in self._refs(arg, "ids"):
            issue = self.issue(ref)
            print(json.dumps(board.record(issue, board.item_values(issue)[1]), ensure_ascii=False))
        return 0

    def _tree(self, arg):
        """Everything under the roots, by sub-issues, each record with its
        parentId; the roots themselves aren't printed."""
        board = self.board()
        queue = [self.resolve(r) for r in self._refs(arg, "tree")]
        seen = set(queue)
        while queue:
            owner, repo, number = queue.pop(0)
            data = self.gql(issue_query, {"owner": owner, "name": repo, "number": number})
            issue = ((data.get("repository") or {}).get("issue")) or {}
            for child in ((issue.get("subIssues") or {}).get("nodes") or []):
                o, r = _repo_of(child)
                k = (o, r, child.get("number"))
                if k in seen or not child.get("number"):
                    continue
                seen.add(k)
                cdata = self.gql(issue_query, {"owner": o, "name": r, "number": k[2]})
                cnode = ((cdata.get("repository") or {}).get("issue")) or None
                if cnode:
                    print(json.dumps(board.record(cnode, board.item_values(cnode)[1]), ensure_ascii=False))
                    queue.append(k)
        return 0

    # -- detail -------------------------------------------------------------

    def cmd_wi_detail(self, ref):
        issue = self.issue(ref, detail=True)
        board = self.board()
        _, values = board.item_values(issue)
        rec = board.record(issue, values)
        owner, repo = _repo_of(issue)
        item = dict(rec)
        item.update({
            "createdBy": ((issue.get("author") or {}).get("login")) or "",
            "createdDate": issue.get("createdAt") or "",
            "changedDate": issue.get("updatedAt") or "",
            "areaPath": "{0}/{1}".format(owner, repo),
            "reason": (issue.get("stateReason") or "").lower().replace("_", " "),
            # Markdown, shown as written: no html_to_text.
            "description": issue.get("body") or "",
            "acceptanceCriteria": "",
            "reproSteps": "",
            "pullRequests": [_pr_summary(p) for p in
                             ((issue.get("closedByPullRequestsReferences") or {}).get("nodes") or []) if p],
            # The branches in its Development section (create-branch's).
            "branches": [{"name": (b.get("ref") or {}).get("name") or "", "repo": _repo_of(b.get("ref"))[1]}
                         for b in ((issue.get("linkedBranches") or {}).get("nodes") or []) if b and b.get("ref")],
        })
        for k in ("changedIso", "changedHuman", "childIds", "parentId"):
            item.pop(k, None)
        parent = issue.get("parent")
        out = {
            "item": item,
            "parent": board.summary(parent) if parent else None,
            "children": [board.summary(c) for c in ((issue.get("subIssues") or {}).get("nodes") or []) if c],
            "comments": [{"id": c.get("databaseId"), "author": ((c.get("author") or {}).get("login")) or "",
                          "date": c.get("createdAt") or "", "text": c.get("body") or ""}
                         for c in ((issue.get("comments") or {}).get("nodes") or []) if c],
            "commentsUnsupported": False,
        }
        print(json.dumps(out, ensure_ascii=False))
        return 0

    # -- state ----------------------------------------------------------------

    def cmd_wi_state(self, rest):
        cmd = rest[0] if rest else ""
        a = list(rest[1:]) + ["", "", ""]
        if cmd == "states":
            opts = self.project().status_options()
            for i, name in enumerate(opts):
                cat = "Proposed" if i == 0 else ("Completed" if i == len(opts) - 1 else "InProgress")
                print(name + "\t" + cat)
            print(CLOSED + "\tCompleted")
            return 0
        if cmd == "transitions":
            for s in self.states():
                if s != a[1]:
                    print(s)
            return 0
        if cmd == "reasons":
            if a[1] == CLOSED:
                for r in CLOSE_REASONS:
                    print(r)
            return 0
        if cmd == "set":
            return self._set_state(a[0], a[1], a[2])
        _error("usage: --wi-state transitions <type> <currentState> | reasons <type> <toState> | "
               "states <type> | set <id> <newState> [reason]")
        return 1

    def _item_id(self, issue):
        """The issue's item in the project, adding it when it isn't in yet."""
        item, _ = self.board().item_values(issue)
        if item:
            return item
        data = self.client.graphql(ADD_ITEM, {"project": self.project().id, "content": issue.get("id")})
        return (((data.get("addProjectV2ItemById") or {}).get("item")) or {}).get("id")

    def _set_option(self, issue, field, name):
        opt = next((o for o in (field.get("options") or []) if o.get("name") == name), None)
        if opt is None:
            raise IssueError("'{0}' isn't a {1} option (one of: {2})".format(
                name, field.get("name"), ", ".join(o.get("name") or "" for o in field.get("options") or [])))
        self.client.graphql(UPDATE_FIELD, {"project": self.project().id, "item": self._item_id(issue),
                                           "field": field.get("id"), "value": {"singleSelectOptionId": opt["id"]}})

    def _set_state(self, ref, new, reason):
        if not ref or not new:
            _error("set needs <id> <newState>")
            return 1
        issue = self.issue(ref)
        if new == CLOSED:
            why = CLOSE_REASONS.get((reason or "completed").strip().lower())
            if why is None:
                raise IssueError("a closed issue is completed or not planned, not '{0}'".format(reason))
            if not self.validate_only:
                self.client.graphql(CLOSE_ISSUE, {"id": issue.get("id"), "reason": why})
            print(CLOSED)
            return 0
        status = self.project().status
        if not status:
            raise IssueError("project '{0}' has no Status field - add one, or close the issue with Closed"
                             .format(self.project().title))
        if new not in self.project().status_options():
            raise IssueError("'{0}' isn't a state here (one of: {1})".format(new, ", ".join(self.states())))
        if not self.validate_only:
            self._set_option(issue, status, new)
            if issue.get("state") == "CLOSED":
                self.client.graphql(REOPEN_ISSUE, {"id": issue.get("id")})
        print(new)
        return 0

    # -- edit -------------------------------------------------------------------

    def cmd_wi_edit(self, rest):
        cmd = rest[0] if rest else ""
        a = list(rest[1:]) + ["", "", "", "", "", ""]
        if cmd == "create":
            return self._create(a[0], a[1], a[2], a[3])
        if cmd == "set":
            return self._set_field(a[0], a[1], a[2])
        if cmd == "comment":
            return self._comment(a[0], a[1])
        if cmd == "link-pr":
            return self._link_pr(a[0], a[2], a[3], a[4])
        if cmd == "unlink-pr":
            return self._unlink_pr(a[0], a[1], a[2])
        if cmd == "create-branch":
            return self._create_branch(a[0], a[2], a[3], a[4], a[5])
        if cmd == "delete-branch":
            return self._delete_branch(a[1], a[2], a[3], a[4])
        _error("usage: --wi-edit create <type> <title> [parentId] [iteration] | set <id> <field> <value> | "
               "comment <id> <text> | link-pr <id> <apiUrl> <owner> <repo> <prNumber> | "
               "unlink-pr <id> <prNumber> [owner/repo] | "
               "create-branch <id|0> <apiUrl> <owner> <repo> <fromBranch> <newBranch> | "
               "delete-branch <apiUrl> <owner> <repo> <branch> [sha]")
        return 1

    # -- branches and pull requests ------------------------------------------

    def _where(self, owner, repo, issue_ref=""):
        """(owner, repo) of a repository argument: owner/repo, else repo
        under `owner` (a GitHub PR record's project), the account's owner,
        or the issue's."""
        repo = (repo or "").strip()
        if "/" in repo:
            o, r = repo.split("/", 1)
            return o, r
        if not repo:
            raise IssueError("which repository? give its name or owner/repo")
        if not owner:
            owner = self.account.owner or (self.resolve(issue_ref)[0] if issue_ref and issue_ref != "0" else "")
        return owner or self.viewer(), repo

    def _create_branch(self, ref, owner, repo, from_branch, new_branch):
        strip = lambda b: b[len("refs/heads/"):] if b.startswith("refs/heads/") else b  # noqa: E731
        from_branch, new_branch = strip(from_branch or ""), strip(new_branch or "")
        if not (repo and from_branch and new_branch):
            _error("create-branch needs <id|0> <apiUrl> <owner> <repo> <fromBranch> <newBranch>")
            return 1
        owner, repo = self._where(owner, repo, ref)
        data = self.client.graphql(REPO_REF, {"owner": owner, "name": repo, "ref": "refs/heads/" + from_branch})
        node = data.get("repository") or {}
        oid = (((node.get("ref") or {}).get("target")) or {}).get("oid")
        if not node.get("id") or not oid:
            raise IssueError("branch '{0}' not found in {1}/{2}".format(from_branch, owner, repo))
        out = {"branch": new_branch, "objectId": oid, "linked": None}
        if ref and ref != "0":
            issue = self.issue(ref)
            try:
                self.client.graphql(CREATE_LINKED_BRANCH, {"issue": issue.get("id"), "repo": node["id"],
                                                           "oid": oid, "name": new_branch})
                out["linked"] = issue.get("number")
            except RuntimeError as e:
                out["linkError"] = _scope_hint(e)
        if out["linked"] is None:
            self.client.rest("POST", self._rest_repo(owner, repo, "/git/refs"),
                             {"ref": "refs/heads/" + new_branch, "sha": oid})
        print(json.dumps(out, ensure_ascii=False))
        return 0

    def _delete_branch(self, owner, repo, branch, sha=""):
        branch = branch[len("refs/heads/"):] if (branch or "").startswith("refs/heads/") else (branch or "")
        if not (repo and branch):
            _error("delete-branch needs <apiUrl> <owner> <repo> <branch> [sha]")
            return 1
        owner, repo = self._where(owner, repo)
        path = self._rest_repo(owner, repo, "/git/refs/heads/" + urllib.parse.quote(branch, safe="/"))
        try:
            tip = ((self.client.rest("GET", path) or {}).get("object") or {}).get("sha")
        except host.GitHubHttpError as e:
            if e.status != 404:
                raise
            tip = None
        if not tip:
            raise IssueError("branch '{0}' doesn't exist".format(branch))
        if sha and tip != sha:
            raise IssueError("'{0}' has moved since it was created (new commits) - not deleting it".format(branch))
        self.client.rest("DELETE", path)
        print(json.dumps({"deleted": branch}))
        return 0

    def _pull(self, owner, repo, number):
        if not str(number or "").isdigit():
            raise IssueError("'{0}' isn't a pull request number".format(number))
        return self.client.rest("GET", self._rest_repo(owner, repo, "/pulls/" + str(number))) or {}

    def _link_pr(self, ref, owner, repo, number):
        """Adds "Closes #n" for issue `ref` to PR `number`'s body."""
        if not (ref and repo and number):
            _error("link-pr needs <id> <apiUrl> <owner> <repo> <prNumber>")
            return 1
        io, ir, inum = self.resolve(ref)
        po, pr = self._where(owner, repo, ref)
        pull = self._pull(po, pr, number)
        body = pull.get("body") or ""
        line = host.closing_line(io, ir, inum, po, pr)
        out = {"linked": inum, "pr": int(number), "line": line}
        if host.closes(body, io, ir, inum, po, pr):
            out["already"] = True
        else:
            self.client.rest("PATCH", self._rest_repo(po, pr, "/pulls/" + str(number)),
                             {"body": (body.rstrip() + "\n\n" if body.strip() else "") + line})
        note = host.default_branch_note(pull)
        if note:
            out["note"] = note
        print(json.dumps(out, ensure_ascii=False))
        return 0

    def _unlink_pr(self, ref, number, where=""):
        """Removes PR `number`'s closing lines for issue `ref`; the PR is in
        `where` (owner/repo), else in the issue's repository."""
        if not (ref and number):
            _error("unlink-pr needs <id> <prNumber> [owner/repo]")
            return 1
        io, ir, inum = self.resolve(ref)
        po, pr = self._where("", where) if where else (io, ir)
        pull = self._pull(po, pr, number)
        body = pull.get("body") or ""
        kept = host.without_closing(body, io, ir, inum, po, pr)
        if kept != body:
            self.client.rest("PATCH", self._rest_repo(po, pr, "/pulls/" + str(number)), {"body": kept})
        print(json.dumps({"unlinked": inum, "pr": int(number), "changed": kept != body}, ensure_ascii=False))
        return 0

    def _create(self, wtype, title, parent, iteration):
        if not wtype or not title:
            _error("create needs <type> <title>")
            return 1
        owner, repo = self.need_default_repo()
        data = {"title": title, "assignees": [self.viewer()]}
        # ["Issue"] is the stand-in for a repository without issue types.
        if self.types() != ["Issue"] and wtype in self.types():
            data["type"] = wtype
        made = self.client.rest("POST", self._rest_repo(owner, repo, "/issues"), data) or {}
        number = made.get("number")
        if number is None:
            _error("unexpected response: " + json.dumps(made)[:400])
            return 2
        out = {"id": number, "title": made.get("title") or title, "key": host.pr_key(owner, repo, number)}
        # The issue exists from here on: a later step failing says so
        # rather than reporting the whole create as failed.
        try:
            added = self.client.graphql(ADD_ITEM, {"project": self.project().id, "content": made.get("node_id")})
            item = (((added.get("addProjectV2ItemById") or {}).get("item")) or {}).get("id")
            if iteration:
                self._set_iteration(owner, repo, number, item, iteration)
            if parent:
                po, pr, pn = self.resolve(parent)
                self.client.rest("POST", self._rest_repo(po, pr, "/issues/{0}/sub_issues".format(pn)),
                                 {"sub_issue_id": made.get("id")})
        except (host.GitHubHttpError, RuntimeError, IssueError) as e:
            out["warning"] = "created {0}/{1}#{2}, but: {3}".format(owner, repo, number, _scope_hint(e))
        print(json.dumps(out, ensure_ascii=False))
        return 0

    def _set_iteration(self, owner, repo, number, item, value):
        """value: an iteration id, milestone/<n>, or "" to clear."""
        if value.startswith(MILESTONE) or (not self.project().iteration and value != ALL):
            milestone = int(value[len(MILESTONE):]) if value.startswith(MILESTONE) and \
                value[len(MILESTONE):].isdigit() else None
            self.client.rest("PATCH", self._rest_repo(owner, repo, "/issues/{0}".format(number)),
                             {"milestone": milestone})
            return
        field = self.project().iteration
        if not field:
            return
        if not value or value == ALL:
            self.client.graphql(CLEAR_FIELD, {"project": self.project().id, "item": item, "field": field.get("id")})
        else:
            self.client.graphql(UPDATE_FIELD, {"project": self.project().id, "item": item, "field": field.get("id"),
                                               "value": {"iterationId": value}})

    def _set_field(self, ref, field, value):
        if not ref or not field:
            _error("set needs <id> <field> <value>")
            return 1
        fields = ("title", "assignedTo", "priority", "iteration", "tags", "description")
        if field not in fields:
            _error("unknown field '{0}', expected one of: {1}".format(field, ", ".join(sorted(fields))))
            return 1
        owner, repo, number = self.resolve(ref)
        path = self._rest_repo(owner, repo, "/issues/{0}".format(number))
        shown = value
        if field == "title":
            self.client.rest("PATCH", path, {"title": value})
        elif field == "description":
            self.client.rest("PATCH", path, {"body": value})
        elif field == "assignedTo":
            shown = value or self.viewer()
            logins = [x.strip().lstrip("@") for x in shown.split(",") if x.strip()]
            self.client.rest("PATCH", path, {"assignees": logins})
            shown = ", ".join(logins)
        elif field == "tags":
            labels = [x.strip() for x in re.split(r"[;,]", value or "") if x.strip()]
            self.client.rest("PATCH", path, {"labels": labels})
            shown = "; ".join(labels)
        else:
            issue = self.issue("{0}/{1}#{2}".format(owner, repo, number))
            if field == "priority":
                pf = self.project().priority
                if not pf:
                    raise IssueError("project '{0}' has no Priority field".format(self.project().title))
                names = self.project().priority_options()
                name = names[int(value) - 1] if str(value).isdigit() and 0 < int(value) <= len(names) else value
                self._set_option(issue, pf, name)
                shown = int(value) if str(value).isdigit() else names.index(name) + 1
            else:
                self._set_iteration(owner, repo, number, self._item_id(issue), value or "")
        print(json.dumps({"id": number, "field": field, "value": shown}, ensure_ascii=False))
        return 0

    def _comment(self, ref, text):
        if not ref or not text:
            _error("comment needs <id> <text>")
            return 1
        owner, repo, number = self.resolve(ref)
        made = self.client.rest("POST", self._rest_repo(owner, repo, "/issues/{0}/comments".format(number)),
                                {"body": text}) or {}
        if made.get("id") is None:
            _error("unexpected response: " + json.dumps(made)[:400])
            return 2
        print(json.dumps({"id": made.get("id")}, ensure_ascii=False))
        return 0


def check_project(account, client):
    """--doctor's line for an account's issues: block: (ok, detail)."""
    acts = IssueActions(account, {}, client)
    p = acts.project()
    have = [n for n, f in (("Status", p.status), ("Iteration", p.iteration), ("Priority", p.priority)) if f]
    missing = [n for n in ("Status", "Iteration") if n not in have]
    detail = "project '{0}' (#{1}): {2}".format(p.title, p.number, ", ".join(have) or "no fields it uses")
    if missing:
        detail += " - no {0} field ({1})".format(
            " or ".join(missing), "milestones are the sprints" if "Iteration" in missing else "states are open/closed")
    return True, detail
