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
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local plugin_root = vim.fn.getcwd()
local marker = vim.fn.tempname()
local py = vim.fn.executable("python3") == 1 and "python3" or "python"

require("azure-cli").setup({ chat = { agent = {
  label = "Fake ACP", acp = true, timeout_seconds = 20, premium_requests = { default = 1 },
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

-- #142: the ACP session id is kept on the conversation, with where and by
-- which agent it runs, and saved with it - the Agents screen's go resumes it.
check("the ACP session id is kept", STATE.chat.session_id == "fake-acp-1", tostring(STATE.chat.session_id))
check("with its directory and agent", type(STATE.chat.agent_cwd) == "string" and STATE.chat.agent_cwd ~= ""
  and STATE.chat.session_agent == "Fake ACP", vim.inspect({ STATE.chat.agent_cwd, STATE.chat.session_agent }))
do
  local saved = require("azure-cli.chat.store").load(STATE.chat.conv_id) or {}
  check("and saved with the conversation", saved.session_id == "fake-acp-1" and saved.agent_cwd == STATE.chat.agent_cwd
    and saved.session_agent == "Fake ACP", vim.inspect({ saved.session_id, saved.agent_cwd, saved.session_agent }))
end

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

-- A new, approved revision (the next stage): the last one's allowances
-- don't carry over, and its Files entries count every path they name - a
-- second one after a comma, a bare file name - and no code word.
do
  local r = PLAN.load("wi-3001")
  PLAN.add_revision(r, "## Goal\nx\n\n## Files\n- `src/a.py`, `src/c.py` - throttle, `M.open(host)`\n"
    .. "- helper.py: the bare name\n", "agent")
  r.status, r.approved_rev = "approved", #r.revisions
  PLAN.save(r)
  asked = {}
  local e = send_and_wait("EDITPATH=" .. wt .. "/src/b.py")
  check("a new revision: the last one's allowance asks again", #asked == 1 and e ~= nil
    and e.text:find("src/b.py]=no", 1, true) ~= nil, vim.inspect(asked))
  asked = {}
  e = send_and_wait("EDITPATH=" .. wt .. "/src/c.py EDITPATH=" .. wt .. "/src/lib/helper.py")
  check("a second comma path and a bare name are in the plan", #asked == 0 and e ~= nil
    and e.text:find("src/c.py]=yes", 1, true) ~= nil and e.text:find("helper.py]=yes", 1, true) ~= nil,
    vim.inspect(asked) .. " " .. tostring(e and e.text))
  check("and the code word isn't a planned-not-changed file",
    vim.deep_equal(PLAN.check_change(PLAN.load("wi-3001"), { "src/a.py", "src/c.py", "src/lib/helper.py" }).missing, {}))
  r = PLAN.load("wi-3001")
  r.revisions = { r.revisions[1] }
  r.approved_rev = nil
  PLAN.save(r)
  os.remove(PLAN.path("wi-3001"))
end

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
asked = {}
local e9b = send_and_wait("EXEC=git_log_--oneline EXEC=grep_-rn_Config_src EXEC=rm_-rf_build")
check("searching through the shell doesn't ask, in any conversation", e9b ~= nil
  and e9b.text:find("exec[git log --oneline]=yes", 1, true) ~= nil
  and e9b.text:find("exec[grep -rn Config src]=yes", 1, true) ~= nil, e9b and e9b.text)
check("a command that changes something still asks", #asked == 1 and asked[1]:find("rm", 1, true) ~= nil,
  vim.inspect(asked))
-- A skill: its prompts ask with a third button; picking it allows the
-- skill from then on, and its later prompts don't ask.
local SK = require("azure-cli.chat.skills")
local orig_avail = SK.available
SK.available = function() return { "deploy-check" } end
local buttons
UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; buttons = o.buttons; cb(3) end
asked = {}
local s1 = send_and_wait("use the deploy-check skill EXEC=kubectl_apply")
check("a skill's prompt offers to allow the skill", buttons and buttons[3] == "Allow all of skill deploy-check"
  and asked[1]:find("(skill deploy-check)", 1, true) ~= nil, vim.inspect({ buttons, asked }))
check("allowing it allows this one", s1 and s1.text:find("exec[kubectl apply]=yes", 1, true) ~= nil, s1 and s1.text)
asked = {}
local s2 = send_and_wait("/deploy-check again EXEC=kubectl_rollout EXEC=rm_-rf_tmp")
check("then the skill's prompts don't ask", #asked == 0 and s2 and s2.text:find("exec[kubectl rollout]=yes", 1, true)
  ~= nil and s2.text:find("exec[rm -rf tmp]=yes", 1, true) ~= nil, vim.inspect({ asked, s2 and s2.text }))
check("and the chat says the skill allowed them", table.concat(s2 and s2.tools or {}, "\n")
  :find("$ kubectl rollout  (allowed: skill deploy-check)", 1, true) ~= nil, vim.inspect(s2 and s2.tools))
asked = {}
UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; buttons = o.buttons; cb(2) end
send_and_wait("no skill here EXEC=kubectl_apply")
check("without the skill it asks as before, with two buttons", #asked == 1 and #buttons == 2, vim.inspect(buttons))
SK.available = orig_avail
-- chat.permissions' "agent-commands": the agent's commands don't ask.
require("azure-cli.config").get().chat.permissions = { ["agent-commands"] = "allow" }
asked = {}
local s3 = send_and_wait("EXEC=kubectl_apply EXEC=rm_-rf_tmp")
check("agent-commands = allow: nothing asks", #asked == 0 and s3 and s3.text:find("exec[rm -rf tmp]=yes", 1, true) ~= nil
  and table.concat(s3.tools or {}, "\n"):find("(allowed: chat.permissions)", 1, true) ~= nil,
  vim.inspect({ asked, s3 and s3.text, s3 and s3.tools }))
require("azure-cli.config").get().chat.permissions = { all = "deny" }
local s4 = send_and_wait("EXEC=kubectl_apply")
check("all = deny: refused without asking", #asked == 0 and s4 and s4.text:find("exec[kubectl apply]=no", 1, true) ~= nil,
  vim.inspect({ asked, s4 and s4.text }))
require("azure-cli.config").get().chat.permissions = nil
local orig_report, orig_popup = SK.report, SK.popup
local on_use
SK.popup = function(_, cb) on_use = cb return 1 end
local n_before = #STATE.chat.entries
CHAT.send("/skills", { view_win = win })
check("/skills opens the popup, without asking the agent or adding to the chat",
  on_use ~= nil and #STATE.chat.entries == n_before and not STATE.chat.running)
on_use("deploy-check")
check("/skills: using one starts the message with it",
  table.concat(vim.api.nvim_buf_get_lines(CHAT._.input_buf(), 0, -1, false), "\n") == "/deploy-check ")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(CHAT._.input_buf(), 0, -1, false, { "" })
SK.popup = function() return nil end
SK.report = function() return "No skills found." end
CHAT.send("/skills", { view_win = win })
local last = STATE.chat.entries[#STATE.chat.entries]
check("/skills with none found says so in the chat", #STATE.chat.entries == n_before + 2
  and last.role == "note" and last.text == "No skills found." and not STATE.chat.running, vim.inspect(last))
SK.report, SK.popup = orig_report, orig_popup
pcall(vim.fn.delete, require("azure-cli.chat.store").root() .. "/allowed_skills.json")
SK._reset()
asked = {}
-- The popup shows the command itself, and the chat logs each one with
-- what became of it.
local shown
UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; shown = o.details; cb(2) end
local e9c = send_and_wait("EXEC=git_status EXEC=rm_-rf_out")
check("the popup shows the command", shown and table.concat(shown, "\n"):find("rm -rf out", 1, true) ~= nil,
  vim.inspect(shown))
local log = table.concat(e9c and e9c.tools or {}, "\n")
check("the chat logs each command and its outcome", log:find("$ git status  (allowed: only looks)", 1, true) ~= nil
  and log:find("$ rm -rf out  (you denied it)", 1, true) ~= nil, log)
UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; cb(2) end
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

-- Usage: ACP's usage_update gives the context and the session's cost so far
-- (each answer's cost is what it grew by); premium_requests counts each
-- message as one request times its model's multiplier.
CHAT.new_chat(true)
local u1 = send_and_wait("USAGE")
local u2 = send_and_wait("USAGE")
check("usage_update: the context", u1 and u1.context and u1.context.used == 50000 and u1.context.size == 200000,
  vim.inspect(u1 and u1.context))
check("usage_update: each answer's cost is what the total grew by",
  u1 and u2 and math.abs((u1.cost or 0) - 0.05) < 1e-9 and math.abs((u2.cost or 0) - 0.05) < 1e-9, vim.inspect({ u1 and u1.cost, u2 and u2.cost }))
local CORE0 = require("azure-cli.chat.core")
check("premium requests: one per message", CORE0.requests_of(STATE.chat.entries) == 2, CORE0.requests_of(STATE.chat.entries))
check("labels", CORE0.context_label(u1 and u1.context) == "ctx 25%" and CORE0.requests_label(2) == "2 req"
  and CORE0.requests_label(1.5) == "1.5 req" and CORE0.requests_label(nil) == "")
local tl = send_and_wait("TOOLS")
check("azure-vicli's own tools aren't listed twice (the bridge lists them)", tl ~= nil
  and vim.tbl_contains(tl.tools, "\u{00B7} Read src/a.cs")
  and not table.concat(tl.tools, "\n"):find("azure-vicli", 1, true), vim.inspect(tl and tl.tools))
check("multiplier: per model, else default, else none",
  CORE0.request_multiplier({ premium_requests = { default = 1, opus = 10 } }, "opus") == 10
    and CORE0.request_multiplier({ premium_requests = { default = 1, opus = 10 } }, "sonnet") == 1
    and CORE0.request_multiplier({ premium_requests = { mini = 0 } }, "mini") == 0
    and CORE0.request_multiplier({}, "opus") == nil)

-- Models by stage: a plan's agent plans on planner_model, switches (in its
-- session) to implementer_model once the plan is approved; the main chat
-- stays on `model`; gm sets one conversation's only.
local AGENT = require("azure-cli.config").get().chat.agent
AGENT.model, AGENT.planner_model, AGENT.implementer_model = "chatty", "thinker", "coder"
local mc = CHAT.conversation("wi-77", { label = "#77", target = { work_item_id = 77 } })
local function conv_send(c, text)
  local d
  CHAT.send(text, { conv = c, view_win = win, on_done = function() d = true end })
  vim.wait(20000, function() return d end, 20)
  return c.entries[#c.entries]
end
local m1 = conv_send(mc, "plan it")
check("a plan's agent plans on planner_model", m1.text:find("model thinker", 1, true) ~= nil and m1.model == "thinker", m1.text)
PLAN.save({ key = "wi-77", status = "approved", target = { work_item_id = 77 }, threads = {}, revisions = { { markdown = "x" } } })
local m2 = conv_send(mc, "go ahead")
check("approved: it implements on implementer_model", m2.text:find("model coder", 1, true) ~= nil, m2.text)
check("switched in the same session", m1.text:match("pid (%d+)") == m2.text:match("pid (%d+)"), { m1.text, m2.text })
CHAT.new_chat(true)
local m3 = send_and_wait("hello")
check("the main chat stays on model", m3 and m3.text:find("model chatty", 1, true) ~= nil, m3 and m3.text)
mc.model, mc.model_agent = "picked", require("azure-cli.chat").current_agent()
check("gm's pick is that conversation's only", CHAT.current_model(AGENT, mc) == "picked"
  and CHAT.current_model(AGENT, STATE.chat) == "chatty")
os.remove(PLAN.root() .. "/wi-77.json")
AGENT.model, AGENT.planner_model, AGENT.implementer_model = nil, nil, nil

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

-- Task agents (#143): start_agents with `task` starts an agent of its own
-- (Task <n>) under chat.max_agents; it only reads - edits refused on every
-- turn, the write tools refused, a shell command still asks - and its
-- answer goes back to the main chat (a note, and its next message) without
-- starting a turn there. It plans only when told: a plan of its task's own,
-- or a work item's, which makes it that item's agent.
do
  local CFG = require("azure-cli.config").get().chat
  local real_max = CFG.max_agents
  CFG.max_agents = 1
  asked = {}
  UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; cb(2) end
  local s1, e1 = call("start_agents", { task = "Find where PERMS EXEC=make_build are handled", title = "Find perms" })
  check("task: start_agents { task } starts a task agent", s1 and s1:find("Started Task 1", 1, true) ~= nil, e1 or s1)
  local s2 = call("start_agents", { task = "Second task, look around", title = "Second" })
  check("task: a second one waits under chat.max_agents", s2 and s2:find("Started Task 2", 1, true) ~= nil
    and s2:find("waiting for an agent", 1, true) ~= nil, s2)
  CFG.max_agents = real_max
  local tc = CHAT.find_conversation("task-1")
  check("task: a conversation of its own, keyed task-1", tc ~= nil and tc.target.task_id == 1 and tc.label == "Task 1",
    tc and vim.inspect(tc.target))
  vim.wait(20000, function() return tc and not tc.running and #tc.entries >= 2 end, 20)
  local te = tc and tc.entries[#tc.entries]
  check("task: a read is allowed", te and te.text:find("read=yes", 1, true) ~= nil, te and te.text)
  check("task: an edit is refused", te and te.text:find("edit=no", 1, true) ~= nil, te and te.text)
  check("task: a shell command still asks", #asked == 1 and asked[1]:find("make build", 1, true) ~= nil, vim.inspect(asked))
  local main = STATE.chat
  local note
  for _, e in ipairs(main.entries) do
    if e.role == "note" and (e.text or ""):find("Task 1's agent - Find perms", 1, true) then note = e end
  end
  check("task: its answer goes back to the main chat", note and note.text:find("read=yes", 1, true) ~= nil,
    vim.inspect(main.entries[#main.entries]))
  check("task: without starting a turn there", not main.running)
  check("task: kept for the main chat's next message", main.task_results and main.task_results[1]
    and main.task_results[1].label == "Task 1's agent" and main.task_results[1].text:find("read=yes", 1, true) ~= nil,
    vim.inspect(main.task_results))
  local rows = require("azure-cli.chat.agents_view").rows(CHAT.conversations(), AG.queued(), PLAN.load, os.time())
  local row
  for _, r in ipairs(rows) do if r.key == "task-1" then row = r end end
  check("task: on the Agents screen, answered", row and row.label == "Task 1" and row.state:find("answered", 1, true) ~= nil
    and row.title == "Find perms", vim.inspect(row))
  local t2 = CHAT.find_conversation("task-2")
  vim.wait(20000, function() return t2 and not t2.running and #t2.entries >= 2 end, 20)
  check("task: the queued one started once there was room", t2 and #t2.entries >= 2, t2 and vim.inspect(t2.entries))
  -- A follow-up turn, the user's in its own chat: still read-only.
  asked = {}
  local fdone
  CHAT.send("PERMS again", { conv = tc, view_win = win, on_done = function() fdone = true end })
  vim.wait(20000, function() return fdone end, 20)
  te = tc.entries[#tc.entries]
  check("task: a follow-up turn refuses edits too", te.text:find("edit=no", 1, true) ~= nil and #asked == 0,
    vim.inspect({ te.text, asked }))
  vim.wait(2000, function() return #(main.task_results or {}) == 3 end, 20)
  check("task: every answer goes back", #(main.task_results or {}) == 3, vim.inspect(main.task_results))
  -- azure-vicli's tools: only the read ones, drafts and the plan's.
  local function tcall(name, args, conv)
    local res, is_err
    TOOLS.call(name, args, { conv = conv, log = function() end, confirm = function(_, cb) cb(false) end,
      view = function() return {} end }, function(r, e) res, is_err = r, e end)
    vim.wait(5000, function() return res ~= nil end, 10)
    return tostring(res), is_err
  end
  local r1, x1 = tcall("commit_and_push_fix", { message = "x" }, tc)
  check("task: commit_and_push_fix refused", x1 and r1:find("read-only until the user approves a plan", 1, true) ~= nil, r1)
  local r2, x2 = tcall("create_pull_request", { repo = "r", source = "a", target = "b", title = "t" }, tc)
  check("task: create_pull_request refused", x2 and r2:find("read-only", 1, true) ~= nil, r2)
  local r3 = tcall("list_agents", {}, tc)
  check("task: a read tool runs", not r3:find("read-only", 1, true), r3)
  local r4 = tcall("draft_reply", { pr_id = 1, thread_id = 1, text = "x" }, tc)
  check("task: a draft isn't refused as a write", not r4:find("read-only", 1, true), r4)
  check("task: the main chat's own calls aren't", not PLAN.task_refusal(nil, { name = "vote", risk = "ask" }))
  -- The main chat's next message carries the results, once.
  local m = send_and_wait("what did the tasks find")
  check("task: the main chat's next message takes the results", m ~= nil and main.task_results == nil,
    vim.inspect(main.task_results))
  local composed = CORE.compose("x", "v", { task_results = { { label = "Task 1's agent", title = "Find perms",
    text = "found it in run.lua" } } })
  check("task: composed under its own heading", composed:find("## Results from task agents since your last message", 1, true)
    ~= nil and composed:find("### Task 1's agent (Find perms)\nfound it in run.lua", 1, true) ~= nil, composed)
  -- Told to, it plans for its own task: task-1's plan, gated like a story's.
  local md = "# Fix\n\n## Goal\nx\n\n## Files\n- `src/a.py` - x\n\n## Test plan\n```sh\nmake test\n```\n"
  local p1, pe1 = call("submit_plan", { title = "Fix", markdown = md }, { conv = tc })
  local trec = PLAN.load("task-1")
  check("task: submit_plan without ids is the task's own plan", p1 and trec and trec.target.task_id == 1, pe1)
  check("task: still read-only while it waits", PLAN.task_read_only(tc))
  check("task: gated as a story", not PLAN.gate({ task_id = 1 }) and PLAN.gate_check(nil, "stories", { task_id = 1 }) == false)
  PLAN.approve("task-1")
  vim.wait(20000, function() return not tc.running end, 20)
  check("task: approved, it isn't read-only any more", not PLAN.task_read_only(tc))
  local r5 = tcall("commit_and_push_fix", { message = "x" }, tc)
  check("task: approved, its write tools aren't refused", not r5:find("read-only", 1, true), r5)
  local _, x6 = call("commit_and_push_fix", { message = "x" }, { conv = tc })
  check("task: they act on its own change", x6 and x6:find("no change in progress for Task 1", 1, true) ~= nil, x6)
  local twt = TF.root() .. "/widgets-task1"
  check("task: its worktree is <repo>-task<n>", TF.story_path("widgets", { task_id = 1 }) == twt)
  check("task: the worktree finds its plan", (PLAN.for_worktree(twt) or {}).key == "task-1")
  check("task: an edit the plan lists is planned", PLAN.edit_check({ twt .. "/src/a.py" }) == "planned")
  check("task: its Test plan runs without asking", PLAN.test_command_allowed("task-1", "make test"))
  check("task: the approval tells it how to push", PLAN.approval_message(vim.tbl_extend("force", trec, { allow_push = true }),
    PLAN.lines(trec)):find("your task's own", 1, true) ~= nil)
  -- Planning for a work item instead makes it that item's agent.
  local p2, pe2 = call("submit_plan", { work_item_id = 3007, title = "For 3007", markdown = md }, { conv = t2 })
  check("task: a work item's plan from a task agent", p2 ~= nil, pe2)
  check("task: it becomes that item's agent", CHAT.find_conversation("wi-3007") == t2 and CHAT.find_conversation("task-2") == nil
    and t2.plan_key == "wi-3007" and t2.target.work_item_id == 3007 and t2.label == "#3007", t2 and vim.inspect(t2.target))
  local _, pe3 = call("submit_plan", { work_item_id = 3005, title = "x", markdown = md }, { conv = tc })
  check("task: not one that has an agent already", pe3 and pe3:find("already has an agent", 1, true) ~= nil, pe3)
  -- Restart: the task agent comes back.
  CHAT.drop_conversation("task-1")
  STATE.chat.plans_restored = nil
  CHAT.restore_plans()
  local back = CHAT.find_conversation("task-1")
  check("task: restored after a restart", back ~= nil and back.target.task_id == 1 and back.label == "Task 1"
    and #back.entries > 0, back and vim.inspect(back.target))
  check("task: the adopted one comes back as the item's", CHAT.find_conversation("task-2") == nil)
  check("task: a new task never reuses a number", PLAN.next_task_id() == 3)
  os.remove(PLAN.root() .. "/task-1.json")
  os.remove(PLAN.root() .. "/task-1.md")
  os.remove(PLAN.root() .. "/wi-3007.json")
  os.remove(PLAN.root() .. "/wi-3007.md")
  CHAT.drop_conversation("task-1")
  CHAT.drop_conversation("wi-3007")
end

-- Claude Code's --permission-prompt-tool (mcp__azure-vicli__permission):
-- its requests reach the same rules and popup as an ACP agent's.
do
  local RUN = require("azure-cli.chat.run")
  local t = RUN.claude_tool({ tool_name = "Bash", input = { command = "git log -3", description = "Show commits" } })
  check("claude_tool: Bash is a command", t.kind == "execute" and t.rawInput.command == "git log -3"
    and t.title == "Bash: Show commits", vim.inspect(t))
  t = RUN.claude_tool({ tool_name = "Edit", input = { file_path = "a.lua", old_string = "x = 1", new_string = "x = 2" } })
  check("claude_tool: an edit, with its diff for the popup", t.kind == "edit"
    and t.rawInput.diff == "--- a.lua\n+++ a.lua\n-x = 1\n+x = 2", vim.inspect(t))
  check("claude_tool: reads and searches", RUN.claude_tool({ tool_name = "Grep", input = {} }).kind == "search"
    and RUN.claude_tool({ tool_name = "mcp__other__x", input = {} }).kind == "other")

  local BRIDGE = require("azure-cli.chat.bridge")
  local handler = BRIDGE.handler
  local listed
  handler({ method = "list" }, function(r) listed = r end)
  local names = {}
  for _, x in ipairs(listed and listed.tools or {}) do names[x.name] = true end
  check("the bridge lists the permission tool", names.permission == true)
  local function ask(tool_name, input)
    local ans
    handler({ method = "call", name = "permission", arguments = { tool_name = tool_name, input = input } },
      function(r) ans = vim.json.decode(r.text) end)
    vim.wait(2000, function() return ans ~= nil end, 10)
    return ans
  end
  asked = {}
  UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; cb(2) end
  local a = ask("Bash", { command = "git log -3" })
  check("a look-only command is allowed without asking", a and a.behavior == "allow"
    and a.updatedInput.command == "git log -3" and #asked == 0, vim.inspect({ a, asked }))
  a = ask("Bash", { command = "rm -rf build" })
  check("anything else asks, and Deny refuses it", a and a.behavior == "deny" and #asked == 1, vim.inspect({ a, asked }))
  -- #74: what every agent runs each round, through the popup's path.
  local quiet, loud = {}, {}
  for _, c in ipairs({ "gh run view 1 --log-failed", "git fetch -q origin github-host", "printf '%s' a", "file a.lua" }) do
    a = ask("Bash", { command = c })
    if not (a and a.behavior == "allow" and #asked == 1) then quiet[#quiet + 1] = c end
  end
  check("printf, file, gh run view and plain git fetch don't ask (#74)", #quiet == 0, vim.inspect({ quiet, asked }))
  for k, c in ipairs({ "git fetch --upload-pack=x origin", "gh run rerun 1", "printf -v x y" }) do
    a = ask("Bash", { command = c })
    if not (a and a.behavior == "deny" and #asked == 1 + k) then loud[#loud + 1] = c end
  end
  check("git fetch --upload-pack, gh run rerun and printf -v still ask (#74)", #loud == 0, vim.inspect({ loud, asked }))
  -- #75: plain diff, gh pr / issue reads and git worktree list, through the popup's path.
  asked, quiet, loud = { asked[1] }, {}, {}
  for _, c in ipairs({ "diff -u a b", "sed -n 1,9p x.md | diff - /tmp/k.md", "cmp -s a b", "comm -12 a b",
    "gh pr view 12 --json state", "gh pr checks 12", "gh pr diff 12 --name-only", "gh pr list -s all", "gh pr status",
    "gh issue view 75 --comments", "gh issue list -l bug", "gh issue status", "git worktree list --porcelain" }) do
    a = ask("Bash", { command = c })
    if not (a and a.behavior == "allow" and #asked == 1) then quiet[#quiet + 1] = c end
  end
  check("diff, cmp, comm, gh pr/issue reads and git worktree list don't ask (#75)", #quiet == 0, vim.inspect({ quiet, asked }))
  for k, c in ipairs({ "diff a b > out", "diff --output=x a b", "gh pr view 12 --web", "gh pr list -w", "gh issue view 75 -wc",
    "gh pr merge 1", "gh pr checkout 1", "gh issue close 1", "git worktree add ../x", "git worktree remove ../x",
    "git worktree prune", "git worktree list x" }) do
    a = ask("Bash", { command = c })
    if not (a and a.behavior == "deny" and #asked == 1 + k) then loud[#loud + 1] = c end
  end
  check("diff that writes, gh --web, gh pr/issue that acts and git worktree add/remove/prune still ask (#75)", #loud == 0,
    vim.inspect({ loud, asked }))
  -- #84: $?, git remote's reads and nvim --version, through the popup's path.
  asked, quiet, loud = { asked[1] }, {}, {}
  for _, c in ipairs({ "for id in 1 2; do gh run watch $id; echo \"$id exit=$?\"; done", "git remote -v",
    "git remote show origin", "git remote get-url origin", "nvim --version", "nvim -v" }) do
    a = ask("Bash", { command = c })
    if not (a and a.behavior == "allow" and #asked == 1) then quiet[#quiet + 1] = c end
  end
  check("$?, git remote -v/show/get-url and nvim --version don't ask (#84)", #quiet == 0, vim.inspect({ quiet, asked }))
  for k, c in ipairs({ "git remote add x y", "git remote set-url origin x", "git remote prune origin", "nvim -l x.lua",
    "nvim --headless -c q", "echo $(nvim -l x)", "echo $-" }) do
    a = ask("Bash", { command = c })
    if not (a and a.behavior == "deny" and #asked == 1 + k) then loud[#loud + 1] = c end
  end
  check("other git remote, other nvim and $- still ask (#84)", #loud == 0, vim.inspect({ loud, asked }))
  asked = { asked[1] }
  UI.choose = function(o, cb) asked[#asked + 1] = o.lines[1]; cb(1) end
  a = ask("Write", { file_path = "notes.txt", content = "hi" })
  check("an edit asks, and Allow allows it with its input", a and a.behavior == "allow"
    and a.updatedInput.file_path == "notes.txt" and #asked == 2, vim.inspect({ a, asked }))

  -- Issue #31: AskUserQuestion is asked as its questions, and the answer
  -- goes back as updatedInput.answers, keyed by the question's text.
  local colour = { question = "Which colour?", header = "Colour", multiSelect = false, options = {
    { label = "Red", description = "warm" }, { label = "Blue", description = "cool" } } }
  local extras = { question = "Which extras?", header = "Extras", multiSelect = true, options = {
    { label = "A", description = "first" }, { label = "B", description = "second" }, { label = "C", description = "third" } } }
  -- `answers`: per popup, what it answers - cb's (index, ticks).
  local popups
  local function answering(answers)
    popups = {}
    UI.choose = function(o, cb)
      popups[#popups + 1] = o
      local ans = table.remove(answers, 1) or {}
      cb(ans[1], ans[2])
    end
  end
  answering({ { 2 } })
  a = ask("AskUserQuestion", { questions = { colour } })
  check("AskUserQuestion: one pick is the answer, under the question's text", a and a.behavior == "allow"
    and a.updatedInput.answers["Which colour?"] == "Blue" and a.updatedInput.questions[1].question == "Which colour?",
    vim.inspect(a))
  local p = popups[1] or {}
  check("AskUserQuestion: the popup shows the header, the question and the options with their descriptions",
    #popups == 1 and p.title == "Colour" and p.lines[1] == "Which colour?"
    and vim.tbl_contains(p.lines, "1. Red - warm") and vim.tbl_contains(p.lines, "2. Blue - cool")
    and vim.deep_equal(p.buttons, { "Red", "Blue", "Other\u{2026}", "Cancel" }) and p.cancel == 4 and p.keys["2"] == 2
    and p.checks == nil and p.arm_ms == 400, vim.inspect(p))

  -- multiSelect: tick boxes, then Done (button 5: A B C Other Done Cancel).
  answering({ { 5, { true, false, true } } })
  a = ask("AskUserQuestion", { questions = { extras } })
  p = popups[1] or {}
  check("AskUserQuestion: multiSelect offers tick boxes and Done", vim.deep_equal(p.checks, { false, false, false })
    and vim.deep_equal(p.buttons, { "A", "B", "C", "Other\u{2026}", "Done", "Cancel" }), vim.inspect(p))
  check("AskUserQuestion: multiSelect answers the ticked labels, joined", a and a.behavior == "allow"
    and a.updatedInput.answers["Which extras?"] == "A, C", vim.inspect(a))

  -- Other: your own words, from the comment editor.
  local EDITOR = require("azure-cli.editor")
  local real_open, opened = EDITOR.open, {}
  EDITOR.open = function(o) opened[#opened + 1] = o; o.on_submit("  my own  ") end
  answering({ { 3 } })
  a = ask("AskUserQuestion", { questions = { colour } })
  check("AskUserQuestion: Other sends your own words", a and a.behavior == "allow"
    and a.updatedInput.answers["Which colour?"] == "my own" and #opened == 1
    and opened[1].context_lines[1] == "Which colour?", vim.inspect({ a, opened }))
  -- Backing out of the editor asks the question again.
  opened = {}
  EDITOR.open = function(o) opened[#opened + 1] = o; o.on_cancel() end
  answering({ { 3 }, { 1 } })
  a = ask("AskUserQuestion", { questions = { colour } })
  check("AskUserQuestion: cancelling Other asks again", a and a.updatedInput.answers["Which colour?"] == "Red"
    and #popups == 2 and #opened == 1, vim.inspect({ a, #popups }))
  EDITOR.open = real_open

  -- Esc (cancel): declined, and nothing answered.
  answering({ { 4 } })
  a = ask("AskUserQuestion", { questions = { colour } })
  check("AskUserQuestion: Esc declines to answer", a and a.behavior == "deny" and a.updatedInput == nil
    and a.message == "The user declined to answer the question(s).", vim.inspect(a))

  -- Two questions: each its own popup, both answers back; cancelling the
  -- second declines both.
  answering({ { 1 }, { 5, { false, true, false } } })
  a = ask("AskUserQuestion", { questions = { colour, extras } })
  check("AskUserQuestion: two questions, two answers", a and a.behavior == "allow" and #popups == 2
    and popups[1].title == "Colour (1/2)" and a.updatedInput.answers["Which colour?"] == "Red"
    and a.updatedInput.answers["Which extras?"] == "B", vim.inspect(a))
  answering({ { 1 }, { 6 } })
  a = ask("AskUserQuestion", { questions = { colour, extras } })
  check("AskUserQuestion: cancelling one of them declines them all", a and a.behavior == "deny", vim.inspect(a))

  -- Every other tool still gets Allow/Deny.
  asked = {}
  UI.choose = function(o, cb) asked[#asked + 1] = o; cb(2) end
  a = ask("Bash", { command = "rm -rf build" })
  check("and any other tool still asks Allow/Deny", a and a.behavior == "deny" and #asked == 1
    and vim.deep_equal(asked[1].buttons, { "Allow", "Deny" }), vim.inspect(asked))
  check("answers_for: declined is a deny", RUN.answers_for({ questions = {} }, nil).behavior == "deny")
  UI.choose = real_choose
end

-- Issue #27: the idle timeout stops a quiet turn through session/cancel,
-- so the session survives it; a popup waiting for you isn't idle.
do
  local AG = require("azure-cli.config").get().chat.agent
  AG.idle_timeout_seconds = 1
  CHAT.new_chat(true)
  local q, qerr = send_and_wait("GOQUIET")
  check("idle timeout: a quiet ACP turn is stopped", q ~= nil and q.status == "timed out (idle 1s)", qerr or (q and q.status))
  check("idle timeout: it says so, naming the setting", q and table.concat(q.tools, "\n")
    :find("no output from the agent for 1s (idle_timeout_seconds = 1)", 1, true) ~= nil, q and vim.inspect(q.tools))
  local n = send_and_wait("after")
  check("idle timeout: the session survives it (its turn 2)", n and n.status == "done" and n.text:match("^turn 2,") ~= nil,
    n and n.text)
  UI.choose = function(_, cb) vim.defer_fn(function() cb(2) end, 2500) end
  local p, perr = send_and_wait("EXEC=rm_-rf_build")
  check("idle timeout: 2.5s on a popup isn't idle", p ~= nil and p.status == "done"
    and p.text:find("exec[rm -rf build]=no", 1, true) ~= nil, perr or (p and (p.status .. " " .. p.text)))
  UI.choose = real_choose
  AG.idle_timeout_seconds = nil
end

CHAT.new_chat(true)
os.remove(marker)

if fails > 0 then
  print(fails .. " chat-acp test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-acp tests passed")
end
