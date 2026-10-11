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

-- Permission requests: a read never asks; an edit asks (the popup, stubbed
-- here to answer Deny) - except while a /plan message runs, when it's
-- refused without asking.
local UI = require("azure-cli.ui")
local real_choose, asked = UI.choose, {}
UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; cb(2) end
local e4, err4 = send_and_wait("PERMS")
check("a read is allowed without asking", e4 ~= nil and e4.text:find("read=yes", 1, true) ~= nil, err4 or (e4 and e4.text))
check("an edit asks", #asked == 1 and asked[1]:find("edit", 1, true) ~= nil, vim.inspect(asked))
check("and gets the answer given", e4 ~= nil and e4.text:find("edit=no", 1, true) ~= nil, e4 and e4.text)
asked = {}
local e5, err5 = send_and_wait("/plan PERMS")
check("planning: a read is allowed", e5 ~= nil and e5.text:find("read=yes", 1, true) ~= nil, err5 or (e5 and e5.text))
check("planning: an edit is refused", e5 ~= nil and e5.text:find("edit=no", 1, true) ~= nil, e5 and e5.text)
check("planning: nothing asked", #asked == 0, vim.inspect(asked))

-- After the plan is approved: an edit to a file its Files section lists,
-- inside its worktree, goes through; one it doesn't list still asks.
local PLAN, TF = require("azure-cli.chat.plan"), require("azure-cli.chat.tools_fix")
PLAN.save({ key = "wi-3001", status = "approved", target = { work_item_id = 3001 }, threads = {},
  revisions = { { at = os.time(), by = "agent", markdown = "## Goal\nx\n\n## Files\n- `src/a.py` - throttle\n" } } })
local wt = TF.root() .. "/widgets-wi3001"
asked = {}
local e6, err6 = send_and_wait("EDITPATH=" .. wt .. "/src/a.py EDITPATH=" .. wt .. "/src/b.py")
check("approved plan: a planned file is edited without asking",
  e6 ~= nil and e6.text:find("src/a.py]=yes", 1, true) ~= nil, err6 or (e6 and e6.text))
check("approved plan: an unplanned file asks", #asked == 1 and asked[1]:find("b.py", 1, true) ~= nil, vim.inspect(asked))
PLAN.save({ key = "wi-3001", status = "draft", target = { work_item_id = 3001 }, threads = {},
  revisions = { { at = os.time(), by = "agent", markdown = "## Files\n- `src/a.py`\n" } } })
asked = {}
send_and_wait("EDITPATH=" .. wt .. "/src/a.py")
check("a plan not approved yet: a planned file still asks", #asked == 1, vim.inspect(asked))
os.remove(PLAN.root() .. "/wi-3001.json")
UI.choose = real_choose

CHAT.new_chat(true)
os.remove(marker)

if fails > 0 then
  print(fails .. " chat-acp test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-acp tests passed")
end
