-- lua/azure-cli/shell.lua: the small housekeeping helpers every surface
-- needs and each one used to carry its own copy of - flashing a message,
-- opening azure-cli.yml, opening a URL in the browser, yanking one,
-- summarising a failed provider job, and reading/writing the little JSON
-- state files under stdpath("data").
--
-- These were duplicated five ways (notify), three ways (config_path /
-- open_config_file / the browser open) and four ways (the JSON load/save
-- pair) across dashboard.lua, workitems/dashboard.lua, workitems/view.lua,
-- review/init.lua, review/viewed.lua and prompt.lua. The copies had drifted:
-- two of the four browser opens detached the fallback job and two didn't,
-- one yank flashed through notify.lua and another through vim.notify, and
-- only one of the three provider-write error paths recorded anything in the
-- session log. Sharing them is what makes those answers the same everywhere.
--
-- Everything here reaches its collaborators through a plain require() inside
-- the function body rather than a module-level local, so review/init.lua can
-- call in without spending one of the few top-level local slots it has left
-- (see that file's own header and README's "Extending the reviewer").
local M = {}

-- The plugin's one "say something to the user" path: notify.lua's flash,
-- defaulting to INFO. Every surface had this exact three-liner.
function M.notify(msg, level)
  require("azure-cli.notify").flash(msg, level or vim.log.levels.INFO)
end

-- Resolve azure-cli.yml's path - delegates to config.lua's M.config_path()
-- (AZVICLI_CONFIG override, else the platform default) so gO always opens
-- exactly what the provider itself would read.
function M.config_path()
  return require("azure-cli.config").config_path()
end

-- Open azure-cli.yml (accounts/PAT/clones_dir config) in a new tab for quick
-- editing, so you don't have to go dig it up manually to add an account or
-- tweak hide_ancient/clones_dir. Explains itself instead when the accounts
-- come from setup({accounts=...}) and the file isn't what's being read.
function M.open_config_file()
  local notice = require("azure-cli.config").setup_accounts_notice()
  if notice then
    M.notify(notice)
    return
  end
  local path = M.config_path()
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "yaml"
  if vim.fn.filereadable(path) == 0 then
    M.notify("azure-cli.yml doesn't exist yet — save this buffer (:w) to create it at " .. path,
      vim.log.levels.WARN)
  end
end

-- Open `url` in the default browser. Returns true when something was
-- launched, or false plus a reason.
--
-- vim.ui.open does NOT raise when it can't open the URL - it returns
-- `nil, "<reason>"` (runtime/lua/vim/ui.lua: "no handler found (tried:
-- wslview, explorer.exe, xdg-open, lemonade)"). Every call site here used
-- to test only pcall's own ok flag, which is true on exactly that failure,
-- so the Windows fallback below could never actually run. Both returns are
-- checked now. The fallback is Windows-only: spawning `cmd` anywhere else
-- just fails silently and buries the real reason. It detaches, so the
-- spawned shell isn't tied to this Neovim's lifetime (two of the four old
-- copies passed detach and two didn't).
function M.open_url(url)
  if not url or url == "" then return false, "no URL" end
  local ok, ret, err = pcall(vim.ui.open, url)
  if not ok then err = ret end          -- vim.ui.open itself raised
  if ok and not err then return true end
  if vim.fn.has("win32") == 1 then
    vim.fn.jobstart({ "cmd", "/c", "start", "", url }, { detach = true })
    return true
  end
  return false, tostring(err or "could not open a browser")
end

-- Copy `url` to both the unnamed and (when there is one) the system
-- clipboard. Returns true when there was anything to copy.
function M.yank_url(url)
  if not url or url == "" then return false end
  vim.fn.setreg('"', url)
  pcall(vim.fn.setreg, "+", url)
  return true
end

-- The one-line message to show for a provider job that exited non-zero.
-- The full raw text (often a multi-line python traceback) goes to the
-- session log and only LOG.summary's one line is returned, with a pointer
-- back to the rest - see log.lua's header comment and README's
-- Troubleshooting. `lines` is the collected stdout/stderr, `source` the
-- label the log entry is filed under ("PR #123", "Work item #456").
--
-- The reviewer's run_write already did this; the two dashboards' own write
-- helpers instead flattened the same text into a single notify() line,
-- which turned a traceback into one unreadable toast and left nothing in
-- :AzureCli log. All three share this now.
function M.job_error(source, code, lines)
  local raw = table.concat(vim.tbl_filter(function(s) return s ~= "" end, lines or {}), "\n")
  local msg = "exit " .. tostring(code)
  if raw ~= "" then
    local LOG = require("azure-cli.log")
    LOG.record(source, raw)
    msg = msg .. ": " .. LOG.summary(raw, vim.o.columns) .. "  (:AzureCli log)"
  end
  return msg
end

-- Read `path` as a JSON object, returning `default` whenever anything at
-- all is wrong with it (missing, unreadable, not JSON, not a table, or
-- rejected by opts.validate) - these are best-effort UI state files, and a
-- corrupt one should cost you your "seen" marks, never a stack trace.
--
--   opts.migrate_from  a pre-rename path to copy in first (migrate.lua)
--   opts.validate      extra predicate on the decoded table
--
-- Guarded on `vim.fn` so a test harness without a real Neovim (see
-- review/viewed.lua's injectable store) just gets the default back.
function M.read_json(path, default, opts)
  opts = opts or {}
  if opts.migrate_from then
    require("azure-cli.migrate").ensure(opts.migrate_from, path)
  end
  if not (vim and vim.fn) or vim.fn.filereadable(path) ~= 1 then return default end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return default end
  local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not (ok2 and type(decoded) == "table") then return default end
  if opts.validate and not opts.validate(decoded) then return default end
  return decoded
end

-- Write `value` to `path` as one line of JSON. Silent on failure, for the
-- same reason read_json is forgiving: losing a "seen" mark is not worth an
-- error in the middle of a keystroke.
function M.write_json(path, value)
  if not (vim and vim.fn) then return end
  pcall(vim.fn.writefile, { vim.json.encode(value) }, path)
end

return M
