#!/usr/bin/env python3
"""tests/fake-provider.py - a stand-in for `python azure-cli.py` that needs
no Azure DevOps, no PAT and no network, for exercising the Neovim side of
azure-vicli by hand (tests/demo.sh) or headless (tests/run.sh's demo
smoke).

The Lua side never talks to Azure DevOps itself: every PR/work-item
action, the branch prefetch and the --serve daemon go through the
"python + azure-cli.py" argv config.lua's provider_cmd() builds. Pointing
AZVICLI_PY at this file makes that argv `fake-provider.py azure-cli.py
<args>` instead, so this script is the "python interpreter" - it ignores
the azure-cli.py path in argv[1] and answers the provider subcommands
itself, from a JSON state file in a workspace directory
($AZVICLI_FAKE_WS, built by `fake-provider.py setup <dir>`):

  - real git repositories: a bare "origin" per fixture repo (so the
    prefetch's `git fetch origin` and the dashboard's clone-on-open both
    work against a file:// remote) plus a clone under <ws>/clones for the
    repos the --list records say are cloned; every PR is a real branch
    with real commits, so the reviewer's file list, diffs, commit log and
    "changes since my last review" run real git commands;
  - a mutable state.json: posting/replying/editing/deleting comments,
    thread status, votes, complete/auto-complete, work-item state/field
    edits all update it, so what you did shows up on the next refresh
    exactly as it would after a round trip to the server;
  - <ws>/calls.log: every invocation (argv + the AZVICLI_* env it saw),
    for checking what the Lua side actually sent.

Same stdout shapes and exit codes as azure-cli.py (see to_record,
_fetch_raw_list, WorkItemActions and the --serve wire protocol there);
where azure-cli.py prints a message on success ("Comment posted.") this
prints the same message. --serve is implemented too, so rpc.lua's daemon
client is exercised for real; AZVICLI_NO_DAEMON=1 still forces the
one-process-per-call path.

Standard library only, like azure-cli.py itself.
"""

import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone

MY_ID = "11111111-1111-1111-1111-111111111111"
MY_NAME = "Demo User"
ORG = "https://dev.azure.com/demo-org"
PROJECT = "Demo"
TEAM = "Demo Team"

PEOPLE = {
    "alice": {"id": "aaaaaaaa-0000-0000-0000-000000000001", "displayName": "Alice Andersson"},
    "bob": {"id": "bbbbbbbb-0000-0000-0000-000000000002", "displayName": "Bob Brown"},
    "carol": {"id": "cccccccc-0000-0000-0000-000000000003", "displayName": "Carol Chen"},
    "me": {"id": MY_ID, "displayName": MY_NAME},
}

THREAD_STATUS_MAP = {
    "active": "active", "fixed": "fixed", "closed": "closed", "pending": "pending",
    "wontfix": "wontFix", "bydesign": "byDesign",
}
VOTES = ("10", "5", "0", "-5", "-10")
MERGE_STRATEGIES = ("squash", "noFastForward", "rebase", "rebaseMerge")
WI_FIELDS = {
    "title": ("title", str), "assignedTo": ("assignedTo", str), "priority": ("priority", int),
    "iteration": ("iterationPath", str), "tags": ("tags", str), "description": ("description", str),
}
WI_TRANSITIONS = {
    "New": ["Active", "Removed"],
    "Active": ["Implemented", "Resolved", "New", "Removed"],
    "Implemented": ["Resolved", "Active"],
    "Resolved": ["Closed", "Active"],
    "Closed": ["Active"],
    "Removed": ["New"],
}
WI_REASONS = {
    "Active": ["Implementation started", "Work started"],
    "Resolved": ["Code complete and unit tests pass", "Fixed"],
    "Closed": ["Acceptance tests pass", "Verified"],
    "Removed": ["Removed from the backlog"],
    "New": ["Reactivated"],
    "Implemented": ["Implemented"],
}


# ---------------------------------------------------------------------------
# Fixtures: two repos, six PRs, a sprint of work items
# ---------------------------------------------------------------------------

BASE_FILES = {
    "README.md": "# widgets\n\nA small demo repository for the azure-vicli reviewer.\n\n"
                 "## Running\n\n    python -m widgets\n",
    "src/app.py": "import sys\n\nfrom util import parse_args\n\n\ndef main(argv):\n    opts = parse_args(argv)\n"
                  "    if opts.verbose:\n        print('starting')\n    return run(opts)\n\n\n"
                  "def run(opts):\n    print('hello', opts.name)\n    return 0\n\n\n"
                  "if __name__ == '__main__':\n    sys.exit(main(sys.argv[1:]))\n",
    "src/auth.py": "import hashlib\n\nUSERS = {}\n\n\ndef register(name, password):\n"
                   "    USERS[name] = hashlib.sha256(password.encode()).hexdigest()\n\n\n"
                   "def login(name, password):\n    digest = hashlib.sha256(password.encode()).hexdigest()\n"
                   "    return USERS.get(name) == digest\n",
    "src/util.py": "def parse_args(argv):\n    class Opts:\n        verbose = False\n        name = 'world'\n"
                   "    opts = Opts()\n    for i, a in enumerate(argv):\n        if a == '-v':\n"
                   "            opts.verbose = True\n        elif a == '--name':\n            opts.name = argv[i]\n"
                   "    return opts\n\n\ndef clamp(n, lo, hi):\n    return max(lo, min(n, hi))\n",
    "docs/guide.md": "# Guide\n\nThis guide is out of date and will be removed.\n",
    "tests/test_app.py": "from app import run\n\n\ndef test_run(capsys):\n    class O:\n        name = 'x'\n"
                         "    assert run(O()) == 0\n    assert 'hello x' in capsys.readouterr().out\n",
}

GADGET_FILES = {
    "README.md": "# gadgets\n\nA second repository, not cloned yet - opening its PR offers to clone it.\n",
    "gadget.py": "def spin():\n    return 'whirr'\n",
}

# Each PR: repo, branch, author key, section-determining fields, and the
# commits on its branch as (message, {path: content or None (=delete)}).
PR_FIXTURES = [
    {
        "id": 101, "repo": "widgets", "source": "feature/login-throttle", "author": "alice",
        "title": "Throttle failed logins", "build": "succeeded",
        "description": "Adds a per-user failure counter so repeated bad passwords lock the account for a minute.",
        "reviewers": [("me", 0), ("bob", 0)],
        "commits": [
            ("Add a throttle helper", {
                "src/throttle.py": "import time\n\nFAILURES = {}\nLIMIT = 5\nWINDOW = 60\n\n\n"
                                   "def record_failure(name):\n    now = time.time()\n"
                                   "    hits = [t for t in FAILURES.get(name, []) if now - t < WINDOW]\n"
                                   "    hits.append(now)\n    FAILURES[name] = hits\n    return len(hits)\n\n\n"
                                   "def is_locked(name):\n    now = time.time()\n"
                                   "    hits = [t for t in FAILURES.get(name, []) if now - t < WINDOW]\n"
                                   "    return len(hits) >= LIMIT\n",
            }),
            ("Wire the throttle into login()", {
                "src/auth.py": "import hashlib\n\nfrom throttle import is_locked, record_failure\n\nUSERS = {}\n\n\n"
                               "def register(name, password):\n"
                               "    USERS[name] = hashlib.sha256(password.encode()).hexdigest()\n\n\n"
                               "def login(name, password):\n    if is_locked(name):\n        return False\n"
                               "    digest = hashlib.sha256(password.encode()).hexdigest()\n"
                               "    ok = USERS.get(name) == digest\n    if not ok:\n        record_failure(name)\n"
                               "    return ok\n",
                "README.md": BASE_FILES["README.md"] + "\n## Security\n\nFailed logins are throttled (see src/throttle.py).\n",
            }),
        ],
        "threads": [
            {"by": "bob", "status": "active", "path": "src/auth.py", "side": "R", "line": 12, "end": 13,
             "comments": [("bob", "Should a locked account return a distinct error rather than plain False? "
                                  "@<{me}> what does the caller expect?"),
                          ("alice", "The caller only checks truthiness today. Happy to change it if we want a reason code.")]},
            {"by": "me", "status": "fixed", "path": "src/throttle.py", "side": "R", "line": 4,
             "comments": [("me", "60 seconds is a magic number - can it be a module constant?"),
                          ("alice", "Done, it's WINDOW now.")]},
            {"by": "bob", "status": "active", "path": None,
             "comments": [("bob", "Looks good overall; one question inline.")]},
        ],
    },
    {
        "id": 102, "repo": "widgets", "source": "feature/config-reload", "author": "me",
        "title": "Reload config.toml on SIGHUP", "build": "succeeded",
        "description": "My own PR: the dashboard puts it under 'Created by me'.",
        "reviewers": [("alice", 10), ("bob", 0)],
        "commits": [
            ("Add a config file and drop the stale guide", {
                "config.toml": "[app]\nname = \"world\"\nverbose = false\n",
                "docs/guide.md": None,
                "src/app.py": "import signal\nimport sys\n\nfrom util import parse_args\n\nCONFIG = {}\n\n\n"
                              "def reload_config(*_):\n    with open('config.toml') as fh:\n"
                              "        CONFIG['raw'] = fh.read()\n\n\n"
                              "def main(argv):\n    signal.signal(signal.SIGHUP, reload_config)\n"
                              "    opts = parse_args(argv)\n    if opts.verbose:\n        print('starting')\n"
                              "    return run(opts)\n\n\ndef run(opts):\n    print('hello', opts.name)\n"
                              "    return 0\n\n\nif __name__ == '__main__':\n    sys.exit(main(sys.argv[1:]))\n",
            }),
        ],
        "threads": [
            {"by": "alice", "status": "active", "path": "src/app.py", "side": "R", "line": 9,
             "comments": [("alice", "Reading the file inside a signal handler can race with a write - "
                                    "maybe set a flag and reload in the main loop?")]},
        ],
    },
    {
        "id": 103, "repo": "widgets", "source": "wip/metrics", "author": "carol", "draft": True,
        "title": "WIP: request metrics", "build": "running", "queue": 2,
        "description": "Draft - not ready for review.",
        "reviewers": [("me", 0)],
        "commits": [
            ("Sketch a metrics module", {
                "src/metrics.py": "COUNTS = {}\n\n\ndef hit(name):\n    COUNTS[name] = COUNTS.get(name, 0) + 1\n",
            }),
        ],
        "threads": [],
    },
    {
        "id": 104, "repo": "widgets", "source": "fix/util-off-by-one", "author": "bob",
        "title": "Fix --name reading the flag instead of its value", "build": "failed", "conflict": True,
        "policies": [("Build", "rejected"), ("Minimum reviewers", "queued")],
        "missing": ["Carol Chen"],
        "description": "parse_args used argv[i] where it meant argv[i + 1].",
        "reviewers": [("me", -5), ("carol", 0)],
        "commits": [
            ("Read the value after --name", {
                "src/util.py": BASE_FILES["src/util.py"].replace("opts.name = argv[i]", "opts.name = argv[i + 1]"),
                "tests/test_app.py": BASE_FILES["tests/test_app.py"].replace("name = 'x'\n", "name = 'x'   \n"),
            }),
        ],
        "threads": [
            {"by": "me", "status": "active", "path": "src/util.py", "side": "R", "line": 10,
             "comments": [("me", "This still IndexErrors when --name is the last argument."),
                          ("bob", "Good catch, will guard it.")]},
        ],
    },
    {
        "id": 105, "repo": "widgets", "source": "chore/readme-typos", "author": "alice",
        "title": "README wording", "build": "succeeded", "auto": True,
        "description": "Tiny wording fixes; auto-complete is on.",
        "reviewers": [("me", 10), ("bob", 5)],
        "commits": [
            ("Tidy the README", {
                "README.md": BASE_FILES["README.md"].replace("A small demo repository", "A small demonstration repository"),
            }),
        ],
        "threads": [],
    },
    {
        "id": 201, "repo": "gadgets", "source": "feature/knob", "author": "carol",
        "title": "Add a knob to the gadget", "build": "none",
        "description": "This repo isn't cloned under clones_dir yet: <CR> on it exercises the clone-on-open path.",
        "reviewers": [("me", 0), ("alice", 0)],
        "commits": [
            ("Add turn()", {
                "gadget.py": "def spin():\n    return 'whirr'\n\n\ndef turn(degrees):\n    return 'click' * (degrees // 90)\n",
            }),
        ],
        "threads": [],
    },
]

SPRINTS = [
    ("Sprint 41", -14, -1, "past"),
    ("Sprint 42", 0, 13, "current"),
    ("Sprint 43", 14, 27, "future"),
]

WI_FIXTURES = [
    {"id": 3001, "type": "User Story", "state": "Active", "title": "Throttle repeated login failures",
     "assignedTo": "me", "priority": 1, "tags": "security", "parentId": 2999, "sprint": 1,
     "description": "Lock an account for a minute after five bad passwords.",
     "acceptanceCriteria": "Sixth attempt within 60s is refused even with the right password.",
     "prs": [101], "comments": [("alice", "PR is up: !101")]},
    {"id": 3002, "type": "Bug", "state": "New", "title": "--name takes the flag as its value",
     "assignedTo": "me", "priority": 2, "tags": "", "parentId": None, "sprint": 1,
     "description": "See PR 104.", "reproSteps": "Run `app --name x` and observe the greeting says '--name'.",
     "prs": [104], "comments": []},
    {"id": 3003, "type": "User Story", "state": "Resolved", "title": "Reload configuration without a restart",
     "assignedTo": "me", "priority": 2, "tags": "ops", "parentId": 2999, "sprint": 1,
     "description": "Operators want to change config.toml and send SIGHUP.", "prs": [102], "comments": []},
    {"id": 3004, "type": "User Story", "state": "New", "title": "Request metrics endpoint",
     "assignedTo": "me", "priority": 3, "tags": "", "parentId": None, "sprint": 2,
     "description": "Expose per-route hit counts.", "prs": [103], "comments": []},
    {"id": 3005, "type": "Bug", "state": "Closed", "title": "Typos in README",
     "assignedTo": "me", "priority": 4, "tags": "docs", "parentId": None, "sprint": 0,
     "description": "", "prs": [105], "comments": [("me", "Fixed in the wording PR.")]},
    {"id": 2999, "type": "Feature", "state": "Active", "title": "Account hardening",
     "assignedTo": "alice", "priority": 1, "tags": "security", "parentId": None, "sprint": None,
     "description": "Parent feature for the security stories.", "prs": [], "comments": []},
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def now_iso():
    return iso(datetime.now(timezone.utc))


def humanize(iso_s):
    try:
        dt = datetime.strptime(iso_s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return ""
    delta = datetime.now(timezone.utc) - dt
    secs = int(delta.total_seconds())
    if secs < 60:
        return "now"
    if secs < 3600:
        return "{0}m ago".format(secs // 60)
    if secs < 86400:
        return "{0}h ago".format(secs // 3600)
    days = secs // 86400
    return "yesterday" if days == 1 else "{0}d ago".format(days)


def surname(name):
    m = re.match(r"^([^,]+),", name or "")
    if m:
        return m.group(1).strip()
    parts = (name or "").split()
    return parts[-1] if parts else name


def vote_glyph(v):
    v = int(v or 0)
    if v in (10, 5):
        return "\u2713"
    if v == -10:
        return "\u2717"
    if v == -5:
        return "~"
    return "\u00b7"


def git(cwd, *args, **kw):
    env = dict(os.environ)
    env.update(kw.pop("env", {}))
    return subprocess.run(["git"] + list(args), cwd=cwd, env=env, check=True, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kw).stdout


def write_files(root, files):
    for rel, content in files.items():
        path = os.path.join(root, rel)
        if content is None:
            if os.path.exists(path):
                os.remove(path)
            continue
        os.makedirs(os.path.dirname(path) or root, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)


class Workspace:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.state_path = os.path.join(self.root, "state.json")
        self.log_path = os.path.join(self.root, "calls.log")
        self.clones = os.path.join(self.root, "clones")
        self.origins = os.path.join(self.root, "origin")

    def load(self):
        with open(self.state_path, encoding="utf-8") as fh:
            return json.load(fh)

    def save(self, state):
        fd, tmp = tempfile.mkstemp(dir=self.root, prefix="state.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=1, ensure_ascii=False)
        os.replace(tmp, self.state_path)

    def log(self, argv, env):
        keys = sorted(k for k in env if k.startswith("AZVICLI_") and k != "AZVICLI_FAKE_WS")
        bits = ["{0}={1}".format(k, env[k]) for k in keys if env[k] != ""]
        line = "{0}  {1}  [{2}]\n".format(time.strftime("%H:%M:%S"), json.dumps(argv), " ".join(bits))
        try:
            with open(self.log_path, "a", encoding="utf-8") as fh:
                fh.write(line)
        except OSError:
            pass

    def clone_url(self, repo):
        return os.path.join(self.origins, repo + ".git")


# ---------------------------------------------------------------------------
# setup: build the git repositories, config and initial state
# ---------------------------------------------------------------------------

def build_repo(ws, repo, base_files, prs, day0):
    """Bare origin at <ws>/origin/<repo>.git with `main` plus one branch per
    PR; returns {branch: [(sha, iso date), ...]} oldest first."""
    bare = ws.clone_url(repo)
    os.makedirs(os.path.dirname(bare), exist_ok=True)
    git(ws.root, "init", "-q", "--bare", "-b", "main", bare)
    work = tempfile.mkdtemp(prefix="fake-work-", dir=ws.root)
    git(work, "init", "-q", "-b", "main")
    git(work, "config", "user.email", "demo@example.com")
    git(work, "config", "user.name", MY_NAME)
    git(work, "remote", "add", "origin", bare)

    def commit(msg, author, when):
        env = {"GIT_AUTHOR_NAME": author["displayName"], "GIT_AUTHOR_EMAIL": author["id"][:8] + "@example.com",
               "GIT_AUTHOR_DATE": when.isoformat(), "GIT_COMMITTER_DATE": when.isoformat()}
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", msg, env=env)
        return git(work, "rev-parse", "HEAD").strip()

    write_files(work, base_files)
    commit("Initial import", PEOPLE["me"], day0 - timedelta(days=20))
    if "src/app.py" in base_files:
        write_files(work, {"src/__init__.py": ""})
        commit("Make src a package", PEOPLE["bob"], day0 - timedelta(days=15))
    git(work, "push", "-q", "origin", "main")

    branches = {}
    for i, pr in enumerate(prs):
        git(work, "checkout", "-q", "main")
        git(work, "checkout", "-q", "-b", pr["source"])
        when = day0 - timedelta(days=6 - i, hours=3 * i)
        shas = []
        for j, (msg, files) in enumerate(pr["commits"]):
            write_files(work, files)
            t = when + timedelta(hours=j)
            shas.append((commit(msg, PEOPLE[pr["author"]], t), iso(t)))
        git(work, "push", "-q", "origin", pr["source"])
        branches[pr["source"]] = shas
    git(work, "checkout", "-q", "main")
    shutil.rmtree(work, ignore_errors=True)
    return branches


def make_thread(state, pr, spec):
    tid = state["next_id"]
    state["next_id"] += 1
    when = datetime.now(timezone.utc) - timedelta(hours=len(state["threads"].get(str(pr["id"]), [])) + 5)
    comments = []
    for k, (who, text) in enumerate(spec["comments"]):
        cid = k + 1
        comments.append({
            "id": cid, "parentCommentId": 0 if k == 0 else 1,
            "author": PEOPLE[who], "content": text.replace("{me}", MY_ID),
            "publishedDate": iso(when + timedelta(minutes=10 * k)),
            "lastUpdatedDate": iso(when + timedelta(minutes=10 * k)),
            "commentType": "text", "isDeleted": False,
        })
    thread = {
        "id": tid, "status": spec["status"], "isDeleted": False,
        "publishedDate": comments[0]["publishedDate"], "lastUpdatedDate": comments[-1]["lastUpdatedDate"],
        "comments": comments, "threadContext": None, "properties": {},
    }
    if spec.get("path"):
        ctx = {"filePath": "/" + spec["path"]}
        if spec.get("line"):
            side = "right" if spec.get("side", "R") == "R" else "left"
            ctx[side + "FileStart"] = {"line": spec["line"], "offset": 1}
            ctx[side + "FileEnd"] = {"line": spec.get("end") or spec["line"], "offset": 999}
        thread["threadContext"] = ctx
    return thread


def cmd_setup(root, fresh=False):
    ws = Workspace(root)
    if fresh and os.path.isdir(ws.root):
        shutil.rmtree(ws.root)
    if os.path.isfile(ws.state_path) and os.path.isdir(ws.origins):
        print("fake-provider: workspace already built at {0} (pass --fresh to rebuild)".format(ws.root))
        return 0
    os.makedirs(ws.clones, exist_ok=True)
    for sub in ("config", "data", "cache", "xdg-state"):
        os.makedirs(os.path.join(ws.root, sub), exist_ok=True)

    day0 = datetime.now(timezone.utc)
    by_repo = {}
    for pr in PR_FIXTURES:
        by_repo.setdefault(pr["repo"], []).append(pr)
    branches = {}
    branches["widgets"] = build_repo(ws, "widgets", BASE_FILES, by_repo["widgets"], day0)
    branches["gadgets"] = build_repo(ws, "gadgets", GADGET_FILES, by_repo["gadgets"], day0)
    # widgets is cloned already; gadgets deliberately is not (clone-on-open).
    git(ws.root, "clone", "-q", ws.clone_url("widgets"), os.path.join(ws.clones, "widgets"))

    state = {"next_id": 5000, "prs": [], "threads": {}, "iterations": {}, "workitems": [], "sprints": [],
             "members": [PEOPLE[k]["displayName"] for k in ("me", "alice", "bob", "carol")]}
    for pr in PR_FIXTURES:
        shas = branches[pr["repo"]][pr["source"]]
        rec = {
            "id": pr["id"], "title": pr["title"], "repo": pr["repo"], "source": pr["source"], "target": "main",
            "author": pr["author"], "isDraft": bool(pr.get("draft")), "autoComplete": bool(pr.get("auto")),
            "autoCompleteSetBy": PEOPLE[pr["author"]]["displayName"] if pr.get("auto") else "",
            "description": pr["description"], "buildStatus": pr["build"], "queuePosition": pr.get("queue", -1),
            "buildUrl": "{0}/{1}/_build/results?buildId={2}".format(ORG, PROJECT, 7000 + pr["id"]) if pr["build"] != "none" else "",
            "policies": [{"name": n, "status": s} for n, s in pr.get("policies", [])],
            "missingReviewers": pr.get("missing", []), "mergeConflict": bool(pr.get("conflict")),
            "reviewers": [{"name": PEOPLE[k]["displayName"], "id": PEOPLE[k]["id"], "vote": v} for k, v in pr["reviewers"]],
            "updatedIso": shas[-1][1], "completed": False,
        }
        state["prs"].append(rec)
        state["threads"][str(pr["id"])] = [make_thread(state, pr, t) for t in pr["threads"]]
        state["iterations"][str(pr["id"])] = [
            {"id": i + 1, "description": "", "createdDate": when, "updatedDate": when,
             "sourceRefCommit": {"commitId": sha}, "targetRefCommit": {"commitId": ""}}
            for i, (sha, when) in enumerate(shas)
        ]
    for name, start, finish, timeframe in SPRINTS:
        state["sprints"].append({
            "name": name, "path": "{0}\\{1}".format(PROJECT, name),
            "start": iso(day0 + timedelta(days=start)), "finish": iso(day0 + timedelta(days=finish)),
            "timeframe": timeframe,
        })
    for wi in WI_FIXTURES:
        changed = day0 - timedelta(hours=wi["id"] % 40)
        rec = dict(wi)
        rec["assignedTo"] = PEOPLE[wi["assignedTo"]]["displayName"]
        rec["createdBy"] = PEOPLE["alice"]["displayName"]
        rec["createdDate"] = iso(changed - timedelta(days=10))
        rec["changedDate"] = iso(changed)
        rec["iterationPath"] = state["sprints"][wi["sprint"]]["path"] if wi["sprint"] is not None else PROJECT
        rec["areaPath"] = PROJECT + "\\Core"
        rec["reason"] = "New" if wi["state"] == "New" else "Work started"
        rec["comments"] = [{"author": PEOPLE[who]["displayName"], "date": iso(changed), "text": text}
                           for who, text in wi["comments"]]
        rec.pop("sprint", None)
        state["workitems"].append(rec)
    ws.save(state)

    with open(os.path.join(ws.root, "config", "azure-cli.yml"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# Demo config written by tests/fake-provider.py - nothing here is real.\n"
                 "# The fake provider ignores it; it exists so gO / :AzureCli doctor have a file to show.\n"
                 "accounts:\n"
                 "  - project_name: {0}\n"
                 "    org_url: {1}\n"
                 "    pat: not-a-real-token\n"
                 "    clones_dir: {2}\n"
                 "    work_items:\n"
                 "      team: {3}\n".format(PROJECT, ORG, ws.clones, TEAM))
    exe = os.path.join(ws.root, "azure-cli")
    with open(exe, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("#!/usr/bin/env bash\n# Stands in for the repo's azure-cli launcher (AZVICLI_EXE).\n"
                 "exec python3 {0} \"$@\"\n".format(json.dumps(os.path.abspath(__file__))))
    os.chmod(exe, 0o755)
    with open(ws.log_path, "a", encoding="utf-8"):
        pass
    print("fake-provider: workspace built at {0}".format(ws.root))
    return 0


# ---------------------------------------------------------------------------
# Dispatch: one provider invocation
# ---------------------------------------------------------------------------

def classify(pr):
    if pr.get("completed"):
        return None
    if pr["author"] == "me":
        return "Created"
    if pr["isDraft"]:
        return "Drafts"
    mine = [r for r in pr["reviewers"] if r["id"] == MY_ID]
    v = int(mine[0]["vote"]) if mine else 0
    if v in (10, 5):
        return "SignedOff"
    if v == -5:
        return "Waiting"
    return "Actionable"


def thread_counts(threads):
    live = [t for t in threads if not t.get("isDeleted") and t["comments"]]
    active = [t for t in live if t["status"] in ("active", "pending")]
    my_active = [t for t in active if t["comments"][0]["author"]["id"] == MY_ID]
    mention_all = [t for t in live if any("@<" + MY_ID + ">" in (c.get("content") or "") for c in t["comments"])]
    mention_active = [t for t in mention_all if t["status"] in ("active", "pending")]
    return len(active), len(live), len(my_active), len(mention_active), len(mention_all)


def to_record(ws, pr, threads):
    active, total, my_active, mention, mention_total = thread_counts(threads)
    signed = sum(1 for r in pr["reviewers"] if int(r["vote"]) in (10, 5))
    return {
        "id": pr["id"], "title": pr["title"], "repo": pr["repo"], "project": PROJECT, "org": ORG,
        "source": pr["source"], "target": pr["target"], "author": PEOPLE[pr["author"]]["displayName"],
        "updatedIso": pr["updatedIso"], "updatedHuman": humanize(pr["updatedIso"]),
        "isDraft": pr["isDraft"], "state": classify(pr),
        "autoComplete": pr["autoComplete"], "autoCompleteSetBy": pr["autoCompleteSetBy"],
        "voteRatio": "{0} / {1}".format(signed, len(pr["reviewers"])),
        "reviewerSummary": " ".join(vote_glyph(r["vote"]) + surname(r["name"]) for r in pr["reviewers"]),
        "activeThreads": active, "closedThreads": total - active, "totalThreads": total,
        "myActiveThreads": my_active, "mentionThreads": mention, "mentionTotal": mention_total,
        "description": pr["description"], "buildStatus": pr["buildStatus"], "queuePosition": pr["queuePosition"],
        "buildUrl": pr["buildUrl"], "policies": pr["policies"], "missingReviewers": pr["missingReviewers"],
        "mergeConflict": pr["mergeConflict"],
        "url": "{0}/{1}/_git/{2}/pullrequest/{3}".format(ORG, PROJECT, pr["repo"], pr["id"]),
        "cloneUrl": ws.clone_url(pr["repo"]), "clonesDir": ws.clones,
        "myId": MY_ID, "myName": MY_NAME, "reviewers": pr["reviewers"],
    }


class Fake:
    def __init__(self, ws, env):
        self.ws = ws
        self.env = env
        self.state = ws.load()

    # -- shared -------------------------------------------------------------

    def pr_id(self):
        return self.env.get("AZVICLI_PR") or ""

    def pr(self):
        pid = self.pr_id()
        for p in self.state["prs"]:
            if str(p["id"]) == pid:
                return p
        return None

    def threads(self):
        return self.state["threads"].setdefault(self.pr_id(), [])

    def find_thread(self, tid):
        for t in self.threads():
            if str(t["id"]) == str(tid):
                return t
        return None

    def new_comment(self, text, parent=0, cid=None):
        return {"id": cid, "parentCommentId": parent, "author": PEOPLE["me"], "content": text,
                "publishedDate": now_iso(), "lastUpdatedDate": now_iso(), "commentType": "text", "isDeleted": False}

    def need_pr(self):
        for name in ("AZVICLI_ORG", "AZVICLI_PROJECT", "AZVICLI_REPO", "AZVICLI_PR"):
            if not self.env.get(name):
                print("{0} not set".format(name), file=sys.stderr)
                return False
        if self.pr() is None:
            print("fake-provider: PR {0} is not in state.json".format(self.pr_id()), file=sys.stderr)
            return False
        return True

    # -- --list / --whoami / --doctor / --ping ------------------------------

    def cmd_list(self):
        for pr in self.state["prs"]:
            if pr.get("completed"):
                continue
            print(json.dumps(to_record(self.ws, pr, self.state["threads"].get(str(pr["id"]), [])), ensure_ascii=False))
        return 0

    def cmd_whoami(self, rest):
        if "--org" not in rest:
            print("azure-cli --whoami requires --org <organization-url>.", file=sys.stderr)
            return 1
        print(json.dumps({"id": MY_ID, "displayName": MY_NAME}))
        return 0

    def cmd_doctor(self, rest):
        checks = [
            {"check": "config file", "ok": True, "detail": os.path.join(self.ws.root, "config", "azure-cli.yml")},
            {"check": "config fields", "ok": True, "detail": "1 account(s) (fake)"},
            {"check": "sign-in " + ORG, "ok": True, "detail": "signed in as {0} (fake provider, no network)".format(MY_NAME)},
            {"check": "work items", "ok": True, "detail": "{0} / {1} (fake)".format(PROJECT, TEAM)},
        ]
        if "--json" in rest:
            for c in checks:
                print(json.dumps(c))
        else:
            for c in checks:
                print("{0} {1}: {2}".format("ok " if c["ok"] else "FAIL", c["check"], c["detail"]))
        return 0

    # -- PR actions ----------------------------------------------------------

    def cmd_threads(self):
        if not self.need_pr():
            return 1
        live = [t for t in self.threads() if not t.get("isDeleted")]
        print(json.dumps({"value": live, "count": len(live)}, ensure_ascii=False))
        return 0

    def cmd_iterations(self):
        if not self.need_pr():
            return 1
        its = self.state["iterations"].get(self.pr_id(), [])
        print(json.dumps({"value": its, "count": len(its)}))
        return 0

    def add_thread(self, text, ctx):
        tid = self.state["next_id"]
        self.state["next_id"] += 1
        self.threads().append({
            "id": tid, "status": "active", "isDeleted": False, "publishedDate": now_iso(),
            "lastUpdatedDate": now_iso(), "comments": [self.new_comment(text, 0, 1)], "threadContext": ctx,
            "properties": {},
        })
        self.ws.save(self.state)
        print("Comment posted.")
        return 0

    def cmd_post(self, rest):
        if not self.need_pr():
            return 1
        path, side, line, text = (rest + ["", "", "", ""])[:4]
        end = rest[4] if len(rest) > 4 else ""
        if not path or not line.isdigit() or line == "0":
            print("Invalid line.")
            return 1
        if side not in ("R", "L"):
            print("Invalid side.")
            return 1
        key = "right" if side == "R" else "left"
        ctx = {"filePath": "/" + path.lstrip("/"),
               key + "FileStart": {"line": int(line), "offset": 1},
               key + "FileEnd": {"line": int(end) if end.isdigit() else int(line), "offset": 999}}
        return self.add_thread(text, ctx)

    def cmd_file_comment(self, rest):
        if not self.need_pr():
            return 1
        path, text = (rest + ["", ""])[:2]
        if not path:
            print("No file selected.")
            return 1
        return self.add_thread(text, {"filePath": "/" + path.lstrip("/")})

    def cmd_pr_comment(self, rest):
        if not self.need_pr():
            return 1
        return self.add_thread(rest[0] if rest else "", None)

    def cmd_reply(self, rest):
        if not self.need_pr():
            return 1
        tid, text = (rest + ["", ""])[:2]
        t = self.find_thread(tid)
        if not tid.isdigit() or t is None:
            print("Invalid thread id.")
            return 1
        if not text.strip():
            print("Empty reply.")
            return 1
        t["comments"].append(self.new_comment(text, 1, max(c["id"] for c in t["comments"]) + 1))
        t["lastUpdatedDate"] = now_iso()
        self.ws.save(self.state)
        print("Reply posted.")
        return 0

    def cmd_status(self, rest):
        if not self.need_pr():
            return 1
        tid, status = (rest + ["", ""])[:2]
        t = self.find_thread(tid)
        if not tid.isdigit() or t is None:
            print("Invalid thread id.")
            return 1
        mapped = THREAD_STATUS_MAP.get(status)
        if mapped is None:
            print("Invalid status: '{0}'".format(status))
            return 1
        t["status"] = mapped
        self.ws.save(self.state)
        print("Thread {0} set to {1}.".format(tid, mapped))
        return 0

    def cmd_edit_comment(self, rest, delete=False):
        if not self.need_pr():
            return 1
        tid, cid = (rest + ["", ""])[:2]
        text = rest[2] if len(rest) > 2 else ""
        t = self.find_thread(tid)
        if not tid.isdigit() or t is None:
            print("Invalid thread id.")
            return 1
        c = next((c for c in t["comments"] if str(c["id"]) == cid), None)
        if not cid.isdigit() or c is None:
            print("Invalid comment id.")
            return 1
        if delete:
            c["isDeleted"] = True
            c["content"] = ""
            if all(x.get("isDeleted") for x in t["comments"]):
                t["isDeleted"] = True
            self.ws.save(self.state)
            print("Comment {0} (thread {1}) deleted.".format(cid, tid))
            return 0
        if not text.strip():
            print("Empty comment.")
            return 1
        c["content"] = text
        c["lastUpdatedDate"] = now_iso()
        self.ws.save(self.state)
        print("Comment {0} (thread {1}) updated.".format(cid, tid))
        return 0

    def cmd_vote(self, rest):
        if not self.need_pr():
            return 1
        vote = rest[0] if rest else ""
        if vote not in VOTES:
            print("Invalid vote: '{0}'".format(vote))
            return 1
        pr = self.pr()
        mine = next((r for r in pr["reviewers"] if r["id"] == MY_ID), None)
        if mine is None:
            mine = {"name": MY_NAME, "id": MY_ID, "vote": 0}
            pr["reviewers"].append(mine)
        mine["vote"] = int(vote)
        self.ws.save(self.state)
        print("Vote set to {0}.".format(vote))
        return 0

    def cmd_complete(self, rest):
        if not self.need_pr():
            return 1
        strategy = rest[0] if rest else ""
        if strategy not in MERGE_STRATEGIES:
            print("Invalid merge strategy: '{0}'".format(strategy))
            return 1
        pr = self.pr()
        if pr["mergeConflict"]:
            print("REST complete failed: HTTP 409: the pull request has merge conflicts (fake).", file=sys.stderr)
            return 1
        pr["completed"] = True
        self.ws.save(self.state)
        print("PR #{0} completed ({1}).".format(pr["id"], strategy))
        return 0

    def cmd_auto_complete(self, rest):
        if not self.need_pr():
            return 1
        mode = rest[0] if rest else ""
        pr = self.pr()
        if mode == "off":
            pr["autoComplete"], pr["autoCompleteSetBy"] = False, ""
            self.ws.save(self.state)
            print("Auto-complete disabled for PR #{0}.".format(pr["id"]))
            return 0
        strategy = rest[1] if len(rest) > 1 and rest[1] else "squash"
        if strategy not in MERGE_STRATEGIES:
            print("Invalid merge strategy: '{0}'".format(strategy))
            return 1
        pr["autoComplete"], pr["autoCompleteSetBy"] = True, MY_NAME
        self.ws.save(self.state)
        print("Auto-complete enabled for PR #{0} ({1}).".format(pr["id"], strategy))
        return 0

    def cmd_requeue(self, rest):
        pid = rest[0] if rest else ""
        pr = next((p for p in self.state["prs"] if str(p["id"]) == pid), None)
        if pr is None:
            print("PR {0} was not found in any configured account.".format(pid))
            return 1
        if pr["buildStatus"] not in ("failed", "expired"):
            print("No expired or failed build validation to re-queue for PR {0}.".format(pid))
            return 0
        pr["buildStatus"], pr["queuePosition"] = "running", 1
        pr["policies"] = [dict(p, status="running") if p["status"] == "rejected" else p for p in pr["policies"]]
        self.ws.save(self.state)
        print("Re-queued 1 build validation(s) for PR {0}.".format(pid))
        return 0

    # -- prefetch (no argv, AZVICLI_PREFETCH=1|all) ---------------------------

    def cmd_prefetch(self):
        for name in ("AZVICLI_ORG", "AZVICLI_PROJECT", "AZVICLI_REPO", "AZVICLI_PR"):
            if not self.env.get(name):
                print("{0} not set".format(name), file=sys.stderr)
                return 1
        repo_path = self.env.get("AZVICLI_REPO_PATH") or os.getcwd()
        if not os.path.isdir(os.path.join(repo_path, ".git")):
            return 0
        mode = self.env.get("AZVICLI_PREFETCH") or ""
        source, target = self.env.get("AZVICLI_SOURCE") or "", self.env.get("AZVICLI_TARGET") or ""
        refspecs = []
        if mode != "all":
            if not source or not target:
                return 0
            refspecs = ["+refs/heads/{0}:refs/remotes/origin/{0}".format(b) for b in (source, target)]
        proc = subprocess.run(["git", "-c", "fetch.showForcedUpdates=false", "fetch", "--quiet", "--no-tags",
                               "origin"] + refspecs, cwd=repo_path, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        return proc.returncode

    # -- work items ----------------------------------------------------------

    def wi(self, wid):
        return next((w for w in self.state["workitems"] if str(w["id"]) == str(wid)), None)

    def wi_list_record(self, w):
        return {"id": w["id"], "type": w["type"], "state": w["state"], "title": w["title"],
                "assignedTo": w["assignedTo"], "priority": w.get("priority"), "tags": w.get("tags", ""),
                "parentId": w.get("parentId"), "changedIso": w["changedDate"], "changedHuman": humanize(w["changedDate"]),
                "url": "{0}/{1}/_workitems/edit/{2}".format(ORG, PROJECT, w["id"])}

    def sprint_meta(self, timeframe):
        sprints = self.state["sprints"]
        cur = next(i for i, s in enumerate(sprints) if s["timeframe"] == "current")
        target = sprints[cur] if timeframe == "current" else (sprints[cur + 1] if cur + 1 < len(sprints) else None)
        if target is None:
            return None, None
        nxt = sprints[cur + 1] if cur + 1 < len(sprints) else {}
        meta = {"_meta": True, "timeframe": timeframe, "sprintName": target["name"], "sprintPath": target["path"],
                "sprintStart": target["start"], "sprintFinish": target["finish"]}
        if timeframe == "current":
            meta.update({"nextSprintName": nxt.get("name", ""), "nextSprintPath": nxt.get("path", ""),
                         "nextStart": nxt.get("start", ""), "nextFinish": nxt.get("finish", "")})
        return meta, target["path"]

    def cmd_wi_list(self, rest):
        select = rest[0] if rest else "current"
        item_path = rest[1] if len(rest) > 1 else ""
        if select not in ("current", "next", "sprints", "items", "members"):
            print("ERROR: selector must be current|next|sprints|items|members, got '{0}'".format(select), file=sys.stderr)
            return 1
        if select == "sprints":
            sprints = self.state["sprints"]
            ci = next(i for i, s in enumerate(sprints) if s["timeframe"] == "current") + 1
            out = {"_sprints": True, "quarter": PROJECT, "currentIndex": ci, "types": ["User Story", "Bug"],
                   "sprints": [{"name": s["name"], "label": s["name"], "path": s["path"], "start": s["start"],
                                "finish": s["finish"], "timeframe": s["timeframe"], "current": s["timeframe"] == "current"}
                               for s in sprints]}
            print(json.dumps(out, ensure_ascii=False))
            return 0
        if select == "members":
            for name in self.state["members"]:
                print(json.dumps({"name": name, "email": name.lower().replace(" ", ".") + "@example.com"}))
            return 0
        if select == "items":
            if not item_path:
                print("ERROR: 'items' needs an iteration path", file=sys.stderr)
                return 1
            path = item_path
        else:
            meta, path = self.sprint_meta(select)
            if meta is None:
                print("ERROR: could not determine {0} sprint".format(select), file=sys.stderr)
                return 1
            print(json.dumps(meta, ensure_ascii=False))
        # Like the real WIQL: the configured assignee's (= my) items in that sprint.
        for w in self.state["workitems"]:
            if w["iterationPath"] == path and w["assignedTo"] == MY_NAME:
                print(json.dumps(self.wi_list_record(w), ensure_ascii=False))
        return 0

    def cmd_wi_detail(self, rest):
        wid = rest[0] if rest else ""
        w = self.wi(wid)
        if w is None:
            print("ERROR: work item {0} not found".format(wid), file=sys.stderr)
            return 1
        summary = lambda x: {k: x[k] for k in ("id", "type", "state", "title", "assignedTo")}  # noqa: E731
        item = {k: w.get(k, "") for k in ("id", "type", "state", "title", "assignedTo", "createdBy", "createdDate",
                                          "changedDate", "priority", "areaPath", "iterationPath", "tags", "reason",
                                          "description", "acceptanceCriteria", "reproSteps")}
        item["url"] = "{0}/{1}/_workitems/edit/{2}".format(ORG, PROJECT, w["id"])
        item["pullRequests"] = [{"id": p} for p in w.get("prs", [])]
        parent = self.wi(w["parentId"]) if w.get("parentId") else None
        children = [x for x in self.state["workitems"] if x.get("parentId") == w["id"]]
        print(json.dumps({"item": item, "parent": summary(parent) if parent else None,
                          "children": [summary(c) for c in children], "comments": w.get("comments", []),
                          "commentsUnsupported": False}, ensure_ascii=False))
        return 0

    def cmd_wi_state(self, rest):
        cmd = rest[0] if rest else ""
        a2, a3, a4 = (rest[1:] + ["", "", ""])[:3]
        if cmd == "transitions":
            if not a2:
                print("ERROR: transitions needs <type>", file=sys.stderr)
                return 1
            for to in WI_TRANSITIONS.get(a3, []):
                print(to)
            return 0
        if cmd == "reasons":
            if not a2 or not a3:
                print("ERROR: reasons needs <type> <toState>", file=sys.stderr)
                return 1
            for r in WI_REASONS.get(a3, []):
                print(r)
            return 0
        if cmd == "set":
            w = self.wi(a2)
            if not a2 or not a3:
                print("ERROR: set needs <id> <newState>", file=sys.stderr)
                return 1
            if w is None:
                print("ERROR: HTTP 404 PATCH: work item {0} does not exist".format(a2), file=sys.stderr)
                return 1
            w["state"], w["changedDate"] = a3, now_iso()
            if a4:
                w["reason"] = a4
            self.ws.save(self.state)
            print(a3)
            return 0
        print("usage: --wi-state transitions <type> <currentState> | reasons <type> <toState> | "
              "set <id> <newState> [reason]", file=sys.stderr)
        return 1

    def cmd_wi_edit(self, rest):
        cmd = rest[0] if rest else ""
        a2, a3, a4, a5, a6 = (rest[1:] + ["", "", "", "", ""])[:5]
        if cmd == "create":
            if not a2 or not a3:
                print("ERROR: create needs <type> <title>", file=sys.stderr)
                return 1
            wid = self.state["next_id"]
            self.state["next_id"] += 1
            sprint = next((s for s in self.state["sprints"] if s["path"] == a5), None)
            self.state["workitems"].append({
                "id": wid, "type": a2, "state": "New", "title": a3, "assignedTo": MY_NAME, "createdBy": MY_NAME,
                "createdDate": now_iso(), "changedDate": now_iso(), "priority": 2, "areaPath": PROJECT + "\\Core",
                "iterationPath": sprint["path"] if sprint else PROJECT, "tags": "", "reason": "New",
                "description": "", "acceptanceCriteria": "", "reproSteps": "",
                "parentId": int(a4) if a4.isdigit() else None, "prs": [], "comments": [],
            })
            self.ws.save(self.state)
            print(json.dumps({"id": wid, "title": a3}, ensure_ascii=False))
            return 0
        if cmd == "set":
            w = self.wi(a2)
            if not a2 or not a3:
                print("ERROR: set needs <id> <field> <value>", file=sys.stderr)
                return 1
            if a3 not in WI_FIELDS:
                print("ERROR: unknown field '{0}', expected one of: {1}".format(a3, ", ".join(sorted(WI_FIELDS))),
                      file=sys.stderr)
                return 1
            if w is None:
                print("ERROR: HTTP 404 PATCH: work item {0} does not exist".format(a2), file=sys.stderr)
                return 1
            key, caster = WI_FIELDS[a3]
            value = a4 if a4 or a3 != "assignedTo" else MY_NAME
            try:
                value = caster(value)
            except (TypeError, ValueError):
                print("ERROR: invalid value for {0}: {1!r}".format(a3, a4), file=sys.stderr)
                return 1
            w[key], w["changedDate"] = value, now_iso()
            self.ws.save(self.state)
            print(json.dumps({"id": w["id"], "field": a3, "value": value}, ensure_ascii=False))
            return 0
        if cmd == "comment":
            w = self.wi(a2)
            if not a2 or not a3:
                print("ERROR: comment needs <id> <text>", file=sys.stderr)
                return 1
            if w is None:
                print("ERROR: HTTP 404 POST: work item {0} does not exist".format(a2), file=sys.stderr)
                return 1
            cid = self.state["next_id"]
            self.state["next_id"] += 1
            w.setdefault("comments", []).append({"author": MY_NAME, "date": now_iso(), "text": a3})
            self.ws.save(self.state)
            print(json.dumps({"id": cid}))
            return 0
        if cmd == "link-pr":
            w = self.wi(a2)
            if not (a2 and a3 and a4 and a5 and a6):
                print("ERROR: link-pr needs <wiId> <orgUrl> <project> <repoName> <prId>", file=sys.stderr)
                return 1
            if w is None:
                print("ERROR: HTTP 404 PATCH: work item {0} does not exist".format(a2), file=sys.stderr)
                return 1
            pid = int(a6) if a6.isdigit() else a6
            if pid not in w.setdefault("prs", []):
                w["prs"].append(pid)
            self.ws.save(self.state)
            print(json.dumps({"linked": pid}))
            return 0
        if cmd == "unlink-pr":
            w = self.wi(a2)
            if not a2 or not a3:
                print("ERROR: unlink-pr needs <wiId> <prId>", file=sys.stderr)
                return 1
            pid = int(a3) if a3.isdigit() else a3
            if w is None or pid not in w.get("prs", []):
                print("ERROR: no linked pull request {0} found on #{1}".format(a3, a2), file=sys.stderr)
                return 1
            w["prs"].remove(pid)
            self.ws.save(self.state)
            print(json.dumps({"unlinked": pid}))
            return 0
        print("usage: --wi-edit create <type> <title> [parentId] [iterationPath] | set <id> <field> <value> | "
              "comment <id> <text> | link-pr <wiId> <orgUrl> <project> <repoName> <prId> | unlink-pr <wiId> <prId>",
              file=sys.stderr)
        return 1


def dispatch(ws, argv, env):
    """Runs one provider invocation (argv = what azure-cli.py would have seen
    after its own path) and returns its exit code; output goes to the
    current sys.stdout/sys.stderr."""
    ws.log(argv, env)
    if not argv:
        if env.get("AZVICLI_PREFETCH"):
            return Fake(ws, env).cmd_prefetch()
        print("fake-provider: no flags means 'launch the dashboard', which this fake doesn't do - "
              "run `bash tests/demo.sh` instead.", file=sys.stderr)
        return 1
    flag, rest = argv[0], argv[1:]
    if flag == "--ping":
        print("pong")
        return 0
    f = Fake(ws, env)
    table = {
        "--list": lambda: f.cmd_list(),
        "--whoami": lambda: f.cmd_whoami(rest),
        "--print-pat": lambda: (sys.stdout.write("not-a-real-token"), 0)[1],
        "--doctor": lambda: f.cmd_doctor(rest),
        "--threads": lambda: f.cmd_threads(),
        "--iterations": lambda: f.cmd_iterations(),
        "--post": lambda: f.cmd_post(rest),
        "--file-comment": lambda: f.cmd_file_comment(rest),
        "--pr-comment": lambda: f.cmd_pr_comment(rest),
        "--reply": lambda: f.cmd_reply(rest),
        "--status": lambda: f.cmd_status(rest),
        "--edit-comment": lambda: f.cmd_edit_comment(rest),
        "--delete-comment": lambda: f.cmd_edit_comment(rest, delete=True),
        "--vote": lambda: f.cmd_vote(rest),
        "--complete": lambda: f.cmd_complete(rest),
        "--auto-complete": lambda: f.cmd_auto_complete(rest),
        "--requeue": lambda: f.cmd_requeue(rest),
        "--wi-list": lambda: f.cmd_wi_list(rest),
        "--wi-detail": lambda: f.cmd_wi_detail(rest),
        "--wi-state": lambda: f.cmd_wi_state(rest),
        "--wi-edit": lambda: f.cmd_wi_edit(rest),
    }
    handler = table.get(flag)
    if handler is None:
        print("fake-provider: unsupported invocation {0}".format(json.dumps(argv)), file=sys.stderr)
        return 1
    return handler()


def serve(ws):
    """The --serve daemon: one JSON request per stdin line, one JSON response
    per stdout line, same wire protocol as azure-cli.py's serve()."""
    stdin = sys.stdin.buffer
    real_out = sys.stdout
    while True:
        line = stdin.readline()
        if not line:
            return 0
        line = line.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError("request is not an object")
        except ValueError as ex:
            real_out.write(json.dumps({"id": None, "code": 1, "stdout": "", "stderr": "bad request: {0}\n".format(ex)}) + "\n")
            real_out.flush()
            continue
        env = dict(os.environ)
        env.update({k: str(v) for k, v in (req.get("env") or {}).items()})
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = dispatch(ws, [str(a) for a in (req.get("argv") or [])], env)
        except Exception as ex:  # noqa: BLE001 - a broken handler must not kill the daemon
            code = 1
            err.write("fake-provider: {0}: {1}\n".format(type(ex).__name__, ex))
        real_out.write(json.dumps({"id": req.get("id"), "code": code, "stdout": out.getvalue(),
                                   "stderr": err.getvalue()}, ensure_ascii=False) + "\n")
        real_out.flush()


def main(argv):
    if argv[:1] == ["setup"]:
        if len(argv) < 2:
            print("usage: fake-provider.py setup <workspace-dir> [--fresh]", file=sys.stderr)
            return 2
        return cmd_setup(argv[1], fresh="--fresh" in argv[2:])
    # Invoked as the "python interpreter": drop the azure-cli.py path.
    if argv and argv[0].endswith("azure-cli.py"):
        argv = argv[1:]
    root = os.environ.get("AZVICLI_FAKE_WS")
    if not root or not os.path.isfile(os.path.join(root, "state.json")):
        print("fake-provider: AZVICLI_FAKE_WS must point at a workspace built by "
              "`fake-provider.py setup <dir>` (tests/demo.sh does this).", file=sys.stderr)
        return 1
    ws = Workspace(root)
    if argv[:1] == ["--serve"]:
        return serve(ws)
    return dispatch(ws, argv, dict(os.environ))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
