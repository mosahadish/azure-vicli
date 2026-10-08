-- test-chat-acp.lua: agent.acp (chat/init.lua's send_acp + chat/acp.lua)
-- keeps one ACP session warm across messages, and - for an agent that
-- only takes http MCP servers, as Copilot's --acp does - hands it
-- azure-cli.py --mcp-http so azure-vicli's tools still reach it.
--
-- tests/fake-acp-agent.py stands in for `copilot --acp`: it advertises
-- http/sse MCP only, calls tools/list and current_view over the http
-- server it gets at session/new, and reports that, its pid and a turn
-- counter in every answer; --marker-file records every pid it ever had.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-acp.lua
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local plugin_root = vim.fn.getcwd()
local marker = vim.fn.tempname()
local py = vim.fn.executable("python3") == 1 and "python3" or "python"

require("azure-cli").setup({ chat = { agent = {
  label = "Fake ACP", acp = true, timeout_seconds = 20,
  cmd = { py, plugin_root .. "/tests/fake-acp-agent.py", "--marker-file", marker },
} } })

local CHAT = require("azure-cli.chat")
local STATE = require("azure-cli.state")
local win = vim.api.nvim_get_current_win()
CHAT.new_chat(true)

local function send_and_wait(text)
  local done
  CHAT.send(text, { view_win = win, on_done = function() done = true end })
  local entry = STATE.chat.entries[#STATE.chat.entries]
  local ok = vim.wait(20000, function() return done end, 20)
  if not ok then return nil, "no answer to " .. vim.inspect(text) .. ": " .. vim.inspect(entry) end
  return entry
end

local e1, err1 = send_and_wait("one")
check("turn 1 answers", e1 ~= nil and e1.status == "done", err1)
check("azure-vicli's tools reached the agent over http", e1 ~= nil and e1.text:find("current_view ok: True", 1, true) ~= nil,
  e1 and (e1.text .. " " .. vim.inspect(e1.tools)))
local pid1 = e1 and e1.text:match("pid (%d+)")

local pj = STATE.chat.persistent_job
check("an ACP connection is tracked", pj ~= nil and pj.acp == true and pj.job ~= nil)

local e2, err2 = send_and_wait("two")
check("turn 2 answers", e2 ~= nil and e2.status == "done", err2)
check("turn 2 is the same session's turn 2", e2 ~= nil and e2.text:match("^turn 2,") ~= nil, e2 and e2.text)
check("turn 2 ran on the same process", pid1 ~= nil and pid1 == (e2 and e2.text:match("pid (%d+)")), e2 and e2.text)

local count = 0
for _ in io.lines(marker) do count = count + 1 end
check("only one agent process was ever started", count == 1, count)

CHAT.new_chat(true)
vim.wait(2000, function() return vim.fn.jobwait({ pj.job }, 0)[1] ~= -1 end, 20)
check("a new chat stops the ACP process", vim.fn.jobwait({ pj.job }, 0)[1] ~= -1)
check("and forgets it", STATE.chat.persistent_job == nil)

local e3, err3 = send_and_wait("three")
check("the next chat starts a fresh session", e3 ~= nil and e3.text:match("^turn 1,") ~= nil, err3 or (e3 and e3.text))
check("its tools reach it too (the http server is reused)", e3 ~= nil and e3.text:find("current_view ok: True", 1, true) ~= nil,
  e3 and e3.text)
CHAT.new_chat(true)
os.remove(marker)

if fails > 0 then
  print(fails .. " chat-acp test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-acp tests passed")
end
