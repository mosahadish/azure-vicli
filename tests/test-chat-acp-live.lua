-- test-chat-acp-live.lua: a manual, not-automated smoke test for
-- agent.acp (chat/init.lua's send_acp + chat/acp.lua) against a REAL
-- `copilot --acp` - needs a locally authenticated Copilot CLI and makes
-- two small real requests, so it isn't wired into tests/run.sh. Run by
-- hand after touching the ACP code:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-acp-live.lua
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

require("azure-cli").setup({ chat = { agent = {
  label = "Copilot (ACP)", acp = true, timeout_seconds = 60,
  cmd = { "copilot", "--acp" },
} } })

local CHAT = require("azure-cli.chat")
local STATE = require("azure-cli.state")
local win = vim.api.nvim_get_current_win()
CHAT.new_chat(true) -- don't replay an older saved conversation into Copilot

local function send_and_wait(text)
  local done
  CHAT.send(text, { view_win = win, on_done = function() done = true end })
  local st = STATE.chat
  local entry = st.entries[#st.entries]
  local ok = vim.wait(60000, function() return done end, 50)
  if not ok then return nil, "no answer to " .. vim.inspect(text) .. ": " .. vim.inspect(entry) end
  return entry
end

local e1, err1 = send_and_wait("Reply with exactly: PONG-ONE (nothing else)")
check("turn 1 answers", e1 ~= nil and e1.status == "done", err1)
check("turn 1 says PONG-ONE", e1 ~= nil and e1.text:find("PONG%-ONE") ~= nil, e1 and e1.text)

local pj = STATE.chat.persistent_job
check("an ACP connection is tracked", pj ~= nil and pj.acp == true and pj.job ~= nil)
check("it's alive", pj ~= nil and vim.fn.jobwait({ pj.job }, 0)[1] == -1)
local job1 = pj and pj.job

local e2, err2 = send_and_wait("Reply with exactly: PONG-TWO (nothing else)")
check("turn 2 answers", e2 ~= nil and e2.status == "done", err2)
check("turn 2 says PONG-TWO", e2 ~= nil and e2.text:find("PONG%-TWO") ~= nil, e2 and e2.text)
check("turn 2 reused the same ACP connection", STATE.chat.persistent_job ~= nil and STATE.chat.persistent_job.job == job1)

CHAT.new_chat(true)
vim.wait(5000, function() return vim.fn.jobwait({ job1 }, 0)[1] ~= -1 end, 50)
check("a new chat stops the ACP process", vim.fn.jobwait({ job1 }, 0)[1] ~= -1)
check("and forgets it", STATE.chat.persistent_job == nil)

if fails > 0 then
  print(fails .. " chat-acp-live test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-acp-live tests passed")
end
