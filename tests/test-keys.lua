-- test-keys.lua: pure tests for lua/azure-cli/config.lua (setup/merge/
-- validate) and lua/azure-cli/keys.lua (resolve/bind/line/label), run under
-- plain luajit with a small vim shim - no real Neovim needed, the same
-- style as test-decorate.lua/test-rpc.lua's shims.
--
-- Usage: luajit test-keys.lua <config.lua path> <keys.lua path>

local keymap_calls = {}
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
    executable = function() return 0 end,
  },
  env = {},
  keymap = {
    set = function(mode, key, fn, opts)
      keymap_calls[#keymap_calls + 1] = { mode = mode, key = key, fn = fn, opts = opts }
    end,
  },
}

local config_path, keys_path = arg[1], arg[2]
assert(config_path and keys_path, "usage: luajit test-keys.lua <config.lua> <keys.lua>")

-- keys.lua does `require("azure-cli.config")` - require()'s own module
-- cache (package.loaded) is plain Lua/LuaJIT, not vim-specific, so
-- pre-seeding it with the already-dofile'd config module makes that
-- require() call return it without ever touching package.path.
package = package or {}
package.loaded = package.loaded or {}

local config = dofile(config_path)
package.loaded["azure-cli.config"] = config
local keys = dofile(keys_path)

local fails = 0
local function check(name, cond, detail)
  if cond then
    print("ok    " .. name)
  else
    fails = fails + 1
    print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- 1. Defaults resolve without setup() ever having run.
check("default dashboard.open", keys.resolve("dashboard", "open") == "<CR>")
check("default diff.next_hunk", keys.resolve("diff", "next_hunk") == "]c")

-- 2. setup() merge: overriding one action leaves its siblings and every
-- other surface untouched (the example from the task/README).
config.setup({ keys = { diff = { next_hunk = "]h" } } })
check("override diff.next_hunk", keys.resolve("diff", "next_hunk") == "]h")
check("sibling diff.prev_hunk untouched", keys.resolve("diff", "prev_hunk") == "[c")
check("other surface untouched", keys.resolve("dashboard", "open") == "<CR>")

-- 3. Unbind via `false` - resolve() returns nil, and bind() then never
-- calls vim.keymap.set for it.
config.setup({ keys = { dashboard = { vote = false } } })
check("unbind dashboard.vote", keys.resolve("dashboard", "vote") == nil)
keymap_calls = {}
keys.bind(1, "dashboard", "vote", function() end)
check("bind() no-ops for an unbound action", #keymap_calls == 0)

-- 4. A list-valued default (workitems.next_sprint responds to both "]" and
-- "<Tab>") resolves and binds every key in the list.
config.setup({})  -- back to defaults
local next_sprint = keys.resolve("workitems", "next_sprint")
check("list default workitems.next_sprint",
  type(next_sprint) == "table" and next_sprint[1] == "]" and next_sprint[2] == "<Tab>",
  next_sprint)
keymap_calls = {}
keys.bind(1, "workitems", "next_sprint", function() end, { desc = "next sprint" })
check("bind() binds every key in a list",
  #keymap_calls == 2 and keymap_calls[1].key == "]" and keymap_calls[2].key == "<Tab>")
check("bind() forwards desc", keymap_calls[1].opts.desc == "next sprint")

-- 5. Per-surface prefix, prepended to every key resolved for that surface.
config.setup({ keys = { prefix = { dashboard = "<leader>a" } } })
check("prefix applies", keys.resolve("dashboard", "open") == "<leader>a<CR>")
config.setup({})

-- 6. Unknown action/surface names error clearly at setup().
local ok, err = pcall(config.setup, { keys = { dashboard = { bogus_action = "x" } } })
check("unknown action errors",
  not ok and tostring(err):find("bogus_action", 1, true) ~= nil, err)
local ok2, err2 = pcall(config.setup, { keys = { bogus_surface = { open = "x" } } })
check("unknown surface errors",
  not ok2 and tostring(err2):find("bogus_surface", 1, true) ~= nil, err2)
config.setup({})  -- setup() above must not have partially applied either error case

-- 7. Help-line rendering: real key + desc when bound, nil when unbound.
local line = keys.line("dashboard", "open", "open the PR under the cursor")
check("help line has key and desc",
  line ~= nil and line:find("<CR>", 1, true) ~= nil
    and line:find("open the PR under the cursor", 1, true) ~= nil,
  line)
config.setup({ keys = { dashboard = { open = false } } })
check("help line nil when unbound", keys.line("dashboard", "open", "x") == nil)
config.setup({})
-- A missing description (an action added to a help table without a desc
-- entry - exactly how `?` on the dashboard once threw) falls back to the
-- action name instead of erroring.
local ok_nil, line_nil = pcall(keys.line, "dashboard", "first_pr", nil)
check("help line survives a nil desc",
  ok_nil and type(line_nil) == "string" and line_nil:find("first pr", 1, true) ~= nil, line_nil)

-- 7b. Grouped help: string entries name groups, unbound actions and empty
--     groups vanish, `now`/`extra`/`notes` land where documented.
do
  config.setup({ keys = { dashboard = { vote = false } } })
  local lines = keys.help_lines("dashboard", "PR dashboard keys", {
    "Navigate", { "open", "open" }, { "first_pr", "first" },
    "Act", { "vote", "vote" },
    "Session", { "quit", "quit" },
  }, { now = { "[filter: x]" }, fixed = { "  j / k       move" }, extra = { { key = "gB", desc = "batch" } },
       extra_title = "Features", notes = { "a note" } })
  local text = table.concat(lines, "\n")
  check("help_lines: title first", lines[1] == "PR dashboard keys")
  check("help_lines: now line", lines[2] == "  now: [filter: x]")
  check("help_lines: group headers", text:find("── Navigate ──", 1, true) and text:find("── Session ──", 1, true))
  check("help_lines: empty group skipped (vote unbound)", not text:find("── Act ──", 1, true))
  check("help_lines: fixed lines under the first group", lines[5] == "  j / k       move")
  check("help_lines: extra under its own title", text:find("── Features ──\n  gB          batch", 1, true) ~= nil)
  check("help_lines: notes last", lines[#lines] == "a note")
  config.setup({})
end

-- 8. Winbar label rendering: "key: hint", "" when unbound.
check("winbar label", keys.label("dashboard", "quit", "quit") == "q: quit")
config.setup({ keys = { dashboard = { quit = false } } })
check("winbar label empty when unbound", keys.label("dashboard", "quit", "quit") == "")
config.setup({})

print(fails == 0 and "test-keys: all cases pass" or ("test-keys: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
