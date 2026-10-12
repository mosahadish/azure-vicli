-- test-keys-palette.lua: the action palette (keys.lua's M.palette, g.) in a
-- real Neovim - binding a screen's keys binds its palette too, the palette
-- lists that buffer's normal-mode actions, and the one you pick runs in the
-- window you opened it from.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-keys-palette.lua
local fails = 0
local function check(name, ok, detail)
  if ok then print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail and ("\n     " .. tostring(detail)) or ""))
  end
end

require("azure-cli").setup({})
local KEYS = require("azure-cli.keys")

local function maps(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do out[m.lhs] = m end
  return out
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local win = vim.api.nvim_get_current_win()
local ran = {}
KEYS.bind(buf, "agents", "open", function() ran[#ran + 1] = { "open", vim.api.nvim_get_current_win() } end,
  { desc = "the row's plan" })
KEYS.bind(buf, "agents", "approve", function() ran[#ran + 1] = { "approve" } end, { desc = "approve its plan" })
KEYS.bind(buf, "agents", "approve", function() end, { desc = "approve the selected", mode = "x" })
KEYS.bind(buf, "agents", "refresh", function() ran[#ran + 1] = { "refresh" } end)

check("binding a screen's key binds its palette", maps(buf)["g."] ~= nil, vim.inspect(vim.tbl_keys(maps(buf))))

-- The palette offers each normal-mode action once, by description and key.
local offered
local pick
local real_select = vim.ui.select
vim.ui.select = function(items, opts, cb)
  offered = {}
  for _, it in ipairs(items) do offered[#offered + 1] = opts.format_item(it) end
  for i, it in ipairs(items) do
    if pick and opts.format_item(it):find(pick, 1, true) then return cb(it, i) end
  end
  cb(nil)
end

-- Opened from another window (as a picker's float would be), it still runs
-- the action back in the screen's window.
pick = "the row's plan"
local other = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
  { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
vim.api.nvim_set_current_win(win)
KEYS.palette(buf)
vim.api.nvim_set_current_win(other)
vim.wait(500, function() return #ran > 0 end)
check("the palette lists every normal-mode action, once", offered and #offered == 3
  and offered[1] == "the row's plan  (<CR>)" and offered[2] == "approve its plan  (gA)"
  and offered[3] == "refresh  (r)", vim.inspect(offered))
check("the chosen action runs, in the screen's window", ran[1] and ran[1][1] == "open" and ran[1][2] == win,
  vim.inspect(ran))
pcall(vim.api.nvim_win_close, other, true)

-- Cancelling runs nothing.
ran, pick = {}, nil
KEYS.palette(buf)
vim.wait(100)
check("cancelling runs nothing", #ran == 0)

-- Another buffer has its own list.
local buf2 = vim.api.nvim_create_buf(false, true)
KEYS.bind(buf2, "plan", "approve", function() end, { desc = "approve the plan" })
KEYS.palette(buf2)
check("each buffer lists its own actions", offered and #offered == 1 and offered[1] == "approve the plan  (gA)",
  vim.inspect(offered))

-- `?` names the palette key; unbinding it drops both.
local help = table.concat(KEYS.help_lines("agents", "Agents keys", { { "open", "the row's plan" } }), "\n")
check("? lists the palette", help:find("g.          every action here, searchable", 1, true) ~= nil, help)
require("azure-cli").setup({ keys = { plan = { palette = false } } })
local buf3 = vim.api.nvim_create_buf(false, true)
KEYS.bind(buf3, "plan", "approve", function() end)
check("palette = false: no palette key", maps(buf3)["g."] == nil)
help = table.concat(KEYS.help_lines("plan", "Plan keys", { { "approve", "approve" } }), "\n")
check("palette = false: not in ?", not help:find("searchable", 1, true), help)

vim.ui.select = real_select
print(fails == 0 and "all palette tests passed" or (fails .. " palette test(s) failed"))
vim.cmd(fails == 0 and "qa!" or "cq!")
