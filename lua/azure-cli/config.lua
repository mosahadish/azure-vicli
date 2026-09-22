-- lua/azure-cli/config.lua: setup() options, defaults and the resolved
-- config every other module reads through M.get().
--
-- `keys` is the whole point of this file: one action name per binding site
-- across every surface (dashboard/list/diff/overview/nav/workitems/
-- workitem_view), each mapped to today's actual key(s) so a plugin-mode
-- install behaves exactly like the standalone launcher out of the box.
-- lua/azure-cli/keys.lua resolves a surface+action pair through this table
-- (plus keys.prefix) at every `keys.bind` call site instead of a UI file
-- ever hard-coding a key string itself; a value of `false` unbinds that
-- action entirely, a list of strings binds several keys to the same action
-- (e.g. the work-items dashboard's next_sprint responding to both "]" and
-- "<Tab>", exactly as it always has).
local M = {}

local DEFAULT_KEYS = {
  dashboard = {
    open = "<CR>", description = "gd", copy_link = "gy", browser = "o",
    filter = "/", vote = "gv", complete = "gm", auto_complete = "ga",
    requeue_build = "gr", open_build = "gb", config = "gO", refresh = "r",
    workitems = "W", toasts = "gN", help = "?", quit = "q",
    toggle_section = "za", expand_all = "zR", collapse_all = "zM",
    first_pr = "gg", last_pr = "G",
  },
  -- Reviewer file list.
  list = {
    open = "<CR>", back = "<BS>", quit = "q", pr_comment = "gC",
    search = "g/", active_filter = "gA", filters = "gF", ignore_ws = "gw",
    config = "gO", vote = "gv", complete = "gm",
    next_file_with_comments = "]C", prev_file_with_comments = "[C",
    resize_less = "<", resize_more = ">", comment_file = "C", help = "?",
    commits = "gc", batch_toggle = "gB", batch_queue = "gQ", batch_submit = "gS",
    since = "gi", followup = "gu",
    toggle_viewed = "m", next_unviewed = "]m", prev_unviewed = "[m",
  },
  -- Reviewer diff pane.
  diff = {
    -- comment_file is a single key on purpose: `c` is bound with nowait,
    -- so a two-key `cf` could never complete in the diff pane.
    comment = "c", comment_range = "c", comment_file = "C",
    next_hunk = "]c", prev_hunk = "[c", view_comments = "K", reply = "R",
    status = "s", vote = "gv", complete = "gm", next_comment = "]C",
    prev_comment = "[C", active_filter = "gA", filters = "gF",
    ignore_ws = "gw", config = "gO", goto_definition = "gd",
    find_references = "gr", open_file = "gf", search = "g/",
    resize_less = "<", resize_more = ">", back = "<BS>", help = "?",
    quit = "q", commits = "gc", batch_toggle = "gB", batch_queue = "gQ",
    batch_submit = "gS", since = "gi", followup = "gu",
    expand_thread = "<Tab>", toggle_viewed = "m", next_unviewed = "]m", prev_unviewed = "[m",
  },
  -- Reviewer Overview page.
  overview = {
    comment = "c", reply = "R", status = "s", next_comment = "]C",
    prev_comment = "[C", search = "g/", vote = "gv", complete = "gm",
    active_filter = "gA", filters = "gF", ignore_ws = "gw", config = "gO",
    resize_less = "<", resize_more = ">", back = "<BS>", help = "?",
    quit = "q", edit_comment = "e", delete_comment = "dd",
    open_commit = "<CR>", batch_toggle = "gB", batch_queue = "gQ",
    batch_submit = "gS", since = "gi", followup = "gu",
  },
  -- Code-navigation peek/revision buffers.
  nav = {
    goto_definition = "gd", find_references = "gr", search = "g/",
    back = "<BS>", back_to_diff = "q", config = "gO", resize_less = "<",
    resize_more = ">", help = "?",
  },
  -- Work-items dashboard.
  workitems = {
    open = "<CR>", state = "gs", new = "n", assign = "ga", priority = "gp",
    edit_title = "ge", move_sprint = "gi", link_pr = "gl", browser = "o",
    refresh = "r", next_sprint = { "]", "<Tab>" }, prev_sprint = { "[", "<S-Tab>" },
    goto_sprint_n = "gt", click = "<LeftMouse>", pr_list = "P",
    copy_link = "gy", config = "gO", help = "?", quit = "q",
    filter = "/", unlink_pr = "gL",
  },
  -- Work-item detail view.
  workitem_view = {
    open = "<CR>", state = "gs", assign = "ga", priority = "gp",
    edit_title = "ge", move_sprint = "gi", comment = "gc", link_pr = "gl",
    unlink_pr = "gL", browser = "o", copy_link = "gy", refresh = "r",
    back = "<BS>", quit = "q", help = "?",
  },
}

-- setup({timing=...}) tunables - each replaces one hard-coded constant a UI
-- file used to own outright:
--   poll_seconds        dashboard.lua's PR list poll, review/init.lua's
--                        reviewer threads/new-push poll, and
--                        workitems/dashboard.lua's list poll (each was a
--                        bare 60000ms timer; one knob for all three since
--                        they're the same "how often does this session
--                        re-check ADO" idea)
--   hover_ms             workitems/dashboard.lua's cursor-settle debounce
--                        before prefetching the item under the cursor
--   warm_concurrency     dashboard.lua's WARM_CONCURRENCY (warm-all pass)
--   cached_prs           cache.lua's M.MAX_PRS
--   threads_ttl_seconds  cache.lua's M.THREADS_TTL
--   aged_days            dashboard.lua's "aged" (AzureCliAged) threshold
-- cached_prs/threads_ttl_seconds are applied to cache.lua directly inside
-- M.setup() below (not read live from M.get() at use time, unlike the
-- others - cache.lua's own M.MAX_PRS/M.THREADS_TTL fields are what every
-- read site there already uses); everything else is read live through
-- M.get().timing at the point it's used, so a setup() call after a surface
-- has already opened still takes effect on its next read.
local DEFAULT_TIMING = {
  poll_seconds = 30,
  hover_ms = 500,
  warm_concurrency = 4,
  cached_prs = 24,
  threads_ttl_seconds = 120,
  aged_days = 14,
}

-- setup({hide_ancient_days=...}) - exported to the provider as
-- AZVICLI_HIDE_ANCIENT_DAYS (see provider_cmd() below); azure-cli.py's
-- _compute_state reads it instead of a hard-coded 30 for an account's
-- hide_ancient: check.
local DEFAULT_HIDE_ANCIENT_DAYS = 30

-- setup({notifications=...}) - "float" (default) routes transient status
-- text (see lua/azure-cli/notify.lua's M.flash) through a small
-- non-focusable floating window stack in the bottom-right corner instead of
-- vim.notify/the command line; "notify" makes M.flash a plain vim.notify
-- pass-through instead, for a setup where vim.notify is already replaced by
-- a UI plugin (e.g. nvim-notify) that should see this plugin's status
-- messages too. Errors always also go through vim.notify at ERROR level
-- either way (see notify.lua's own header comment), so :messages never
-- loses one regardless of this setting.
local DEFAULT_NOTIFICATIONS = "float"

-- setup({collapsed_sections=...}) - the PR dashboard section keys ("Mentions",
-- "Actionable", "Waiting", "SignedOff", "Drafts", "Created") that start
-- collapsed for the session; `za` (dashboard.lua's toggle_section) toggles
-- one, `zR`/`zM` expand/collapse every section. Only seeds the very first
-- render of the session (dashboard.lua stashes the live set in
-- STATE.dashboard_collapsed, same as its warm/prefetch bookkeeping, so a W/P
-- swap back to the dashboard keeps whatever the user toggled instead of
-- resetting to this default every time).
local DEFAULT_COLLAPSED_SECTIONS = { "SignedOff", "Drafts" }

local DEFAULTS = {
  keys = DEFAULT_KEYS, timing = DEFAULT_TIMING, hide_ancient_days = DEFAULT_HIDE_ANCIENT_DAYS,
  notifications = DEFAULT_NOTIFICATIONS, collapsed_sections = DEFAULT_COLLAPSED_SECTIONS,
}

local resolved = nil  -- set by M.setup(); M.get() falls back to DEFAULTS until then

-- This file's own directory is lua/azure-cli/ - two directories up is the
-- plugin root, whether that's this repo's own root (the common case, since
-- the plugin currently lives at the repo root) or wherever a plugin manager
-- cloned it. standalone/init.lua prepends this same root to 'rtp'; a
-- plugin-manager install already has it on 'rtp' by the time require() runs.
function M.plugin_root()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(path, ":p:h:h:h")
end

-- The data-provider argv (python + azure-cli.py) every PR/work-item action
-- and prefetch job runs, replacing each UI file's own copy of this
-- resolution. Python precedence: env AZVICLI_PY (an ambient override the
-- shell/launcher already set before Neovim started) first, then
-- setup({python=...}), then probing python3/python on PATH.
--
-- Also where the AZVICLI_PREFETCH_DIR every provider call should see gets
-- set, once, the first time any surface asks for an argv to run - every
-- surface calls this before its first provider job, and a job's spawned
-- environment inherits vim.env (jobstart's own `env` option only adds to
-- that, never replaces it - see rpc.lua), so setting it here covers every
-- provider invocation this session makes, including the --serve daemon's
-- own spawn, without each call site threading it through explicitly. Left
-- alone when already set (an ambient override from the shell the launcher
-- ran in, or a previous call already having resolved it) - never stomps a
-- real value with the default.
function M.provider_cmd()
  local env = vim.env
  local py = env.AZVICLI_PY
  if not py or py == "" then
    py = M.get().python
    if not py or py == "" then
      py = vim.fn.executable("python3") == 1 and "python3" or "python"
    end
  end
  local path = env.AZVICLI_PROVIDER
  if not path or path == "" then
    path = M.plugin_root() .. "/azure-cli.py"
  end
  if not env.AZVICLI_PREFETCH_DIR or env.AZVICLI_PREFETCH_DIR == "" then
    env.AZVICLI_PREFETCH_DIR = vim.fn.stdpath("cache") .. "/azure-cli"
  end
  if not env.AZVICLI_HIDE_ANCIENT_DAYS or env.AZVICLI_HIDE_ANCIENT_DAYS == "" then
    env.AZVICLI_HIDE_ANCIENT_DAYS = tostring(M.get().hide_ancient_days)
  end
  return { py, path }
end

-- setup({accounts=...}): the plugin-mode alternative to azure-cli.yml.
-- Validated field by field (same names as the YAML file, minus `pat`: an
-- init.lua lives in a dotfiles repo, so the token can only come from
-- `pat_file`, and an inline `pat` is refused outright rather than exported
-- into every provider process's environment), then exported as JSON in
-- AZVICLI_ACCOUNTS_JSON for the provider (Config.from_json in
-- azure-cli.py), which prefers it over the file outright. Returns the
-- validated list.
local ACCOUNT_FIELDS = {
  project_name = "string", org_url = "string", pat_file = "string",
  hide_ancient = "boolean", clones_dir = "string", work_items = "table",
}
local WORK_ITEM_FIELDS = {
  team = "string", assignee = "string", types = "list", states = "list", sprint_scope = "string",
}

local function check_fields(tbl, allowed, where)
  for k, v in pairs(tbl) do
    local want = allowed[k]
    if not want then
      error("azure-cli.setup: unknown field `" .. tostring(k) .. "` in " .. where)
    end
    if want == "list" then
      if type(v) ~= "string" and type(v) ~= "table" then
        error("azure-cli.setup: `" .. k .. "` in " .. where .. " must be a string or a list of strings")
      end
      if type(v) == "table" then
        for _, item in ipairs(v) do
          if type(item) ~= "string" then
            error("azure-cli.setup: `" .. k .. "` in " .. where .. " must be a list of strings")
          end
        end
      end
    elseif type(v) ~= want then
      error("azure-cli.setup: `" .. k .. "` in " .. where .. " must be a " .. want)
    end
  end
end

local function validate_accounts(accounts)
  if type(accounts) ~= "table" then
    error("azure-cli.setup: `accounts` must be a list of account tables")
  end
  if #accounts == 0 then
    error("azure-cli.setup: `accounts` is empty - add one with project_name, org_url and pat_file")
  end
  for i, a in ipairs(accounts) do
    local where = "accounts[" .. i .. "]"
    if type(a) ~= "table" then
      error("azure-cli.setup: " .. where .. " must be a table")
    end
    if a.pat ~= nil then
      error("azure-cli.setup: " .. where .. ".pat isn't accepted - setup() lives in your Neovim config, "
        .. "so the token goes in a file of its own: pat_file = \"~/.config/azure-cli/pat\"")
    end
    check_fields(a, ACCOUNT_FIELDS, where)
    for _, req in ipairs({ "project_name", "org_url" }) do
      if type(a[req]) ~= "string" or a[req] == "" then
        error("azure-cli.setup: " .. where .. " needs a non-empty `" .. req .. "`")
      end
    end
    if not a.org_url:match("^[Hh][Tt][Tt][Pp][Ss]?://") then
      error("azure-cli.setup: " .. where .. ".org_url must start with https:// (got " .. a.org_url .. ")")
    end
    if type(a.pat_file) ~= "string" or a.pat_file == "" then
      error("azure-cli.setup: " .. where .. " needs a non-empty `pat_file` (a file holding just the token)")
    end
    if a.work_items ~= nil then
      check_fields(a.work_items, WORK_ITEM_FIELDS, where .. ".work_items")
      if type(a.work_items.team) ~= "string" or a.work_items.team == "" then
        error("azure-cli.setup: " .. where .. ".work_items needs a non-empty `team`")
      end
      local scope = a.work_items.sprint_scope
      if scope ~= nil and scope ~= "parent" and scope ~= "all" then
        error("azure-cli.setup: " .. where .. ".work_items.sprint_scope must be \"parent\" or \"all\"")
      end
    end
  end
  return accounts
end

-- Merges `overrides` onto a deep copy of `base`, action by action, erroring
-- on any surface/action name overrides doesn't recognise - see M.setup.
local function merge_keys(base, overrides)
  local merged = vim.deepcopy(base)
  if overrides == nil then return merged end
  if type(overrides) ~= "table" then
    error("azure-cli.setup: `keys` must be a table")
  end
  for surface, actions in pairs(overrides) do
    if surface == "prefix" then
      if type(actions) ~= "table" then
        error("azure-cli.setup: `keys.prefix` must be a table of surface -> prefix string")
      end
      merged.prefix = vim.deepcopy(actions)
    else
      if merged[surface] == nil then
        error("azure-cli.setup: unknown key surface '" .. tostring(surface) .. "'")
      end
      if type(actions) ~= "table" then
        error("azure-cli.setup: `keys." .. tostring(surface) .. "` must be a table of action -> key")
      end
      for action, keyspec in pairs(actions) do
        if merged[surface][action] == nil then
          error("azure-cli.setup: unknown key action '" .. surface .. "." .. tostring(action) .. "'")
        end
        merged[surface][action] = keyspec
      end
    end
  end
  return merged
end

-- Merges `overrides` onto a deep copy of `base` (DEFAULT_TIMING), field by
-- field, requiring every given value be a positive number and erroring on
-- an unknown field name - same shape of validation merge_keys does for
-- `keys`, one flat table instead of one per surface.
local function merge_timing(base, overrides)
  local merged = vim.deepcopy(base)
  if overrides == nil then return merged end
  if type(overrides) ~= "table" then
    error("azure-cli.setup: `timing` must be a table")
  end
  for field, value in pairs(overrides) do
    if merged[field] == nil then
      error("azure-cli.setup: unknown `timing` field '" .. tostring(field) .. "'")
    end
    if type(value) ~= "number" or value <= 0 then
      error("azure-cli.setup: `timing." .. field .. "` must be a positive number")
    end
    merged[field] = value
  end
  return merged
end

-- setup(opts): opts.keys merges over the defaults above (see merge_keys).
-- Optional - every surface applies the defaults untouched when setup() is
-- never called (:AzureCli works standalone, no setup() required).
--
-- opts.python: overrides the python3/python probe in provider_cmd() below -
-- precedence is env AZVICLI_PY (an ambient override the shell/launcher set
-- before Neovim even started) first, then this, then the probe. opts.config:
-- sets AZVICLI_CONFIG (see M.config_path()/provider_cmd() below) to a
-- specific azure-cli.yml path, `~` expanded by whoever reads it (Config.path()
-- on the python side, M.config_path() here) rather than here, so the raw
-- string this sets is exactly what a subprocess inheriting it would also see.
-- Unlike `python`, there's no "env wins" precedence to preserve for `config` -
-- calling setup({config=...}) is itself the explicit override, so it's
-- applied unconditionally (an ambient AZVICLI_CONFIG some other tool already
-- exported is deliberately overwritten, not deferred to).
function M.setup(opts)
  opts = opts or {}
  if opts.python ~= nil and (type(opts.python) ~= "string" or opts.python == "") then
    error("azure-cli.setup: `python` must be a non-empty string")
  end
  if opts.config ~= nil then
    if type(opts.config) ~= "string" or opts.config == "" then
      error("azure-cli.setup: `config` must be a non-empty string")
    end
    vim.env.AZVICLI_CONFIG = opts.config
  end
  if opts.hide_ancient_days ~= nil and (type(opts.hide_ancient_days) ~= "number" or opts.hide_ancient_days <= 0) then
    error("azure-cli.setup: `hide_ancient_days` must be a positive number")
  end
  if opts.notifications ~= nil and opts.notifications ~= "float" and opts.notifications ~= "notify" then
    error("azure-cli.setup: `notifications` must be \"float\" or \"notify\"")
  end
  local collapsed_sections = DEFAULTS.collapsed_sections
  if opts.collapsed_sections ~= nil then
    if type(opts.collapsed_sections) ~= "table" then
      error("azure-cli.setup: `collapsed_sections` must be a table of section keys")
    end
    for _, v in ipairs(opts.collapsed_sections) do
      if type(v) ~= "string" then
        error("azure-cli.setup: `collapsed_sections` entries must be strings")
      end
    end
    collapsed_sections = opts.collapsed_sections
  end
  local accounts
  if opts.accounts ~= nil then
    accounts = validate_accounts(opts.accounts)
    vim.env.AZVICLI_ACCOUNTS_JSON = vim.json.encode({ accounts = accounts })
  else
    -- No accounts here: the provider reads azure-cli.yml (and a stale
    -- export from an earlier setup() call in this session must not linger).
    vim.env.AZVICLI_ACCOUNTS_JSON = nil
  end
  local timing = merge_timing(DEFAULTS.timing, opts.timing)
  resolved = {
    keys = merge_keys(DEFAULTS.keys, opts.keys),
    python = opts.python,
    accounts = accounts,
    timing = timing,
    hide_ancient_days = opts.hide_ancient_days or DEFAULTS.hide_ancient_days,
    notifications = opts.notifications or DEFAULTS.notifications,
    collapsed_sections = collapsed_sections,
  }
  -- cached_prs/threads_ttl_seconds apply straight to cache.lua's own
  -- M.MAX_PRS/M.THREADS_TTL fields, which every read site there already
  -- uses live - see the DEFAULT_TIMING comment above for why these two
  -- (and only these two) are pushed at setup() time instead of read
  -- through M.get().timing where they're used. pcall'd: cache.lua is
  -- always a real sibling module under a plugin-manager/standalone install
  -- (require() resolves it through 'runtimepath'), but a couple of dev-only
  -- tools dofile() this file directly with no 'rtp'/LUA_PATH set up at all
  -- (tests/gen-keys-table.lua only wants DEFAULT_KEYS) - setup() shouldn't
  -- fail there just because cache.lua isn't reachable.
  local ok, cache = pcall(require, "azure-cli.cache")
  if ok then
    cache.MAX_PRS = timing.cached_prs
    cache.THREADS_TTL = timing.threads_ttl_seconds
  end
  return resolved
end

-- The active config: whatever setup() last resolved, or the defaults.
function M.get()
  return resolved or DEFAULTS
end

-- Path of the optional standalone options file: azure-cli.lua next to
-- azure-cli.yml (standalone/init.lua dofile()s it and passes the returned
-- table to setup(); plugin users call setup() from their own init instead).
function M.options_path()
  return (M.config_path():gsub("%.yml$", ".lua"))
end

-- Renders a complete azure-cli.lua holding every setup() option at its
-- default value, generated from the same DEFAULTS tables setup() merges
-- over so the file can never drift from the code. Surfaces come out in the
-- README's order, actions alphabetically, so a diff of two generated files
-- is meaningful. Multi-key defaults render as Lua lists.
local SURFACE_ORDER = { "dashboard", "list", "diff", "overview", "nav", "workitems", "workitem_view" }
local SURFACE_TITLES = {
  dashboard = "Pull-request dashboard", list = "Reviewer: file list", diff = "Reviewer: diff pane",
  overview = "Reviewer: Overview page", nav = "Reviewer: gd/gr/gf revision buffers and peek",
  workitems = "Work-items dashboard", workitem_view = "Work-item detail view",
}
local function lua_literal(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  if type(v) == "table" then
    local parts = {}
    for _, item in ipairs(v) do parts[#parts + 1] = lua_literal(item) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return "nil"
end
local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end
function M.render_options()
  local out = {}
  local function w(line) out[#out + 1] = line end
  w("-- azure-cli.lua: setup() options for the standalone launcher.")
  w("-- Generated by :AzureCli options with every option at its default; edit")
  w("-- what you want to change and delete the rest (or leave it - a value equal")
  w("-- to the default is harmless). Keys: a string, a list of strings for")
  w("-- several bindings, or false to unbind. `keys.prefix = { diff = \"<leader>a\" }`")
  w("-- prepends a prefix to every key of that surface. Plugin users pass this")
  w("-- same table to require(\"azure-cli\").setup() instead.")
  w("return {")
  w("  keys = {")
  for _, surface in ipairs(SURFACE_ORDER) do
    local actions = DEFAULTS.keys[surface]
    if actions then
      w("    -- " .. (SURFACE_TITLES[surface] or surface))
      w("    " .. surface .. " = {")
      for _, action in ipairs(sorted_keys(actions)) do
        w("      " .. action .. " = " .. lua_literal(actions[action]) .. ",")
      end
      w("    },")
    end
  end
  w("  },")
  w("")
  w("  -- Seconds/milliseconds/counts behind polling, hover prefetch, the warm-all")
  w("  -- pass, the content cache and the 'aged' highlight on old PRs.")
  w("  timing = {")
  for _, k in ipairs(sorted_keys(DEFAULTS.timing)) do
    w("    " .. k .. " = " .. lua_literal(DEFAULTS.timing[k]) .. ",")
  end
  w("  },")
  w("")
  w("  -- Days without a commit before an account's hide_ancient: hides a PR.")
  w("  hide_ancient_days = " .. lua_literal(DEFAULTS.hide_ancient_days) .. ",")
  w("  -- \"float\": transient messages in a corner float; \"notify\": plain vim.notify.")
  w("  notifications = " .. lua_literal(DEFAULTS.notifications) .. ",")
  w("  -- Dashboard sections that start collapsed (Mentions, Actionable, Waiting,")
  w("  -- SignedOff, Drafts, Created).")
  w("  collapsed_sections = " .. lua_literal(DEFAULTS.collapsed_sections) .. ",")
  w("  -- python = \"/path/to/python\",       -- interpreter for azure-cli.py (default: python3, else python)")
  w("  -- config = \"~/other/azure-cli.yml\",  -- a different config file")
  w("}")
  return table.concat(out, "\n") .. "\n"
end

-- Writes the generated options file unless one already exists. Returns
-- the path and whether it was created.
function M.write_options()
  local path = M.options_path()
  if vim.fn.filereadable(path) == 1 then return path, false end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok = vim.fn.writefile(vim.split(M.render_options(), "\n", { plain = true, trimempty = true }), path) == 0
  return path, ok
end

-- Resolves azure-cli.yml's path exactly like azure-cli.py's Config.path():
-- AZVICLI_CONFIG (expanded here with `~` support, same as Config.path()'s
-- own os.path.expanduser) first, else %APPDATA%\azure-cli.yml on Windows,
-- $XDG_CONFIG_HOME/azure-cli.yml (default ~/.config) elsewhere. Every
-- surface's own config_path() (dashboard.lua, workitems/dashboard.lua,
-- review/init.lua) delegates here instead of re-deriving it, so gO and
-- `:AzureCli status` never drift from what the provider itself resolves.
-- How many accounts setup({accounts=...}) configured, or nil when the
-- accounts come from azure-cli.yml. What firstrun.lua, health.lua,
-- :AzureCli status and the gO keys branch on.
function M.accounts_from_setup()
  local a = M.get().accounts
  return a and #a or nil
end

-- The message a gO key shows instead of opening azure-cli.yml when the
-- accounts live in setup(); nil when the file is the config.
function M.setup_accounts_notice()
  local n = M.accounts_from_setup()
  if not n then return nil end
  return "azure-cli: your " .. n .. " account(s) are configured with setup({accounts=...}) in your Neovim "
    .. "config, so azure-cli.yml isn't used - edit that setup() call instead."
end

function M.config_path()
  local env = vim.env
  if env.AZVICLI_CONFIG and env.AZVICLI_CONFIG ~= "" then
    return vim.fn.expand(env.AZVICLI_CONFIG)
  end
  if vim.fn.has("win32") == 1 then
    return (env.APPDATA or vim.fn.expand("$APPDATA")) .. "\\azure-cli.yml"
  end
  local xdg = env.XDG_CONFIG_HOME
  if not xdg or xdg == "" then xdg = vim.fn.expand("~/.config") end
  return xdg .. "/azure-cli.yml"
end

return M
