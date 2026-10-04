-- test-chat.lua: unit tests for the chat panel's pure helpers -
-- chat/init.lua (compose, parse_answer, can_resume, render, models,
-- current_model, expand), chat/view.lua (text), chat/tools.lua
-- (simplify_threads, args_label, the tool list's shape, the ask/write split)
-- and review/chat.lua (thread). They need vim.json and vim.api at load, so
-- this runs under a real headless Neovim:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat.lua
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local CHAT = require("azure-cli.chat")
local VIEW = require("azure-cli.chat.view")
local TOOLS = require("azure-cli.chat.tools")
local RCHAT = require("azure-cli.review.chat")

-- --- compose -----------------------------------------------------------------
do
  local first = CHAT.compose("hi", "Screen: x", { first = true })
  check("compose: first message has the preamble, view and message",
    first:find(CHAT.PREAMBLE, 1, true) == 1 and first:find("## Current view\nScreen: x", 1, true)
      and first:sub(-13) == "## Message\nhi")
  local later = CHAT.compose("and?", "Screen: y", {})
  check("compose: a resumed message is just view + message", not later:find(CHAT.PREAMBLE, 1, true)
    and later == "## Current view\nScreen: y\n\n## Message\nand?")
  local replay = CHAT.compose("and?", "v", { history = {
    { role = "you", text = "q1" }, { role = "agent", text = "a1" }, { role = "agent", text = "" } } })
  check("compose: a replay carries the preamble and the conversation",
    replay:find(CHAT.PREAMBLE, 1, true) and replay:find("## The conversation so far\n\nUser: q1\n\nYou: a1\n\n## Current view", 1, true))
end

-- --- parse_answer / can_resume / expand ---------------------------------------
do
  local text, sid = CHAT.parse_answer('{"type":"result","result":"  Hello\\n","session_id":"s-1"}', "", vim.json.decode)
  check("parse: claude envelope", text == "Hello" and sid == "s-1")
  text, sid = CHAT.parse_answer("plain answer\r\n", "", vim.json.decode)
  check("parse: plain text", text == "plain answer" and sid == nil)
  text, sid = CHAT.parse_answer("hi", "Session ID: abc-9", vim.json.decode, "Session ID: (%S+)")
  check("parse: session_pattern on stderr", text == "hi" and sid == "abc-9")
  text = CHAT.parse_answer('{"result":"","is_error":true}', "", vim.json.decode)
  check("parse: an empty error envelope says so", text == "(the agent reported an error)")
  text = CHAT.parse_answer("{not json", "", vim.json.decode)
  check("parse: broken json stays text", text == "{not json")

  local agent = { cmd = { "x" }, followup = { cmd = { "x", "--resume", "{session_id}" } } }
  check("can_resume: needs the session", not CHAT.can_resume(agent, nil) and CHAT.can_resume(agent, "s"))
  check("can_resume: no followup", not CHAT.can_resume({ cmd = { "x" } }, "s"))
  check("can_resume: --continue style needs none", CHAT.can_resume({ followup = { cmd = { "x", "-c" } } }, nil))
  check("expand", CHAT.expand("{a} {b} {zz}", { a = "1", b = "x y" }, function(v) return "'" .. v .. "'" end)
    == "'1' 'x y' {zz}")
end

-- --- models -------------------------------------------------------------------
do
  local a = { models = { "fast", { label = "Smart one", value = "smart" }, { label = "bad" } } }
  local m = CHAT.models(a)
  check("models: strings and pairs, junk dropped", #m == 2 and m[1].value == "fast" and m[2].label == "Smart one")
  require("azure-cli.state").chat = nil
  check("current_model: first listed", CHAT.current_model(a) == "fast")
  check("current_model: agent.model wins over the list", CHAT.current_model({ model = "m", models = { "fast" } }) == "m")
  check("current_model: none", CHAT.current_model({}) == nil and CHAT.current_model(nil) == nil)
end

-- --- render -------------------------------------------------------------------
do
  local empty = CHAT.render({}, 0, "Claude")
  check("render: empty chat explains itself", empty[1] == "# Chat" and table.concat(empty, " "):find("triage", 1, true))
  local lines = CHAT.render({
    { role = "you", text = "triage\nplease", where = "on PR #1" },
    { role = "agent", status = "running", started = 100, tools = { "\u{00B7} current_view" } },
  }, 112, "Claude")
  local all = table.concat(lines, "\n")
  check("render: your turn with where", all:find("## You  \u{00B7}  _on PR #1_\n\ntriage\nplease", 1, true))
  check("render: running agent with its tools", all:find("## Claude  \u{00B7}  _working\u{2026} 12s_\n\n    \u{00B7} current_view", 1, true))
  local done = table.concat(CHAT.render({ { role = "agent", status = "failed (exit 1)", text = "boom", mode = "replay" },
    { role = "note", text = "hello" } }, 0, nil), "\n")
  check("render: status, replay, note", done:find("## Agent  \u{00B7}  _failed (exit 1)_  \u{00B7}  _replayed_\n\nboom", 1, true)
    and done:find("_hello_", 1, true))
end

-- --- view.text ------------------------------------------------------------------
do
  local t = VIEW.text({
    screen = "reviewer: a file's diff", file = "src/a.py", line = 12, side = "R", code_line = "return x",
    pr = { id = 101, title = "Throttle", repo = "widgets", source = "f", target = "main" },
    thread = { id = 5000, status = "active", comments = { { author = "Bob", content = "Why\nnot?" } } },
    work_item = { id = 3001, type = "User Story", title = "Login", state = "Active" },
  })
  check("view: pr", t:find('Pull request: PR #101 "Throttle" in widgets (f -> main)', 1, true) ~= nil, t)
  check("view: file, line, side", t:find("File: src/a.py line 12 (source side)", 1, true) ~= nil)
  check("view: thread", t:find("Comment thread #5000 [active] started by Bob: Why not?", 1, true) ~= nil, t)
  check("view: work item", t:find('Work item: work item #3001 User Story "Login" [Active]', 1, true) ~= nil)
  check("view: nothing", VIEW.text({}) == "Screen: ?")
end

-- --- tools ------------------------------------------------------------------------
do
  local names, asks = {}, {}
  for _, t in ipairs(TOOLS.list) do
    names[#names + 1] = t.name
    if t.risk == "ask" then asks[#asks + 1] = t.name end
    check("tool " .. t.name .. " is complete", type(t.description) == "string" and type(t.schema) == "table"
      and type(t.run) == "function" and (t.risk == "read" or t.risk == "write" or t.risk == "ask"))
  end
  check("tools: votes and state changes ask; links, branches and drafts don't",
    table.concat(asks, ",") == "vote,set_work_item_state"
      and TOOLS.by_name.create_branch.risk == "write" and TOOLS.by_name.draft_reply.risk == "write")
  check("tools: describe() is tools/list's shape", #TOOLS.describe() == #names and TOOLS.describe()[1].inputSchema ~= nil)
  check("args_label", TOOLS.args_label({ pr_id = 1, text = string.rep("x", 50), b = true }) == " (b=true, pr_id=1)"
    and TOOLS.args_label({}) == "")
  local th = TOOLS.simplify_threads({ value = {
    { id = 1, status = "active", threadContext = { filePath = "/a.py", rightFileStart = { line = 3 } },
      comments = { { author = { displayName = "B" }, content = "x", commentType = "text" } } },
    { id = 2, comments = { { content = "vote", commentType = "system" } } },
  } })
  check("simplify_threads", #th == 1 and th[1].file == "a.py" and th[1].side == "R" and th[1].line == 3)
  check("clone_path", TOOLS.clone_path({ clonesDir = "C:\\src", repo = "w" }) == "C:/src/w")

  -- An "ask" tool: declined -> the agent hears so, run never called.
  local ran, logged, answer = false, {}, nil
  local orig = TOOLS.by_name.vote.run
  TOOLS.by_name.vote.run = function() ran = true end
  TOOLS.call("vote", { pr_id = 1, vote = "approve" }, {
    main_win = function() end, log = function(l) logged[#logged + 1] = l end,
    confirm = function(_, cb) cb(false) end,
  }, function(text, err) answer = { text, err } end)
  TOOLS.by_name.vote.run = orig
  check("ask: declined is reported, not run", not ran and answer[2] == true
    and answer[1]:find('declined: vote "Approve" on PR #1', 1, true) and logged[1]:find("declined", 1, true))
  TOOLS.call("nope", {}, {}, function(text, err) answer = { text, err } end)
  check("call: unknown tool", answer[2] == true and answer[1]:find("unknown tool", 1, true))
end

-- --- review/chat.lua -----------------------------------------------------------------
do
  local t = RCHAT.thread({ id = 7, status = "fixed", path = "a.py", side = "R", lineno = 4,
    comments = { { author = "A", content = "c", authorId = "x", pending = true } } })
  check("review thread", t.id == 7 and t.file == "a.py" and t.line == 4 and t.comments[1].author == "A"
    and t.comments[1].authorId == nil)
end

if fails > 0 then
  print(fails .. " failure(s)")
  vim.cmd("cq")
end
print("all chat tests passed")
vim.cmd("qa!")
