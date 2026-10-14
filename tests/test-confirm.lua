-- test-confirm.lua: ui.lua's question popup (UI.choose, UI.confirm) in a
-- real Neovim - its layout, every way out, the moment keys don't count yet,
-- the details above it, insert mode, ui.confirm = "select" - and the two
-- places that ask through it: the chat's "may the agent ...?" and approving
-- a plan. Needs the main loop (insert mode, real input), so not nvim -l:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-confirm.lua"
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  if ok then io.stdout:write("ok   " .. name .. "\n")
  else
    fails = fails + 1
    io.stdout:write("FAIL " .. name .. (detail and ("\n     " .. tostring(detail)) or "") .. "\n")
  end
end
require("azure-cli").setup({})
local UI = require("azure-cli.ui")

-- Layout (pure).
local lines, hls, rows = UI.choose_lines({ "PR #7  Fix it", "", "Runs its build again." }, { "Re-queue", "Cancel" }, 1,
  40, "y re-queue", false)
check("lines: the body, the buttons in a row, the hint", lines[1] == " PR #7  Fix it" and lines[2] == ""
  and lines[5] == " " .. "  Re-queue  " .. "   " .. "  Cancel  " and lines[7] == " y re-queue" and rows[1] == 5 and rows[2] == 5,
  vim.inspect(lines))
check("lines: the focused button stands out", hls[1][4] == "AzureCliButtonActive" and hls[2][4] == "AzureCliButton"
  and lines[5]:sub(hls[1][2] + 1, hls[1][3]) == "  Re-queue  " and lines[5]:sub(hls[2][2] + 1, hls[2][3]) == "  Cancel  ")
local _, waiting = UI.choose_lines({}, { "Allow", "Deny" }, 2, 40, nil, true)
check("lines: while keys don't count yet, no button is lit", waiting[1][4] == "AzureCliButton"
  and waiting[2][4] == "AzureCliButton")
local wrapped = UI.choose_lines({ string.rep("word ", 20) }, { "Ok" }, 1, 30)
check("lines: a long body wraps inside the width", #wrapped >= 4 and vim.fn.strdisplaywidth(wrapped[1]) <= 29,
  vim.inspect(wrapped))
local long_hint = UI.choose_lines({}, { "Ok" }, 1, 30, string.rep("key thing \u{00B7} ", 6))
local fits = true
for _, l in ipairs(long_hint) do if vim.fn.strdisplaywidth(l) > 30 then fits = false end end
check("lines: a long hint wraps too", fits and #long_hint >= 5, vim.inspect(long_hint))
local stacked, shls, srows = UI.choose_lines({}, { "Approve", "Approve, and let it push without asking", "Cancel" }, 2, 40)
check("lines: buttons that don't fit in a row go one per line", srows[1] == 2 and srows[2] == 3 and srows[3] == 4
  and vim.trim(stacked[3]) == "Approve, and let it push without asking" and shls[2][4] == "AzureCliButtonActive"
  and shls[1][3] - shls[1][2] == shls[2][3] - shls[2][2],
  vim.inspect(stacked))

-- The details' rows (issue #30: a long command was one line, wrapped by
-- Neovim in three rows, and scrolling by line skipped what didn't show).
local words = {}
for i = 1, 50 do words[i] = "word" .. i end
local long_cmd = table.concat(words, " ")
local drows = UI.wrap_details({ "Command:", "  " .. long_cmd }, 40)
local within, indented, back = true, true, {}
for i, l in ipairs(drows) do
  if vim.fn.strdisplaywidth(l) > 40 then within = false end
  if i > 1 and not l:match("^  %S") then indented = false end
  if i > 1 then for w in l:gmatch("%S+") do back[#back + 1] = w end end
end
check("wrap_details: rows within the width, indented like their line, the same words", #drows > 5 and within
  and indented and table.concat(back, " ") == long_cmd, vim.inspect(drows))
local drows_diff = UI.wrap_details({ "+" .. string.rep("abc ", 30) }, 30, true)
check("wrap_details: a diff line's later rows keep its +", #drows_diff > 1 and drows_diff[2]:sub(1, 1) == "+",
  vim.inspect(drows_diff))
local hard = UI.wrap_details({ string.rep("x", 70) }, 30)
check("wrap_details: a word longer than a row is cut", #hard == 3 and hard[1] == string.rep("x", 30)
  and table.concat(hard) == string.rep("x", 70), vim.inspect(hard))
check("wrap_details: short lines as they are", vim.deep_equal(UI.wrap_details({ "a", "", "  b" }, 30), { "a", "", "  b" }))

-- The popup: opens it, presses `keys` (after `wait` ms), returns its answers.
local function float_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then out[#out + 1] = w end
  end
  return out
end
local function run(keys, opts, wait)
  local got = {}
  local main = vim.api.nvim_get_current_win()
  local win = UI.choose(vim.tbl_extend("force", { title = "Sure?", lines = { "x" }, buttons = { "Yes", "No" },
    keys = { y = 1, n = 2 } }, opts or {}), function(i) got[#got + 1] = i end)
  if wait then vim.wait(wait) end
  if keys == "leave" then vim.api.nvim_set_current_win(main)
  else vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false) end
  vim.wait(150, function() return #got > 0 end, 10)
  vim.wait(30)
  local answered = vim.deepcopy(got)  -- before closing a popup still open answers it (cancel)
  local open = win and vim.api.nvim_win_is_valid(win)
  if open then pcall(vim.api.nvim_win_close, win, true) vim.wait(30) end
  return answered, open
end
local function is(got, want) return #got == 1 and got[1] == want end

check("y: its button", is(run("y"), 1))
check("<CR>: the focused one (the first by default)", is(run("<CR>"), 1))
check("<CR> with default = 2", is(run("<CR>", { default = 2 }), 2))
check("<Tab> <CR>: the next one", is(run("<Tab><CR>"), 2))
check("j k <CR>: back where it was", is(run("jk<CR>"), 1))
check("<Tab> past the last wraps to the first", is(run("<Tab><Tab><CR>"), 1))
check("n: its button", is(run("n"), 2))
check("q: cancel (the last button)", is(run("q"), 2))
check("<Esc>: cancel", is(run("<Esc>"), 2))
check("opts.cancel picks what backing out answers", is(run("<Esc>", { buttons = { "A", "B", "C" }, cancel = 1 }), 1))
local left = run("leave")
check("leaving the popup: cancel, once", is(left, 2), vim.inspect(left))
check("stray editing keys do nothing", select(2, run("ia:x")) == true)

-- Keys only count after arm_ms; backing out always works.
local early, still = run("y", { arm_ms = 400 })
check("arm_ms: y straight away does nothing", #early == 0 and still, vim.inspect(early))
check("arm_ms: <Esc> straight away still cancels", is(run("<Esc>", { arm_ms = 400 }), 2))
check("arm_ms: y after the moment answers", is(run("y", { arm_ms = 150 }, 250), 1))

-- Tick boxes (issue #31's multiSelect): <CR>, <Space>, x and their keys
-- tick, another button answers with the ticks; nothing given, none.
do
  local function ticking(keys, wait)
    local got = {}
    local win = UI.choose({ title = "Pick", lines = { "x" }, buttons = { "A", "B", "C", "Done", "Cancel" },
      keys = { ["1"] = 1, ["2"] = 2, ["3"] = 3 }, checks = { false, true, false }, stack = true, arm_ms = wait and 150 or nil },
      function(i, ticks) got[#got + 1] = { i, ticks } end)
    if wait then vim.wait(wait) end
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    vim.wait(150, function() return #got > 0 end, 10)
    local answered = vim.deepcopy(got)  -- (closing it below answers cancel)
    local open = vim.api.nvim_win_is_valid(win)
    if open then pcall(vim.api.nvim_win_close, win, true) vim.wait(30) end
    return answered, open, text
  end
  local got, _, text = ticking("<Esc>")
  check("checks: drawn as tick boxes, the others as they are", text:find("[ ] A", 1, true) and text:find("[x] B", 1, true)
    and text:find("  Done", 1, true) and not text:find("] Done", 1, true), text)
  check("checks: <Esc> answers cancel, with the ticks", #got == 1 and got[1][1] == 5
    and vim.deep_equal(got[1][2], { false, true, false }), vim.inspect(got))
  got = ticking("<CR>")
  check("checks: <CR> on a tick box ticks it and keeps asking", #got == 0, vim.inspect(got))
  got = ticking("<CR>j<Space>jjx<CR>")
  check("checks: <CR> / <Space> tick, x off a tick box does nothing, <CR> on Done answers",
    #got == 1 and got[1][1] == 4 and vim.deep_equal(got[1][2], { true, false, false }), vim.inspect(got))
  got = ticking("1<Tab><Tab><Tab><CR>")
  check("checks: a tick box's key ticks it", #got == 1 and got[1][1] == 4
    and vim.deep_equal(got[1][2], { true, true, false }), vim.inspect(got))
  got = ticking("1", 0)
  check("checks: arm_ms guards ticking too", #got == 0, vim.inspect(got))
  local plain = {}
  UI.choose({ title = "T", lines = { "x" }, buttons = { "Yes", "No" } }, function(i, t) plain = { i, t } end)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(100, function() return plain[1] ~= nil end, 10)
  check("checks: without them <CR> answers and cb gets no ticks", plain[1] == 1 and plain[2] == nil, vim.inspect(plain))
end

-- The details: a window above the popup, scrolled from it.
do
  local details = {}
  for i = 1, 200 do details[i] = "line " .. i end
  local got = {}
  local win = UI.choose({ title = "Push?", lines = { "Push it?" }, buttons = { "Allow", "Deny" }, keys = { y = 1 },
    details = details, details_ft = "diff" }, function(i) got[#got + 1] = i end)
  local dwin
  for _, w in ipairs(float_wins()) do if w ~= win then dwin = w end end
  check("details: a second window, above the popup", dwin and vim.api.nvim_win_get_position(dwin)[1]
    < vim.api.nvim_win_get_position(win)[1])
  check("details: its filetype", dwin and vim.bo[vim.api.nvim_win_get_buf(dwin)].filetype == "diff")
  check("details: the popup has the focus", vim.api.nvim_get_current_win() == win)
  local top = dwin and vim.fn.line("w0", dwin)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
  check("details: <C-d> in the popup scrolls them", dwin and vim.fn.line("w0", dwin) > top)
  top = dwin and vim.fn.line("w0", dwin)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-e>", true, false, true), "x", false)
  check("details: <C-e> scrolls one row", dwin and vim.fn.line("w0", dwin) == top + 1)
  vim.api.nvim_feedkeys("y", "x", false)
  vim.wait(100, function() return #got > 0 end, 10)
  check("details: gone with the popup", is(got, 1) and not vim.api.nvim_win_is_valid(dwin), vim.inspect(got))
end

-- ui.confirm = "select": vim.ui.select with the same buttons.
do
  require("azure-cli").setup({ ui = { confirm = "select" } })
  local real = vim.ui.select
  local offered
  vim.ui.select = function(items, _, cb) offered = items cb(items[2], 2) end
  local got
  UI.choose({ title = "T", lines = { "q" }, buttons = { "Allow", "Deny" } }, function(i) got = i end)
  vim.ui.select = real
  check("select: the buttons as the menu, the answer its index", got == 2 and offered and offered[1] == "Allow")
  require("azure-cli").setup({})
end

-- The chat's question: Deny first, keys after a moment, the details above.
do
  local CHAT = require("azure-cli.chat")
  local got
  CHAT.confirm("The agent wants to push fix/x.", function(yes) got = yes end, { "diff --git a/x b/x", "+1" })
  local wins = float_wins()
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
  local has_details = false
  for _, w in ipairs(wins) do  -- (the "answer in the prompt" note is a float too)
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "diff" then has_details = true end
  end
  check("chat: a popup with the question, and the details as a diff", has_details
    and text:find("push fix/x", 1, true), text)
  vim.api.nvim_feedkeys("y", "x", false)
  check("chat: y straight away doesn't allow", got == nil)
  vim.wait(500)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(100, function() return got ~= nil end, 10)
  check("chat: <CR> on the focused button denies", got == false, tostring(got))
end

-- The chat's question, answered with each of its keys (issue #41: y did
-- nothing and <CR> on Allow declined).
local function feed(keys) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false) end
local function ask_chat(keys, before)
  local CHAT = require("azure-cli.chat")
  local got
  CHAT.confirm("The agent wants to run `bash tests/run.sh` in wt.", function(yes) got = yes end)
  local popup = vim.api.nvim_get_current_win()
  if before then before(popup) end
  vim.wait(500)
  feed(keys)
  vim.wait(100, function() return got ~= nil end, 10)
  if got == nil and vim.api.nvim_win_is_valid(popup) then pcall(vim.api.nvim_win_close, popup, true) vim.wait(30) end
  return got, popup
end
check("chat: y after the moment allows", ask_chat("y") == true)
check("chat: <Tab> to Allow, <CR> allows", ask_chat("<Tab><CR>") == true)
check("chat: n denies", ask_chat("n") == false)

-- Issue #31: the agent's own questions in the real popup, one at a time
-- with the yes/no ones - a confirm asked meanwhile waits for the answer.
do
  local CHAT = require("azure-cli.chat")
  local main = vim.api.nvim_get_current_win()
  local picks, yes = false, nil
  CHAT.ask_questions({ label = "#21" }, { { question = "Which colour?", header = "Colour",
    options = { { label = "Red", description = "warm" }, { label = "Blue", description = "cool" } } } },
    function(p) picks = p end)
  local popup = vim.api.nvim_get_current_win()
  local cfg = vim.api.nvim_win_get_config(popup)
  local title = type(cfg.title) == "table" and (cfg.title[1] and cfg.title[1][1]) or cfg.title
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup), 0, -1, false), "\n")
  check("ask_questions: the header (whose it is) as the title, the options with their descriptions",
    tostring(title):find("[#21] Colour", 1, true) and text:find("1. Red - warm", 1, true)
    and text:find("Other\u{2026}", 1, true), vim.inspect({ title, text }))
  CHAT.confirm("The agent wants to run `ls`.", function(y) yes = y end)
  check("ask_questions: a yes/no question waits for it", vim.api.nvim_get_current_win() == popup and yes == nil)
  feed("2")
  check("ask_questions: 2 straight away does nothing", picks == false)
  vim.wait(500)
  feed("2")
  vim.wait(200, function() return picks ~= false end, 10)
  check("ask_questions: 2 after the moment picks Blue", vim.deep_equal(picks, { { "Blue" } }), vim.inspect(picks))
  vim.wait(300, function() return vim.api.nvim_get_current_win() ~= main end, 10)
  vim.wait(500)
  feed("n")
  vim.wait(200, function() return yes ~= nil end, 10)
  check("ask_questions: then the waiting yes/no question asks", yes == false, tostring(yes))
  pcall(vim.api.nvim_set_current_win, main)
  -- Esc declines.
  picks = false
  CHAT.ask_questions(nil, { { question = "Q?", options = { { label = "A" } } } }, function(p) picks = p end)
  feed("<Esc>")
  vim.wait(200, function() return picks ~= false end, 10)
  check("ask_questions: <Esc> declines", picks == nil, vim.inspect(picks))
  check("ask_questions: the focus comes back", vim.api.nvim_get_current_win() == main)
end

do
  local lit
  local got = ask_chat("<CR>", function(popup)
    vim.wait(500)
    -- The cursor put on Allow some other way than Tab (a mouse click does this).
    local buf = vim.api.nvim_win_get_buf(popup)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local c = l:find("Allow", 1, true)
      if c then vim.api.nvim_win_set_cursor(popup, { i, c }) vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf }) end
    end
    local line = vim.api.nvim_win_get_cursor(popup)[1]
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
      if m[4].hl_group == "AzureCliButtonActive" then lit = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
        :sub(m[3] + 1, m[4].end_col) end
    end
  end)
  check("chat: the cursor on Allow lights it, and <CR> allows", got == true and lit and lit:find("Allow", 1, true),
    vim.inspect({ got, lit }))
end
do
  local main = vim.api.nvim_get_current_win()
  local still, answered
  local got = ask_chat("y", function(popup)
    vim.api.nvim_set_current_win(main)  -- something takes the cursor before keys count
    vim.wait(50)
    still = vim.api.nvim_win_is_valid(popup) and vim.api.nvim_get_current_win() == popup
  end)
  check("chat: the focus taken before keys count comes back, and y allows", still and got == true,
    vim.inspect({ still, got }))
  answered = ask_chat("<Esc>", function() end)
  check("chat: <Esc> still denies", answered == false)
end

-- The issue's sequence: show_fix opens the change tab, the agent's
-- run_tests asks straight away, and the chat panel following into the tab
-- (its BufWinEnter, on a scheduled callback) used to split from the popup -
-- leaving it, which declined. Through the tool's own ask path.
do
  local CHAT = require("azure-cli.chat")
  local TOOLS = require("azure-cli.chat.tools")
  CHAT.show(false)
  local rt = TOOLS.by_name.run_tests
  local real = { run = rt.run, confirm = rt.confirm, preapproved = rt.preapproved, details = rt.details }
  local ran, logged, answer = false, {}, nil
  rt.run = function(_, _, done) ran = true done({ passed = true }) end
  rt.confirm = function() return "run `bash tests/run.sh` in wt" end
  rt.preapproved, rt.details = nil, nil
  vim.cmd("tabnew")
  vim.bo.filetype = "azurecli-changes"
  local tab = vim.api.nvim_get_current_tabpage()
  TOOLS.call("run_tests", { work_item_id = 41 }, { main_win = function() end,
    log = function(l) logged[#logged + 1] = l end, confirm = CHAT.confirm }, function(t, e) answer = { t, e } end)
  local popup = vim.api.nvim_get_current_win()
  vim.wait(100)
  check("issue: the popup keeps the focus while the chat panel would follow",
    vim.api.nvim_win_is_valid(popup) and vim.api.nvim_get_current_win() == popup and answer == nil,
    vim.inspect({ answer, logged }))
  vim.wait(450)
  feed("y")
  vim.wait(200, function() return answer ~= nil end, 10)
  check("issue: y runs the tests, nothing declined", ran and answer and answer[2] == false
    and not table.concat(logged, "|"):find("declined", 1, true), vim.inspect({ answer, logged }))
  vim.wait(100)
  local panel = false
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.b[vim.api.nvim_win_get_buf(w)].azure_cli_chat then panel = true end
  end
  check("issue: the chat panel follows into the tab once it's answered", panel)
  for k, v in pairs(real) do rt[k] = v end
  vim.cmd("tabclose!")
  CHAT.hide()
end

-- Issue #30: a long command shown whole, o opens it to read or yank, and
-- only y / n / Esc / Tab / CR answer - a stray key neither answers nor
-- leaves, and typing can't carry over to the next question.
do
  local got = {}
  local details = { "Command:", "  " .. long_cmd }
  local win = UI.choose({ title = "Run?", lines = { "Run it?" }, buttons = { "Allow", "Deny" }, keys = { y = 1, n = 2 },
    details = details }, function(i) got[#got + 1] = i end)
  local dwin
  for _, w in ipairs(float_wins()) do
    if vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 1, false)[1] == "Command:" then dwin = w end
  end
  local drawn = dwin and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(dwin), 0, -1, false) or {}
  local fit = true
  for _, l in ipairs(drawn) do if vim.fn.strdisplaywidth(l) > vim.api.nvim_win_get_width(dwin) then fit = false end end
  check("#30 details: as tall as the wrapped command, every row inside the window", dwin and #drawn > 3
    and vim.api.nvim_win_get_height(dwin) == #drawn and fit, vim.inspect({ drawn, dwin and vim.api.nvim_win_get_height(dwin) }))
  feed("o")
  local fwin = vim.api.nvim_get_current_win()
  local shown = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  check("#30 o: all of it as it is, in a window of its own", fwin ~= win and vim.deep_equal(shown, details),
    vim.inspect(shown))
  feed("jyy")
  check("#30 o: yy there yanks the command whole", vim.fn.getreg('"') == "  " .. long_cmd .. "\n", vim.fn.getreg('"'))
  feed("q")
  vim.wait(50)
  check("#30 o: q goes back to the popup, still asking", vim.api.nvim_get_current_win() == win and #got == 0
    and not vim.api.nvim_win_is_valid(fwin))
  feed("y")
  vim.wait(100, function() return #got > 0 end, 10)
  check("#30 o: then y allows", is(got, 1), vim.inspect(got))
end
do
  local got, open = run("q", { arm_ms = 150 }, 250)
  check("#30 arm_ms: q is a stray key there, not cancel", #got == 0 and open, vim.inspect(got))
  for _, keys in ipairs({ ":", "q:", "<C-w>w", "<C-w>p", "Z", "ZZ", "@", "x", ":wq<CR>" }) do
    got, open = run(keys, { arm_ms = 150 }, 250)
    check("#30 stray " .. keys .. ": no answer, the popup stays", #got == 0 and open, vim.inspect(got))
  end
end
do
  local got = {}
  UI.choose({ title = "T", lines = { "x" }, buttons = { "Yes", "No" }, keys = { y = 1, n = 2 }, arm_ms = 150 },
    function(i) got[#got + 1] = i end)
  vim.wait(250)
  feed("xy")
  vim.wait(50)
  check("#30 arm_ms: a stray key, then y at once: nothing", #got == 0, vim.inspect(got))
  vim.wait(250)
  feed("y")
  vim.wait(100, function() return #got > 0 end, 10)
  check("#30 arm_ms: y after a pause answers", is(got, 1), vim.inspect(got))
end
do
  -- The report: keys typed on after one question was denied went on to deny
  -- the next one (run_tests).
  local CHAT = require("azure-cli.chat")
  local a, b
  CHAT.confirm("First?", function(yes) a = yes end)
  CHAT.confirm("Second?", function(yes) b = yes end)
  vim.wait(500)
  feed("n")
  vim.wait(20)  -- the second one opens
  local second = vim.api.nvim_get_current_win()
  feed("yyy")
  vim.wait(300)
  feed("x")
  vim.wait(150)
  feed("y")  -- past the second one's first moment, but the typing went on
  vim.wait(50)
  check("#30 the first denied, typing on doesn't answer the next", a == false and b == nil
    and vim.api.nvim_win_is_valid(second), vim.inspect({ a, b }))
  vim.wait(500)
  feed("y")
  vim.wait(100, function() return b ~= nil end, 10)
  check("#30 after a pause, y allows the next", b == true, tostring(b))
end
do
  -- An agent's long shell command through decide_permission: o shows it
  -- whole (it used to be cut, and its rows skipped).
  local RUN = require("azure-cli.chat.run")
  local long = "make build " .. long_cmd .. " && echo done"
  local yes
  RUN.decide_permission(nil, { tools = {}, text = "" }, { kind = "execute", title = "Bash", rawInput = { command = long } },
    function(y) yes = y end)
  vim.wait(500)
  feed("o")
  local shown = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  check("#30 a long Bash command: o shows it as it is", #shown == 1 and shown[1] == long, vim.inspect(shown))
  feed("q")
  vim.wait(50)
  feed("<Esc>")
  vim.wait(100, function() return yes ~= nil end, 10)
  check("#30 a long Bash command: <Esc> denies", yes == false, tostring(yes))
end
do
  -- #62: the #29 agent's command, the way Claude Code asks for it, again
  -- and again: allowed without a popup every time, once LuaJIT has
  -- compiled the look-only check too. One that writes still asks.
  local RUN = require("azure-cli.chat.run")
  local cmd = "R=origin/github-host; git grep -nE \"choosing|function M\\.(input|choose|text)\" $R -- "
    .. "lua/azure-cli/ui.lua lua/azure-cli/prompt.lua | sed 's/^origin\\/github-host://'; "
    .. "git show $R:lua/azure-cli/prompt.lua | sed -n 1,30p"
  local entry, asked = { tools = {}, text = "" }, nil
  for k = 1, 200 do
    local yes
    RUN.decide_permission(nil, entry, RUN.claude_tool({ tool_name = "Bash", input = { command = cmd } }),
      function(y) yes = y end)
    if yes ~= true then asked = k; break end
  end
  if asked then vim.wait(500); feed("<Esc>"); vim.wait(100) end
  check("#62 a look-only command with s/a\\/b// is allowed every time", asked == nil
    and (entry.tools[#entry.tools] or ""):find("(allowed: only looks)", 1, true) ~= nil,
    asked and ("asked on call " .. asked) or entry.tools[#entry.tools])
  local yes
  RUN.decide_permission(nil, entry, RUN.claude_tool({ tool_name = "Bash", input = { command = cmd .. " > out" } }),
    function(y) yes = y end)
  vim.wait(500)
  local popup = yes == nil
  feed("<Esc>")
  vim.wait(100, function() return yes ~= nil end, 10)
  check("#62 the same command writing to a file still asks", popup and yes == false, tostring(yes))
end

-- Approving a plan: three buttons, p lets it push.
do
  local PLAN = require("azure-cli.chat.plan")
  local real_load = PLAN.load
  PLAN.load = function(k) return { key = k, target = { work_item_id = 9 }, revisions = {}, threads = {} } end
  local got
  PLAN.ask_approval({ "wi-9" }, function(allow) got = allow end)
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
  check("approve: Approve, Approve and push, Cancel", text:find("Approve", 1, true)
    and text:find("let it push", 1, true) and text:find("Cancel", 1, true), text)
  check("approve #57: it says an existing branch gets no PR", text:find("existing branch", 1, true)
    and text:find("no PR", 1, true), text)
  vim.api.nvim_feedkeys("p", "x", false)
  vim.wait(100, function() return got ~= nil end, 10)
  check("approve: p approves and lets it push", got == true, tostring(got))
  got = "untouched"
  PLAN.ask_approval({ "wi-9" }, function(allow) got = allow end)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  vim.wait(100)
  check("approve: <Esc> approves nothing", got == "untouched")
  PLAN.load = real_load
end

-- Issue #55: answered, a popup gives the focus back to the window it was
-- opened from, in normal mode - not to the chat's input box, where the
-- keys typed next went out as messages. From screens with the chat panel
-- beside them, as the agents' popups come.
local CHAT55 = require("azure-cli.chat")
local RUN55 = require("azure-cli.chat.run")
local real_send, sent55 = RUN55.send, {}
RUN55.send = function(text) sent55[#sent55 + 1] = text or CHAT55._.input_text() end
local function screen55(ft)
  vim.cmd("tabnew")
  vim.bo.buftype, vim.bo.filetype = "nofile", ft
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "row 1", "row 2" })
  local w = vim.api.nvim_get_current_win()
  CHAT55.show(false)
  vim.wait(50)
  vim.api.nvim_set_current_win(w)
  return w
end
local function where55(w)
  return { same = vim.api.nvim_get_current_win() == w, mode = vim.api.nvim_get_mode().mode,
    buf = vim.api.nvim_buf_get_name(0), sent = #sent55 }
end
do
  local screen = screen55("azurecli-agents")
  local got
  CHAT55.confirm("The agent wants to run `git status`.", function(yes) got = yes end)
  vim.wait(500)
  feed("y")
  vim.wait(100, function() return got ~= nil end, 10)
  local at = where55(screen)
  check("#55 Agents screen: y allows, back on the screen in normal mode", got == true and at.same and at.mode == "n",
    vim.inspect(at))
  vim.g.azure_cli_t55 = nil
  feed(":let g:azure_cli_t55 = 1<CR>")
  check("#55 Agents screen: a : command typed next runs, nothing is sent", vim.g.azure_cli_t55 == 1 and #sent55 == 0,
    vim.inspect(sent55))
  vim.cmd("tabclose!")
end
do
  local screen = screen55("azurecli-workitems")
  local got
  CHAT55.confirm("The agent wants to push.", function(yes) got = yes end)
  vim.wait(500)
  feed("<Esc>")
  vim.wait(100, function() return got ~= nil end, 10)
  local at = where55(screen)
  check("#55 dashboard: <Esc> denies, back on the dashboard in normal mode", got == false and at.same
    and at.mode == "n" and at.sent == 0, vim.inspect(at))
  vim.cmd("tabclose!")
end
do
  local PLAN = require("azure-cli.chat.plan")
  local real_load = PLAN.load
  PLAN.load = function(k) return { key = k, target = { work_item_id = 9 }, revisions = {}, threads = {} } end
  local screen = screen55("azurecli-agents")
  local got
  PLAN.ask_approval({ "wi-9" }, function(allow) got = allow end)
  feed("a")
  vim.wait(100, function() return got ~= nil end, 10)
  local at = where55(screen)
  check("#55 plan approval: a approves, back on the Agents screen in normal mode", got == false and at.same
    and at.mode == "n", vim.inspect(at))
  PLAN.load = real_load
  vim.cmd("tabclose!")
end
do
  -- The window it was opened from closed while it asked: the screen beside
  -- the chat, never the chat.
  local screen = screen55("azurecli-agents")
  local fw = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
    { relative = "editor", row = 2, col = 2, width = 30, height = 3 })
  local got
  UI.choose({ lines = { "q?" }, buttons = { "Yes", "No" }, keys = { y = 1 } }, function(i) got = i end)
  pcall(vim.api.nvim_win_close, fw, true)
  feed("y")
  vim.wait(100, function() return got ~= nil end, 10)
  local at = where55(screen)
  check("#55 its window gone: back on the screen, not the chat", got == 1 and at.same and at.mode == "n"
    and not vim.b.azure_cli_chat, vim.inspect(at))
  vim.cmd("tabclose!")
end
do
  -- A question over an agent's conversation popup: that popup stays, and
  -- the focus comes back to it.
  local screen = screen55("azurecli-agents")
  CHAT55.conversation("wi-55", { label = "#55" })
  local log = CHAT55.popup("wi-55")
  local got
  CHAT55.confirm("The agent wants to run `ls`.", function(yes) got = yes end)
  vim.wait(500)
  feed("y")
  vim.wait(100, function() return got ~= nil end, 10)
  vim.wait(50)
  local pw = CHAT55.popup_wins()
  check("#55 conversation popup: still open after the question, the focus back in it", got == true and pw
    and vim.api.nvim_win_is_valid(log) and vim.api.nvim_get_current_win() == log
    and vim.api.nvim_get_mode().mode == "n", vim.inspect({ got, pw and true, vim.api.nvim_get_current_win() == log }))
  vim.api.nvim_set_current_win(screen)
  vim.wait(50)
  vim.cmd("tabclose!")
end

-- Last, once this script has returned to the main loop - startinsert only
-- takes effect there: from insert mode, out of it while the popup asks,
-- back in after, in the same buffer.
local function finish()
  io.stdout:write((fails == 0 and "all confirm tests passed" or (fails .. " confirm test(s) failed")) .. "\n")
  vim.cmd(fails == 0 and "qa!" or "cq!")
end
-- Each: `setup()` puts the cursor somewhere in insert mode (returning the
-- window), a popup opens, `during()` runs while it asks, y answers,
-- `after(win, got, mode_in)` checks.
local function in_insert(setup, during, after, nxt)
  local win = setup()
  vim.cmd("startinsert")
  vim.defer_fn(function()
    local got, mode_in
    UI.choose({ lines = { "q?" }, buttons = { "Yes", "No" }, keys = { y = 1 } }, function(i) got = i end)
    if during then during() end
    vim.defer_fn(function()
      mode_in = vim.api.nvim_get_mode().mode
      vim.api.nvim_input("y")
      vim.defer_fn(function()
        after(win, got, mode_in)
        vim.cmd("stopinsert")
        vim.defer_fn(nxt, 50)
      end, 100)
    end, 100)
  end, 100)
end
local ebuf
in_insert(function()
  vim.cmd("enew")
  ebuf = vim.api.nvim_get_current_buf()
  return vim.api.nvim_get_current_win()
end, nil, function(_, got, mode_in)
  local mode_after = vim.api.nvim_get_mode().mode
  check("insert mode: left while it asks, back after, in the same buffer", got == 1 and mode_in == "n"
    and mode_after == "i" and vim.api.nvim_get_current_buf() == ebuf, vim.inspect({ got, mode_in, mode_after }))
end, function()
  -- #55: typing in the chat's input box when it asks - back there, but in
  -- normal mode: what you type next isn't a message.
  local screen
  in_insert(function()
    screen = screen55("azurecli-agents")
    CHAT55.show(true)
    vim.wait(50)
    return vim.api.nvim_get_current_win()
  end, nil, function(input, got)
    local at = where55(input)
    check("#55 from the chat's input box in insert mode: back there in normal mode", got == 1 and at.same
      and at.mode == "n" and vim.b.azure_cli_chat == true and at.sent == 0, vim.inspect(at))
  end, function()
    vim.cmd("tabclose!")
    -- #55: its window closed while it asked - insert mode doesn't carry
    -- over to wherever the cursor lands.
    local fw
    in_insert(function()
      screen = screen55("azurecli-agents")
      fw = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
        { relative = "editor", row = 2, col = 2, width = 30, height = 3 })
      return fw
    end, function() pcall(vim.api.nvim_win_close, fw, true) end, function(_, got)
      local at = where55(screen)
      check("#55 from insert mode in a window closed while it asks: the screen, normal mode", got == 1
        and at.same and at.mode == "n" and at.sent == 0, vim.inspect(at))
    end, function()
      vim.cmd("tabclose!")
      RUN55.send = real_send
      finish()
    end)
  end)
end)
