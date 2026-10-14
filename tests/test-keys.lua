-- test-keys.lua: pure tests for lua/azure-cli/config.lua (setup/merge/
-- validate) and lua/azure-cli/keys.lua (resolve/bind/line/label), run under
-- plain luajit with a small vim shim - no real Neovim needed, the same
-- style as test-decorate.lua/test-rpc.lua's shims.
--
-- Usage: luajit test-keys.lua <config.lua path> <keys.lua path>

dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
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

-- 4. A list-valued default (workitems.toggle_fold responds to both "za" and
-- "<Space>") resolves and binds every key in the list.
config.setup({})  -- back to defaults
local toggle_fold = keys.resolve("workitems", "toggle_fold")
check("list default workitems.toggle_fold",
  type(toggle_fold) == "table" and toggle_fold[1] == "za" and toggle_fold[2] == "<Space>",
  toggle_fold)
keymap_calls = {}
keys.bind(1, "workitems", "toggle_fold", function() end, { desc = "fold" })
check("bind() binds every key in a list",
  #keymap_calls == 2 and keymap_calls[1].key == "za" and keymap_calls[2].key == "<Space>")
check("bind() forwards desc", keymap_calls[1].opts.desc == "fold")

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

-- 9. The "keys that matter now" hints: first key of each bound action, the
-- unbound ones left out; the key highlighted inside the muted line.
config.setup({ keys = { plan = { revise = false, approve = { "gA", "Y" } } } })
do
  local lines, hls = keys.hint_lines({ { "plan", "approve", "approve" }, { "plan", "revise", "ask for changes" },
    { "plan", "help", "all keys" } })
  check("hint_lines: unbound skipped, first key", #lines == 2 and lines[1] == " gA  approve" and lines[2] == " ?   all keys")
  check("hint_lines: line muted, key highlighted", hls[1][4] == "AzureCliMuted" and hls[2][2] == 1 and hls[2][3] == 3
    and hls[2][4] == "AzureCliKeyHint" and hls[4][1] == 1)
  local text, lhls = keys.hint_line({ { "plan", "approve", "approve" }, { "plan", "revise", "x" },
    { "plan", "help", "all keys" } }, "  ")
  check("hint_line: one line, separated", text == "  gA approve  \u{00B7}  ? all keys")
  check("hint_line: key columns", #lhls == 2 and text:sub(lhls[1][1] + 1, lhls[1][2]) == "gA"
    and text:sub(lhls[2][1] + 1, lhls[2][2]) == "?")
  check("name: the key, or the action in words when unbound", keys.name("plan", "approve") == "gA"
    and keys.name("plan", "revise") == "revise")
  local fn_lines = keys.help_lines("plan", "T", { "G", { "approve", function() return "made " .. "now" end } })
  check("help_lines: a description can be worked out when shown", fn_lines[4]:find("^  gA / Y%s+made now$") ~= nil,
    table.concat(fn_lines, "\n"))
  check("first: nil when unbound, else the first key", keys.first("plan", "revise") == nil and keys.first("plan", "approve") == "gA")
end
config.setup({})

-- 10. `?` marks what changes Azure DevOps, with a legend; a screen whose
-- same actions stay local (opts.writes = {}) has neither.
do
  local tbl = { "Act", { "vote", "vote" }, { "refresh", "refresh" } }
  local lines = keys.help_lines("dashboard", "T", tbl)
  local text = table.concat(lines, "\n")
  check("help_lines: a write is marked", text:find("\n\u{2191} gv          vote", 1, true) ~= nil, text)
  check("help_lines: the rest isn't", text:find("\n  r           refresh", 1, true) ~= nil, text)
  check("help_lines: legend when something is marked", text:find("\u{2191} changes Azure DevOps", 1, true) ~= nil)
  text = table.concat(keys.help_lines("diff", "T", { "Ask", { "comment", "queue" } }, { writes = {} }), "\n")
  check("help_lines: opts.writes = {} marks nothing", not text:find("\u{2191}", 1, true), text)
end

-- 11. No default key is something that acts on one screen and something
-- harmless on another - you'd learn it on the harmless one and press it on
-- the other - unless the acting one asks before it does anything, so a
-- mistaken press costs one "no". Acting = changes Azure DevOps (keys.WRITES)
-- or lets an agent go ahead. A new clash fails here: give one of the two
-- another key, or - if the acting one really asks first - add it below.
do
  local ACTS = {}
  for surface, t in pairs(keys.WRITES) do for action in pairs(t) do ACTS[surface .. "." .. action] = true end end
  ACTS["plan.approve"], ACTS["agents.approve"], ACTS["agents.discard"] = true, true, true
  -- Acting keys that ask first (a dialog, an editor, a picker or a confirm).
  local ASKS_FIRST = {
    ["dashboard.complete"] = "the complete dialog", ["list.complete"] = "the complete dialog",
    ["diff.complete"] = "the complete dialog", ["overview.complete"] = "the complete dialog",
    ["workitems.assign"] = "asks whom", ["workitem_view.assign"] = "asks whom",
    ["workitems.move_sprint"] = "picks the sprint", ["workitem_view.move_sprint"] = "picks the sprint",
    ["workitems.priority"] = "picks the priority", ["workitem_view.priority"] = "picks the priority",
    ["workitem_view.comment"] = "opens the editor",
    ["overview.delete_comment"] = "confirms",
    ["plan.approve"] = "asks how (and whether to let it push)", ["agents.approve"] = "asks how",
    ["dashboard.requeue_build"] = "confirms (UI.confirm's popup)",
    ["agents.discard"] = "confirms (UI.confirm's popup)",
  }
  local function find_clashes()
    local by_key = {}
    for surface, t in pairs(config.get().keys) do
      if surface ~= "prefix" then
        for action in pairs(t) do
          local spec = keys.resolve(surface, action)
          for _, k in ipairs(type(spec) == "table" and spec or { spec }) do
            by_key[k] = by_key[k] or {}
            table.insert(by_key[k], surface .. "." .. action)
          end
        end
      end
    end
    local clashes = {}
    for k, ids in pairs(by_key) do
      local acting, other = {}, {}
      for _, id in ipairs(ids) do
        if ACTS[id] then acting[#acting + 1] = id else other[#other + 1] = id end
      end
      if #other > 0 then
        for _, id in ipairs(acting) do
          if not ASKS_FIRST[id] then
            table.sort(other)
            clashes[#clashes + 1] = k .. ": " .. id .. " acts without asking, but is " .. table.concat(other, ", ")
              .. " elsewhere"
          end
        end
      end
    end
    table.sort(clashes)
    return clashes
  end
  local clashes = find_clashes()
  check("no key acts on one screen and is harmless on another", #clashes == 0, table.concat(clashes, "\n"))
  -- And the check bites: gL as the plan's run log again would be one.
  config.setup({ keys = { plan = { run_log = "gL" } } })
  clashes = find_clashes()
  local text = table.concat(clashes, "\n")
  check("the clash check catches gL as both unlink and the run log",
    text:find("gL: dashboard.unlink_workitem acts without asking, but is plan.run_log elsewhere", 1, true) ~= nil, text)
  config.setup({})
end

-- 12. i types in the chat on the home screens only (the PR dashboard, the
-- boards, Agents); everywhere else it's still Vim's own i.
check("chat_input is i on the home screens", keys.resolve("dashboard", "chat_input") == "i"
  and keys.resolve("workitems", "chat_input") == "i" and keys.resolve("agents", "chat_input") == "i")
for _, s in ipairs({ "diff", "list", "workitem_view" }) do
  check("no chat_input on " .. s, config.get().keys[s].chat_input == nil)
end

-- 13. Inner tabs (innertabs.lua): ]r / [r, and g1..g9 for the strip's
-- entries. They're bound on the PR dashboard, the boards (W, I), the
-- reviewer's and the work-item view's buffers next to those surfaces' own
-- keys, so none of those may have a key that starts one of them (a bare ]
-- or [) - bound with nowait, it would fire before the r.
check("tabs: ]r / [r", keys.resolve("tabs", "next") == "]r" and keys.resolve("tabs", "prev") == "[r")
local tab_keys = {}
do
  local pick = keys.resolve("tabs", "pick")
  check("tabs: pick is g1..g9", type(pick) == "table" and #pick == 9 and pick[1] == "g1" and pick[9] == "g9")
  for _, a in ipairs({ "next", "prev", "pick" }) do
    local spec = keys.resolve("tabs", a)
    for _, k in ipairs(type(spec) == "table" and spec or { spec }) do tab_keys[#tab_keys + 1] = k end
  end
end
for _, s in ipairs({ "dashboard", "list", "diff", "overview", "nav", "workitems", "workitem_view" }) do
  local bad = {}
  for action, spec in pairs(config.get().keys[s]) do
    for _, k in ipairs(type(spec) == "table" and spec or { spec }) do
      for _, t in ipairs(tab_keys) do
        if type(k) == "string" and #k < #t and t:sub(1, #k) == k then bad[#bad + 1] = action .. " (" .. k .. ")" end
      end
    end
  end
  check("tabs: nothing on " .. s .. " starts an inner-tab key", #bad == 0, table.concat(bad, ", "))
end

print(fails == 0 and "test-keys: all cases pass" or ("test-keys: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
