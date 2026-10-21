#!/usr/bin/env bash
# tests/run.sh - azure-vicli test runner.
#
# Requires: bash, git, luajit, python3. There is no compiled data provider
# any more (azure-cli.py is run directly by python), so nothing here needs
# a build step first.
#
# What it checks, in order:
#   0. Every tests/*.lua loads tests/sandbox.lua first (its own XDG dirs,
#      an empty HOME and a clean environment however it's started); step 4 and the
#      smokes also start some straight from a polluted environment and
#      check nothing reached the sentinel "real" dirs.
#   1. luajit -bl syntax check on every Lua UI file, plus (when nvim is on
#      PATH) loading every file with a real Neovim, which is stricter.
#   2. A global-name scan on every Lua UI file: any name luajit resolves as
#      a global that isn't a known Lua/vim builtin means some *other* name
#      is being read before its `local` declaration further down the file
#      (shadowing what looks like a builtin, or just a typo) - a real bug
#      class in this codebase's style of long files with forward references.
#   3. bash -n on every shell script.
#   4. The thirty-five Lua unit tests below it in this directory, against a
#      synthetic scratch git repo and a stubbed provider --threads.
#   5. `python3 -m unittest` over tests/test_*.py - unit tests for
#      azure-cli.py (the YAML-subset config parser, PR classification,
#      thread/mention counting, build-status aggregation, formatting,
#      NDJSON serialization, the PR-action REST bodies, and the work-item
#      subcommands' REST bodies/sprint-resolution/HTML flattening), all
#      against hand-built fixtures and a fake `fetch` - no network access
#      or live Azure DevOps instance needed.
#
# The repo's Lua and shell files are CRLF (see README.md); luajit needs LF
# input for -bl and dofile, and CR bytes upset some `bash -n` diagnostics,
# so everything gets CR-stripped into a temp dir before it's touched.
# azure-cli.py and tests/test_*.py are plain LF, like every other new
# (post-C#) file in this repo.
#
# Prints a PASS/FAIL line per check and a summary, and exits non-zero if
# anything failed.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Nothing from the environment we were started in: a run from inside
# Neovim (the chat agent's run_tests, a :terminal) inherits the plugin's
# AZVICLI_* exports - the prefetch dir, the PR the dashboard last opened -
# which the tests would otherwise read as their own.
for v in $(env | sed -n 's/^\(AZVICLI_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
# Nor the parent Neovim's runtime: an nvim started from a :terminal or an
# agent would otherwise use that one's VIMRUNTIME, whatever nvim PATH finds.
# NVIM_LOG_FILE too, so a run from inside Neovim sees what CI sees.
unset VIM VIMRUNTIME NVIM MYVIMRC NVIM_LOG_FILE

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Every test gets its own Neovim data/cache/state/config directories: the
# chat's conversations, plans and audit log, the per-agent MCP config files
# and the rest must never land in (or be read from) the real ones.
export XDG_DATA_HOME="$TMP/xdg-data" XDG_CACHE_HOME="$TMP/xdg-cache" XDG_STATE_HOME="$TMP/xdg-state"
export XDG_CONFIG_HOME="$TMP/xdg-config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"

PASS=0
FAIL=0
SKIPPED=0  # smoke checks skipped for an earlier smoke failure
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/      /'; fi
}

for tool in luajit git bash python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "tests/run.sh: '$tool' is required but not on PATH" >&2; exit 1; }
done

# Every Lua file the plugin ships: lua/azure-cli/**/*.lua (the require()'d
# modules), plugin/*.lua (the :AzureCli command) and standalone/*.lua (the
# launcher's nvim entry point) - see README's Architecture section for the
# tree. Sorted so the check output (and any failure) is stable across runs.
LUA_FILES=($(cd "$REPO_ROOT" && find lua plugin standalone -name '*.lua' | LC_ALL=C sort))
SH_FILES=(azure-cli install.sh tests/demo.sh)

# Names luajit's bytecode listing may report GGET/GSET for without it being a
# sign of trouble: Lua/LuaJIT builtins these files actually use, plus `vim`
# (the host global every UI file assumes), `require` (every module resolves
# its sibling modules through Neovim's package.path/rtp with it now - see
# lua/azure-cli/init.lua) and `_G` (keyhints.lua's: whether which-key or
# mini.clue is there - _G.package.loaded, _G.MiniClue).
# setmetatable is review/comments.lua's (and, the same way, review/commits.lua's
# and review/range.lua's) own: each module table doubles as a plain table of
# pure helpers (for its tests/test-review-*.lua) and a callable
# `require(path)(ctx)` (for review/init.lua's EXT wiring) via a __call
# metamethod. rawset is chat/init.lua's: a plan's own conversation keeps
# its fields raw and hands the rest to the main one (__newindex).
ALLOWED_GLOBALS=(_G debug dofile error ipairs math next os pairs pcall rawset require select setmetatable string table tonumber tostring type vim)

mkdir -p "$TMP/lua" "$TMP/sh"

# --- CR-strip everything the checks below need into the temp dir. ---------
# LUA_FILES entries carry their own lua/, plugin/, standalone/ prefix, so
# each one's CR-stripped copy lands at the same relative path under $TMP/lua
# (its own subdirectory created on demand) rather than colliding on basename.
for f in "${LUA_FILES[@]}"; do
  mkdir -p "$TMP/lua/$(dirname "$f")"
  tr -d '\r' < "$REPO_ROOT/$f" > "$TMP/lua/$f"
done
for f in "${SH_FILES[@]}"; do
  mkdir -p "$TMP/sh/$(dirname "$f")"
  tr -d '\r' < "$REPO_ROOT/$f" > "$TMP/sh/$f"
done

# 0. Every Lua test loads tests/sandbox.lua before anything else, so it gets
# its own XDG dirs however it is started - not only from here. Not
# gen-keys-table.lua: a generator, not a test.
echo "== 0. sandbox guard =="
for f in tests/*.lua; do
  case "$f" in tests/sandbox.lua|tests/gen-keys-table.lua) continue ;; esac
  first="$(tr -d '\r' < "$f" | awk '!/^[[:space:]]*(--|$)/{print; exit}')"
  if [[ "$first" == 'dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")('* ]]; then
    pass "sandbox: $f"
  else
    fail "sandbox: $f" "its first statement must load tests/sandbox.lua (see that file), not: $first"
  fi
done

echo
echo "== 1. luajit -bl syntax check =="
for f in "${LUA_FILES[@]}"; do
  bc="$TMP/lua/$f.bc"
  if err="$(luajit -bl "$TMP/lua/$f" 2>&1 1>"$bc")"; then
    pass "syntax: $f"
  else
    fail "syntax: $f" "$err"
  fi
done

# 1b. Load every Lua file with a real Neovim when one is on PATH, against
# the original (CRLF) files exactly as the dashboard does. Neovim's Lua
# rejects some code standalone luajit accepts - a statement that starts with
# "(" right after another statement is "ambiguous syntax" - so the luajit -bl
# check alone once let a pr-review.lua that nvim could not load reach master.
echo "== 1b. nvim loadfile check =="
if command -v nvim >/dev/null 2>&1; then
  for f in "${LUA_FILES[@]}"; do
    out="$(nvim -u NONE --headless \
      -c "lua local fn, err = loadfile([[$REPO_ROOT/$f]]); if fn then print('LOAD-OK') else print('LOAD-FAIL ' .. tostring(err)) end" \
      -c 'qa!' 2>&1)"
    if [[ "$out" == *LOAD-OK* ]]; then
      pass "nvim load: $f"
    else
      fail "nvim load: $f" "$out"
    fi
  done
else
  echo "(nvim not on PATH - skipped; CI installs neovim so it runs there)"
fi

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
  # LC_ALL=C here too: comm checks its inputs are sorted per the active
  # locale's collation, and both were sorted above with LC_ALL=C - under a
  # non-C locale (e.g. a UTF-8 one that collates "_"/case differently) comm
  # would disagree they're sorted and silently drop entries instead of
  # comparing them.
  extra="$(LC_ALL=C comm -23 <(printf '%s\n' "$names") <(printf '%s\n' "$allowed_sorted"))"
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

# --- Scratch git repo + stub provider script for the prefetch/split/decorate
#     tests. Recipe: tgt branch has f.txt = "a\nb\n", d/g.txt = "x\n" and
#     ws.txt = "same content\n"; src branch (from tgt) edits f.txt to
#     "a\nB\nc\n", adds n.txt, removes d/g.txt, and only adds trailing
#     whitespace to ws.txt (ws.txt exercises the gw/ignore_ws prefetch
#     variant in test-prefetch.lua: it has a plain diff but none under
#     --ignore-all-space). Both branches are exposed as
#     refs/remotes/origin/{src,tgt} because cache.lua's prefetch
#     always diffs origin/<target>...origin/<source>.
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
    printf 'same content\n' > ws.txt
    git add -A
    git commit -q -m "tgt"
    git checkout -q -b src
    printf 'a\nB\nc\n' > f.txt
    printf 'new\n' > n.txt
    git rm -q d/g.txt
    printf 'same content \n' > ws.txt
    git add -A
    git commit -q -m "src"
    git update-ref refs/remotes/origin/src src
    git update-ref refs/remotes/origin/tgt tgt
  )
}
build_scratch_repo

# Stub for the data provider (azure-cli.py, invoked via EXT.provider/
# PROVIDER_CMD as { python, azure-cli.py, ... } in the real app): only
# understands --threads, used by cache.lua's prefetch (spec.cmd) to
# warm the comment-thread cache. test-prefetch.lua passes spec.cmd =
# { "bash", STUB_SCRIPT } - a bash stub is fine here, the Lua side only
# cares that spec.cmd is a list it can append "--threads" onto.
STUB_SCRIPT="$TMP/stub-provider.sh"
cat > "$STUB_SCRIPT" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--threads" ]; then
  printf '%s\n' '{"value":[],"threads-ok":1}'
fi
exit 0
EOF
chmod +x "$STUB_SCRIPT"

echo
echo "== 4. lua tests =="

CACHE_LUA="$TMP/lua/lua/azure-cli/cache.lua"
REVIEW_LUA="$TMP/lua/lua/azure-cli/review/init.lua"
# Code navigation moved out of review/init.lua into its own module; test-nav.lua
# reads def_score and its keyword tables out of that file's source.
NAV_LUA="$TMP/lua/lua/azure-cli/review/nav.lua"
NOTIFY_LUA="$TMP/lua/lua/azure-cli/notify.lua"
RPC_LUA="$TMP/lua/lua/azure-cli/rpc.lua"
EDITOR_LUA="$TMP/lua/lua/azure-cli/editor.lua"
LOG_LUA="$TMP/lua/lua/azure-cli/log.lua"
PERF_LUA="$TMP/lua/lua/azure-cli/perf.lua"
WEB_LUA="$TMP/lua/lua/azure-cli/web.lua"
COMMENTS_LUA="$TMP/lua/lua/azure-cli/review/comments.lua"
COMMITS_LUA="$TMP/lua/lua/azure-cli/review/commits.lua"
RANGE_LUA="$TMP/lua/lua/azure-cli/review/range.lua"
BATCH_LUA="$TMP/lua/lua/azure-cli/review/batch.lua"
SINCE_LUA="$TMP/lua/lua/azure-cli/review/since.lua"
FOLLOWUP_LUA="$TMP/lua/lua/azure-cli/review/followup.lua"
CONFIG_LUA="$TMP/lua/lua/azure-cli/config.lua"
KEYS_LUA="$TMP/lua/lua/azure-cli/keys.lua"
UI_LUA="$TMP/lua/lua/azure-cli/ui.lua"
INNERTABS_LUA="$TMP/lua/lua/azure-cli/innertabs.lua"
PROMPT_LUA="$TMP/lua/lua/azure-cli/prompt.lua"
PRS_LUA="$TMP/lua/lua/azure-cli/prs.lua"
MERGE_LUA="$TMP/lua/lua/azure-cli/merge.lua"
HOSTS_LUA="$TMP/lua/lua/azure-cli/hosts.lua"
SHELL_LUA="$TMP/lua/lua/azure-cli/shell.lua"
PANE_LUA="$TMP/lua/lua/azure-cli/review/pane.lua"
VIEWED_LUA="$TMP/lua/lua/azure-cli/review/viewed.lua"
FOLDS_LUA="$TMP/lua/lua/azure-cli/review/folds.lua"
BOM_LUA="$TMP/lua/lua/azure-cli/review/bom.lua"
FILELIST_LUA="$TMP/lua/lua/azure-cli/review/filelist.lua"
IMAGES_LUA="$TMP/lua/lua/azure-cli/review/images.lua"
MIGRATE_LUA="$TMP/lua/lua/azure-cli/migrate.lua"
STATES_LUA="$TMP/lua/lua/azure-cli/workitems/states.lua"
STATE_DIALOG_LUA="$TMP/lua/lua/azure-cli/workitems/state_dialog.lua"
LINKED_PRS_LUA="$TMP/lua/lua/azure-cli/workitems/linked_prs.lua"
PR_WORKITEMS_LUA="$TMP/lua/lua/azure-cli/pr_workitems.lua"

# test-split.lua wants a real, multi-file range - use this repo's own
# history rather than the tiny scratch repo above. When there is nothing
# older than HEAD to diff against (a single-commit history, or a shallow
# checkout), diff the empty tree against HEAD instead, so the range still
# covers every file in the repo.
ROOT_COMMIT="$(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"
HEAD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [ -z "$ROOT_COMMIT" ] || [ "$ROOT_COMMIT" = "$HEAD_COMMIT" ]; then
  ROOT_COMMIT="$(git -C "$REPO_ROOT" hash-object -t tree /dev/null)"
fi
SPLIT_RANGE="$ROOT_COMMIT..$HEAD_COMMIT"

# cache.lua/notify.lua/rpc.lua now require() their siblings (state.lua,
# rpc.lua) instead of dofile()ing them, even when a test dofile()s ONE of
# them directly without going through Neovim's own runtimepath-aware
# require(). LUA_PATH is plain Lua/LuaJIT's own require() search path (not
# vim-specific), so pointing it at the CR-stripped mirror's lua/ directory
# lets that inner require("azure-cli.x") resolve to the matching
# CR-stripped copy on disk - the same modules, found the normal way,
# instead of every affected test needing its own package.loaded shim.
export LUA_PATH="$TMP/lua/lua/?.lua;$TMP/lua/lua/?/init.lua;;"

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
run_lua_test test-nav.lua "$REPO_ROOT" "$NAV_LUA"
run_lua_test test-decorate.lua "$REPO_ROOT" "$CACHE_LUA" "$NAV_LUA" "$SCRATCH"
run_lua_test test-worddiff.lua "$REPO_ROOT" "$CACHE_LUA"
run_lua_test test-notify.lua "$REPO_ROOT" "$NOTIFY_LUA"
run_lua_test test-rpc.lua "$REPO_ROOT" "$RPC_LUA"
run_lua_test test-editor.lua "$REPO_ROOT" "$EDITOR_LUA"
run_lua_test test-log.lua "$REPO_ROOT" "$LOG_LUA"
run_lua_test test-perf.lua "$REPO_ROOT" "$PERF_LUA"
run_lua_test test-web.lua "$REPO_ROOT" "$WEB_LUA"
run_lua_test test-review-comments.lua "$REPO_ROOT" "$COMMENTS_LUA"
run_lua_test test-review-commits.lua "$REPO_ROOT" "$COMMITS_LUA"
run_lua_test test-review-range.lua "$REPO_ROOT" "$RANGE_LUA"
run_lua_test test-review-batch.lua "$REPO_ROOT" "$BATCH_LUA"
run_lua_test test-review-since.lua "$REPO_ROOT" "$SINCE_LUA"
run_lua_test test-review-followup.lua "$REPO_ROOT" "$FOLLOWUP_LUA"
run_lua_test test-keys.lua "$REPO_ROOT" "$CONFIG_LUA" "$KEYS_LUA"
run_lua_test test-migrate.lua "$REPO_ROOT" "$MIGRATE_LUA"
run_lua_test test-states.lua "$REPO_ROOT" "$STATES_LUA"
run_lua_test test-config.lua "$REPO_ROOT" "$CONFIG_LUA" "$CACHE_LUA"
run_lua_test test-ui.lua "$REPO_ROOT" "$UI_LUA"
run_lua_test test-innertabs.lua "$REPO_ROOT" "$INNERTABS_LUA"
run_lua_test test-prompt.lua "$REPO_ROOT" "$PROMPT_LUA"
run_lua_test test-prs.lua "$REPO_ROOT" "$PRS_LUA"
run_lua_test test-merge.lua "$REPO_ROOT" "$MERGE_LUA"
run_lua_test test-hosts.lua "$REPO_ROOT" "$HOSTS_LUA"
run_lua_test test-shell.lua "$REPO_ROOT" "$SHELL_LUA"
run_lua_test test-state-dialog.lua "$REPO_ROOT" "$STATE_DIALOG_LUA"
run_lua_test test-linked-prs.lua "$REPO_ROOT" "$LINKED_PRS_LUA"
run_lua_test test-pr-workitems.lua "$REPO_ROOT" "$PR_WORKITEMS_LUA"
run_lua_test test-review-pane.lua "$REPO_ROOT" "$PANE_LUA"
run_lua_test test-review-viewed.lua "$REPO_ROOT" "$VIEWED_LUA"
run_lua_test test-review-folds.lua "$REPO_ROOT" "$FOLDS_LUA" "$PANE_LUA" "$VIEWED_LUA"
run_lua_test test-review-bom.lua "$REPO_ROOT" "$BOM_LUA" "$CACHE_LUA" "$PANE_LUA"
run_lua_test test-review-filelist.lua "$REPO_ROOT" "$FILELIST_LUA"
run_lua_test test-review-images.lua "$REPO_ROOT" "$IMAGES_LUA" "$REPO_ROOT/tests/fake-provider.py"

# A test started straight from a polluted environment - XDG dirs at a
# sentinel "real" directory, the parent nvim's runtime vars, the chat's
# AZVICLI_CHAT_* - must not write a byte there (tests/sandbox.lua).
# The outer nvim creates its log at startup, before any test code runs, so
# it gets NVIM_LOG_FILE outside $REAL - as an nvim started from Neovim
# would; test-sandbox.lua checks that file doesn't reach the sandbox.
REAL="$TMP/real"
OUTER_LOG="$TMP/outer-nvim.log"
mkdir -p "$REAL/data" "$REAL/state" "$REAL/cache" "$REAL/config" "$REAL/home" "$TMP/bogus-runtime"
sentinel() {
  local name="$1"
  shift
  local out rc left
  out="$(cd "$REPO_ROOT" && env -u AZVICLI_TEST_SANDBOX \
    XDG_DATA_HOME="$REAL/data" XDG_STATE_HOME="$REAL/state" XDG_CACHE_HOME="$REAL/cache" XDG_CONFIG_HOME="$REAL/config" \
    HOME="$REAL/home" VIM="$TMP/bogus-runtime" VIMRUNTIME="$TMP/bogus-runtime" NVIM="$TMP/bogus-nvim.sock" MYVIMRC="$REAL/config/nvim/init.lua" \
    NVIM_LOG_FILE="$OUTER_LOG" \
    AZVICLI_CHAT_AGENT=leak AZVICLI_CHAT_BRIDGE=leak AZVICLI_CHAT_TOKEN=leak \
    timeout 120 "$@" 2>&1)"
  rc=$?
  left="$(find "$REAL" -mindepth 2 2>/dev/null)"
  if [ $rc -eq 0 ] && [ -z "$left" ]; then
    pass "sandbox: $name leaves the real data dir alone"
  else
    fail "sandbox: $name leaves the real data dir alone" "rc $rc; written to the real dirs: ${left:-nothing}
$out"
  fi
}
sentinel "test-sandbox.lua (luajit, started directly)" luajit "$REPO_ROOT/tests/test-sandbox.lua" "$REAL"

echo
echo "== 5. python tests (azure-cli.py) =="
if out="$(cd "$REPO_ROOT" && python3 -m unittest discover -s tests -p 'test_*.py' 2>&1)"; then
  pass "python: tests/test_*.py"
else
  fail "python: tests/test_*.py" "$out"
fi

echo
echo "== 6. headless nvim smokes (plugin load, standalone launch, fake-provider demo) =="
if command -v nvim >/dev/null 2>&1; then
  # setup()/config.lua smoke: the plugin loads standalone (rtp set by hand,
  # like a plugin manager would), setup() runs with no options, and
  # config.lua's resolved defaults carry the diff surface's next_hunk key -
  # i.e. requiring azure-cli.config from a plain 'require("azure-cli")'
  # install actually resolves through 'rtp', not just from this repo's own
  # checkout layout.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" \
    -c "lua require('azure-cli').setup()" \
    -c "lua assert(require('azure-cli.config').get().keys.diff.next_hunk)" \
    -c "lua print('SETUP-SMOKE-OK')" \
    -c "qa!" 2>&1)"
  if [[ "$out" == *SETUP-SMOKE-OK* ]]; then
    pass "smoke: setup()/config.lua keys.diff.next_hunk"
  else
    fail "smoke: setup()/config.lua keys.diff.next_hunk" "$out"
  fi

  # standalone/init.lua first-run smoke: the launcher's real nvim entry
  # point, headless, against a temp config directory with no azure-cli.yml.
  # There is no install step any more (install.sh only checks dependencies),
  # so this first launch must write the template (firstrun.lua -> the
  # provider's --init-config) and open THAT file - filetype yaml, a TODO in
  # it - rather than a dashboard that can only say "configuration does not
  # exist".
  SMOKE_CFG="$TMP/smoke-config"
  mkdir -p "$SMOKE_CFG"
  out="$(XDG_CONFIG_HOME="$SMOKE_CFG" nvim --headless -u "$REPO_ROOT/standalone/init.lua" \
    -c "lua assert(vim.bo.filetype == 'yaml', 'filetype=' .. tostring(vim.bo.filetype))" \
    -c "lua assert(vim.fn.expand('%:p') == '$SMOKE_CFG/azure-cli.yml', 'buffer=' .. vim.fn.expand('%:p'))" \
    -c "lua assert(vim.fn.filereadable('$SMOKE_CFG/azure-cli.yml') == 1, 'template not written')" \
    -c "lua assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n'):find('TODO', 1, true), 'no TODO in template')" \
    -c "lua print('FIRSTRUN-SMOKE-OK')" \
    -c "qa!" 2>&1)"
  if [[ "$out" == *FIRSTRUN-SMOKE-OK* ]]; then
    pass "smoke: standalone/init.lua first run writes the config template and opens it"
  else
    fail "smoke: standalone/init.lua first run writes the config template and opens it" "$out"
  fi

  # Second launch against the same directory: the (still-TODO) template now
  # exists, so the dashboard buffer itself renders (filetype
  # "azurecli-dashboard") - --list fails fast on the incomplete config, and
  # that failure text is what the buffer shows; the point is that the
  # dashboard opens, not that the fetch succeeds.
  out="$(XDG_CONFIG_HOME="$SMOKE_CFG" nvim --headless -u "$REPO_ROOT/standalone/init.lua" \
    -c "lua assert(vim.bo.filetype == 'azurecli-dashboard', 'filetype=' .. tostring(vim.bo.filetype))" \
    -c "lua print('STANDALONE-SMOKE-OK')" \
    -c "qa!" 2>&1)"
  if [[ "$out" == *STANDALONE-SMOKE-OK* ]]; then
    pass "smoke: standalone/init.lua opens the dashboard buffer once a config exists"
  else
    fail "smoke: standalone/init.lua opens the dashboard buffer once a config exists" "$out"
  fi

  # Stage 2 smoke: setup({keys={diff={next_hunk="]h"}}}) actually changes
  # what the diff surface resolves - not just that config.lua's defaults
  # carry the action (stage 1's smoke above), but that a real override
  # applies end to end through KEYS.resolve.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" \
    -c "lua require('azure-cli').setup({ keys = { diff = { next_hunk = ']h' } } })" \
    -c "lua assert(require('azure-cli.keys').resolve('diff', 'next_hunk') == ']h', require('azure-cli.keys').resolve('diff', 'next_hunk'))" \
    -c "lua print('KEYS-OVERRIDE-SMOKE-OK')" \
    -c "qa!" 2>&1)"
  if [[ "$out" == *KEYS-OVERRIDE-SMOKE-OK* ]]; then
    pass "smoke: setup({keys={diff={next_hunk=']h'}}}) overrides the diff surface"
  else
    fail "smoke: setup({keys={diff={next_hunk=']h'}}}) overrides the diff surface" "$out"
  fi

  # :AzureCli status smoke: setup({python=..., config=...}) end to end
  # through init.lua's M.status() - the resolved python/config it reports
  # (and returns) must be exactly what was passed to setup(), not the probe/
  # platform defaults, and AZVICLI_PY must NOT win here since it's deliberately
  # left unset in this smoke (see test-config.lua for the env-wins-over-setup
  # precedence case).
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" \
    -c "lua require('azure-cli').setup({ python = '/opt/my/python', config = '/tmp/my-azure-cli.yml' })" \
    -c "lua local st = require('azure-cli').status(); assert(st.python == '/opt/my/python', st.python); assert(st.config == '/tmp/my-azure-cli.yml', st.config)" \
    -c "lua print('STATUS-SMOKE-OK')" \
    -c "qa!" 2>&1)"
  if [[ "$out" == *STATUS-SMOKE-OK* ]]; then
    pass "smoke: :AzureCli status shows setup({python=..., config=...})'s resolved values"
  else
    fail "smoke: :AzureCli status shows setup({python=..., config=...})'s resolved values" "$out"
  fi

  # gO and :AzureCli status name both config files: the accounts
  # (azure-cli.yml) and the options - azure-cli.lua next to it in the
  # standalone launcher, your own setup() in plugin mode.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" \
    -c "lua require('azure-cli').setup({ config = '/tmp/my-cfg/azure-cli.yml' })" \
    -c "lua local c = require('azure-cli.shell').config_choices(); assert(#c == 2 and c[1].label:find('azure-cli.yml', 1, true) and c[2].label:find('setup({...})', 1, true), vim.inspect(c)); assert(require('azure-cli').status().options:find('setup()', 1, true))" \
    -c "lua require('azure-cli.shell').open_options_file(); assert(vim.bo.buftype == 'nofile' and vim.tbl_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), 'return {'), 'no scratch options list'); assert(vim.fn.filereadable('/tmp/my-cfg/azure-cli.lua') == 0, 'plugin mode wrote azure-cli.lua')" \
    -c "lua require('azure-cli').set_standalone(true); local c = require('azure-cli.shell').config_choices(); assert(c[2].label:find('/tmp/my-cfg/azure-cli.lua  (new', 1, true), c[2].label); assert(require('azure-cli').status().options:find('/tmp/my-cfg/azure-cli.lua (not created', 1, true))" \
    -c "lua print('GO-SMOKE-OK')" \
    -c "qa!" 2>&1)"
  if [[ "$out" == *GO-SMOKE-OK* ]]; then
    pass "smoke: gO offers the accounts and the options file, and :AzureCli status names both"
  else
    fail "smoke: gO offers the accounts and the options file, and :AzureCli status names both" "$out"
  fi

  # setup({accounts=...}) smoke: a plugin install with no azure-cli.yml at
  # all - the accounts table (with a pat_file) is exported to the provider,
  # so the first :AzureCli opens the real dashboard buffer (not the
  # first-run template), and the real provider resolves the token from the
  # file for --print-pat. org_url points at a closed local port so the
  # dashboard's own --list fails instantly instead of touching the network.
  SMOKE_ACCT="$TMP/smoke-accounts"
  mkdir -p "$SMOKE_ACCT/config"
  printf 'the-token\n' > "$SMOKE_ACCT/pat"
  chmod 600 "$SMOKE_ACCT/pat"
  out="$(XDG_CONFIG_HOME="$SMOKE_ACCT/config" nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" \
    -c "runtime plugin/azure-cli.lua" \
    -c "lua require('azure-cli').setup({ accounts = { { project_name = 'P', org_url = 'http://127.0.0.1:9/', pat_file = '$SMOKE_ACCT/pat' } } })" \
    -c "AzureCli dashboard" \
    -c "lua assert(vim.bo.filetype == 'azurecli-dashboard', 'filetype=' .. tostring(vim.bo.filetype))" \
    -c "lua assert(vim.fn.filereadable('$SMOKE_ACCT/config/azure-cli.yml') == 0, 'a template was written despite setup accounts')" \
    -c "lua local argv = require('azure-cli.config').provider_cmd(); vim.list_extend(argv, { '--print-pat', '--org', 'http://127.0.0.1:9' }); local tok = vim.fn.system(argv); assert(tok == 'the-token', 'print-pat gave ' .. vim.inspect(tok))" \
    -c "lua assert(require('azure-cli').status().config:find('setup({accounts', 1, true), 'status did not name setup()')" \
    -c "lua print('ACCOUNTS-SMOKE-OK')" \
    -c "qa!" 2>&1)"
  if [[ "$out" == *ACCOUNTS-SMOKE-OK* ]]; then
    pass "smoke: setup({accounts={{pat_file=...}}}) needs no config file and the provider reads the token"
  else
    fail "smoke: setup({accounts={{pat_file=...}}}) needs no config file and the provider reads the token" "$out"
  fi

  # The chat panel's pure helpers (chat/*.lua, review/chat.lua) need
  # vim.json and vim.api at load, so their unit tests run in a real nvim.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-chat.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all chat tests passed"* ]]; then
    pass "test-chat.lua (headless nvim)"
  else
    fail "test-chat.lua (headless nvim)" "$out"
  fi

  # A chat turn's idle timeout and hard cap (chat/watchdog.lua), on a
  # clock the test turns by hand.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-chat-watchdog.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all chat-watchdog tests passed"* ]]; then
    pass "test-chat-watchdog.lua (headless nvim)"
  else
    fail "test-chat-watchdog.lua (headless nvim)" "$out"
  fi

  # The reviewer Overview's highlighting (review/overview_syntax.lua, #135):
  # Markdown only in the description and comment bodies, no markdownError.
  out="$(timeout 30 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-review-overview-syntax.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all overview syntax tests passed"* ]]; then
    pass "test-review-overview-syntax.lua (headless nvim)"
  else
    fail "test-review-overview-syntax.lua (headless nvim)" "$out"
  fi

  # How a comment reads in the K popup (review/thread_text.lua): links,
  # bots' reference lines, wrapping under the gutter, the colours.
  out="$(timeout 30 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-review-thread-text.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all thread text tests passed"* ]]; then
    pass "test-review-thread-text.lua (headless nvim)"
  else
    fail "test-review-thread-text.lua (headless nvim)" "$out"
  fi

  # poll.lua (#93): the network polls slow while unfocused or idle and
  # refresh once on return, on a clock the test turns by hand; the phone
  # dashboard's feed keeps its pace.
  out="$(timeout 30 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-poll.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all poll tests passed"* ]]; then
    pass "test-poll.lua (headless nvim)"
  else
    fail "test-poll.lua (headless nvim)" "$out"
  fi

  # The phone dashboard's token across restarts (#105), against the real
  # --web-dashboard server: same URL after a restart, 0600, rotate, never
  # on argv or in the log.
  out="$(timeout 60 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-web-token.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all web-token tests passed"* ]]; then
    pass "test-web-token.lua (headless nvim)"
  else
    fail "test-web-token.lua (headless nvim)" "$out"
  fi

  # start_story against a scratch origin and clone: the worktree on its
  # branch (#59), the clone from clones_dir (#64), no PR on an existing
  # branch (#57).
  out="$(timeout 60 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-start-story.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all start_story tests passed"* ]]; then
    pass "test-start-story.lua (headless nvim)"
  else
    fail "test-start-story.lua (headless nvim)" "$out"
  fi

  # The comment editor leaves insert mode behind it (needs the main loop).
  out="$(timeout 20 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -c "luafile $REPO_ROOT/tests/test-editor-mode.lua" 2>&1)"
  if [[ "$out" == *EDITOR-MODE-OK* ]]; then
    pass "test-editor-mode.lua (headless nvim, real input)"
  else
    fail "test-editor-mode.lua (headless nvim, real input)" "$out"
  fi

  # The chat input: <CR> sends while typing, <C-j> breaks the line (real input).
  out="$(timeout 20 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -c "luafile $REPO_ROOT/tests/test-chat-insert-send.lua" 2>&1)"
  if [[ "$out" == *CHAT-INSERT-SEND-OK* ]]; then
    pass "test-chat-insert-send.lua (headless nvim, real input)"
  else
    fail "test-chat-insert-send.lua (headless nvim, real input)" "$out"
  fi

  # Enter on an Agents row opens its agent in normal mode; i types (#118).
  out="$(timeout 30 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -c "luafile $REPO_ROOT/tests/test-agents-enter-mode.lua" 2>&1)"
  if [[ "$out" == *AGENTS-ENTER-MODE-OK* ]]; then
    pass "test-agents-enter-mode.lua (headless nvim, real input)"
  else
    fail "test-agents-enter-mode.lua (headless nvim, real input)" "$out"
  fi

  # The chat bridge over a real socket: the token, and the request size cap.
  out="$(timeout 20 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-chat-bridge.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all bridge tests passed"* ]]; then
    pass "test-chat-bridge.lua (headless nvim)"
  else
    fail "test-chat-bridge.lua (headless nvim)" "$out"
  fi

  # The yes/no popup (UI.confirm): its layout and every way out.
  out="$(timeout 30 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -c "luafile $REPO_ROOT/tests/test-confirm.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all confirm tests passed"* ]]; then
    pass "test-confirm.lua (headless nvim)"
  else
    fail "test-confirm.lua (headless nvim)" "$out"
  fi

  # The action palette (g.): a buffer's actions, run in its window.
  out="$(timeout 20 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-keys-palette.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all palette tests passed"* ]]; then
    pass "test-keys-palette.lua (headless nvim)"
  else
    fail "test-keys-palette.lua (headless nvim)" "$out"
  fi

  # g and a pause list the screen's g keys; the next key does what it did.
  out="$(timeout 20 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -c "luafile $REPO_ROOT/tests/test-key-hints.lua" 2>&1)"
  if [[ "$out" == *KEY-HINTS-OK* ]]; then
    pass "test-key-hints.lua (headless nvim, real input)"
  else
    fail "test-key-hints.lua (headless nvim, real input)" "$out"
  fi

  # Quitting while agents work, with more queued, exits right away.
  start=$(date +%s)
  out="$(timeout 30 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -c "luafile $REPO_ROOT/tests/test-chat-exit.lua" 2>&1)"
  rc=$?
  took=$(( $(date +%s) - start ))
  if [ $rc -ne 124 ] && [ "$took" -lt 10 ] && [[ "$out" == *CHAT-EXIT-STARTED* ]]; then
    pass "test-chat-exit.lua (quitting while agents work doesn't hang)"
  else
    fail "test-chat-exit.lua (quitting while agents work doesn't hang)" "rc $rc after ${took}s: $out"
  fi

  # The plan, the questions under a line, the change viewer's file list.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-chat-plan.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all chat-plan tests passed"* ]]; then
    pass "test-chat-plan.lua (headless nvim)"
  else
    fail "test-chat-plan.lua (headless nvim)" "$out"
  fi

  # dd on the Agents screen (#98): discarding a row's plan, against real
  # worktrees - asks first, refused while working, keeps a worktree with
  # changes, moves the files to plans/discarded/.
  out="$(timeout 60 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-plan-discard.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all plan-discard tests passed"* ]]; then
    pass "test-plan-discard.lua (headless nvim)"
  else
    fail "test-plan-discard.lua (headless nvim)" "$out"
  fi

  # The tab line's "N plans wait for you" (#117): redrawn once whenever the
  # plans index changes - discard, approve, a new plan - with no chat render.
  out="$(timeout 60 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-plan-tabline.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all plan-tabline tests passed"* ]]; then
    pass "test-plan-tabline.lua (headless nvim)"
  else
    fail "test-plan-tabline.lua (headless nvim)" "$out"
  fi

  # chat/init.lua's `send`: one agent process for the whole conversation
  # (tests/fake-persistent-agent.py), a new one after gm, and a one-shot
  # CLI (tests/fake-oneshot-agent.py) reported as one that can't stay up.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-chat-persistent.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all chat-persistent tests passed"* ]]; then
    pass "test-chat-persistent.lua (headless nvim)"
  else
    fail "test-chat-persistent.lua (headless nvim)" "$out"
  fi

  # agent.acp: one warm ACP session across messages, and azure-cli.py
  # --mcp-http for an agent that only takes http MCP servers (Copilot's
  # --acp) - tests/fake-acp-agent.py calls the tools over it.
  out="$(nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/test-chat-acp.lua" 2>&1)"
  if [ $? -eq 0 ] && [[ "$out" == *"all chat-acp tests passed"* ]]; then
    pass "test-chat-acp.lua (headless nvim)"
  else
    fail "test-chat-acp.lua (headless nvim)" "$out"
  fi

  # The same sentinel check as step 4's, under nvim: the probe, then the
  # chat tests that used to leave conversations behind when run by hand.
  for t in test-sandbox.lua test-chat.lua test-chat-persistent.lua test-chat-acp.lua; do
    sentinel "$t (nvim -l, started directly)" nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -l "$REPO_ROOT/tests/$t" "$REAL"
  done
  # A script loaded into an already-running nvim can't start again in a
  # sandbox of its own, so outside one it refuses (and touches nothing).
  out="$(cd "$REPO_ROOT" && env -u AZVICLI_TEST_SANDBOX XDG_DATA_HOME="$REAL/data" XDG_STATE_HOME="$REAL/state" \
    XDG_CACHE_HOME="$REAL/cache" XDG_CONFIG_HOME="$REAL/config" HOME="$REAL/home" NVIM_LOG_FILE="$OUTER_LOG" \
    timeout 20 nvim -u NONE --headless --cmd "set rtp+=$REPO_ROOT" -c "luafile $REPO_ROOT/tests/test-boards.lua" -c 'qa!' 2>&1)"
  rc=$?
  left="$(find "$REAL" -mindepth 2 2>/dev/null)"
  if [ $rc -ne 0 ] && [[ "$out" == *"refusing to run outside a sandbox"* ]] && [ -z "$left" ]; then
    pass "sandbox: test-boards.lua outside a sandbox refuses to run"
  else
    fail "sandbox: test-boards.lua outside a sandbox refuses to run" "rc $rc; written: ${left:-nothing}
$out"
  fi

  # tests/test-boards.lua: I (the Issues tab) only when --boards lists a
  # GitHub account with issues: - once on the demo config, once on it
  # trimmed to its Azure account. Each on its own fake workspace, wired up
  # the way tests/demo.sh does.
  for expect in issues azure; do
    ws="$TMP/boards-$expect"
    python3 "$REPO_ROOT/tests/fake-provider.py" setup "$ws" --fresh >/dev/null 2>&1
    printf 'vim.opt.rtp:prepend([[%s]])\nrequire("azure-cli").setup({})\n' "$REPO_ROOT" > "$ws/init.lua"
    mkdir -p "$ws/home"
    out="$(BOARDS_EXPECT=$expect AZVICLI_FAKE_WS="$ws" AZVICLI_TEST_SANDBOX="$ws" AZVICLI_PY="$REPO_ROOT/tests/fake-provider.py" \
      AZVICLI_EXE="$ws/azure-cli" XDG_CONFIG_HOME="$ws/config" XDG_DATA_HOME="$ws/data" HOME="$ws/home" \
      XDG_CACHE_HOME="$ws/cache" XDG_STATE_HOME="$ws/xdg-state" AZVICLI_TOASTS=0 \
      AZVICLI_CONFIG= AZVICLI_PROVIDER= AZVICLI_PREFETCH_DIR= \
      timeout 120 nvim --headless -u "$ws/init.lua" \
      -c "lua local ok, err = pcall(dofile, [[$REPO_ROOT/tests/test-boards.lua]]); if not ok then print('BOARDS-TEST-FAIL: ' .. tostring(err)) end; vim.cmd('qa!')" 2>&1)"
    if [[ "$out" == *BOARDS-TEST-OK* ]]; then
      pass "test-boards.lua ($expect): I only when a GitHub account has issues:"
    else
      fail "test-boards.lua ($expect): I only when a GitHub account has issues:" "$out"
    fi
  done

  # tests/test-poll.lua on the real screens (#93): the PR dashboard, both
  # boards, a review and the chat's watched PRs all poll through poll.lua.
  ws="$TMP/poll-surfaces"
  python3 "$REPO_ROOT/tests/fake-provider.py" setup "$ws" --fresh >/dev/null 2>&1
  printf 'vim.opt.rtp:prepend([[%s]])\nrequire("azure-cli").setup({})\n' "$REPO_ROOT" > "$ws/init.lua"
  mkdir -p "$ws/home"
  out="$(POLL_SURFACES=1 AZVICLI_FAKE_WS="$ws" AZVICLI_TEST_SANDBOX="$ws" AZVICLI_PY="$REPO_ROOT/tests/fake-provider.py" \
    AZVICLI_EXE="$ws/azure-cli" XDG_CONFIG_HOME="$ws/config" XDG_DATA_HOME="$ws/data" HOME="$ws/home" \
    XDG_CACHE_HOME="$ws/cache" XDG_STATE_HOME="$ws/xdg-state" AZVICLI_TOASTS=0 \
    AZVICLI_CONFIG= AZVICLI_PROVIDER= AZVICLI_PREFETCH_DIR= \
    timeout 120 nvim --headless -u "$ws/init.lua" \
    -c "lua local ok, err = pcall(dofile, [[$REPO_ROOT/tests/test-poll.lua]]); if not ok then print('POLL-TEST-FAIL: ' .. tostring(err)) end; vim.cmd('qa!')" 2>&1)"
  if [[ "$out" == *POLL-TEST-OK* ]]; then
    pass "test-poll.lua (surfaces): every network poll goes through poll.lua"
  else
    fail "test-poll.lua (surfaces): every network poll goes through poll.lua" "$out"
  fi

  # Fake-provider smoke: tests/demo.sh --headless builds a scratch workspace
  # (tests/fake-provider.py setup: two file:// git remotes, one clone, a
  # state.json of PRs/threads/work items), then runs tests/demo-smoke.lua
  # in a headless nvim wired up exactly like the interactive demo - the
  # fake as AZVICLI_PY, its --serve daemon, private XDG dirs - and asserts
  # the dashboard lists the fake PRs and the reviewer opens PR #101 with
  # its file list. The one check that goes through rpc.lua's real daemon
  # client, the real --list/--threads parsing, the warm-all prefetch's
  # `git fetch` and the reviewer's git diff pipeline together.
  #
  # It then drives the code-navigation surface on the same PR (gd into
  # throttle.py's is_locked at the PR's revision, <BS> back, gr's peek over
  # all three references) - the reviewer's least automated surface, and the
  # one whose helpers the other review/* modules reach through ctx.
  out="$(bash "$REPO_ROOT/tests/demo.sh" --headless --fresh --workspace "$TMP/demo-ws" 2>&1)"
  # One result per check of demo-smoke.lua's (see its header). A failed one
  # shows its own DEMO-SMOKE-FAIL[<marker>] lines and what it printed with
  # them, not the whole output again; one skipped because a check it builds
  # on failed is listed as skipped - that failure is reported once, there.
  smoke_check() {
    local desc="$1" m why="" skipped=""
    shift
    for m in "$@"; do
      [[ "$out" == *"$m-SMOKE-OK"* ]] && continue
      if [[ "$out" == *"SMOKE-SKIP[$m]"* ]]; then
        skipped="$(printf '%s\n' "$out" | grep -aF "SMOKE-SKIP[$m]" | head -1)"
      elif [[ "$out" == *"DEMO-SMOKE-FAIL[$m]"* ]]; then
        why+="$(printf '%s\n' "$out" | awk -v tag="DEMO-SMOKE-FAIL[$m]" '
          index($0, tag) { on = 1; n = 0 }
          on && !index($0, tag) && (/-SMOKE-OK/ || /SMOKE-SKIP\[/ || /DEMO-SMOKE-FAIL\[/) { on = 0 }
          on && n++ < 60')"$'\n'
      else
        why+="no result for $m: the smoke stopped before it (see the SMOKE-DONE check)"$'\n'
      fi
    done
    if [ -n "$why" ]; then
      fail "$desc" "$why"
    elif [ -n "$skipped" ]; then
      SKIPPED=$((SKIPPED + 1))
      printf 'SKIP  %s\n      %s\n' "$desc" "$skipped"
    else
      pass "$desc"
    fi
  }
  smoke_check "smoke: demo.sh --headless renders the fake dashboard, numbers its rows, <Space> folds a section" DEMO
  smoke_check "smoke: gd jumps to the definition at the PR's revision, <BS> walks back, gr peeks every reference" NAV
  smoke_check "smoke: gu lists my comments and gA filters them there like everywhere else" FOLLOWUP
  smoke_check "smoke: ]C / ]c on the file list land on the comment / change itself in the diff pane" LISTJUMP
  smoke_check "smoke: gR adds a reviewer found by name; <C-t> in the comment editor tags anyone as a real mention" PEOPLE
  smoke_check "smoke: an unfolded diff fold stays open across files, a reopen and a restart; a push drops it; zR/zM and toggle_fold" FOLDS
  smoke_check "smoke: a PR row shows its linked work item, PR #101 opens in the reviewer, and gW opens the item from the dashboard and the reviewer" PRWI REVIEW-WI
  smoke_check "smoke: gl/gL popups link and unlink from either dashboard, and both update at once" LINK
  smoke_check "smoke: I lists the GitHub project by iteration; open, gc, gs Done/Closed and n work on issues" ISSUES
  smoke_check "smoke: W and I never share #3001, and only I's calls carry AZVICLI_WI_HOST=github" BOARDS
  smoke_check "smoke: the agent's board tools on I (state, comment, sub-issue, start_story, Closes #n, link + undo), gW, gP" ISSUE-TOOLS
  smoke_check "smoke: chat streaming, selection/refs, /prompts, build log, show-me, notes, the fix flow, board tools + undo, gr, ga, gh" CHATPLUS
  smoke_check "smoke: no story without an approved plan; the plan's window, ga answers under a line (plan and change), gf edits, gA approves" PLAN
  smoke_check "smoke: gP on the board starts an agent per work item (queued past max_agents), each planning in its own conversation" AGENTS
  smoke_check "smoke: gQ shows each queued comment's place in the diff as you move, <Tab> goes there, gS sends them all at once" BATCHQ
  smoke_check "smoke: the chat panel sees the cursor's PR/file/thread, drafts, creates a branch, asks before voting" CHAT
  smoke_check "smoke: i on the PR dashboard, Issues and Agents types in the chat, keeping a draft" CHATI
  smoke_check "smoke: both dashboards number their rows relatively inside the box, following the cursor" ROWNUM
  smoke_check "smoke: progress counts, T shows children and grandchildren (remembered), za/zM/zR fold them" TREE
  smoke_check "smoke: the dashboard marks linked PRs and the item view lists them with title and status" PRS
  smoke_check "smoke: gs on a visual selection maps the other items onto the first one's state" SELECTION
  smoke_check "smoke: gs's popup maps a story's tasks by state category and sets only the checked ones" GS
  smoke_check "smoke: gU moves a work item under another parent (picked, then typed) and the tree regroups" PARENT
  smoke_check "smoke: ge opens a Task with its edit form; title, priority and hours are held, then saved with <C-s>" WIEDIT
  smoke_check "smoke: W's No sprint tab lists my open backlog/root items, and gi files one there" NOSPRINT
  smoke_check "smoke: two PRs open as inner tabs of Pull requests: one tab-line entry, the strip, ]r/[r/g2 keep each cursor, no twin, q goes back" INNERTABS
  smoke_check "smoke: two work items in W and two issues in I open as inner tabs: the strip, ]r/[r/g1..g3, no twin, q goes back, <CR> retitles, the chat sees each, gW's q returns to the review" INNERTABS-WI
  smoke_check "smoke: two plans open as inner tabs of Agents: the strip, ]r/[r/g1..g3, <CR> again keeps the older revision and the Changes file, a new revision reloads, q goes back, dd closes the open tab" INNERTABS-PLAN
  smoke_check "smoke: with 1, 3 and 4 plans open at 80 and 120 columns, the plan's status shows in full and the current plan stays identifiable" INNERTABS-FIT
  smoke_check "smoke: gr and the agent's requeue_build on a GitHub #7 re-run that PR's checks with its own env, never Azure's --requeue" GH_REQUEUE
  smoke_check "smoke: a GitHub account lists PR #7 from two repos, each in its own reviewer; the merge dialog and complete_pull_request keep to each repo's rules" GITHUB
  smoke_check "smoke: after a push (updatedIso unchanged), a deleted file is D with only deletions, and every row's counts match its diff" PUSHDIFF
  smoke_check "smoke: a push to an Azure PR (updatedIso unchanged) re-warms it on the next list load, keyed on its source commit" REWARM
  smoke_check "smoke: GitHub PRs are marked warm under their key at their head commit, never under their number" REWARM-GH
  smoke_check "smoke: a dashboard warm callback queued while the reviewer fetches runs once, with the fetch's success" REWARM-REVIEW
  # Every check above got its own result only if the script ran to its end:
  # a crash, a hang (demo.sh's timeout) or a Lua error outside a check
  # stops it short, and shows here with the end of the output.
  if [[ "$out" == *SMOKE-DONE* ]]; then
    pass "smoke: demo-smoke.lua ran to its end"
  else
    fail "smoke: demo-smoke.lua ran to its end" "$(printf '%s\n' "$out" | tail -40)"
  fi
else
  echo "(nvim not on PATH - smokes skipped; CI installs neovim so they run there)"
fi

echo
echo "== summary =="
echo "passed: $PASS  failed: $FAIL  skipped: $SKIPPED"
if [ "$FAIL" -gt 0 ]; then
  echo "failing checks:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
