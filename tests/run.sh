#!/usr/bin/env bash
# tests/run.sh - azure-vicli test runner.
#
# Requires: bash, git, luajit. Does NOT require dotnet - CI builds the C#
# project as a separate step; this script only exercises the Lua UIs and
# the bash helpers.
#
# What it checks, in order:
#   1. luajit -bl syntax check on every Lua UI file.
#   2. A global-name scan on every Lua UI file: any name luajit resolves as
#      a global that isn't a known Lua/vim builtin means some *other* name
#      is being read before its `local` declaration further down the file
#      (shadowing what looks like a builtin, or just a typo) - a real bug
#      class in this codebase's style of long files with forward references.
#   3. bash -n on every shell script.
#   4. The five Lua unit tests below it in this directory, against a
#      synthetic scratch git repo and a stubbed review-pr.sh --threads.
#
# The repo's Lua and shell files are CRLF (see README.md); luajit needs LF
# input for -bl and dofile, and CR bytes upset some `bash -n` diagnostics,
# so everything gets CR-stripped into a temp dir before it's touched.
#
# Prints a PASS/FAIL line per check and a summary, and exits non-zero if
# anything failed.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/      /'; fi
}

for tool in luajit git bash; do
  command -v "$tool" >/dev/null 2>&1 || { echo "tests/run.sh: '$tool' is required but not on PATH" >&2; exit 1; }
done

LUA_FILES=(azure-cli.lua pr-review.lua wi-dash.lua wi-view.lua prdash-cache.lua prdash-notify.lua)
SH_FILES=(install.sh resolve-pat.sh review-pr.sh wi-detail.sh wi-edit.sh wi-list.sh wi-state.sh)

# Names luajit's bytecode listing may report GGET/GSET for without it being a
# sign of trouble: Lua/LuaJIT builtins these files actually use, plus `vim`
# (the host global every UI file assumes) and `_G` (used to publish caches).
ALLOWED_GLOBALS=(_G debug dofile error ipairs math os pairs pcall select string table tonumber tostring type vim)

mkdir -p "$TMP/lua" "$TMP/sh"

# --- CR-strip everything the checks below need into the temp dir. ---------
for f in "${LUA_FILES[@]}"; do
  tr -d '\r' < "$REPO_ROOT/$f" > "$TMP/lua/$f"
done
for f in "${SH_FILES[@]}"; do
  tr -d '\r' < "$REPO_ROOT/$f" > "$TMP/sh/$f"
done

echo "== 1. luajit -bl syntax check =="
for f in "${LUA_FILES[@]}"; do
  bc="$TMP/lua/$f.bc"
  if err="$(luajit -bl "$TMP/lua/$f" 2>&1 1>"$bc")"; then
    pass "syntax: $f"
  else
    fail "syntax: $f" "$err"
  fi
done

echo
echo "== 2. global-name scan =="
allowed_sorted="$(printf '%s\n' "${ALLOWED_GLOBALS[@]}" | LC_ALL=C sort -u)"
for f in "${LUA_FILES[@]}"; do
  bc="$TMP/lua/$f.bc"
  if [ ! -s "$bc" ]; then
    fail "globals: $f" "no bytecode listing (syntax check above failed)"
    continue
  fi
  names="$(grep -E 'G(GET|SET)' "$bc" | sed -E 's/.*"([^"]+)".*/\1/' | LC_ALL=C sort -u)"
  extra="$(comm -23 <(printf '%s\n' "$names") <(printf '%s\n' "$allowed_sorted"))"
  extra="$(printf '%s' "$extra" | sed '/^$/d')"
  if [ -z "$extra" ]; then
    pass "globals: $f"
  else
    fail "globals: $f" "unexpected global name(s), likely a local read before its declaration: $(printf '%s' "$extra" | tr '\n' ' ')"
  fi
done

echo
echo "== 3. bash -n on shell scripts =="
for f in "${SH_FILES[@]}"; do
  if err="$(bash -n "$TMP/sh/$f" 2>&1)"; then
    pass "bash -n: $f"
  else
    fail "bash -n: $f" "$err"
  fi
done

# --- Scratch git repo + stub review script for the prefetch/split/decorate
#     tests. Recipe: tgt branch has f.txt = "a\nb\n" and d/g.txt = "x\n";
#     src branch (from tgt) edits f.txt to "a\nB\nc\n", adds n.txt, removes
#     d/g.txt; both are exposed as refs/remotes/origin/{src,tgt} because
#     prdash-cache.lua's prefetch always diffs origin/<target>...origin/<source>.
SCRATCH="$TMP/scratch-repo"
build_scratch_repo() {
  git init -q "$SCRATCH"
  (
    cd "$SCRATCH" || exit 1
    git config user.email "test@example.com"
    git config user.name "azure-vicli tests"
    git checkout -q -b tgt
    mkdir -p d
    printf 'a\nb\n' > f.txt
    printf 'x\n' > d/g.txt
    git add -A
    git commit -q -m "tgt"
    git checkout -q -b src
    printf 'a\nB\nc\n' > f.txt
    printf 'new\n' > n.txt
    git rm -q d/g.txt
    git add -A
    git commit -q -m "src"
    git update-ref refs/remotes/origin/src src
    git update-ref refs/remotes/origin/tgt tgt
  )
}
build_scratch_repo

STUB_SCRIPT="$TMP/stub-review.sh"
cat > "$STUB_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Stub for review-pr.sh: only understands --threads, used by
# prdash-cache.lua's prefetch to warm the comment-thread cache.
if [ "${1:-}" = "--threads" ]; then
  printf '%s\n' '{"value":[],"threads-ok":1}'
fi
exit 0
EOF
chmod +x "$STUB_SCRIPT"

echo
echo "== 4. lua tests =="

CACHE_LUA="$TMP/lua/prdash-cache.lua"
REVIEW_LUA="$TMP/lua/pr-review.lua"
NOTIFY_LUA="$TMP/lua/prdash-notify.lua"

# test-split.lua wants a real, multi-file range - use this repo's own
# history rather than the tiny scratch repo above. Falls back gracefully
# (an empty but valid range) on a shallow checkout with no older commits.
ROOT_COMMIT="$(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"
HEAD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [ -z "$ROOT_COMMIT" ]; then ROOT_COMMIT="$HEAD_COMMIT"; fi
SPLIT_RANGE="$ROOT_COMMIT..$HEAD_COMMIT"

run_lua_test() {
  local name="$1" cwd="$2"
  shift 2
  local out
  if out="$(cd "$cwd" && luajit "$REPO_ROOT/tests/$name" "$@" 2>&1)"; then
    pass "$name"
  else
    fail "$name" "$out"
  fi
}

run_lua_test test-split.lua "$REPO_ROOT" "$CACHE_LUA" "$SPLIT_RANGE"
run_lua_test test-prefetch.lua "$REPO_ROOT" "$CACHE_LUA" "$SCRATCH" "$STUB_SCRIPT"
run_lua_test test-nav.lua "$REPO_ROOT" "$REVIEW_LUA"
run_lua_test test-decorate.lua "$REPO_ROOT" "$CACHE_LUA" "$REVIEW_LUA" "$SCRATCH"
run_lua_test test-notify.lua "$REPO_ROOT" "$NOTIFY_LUA"

echo
echo "== summary =="
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "failing checks:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
