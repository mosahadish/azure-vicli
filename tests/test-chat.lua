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
  local empty, eroles = CHAT.render({}, 0, "Claude")
  check("render: empty chat explains itself", empty[1] == "Chat" and eroles[3] == "intro"
    and table.concat(empty, " "):find("triage", 1, true))
  local lines, roles, name_end = CHAT.render({
    { role = "you", text = "triage\nplease", where = "on PR #1" },
    { role = "agent", status = "running", started = 100, tools = { "\u{00B7} current_view", "\u{270E} draft_reply",
      "\u{2717} vote: declined" } },
  }, 112, "Claude")
  check("render: your heading, name then where", lines[1] == "You  \u{00B7}  on PR #1" and roles[1] == "you_head"
    and name_end[1] == 3)
  check("render: your text", lines[2] == "triage" and lines[3] == "please" and roles[3] == "you")
  check("render: a gap between turns has no role", lines[4] == "" and roles[4] == nil)
  check("render: running agent heading", lines[5] == "Claude  \u{00B7}  working\u{2026} 12s" and roles[5] == "agent_head"
    and name_end[5] == #"Claude")
  check("render: tool calls by kind", roles[6] == "tool_read" and roles[7] == "tool_write" and roles[8] == "tool_err"
    and lines[6] == "  \u{00B7} current_view")
  local done, droles = CHAT.render({ { role = "agent", status = "failed (exit 1)", text = "**boom**", mode = "replay" },
    { role = "note", text = "hello" } }, 0, nil)
  check("render: status and replay in the heading", done[1] == "Agent  \u{00B7}  failed (exit 1)  \u{00B7}  replayed")
  check("render: the answer stays markdown", done[2] == "**boom**" and droles[2] == "agent")
  check("render: a note", done[4] == "hello" and droles[4] == "note")
  local plain = CHAT.render({ { role = "agent", status = "done", text = "ok" } }, 0, "A")
  check("render: a finished turn's heading is just the name", plain[1] == "A")
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
  table.sort(asks)
  check("tools: what asks first - everything others see or that leaves the machine",
    table.concat(asks, ",") == "add_reviewer,assign_work_item,comment_on_work_item,commit_and_push_fix,"
      .. "complete_pull_request,create_pull_request,set_thread_status,set_work_item_state,update_pr_description,vote",
    table.concat(asks, ","))
  check("tools: links, branches, drafts, tasks and sprints don't",
    TOOLS.by_name.create_branch.risk == "write" and TOOLS.by_name.draft_reply.risk == "write"
      and TOOLS.by_name.link_pr_to_work_item.risk == "write" and TOOLS.by_name.create_child_task.risk == "write"
      and TOOLS.by_name.move_to_sprint.risk == "write")
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

-- --- core: streaming, prompts, refs, title ------------------------------------
do
  local CORE = require("azure-cli.chat.core")
  local dec = vim.json.decode
  local r = CORE.stream_new()
  CORE.stream_feed(r, { '{"type":"system","subtype":"init","session_id":"s-9"}', '{"type":"assistant","message":{"content":[{"type":"text","text":"Hel' }, dec)
  check("stream: a partial line waits", #r.texts == 0 and r.session == "s-9")
  CORE.stream_feed(r, { 'lo"},{"type":"tool_use","name":"Read","input":{"file_path":"a.py"}}]}}', "" }, dec)
  check("stream: the completed line is read", CORE.stream_text(r) == "Hello" and r.tools[1] == "Read a.py")
  CORE.stream_feed(r, { '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__azure-vicli__get_pr","input":{}}]}}', "" }, dec)
  check("stream: our own MCP tools aren't listed twice", #r.tools == 1)
  CORE.stream_feed(r, { '{"type":"result","result":"Hello world","session_id":"s-9"}', "" }, dec)
  check("stream: the result wins", CORE.stream_text(r) == "Hello world")
  local p = CORE.stream_new({ "^\u{25CF} ", "^%s+\u{2514}" })
  CORE.stream_feed(p, { "\u{25CF} list_items (MCP)", "  \u{2514} [{...}]", "", "The answer.", "" }, dec)
  CORE.stream_finish(p, dec)
  check("stream: plain text, strip patterns", CORE.stream_text(p) == "The answer.")
  local q = CORE.stream_new()
  CORE.stream_feed(q, { "no newline at the end" }, dec)
  CORE.stream_finish(q, dec)
  check("stream: finish flushes the last line", CORE.stream_text(q) == "no newline at the end")
  local text, sid, tools = CORE.parse_answer('{"type":"system","session_id":"x"}\n{"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}]}}\n{"type":"result","result":"Hi","session_id":"x"}', "", dec)
  check("parse_answer: stream-json too", text == "Hi" and sid == "x" and #tools == 0)
  local pretty = CORE.parse_answer('{\n  "result": "multi",\n  "session_id": "m"\n}', "", dec)
  check("parse_answer: a pretty-printed envelope", pretty == "multi")

  local prompts = CORE.prompts({ mine = "Do X", standup = false })
  check("prompts: defaults, added, removed", prompts.triage and prompts.mine == "Do X" and prompts.standup == nil)
  local exp, name = CORE.expand_prompt("/mine  for !12 ", prompts)
  check("expand_prompt: with the rest", exp == "Do X\n\nfor !12" and name == "mine")
  check("expand_prompt: unknown /name stays", CORE.expand_prompt("/nope x", prompts) == "/nope x")
  check("expand_prompt: plain text", CORE.expand_prompt("hello", prompts) == "hello")

  local refs, all = CORE.find_refs("See !101 and #3001, PR 102, pr #103; again !101, not a&#38; or abc#5")
  local got = {}
  for _, x in ipairs(refs) do got[#got + 1] = x.kind .. x.id end
  check("find_refs: kinds, order, no repeats", table.concat(got, ",") == "pr101,any3001,pr102,pr103", table.concat(got, ","))
  check("find_refs: spans", all[1].s == 5 and all[1].e == 8)
  check("title", CORE.title({ { role = "note", text = "n" }, { role = "you", text = "first\nmessage" } }) == "first message"
    and CORE.title({}) == "(empty)")
  local c = CORE.compose("m", "v", { refs = "- PR !1" })
  check("compose: references section", c:find("## Referenced in the message\n- PR !1", 1, true) ~= nil)
end

-- --- refs (with caches) ----------------------------------------------------------
do
  local REFS = require("azure-cli.chat.refs")
  local S = require("azure-cli.state")
  S.PR_LIST_CACHE = { prs = { { id = 101, title = "Throttle", repo = "w", source = "f", target = "main", author = "Al" } } }
  S.WI_LIST_CACHE = { items = { { id = 3001, type = "Story", title = "Login", state = "Active" } } }
  check("refs: # resolves to a listed PR first", REFS.resolve({ kind = "any", id = 101 }).kind == "pr")
  check("refs: else a work item", REFS.resolve({ kind = "any", id = 3001 }).item.title == "Login")
  local d = REFS.describe("!101 and #3001 and #9")
  check("refs: describe", d:find('PR !101 "Throttle" in w (f -> main), by Al', 1, true)
    and d:find('work item #3001 Story "Login" [Active]', 1, true) and d:find("#9 (a work item, probably", 1, true), d)
  check("refs: at a column", REFS.at("open !101 now", 6).id == 101 and REFS.at("open !101 now", 1) == nil)
  local items = REFS.complete("#", "30")
  check("refs: completion", #items == 1 and items[1].word == "#3001")
  check("refs: ! completes PRs only", #REFS.complete("!", "") == 1)
end

-- --- permissions ---------------------------------------------------------------------
do
  check("permission: reads allow", TOOLS.permission(TOOLS.by_name.get_pr_threads, nil) == "allow")
  check("permission: ask stays ask", TOOLS.permission(TOOLS.by_name.vote, {}) == "ask")
  check("permission: the user's override", TOOLS.permission(TOOLS.by_name.create_branch, { create_branch = "ask" }) == "ask"
    and TOOLS.permission(TOOLS.by_name.vote, { vote = "allow" }) == "allow")
  require("azure-cli").setup({ chat = { agent = { cmd = { "x" } }, permissions = { vote = "deny" } } })
  local listed = false
  for _, t in ipairs(TOOLS.describe()) do if t.name == "vote" then listed = true end end
  check("permission: denied tools aren't listed", not listed)
  local said
  TOOLS.call("vote", { pr_id = 1, vote = "approve" }, { log = function() end }, function(t, err) said = { t, err } end)
  check("permission: a denied call is refused", said[2] == true and said[1]:find("doesn't allow", 1, true))
  require("azure-cli").setup({})
  check("tools: the groups are all there", TOOLS.by_name.start_fix and TOOLS.by_name.get_build_log
    and TOOLS.by_name.move_to_sprint and TOOLS.by_name.open_in_ui and TOOLS.by_name.annotate_code)
  check("tools: every undo op has an undoer", TOOLS.undoers.unlink and TOOLS.undoers.delete_branch and TOOLS.undoers.drop_draft
    and TOOLS.undoers.set_field and TOOLS.undoers.thread_status)
end

-- --- store (in a scratch directory) --------------------------------------------------
do
  local STORE = require("azure-cli.chat.store")
  local tmp = vim.fn.tempname()
  STORE.root = function() return tmp end
  STORE.save({ id = "20260101-000000-aaaa", created = 1, entries = {
    { role = "you", text = "first", view_win = 1000, view = { screen = "x" } },
    { role = "agent", text = "ok", status = "running", snap = { big = true } } } })
  local back = STORE.load_current()
  check("store: saved and current", back and back.id == "20260101-000000-aaaa" and back.title == "first")
  check("store: a running turn is saved as stopped, window ids dropped",
    back.entries[2].status == "stopped" and back.entries[1].view_win == nil and back.entries[2].snap == nil)
  check("store: list", #STORE.list() == 1)
  STORE.audit_add({ tool = "draft_reply", summary = "s", undo = { op = "drop_draft", pr_id = 1,
    item = { kind = "reply", text = "t", thread_id = 4, comment = { huge = true }, thread = {} } } })
  local a = STORE.audit()
  check("store: audit keeps a slim draft", a[1].undo.item.text == "t" and a[1].undo.item.comment == nil)
  STORE.audit_mark_undone(1)
  check("store: undone", STORE.audit()[1].undone ~= nil)
  STORE.forget_current()
  check("store: forget", STORE.load_current() == nil)
  vim.fn.delete(tmp, "rf")
end

-- --- review/chat.lua -----------------------------------------------------------------
do
  local t = RCHAT.thread({ id = 7, status = "fixed", path = "a.py", side = "R", lineno = 4,
    comments = { { author = "A", content = "c", authorId = "x", pending = true } } })
  check("review thread", t.id == 7 and t.file == "a.py" and t.line == 4 and t.comments[1].author == "A"
    and t.comments[1].authorId == nil)
  local map = { { kind = "ctx", side = "R", lineno = 10 }, { kind = "del", side = "L", lineno = 11 },
    { kind = "add", side = "R", lineno = 11 }, { kind = "add", side = "R", lineno = 12 }, { kind = "ctx", side = "R", lineno = 13 } }
  local lines = { " a", "-b", "+B", "+C", " d" }
  check("hunk: the changed run around the cursor", RCHAT.hunk(map, lines, 3) == "--b\n++B\n++C")
  check("hunk: none on an unchanged line", RCHAT.hunk(map, lines, 1) == nil)
  check("hunk: capped", RCHAT.hunk(map, lines, 3, 2) == "--b\n++B")
  local range, side = RCHAT.selection_lines(map, 2, 5)
  check("selection_lines: source side preferred", range == "11-13" and side == "R")
  check("selection_lines: target only", RCHAT.selection_lines(map, 2, 2) == "11")
  check("selection_lines: one line", RCHAT.selection_lines(map, 1, 1) == "10")
end

if fails > 0 then
  print(fails .. " failure(s)")
  vim.cmd("cq")
end
print("all chat tests passed")
vim.cmd("qa!")
