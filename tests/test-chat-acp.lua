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
-- (in a plan's own conversation: the main chat's /plan starts an agent)
local pc = CHAT.conversation("wi-9", { label = "#9", target = { work_item_id = 9 } })
local pdone
CHAT.send("/plan PERMS", { conv = pc, view_win = win, on_done = function() pdone = true end })
vim.wait(20000, function() return pdone end, 20)
local e5, err5 = pc.entries[#pc.entries], (not pdone) and vim.inspect(pc.entries) or nil
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
check("saying it isn't in the plan, and why", #asked == 1 and asked[1]:find("doesn't include", 1, true) ~= nil
  and asked[1]:find("Why: I need b.py for the shared helper.", 1, true) ~= nil, vim.inspect(asked))
check("denied: not added to the plan", not (PLAN.load("wi-3001").allowed_files or {})[1])
UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; cb(1) end
asked = {}
local e7 = send_and_wait("EDITPATH=" .. wt .. "/src/b.py")
check("allowed once", #asked == 1 and e7 ~= nil and e7.text:find("src/b.py]=yes", 1, true) ~= nil, vim.inspect(asked))
check("and now it's part of the plan", vim.deep_equal(PLAN.load("wi-3001").allowed_files, { "src/b.py" }))
asked = {}
local e8 = send_and_wait("EDITPATH=" .. wt .. "/src/b.py")
check("so the next edit to it doesn't ask", #asked == 0 and e8 ~= nil and e8.text:find("src/b.py]=yes", 1, true) ~= nil,
  vim.inspect(asked))
check("and the change check counts it as planned",
  #PLAN.check_change(PLAN.load("wi-3001"), { "src/a.py", "src/b.py" }).unplanned == 0)
UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; cb(2) end

-- Building and testing as the approved plan's Test plan says: the agent's
-- own shell running it (in that plan's conversation) and run_tests
-- don't ask; another command does.
local rec = PLAN.load("wi-3001")
rec.revisions[1].markdown = rec.revisions[1].markdown .. "\n## Test plan\n```sh\ndotnet build\ndotnet test\n```\n"
PLAN.save(rec)
STATE.chat.plan_key = "wi-3001"
asked = {}
local e9 = send_and_wait("EXEC=dotnet_build EXEC=dotnet_test EXEC=curl_example.com")
check("the plan's build and test commands run without asking", e9 ~= nil
  and e9.text:find("exec[dotnet build]=yes", 1, true) ~= nil and e9.text:find("exec[dotnet test]=yes", 1, true) ~= nil,
  e9 and e9.text)
check("another command asks", #asked == 1 and asked[1]:find("curl", 1, true) ~= nil, vim.inspect(asked))
STATE.chat.plan_key = nil
vim.fn.mkdir(wt, "p")
vim.fn.writefile({ "gitdir: x" }, wt .. "/.git")
vim.fn.writefile({ "feature/3001" }, wt .. ".branch")
local RT = require("azure-cli.chat.tools").by_name.run_tests
local pre, why
RT.preapproved({ work_item_id = 3001 }, function(ok, w) pre, why = ok, w end)
check("run_tests: the approved plan's command doesn't ask", pre == true, why)
RT.preapproved({ work_item_id = 3001, command = "make" }, function(ok) pre = ok end)
check("run_tests: a command of the agent's own asks", pre == false)

PLAN.save({ key = "wi-3001", status = "draft", target = { work_item_id = 3001 }, threads = {},
  revisions = { { at = os.time(), by = "agent", markdown = "## Files\n- `src/a.py`\n" } } })
asked = {}
send_and_wait("EDITPATH=" .. wt .. "/src/a.py")
check("a plan not approved yet: a planned file still asks", #asked == 1, vim.inspect(asked))
RT.preapproved({ work_item_id = 3001 }, function(ok) pre = ok end)
check("run_tests: a plan not approved yet asks", pre == false)
vim.fn.delete(wt, "rf")
os.remove(wt .. ".branch")
os.remove(PLAN.root() .. "/wi-3001.json")
UI.choose = real_choose

-- The main chat as the coordinator: its /plan starts an agent (shown on
-- the Agents screen) instead of planning itself; list_agents and
-- message_agent reach the agents; a plan's agent can't use them.
CHAT.new_chat(true)
local CORE, AG, TOOLS = require("azure-cli.chat.core"), require("azure-cli.chat.agents"), require("azure-cli.chat.tools")
check("the main chat is told it coordinates", CORE.compose("x", "v", { first = true, orchestrator = true })
  :find("you coordinate", 1, true) ~= nil and not CORE.compose("x", "v", { first = true }):find("you coordinate", 1, true))
CHAT.send("/plan #3005 keep it small", { view_win = win })
local main = STATE.chat
local last = main.entries[#main.entries]
check("/plan in the main chat starts an agent", last and last.role == "note" and last.text:find("Planning #3005", 1, true) ~= nil,
  vim.inspect(last))
local conv = CHAT.find_conversation("wi-3005")
check("in a conversation of its own", conv ~= nil and conv ~= main)
check("and the main chat's agent wasn't asked", not main.running)
vim.wait(20000, function() return conv and not conv.running end, 20)
local rows = require("azure-cli.chat.agents_view").rows(CHAT.conversations(), AG.queued(), PLAN.load, os.time())
local on_screen = false
for _, r in ipairs(rows) do if r.key == "wi-3005" then on_screen = true end end
check("it's on the Agents screen", on_screen, vim.inspect(rows))
local function call(name, args, env)
  local res, err
  TOOLS.by_name[name].run(args, env or {}, function(r, e) res, err = r, e end)
  vim.wait(2000, function() return res ~= nil or err ~= nil end, 10)
  return res, err
end
local listed = call("list_agents", {})
check("list_agents lists it", type(listed) == "table" and listed[1] and listed[1].agent == "#3005", vim.inspect(listed))
local sent, serr = call("message_agent", { work_item_id = 3005, message = "use the existing cache" })
check("message_agent sends it on", sent and sent:find("Sent to #3005", 1, true) ~= nil, serr)
vim.wait(20000, function() return not conv.running end, 20)
local shown = false
for _, e in ipairs(conv.entries) do if e.role == "you" and e.text == "From the main chat: use the existing cache" then shown = true end end
check("shown in that agent's own chat", shown, vim.inspect(conv.entries))
check("which answered it", conv.entries[#conv.entries].status == "done", vim.inspect(conv.entries[#conv.entries]))
local _, refused = call("start_agents", { work_item_ids = { 3006 } }, { conv = conv })
check("a plan's agent can't start agents", refused and refused:find("only the main chat", 1, true) ~= nil, refused)
local started = call("start_agents", { work_item_ids = { 3006 } })
check("start_agents starts one", started and started:find("Planning #3006", 1, true) ~= nil, started)
local c6 = CHAT.find_conversation("wi-3006")
vim.wait(20000, function() return c6 and not c6.running end, 20)

CHAT.new_chat(true)
os.remove(marker)

if fails > 0 then
  print(fails .. " chat-acp test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-acp tests passed")
end
