-- test-chat-insert-send.lua: in the chat's input box, <CR> while typing
-- sends (as the hint says) and leaves insert mode; <C-j> (and <S-CR> where
-- the terminal reports it) breaks the line instead; <C-s> still sends; and
-- with the completion menu open <CR> picks the entry, it doesn't send.
-- And while the agent answers (issue #29), <CR> - typing or not - queues
-- the message instead, and the box is left as after a send.
-- Needs the main loop (real input events, as in test-editor-mode.lua), so:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-chat-insert-send.lua"
require("azure-cli").setup({})
local CHAT = require("azure-cli.chat")
local sent = {}
local RUN = require("azure-cli.chat.run")
local real_send = RUN.send
local STATE = require("azure-cli.state")
RUN.send = function()
  sent[#sent + 1] = CHAT._.input_text()
  vim.api.nvim_buf_set_lines(CHAT._.input_buf(), 0, -1, false, {})
end
_G.TEST_COMPLETE = function()
  vim.fn.complete(vim.fn.col("."), { "alpha", "beta" })
  return ""
end
vim.o.completeopt = "menuone,noinsert"

local function finish(ok, why)
  io.stdout:write((ok and "CHAT-INSERT-SEND-OK" or ("CHAT-INSERT-SEND-FAIL: " .. why)) .. "\n")
  vim.cmd(ok and "qa!" or "cq!")
end
local function lines() return vim.api.nvim_buf_get_lines(CHAT._.input_buf(), 0, -1, false) end
local function mode() return vim.api.nvim_get_mode().mode end

-- Each step types `keys`, then `check()` after a moment returns an error or nil.
local steps = {
  { keys = "a<C-j>b", check = function()
    if #sent > 0 then return "<C-j> sent the message" end
    if not vim.deep_equal(lines(), { "a", "b" }) then return "<C-j> gave " .. vim.inspect(lines()) end
    if mode() ~= "i" then return "<C-j> left insert mode" end
  end },
  { clear = true, keys = "hi<CR>", check = function()
    if sent[1] ~= "hi" then return "<CR> while typing sent " .. vim.inspect(sent) end
    if mode() ~= "n" then return "<CR> left the box in mode " .. mode() end
  end },
  { keys = "iyo<C-s>", check = function()
    if sent[2] ~= "yo" then return "<C-s> sent " .. vim.inspect(sent) end
  end },
  { keys = "i<C-r>=v:lua.TEST_COMPLETE()<CR>", check = function()
    if vim.fn.pumvisible() ~= 1 then return "the completion menu didn't open" end
  end },
  { keys = "<CR>", check = function()
    if #sent ~= 2 then return "<CR> in the completion menu sent " .. vim.inspect(sent[3]) end
    if not table.concat(lines(), "\n"):find("alpha", 1, true) then return "<CR> didn't pick the entry: " .. vim.inspect(lines()) end
  end },
  -- The agent answering: the real send queues what's typed.
  { clear = true, setup = function()
    RUN.send = real_send
    STATE.chat.running = { entry = { started = os.time() } }
  end, keys = "<Esc>iwhile busy<CR>", check = function()
    local q = STATE.chat.queue or {}
    if #q ~= 1 or q[1].text ~= "while busy" then return "<CR> while busy queued " .. vim.inspect(q) end
    if #sent ~= 2 then return "<CR> while busy sent it" end
    if table.concat(lines(), "") ~= "" then return "the box kept " .. vim.inspect(lines()) end
    if mode() ~= "n" then return "<CR> while busy left the box in mode " .. mode() end
  end },
  { keys = "iand again<Esc><CR>", check = function()
    local q = STATE.chat.queue or {}
    if #q ~= 2 or q[2].text ~= "and again" then return "<CR> in normal mode while busy queued " .. vim.inspect(q) end
    if mode() ~= "n" then return "normal-mode <CR> left mode " .. mode() end
    STATE.chat.running, STATE.chat.queue = nil, nil
  end },
}

CHAT.show(true)
vim.defer_fn(function()
  local win = vim.fn.bufwinid(CHAT._.input_buf())
  if win == -1 then return finish(false, "the input box isn't showing") end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_set_lines(CHAT._.input_buf(), 0, -1, false, {})
  vim.cmd("startinsert")
  local i = 0
  local function step()
    i = i + 1
    if i > #steps then return finish(true) end
    if steps[i].clear then vim.api.nvim_buf_set_lines(CHAT._.input_buf(), 0, -1, false, {}) end
    if steps[i].setup then steps[i].setup() end
    vim.api.nvim_input(steps[i].keys)
    vim.defer_fn(function()
      local err = steps[i].check()
      if err then return finish(false, err) end
      step()
    end, 150)
  end
  vim.defer_fn(step, 100)
end, 200)
