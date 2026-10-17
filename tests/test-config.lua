-- test-config.lua: tests for lua/azure-cli/config.lua's setup() options
-- beyond `keys` (already covered by test-keys.lua): `python`/`config`
-- validation and precedence, M.config_path(), the AZVICLI_PREFETCH_DIR
-- default provider_cmd() sets, `timing`/`hide_ancient_days` defaults/
-- overrides/validation, and (when cache.lua's path is given too)
-- setup({timing={cached_prs=...,threads_ttl_seconds=...}}) applying to
-- cache.lua's M.MAX_PRS/M.THREADS_TTL. Runs under plain luajit with a small
-- vim shim - no real Neovim needed, same style as test-keys.lua.
--
-- Usage: luajit test-config.lua <config.lua path> [cache.lua path]

dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
vim = {
  deepcopy = function(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = vim.deepcopy(v) end
    return out
  end,
  fn = {
    strdisplaywidth = function(s) return #s end,
    fnamemodify = function(p) return p end,
    executable = function() return 0 end,  -- neither python3 nor python "found" by default
    has = function() return 0 end,          -- not win32
    expand = function(s)
      -- Just enough of vim.fn.expand for `~` prefix handling, the only
      -- expansion config.lua's M.config_path() relies on.
      local home = os.getenv("HOME") or "/home/test"
      if s == "~/.config" then return home .. "/.config" end
      if s:sub(1, 2) == "~/" then return home .. s:sub(2) end
      return s
    end,
    stdpath = function(what)
      if what == "cache" then return "/tmp/nvim-cache-test" end
      return "/tmp/nvim-test"
    end,
  },
  env = {},
  -- Just enough of vim.json.encode for setup({accounts=...})'s export:
  -- strings, numbers, booleans, arrays (#t > 0) and objects (sorted keys).
  json = {
    encode = function(v)
      local t = type(v)
      if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
      if t == "number" or t == "boolean" then return tostring(v) end
      if t == "table" then
        if #v > 0 then
          local parts = {}
          for _, x in ipairs(v) do parts[#parts + 1] = vim.json.encode(x) end
          return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. k .. '":' .. vim.json.encode(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
      end
      return "null"
    end,
  },
}

local config_path = arg[1]
assert(config_path, "usage: luajit test-config.lua <config.lua> [cache.lua]")
local cache_path = arg[2]

local config = dofile(config_path)

local fails = 0
local function check(name, cond, detail)
  if cond then
    print("ok    " .. name)
  else
    fails = fails + 1
    print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- --- python: precedence and validation --------------------------------------

do
  vim.env = {}
  config.setup({})
  local cmd = config.provider_cmd()
  check("python: probe fallback (neither python3 nor python executable, still returns 'python')",
    cmd[1] == "python", cmd[1])
end

do
  vim.env = {}
  vim.fn.executable = function(name) return name == "python3" and 1 or 0 end
  config.setup({})
  local cmd = config.provider_cmd()
  check("python: probe prefers python3 when it's on PATH", cmd[1] == "python3", cmd[1])
  vim.fn.executable = function() return 0 end
end

do
  vim.env = {}
  config.setup({ python = "/opt/my/python" })
  local cmd = config.provider_cmd()
  check("python: setup({python=...}) overrides the probe", cmd[1] == "/opt/my/python", cmd[1])
end

do
  vim.env = { AZVICLI_PY = "/env/python" }
  config.setup({ python = "/opt/my/python" })
  local cmd = config.provider_cmd()
  check("python: env AZVICLI_PY beats setup({python=...})", cmd[1] == "/env/python", cmd[1])
  vim.env = {}
end

do
  local ok, err = pcall(config.setup, { python = 42 })
  check("python: non-string errors clearly", not ok and tostring(err):find("python", 1, true) ~= nil, err)
end

do
  local ok, err = pcall(config.setup, { python = "" })
  check("python: empty string errors clearly", not ok and tostring(err):find("python", 1, true) ~= nil, err)
end

config.setup({})  -- reset

-- --- config: AZVICLI_CONFIG + M.config_path() precedence --------------------

do
  vim.env = {}
  config.setup({ config = "/custom/azure-cli.yml" })
  check("config: setup({config=...}) sets AZVICLI_CONFIG", vim.env.AZVICLI_CONFIG == "/custom/azure-cli.yml")
  check("config: M.config_path() reflects it", config.config_path() == "/custom/azure-cli.yml")
end

do
  vim.env = {}
  config.setup({ config = "~/configs/azure-cli.yml" })
  local home = os.getenv("HOME") or "/home/test"
  check("config: M.config_path() expands ~", config.config_path() == home .. "/configs/azure-cli.yml",
    config.config_path())
end

do
  local ok, err = pcall(config.setup, { config = 5 })
  check("config: non-string errors clearly", not ok and tostring(err):find("config", 1, true) ~= nil, err)
end

do
  local ok, err = pcall(config.setup, { config = "" })
  check("config: empty string errors clearly", not ok and tostring(err):find("config", 1, true) ~= nil, err)
end

do
  vim.env = {}
  config.setup({})
  local path = config.config_path()
  check("config: falls back to the platform default when unset",
    path:find("azure%-cli%.yml$") ~= nil, path)
end

-- AZVICLI_PREFETCH_DIR: provider_cmd() sets it once, from stdpath("cache"),
-- unless something already set it (an ambient override never gets stomped).
do
  vim.env = {}
  config.setup({})
  config.provider_cmd()
  check("prefetch dir: defaults to stdpath('cache') .. '/azure-cli'",
    vim.env.AZVICLI_PREFETCH_DIR == "/tmp/nvim-cache-test/azure-cli", vim.env.AZVICLI_PREFETCH_DIR)
end

do
  vim.env = { AZVICLI_PREFETCH_DIR = "/already/set" }
  config.setup({})
  config.provider_cmd()
  check("prefetch dir: an ambient value is never overwritten",
    vim.env.AZVICLI_PREFETCH_DIR == "/already/set", vim.env.AZVICLI_PREFETCH_DIR)
end

vim.env = {}
config.setup({})

-- --- timing: setup({timing=...}) applies to cache.lua ----------------------

if cache_path then
  -- cache.lua requires "azure-cli.state" and "azure-cli.rpc" - stub both in
  -- package.loaded so dofile()ing it here doesn't need a real Neovim.
  package = package or {}
  package.loaded = package.loaded or {}
  package.loaded["azure-cli.state"] = {
    PR_DIFF_CACHE = {}, PR_FILES_CACHE = {}, PR_COMMITS_CACHE = {},
    PR_CACHE_ORDER = {}, PR_THREADS_CACHE = {}, PR_DIFF_CACHE_EXTRA = {},
  }
  package.loaded["azure-cli.rpc"] = { run = function() end }
  local cache = dofile(cache_path)
  -- config.lua's own M.setup() does `require("azure-cli.cache")` internally
  -- (see its own comment) - pre-seed package.loaded so that resolves to
  -- this SAME table (require()'s module cache, keyed by the module name),
  -- not a second, separately dofile()'d instance under LUA_PATH.
  package.loaded["azure-cli.cache"] = cache

  check("timing: cache.lua defaults before any setup({timing=...})",
    cache.MAX_PRS == 24 and cache.THREADS_TTL == 120,
    cache.MAX_PRS .. "/" .. cache.THREADS_TTL)

  config.setup({ timing = { cached_prs = 5, threads_ttl_seconds = 30 } })
  check("timing: cached_prs applies to cache.lua's M.MAX_PRS straight from setup()",
    cache.MAX_PRS == 5, cache.MAX_PRS)
  check("timing: threads_ttl_seconds applies to cache.lua's M.THREADS_TTL straight from setup()",
    cache.THREADS_TTL == 30, cache.THREADS_TTL)

  config.setup({})
  check("timing: setup({}) (defaults) resets cache.lua's fields back too",
    cache.MAX_PRS == 24 and cache.THREADS_TTL == 120,
    cache.MAX_PRS .. "/" .. cache.THREADS_TTL)
end

-- --- timing: defaults, overrides and validation ------------------------------

do
  local t = config.get().timing
  check("timing: default poll_seconds", t.poll_seconds == 30, t.poll_seconds)
  check("timing: default hover_ms", t.hover_ms == 500, t.hover_ms)
  check("timing: default warm_concurrency", t.warm_concurrency == 4, t.warm_concurrency)
  check("timing: default cached_prs", t.cached_prs == 24, t.cached_prs)
  check("timing: default threads_ttl_seconds", t.threads_ttl_seconds == 120, t.threads_ttl_seconds)
  check("timing: default aged_days", t.aged_days == 14, t.aged_days)
  check("timing: default idle_after", t.idle_after == 300, t.idle_after)
  check("timing: default max_poll_seconds", t.max_poll_seconds == 300, t.max_poll_seconds)
  check("hide_ancient_days: default", config.get().hide_ancient_days == 30, config.get().hide_ancient_days)
end

do
  config.setup({ timing = { poll_seconds = 45 } })
  local t = config.get().timing
  check("timing: partial override keeps siblings at default",
    t.poll_seconds == 45 and t.hover_ms == 500, t.poll_seconds .. "/" .. t.hover_ms)
  config.setup({})
end

do
  local ok, err = pcall(config.setup, { timing = { poll_seconds = "soon" } })
  check("timing: non-number errors clearly",
    not ok and tostring(err):find("poll_seconds", 1, true) ~= nil, err)
  config.setup({})
end

do
  local ok, err = pcall(config.setup, { timing = { poll_seconds = -5 } })
  check("timing: non-positive number errors clearly",
    not ok and tostring(err):find("poll_seconds", 1, true) ~= nil, err)
  config.setup({})
end

do
  local ok, err = pcall(config.setup, { timing = { idle_after = 0 } })
  check("timing: non-positive idle_after errors clearly",
    not ok and tostring(err):find("idle_after", 1, true) ~= nil, err)
  ok, err = pcall(config.setup, { timing = { max_poll_seconds = "slow" } })
  check("timing: non-number max_poll_seconds errors clearly",
    not ok and tostring(err):find("max_poll_seconds", 1, true) ~= nil, err)
  config.setup({ timing = { idle_after = 60, max_poll_seconds = 600 } })
  local t = config.get().timing
  check("timing: idle_after/max_poll_seconds override", t.idle_after == 60 and t.max_poll_seconds == 600)
  config.setup({})
end

do
  local ok, err = pcall(config.setup, { timing = { bogus_field = 1 } })
  check("timing: unknown field errors clearly",
    not ok and tostring(err):find("bogus_field", 1, true) ~= nil, err)
  config.setup({})
end

-- --- hide_ancient_days: default, override, AZVICLI_HIDE_ANCIENT_DAYS export -

do
  config.setup({ hide_ancient_days = 45 })
  check("hide_ancient_days: override applies", config.get().hide_ancient_days == 45)
  vim.env = {}
  config.provider_cmd()
  check("hide_ancient_days: exported as AZVICLI_HIDE_ANCIENT_DAYS",
    vim.env.AZVICLI_HIDE_ANCIENT_DAYS == "45", vim.env.AZVICLI_HIDE_ANCIENT_DAYS)
  config.setup({})
end

do
  vim.env = {}
  config.setup({})
  config.provider_cmd()
  check("hide_ancient_days: default (30) exported when setup() never overrides it",
    vim.env.AZVICLI_HIDE_ANCIENT_DAYS == "30", vim.env.AZVICLI_HIDE_ANCIENT_DAYS)
end

do
  vim.env = { AZVICLI_HIDE_ANCIENT_DAYS = "99" }
  config.setup({})
  config.provider_cmd()
  check("hide_ancient_days: an ambient env value is never overwritten",
    vim.env.AZVICLI_HIDE_ANCIENT_DAYS == "99", vim.env.AZVICLI_HIDE_ANCIENT_DAYS)
  vim.env = {}
end

do
  local ok, err = pcall(config.setup, { hide_ancient_days = "many" })
  check("hide_ancient_days: non-number errors clearly",
    not ok and tostring(err):find("hide_ancient_days", 1, true) ~= nil, err)
  config.setup({})
end

do
  local ok, err = pcall(config.setup, { hide_ancient_days = -1 })
  check("hide_ancient_days: non-positive number errors clearly",
    not ok and tostring(err):find("hide_ancient_days", 1, true) ~= nil, err)
  config.setup({})
end

-- --- row_numbers: default, override, validation -----------------------------

do
  check("row_numbers: default is relative", config.get().row_numbers == "relative")
  config.setup({ row_numbers = false })
  check("row_numbers: false turns them off", config.get().row_numbers == false)
  config.setup({ row_numbers = "absolute" })
  check("row_numbers: absolute", config.get().row_numbers == "absolute")
  local ok, err = pcall(config.setup, { row_numbers = true })
  check("row_numbers: anything else errors clearly",
    not ok and tostring(err):find("row_numbers", 1, true) ~= nil, err)
  config.setup({})
  check("row_numbers: setup({}) resets to relative", config.get().row_numbers == "relative")
end

-- --- collapsed_sections: default, override, validation ----------------------

do
  local cs = config.get().collapsed_sections
  check("collapsed_sections: default is SignedOff/Drafts",
    #cs == 2 and cs[1] == "SignedOff" and cs[2] == "Drafts", table.concat(cs, ","))
end

do
  config.setup({ collapsed_sections = { "Waiting" } })
  local cs = config.get().collapsed_sections
  check("collapsed_sections: override replaces the default",
    #cs == 1 and cs[1] == "Waiting", table.concat(cs, ","))
  config.setup({})
  check("collapsed_sections: setup({}) resets back to the default",
    #config.get().collapsed_sections == 2)
end

do
  config.setup({ collapsed_sections = {} })
  check("collapsed_sections: an empty table means nothing starts collapsed",
    #config.get().collapsed_sections == 0)
  config.setup({})
end

do
  local ok, err = pcall(config.setup, { collapsed_sections = "SignedOff" })
  check("collapsed_sections: non-table errors clearly",
    not ok and tostring(err):find("collapsed_sections", 1, true) ~= nil, err)
  config.setup({})
end

do
  local ok, err = pcall(config.setup, { collapsed_sections = { "SignedOff", 5 } })
  check("collapsed_sections: a non-string entry errors clearly",
    not ok and tostring(err):find("collapsed_sections", 1, true) ~= nil, err)
  config.setup({})
end

print(fails == 0 and "test-config: all cases pass" or ("test-config: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end

-- render_options() must be valid Lua that evaluates back to the defaults,
-- so :AzureCli options can never hand out a file setup() would reject.
do
  local text = config.render_options()
  local chunk = assert(loadstring(text), "rendered options must parse")
  local opts = chunk()
  assert(type(opts) == "table" and type(opts.keys) == "table", "options file returns a table with keys")
  config.setup({})
  local defaults = config.get()
  for surface, actions in pairs(defaults.keys) do
    for action, key in pairs(actions) do
      local got = opts.keys[surface] and opts.keys[surface][action]
      if type(key) == "table" then
        assert(type(got) == "table" and #got == #key and got[1] == key[1], surface .. "." .. action .. " list preserved")
      else
        assert(got == key, surface .. "." .. action .. " default preserved (" .. tostring(got) .. " vs " .. tostring(key) .. ")")
      end
    end
  end
  for k, v in pairs(defaults.timing) do
    assert(opts.timing[k] == v, "timing." .. k .. " preserved")
  end
  assert(opts.hide_ancient_days == defaults.hide_ancient_days, "hide_ancient_days preserved")
  assert(opts.notifications == defaults.notifications, "notifications preserved")
  assert(#opts.collapsed_sections == #defaults.collapsed_sections, "collapsed_sections preserved")
  for k, v in pairs(defaults.ui) do
    assert(opts.ui and opts.ui[k] == v, "ui." .. k .. " preserved")
  end
  for k, v in pairs(defaults.dashboard_web) do
    assert(opts.dashboard_web and opts.dashboard_web[k] == v, "dashboard_web." .. k .. " preserved")
  end
  for field in pairs(config._CHAT_FIELDS) do
    assert(text:find("%f[%w_]" .. field .. " =") or text:find("%f[%w_]" .. field .. ","), "the options file mentions chat." .. field)
  end
  -- and setup() accepts the rendered table unchanged
  config.setup(opts)
  print("ok: render_options() round-trips the defaults through setup()")
end

-- --- accounts: setup({accounts=...}) validation and the JSON export ----------

do
  vim.env = {}
  config.setup({})
  check("no accounts: nothing exported, accounts_from_setup() nil",
    vim.env.AZVICLI_ACCOUNTS_JSON == nil and config.accounts_from_setup() == nil and config.setup_accounts_notice() == nil)

  local good = { {
    project_name = "P", org_url = "https://dev.azure.com/o", pat_file = "~/.config/azure-cli/pat",
    clones_dir = "/src", hide_ancient = true,
    work_items = { team = "T", types = { "User Story", "Bug" }, sprint_scope = "all" },
  } }
  config.setup({ accounts = good })
  local exported = vim.env.AZVICLI_ACCOUNTS_JSON
  check("accounts exported as JSON", type(exported) == "string" and exported:find('"accounts":[', 1, true) ~= nil, exported)
  check("export carries pat_file, not a token", exported:find('"pat_file":"~/.config/azure-cli/pat"', 1, true) ~= nil, exported)
  check("export keeps work_items.types as a list", exported:find('"types":["User Story","Bug"]', 1, true) ~= nil, exported)
  check("accounts_from_setup() counts them", config.accounts_from_setup() == 1)
  check("setup_accounts_notice() explains gO", (config.setup_accounts_notice() or ""):find("setup({accounts", 1, true) ~= nil)
  check("M.get().accounts is the validated list", config.get().accounts == good)

  -- a later setup() without accounts clears the export again
  config.setup({})
  check("setup() without accounts clears the export", vim.env.AZVICLI_ACCOUNTS_JSON == nil and config.accounts_from_setup() == nil)

  local function rejects(name, accounts, needle)
    local ok, err = pcall(config.setup, { accounts = accounts })
    check("rejects " .. name, not ok and tostring(err):find(needle, 1, true) ~= nil, err)
  end
  rejects("a non-table", "x", "list of account tables")
  rejects("an empty list", {}, "is empty")
  rejects("a missing project_name", { { org_url = "https://x", pat_file = "f" } }, "project_name")
  rejects("a missing org_url", { { project_name = "p", pat_file = "f" } }, "org_url")
  rejects("an org_url without a scheme", { { project_name = "p", org_url = "dev.azure.com/o", pat_file = "f" } }, "https://")
  rejects("a missing pat_file", { { project_name = "p", org_url = "https://x" } }, "non-empty `pat_file`")
  rejects("an empty pat_file", { { project_name = "p", org_url = "https://x", pat_file = "" } }, "non-empty `pat_file`")
  rejects("an inline pat", { { project_name = "p", org_url = "https://x", pat = "t" } }, "pat isn't accepted")
  rejects("an inline pat next to pat_file", { { project_name = "p", org_url = "https://x", pat = "t", pat_file = "f" } }, "pat isn't accepted")
  rejects("an unknown field", { { project_name = "p", org_url = "https://x", pat_file = "f", token = "t" } }, "unknown field `token`")
  rejects("a wrong type", { { project_name = "p", org_url = "https://x", pat_file = "f", hide_ancient = "yes" } }, "must be a boolean")
  rejects("work_items without team", { { project_name = "p", org_url = "https://x", pat_file = "f", work_items = {} } }, "`team`")
  rejects("a bad sprint_scope", { { project_name = "p", org_url = "https://x", pat_file = "f", work_items = { team = "T", sprint_scope = "some" } } }, "sprint_scope")
  rejects("a non-string in types", { { project_name = "p", org_url = "https://x", pat_file = "f", work_items = { team = "T", types = { 1 } } } }, "list of strings")

  -- issues: on a GitHub account (github_issues.py)
  config.setup({ accounts = { { host = "github", owner = "o", issues = { project = 3, scope = "all" } } } })
  check("issues: a project number is exported as one",
    (vim.env.AZVICLI_ACCOUNTS_JSON or ""):find('"project":3', 1, true) ~= nil, vim.env.AZVICLI_ACCOUNTS_JSON)
  local ok_title = pcall(config.setup, { accounts = { { host = "github", issues = { project = "Roadmap", repo = "r" } } } })
  check("issues: a project title is accepted", ok_title)
  config.setup({})
  rejects("issues without project", { { host = "github", issues = {} } }, "needs a `project`")
  rejects("a bad issues.scope", { { host = "github", issues = { project = 1, scope = "team" } } }, "issues.scope")
  rejects("an unknown issues field", { { host = "github", issues = { project = 1, team = "T" } } }, "unknown field `team`")
  rejects("issues on an Azure account", { { project_name = "p", org_url = "https://x", pat_file = "f", issues = { project = 1 } } }, "is for a GitHub account")
end

-- --- chat: placement defaults, agents, prompts, permissions -------------------
do
  config.setup({})
  local c = config.get().chat
  check("chat: defaults", c.position == "right" and c.size == 0.35 and c.input_height == 3 and c.agent == nil)
  local good = {
    position = "bottom", size = 12, daily_summary = true, suggest_on_new_comments = false, default_agent = "claude",
    agents = {
      claude = { cmd = { "claude", "-p", "--input-format", "stream-json" }, models = { "sonnet", { label = "Opus", value = "opus" } },
        strip = { "^\u{25CF}" } },
      copilot = { cmd = { "copilot", "--acp" }, acp = true },
    },
    prompts = { mine = "Do X", standup = false },
    permissions = { vote = "deny", create_branch = "ask" },
  }
  config.setup({ chat = good })
  c = config.get().chat
  check("chat: accepted", c.position == "bottom" and c.agents.claude and c.prompts.mine == "Do X" and c.permissions.vote == "deny")
  local function rejects(name, chat, needle)
    local ok, err = pcall(config.setup, { chat = chat })
    check("chat rejects " .. name, not ok and tostring(err):find(needle, 1, true) ~= nil, err)
  end
  rejects("a bad position", { position = "middle" }, "chat.position")
  rejects("an unknown field", { colour = "x" }, "unknown field `colour` in chat")
  rejects("an agent without cmd", { agent = { label = "x" } }, "chat.agent needs a `cmd`")
  rejects("a bad agents entry", { agents = { x = { cmd = {} } } }, "chat.agents.x.cmd is an empty list")
  rejects("a default_agent that isn't there", { agents = { a = { cmd = { "a" } } }, default_agent = "b" }, "default_agent")
  rejects("a bad model", { agent = { cmd = { "a" }, models = { 3 } } }, "models[1]")
  rejects("a bad strip pattern", { agent = { cmd = { "a" }, strip = { 1 } } }, "strip[1]")
  rejects("a bad prompt", { prompts = { ["bad name"] = "x" } }, "chat.prompts")
  rejects("a bad permission", { permissions = { vote = "maybe" } }, "chat.permissions.vote")
  rejects("a followup (gone)", { agent = { cmd = { "a" }, followup = { cmd = { "a" } } } }, "chat.agent.followup is gone")
  rejects("a session_pattern (gone)", { agent = { cmd = { "a" }, session_pattern = "x" } }, "chat.agent.session_pattern is gone")
  rejects("acp with a string cmd", { agent = { cmd = "copilot --acp", acp = true } }, "must be a list of strings when acp is set")
  rejects("a bad plan_first", { plan_first = "sometimes" }, "chat.plan_first")
  rejects("a bad test_cmd", { test_cmd = { widgets = 3 } }, "chat.test_cmd")
  rejects("a bad max_agents", { max_agents = 0 }, "chat.max_agents")
  config.setup({})
end

-- ui: border and palette.
do
  check("ui: defaults", config.get().ui.border == "rounded" and config.get().ui.palette == "colorscheme")
  config.setup({ ui = { border = "single" } })
  check("ui: a border, the palette left at its default", config.get().ui.border == "single"
    and config.get().ui.palette == "colorscheme")
  check("ui: key_hints defaults to auto", config.get().ui.key_hints == "auto")
  config.setup({ ui = { key_hints = false } })
  check("ui: key_hints = false kept", config.get().ui.key_hints == false)
  check("ui: confirm defaults to popup", config.get().ui.confirm == "popup")
  for _, bad in ipairs({ { border = "fancy" }, { palette = "pink" }, { colour = 1 }, { key_hints = "yes" }, { confirm = "dialog" } }) do
    local ok, err = pcall(config.setup, { ui = bad })
    check("ui: rejects " .. next(bad), not ok and tostring(err):find("ui", 1, true) ~= nil, err)
  end
  config.setup({})
end

-- dashboard_web: the phone dashboard (#97) - off, on loopback, never on every interface.
do
  local w = config.get().dashboard_web
  check("dashboard_web: off by default, loopback, port 8797", w.enabled == false and w.bind == "127.0.0.1"
    and w.port == 8797)
  config.setup({ dashboard_web = { enabled = true, bind = "100.64.0.5" } })
  w = config.get().dashboard_web
  check("dashboard_web: a VPN address accepted, the port left at its default", w.enabled == true
    and w.bind == "100.64.0.5" and w.port == 8797)
  config.setup({ dashboard_web = { port = 0 } })
  check("dashboard_web: port 0 (any free one) accepted", config.get().dashboard_web.port == 0)
  check("dashboard_web: persist_token on by default (#105)", config.get().dashboard_web.persist_token == true)
  config.setup({ dashboard_web = { persist_token = false } })
  check("dashboard_web: persist_token = false accepted", config.get().dashboard_web.persist_token == false)
  for _, bad in ipairs({ { bind = "0.0.0.0" }, { bind = "::" }, { bind = " 0.0.0.0 " }, { bind = "" }, { bind = "[::]" },
    { bind = 1 }, { port = 70000 }, { port = 1.5 }, { port = "80" }, { enabled = "yes" }, { colour = 1 },
    { persist_token = "no" } }) do
    local ok, err = pcall(config.setup, { dashboard_web = bad })
    check("dashboard_web: rejects " .. next(bad) .. " = " .. tostring(bad[next(bad)]),
      not ok and tostring(err):find("dashboard_web", 1, true) ~= nil, err)
  end
  local ok, err = pcall(config.setup, { dashboard_web = { bind = "0.0.0.0" } })
  check("dashboard_web: says why every interface is refused", not ok and tostring(err):find("every interface", 1, true),
    err)
  config.setup({})
end

if fails > 0 then
  print(fails .. " check(s) failed")
  os.exit(1)
end
