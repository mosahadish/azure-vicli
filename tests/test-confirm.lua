-- test-confirm.lua: ui.lua's yes/no popup (UI.confirm) in a real Neovim -
-- its layout, and every way out: y, <CR> on the focused button, <Tab> then
-- <CR>, n / q / <Esc>, leaving the window; the answer comes once.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-confirm.lua
local fails = 0
local function check(name, ok, detail)
  if ok then print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail and ("\n     " .. tostring(detail)) or ""))
  end
end
local UI = require("azure-cli.ui")

local lines, hls, width = UI.confirm_lines({ "PR #7  Fix it", "Build: failed" }, "Re-queue", "Cancel", true)
check("lines: the body, then the buttons, then the keys", lines[1] == " PR #7  Fix it" and lines[3] == ""
  and lines[4] == " " .. "  Re-queue  " .. "   " .. "  Cancel  " and lines[6]:find("y re-queue", 1, true), vim.inspect(lines))
check("lines: the focused button stands out", hls[1][4] == "AzureCliButtonActive" and hls[2][4] == "AzureCliButton"
  and lines[4]:sub(hls[1][2] + 1, hls[1][3]) == "  Re-queue  " and lines[4]:sub(hls[2][2] + 1, hls[2][3]) == "  Cancel  ")
local _, hls_no = UI.confirm_lines({}, "Yes", "No", false)
check("lines: focus on no", hls_no[1][4] == "AzureCliButton" and hls_no[2][4] == "AzureCliButtonActive")
check("lines: wide enough for its longest line", width >= vim.fn.strdisplaywidth(lines[6]))

-- Opens the popup, presses `keys`, returns the answers it gave.
local function answers(keys, opts)
  local got = {}
  local main = vim.api.nvim_get_current_win()
  local win = UI.confirm(vim.tbl_extend("force", { title = "Sure?", lines = { "x" } }, opts or {}), function(a)
    got[#got + 1] = a
  end)
  if vim.api.nvim_get_current_win() ~= win then return { "not focused" } end
  if keys == "leave" then vim.api.nvim_set_current_win(main)
  else vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false) end
  vim.wait(200, function() return #got > 0 end, 10)
  vim.wait(50)
  if vim.api.nvim_win_is_valid(win) then got[#got + 1] = "still open" end
  return got
end
local function is(got, want) return #got == 1 and got[1] == want end

check("y: yes", is(answers("y"), true))
check("<CR>: the focused button - yes by default", is(answers("<CR>"), true))
check("<CR> with default = no: no", is(answers("<CR>", { default = "no" }), false))
check("<Tab> then <CR>: the other button", is(answers("<Tab><CR>"), false))
check("l h then <CR>: back where it was", is(answers("lh<CR>"), true))
check("n: no", is(answers("n"), false))
check("q: no", is(answers("q"), false))
check("<Esc>: no", is(answers("<Esc>"), false))
local left = answers("leave")
check("leaving the popup: no, once, and it's closed", is(left, false), vim.inspect(left))

print(fails == 0 and "all confirm tests passed" or (fails .. " confirm test(s) failed"))
vim.cmd(fails == 0 and "qa!" or "cq!")
