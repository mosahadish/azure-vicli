#!/usr/bin/env bash
#
# wi-detail.sh <id> - fetch a single work item plus its parent and children for
# the Neovim detail view (wi-view.lua). Prints one JSON object to stdout:
#   { "item": {...}, "parent": {...}|null, "children": [ {...}, ... ],
#     "comments": [ {...}, ... ], "commentsUnsupported": bool }
# HTML fields (description / acceptance criteria / repro steps, and comment
# text) are flattened to plain text so they render cleanly in a scratch
# buffer. The item object's "pullRequests" field lists the pull requests
# linked to it via ArtifactLink relations, as [{"id":..}, ...].
#
# Comments come from GET .../workItems/{id}/comments (api-version
# 7.1-preview.4), oldest first. Older on-prem TFS instances don't expose this
# endpoint: an HTTP 404/400 degrades to an empty "comments" list plus
# "commentsUnsupported": true instead of failing the whole detail fetch.
#
# Config via environment (same defaults as wi-list.sh):
#   ADO_PAT always resolved from azure-cli.yml via azure-cli.exe --print-pat
#   (never from an ambient env var - config is the only source),
#   WIDASH_COLLECTION, WIDASH_PROJECT
set -euo pipefail

ID="${1:?ERROR: usage: wi-detail.sh <work-item-id>}"
COLLECTION="${WIDASH_COLLECTION:-https://tfs.zeiss.org/tfs/SMT_SMS}"
PROJECT="${WIDASH_PROJECT:-BarLev-RnD}"

# Shared PAT lookup (pure-bash scan of PRDASH_PATS when launched through
# azure-cli.exe, else one --print-pat call) - see resolve-pat.sh.
if [[ "${BASH_SOURCE[0]}" == */* ]]; then . "${BASH_SOURCE[0]%/*}/resolve-pat.sh"; else . "./resolve-pat.sh"; fi
resolve_pat_into ADO_PAT "$COLLECTION" "$PROJECT" \
  || { echo "ERROR: no PAT available - add 'pat:' to this account in azure-cli.yml" >&2; exit 1; }
export ADO_PAT
export COLLECTION PROJECT ID

PY="python"; command -v python >/dev/null 2>&1 || PY="python3"

"$PY" - <<'PYEOF'
import os, sys, json, base64, re, urllib.request, urllib.error
from html.parser import HTMLParser

collection = os.environ["COLLECTION"]
project    = os.environ["PROJECT"]
auth       = base64.b64encode((":" + os.environ["ADO_PAT"]).encode()).decode()
wid        = os.environ["ID"]
api        = "7.1"

def api_request(url, method="GET", data=None):
    headers = {"Authorization": f"Basic {auth}", "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = data.encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:400]
        print(f"ERROR: HTTP {e.code} {method} {url}\n{body}", file=sys.stderr)
        sys.exit(2)

class _Text(HTMLParser):
    BLOCK = {"p","div","br","li","tr","h1","h2","h3","h4","ul","ol","table"}
    def __init__(self):
        super().__init__(); self.out = []
    def handle_starttag(self, tag, attrs):
        if tag == "li": self.out.append("\n- ")
        elif tag in self.BLOCK: self.out.append("\n")
    def handle_endtag(self, tag):
        if tag in self.BLOCK: self.out.append("\n")
    def handle_data(self, data):
        self.out.append(data)

def html_to_text(s):
    if not s: return ""
    p = _Text(); p.feed(str(s))
    txt = "".join(p.out)
    txt = re.sub(r"[ \t]+", " ", txt)
    txt = re.sub(r"\n[ \t]+", "\n", txt)
    txt = re.sub(r"\n{3,}", "\n\n", txt)
    return txt.strip()

def assigned_str(v):
    if isinstance(v, dict):
        return v.get("displayName","") or v.get("uniqueName","") or ""
    return "" if v is None else str(v)

def fetch_comments(wid):
    # On-prem TFS may not expose this endpoint at all: degrade to an empty
    # list rather than failing the whole detail fetch on HTTP 404/400.
    url = f"{collection}/{project}/_apis/wit/workItems/{wid}/comments?api-version=7.1-preview.4"
    headers = {"Authorization": f"Basic {auth}", "Accept": "application/json"}
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req) as resp:
            d = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code in (400, 404):
            return [], True
        body = e.read().decode("utf-8", errors="replace")[:400]
        print(f"ERROR: HTTP {e.code} GET {url}\n{body}", file=sys.stderr)
        sys.exit(2)
    raw = d.get("comments") if isinstance(d, dict) else None
    if raw is None:
        raw = d if isinstance(d, list) else []
    raw = sorted(raw, key=lambda c: (str(c.get("createdDate","")), c.get("id") or 0))
    out = []
    for c in raw:
        out.append({
            "id": c.get("id"),
            "author": assigned_str(c.get("createdBy","")),
            "date": str(c.get("createdDate","")),
            "text": html_to_text(c.get("text","")),
        })
    return out, False

def pr_ids_from_relations(relations):
    # ArtifactLink relations to a pull request look like
    # vstfs:///Git/PullRequestId/{projectGuid}%2F{repoGuid}%2F{prId} (the
    # last segment after the final %2F/%2f or plain "/" is the PR id).
    out = []
    for rel in (relations or []):
        if rel.get("rel") != "ArtifactLink":
            continue
        url = rel.get("url","") or ""
        if not url.startswith("vstfs:///Git/PullRequestId/"):
            continue
        m = re.search(r"(?:%2[Ff]|/)([0-9]+)$", url)
        if m:
            out.append({"id": int(m.group(1))})
    return out

def summary(wi):
    f = wi.get("fields") or {}
    return {
        "id": wi.get("id"),
        "type": str(f.get("System.WorkItemType","")),
        "state": str(f.get("System.State","")),
        "title": re.sub(r"\s+"," ", str(f.get("System.Title","")).strip()),
        "assignedTo": assigned_str(f.get("System.AssignedTo","")),
    }

full = api_request(f"{collection}/_apis/wit/workitems/{wid}?$expand=all&api-version={api}")
f = full.get("fields") or {}

parent_id = None
child_ids = []
for rel in (full.get("relations") or []):
    r = rel.get("rel","")
    m = re.search(r"/workItems/(\d+)$", rel.get("url",""))
    if not m: continue
    if r == "System.LinkTypes.Hierarchy-Reverse":
        parent_id = int(m.group(1))
    elif r == "System.LinkTypes.Hierarchy-Forward":
        child_ids.append(int(m.group(1)))

related = {}
need = ([parent_id] if parent_id else []) + child_ids
if need:
    r = api_request(f"{collection}/_apis/wit/workitemsbatch?api-version={api}",
                    method="POST",
                    data=json.dumps({"ids": need,
                                     "fields": ["System.Id","System.WorkItemType",
                                                "System.State","System.Title",
                                                "System.AssignedTo"]}))
    for wi in (r.get("value") or []):
        related[wi.get("id")] = summary(wi)

item = {
    "id": full.get("id"),
    "type": str(f.get("System.WorkItemType","")),
    "state": str(f.get("System.State","")),
    "title": re.sub(r"\s+"," ", str(f.get("System.Title","")).strip()),
    "assignedTo": assigned_str(f.get("System.AssignedTo","")),
    "createdBy": assigned_str(f.get("System.CreatedBy","")),
    "createdDate": str(f.get("System.CreatedDate","")),
    "changedDate": str(f.get("System.ChangedDate","")),
    "priority": f.get("Microsoft.VSTS.Common.Priority"),
    "areaPath": str(f.get("System.AreaPath","")),
    "iterationPath": str(f.get("System.IterationPath","")),
    "tags": str(f.get("System.Tags","") or ""),
    "reason": str(f.get("System.Reason","")),
    "description": html_to_text(f.get("System.Description","")),
    "acceptanceCriteria": html_to_text(f.get("Microsoft.VSTS.Common.AcceptanceCriteria","")),
    "reproSteps": html_to_text(f.get("Microsoft.VSTS.TCM.ReproSteps","")),
    "url": f"{collection}/{project}/_workitems/edit/{full.get('id')}",
    "pullRequests": pr_ids_from_relations(full.get("relations")),
}

comments, comments_unsupported = fetch_comments(wid)

out = {
    "item": item,
    "parent": related.get(parent_id) if parent_id else None,
    "children": [related[c] for c in child_ids if c in related],
    "comments": comments,
    "commentsUnsupported": comments_unsupported,
}
print(json.dumps(out, ensure_ascii=False))
PYEOF
