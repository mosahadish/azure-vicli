-- test-chat-acp-mcp-live.lua: manual check of whether azure-vicli's MCP
-- server is reachable from a real `copilot --acp` session yet.
--
-- As of Copilot CLI 1.0.92 it isn't: its own `initialize` response only
-- advertises `mcpCapabilities: {http, sse}` (no stdio), and its log says
-- so explicitly - "[rust:acp::mcp_servers] Rejecting non-http/sse MCP
-- server \"azure-vicli\" from client" (see ~/.copilot/logs/process-*.log
-- after a run). azure-vicli's MCP server is stdio-only, so send_acp's
-- `mcpServers` entry (name + array-shaped env, chat/init.lua's
-- acp_mcp_server - fixed from an earlier shape Copilot silently
-- tolerated rather than erroring on) is correctly built but never
-- connected; docs/chat.md's "Keeping the agent warm" section explains
-- this to users of `acp = true`.
--
-- This test currently asserts that known limitation rather than the
-- tool actually working, so a pass here isn't "MCP works", it's "still
-- rejected the same way" - a future Copilot version accepting the
-- server would make the second check below FAIL, the signal to revisit
-- this and update the docs.
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

local no_tool_text = entry and entry.text:lower():find("azure%-vicli") and entry.text:lower():find("tool")
check("Copilot still reports no azure-vicli tool (the known ACP limitation)", entry and no_tool_text ~= nil, entry and entry.text)
check("...and so never actually called it", entry and #entry.tools == 0, entry and vim.inspect(entry.tools))

CHAT.new_chat(true)
if fails > 0 then
  print(fails .. " chat-acp-mcp-live test(s) FAILED (if Copilot's ACP now accepts a stdio MCP server, update docs/chat.md)")
  vim.cmd("cquit 1")
else
  print("all chat-acp-mcp-live tests passed (azure-vicli's MCP server is still rejected over ACP, as documented)")
end
