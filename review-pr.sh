#!/usr/bin/env bash
#
# azure-cli review helper.
#
# Invoked by azure-cli.lua when opening a PR for review.
# Consumes the PRDASH_* environment variables exported by the caller:
#   PRDASH_ID, PRDASH_REPO, PRDASH_PROJECT, PRDASH_ORG, PRDASH_SOURCE, PRDASH_TARGET
#
# Local clone location comes from PRDASH_REPO_PATH, which azure-cli.lua sets
# per-PR from this account's clones_dir (azure-cli.yml).
#
# All ADO calls below go straight to the REST API with a PAT. The PAT is
# always resolved from azure-cli.yml (never from an ambient AZURE_DEVOPS_EXT_PAT/
# ADO_PAT env var): see resolve-pat.sh next to this script. It is resolved
# lazily (ensure_pat), only on the paths that actually talk to the REST API,
# so the background branch prefetch - the hottest path, fired as the cursor
# moves over the PR list - is git-only and never pays for the lookup.
#
# This script only ever runs the full PR review inside Neovim (pr-review.lua,
# next to this script) - there is no standalone fallback UI.
# Required: git, bash, curl, python, nvim.
#
set -uo pipefail

ORG="${PRDASH_ORG:?PRDASH_ORG not set}"
PROJECT="${PRDASH_PROJECT:?PRDASH_PROJECT not set}"
REPO="${PRDASH_REPO:?PRDASH_REPO not set}"
ID="${PRDASH_ID:?PRDASH_ID not set}"
SOURCE="${PRDASH_SOURCE:-}"
TARGET="${PRDASH_TARGET:-}"
REPO_PATH="${PRDASH_REPO_PATH:-$PWD}"

have() { command -v "$1" >/dev/null 2>&1; }

RANGE="origin/${TARGET}...origin/${SOURCE}"

# Absolute path to this script; exported as PRDASH_SCRIPT so pr-review.lua
# can re-invoke it per action (--post, --status, --vote, etc.).
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# Dir via parameter expansion (no dirname fork); reused for every sibling path.
SCRIPT_DIR="${SCRIPT_PATH%/*}"

# Resolve the PAT for this PR's org/project into AZURE_DEVOPS_EXT_PAT (from
# azure-cli.yml only - whatever this shell already had exported is ignored).
# Called right before anything that hits the REST API; a pure-bash scan of
# PRDASH_PATS when launched via azure-cli.exe, else one --print-pat call.
. "$SCRIPT_DIR/resolve-pat.sh"
ensure_pat() {
  resolve_pat_into AZURE_DEVOPS_EXT_PAT "$ORG" "$PROJECT" || true
  export AZURE_DEVOPS_EXT_PAT
  if [[ -z "$AZURE_DEVOPS_EXT_PAT" ]]; then
    echo "No PAT available: add 'pat:' to this account in azure-cli.yml." >&2
    return 1
  fi
}

# JSON-encode stdin safely with python (jq is not available here).
json_encode() { python -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# --- Timing instrumentation (opt-in: export PRDASH_TIMING=1) ----------------
# When enabled, each phase's elapsed time is appended to a log file so we can
# see where the open-a-PR latency goes (git fetch vs metadata vs threads REST).
# Override the log location with PRDASH_TIMING_LOG.
TIMING_LOG="${PRDASH_TIMING_LOG:-$SCRIPT_DIR/timing.log}"
timing_enabled() { [[ -n "${PRDASH_TIMING:-}" ]]; }
# Fork-free millisecond epoch. git-bash fork()/exec is ~300ms each here, so
# spawning `date` per timestamp dominated open latency. EPOCHREALTIME is a bash
# builtin (seconds.microseconds); set_now_ms assigns straight into a named var
# via `printf -v`, avoiding both the `date` exe AND the $(...) subshell fork.
set_now_ms() { local e=$EPOCHREALTIME; printf -v "$1" '%s%03d' "${e%.*}" "$(( 10#${e#*.} / 1000 ))"; }
tlog() {
  timing_enabled || return 0
  # %(...)T is a bash builtin time format (no `date` exe, no fork).
  printf '%(%Y-%m-%d %H:%M:%S)T  PR#%s  %s\n' -1 "${ID:-?}" "$*" >> "$TIMING_LOG" 2>/dev/null || true
}
# Wall-clock at the earliest point in the script, to measure login-shell +
# arg-parse + header cost that lands BEFORE the interactive t_start anchor.
set_now_ms t_script_start

# --- Prefetch cache markers -------------------------------------------------
# azure-cli warms a highlighted PR's branches in the background (PRDASH_PREFETCH)
# and drops a marker file here; the interactive flow skips the slow branch
# fetch when the marker is fresh, making the open near-instant.
PREFETCH_DIR="${PRDASH_PREFETCH_DIR:-$SCRIPT_DIR/.prefetch}"
PREFETCH_TTL_MIN=3
# Markers are keyed by the local clone path ($REPO_PATH) that is actually
# fetched, NOT the PR's ADO repo name ($REPO): a single clone serves PRs from
# multiple ADO repos, so keying by name would warm one marker but check another.
# The key is sanitized with pure bash parameter expansion (no printf|tr fork)
# because this runs on the hot interactive open path where git-bash's slow
# fork() dominates latency; ${var//[!set]/_} mirrors `tr -c 'set' '_'`.
_prefetch_key="${REPO_PATH//[!A-Za-z0-9._-]/_}"
PREFETCH_MARKER="$PREFETCH_DIR/${_prefetch_key}-${ID}"
# Repository-wide marker written by the periodic background full fetch; when it
# is fresh, every branch is already current so any PR open can skip the fetch.
PREFETCH_ALL_MARKER="$PREFETCH_DIR/all-${_prefetch_key}"
prefetch_marker() { printf '%s' "$PREFETCH_MARKER"; }
prefetch_all_marker() { printf '%s' "$PREFETCH_ALL_MARKER"; }
# Single find covering both markers with -print -quit (stop at first match) so
# the freshness check costs one process spawn instead of ~6.
prefetch_fresh() {
  [[ -n "$(find "$PREFETCH_DIR" -maxdepth 1 -type f -mmin "-$PREFETCH_TTL_MIN" \
       \( -name "${PREFETCH_MARKER##*/}" -o -name "${PREFETCH_ALL_MARKER##*/}" \) \
       -print -quit 2>/dev/null)" ]]
}

# POST a prepared thread body (file path in $1) to the PR via REST.
# Returns 0 only on success; prints diagnostics on failure.
post_thread() {
  local tmp_body="$1" out rc win_body url
  win_body="$(cygpath -m "$tmp_body" 2>/dev/null || echo "$tmp_body")"
  url="$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID/threads?api-version=6.0"

  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || { echo "AZURE_DEVOPS_EXT_PAT not set."; return 1; }
  out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" \
       -H "Content-Type: application/json" --data-binary @"$win_body" "$url" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "Comment posted."
    return 0
  fi
  echo "REST post failed (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
  return 1
}

# Fetch all comment threads for the PR as raw ADO JSON (for the nvim UI to
# render existing comments inline), via REST. Unlike the other REST helpers
# above this used to swallow every failure silently (curl -sf ... 2>/dev/null,
# discarding both the HTTP response body and any curl diagnostic), which made
# "no comments" and "the fetch is broken" look identical. It now reports the
# HTTP status + response body (or curl's own transport error, e.g. a TLS
# problem) to stderr on failure so the caller can actually tell what happened.
fetch_threads() {
  local url out rc status body
  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || { echo "fetch_threads: AZURE_DEVOPS_EXT_PAT not set." >&2; return 1; }
  url="$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID/threads?api-version=6.0"
  out="$(curl -sS -w $'\n%{http_code}' -u ":${AZURE_DEVOPS_EXT_PAT}" "$url" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "fetch_threads: curl transport error (rc=$rc) for $url: $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)" >&2
    return 1
  fi
  status="${out##*$'\n'}"
  body="${out%$'\n'"$status"}"
  if [[ "$status" != 2?? ]]; then
    echo "fetch_threads: HTTP $status from $url: $(printf '%s' "$body" | tr '\n' ' ' | tail -c 300)" >&2
    return 1
  fi
  if [[ -z "$body" ]]; then
    echo "fetch_threads: empty response body (HTTP $status) from $url." >&2
    return 1
  fi
  printf '%s' "$body"
  return 0
}

# Post a file-level comment (thread anchored to a file). $1 = repo-relative path.
post_file_comment() {
  local path="$1" comment="${2:-}" content fp_json tmp_body
  if [[ -z "$path" ]]; then
    echo "No file selected."
    return 1
  fi
  # Prompt only when the text wasn't supplied as an argument (nvim's cf flow
  # always supplies it; this interactive fallback is unused today but kept
  # cheap to leave in).
  if [[ -z "$comment" ]]; then
    echo
    echo "Comment on file: $path"
    read -rp "Comment text (empty to cancel): " comment
  fi
  if [[ -z "${comment// }" ]]; then
    echo "Cancelled."
    return 0
  fi
  content="$(printf '%s' "$comment" | json_encode)"
  # ADO expects filePath repo-relative with a leading slash.
  fp_json="$(printf '/%s' "$path" | json_encode)"
  tmp_body="$(mktemp)"
  printf '{ "comments": [ { "parentCommentId": 0, "content": %s, "commentType": 1 } ], "status": 1, "threadContext": { "filePath": %s } }' \
    "$content" "$fp_json" > "$tmp_body"
  post_thread "$tmp_body"
  local rc=$?
  rm -f "$tmp_body"
  return $rc
}

# Post a PR-level (general) comment: a thread with no threadContext. $1 = text.
post_pr_comment() {
  local comment="$1" content tmp_body rc
  if [[ -z "${comment// }" ]]; then
    echo "Cancelled."
    return 0
  fi
  content="$(printf '%s' "$comment" | json_encode)"
  tmp_body="$(mktemp)"
  printf '{ "comments": [ { "parentCommentId": 0, "content": %s, "commentType": 1 } ], "status": 1 }' \
    "$content" > "$tmp_body"
  post_thread "$tmp_body"
  rc=$?
  rm -f "$tmp_body"
  return $rc
}

# Build + POST an inline comment without prompting (used by the nvim UI).
# $1 = path, $2 = side (R/L), $3 = 1-based line number, $4 = comment text.
post_inline() {
  local path="$1" side="$2" lineno="$3" comment="$4" blob linetext len content fp_json tmp_body anchor
  if [[ -z "$path" || -z "$lineno" || -n "${lineno//[0-9]/}" || "$lineno" -eq 0 ]]; then
    echo "Invalid line."
    return 1
  fi
  case "$side" in
    R) blob="origin/${SOURCE}:${path}" ;;
    L) blob="origin/${TARGET}:${path}" ;;
    *) echo "Invalid side."; return 1 ;;
  esac
  linetext="$(git show "$blob" 2>/dev/null | sed -n "${lineno}p")"
  len=${#linetext}
  content="$(printf '%s' "$comment" | json_encode)"
  fp_json="$(printf '/%s' "$path" | json_encode)"
  if [[ "$side" == "R" ]]; then
    anchor="$(printf '"rightFileStart": { "line": %d, "offset": 1 }, "rightFileEnd": { "line": %d, "offset": %d }' "$lineno" "$lineno" "$((len + 1))")"
  else
    anchor="$(printf '"leftFileStart": { "line": %d, "offset": 1 }, "leftFileEnd": { "line": %d, "offset": %d }' "$lineno" "$lineno" "$((len + 1))")"
  fi
  tmp_body="$(mktemp)"
  printf '{ "comments": [ { "parentCommentId": 0, "content": %s, "commentType": 1 } ], "status": 1, "threadContext": { "filePath": %s, %s } }' \
    "$content" "$fp_json" "$anchor" > "$tmp_body"
  post_thread "$tmp_body"
  local rc=$?
  rm -f "$tmp_body"
  return $rc
}

# Post a reply into an existing thread. $1 = threadId, $2 = reply text.
# PATCHes the thread's comments sub-resource via REST. parentCommentId 1 is
# the thread's first comment.
post_reply() {
  local thread_id="$1" comment="$2" content tmp_body win_body out rc
  if [[ -z "$thread_id" || -n "${thread_id//[0-9]/}" ]]; then
    echo "Invalid thread id."
    return 1
  fi
  if [[ -z "${comment// }" ]]; then
    echo "Empty reply."
    return 1
  fi
  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || { echo "AZURE_DEVOPS_EXT_PAT not set."; return 1; }
  content="$(printf '%s' "$comment" | json_encode)"
  tmp_body="$(mktemp)"
  printf '{ "parentCommentId": 1, "content": %s, "commentType": 1 }' "$content" > "$tmp_body"
  win_body="$(cygpath -m "$tmp_body" 2>/dev/null || echo "$tmp_body")"
  url="$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID/threads/$thread_id/comments?api-version=6.0"

  out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" \
       -H "Content-Type: application/json" --data-binary @"$win_body" "$url" 2>&1)"
  rc=$?
  rm -f "$tmp_body"
  if [[ $rc -eq 0 ]]; then
    echo "Reply posted."
    return 0
  fi
  echo "REST reply failed (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
  return 1
}

# Set an existing thread's status. $1 = threadId, $2 = status keyword
# (active|fixed|wontfix|closed|bydesign|pending). PATCHes the thread via REST.
# ADO's enum uses camelCase for two values.
set_thread_status() {
  local thread_id="$1" status="$2" tmp_body win_body url out rc
  if [[ -z "$thread_id" || -n "${thread_id//[0-9]/}" ]]; then
    echo "Invalid thread id."
    return 1
  fi
  case "$status" in
    active|fixed|closed|pending) ;;
    wontfix)  status="wontFix" ;;
    bydesign) status="byDesign" ;;
    *) echo "Invalid status: '$status'"; return 1 ;;
  esac
  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || { echo "AZURE_DEVOPS_EXT_PAT not set."; return 1; }
  tmp_body="$(mktemp)"
  printf '{ "status": "%s" }' "$status" > "$tmp_body"
  win_body="$(cygpath -m "$tmp_body" 2>/dev/null || echo "$tmp_body")"
  url="$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID/threads/$thread_id?api-version=6.0"

  out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" -X PATCH \
       -H "Content-Type: application/json" --data-binary @"$win_body" "$url" 2>&1)"
  rc=$?
  rm -f "$tmp_body"
  if [[ $rc -eq 0 ]]; then
    echo "Thread $thread_id set to $status."
    return 0
  fi
  echo "REST status update failed (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
  return 1
}

# Resolve the authenticated user's id (GUID) via the connectionData endpoint,
# cached in the prefetch dir since it never changes. Needed to cast a vote,
# which is keyed by reviewer id.
current_user_id() {
  local cache="$PREFETCH_DIR/.userid" out id
  if [[ -s "$cache" ]]; then
    cat "$cache"
    return 0
  fi
  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || return 1
  # On-prem TFS rejects api-version on ConnectionData (400); call it bare.
  out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" \
       "$ORG/_apis/ConnectionData" 2>/dev/null)" || return 1
  id="$(printf '%s' "$out" | python -c 'import json,sys; print(json.load(sys.stdin)["authenticatedUser"]["id"])' 2>/dev/null)"
  [[ -n "$id" ]] || return 1
  mkdir -p "$PREFETCH_DIR" 2>/dev/null && printf '%s' "$id" > "$cache" 2>/dev/null
  printf '%s' "$id"
}

# Cast the current user's vote on the PR (adds them as a reviewer if needed).
# $1 = vote: 10 approve, 5 approve-with-suggestions, 0 reset, -5 wait, -10 reject.
set_vote() {
  local vote="$1" uid tmp_body win_body url out rc
  case "$vote" in
    10|5|0|-5|-10) ;;
    *) echo "Invalid vote: '$vote'"; return 1 ;;
  esac
  uid="$(current_user_id)"
  if [[ -z "$uid" ]]; then
    echo "Could not resolve your user id (connectionData); cannot vote."
    return 1
  fi
  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || { echo "AZURE_DEVOPS_EXT_PAT not set."; return 1; }
  tmp_body="$(mktemp)"
  printf '{ "vote": %s }' "$vote" > "$tmp_body"
  win_body="$(cygpath -m "$tmp_body" 2>/dev/null || echo "$tmp_body")"
  url="$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID/reviewers/$uid?api-version=6.0"

  out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" -X PUT \
       -H "Content-Type: application/json" --data-binary @"$win_body" "$url" 2>&1)"
  rc=$?
  rm -f "$tmp_body"
  if [[ $rc -eq 0 ]]; then
    echo "Vote set to $vote."
    return 0
  fi
  echo "REST vote failed (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
  return 1
}

# Complete (merge) the PR. $1 = merge strategy (squash|noFastForward|rebase|
# rebaseMerge), $2 = delete source branch (true|false), $3 = transition work
# items (true|false). Fetches lastMergeSourceCommit first (required by ADO).
complete_pr() {
  local strategy="$1" del_branch="${2:-true}" transition="${3:-true}"
  local pr_json commit tmp_body win_body url out rc
  case "$strategy" in
    squash|noFastForward|rebase|rebaseMerge) ;;
    *) echo "Invalid merge strategy: '$strategy'"; return 1 ;;
  esac
  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || { echo "AZURE_DEVOPS_EXT_PAT not set."; return 1; }

  # ADO requires lastMergeSourceCommit to guard against racing new commits.
  pr_json="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" \
       "$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID?api-version=6.0" 2>/dev/null)" || {
    echo "Could not fetch PR to determine merge commit."; return 1; }
  commit="$(printf '%s' "$pr_json" | python -c 'import json,sys; print(json.load(sys.stdin)["lastMergeSourceCommit"]["commitId"])' 2>/dev/null)"
  if [[ -z "$commit" ]]; then
    echo "Could not resolve lastMergeSourceCommit; PR may not be mergeable."
    return 1
  fi

  tmp_body="$(mktemp)"
  printf '{ "status": "completed", "lastMergeSourceCommit": { "commitId": "%s" }, "completionOptions": { "mergeStrategy": "%s", "deleteSourceBranch": %s, "transitionWorkItems": %s } }' \
    "$commit" "$strategy" "$del_branch" "$transition" > "$tmp_body"
  win_body="$(cygpath -m "$tmp_body" 2>/dev/null || echo "$tmp_body")"
  url="$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID?api-version=6.0"

  out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" -X PATCH \
       -H "Content-Type: application/json" --data-binary @"$win_body" "$url" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "PR #$ID completed ($strategy)."
    rm -f "$tmp_body"
    return 0
  fi
  echo "REST complete failed (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
  rm -f "$tmp_body"
  return 1
}

# Toggle "complete automatically when requirements are met" (auto-complete),
# same as the web UI checkbox on the completion dialog. $1 = "on"|"off".
# When "on": $2 = merge strategy (squash|noFastForward|rebase|rebaseMerge),
# $3 = delete source branch (true|false), $4 = transition work items
# (true|false). The PR stays "active"; ADO merges it itself once every
# required policy (build validation, required reviewers, etc.) passes.
set_auto_complete() {
  local mode="$1" tmp_body win_body url out rc
  [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] || { echo "AZURE_DEVOPS_EXT_PAT not set."; return 1; }
  url="$ORG/$PROJECT/_apis/git/repositories/$REPO/pullRequests/$ID?api-version=6.0"

  if [[ "$mode" == "off" ]]; then
    tmp_body="$(mktemp)"
    # Matches the official az-cli behaviour for clearing auto-complete: set
    # autoCompleteSetBy to the empty-GUID identity rather than null.
    printf '{ "autoCompleteSetBy": { "id": "00000000-0000-0000-0000-000000000000" } }' > "$tmp_body"
    win_body="$(cygpath -m "$tmp_body" 2>/dev/null || echo "$tmp_body")"
    out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" -X PATCH \
         -H "Content-Type: application/json" --data-binary @"$win_body" "$url" 2>&1)"
    rc=$?
    rm -f "$tmp_body"
    if [[ $rc -eq 0 ]]; then
      echo "Auto-complete disabled for PR #$ID."
      return 0
    fi
    echo "REST auto-complete failed (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
    return 1
  fi

  local strategy="$2" del_branch="${3:-true}" transition="${4:-true}" uid
  case "$strategy" in
    squash|noFastForward|rebase|rebaseMerge) ;;
    *) echo "Invalid merge strategy: '$strategy'"; return 1 ;;
  esac

  uid="$(current_user_id)"
  if [[ -z "$uid" ]]; then
    echo "Could not resolve your user id (connectionData); cannot set auto-complete."
    return 1
  fi

  tmp_body="$(mktemp)"
  printf '{ "autoCompleteSetBy": { "id": "%s" }, "completionOptions": { "mergeStrategy": "%s", "deleteSourceBranch": %s, "transitionWorkItems": %s } }' \
    "$uid" "$strategy" "$del_branch" "$transition" > "$tmp_body"
  win_body="$(cygpath -m "$tmp_body" 2>/dev/null || echo "$tmp_body")"

  out="$(curl -sf -u ":${AZURE_DEVOPS_EXT_PAT}" -X PATCH \
       -H "Content-Type: application/json" --data-binary @"$win_body" "$url" 2>&1)"
  rc=$?
  rm -f "$tmp_body"
  if [[ $rc -eq 0 ]]; then
    echo "Auto-complete enabled for PR #$ID ($strategy)."
    return 0
  fi
  echo "REST auto-complete failed (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
  return 1
}

# Subcommand mode: invoked from the nvim UI to run a single action and exit.
# Every subcommand talks to the REST API, so this is where the PAT is needed.
case "${1:-}" in
  --*) ensure_pat || exit 1 ;;
esac
case "${1:-}" in
  --file-comment)
    # 3-arg form (path text) is non-interactive, for the nvim UI.
    if [[ -n "${3:-}" ]]; then
      post_file_comment "${2:-}" "${3:-}"
      exit $?
    fi
    post_file_comment "${2:-}"
    read -rp "Press Enter to return to the file list..."
    exit 0
    ;;
  --pr-comment)
    cd "$REPO_PATH" 2>/dev/null || true
    post_pr_comment "${2:-}"
    exit $?
    ;;
  --post)
    cd "$REPO_PATH" 2>/dev/null || true
    post_inline "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    exit $?
    ;;
  --threads)
    set_now_ms t0
    fetch_threads
    rc=$?
    set_now_ms _n; tlog "threads fetch: $(( _n - t0 )) ms (rc=$rc)"
    exit $rc
    ;;
  --reply)
    cd "$REPO_PATH" 2>/dev/null || true
    post_reply "${2:-}" "${3:-}"
    exit $?
    ;;
  --status)
    cd "$REPO_PATH" 2>/dev/null || true
    set_thread_status "${2:-}" "${3:-}"
    exit $?
    ;;
  --vote)
    cd "$REPO_PATH" 2>/dev/null || true
    set_vote "${2:-}"
    exit $?
    ;;
  --complete)
    cd "$REPO_PATH" 2>/dev/null || true
    complete_pr "${2:-}" "${3:-}" "${4:-}"
    exit $?
    ;;
  --auto-complete)
    cd "$REPO_PATH" 2>/dev/null || true
    set_auto_complete "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    exit $?
    ;;
esac

# --- Prefetch mode: warm the branches only, then exit (no UI) ---------------
# azure-cli invokes this in the background as the selection cursor lands on a PR.
# It fetches the source/target branches and drops a freshness marker so the
# interactive open can skip the fetch.
if [[ -n "${PRDASH_PREFETCH:-}" ]]; then
  if [[ ! -d "$REPO_PATH/.git" ]]; then
    tlog "prefetch abort: '$REPO_PATH' is not a git repo"
    exit 0
  fi
  cd "$REPO_PATH" || { tlog "prefetch abort: cd '$REPO_PATH' failed"; exit 0; }

  # Repository-wide warm: one full fetch keeps every PR's branches current.
  #
  if [[ "$PRDASH_PREFETCH" == "all" ]]; then
    tlog "prefetch(all) invoked: repo='$REPO_PATH'"
    set_now_ms t_pf0
    pf_err="$(git -c fetch.showForcedUpdates=false fetch --quiet --no-tags origin 2>&1)"
    pf_rc=$?
    set_now_ms _n
    if [[ $pf_rc -eq 0 ]]; then
      mkdir -p "$PREFETCH_DIR" 2>/dev/null && : > "$PREFETCH_ALL_MARKER" 2>/dev/null
      tlog "prefetch(all) git fetch: $(( _n - t_pf0 )) ms (marker: $PREFETCH_ALL_MARKER)"
    else
      tlog "prefetch(all) git fetch FAILED (rc=$pf_rc) after $(( _n - t_pf0 )) ms: $(printf '%s' "$pf_err" | tr '\n' ' ' | tail -c 300)"
    fi
    # Report the fetch's own result: the dashboard only marks branches warm
    # (and only prefetches content against them) on success.
    exit $pf_rc
  fi

  # Per-PR warm: fetch just this PR's two branches.
  #
  tlog "prefetch invoked: source='$SOURCE' target='$TARGET' repo='$REPO_PATH'"
  if [[ -z "$SOURCE" || -z "$TARGET" ]]; then
    tlog "prefetch abort: source/target not set"
    exit 0
  fi
  set_now_ms t_pf0
  pf_err="$(git -c fetch.showForcedUpdates=false fetch --quiet --no-tags origin \
       "+refs/heads/${SOURCE}:refs/remotes/origin/${SOURCE}" \
       "+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}" 2>&1)"
  pf_rc=$?
  set_now_ms _n
  if [[ $pf_rc -eq 0 ]]; then
    mkdir -p "$PREFETCH_DIR" 2>/dev/null && : > "$PREFETCH_MARKER" 2>/dev/null
    tlog "prefetch git fetch: $(( _n - t_pf0 )) ms (marker: $PREFETCH_MARKER)"
  else
    tlog "prefetch git fetch FAILED (rc=$pf_rc) after $(( _n - t_pf0 )) ms: $(printf '%s' "$pf_err" | tr '\n' ' ' | tail -c 300)"
  fi
  exit $pf_rc
fi

# Interactive open: the reviewer's own REST calls (via this script's
# subcommands) need the PAT exported into nvim's environment.
ensure_pat || true

echo "==================================================================="
echo " PR #$ID   $SOURCE -> $TARGET"
echo " repo: $REPO   project: $PROJECT"
echo "==================================================================="
echo

set_now_ms t_start

if [[ ! -d "$REPO_PATH/.git" ]]; then
  echo "PRDASH_REPO_PATH ('$REPO_PATH') is not a git repo; cannot show files."
  read -rp "Press Enter to close..."
  exit 1
fi
cd "$REPO_PATH"

# --- Fetch the PR branches so the diff range resolves ----------------------
# --no-tags and fetch.showForcedUpdates=false noticeably speed up fetches on
# large repos by skipping tag transfer and the forced-update check. When a
# background prefetch already warmed these branches, skip the fetch entirely.
tlog "phase: script-top -> t_start (login+args+header): $(( t_start - t_script_start )) ms"
if [[ -n "$SOURCE" && -n "$TARGET" ]]; then
  if prefetch_fresh; then
    echo "Branches already warmed (prefetched)."
    set_now_ms _n
    tlog "git fetch branches: skipped (prefetched)"
    tlog "phase: fetch/skip decision: $(( _n - t_start )) ms"
  else
    echo "Fetching branches ($SOURCE, $TARGET)..."
    set_now_ms t_fetch0
    git -c fetch.showForcedUpdates=false fetch --quiet --no-tags origin \
      "+refs/heads/${SOURCE}:refs/remotes/origin/${SOURCE}" \
      "+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}" \
      || echo "(fetch failed; diff may be stale or incomplete)"
    set_now_ms _n; tlog "git fetch branches: $(( _n - t_fetch0 )) ms"
  fi
else
  echo "Source/target branch unknown; cannot compute PR diff."
  read -rp "Press Enter to close..."
  exit 1
fi
echo

# --- Preferred UI: full review inside Neovim --------------------------------
# Everything runs in one nvim session with native vim navigation and cached
# diff buffers; comments post via this script's --post subcommand.
LUA_UI="$SCRIPT_DIR/pr-review.lua"
set_now_ms t_prep0
if have nvim && [[ -f "$LUA_UI" ]]; then
  # nvim is a native Windows process, so it needs a Windows path to bash.exe;
  # the script path stays MSYS-style since bash.exe understands it.
  PRDASH_BASH="$(cygpath -w "$(command -v bash)" 2>/dev/null || command -v bash)"
  export PRDASH_SCRIPT="$SCRIPT_PATH"
  export PRDASH_BASH SOURCE TARGET AZURE_DEVOPS_EXT_PAT
  export PRDASH_ID PRDASH_ORG PRDASH_PROJECT PRDASH_REPO PRDASH_SOURCE PRDASH_TARGET PRDASH_REPO_PATH
  set_now_ms _n
  tlog "phase: exports+cygpath (nvim prep): $(( _n - t_prep0 )) ms"
  tlog "phase: total script-top -> nvim launch: $(( _n - t_script_start )) ms"
  tlog "pre-nvim total (Enter -> nvim launch): $(( _n - t_start )) ms"
  nvim -u "$(cygpath -m "$LUA_UI" 2>/dev/null || echo "$LUA_UI")"
  exit 0
fi
echo "nvim (with pr-review.lua next to this script) is required to review a PR." >&2
exit 1
