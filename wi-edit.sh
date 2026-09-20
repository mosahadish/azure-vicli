#!/usr/bin/env bash
#
# wi-edit.sh - create and edit work items for the Neovim work-items dashboard
# (wi-dash.lua) and detail view (wi-view.lua). Two subcommands:
#
#   wi-edit.sh create <type> <title> [parentId] [iterationPath]
#       Create a new work item of <type> (e.g. "User Story" or "Bug") titled
#       <title>, assigned to WIDASH_ASSIGNEE (me, the same default wi-list.sh
#       uses) and area-pathed to the team's default area (teamsettings/
#       teamfieldvalues' defaultValue - the same endpoint wi-list.sh reads
#       team areas from). [iterationPath], when given, sets
#       System.IterationPath. [parentId], when given, adds a
#       System.LinkTypes.Hierarchy-Reverse relation to that work item.
#       Prints {"id":..,"title":..} on success.
#
#   wi-edit.sh set <id> <field> <value>
#       Patch one field of work item <id>. <field> is one of these friendly
#       names, mapped to the ADO field reference name:
#         title       -> System.Title
#         assignedTo  -> System.AssignedTo
#         priority    -> Microsoft.VSTS.Common.Priority (integer)
#         iteration   -> System.IterationPath
#         tags        -> System.Tags
#         description -> System.Description
#       Prints {"id":..,"field":..,"value":..} on success.
#
#   wi-edit.sh comment <id> <text>
#       Add a discussion comment to work item <id>
#       (POST .../workItems/{id}/comments). Prints {"id":..} (the new
#       comment's id) on success.
#
#   wi-edit.sh link-pr <wiId> <orgUrl> <project> <repoName> <prId>
#       Link pull request <prId> (in <repoName> under <orgUrl>/<project>) to
#       work item <wiId> as an ArtifactLink relation. Resolves the project
#       and repository GUIDs with one call to the git repositories endpoint,
#       then adds the relation. Prints {"linked":<prId>} on success.
#
#   wi-edit.sh unlink-pr <wiId> <prId>
#       Remove the ArtifactLink relation for pull request <prId> from work
#       item <wiId>. Prints {"unlinked":<prId>} on success.
#
# Config via environment (same defaults as wi-list.sh):
#   ADO_PAT            always resolved from azure-cli.yml (see resolve-pat.sh)
#                       for the account matching WIDASH_COLLECTION/WIDASH_PROJECT;
#                       never taken from an ambient ADO_PAT env var, config is
#                       the only source
#   WIDASH_COLLECTION  TFS collection URL
#   WIDASH_PROJECT     team project
#   WIDASH_TEAM        team (for the default area path on create)
#   WIDASH_ASSIGNEE    exact System.AssignedTo value (name or "Name <email>"),
#                       also the default assignee for a newly created item
set -euo pipefail

COLLECTION="${WIDASH_COLLECTION:-https://tfs.zeiss.org/tfs/SMT_SMS}"
PROJECT="${WIDASH_PROJECT:-BarLev-RnD}"
TEAM="${WIDASH_TEAM:-DUNE SW}"
ASSIGNEE="${WIDASH_ASSIGNEE:-Hadish, Mosa}"

# Shared PAT lookup (pure-bash scan of PRDASH_PATS when launched through
# azure-cli.exe, else one --print-pat call) - see resolve-pat.sh.
if [[ "${BASH_SOURCE[0]}" == */* ]]; then . "${BASH_SOURCE[0]%/*}/resolve-pat.sh"; else . "./resolve-pat.sh"; fi
resolve_pat_into ADO_PAT "$COLLECTION" "$PROJECT" \
  || { echo "ERROR: no PAT available - add 'pat:' to this account in azure-cli.yml" >&2; exit 1; }
export ADO_PAT

WIE_CMD="${1:-}"
WIE_A2="${2:-}"
WIE_A3="${3:-}"
WIE_A4="${4:-}"
WIE_A5="${5:-}"
WIE_A6="${6:-}"

export COLLECTION PROJECT TEAM ASSIGNEE WIE_CMD WIE_A2 WIE_A3 WIE_A4 WIE_A5 WIE_A6

PY="python"; command -v python >/dev/null 2>&1 || PY="python3"

"$PY" - <<'PYEOF'
import os, sys, json, base64, urllib.parse, urllib.request, urllib.error

collection = os.environ["COLLECTION"]
project    = os.environ["PROJECT"]
team       = os.environ["TEAM"]
assignee   = os.environ["ASSIGNEE"]
auth       = base64.b64encode((":" + os.environ["ADO_PAT"]).encode()).decode()
cmd        = os.environ.get("WIE_CMD", "")
a2         = os.environ.get("WIE_A2", "")
a3         = os.environ.get("WIE_A3", "")
a4         = os.environ.get("WIE_A4", "")
a5         = os.environ.get("WIE_A5", "")
a6         = os.environ.get("WIE_A6", "")
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
            msg = json.loads(detail).get("message") or detail[:400]
        except Exception:
            msg = detail[:400]
        print(f"ERROR: HTTP {e.code} {method} {url}\n{msg}", file=sys.stderr)
        sys.exit(2)


# Friendly field name -> (ADO field reference name, value caster).
FIELD_MAP = {
    "title":       ("System.Title", str),
    "assignedTo":  ("System.AssignedTo", str),
    "priority":    ("Microsoft.VSTS.Common.Priority", int),
    "iteration":   ("System.IterationPath", str),
    "tags":        ("System.Tags", str),
    "description": ("System.Description", str),
}

if cmd == "create":
    wtype, title, parent_id, iteration_path = a2, a3, a4, a5
    if not wtype or not title:
        print("ERROR: create needs <type> <title>", file=sys.stderr)
        sys.exit(1)

    patch = [
        {"op": "add", "path": "/fields/System.Title", "value": title},
        {"op": "add", "path": "/fields/System.AssignedTo", "value": assignee},
    ]

    # Default area path: the team's default area. Same endpoint wi-list.sh
    # reads team areas from (teamsettings/teamfieldvalues); its "defaultValue"
    # is the single area new work items should land in, falling back to the
    # first configured area for a team with none marked default.
    team_url = (f"{collection}/{project}/{urllib.parse.quote(team)}"
                f"/_apis/work/teamsettings/teamfieldvalues?api-version={api}")
    areas = request(team_url)
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
                "url": f"{collection}/_apis/wit/workItems/{parent_id}",
            },
        })

    url = f"{collection}/{project}/_apis/wit/workitems/${urllib.parse.quote(wtype)}?api-version={api}"
    d = request(url, method="POST", data=patch, content_type="application/json-patch+json")
    new_id = d.get("id")
    if new_id is None:
        print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
        sys.exit(2)
    fields = d.get("fields") or {}
    print(json.dumps({"id": new_id, "title": fields.get("System.Title", title)}, ensure_ascii=False))

elif cmd == "set":
    wid, field, value = a2, a3, a4
    if not wid or not field:
        print("ERROR: set needs <id> <field> <value>", file=sys.stderr)
        sys.exit(1)
    mapping = FIELD_MAP.get(field)
    if not mapping:
        print("ERROR: unknown field '" + field + "', expected one of: "
              + ", ".join(sorted(FIELD_MAP)), file=sys.stderr)
        sys.exit(1)
    ado_field, caster = mapping
    try:
        cast_value = caster(value)
    except (TypeError, ValueError):
        print(f"ERROR: invalid value for {field}: {value!r}", file=sys.stderr)
        sys.exit(1)

    url = f"{collection}/_apis/wit/workitems/{wid}?api-version={api}"
    patch = [{"op": "add", "path": f"/fields/{ado_field}", "value": cast_value}]
    d = request(url, method="PATCH", data=patch, content_type="application/json-patch+json")
    fields = d.get("fields")
    if not isinstance(fields, dict):
        print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"id": d.get("id"), "field": field,
                      "value": fields.get(ado_field, cast_value)}, ensure_ascii=False))

elif cmd == "comment":
    wid, text = a2, a3
    if not wid or not text:
        print("ERROR: comment needs <id> <text>", file=sys.stderr)
        sys.exit(1)
    url = f"{collection}/{project}/_apis/wit/workItems/{wid}/comments?api-version=7.1-preview.4"
    d = request(url, method="POST", data={"text": text}, content_type="application/json")
    cid = d.get("id")
    if cid is None:
        print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"id": cid}, ensure_ascii=False))

elif cmd == "link-pr":
    wid, org_url, link_project, repo_name, pr_id = a2, a3, a4, a5, a6
    if not (wid and org_url and link_project and repo_name and pr_id):
        print("ERROR: link-pr needs <wiId> <orgUrl> <project> <repoName> <prId>", file=sys.stderr)
        sys.exit(1)
    repo_url = (f"{org_url}/{link_project}/_apis/git/repositories/"
                f"{urllib.parse.quote(repo_name)}?api-version=7.1")
    repo = request(repo_url)
    repo_guid = repo.get("id")
    project_guid = (repo.get("project") or {}).get("id")
    if not repo_guid or not project_guid:
        print("ERROR: could not resolve repository/project id for '" + repo_name + "'", file=sys.stderr)
        sys.exit(2)
    artifact_url = f"vstfs:///Git/PullRequestId/{project_guid}%2F{repo_guid}%2F{pr_id}"
    patch = [{
        "op": "add",
        "path": "/relations/-",
        "value": {
            "rel": "ArtifactLink",
            "url": artifact_url,
            "attributes": {"name": "Pull Request"},
        },
    }]
    url = f"{collection}/_apis/wit/workitems/{wid}?api-version={api}"
    d = request(url, method="PATCH", data=patch, content_type="application/json-patch+json")
    if not isinstance(d.get("fields"), dict):
        print("ERROR: unexpected response: " + json.dumps(d)[:400], file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"linked": int(pr_id) if pr_id.isdigit() else pr_id}, ensure_ascii=False))

elif cmd == "unlink-pr":
    wid, pr_id = a2, a3
    if not wid or not pr_id:
        print("ERROR: unlink-pr needs <wiId> <prId>", file=sys.stderr)
        sys.exit(1)
    url = f"{collection}/_apis/wit/workitems/{wid}?$expand=relations&api-version={api}"
    d = request(url)
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
        print(f"ERROR: no linked pull request {pr_id} found on #{wid}", file=sys.stderr)
        sys.exit(1)
    patch = [{"op": "remove", "path": f"/relations/{idx}"}]
    url2 = f"{collection}/_apis/wit/workitems/{wid}?api-version={api}"
    d2 = request(url2, method="PATCH", data=patch, content_type="application/json-patch+json")
    if not isinstance(d2.get("fields"), dict):
        print("ERROR: unexpected response: " + json.dumps(d2)[:400], file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"unlinked": int(pr_id) if pr_id.isdigit() else pr_id}, ensure_ascii=False))

else:
    print("usage: wi-edit.sh create <type> <title> [parentId] [iterationPath] | "
          "set <id> <field> <value> | comment <id> <text> | "
          "link-pr <wiId> <orgUrl> <project> <repoName> <prId> | "
          "unlink-pr <wiId> <prId>", file=sys.stderr)
    sys.exit(1)
PYEOF
