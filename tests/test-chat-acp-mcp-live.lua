-- test-chat-acp-mcp-live.lua: manual check that azure-vicli's tools reach
-- a REAL `copilot --acp` session - needs a locally authenticated Copilot
-- CLI and makes one small real request, so it isn't in tests/run.sh
-- (tests/test-chat-acp.lua covers the same path against a fake agent).
--
-- Copilot's ACP (1.0.92) rejects a stdio MCP server ("Rejecting
-- non-http/sse MCP server ... from client"), so send_acp gives an agent
-- that advertises http azure-cli.py --mcp-http instead. A failure here
-- with "no such tool" in the answer means Copilot still didn't get it:
-- check ~/.copilot/logs/process-*.log for what it said about the server.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-acp-mcp-live.lua
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
CHAT.new_chat(true)

local done
CHAT.send("Call the azure-vicli current_view tool and tell me exactly what \"screen\" it reports, nothing else.",
  { view_win = win, on_done = function() done = true end })
local st = STATE.chat
local entry = st.entries[#st.entries]
local ok = vim.wait(60000, function() return done end, 50)
check("the message answers", ok and entry.status == "done", vim.inspect(entry))

check("Copilot called current_view", entry ~= nil and #entry.tools > 0, entry and vim.inspect(entry.tools))
check("and reported a screen", entry ~= nil and entry.text ~= "" and not entry.text:lower():find("no such tool"), entry and entry.text)
print("answer: " .. tostring(entry and entry.text))

CHAT.new_chat(true)
if fails > 0 then
  print(fails .. " chat-acp-mcp-live test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-acp-mcp-live tests passed")
end
