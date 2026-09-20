#!/usr/bin/env bash
#
# wi-state.sh - work-item state helper for the Neovim work-items dashboard
# (wi-dash.lua). Two subcommands:
#
#   wi-state.sh transitions <type> <currentState>
#       Print the allowed target states (one per line) reachable from
#       <currentState> for the given work item <type>, per the ADO workflow.
#       This is the same set the web UI's state dropdown offers. The current
#       state itself is omitted. The allowed transitions come from the work
#       item type's "transitions" map (GET .../wit/workitemtypes/{type}),
#       which is keyed by current state -> list of { to: <state> }.
#
#   wi-state.sh reasons <type> <toState>
#       Print the reasons (one per line) that are valid when a work item of
#       <type> enters <toState>, most-common first. ADO/on-prem TFS does not
#       expose per-transition reasons over REST, so this derives the real,
#       accepted vocabulary from existing work items already in <toState>.
#
#   wi-state.sh set <id> <newState> [reason]
#       Transition work item <id> to <newState> (System.State), optionally
#       also setting System.Reason to [reason]. Prints the resulting state on
#       success. Set WIDASH_VALIDATE_ONLY=1 to validate without persisting.
#
# Config via environment (same defaults as wi-list.sh):
#   ADO_PAT           always resolved from azure-cli.yml via
#                      azure-cli.exe --print-pat (never from an ambient env
#                      var - config is the only source)
#   WIDASH_COLLECTION TFS collection URL
#   WIDASH_PROJECT    team project
set -euo pipefail

COLLECTION="${WIDASH_COLLECTION:-https://tfs.zeiss.org/tfs/SMT_SMS}"
PROJECT="${WIDASH_PROJECT:-BarLev-RnD}"

# Shared PAT lookup (pure-bash scan of PRDASH_PATS when launched through
# azure-cli.exe, else one --print-pat call) - see resolve-pat.sh.
if [[ "${BASH_SOURCE[0]}" == */* ]]; then . "${BASH_SOURCE[0]%/*}/resolve-pat.sh"; else . "./resolve-pat.sh"; fi
resolve_pat_into ADO_PAT "$COLLECTION" "$PROJECT" \
  || { echo "ERROR: no PAT available - add 'pat:' to this account in azure-cli.yml" >&2; exit 1; }
export ADO_PAT

WIS_CMD="${1:-}"
WIS_A2="${2:-}"
WIS_A3="${3:-}"
WIS_A4="${4:-}"

export COLLECTION PROJECT WIS_CMD WIS_A2 WIS_A3 WIS_A4

PY="python"; command -v python >/dev/null 2>&1 || PY="python3"

"$PY" - <<'PYEOF'
import os, sys, json, base64, urllib.parse, urllib.request, urllib.error

collection = os.environ["COLLECTION"]
project    = os.environ["PROJECT"]
auth       = base64.b64encode((":" + os.environ["ADO_PAT"]).encode()).decode()
cmd        = os.environ.get("WIS_CMD", "")
a2         = os.environ.get("WIS_A2", "")
a3         = os.environ.get("WIS_A3", "")
a4         = os.environ.get("WIS_A4", "")
api        = "7.1"


def request(url, method="GET", data=None, content_type="application/json"):
    headers = {"Authorization": f"Basic {auth}", "Accept": "application/json"}
    body = None
    if data is not None:
        headers["Content-Type"] = content_type
        body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        try:
            msg = json.loads(detail).get("message") or detail[:300]
        except Exception:
            msg = detail[:300]
        print(f"ERROR: HTTP {e.code} {method}: {msg}", file=sys.stderr)
        sys.exit(2)


if cmd == "transitions":
    wtype, cur = a2, a3
    if not wtype:
        print("ERROR: transitions needs <type>", file=sys.stderr)
        sys.exit(1)
    url = f"{collection}/{project}/_apis/wit/workitemtypes/{urllib.parse.quote(wtype)}?api-version={api}"
    d = request(url)
    transitions = d.get("transitions", {}) or {}
    seen = set()
    for x in transitions.get(cur, []):
        to = x.get("to")
        if to and to != cur and to not in seen:
            seen.add(to)
            print(to)

elif cmd == "reasons":
    wtype, state = a2, a3
    if not wtype or not state:
        print("ERROR: reasons needs <type> <toState>", file=sys.stderr)
        sys.exit(1)
    # ADO/on-prem TFS has no REST route for per-transition reasons; derive the
    # accepted vocabulary from work items already in the target state.
    safe_type = wtype.replace("'", "''")
    safe_state = state.replace("'", "''")
    wiql = {"query": (
        "SELECT [System.Id] FROM WorkItems WHERE "
        f"[System.WorkItemType]='{safe_type}' AND [System.State]='{safe_state}' "
        "ORDER BY [System.ChangedDate] DESC"
    )}
    d = request(f"{collection}/{project}/_apis/wit/wiql?api-version={api}&$top=200",
                method="POST", data=wiql)
    ids = [w["id"] for w in (d.get("workItems") or [])] if isinstance(d, dict) else []
    counts = {}
    for i in range(0, len(ids), 200):
        batch = ids[i:i + 200]
        if not batch:
            break
        idstr = ",".join(str(x) for x in batch)
        b = request(f"{collection}/{project}/_apis/wit/workitems?ids={idstr}"
                    f"&fields=System.Reason&api-version={api}")
        for w in (b.get("value") or []):
            rv = (w.get("fields") or {}).get("System.Reason") or ""
            if rv:
                counts[rv] = counts.get(rv, 0) + 1
    for rv, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(rv)

elif cmd == "set":
    wid, new = a2, a3
    if not wid or not new:
        print("ERROR: set needs <id> <newState>", file=sys.stderr)
        sys.exit(1)
    validate = "&validateOnly=true" if os.environ.get("WIDASH_VALIDATE_ONLY") == "1" else ""
    url = f"{collection}/{project}/_apis/wit/workitems/{wid}?api-version={api}{validate}"
    patch = [{"op": "add", "path": "/fields/System.State", "value": new}]
    if a4:
        patch.append({"op": "add", "path": "/fields/System.Reason", "value": a4})
    d = request(url, method="PATCH", data=patch, content_type="application/json-patch+json")
    fields = d.get("fields")
    if isinstance(fields, dict):
        print(fields.get("System.State", new))
    else:
        print("ERROR: unexpected response: " + json.dumps(d)[:300], file=sys.stderr)
        sys.exit(2)

else:
    print("usage: wi-state.sh transitions <type> <currentState> | "
          "reasons <type> <toState> | set <id> <newState> [reason]", file=sys.stderr)
    sys.exit(1)
PYEOF
