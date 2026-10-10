-- test-confirm.lua: ui.lua's question popup (UI.choose, UI.confirm) in a
-- real Neovim - its layout, every way out, the moment keys don't count yet,
-- the details above it, insert mode, ui.confirm = "select" - and the two
-- places that ask through it: the chat's "may the agent ...?" and approving
-- a plan. Needs the main loop (insert mode, real input), so not nvim -l:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-confirm.lua"
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
  and stacked[3] == "   Approve, and let it push without asking  " and shls[2][4] == "AzureCliButtonActive",
  vim.inspect(stacked))

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

-- Last, once this script has returned to the main loop - startinsert only
-- takes effect there: from insert mode, out of it while the popup asks,
-- back in after, in the same buffer.
local function finish()
  io.stdout:write((fails == 0 and "all confirm tests passed" or (fails .. " confirm test(s) failed")) .. "\n")
  vim.cmd(fails == 0 and "qa!" or "cq!")
end
vim.cmd("enew")
local ebuf = vim.api.nvim_get_current_buf()
vim.cmd("startinsert")
vim.defer_fn(function()
  local got, mode_in
  UI.choose({ lines = { "q?" }, buttons = { "Yes", "No" }, keys = { y = 1 } }, function(i) got = i end)
  vim.defer_fn(function()
    mode_in = vim.api.nvim_get_mode().mode
    vim.api.nvim_input("y")
    vim.defer_fn(function()
      local mode_after = vim.api.nvim_get_mode().mode
      check("insert mode: left while it asks, back after, in the same buffer", got == 1 and mode_in == "n"
        and mode_after == "i" and vim.api.nvim_get_current_buf() == ebuf, vim.inspect({ got, mode_in, mode_after }))
      finish()
    end, 100)
  end, 100)
end, 100)
