-- test-prompt.lua: lua/azure-cli/prompt.lua under a vim.ui shim - checks
-- the select/input/confirm wrappers hand vim.ui.* the right shape and map
-- its answers (and cancels) back to the plugin's cb(item|nil) contract.
--
-- Usage: luajit test-prompt.lua <prompt.lua path>

local path = arg[1]
assert(path, "usage: luajit test-prompt.lua <prompt.lua path>")

local flashes = {}
local last_select, last_input
local select_answer, input_answer  -- what the shimmed vim.ui.* answers with
vim = {
  log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
  trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
  ui = {
    select = function(items, opts, on_choice)
      last_select = { items = items, opts = opts }
      local ans = select_answer
      if ans == nil then on_choice(nil, nil) else on_choice(items[ans], ans) end
    end,
    input = function(opts, on_confirm)
      last_input = opts
      on_confirm(input_answer)
    end,
  },
}
package.loaded["azure-cli.notify"] = { flash = function(msg) flashes[#flashes + 1] = msg end }
-- ui.confirm: "select" for the vim.ui.* cases, "popup" for the last ones -
-- with ui.lua stubbed, recording what the popup was asked for.
local ui_style = "select"
package.loaded["azure-cli.config"] = { get = function() return { ui = { confirm = ui_style } } end }
local popup_call, popup_answer
package.loaded["azure-cli.ui"] = {
  choose = function(o, cb) popup_call = o cb(popup_answer) end,
  confirm = function(o, cb) popup_call = o cb(popup_answer == 1) end,
}

local P = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then
    print("ok    " .. name)
  else
    fails = fails + 1
    print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- select: labelled items, the current one is marked, the chosen table
-- comes back as-is with its index.
do
  local items = { { label = "Approve", key = "10" }, { label = "Reject", key = "-10" } }
  select_answer = 2
  local got, got_idx
  P.select({ prompt = "Vote on PR #1", items = items, current = items[1] }, function(c, i) got, got_idx = c, i end)
  check("select: chosen item and index", got == items[2] and got_idx == 2)
  check("select: prompt gets a trailing colon", last_select.opts.prompt == "Vote on PR #1:")
  check("select: current item is marked", last_select.opts.format_item(items[1]) == "Approve  (current)")
  check("select: other items are not", last_select.opts.format_item(items[2]) == "Reject")
end

-- select: a predicate can pick the current entry; plain strings format
-- as themselves.
do
  select_answer = 1
  local got
  P.select({ items = { "P1", "P2" }, current = function(x) return x == "P2" end }, function(c) got = c end)
  check("select: string items", got == "P1")
  check("select: predicate current", last_select.opts.format_item("P2") == "P2  (current)")
end

-- select: cancel -> cb(nil) plus a "Cancelled." flash (unless silent).
do
  flashes = {}
  select_answer = nil
  local called, got = false, "unset"
  P.select({ items = { "a" } }, function(c) called, got = true, c end)
  check("select: cancel calls cb(nil)", called and got == nil)
  check("select: cancel flashes", flashes[1] == "Cancelled.")
  flashes = {}
  P.select({ items = { "a" }, silent = true }, function() end)
  check("select: silent cancel is quiet", #flashes == 0)
end

-- select: no items at all is an immediate cancel with a warning.
do
  flashes = {}
  select_answer = 1
  local got = "unset"
  P.select({ items = {} }, function(c) got = c end)
  check("select: empty list cancels", got == nil and flashes[1] == "Nothing to choose from.")
end

-- input: trimmed text through, empty/Esc as cancel, allow_empty passes "".
do
  input_answer = "  hello  "
  local got
  P.input({ prompt = "Title for #1:", default = "old" }, function(t) got = t end)
  check("input: text is trimmed", got == "hello")
  check("input: prompt gets a trailing space", last_input.prompt == "Title for #1: ")
  check("input: default forwarded", last_input.default == "old")

  input_answer = nil
  got = "unset"
  P.input({}, function(t) got = t end)
  check("input: Esc is cb(nil)", got == nil)

  input_answer = "   "
  got = "unset"
  P.input({}, function(t) got = t end)
  check("input: blank is a cancel by default", got == nil)

  input_answer = ""
  got = "unset"
  P.input({ allow_empty = true }, function(t) got = t end)
  check("input: allow_empty passes the empty string", got == "")
end

-- confirm: only the affirmative answer is true.
do
  select_answer = 1
  local got
  P.confirm({ prompt = "Merge?", yes = "Merge", no = "Keep open" }, function(b) got = b end)
  check("confirm: yes", got == true and last_select.items[1] == "Merge" and last_select.items[2] == "Keep open")
  select_answer = 2
  P.confirm({ prompt = "Merge?" }, function(b) got = b end)
  check("confirm: no", got == false)
  select_answer = nil
  got = "unset"
  P.confirm({ prompt = "Merge?" }, function(b) got = b end)
  check("confirm: Esc is false", got == false)
end

-- ui.confirm = "popup": a short menu and a yes/no question are the popup;
-- a long list, or one marked `search`, stays vim.ui.select.
do
  ui_style = "popup"
  last_select = nil
  popup_answer = 2
  local got, idx
  P.select({ prompt = "Vote:", items = { "Approve", "Wait", "Reject" }, current = "Wait" }, function(c, i) got, idx = c, i end)
  check("popup: a short menu", popup_call and popup_call.stack and popup_call.title == "Vote"
    and popup_call.buttons[1] == "1  Approve" and popup_call.buttons[2] == "2  Wait  (current)"
    and popup_call.keys["3"] == 3 and popup_call.default == 2 and popup_call.cancel == false and last_select == nil)
  check("popup: its answer is the item", got == "Wait" and idx == 2)
  popup_answer = nil
  got = "unset"
  P.select({ items = { "a", "b" } }, function(c) got = c end)
  check("popup: Esc is cb(nil)", got == nil)
  popup_call = nil
  local many = {}
  for i = 1, P.POPUP_MAX + 1 do many[i] = "x" .. i end
  P.select({ items = many }, function() end)
  check("popup: a long list stays vim.ui.select", popup_call == nil and last_select and #last_select.items == #many)
  last_select = nil
  P.select({ items = { "a" }, search = true }, function() end)
  check("popup: search = true stays vim.ui.select", popup_call == nil and last_select ~= nil)
  popup_answer = 1
  local yes
  P.confirm({ title = "Delete?", prompt = "It goes.", yes = "Delete", no = "Keep", danger = true }, function(b) yes = b end)
  check("popup: confirm", yes == true and popup_call.title == "Delete?" and popup_call.lines[1] == "It goes."
    and popup_call.yes == "Delete" and popup_call.default == "no")
  ui_style = "select"
end

print(fails == 0 and "test-prompt: all cases pass" or ("test-prompt: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
