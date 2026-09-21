#!/usr/bin/env bash
# tests/demo.sh - run the azure-vicli Neovim UI against tests/fake-provider.py
# (no Azure DevOps, no PAT, no network), for trying the dashboard, the
# reviewer and the work-item screens by hand, or as a headless self-check.
#
#   bash tests/demo.sh                # plugin mode: nvim -u <ws>/init.lua, :AzureCli dashboard
#   bash tests/demo.sh --standalone   # the launcher's own entry point, standalone/init.lua
#   bash tests/demo.sh --headless     # no UI: dashboard + reviewer on PR #101, assert they rendered, exit
#   bash tests/demo.sh --no-daemon    # AZVICLI_NO_DAEMON=1: one fake process per call instead of --serve
#   bash tests/demo.sh --fresh        # rebuild the workspace (forgets comments/votes you made)
#   bash tests/demo.sh --workspace D  # use D instead of the default workspace directory
#
# The workspace (default: $TMPDIR-or-/tmp/azure-vicli-demo-$USER) holds the
# fake's git repositories, its state.json, calls.log, and private XDG
# config/data/cache directories, so nothing here touches your real
# azure-cli.yml or the plugin's real viewed-marks/cache files. It is kept
# between runs: comments, votes and work-item edits you make persist until
# --fresh. Every provider call the Lua side made is in <ws>/calls.log.
#
# Plugin mode is the closest thing to a plugin-manager install: <ws>/init.lua
# prepends the repo root to 'runtimepath' the way lazy.nvim/packer would,
# so plugin/azure-cli.lua is sourced normally and :AzureCli is defined by
# it, not by hand. Requires nvim, git and python3 on PATH.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=plugin
FRESH=0
WS="${TMPDIR:-/tmp}/azure-vicli-demo-${USER:-user}"

while [ $# -gt 0 ]; do
  case "$1" in
    --standalone) MODE=standalone ;;
    --headless) MODE=headless ;;
    --no-daemon) export AZVICLI_NO_DAEMON=1 ;;
    --fresh) FRESH=1 ;;
    --workspace) shift; WS="${1:?--workspace needs a directory}" ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "demo.sh: unknown option $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

for tool in nvim git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "demo.sh: $tool is not on PATH" >&2
    exit 1
  fi
done

if [ "$FRESH" = 1 ]; then
  python3 "$ROOT/tests/fake-provider.py" setup "$WS" --fresh || exit 1
else
  python3 "$ROOT/tests/fake-provider.py" setup "$WS" || exit 1
fi

# Everything the plugin resolves at load time: the fake as the "python"
# (config.lua's provider_cmd(); env wins over setup({python=...})), the
# fake's launcher wrapper as AZVICLI_EXE (the reviewer's --whoami call),
# and private XDG dirs so the real config/viewed marks/cache stay untouched.
export AZVICLI_FAKE_WS="$WS"
export AZVICLI_PY="$ROOT/tests/fake-provider.py"
export AZVICLI_EXE="$WS/azure-cli"
export XDG_CONFIG_HOME="$WS/config"
export XDG_DATA_HOME="$WS/data"
export XDG_CACHE_HOME="$WS/cache"
export XDG_STATE_HOME="$WS/xdg-state"
export AZVICLI_TOASTS="${AZVICLI_TOASTS:-0}"   # no desktop notifications from a demo
unset AZVICLI_CONFIG AZVICLI_PROVIDER AZVICLI_PREFETCH_DIR

cat > "$WS/init.lua" <<EOF
-- Written by tests/demo.sh: what a plugin manager's install boils down to.
vim.opt.rtp:prepend([[$ROOT]])
vim.o.termguicolors = true
vim.o.mouse = "a"
pcall(vim.cmd, "colorscheme habamax")
require("azure-cli").setup({})
EOF

case "$MODE" in
  plugin)
    echo "demo.sh: workspace $WS (calls.log there); plugin mode, :AzureCli dashboard"
    exec nvim -u "$WS/init.lua" -c "AzureCli dashboard"
    ;;
  standalone)
    echo "demo.sh: workspace $WS (calls.log there); standalone/init.lua"
    exec nvim -u "$ROOT/standalone/init.lua"
    ;;
  headless)
    # tests/demo-smoke.lua: dashboard rows through the daemon, then the
    # reviewer on PR #101 - see that file's header comment.
    out="$(nvim --headless -u "$WS/init.lua" -c "luafile $ROOT/tests/demo-smoke.lua" 2>&1)"
    printf '%s\n' "$out"
    case "$out" in
      *DEMO-SMOKE-OK*) exit 0 ;;
      *) echo "demo.sh: headless smoke failed (see $WS/calls.log)" >&2; exit 1 ;;
    esac
    ;;
esac
