#!/usr/bin/env bash
# tests/run.sh - azure-vicli test runner.
#
# Requires: bash, git, luajit, python3. There is no compiled data provider
# any more (azure-cli.py is run directly by python), so nothing here needs
# a build step first.
#
# What it checks, in order:
#   1. luajit -bl syntax check on every Lua UI file, plus (when nvim is on
#      PATH) loading every file with a real Neovim, which is stricter.
#   2. A global-name scan on every Lua UI file: any name luajit resolves as
#      a global that isn't a known Lua/vim builtin means some *other* name
#      is being read before its `local` declaration further down the file
#      (shadowing what looks like a builtin, or just a typo) - a real bug
#      class in this codebase's style of long files with forward references.
#   3. bash -n on every shell script.
#   4. The twenty-one Lua unit tests below it in this directory, against a
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
# lua/azure-cli/init.lua) and `_G` (unused by anything under lua/ any more,
# kept allowed as harmless back-compat in case a future file still wants a
# process-wide value require()'s module caching doesn't fit).
# setmetatable is review/comments.lua's (and, the same way, review/commits.lua's
# and review/range.lua's) own: each module table doubles as a plain table of
# pure helpers (for its tests/test-review-*.lua) and a callable
# `require(path)(ctx)` (for review/init.lua's EXT wiring) via a __call
# metamethod.
ALLOWED_GLOBALS=(_G debug dofile error ipairs math os pairs pcall require select setmetatable string table tonumber tostring type vim)

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
NOTIFY_LUA="$TMP/lua/lua/azure-cli/notify.lua"
RPC_LUA="$TMP/lua/lua/azure-cli/rpc.lua"
EDITOR_LUA="$TMP/lua/lua/azure-cli/editor.lua"
LOG_LUA="$TMP/lua/lua/azure-cli/log.lua"
COMMENTS_LUA="$TMP/lua/lua/azure-cli/review/comments.lua"
COMMITS_LUA="$TMP/lua/lua/azure-cli/review/commits.lua"
RANGE_LUA="$TMP/lua/lua/azure-cli/review/range.lua"
BATCH_LUA="$TMP/lua/lua/azure-cli/review/batch.lua"
SINCE_LUA="$TMP/lua/lua/azure-cli/review/since.lua"
FOLLOWUP_LUA="$TMP/lua/lua/azure-cli/review/followup.lua"
CONFIG_LUA="$TMP/lua/lua/azure-cli/config.lua"
KEYS_LUA="$TMP/lua/lua/azure-cli/keys.lua"
UI_LUA="$TMP/lua/lua/azure-cli/ui.lua"
PROMPT_LUA="$TMP/lua/lua/azure-cli/prompt.lua"
PRS_LUA="$TMP/lua/lua/azure-cli/prs.lua"
MERGE_LUA="$TMP/lua/lua/azure-cli/merge.lua"
PANE_LUA="$TMP/lua/lua/azure-cli/review/pane.lua"
VIEWED_LUA="$TMP/lua/lua/azure-cli/review/viewed.lua"
FILELIST_LUA="$TMP/lua/lua/azure-cli/review/filelist.lua"
MIGRATE_LUA="$TMP/lua/lua/azure-cli/migrate.lua"
STATES_LUA="$TMP/lua/lua/azure-cli/workitems/states.lua"

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
run_lua_test test-nav.lua "$REPO_ROOT" "$REVIEW_LUA"
run_lua_test test-decorate.lua "$REPO_ROOT" "$CACHE_LUA" "$REVIEW_LUA" "$SCRATCH"
run_lua_test test-worddiff.lua "$REPO_ROOT" "$CACHE_LUA"
run_lua_test test-notify.lua "$REPO_ROOT" "$NOTIFY_LUA"
run_lua_test test-rpc.lua "$REPO_ROOT" "$RPC_LUA"
run_lua_test test-editor.lua "$REPO_ROOT" "$EDITOR_LUA"
run_lua_test test-log.lua "$REPO_ROOT" "$LOG_LUA"
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
run_lua_test test-prompt.lua "$REPO_ROOT" "$PROMPT_LUA"
run_lua_test test-prs.lua "$REPO_ROOT" "$PRS_LUA"
run_lua_test test-merge.lua "$REPO_ROOT" "$MERGE_LUA"
run_lua_test test-review-pane.lua "$REPO_ROOT" "$PANE_LUA"
run_lua_test test-review-viewed.lua "$REPO_ROOT" "$VIEWED_LUA"
run_lua_test test-review-filelist.lua "$REPO_ROOT" "$FILELIST_LUA"

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

  # Fake-provider smoke: tests/demo.sh --headless builds a scratch workspace
  # (tests/fake-provider.py setup: two file:// git remotes, one clone, a
  # state.json of PRs/threads/work items), then runs tests/demo-smoke.lua
  # in a headless nvim wired up exactly like the interactive demo - the
  # fake as AZVICLI_PY, its --serve daemon, private XDG dirs - and asserts
  # the dashboard lists the fake PRs and the reviewer opens PR #101 with
  # its file list. The one check that goes through rpc.lua's real daemon
  # client, the real --list/--threads parsing, the warm-all prefetch's
  # `git fetch` and the reviewer's git diff pipeline together.
  out="$(bash "$REPO_ROOT/tests/demo.sh" --headless --fresh --workspace "$TMP/demo-ws" 2>&1)"
  if [[ "$out" == *DEMO-SMOKE-OK* ]]; then
    pass "smoke: demo.sh --headless renders the fake dashboard and opens PR #101 in the reviewer"
  else
    fail "smoke: demo.sh --headless renders the fake dashboard and opens PR #101 in the reviewer" "$out"
  fi
else
  echo "(nvim not on PATH - smokes skipped; CI installs neovim so they run there)"
fi

echo
echo "== summary =="
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "failing checks:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
