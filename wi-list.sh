#!/usr/bin/env bash
#
# wi-list.sh - headless work-item data provider for the Neovim work-items
# dashboard (wi-dash.lua). Queries Azure DevOps (on-prem TFS) for the work
# items assigned to me in a sprint and prints one JSON object per line
# (NDJSON), mirroring how `azure-cli --list` feeds azure-cli.lua.
#
# Usage: wi-list.sh [current|next]   (default: current)
#
# Config via environment (sensible BarLev-RnD / DUNE SW defaults):
#   ADO_PAT            always resolved from azure-cli.yml (see resolve-pat.sh)
#                       for the account matching WIDASH_COLLECTION/WIDASH_PROJECT;
#                       never taken from an ambient ADO_PAT env var, config is
#                       the only source
#   WIDASH_COLLECTION  TFS collection URL
#   WIDASH_PROJECT     team project
#   WIDASH_TEAM        team (for current-sprint + area resolution)
#   WIDASH_ASSIGNEE    exact System.AssignedTo value (name or "Name <email>")
#   WIDASH_TYPES       comma-separated work item types (default "User Story,Bug")
#
# Output: the first line is a sprint metadata object
#   {"_meta":true,"timeframe":..,"sprintName":..,"sprintPath":..,"sprintStart":..,"sprintFinish":..[,"nextSprintName":..,"nextStart":..,"nextFinish":..]}
# followed by one work-item object per line with fields:
#   id, type, state, title, assignedTo, priority, tags, parentId,
#   changedIso, changedHuman, url
set -euo pipefail

COLLECTION="${WIDASH_COLLECTION:-https://tfs.zeiss.org/tfs/SMT_SMS}"
PROJECT="${WIDASH_PROJECT:-BarLev-RnD}"
TEAM="${WIDASH_TEAM:-DUNE SW}"
ASSIGNEE="${WIDASH_ASSIGNEE:-Hadish, Mosa}"
TYPES="${WIDASH_TYPES:-User Story,Bug}"

# Which data to emit (arg 1):
#   current|next     work items for the current/next sprint (first line _meta)
#   sprints          the sprints in the current quarter (one _sprints line)
#   items <path>     work items for the given iteration path (arg 2)
SPRINT_SELECT="${1:-current}"
ITEM_PATH="${2:-}"
case "$SPRINT_SELECT" in
  current|next|sprints) ;;
  items)
    [ -n "$ITEM_PATH" ] || { echo "ERROR: 'items' needs an iteration path" >&2; exit 1; }
    ;;
  *) echo "ERROR: selector must be current|next|sprints|items, got '$SPRINT_SELECT'" >&2; exit 1 ;;
esac

# Shared PAT lookup (pure-bash scan of PRDASH_PATS when launched through
# azure-cli.exe, else one --print-pat call) - see resolve-pat.sh.
if [[ "${BASH_SOURCE[0]}" == */* ]]; then . "${BASH_SOURCE[0]%/*}/resolve-pat.sh"; else . "./resolve-pat.sh"; fi
resolve_pat_into ADO_PAT "$COLLECTION" "$PROJECT" \
  || { echo "ERROR: no PAT available - add 'pat:' to this account in azure-cli.yml" >&2; exit 1; }
export ADO_PAT

urlencode() {
  local s="$1" out="" i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

TEAM_ESCAPED="$(urlencode "$TEAM")"
ITERS_URL="${COLLECTION}/${PROJECT}/${TEAM_ESCAPED}/_apis/work/teamsettings/iterations?timeframe=all&api-version=7.1"
AREAS_URL="${COLLECTION}/${PROJECT}/${TEAM_ESCAPED}/_apis/work/teamsettings/teamfieldvalues?api-version=7.1"

ITERS_JSON="$(curl -sS -u ":${ADO_PAT}" "$ITERS_URL")"
AREAS_JSON="$(curl -sS -u ":${ADO_PAT}" "$AREAS_URL")"
if [[ -z "$ITERS_JSON" || "${ITERS_JSON:0:1}" != "{" ]]; then
  echo "ERROR: could not fetch iterations from ADO - check the PAT's permissions/scope" \
       "(needs Work Items - Read) for $COLLECTION/$PROJECT: ${ITERS_JSON:0:200}" >&2
  exit 1
fi
export ITERS_JSON AREAS_JSON COLLECTION PROJECT ASSIGNEE TYPES SPRINT_SELECT ITEM_PATH

PY="python"; command -v python >/dev/null 2>&1 || PY="python3"

"$PY" - <<'PYEOF'
import os, sys, json, base64, re, datetime, urllib.request, urllib.error

collection = os.environ["COLLECTION"]
project    = os.environ["PROJECT"]
auth       = base64.b64encode((":" + os.environ["ADO_PAT"]).encode()).decode()
assignee   = os.environ["ASSIGNEE"]
types      = os.environ["TYPES"]
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

def sql_esc(s): return s.replace("'", "''")

select = os.environ.get("SPRINT_SELECT", "current")
item_path = os.environ.get("ITEM_PATH", "")

def pdt(s):
    try:
        return datetime.datetime.fromisoformat((s or "").replace("Z", "+00:00"))
    except Exception:
        return None

def sprint_name(it):
    if not it:
        return ""
    return it.get("name") or (it.get("path", "").split("\\")[-1])

# Resolve the current sprint.
iters = (json.loads(os.environ["ITERS_JSON"]).get("value") or [])

def resolve_current():
    for it in iters:
        if (it.get("attributes") or {}).get("timeFrame") == "current":
            return it
    now = datetime.datetime.now(datetime.timezone.utc)
    for it in iters:
        a = it.get("attributes") or {}
        st, fn = pdt(a.get("startDate")), pdt(a.get("finishDate"))
        if st and fn and st <= now <= fn:
            return it
    return None

def resolve_next(cur):
    dated = [(pdt((it.get("attributes") or {}).get("startDate")), it) for it in iters]
    dated = [(d, it) for (d, it) in dated if d is not None]
    dated.sort(key=lambda x: x[0])
    for i, (_, it) in enumerate(dated):
        if it.get("path") == cur.get("path"):
            return dated[i + 1][1] if i + 1 < len(dated) else None
    fut = [it for it in iters if (it.get("attributes") or {}).get("timeFrame") == "future"]
    fut.sort(key=lambda it: (pdt((it.get("attributes") or {}).get("startDate")) is None,
                             pdt((it.get("attributes") or {}).get("startDate"))
                             or datetime.datetime.max.replace(tzinfo=datetime.timezone.utc)))
    return fut[0] if fut else None

# Mode: list the current quarter's sprints (one _sprints line) and stop. The
# quarter is the parent iteration node of the current sprint (e.g. 2026\Q3).
if select == "sprints":
    cur = resolve_current()
    if cur is None:
        print("ERROR: could not determine current sprint", file=sys.stderr)
        sys.exit(1)
    cur_path = cur.get("path", "")
    quarter = cur_path.rsplit("\\", 1)[0] if "\\" in cur_path else cur_path
    group = [it for it in iters
             if "\\" in it.get("path", "")
             and it.get("path", "").rsplit("\\", 1)[0] == quarter]
    group.sort(key=lambda it: (pdt((it.get("attributes") or {}).get("startDate"))
                               or datetime.datetime.max.replace(tzinfo=datetime.timezone.utc)))
    out_sprints, current_index = [], 0
    for i, it in enumerate(group):
        a = it.get("attributes") or {}
        pth = it.get("path", "")
        is_cur = (pth == cur_path)
        if is_cur:
            current_index = i + 1
        out_sprints.append({
            "name": sprint_name(it),
            "label": pth.rsplit("\\", 1)[-1] if "\\" in pth else pth,
            "path": pth,
            "start": a.get("startDate", "") or "",
            "finish": a.get("finishDate", "") or "",
            "timeframe": a.get("timeFrame", "") or "",
            "current": is_cur,
        })
    print(json.dumps({"_sprints": True, "quarter": quarter,
                      "currentIndex": current_index, "sprints": out_sprints},
                     ensure_ascii=False))
    sys.exit(0)

# Mode: work items for an explicit iteration path (arg 2).
if select == "items":
    sprint_path = item_path
else:
    cur = resolve_current()
    if cur is None:
        print("ERROR: could not determine current sprint", file=sys.stderr)
        sys.exit(1)
    nxt = resolve_next(cur)
    if select == "next":
        if nxt is None:
            print("ERROR: could not determine next sprint", file=sys.stderr)
            sys.exit(1)
        target = nxt
        na = nxt.get("attributes") or {}
        meta = {"_meta": True, "timeframe": "next",
                "sprintName": sprint_name(nxt), "sprintPath": nxt.get("path", ""),
                "sprintStart": na.get("startDate", "") or "",
                "sprintFinish": na.get("finishDate", "") or ""}
    else:
        target = cur
        ca = cur.get("attributes") or {}
        na = (nxt.get("attributes") or {}) if nxt else {}
        meta = {"_meta": True, "timeframe": "current",
                "sprintName": sprint_name(cur), "sprintPath": cur.get("path", ""),
                "sprintStart": ca.get("startDate", "") or "",
                "sprintFinish": ca.get("finishDate", "") or "",
                "nextSprintName": sprint_name(nxt), "nextSprintPath": (nxt.get("path", "") if nxt else ""),
                "nextStart": na.get("startDate", "") or "",
                "nextFinish": na.get("finishDate", "") or ""}
    sprint_path = target.get("path", "")
    # Emit the sprint metadata first so the dashboard can label its tab even
    # when the sprint has zero assigned work items.
    print(json.dumps(meta, ensure_ascii=False))

# team areas
areas = [v.get("value") for v in (json.loads(os.environ["AREAS_JSON"]).get("values") or []) if v.get("value")]
if not areas:
    print("ERROR: no team areas returned", file=sys.stderr); sys.exit(1)

area_clause = " OR ".join(f"[System.AreaPath] UNDER '{sql_esc(a)}'" for a in areas)
type_list = [t.strip() for t in types.split(",") if t.strip()]
type_clause = ""
if type_list:
    type_clause = " AND [System.WorkItemType] IN (" + ",".join(f"'{sql_esc(t)}'" for t in type_list) + ")"

wiql = f"""SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = '{sql_esc(project)}'
  AND [System.IterationPath] = '{sql_esc(sprint_path)}'
  AND ( {area_clause} )
  {type_clause}
  AND [System.AssignedTo] = '{sql_esc(assignee)}'
ORDER BY [System.Id]"""

resp = api_request(f"{collection}/{project}/_apis/wit/wiql?api-version={api}",
                   method="POST", data=json.dumps({"query": wiql}))
ids = [w["id"] for w in (resp.get("workItems") or [])]
if not ids:
    sys.exit(0)

def assigned_str(v):
    if isinstance(v, dict):
        return v.get("displayName","") or v.get("uniqueName","") or ""
    return "" if v is None else str(v)

def human(iso):
    try:
        dt = datetime.datetime.fromisoformat((iso or "").replace("Z","+00:00"))
    except Exception:
        return ""
    now = datetime.datetime.now(datetime.timezone.utc)
    secs = (now - dt).total_seconds()
    if secs < 60: return "just now"
    if secs < 3600: return f"{int(secs//60)}m ago"
    if secs < 86400: return f"{int(secs//3600)}h ago"
    d = int(secs//86400)
    return f"{d}d ago" if d < 30 else f"{d//30}mo ago"

batch = f"{collection}/_apis/wit/workitemsbatch?api-version={api}"
for i in range(0, len(ids), 200):
    chunk = ids[i:i+200]
    r = api_request(batch, method="POST",
                    data=json.dumps({"ids": chunk, "$expand": "relations"}))
    for wi in (r.get("value") or []):
        f = wi.get("fields") or {}
        parent = f.get("System.Parent")
        if not isinstance(parent, int):
            for rel in (wi.get("relations") or []):
                if rel.get("rel") == "System.LinkTypes.Hierarchy-Reverse":
                    m = re.search(r"/workItems/(\d+)$", rel.get("url",""))
                    if m: parent = int(m.group(1)); break
        changed = str(f.get("System.ChangedDate",""))
        rec = {
            "id": wi.get("id"),
            "type": str(f.get("System.WorkItemType","")),
            "state": str(f.get("System.State","")),
            "title": re.sub(r"\s+"," ", str(f.get("System.Title","")).strip()),
            "assignedTo": assigned_str(f.get("System.AssignedTo","")),
            "priority": f.get("Microsoft.VSTS.Common.Priority"),
            "tags": str(f.get("System.Tags","") or ""),
            "parentId": parent if isinstance(parent, int) else None,
            "changedIso": changed,
            "changedHuman": human(changed),
            "url": f"{collection}/{project}/_workitems/edit/{wi.get('id')}",
        }
        print(json.dumps(rec, ensure_ascii=False))
PYEOF
