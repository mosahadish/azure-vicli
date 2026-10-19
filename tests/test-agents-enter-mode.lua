-- test-agents-enter-mode.lua: <CR> on an Agents row opens the row's agent
-- and leaves you in normal mode wherever the focus lands (issue #118) -
-- on a row with a plan (its plan's tab, the chat panel opened on its
-- conversation) and on one before it has planned (its conversation in the
-- popup). Only i types: i there goes into the chat's input box, insert
-- mode. A stray startinsert only shows once the main loop runs, so this
-- types real input (as test-chat-insert-send.lua does):
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-agents-enter-mode.lua"
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
require("azure-cli.config").setup({ chat = { agent = { label = "fake", cmd = { "true" } } } })
local CHAT = require("azure-cli.chat")
local PLAN = require("azure-cli.chat.plan")
local AV = require("azure-cli.chat.agents_view")
local STORE = require("azure-cli.chat.store")

local function finish(ok, why)
  io.stdout:write((ok and "AGENTS-ENTER-MODE-OK" or ("AGENTS-ENTER-MODE-FAIL: " .. why)) .. "\n")
  vim.cmd(ok and "qa!" or "cq!")
end
local function mode() return vim.api.nvim_get_mode().mode end

-- wi-9001: a plan and its agent's conversation; wi-9002: an agent that
-- hasn't planned yet.
local md = "# T\n\n## Goal\nx\n\n## Approach\nx\n\n## Files\n- `a`\n\n## Risks\nx\n\n## Test plan\nx\n\n## Open questions\nNone"
PLAN.save({ key = "wi-9001", target = { work_item_id = 9001 }, title = "Plan 9001", status = "draft",
  revisions = { { text = md, by = "agent", at = os.time() } }, threads = {}, created = os.time() })
vim.fn.writefile(vim.split(md, "\n"), PLAN.path("wi-9001"))
for _, id in ipairs({ 9001, 9002 }) do
  local c = CHAT.conversation("wi-" .. id, { target = { work_item_id = id }, label = "#" .. id })
  c.entries = { { role = "you", text = "/plan #" .. id }, { role = "agent", text = "PLANNING-" .. id, status = "done" } }
  STORE.save({ id = c.conv_id, created = c.created, entries = c.entries, plan = id == 9001 and "wi-9001" or nil })
end

local av
local function to_row(label)
  vim.api.nvim_set_current_tabpage(av.tab)
  vim.api.nvim_set_current_win(av.win)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(av.buf, 0, -1, false)) do
    if l:find(label, 1, true) then vim.api.nvim_win_set_cursor(av.win, { i, 0 }) return true end
  end
end

-- The first / last line of the screen that's an agent's row.
local function edge_row(last)
  local at
  for l in pairs(av.rows) do
    if not at or (last and l > at) or (not last and l < at) then at = l end
  end
  return at
end
local function cursor_on(want, what)
  local l = vim.api.nvim_win_get_cursor(av.win)[1]
  if l ~= want then return what .. " went to line " .. l .. ", not the row on " .. tostring(want) end
end

-- Each step runs `before`, then - once what that scheduled has run (the
-- panel following into a tab moves the focus) - `at` (the row to type
-- on), types `keys`, and `check()` a moment later returns an error or nil.
local steps = {
  -- gg / G: the first / last agent, past the group headers (#123).
  { at = "#9001", keys = "G", check = function() return cursor_on(edge_row(true), "G") end },
  { keys = "gg", check = function()
    if edge_row(false) == 1 then return "line 1 is a row: no header to test gg past" end
    return cursor_on(edge_row(false), "gg")
  end },
  { keys = "2G", check = function() return cursor_on(edge_row(true), "2G") end },
  { keys = "1G", check = function() return cursor_on(edge_row(false), "1G") end },
  { at = "#9001", keys = "<CR>",
    check = function()
      local v = PLAN.current()
      if not (v and v.key == "wi-9001" and vim.api.nvim_get_current_tabpage() == v.tab) then
        return "<CR> on #9001's row didn't open its plan"
      end
      if mode() ~= "n" then return "<CR> on a row with a plan left the mode " .. mode() .. ", not normal" end
      if vim.api.nvim_get_current_win() ~= v.plan_win then return "the focus isn't on the plan" end
      local w = require("azure-cli.state").chat.wins[v.tab]
      if not (w and vim.api.nvim_win_is_valid(w.log)) then return "the chat panel didn't open on the plan's conversation" end
    end },
  -- i on the plan: the chat's input box, typing.
  { keys = "i", check = function()
    if mode() ~= "i" then return "i on the plan left the mode " .. mode() end
    if not vim.endswith(vim.api.nvim_buf_get_name(0), "azure-cli://chat-input") then
      return "i on the plan didn't go into the chat's input: " .. vim.api.nvim_buf_get_name(0)
    end
  end },
  { before = function()
      vim.cmd("stopinsert")
      vim.cmd("tabclose")
    end, at = "#9002", keys = "<CR>", check = function()
      local p = CHAT.popup_wins()
      if not (p and p.key == "wi-9002") then return "<CR> on a row without a plan didn't open its conversation" end
      if mode() ~= "n" then return "<CR> on a row without a plan left the mode " .. mode() .. ", not normal" end
      if vim.api.nvim_get_current_win() ~= p.log then return "the focus isn't on the popup's conversation" end
    end },
  -- i in the popup: its own input box, typing (the chat's focus_input).
  { keys = "i", check = function()
    local p = CHAT.popup_wins()
    if mode() ~= "i" or not p or vim.api.nvim_get_current_win() ~= p.input then
      return "i in the popup left the mode " .. mode() .. " in " .. vim.api.nvim_buf_get_name(0)
    end
  end },
  -- i on the Agents screen itself: the main chat's input.
  { before = function()
      vim.cmd("stopinsert")
      CHAT.hide()
      vim.wait(200, function() return CHAT.popup_wins() == nil end, 10)
    end, at = "#9001", keys = "i", check = function()
      if mode() ~= "i" or not vim.endswith(vim.api.nvim_buf_get_name(0), "azure-cli://chat-input") then
        return "i on the Agents screen left the mode " .. mode() .. " in " .. vim.api.nvim_buf_get_name(0)
      end
    end },
}

AV.open()
vim.defer_fn(function()
  av = AV.current()
  if not av then return finish(false, "the Agents screen didn't open") end
  local i = 0
  local function step()
    i = i + 1
    if i > #steps then return finish(true) end
    if steps[i].before then steps[i].before() end
    vim.defer_fn(function()
      if steps[i].at and not to_row(steps[i].at) then return finish(false, "no " .. steps[i].at .. " row on the Agents screen") end
      vim.api.nvim_input(steps[i].keys)
      vim.defer_fn(function()
        local err = steps[i].check()
        if err then return finish(false, err) end
        step()
      end, 400)
    end, 200)
  end
  step()
end, 300)
