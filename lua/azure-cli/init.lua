-- lua/azure-cli/init.lua: the plugin's entry point - setup() plus the
-- functions plugin/azure-cli.lua's :AzureCli command and the standalone
-- launcher (standalone/init.lua) both call into.
--
-- Every surface below is its own require()'d module exposing M.open(...):
-- unlike the old dofile()/`:luafile` scripts, requiring a module only
-- compiles it once (cached by Lua's `require`), so each M.open() call is
-- what actually (re)builds that surface's buffer/window/keymaps - the same
-- "reset on every entry" behaviour a `:luafile` re-source used to give for
-- free. See lua/azure-cli/state.lua for what's shared across calls instead
-- (the list/content caches, the daemon client, ...).
local M = {}

-- True once standalone/init.lua has opened this session (vs. a normal
-- plugin-manager install, :AzureCli run by hand). Read by dashboard.lua's
-- quit key: standalone quits Neovim entirely (today's behaviour, `qa!`),
-- plugin mode just closes the dashboard's own tab.
M._standalone = false

function M.is_standalone()
  return M._standalone
end

function M.set_standalone(v)
  M._standalone = v and true or false
end

-- setup(opts): optional - every surface applies config.lua's defaults
-- untouched when this is never called, so `:AzureCli dashboard` with no
-- setup() works out of the box.
function M.setup(opts)
  return require("azure-cli.config").setup(opts)
end

-- Opens the PR dashboard: a new tab in plugin mode, the current window in
-- standalone mode (matching the pre-plugin launcher exactly).
function M.open_dashboard()
  local UI = require("azure-cli.ui")
  if UI.goto_tab(function(b) return vim.bo[b].filetype == "azurecli-dashboard" end) then return end
  -- No config file yet (first run): firstrun.lua writes the template, opens
  -- it instead, and calls back here once it's saved.
  if not require("azure-cli.firstrun").ensure(M.open_dashboard) then return end
  if not M._standalone then
    vim.cmd("tabnew")
  end
  require("azure-cli.dashboard").open()
end

-- Opens the work-items dashboard the same way (see open_dashboard above);
-- also what the PR dashboard's own "workitems" key swaps into in-place.
function M.open_workitems()
  local UI = require("azure-cli.ui")
  if UI.goto_tab(function(b) return vim.bo[b].filetype == "azurecli-workitems" end) then return end
  if not require("azure-cli.firstrun").ensure(M.open_workitems) then return end
  if not M._standalone then
    vim.cmd("tabnew")
  end
  require("azure-cli.workitems.dashboard").open()
end

-- Opens the reviewer for PR `id` directly (:AzureCli review <id>), always in
-- a new tab - same as pressing <CR> on a dashboard row. Needs the PR's
-- org/project/source/target/repo, which only the dashboard's list fetch
-- knows; this looks it up in the shared list cache (lua/azure-cli/state.lua)
-- rather than re-implementing that fetch, so it only works for a PR the
-- dashboard has already listed this session.
function M.open_review(id)
  id = tostring(id)
  local state = require("azure-cli.state")
  local cache = state.PR_LIST_CACHE
  local pr
  if cache and cache.prs then
    for _, p in ipairs(cache.prs) do
      if tostring(p.id) == id then pr = p; break end
    end
  end
  if not pr then
    vim.notify(
      "azure-cli: PR #" .. id .. " isn't in the cached list yet - open :AzureCli dashboard first.",
      vim.log.levels.ERROR
    )
    return
  end
  require("azure-cli.dashboard").open_pr_by_record(pr)
end

-- :AzureCli toasts - toggles desktop notifications for the rest of this
-- session, the same effective switch the dashboard's own toasts key flips.
function M.toggle_toasts()
  local on = require("azure-cli.notify").toggle()
  vim.notify("Desktop notifications " .. (on and "enabled" or "disabled") .. " for this session.")
end

-- :AzureCli status - the provider daemon's status (see rpc.lua's
-- header comment / README's troubleshooting section), plus the python
-- interpreter and config file path every provider call currently resolves
-- to (config.lua's provider_cmd()/config_path() - see setup()'s `python`/
-- `config` options), so a python/config mismatch is visible without going
-- digging through setup() calls or AZVICLI_* env vars by hand.
function M.status()
  local st = require("azure-cli.rpc").status()
  local config = require("azure-cli.config")
  local cmd = config.provider_cmd()
  st.python = cmd[1]
  local n = config.accounts_from_setup()
  st.config = n and ("setup({accounts=...}) - " .. n .. " account(s)") or config.config_path()
  vim.notify(string.format(
    "azure-cli: daemon running=%s fallback=%s pid=%s\npython=%s\nconfig=%s",
    tostring(st.running), tostring(st.fallback), tostring(st.pid), st.python, st.config
  ))
  return st
end

return M
