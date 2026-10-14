-- test-chat.lua: unit tests for the chat panel's pure helpers -
-- chat/init.lua (compose, parse_answer, render, models,
-- current_model, expand), chat/view.lua (text), chat/tools.lua
-- (simplify_threads, args_label, the tool list's shape, the ask/write split)
-- and review/chat.lua (thread). They need vim.json and vim.api at load, so
-- this runs under a real headless Neovim:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
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
  -- Shell writes always ask; Edit/Write on a planned file doesn't (#70).
  for name, text in pairs({ first = first, replay = replay }) do
    local missing = {}
    for _, phrase in ipairs({ "with your Edit and Write tools", "never with shell commands or scripts through Bash",
      "sed -i", "always asks the user to allow it", "use delete_fix_file" }) do
      if not text:find(phrase, 1, true) then missing[#missing + 1] = phrase end
    end
    check("compose: the " .. name .. " message says to edit with Edit/Write, not shell", #missing == 0,
      "missing: " .. table.concat(missing, ", "))
  end
end

-- #71: planners read the story's branch in start_story's read-only
-- worktree, not copies of it out of the clone.
do
  local CORE = require("azure-cli.chat.core")
  local AGENTS = require("azure-cli.chat.agents")
  local missing = {}
  for _, phrase in ipairs({ "start_story then only gives you a read-only worktree", "call start_story first",
    "with your Read and Grep tools", "never by copying them out with git show or git archive",
    "which branch and commit its line numbers refer to" }) do
    if not CORE.PREAMBLE:find(phrase, 1, true) then missing[#missing + 1] = phrase end
  end
  check("#71 preamble: plan in start_story's read-only worktree", #missing == 0, "missing: " .. table.concat(missing, ", "))
  check("#71 /plan: reads a work item's code in start_story's worktree",
    CORE.DEFAULT_PROMPTS.plan:find("read-only worktree start_story gives you", 1, true) ~= nil)
  for _, board in ipairs({ "github", "azure" }) do
    local p = AGENTS.plan_prompt({ id = 7, title = "t", board = board ~= "azure" and board or nil })
    check("#71 plan_prompt (" .. board .. "): start_story's read-only worktree first",
      p:find("call start_story for its repository and branch first", 1, true)
        and p:find("read-only worktree of that branch to read with Read/Grep", 1, true), p)
  end
end

-- --- parse_answer / expand ---------------------------------------
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
      .. "complete_pull_request,create_pull_request,create_work_item,run_tests,set_thread_status,set_work_item_parent,"
      .. "set_work_item_state,update_pr_description,vote",
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

  -- Which board a tool works on (GITHUB_PLAN.md phase 6 stage 3): board=,
  -- else the view's, else the only board, else Azure's.
  local ST = require("azure-cli.state")
  local saved_boards = ST.BOARDS
  local function on(args, snap) return TOOLS.board_for(args, { view = function() return snap end }).host end
  ST.BOARDS = { workItems = true, issues = { { owner = "o", project = "3", apiUrl = "https://api.github.com" } } }
  check("board_for: board= first", on({ board = "github" }, { board = "azure" }) == "github"
    and on({ board = "azure" }, { board = "github" }) == "azure")
  check("board_for: else the view's", on({}, { board = "github" }) == "github"
    and on({}, { work_item = { id = 1, board = "github" } }) == "github" and on({}, { screen = "x" }) == "azure")
  ST.BOARDS = { workItems = false, issues = { { owner = "o", project = "3" } } }
  check("board_for: else the only board", on({}, nil) == "github")
  ST.BOARDS = { workItems = true, issues = {} }
  check("board_for: else Azure's, and a stray board= can't reach GitHub", on({}, nil) == "azure"
    and on({ board = "jira" }, nil) == "azure")
  ST.BOARDS = { workItems = true, issues = { { owner = "o", project = "3" } } }
  local GH = require("azure-cli.workitems.board").get("github")
  local AZ = require("azure-cli.workitems.board").get("azure")
  check("wi_ref: owner/repo#n on GitHub only", TOOLS.wi_ref(GH, 7, "o/web") == "o/web#7"
    and TOOLS.wi_ref(GH, 7, "web") == "o/web#7" and TOOLS.wi_ref(GH, 7) == "7" and TOOLS.wi_ref(AZ, 7, "o/web") == "7")
  ST.BOARDS = saved_boards
  for _, name in ipairs({ "list_work_items", "get_work_item", "set_work_item_state", "link_pr_to_work_item",
      "create_branch", "list_sprints", "create_child_task", "create_work_item", "assign_work_item", "move_to_sprint",
      "set_work_item_parent", "comment_on_work_item", "start_story", "create_pull_request", "open_in_ui", "start_agents" }) do
    local props = TOOLS.by_name[name].schema.properties
    check("tools: " .. name .. " takes board", type(props) == "table" and props.board ~= nil
      and props.board.enum[1] == "azure" and props.board.enum[2] == "github")
  end

  -- list_work_items: each row's iteration (Azure: its path; GitHub: its
  -- name, and iteration_id for move_to_sprint).
  local function run_tool(name, args, env)
    local res, err
    TOOLS.by_name[name].run(args, env or {}, function(r, e) res, err = r, e end)
    return res, err
  end
  local saved_caches = { az = AZ.state.WI_LIST_CACHE, gh = GH.state.WI_LIST_CACHE }
  AZ.state.WI_LIST_CACHE = { items = { { id = 5, title = "Az", iterationPath = "Demo\\Sprint 42" } } }
  GH.state.WI_LIST_CACHE = { items = { { id = 12, title = "Gh", repo = "gizmos", iteration = "it2",
    iterationPath = "Iteration 2" }, { id = 13, title = "None", repo = "gizmos", iteration = "", iterationPath = "" } } }
  local az_rows = run_tool("list_work_items", { board = "azure" })
  check("list_work_items: an Azure row's iteration is its path", az_rows and az_rows[1].iteration == "Demo\\Sprint 42"
    and az_rows[1].iteration_id == nil, vim.inspect(az_rows))
  local gh_rows = run_tool("list_work_items", { board = "github" })
  check("list_work_items: a GitHub row's is its iteration's name, with its id", gh_rows
    and gh_rows[1].iteration == "Iteration 2" and gh_rows[1].iteration_id == "it2" and gh_rows[2].iteration == ""
    and gh_rows[2].iteration_id == nil, vim.inspect(gh_rows))

  -- start_agents: each item goes to its agent with its board - board= first,
  -- else the board a list has it on, else board_for's default.
  local AGS = require("azure-cli.chat.agents")
  local real_start, got = AGS.start_for_items, nil
  AGS.start_for_items = function(items) got = items return "ok", {} end
  ST.BOARDS = { workItems = true, issues = {} }
  run_tool("start_agents", { work_item_ids = { 48 }, board = "github" })
  check("start_agents: board = github reaches the agent", got and got[1].id == 48 and got[1].board == "github",
    vim.inspect(got))
  run_tool("start_agents", { work_item_ids = { 48 } }, { view = function() return { board = "github" } end })
  check("start_agents: without board, the view's", got and got[1].board == "github", vim.inspect(got))
  run_tool("start_agents", { work_item_ids = { 48 } })
  check("start_agents: else Azure's", got and got[1].id == 48 and got[1].board == nil, vim.inspect(got))
  run_tool("start_agents", { work_item_ids = { 5 } }, { view = function() return { board = "github" } end })
  check("start_agents: an item the Azure list has stays Azure's", got and got[1].title == "Az" and got[1].board == nil,
    vim.inspect(got))
  run_tool("start_agents", { work_item_ids = { 5, 12 }, board = "github" })
  check("start_agents: board = github doesn't take the Azure item with that id", got and got[1].title == nil
    and got[1].board == "github" and got[2].title == "Gh" and got[2].repo == "gizmos", vim.inspect(got))
  AGS.start_for_items, ST.BOARDS = real_start, saved_boards
  AZ.state.WI_LIST_CACHE, GH.state.WI_LIST_CACHE = saved_caches.az, saved_caches.gh

  -- set_work_item_parent: --wi-edit set-parent on the board's ref, what it
  -- says, the undo that puts the old parent back, and the item's screens
  -- told (workitems/parent.lua's changed: the dashboard's hook).
  do
    local real_provider, calls, answer = TOOLS.provider, {}, nil
    local moved
    local real_hook = GH.state.WI_PARENT_CHANGED
    GH.state.WI_PARENT_CHANGED = function(ref, id, old, new) moved = { ref, id, old, new } end
    TOOLS.provider = function(argv, _, cb)
      calls[#calls + 1] = argv
      if argv[4] == "none" then return cb(true, '{"id": 7, "parent": null, "previous": 3}', "") end
      if argv[4] == "9" then return cb(true, '{"id": 7, "parent": 9, "previous": 9, "unchanged": true}', "") end
      if argv[4] == "5" then return cb(false, "", "#7's parent wasn't changed (it is still under #3): HTTP 400: no") end
      cb(true, '{"id": 7, "parent": 12, "previous": 3}', "")
    end
    ST.BOARDS = { workItems = true, issues = { { owner = "o", project = "3" } } }
    local res, err, undo
    TOOLS.by_name.set_work_item_parent.run({ id = 7, parent_id = 12, board = "github", repo = "o/web" }, {},
      function(r, e, u) res, err, undo = r, e, u end)
    check("set_work_item_parent: set-parent on the issue's ref", calls[1] and calls[1][1] == "--wi-edit"
      and calls[1][2] == "set-parent" and calls[1][3] == "o/web#7" and calls[1][4] == "12", vim.inspect(calls))
    check("set_work_item_parent: says where it was", res == "Moved #7 under #12 (it was under #3)." and not err,
      tostring(res))
    check("set_work_item_parent: the screens are told", moved and moved[1] == "o/web#7" and moved[3] == 3
      and moved[4] == 12, vim.inspect(moved))
    check("set_work_item_parent: the undo puts #3 back", undo and undo.op == "set_parent" and undo.parent == "3"
      and undo.ref == "o/web#7" and undo.board == "github", vim.inspect(undo))
    TOOLS.undoers.set_parent(undo, function(ok, msg) answer = { ok, msg } end)
    check("set_work_item_parent: undoing runs set-parent back", calls[2] and calls[2][3] == "o/web#7"
      and calls[2][4] == "3" and answer[1] == true and answer[2] == "#7 is under #3 again.", vim.inspect(answer))
    TOOLS.by_name.set_work_item_parent.run({ id = 7, parent_id = "none", board = "azure" }, {},
      function(r, e, u) res, err, undo = r, e, u end)
    check("set_work_item_parent: none takes it off, undo puts it back under #3", calls[3][3] == "7"
      and res == "#7 has no parent now (it was under #3)." and undo.parent == "3", tostring(res))
    TOOLS.by_name.set_work_item_parent.run({ id = 7, parent_id = 9, board = "azure" }, {},
      function(r, e, u) res, err, undo = r, e, u end)
    check("set_work_item_parent: unchanged says so, no undo", res == "#7 is already under #9 - nothing changed."
      and undo == nil, tostring(res))
    TOOLS.by_name.set_work_item_parent.run({ id = 7, parent_id = 5, board = "azure" }, {},
      function(r, e, u) res, err, undo = r, e, u end)
    check("set_work_item_parent: a failure says what didn't take", res == nil
      and err:find("still under #3", 1, true) ~= nil, tostring(err))
    check("set_work_item_parent: asks first, naming the move",
      TOOLS.by_name.set_work_item_parent.confirm({ id = 7, parent_id = 12 }) == "move #7 under #12"
        and TOOLS.by_name.set_work_item_parent.confirm({ id = 7, parent_id = "none" }) == "take #7 off its parent")
    TOOLS.provider, GH.state.WI_PARENT_CHANGED, ST.BOARDS = real_provider, real_hook, saved_boards
  end

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
  -- chat.permissions' groups: a tool's own name, then its group, then "all".
  local P = TOOLS.permission
  local vote, list_prs = TOOLS.by_name.vote, { name = "x", risk = "read" }
  check("permissions: all = allow", P(vote, { all = "allow" }) == "allow")
  check("permissions: the group over all", P(vote, { all = "deny", ["azure-vicli-tools"] = "allow" }) == "allow")
  check("permissions: the tool's name over its group", P(vote, { ["azure-vicli-tools"] = "allow", vote = "ask" }) == "ask")
  check("permissions: a group's ask leaves reads alone", P(list_prs, { all = "ask" }) == "allow"
    and P({ name = "y", risk = "write" }, { all = "ask" }) == "ask")
  check("permissions: the agent's groups don't touch azure-vicli's", P(vote, { ["agent-commands"] = "allow" }) == "ask")
  require("azure-cli").setup({ chat = { permissions = { ["agent-edits"] = "allow", all = "deny" } } })
  check("permissions: agent-edits for a file change, all for the rest",
    TOOLS.agent_permission("edit") == "allow" and TOOLS.agent_permission("execute") == "deny")
  require("azure-cli").setup({ chat = { permissions = { ["agent-commands"] = "allow" } } })
  check("permissions: agent-commands for a command, nothing said for an edit",
    TOOLS.agent_permission("execute") == "allow" and TOOLS.agent_permission("edit") == nil)
  require("azure-cli").setup({})
  TOOLS.call("nope", {}, {}, function(text, err) answer = { text, err } end)
  check("call: unknown tool", answer[2] == true and answer[1]:find("unknown tool", 1, true))
end

-- --- render: folding ------------------------------------------------------------
do
  local CORE = require("azure-cli.chat.core")
  local long = {}
  for i = 1, 50 do long[i] = "line " .. i end
  local e = { role = "agent", status = "done", label = "A", text = table.concat(long, "\n"),
    tools = { "\u{00B7} a", "\u{00B7} b", "\u{270E} c", "\u{2717} d: declined", "\u{2713} e: allowed by the plan" } }
  local lines, roles = CORE.render({ e }, 0, "A")
  local all = table.concat(lines, "\n")
  check("render: many tool calls -> one summary line, failures and allowances kept",
    all:find("  \u{270E} 2 lookups, 1 change  (<Tab> shows them)\n  \u{2717} d: declined\n  \u{2713} e: allowed by the plan", 1, true)
      and not all:find("\u{00B7} a", 1, true), all:sub(1, 300))
  check("render: a long answer folds after KEEP_LINES", all:find("line 30\n\u{2026} 20 more lines  (<Tab> unfolds)", 1, true)
    and not all:find("line 31", 1, true) and roles[#lines] == "fold")
  e.open = true
  all = table.concat(CORE.render({ e }, 0, "A"), "\n")
  check("render: open shows everything", all:find("\u{00B7} a", 1, true) and all:find("line 50", 1, true)
    and not all:find("more lines", 1, true))
  e.open, e.status = nil, "running"
  check("render: a running turn shows every call", table.concat(CORE.render({ e }, 0, "A"), "\n"):find("\u{00B7} b", 1, true) ~= nil)
  e.status, e.tools = "done", { "\u{00B7} a", "\u{00B7} b", "\u{00B7} c" }
  check("render: a few calls stay listed", table.concat(CORE.render({ e }, 0, "A"), "\n"):find("\u{00B7} c", 1, true) ~= nil)
end

-- --- messages queued while the agent answers (issue #29) ---------------------------------
do
  local CORE = require("azure-cli.chat.core")
  local entries = { { role = "you", text = "q" }, { role = "agent", status = "running", started = 0, text = "", tools = {} } }
  local plain = CORE.render(entries, 0, "A")
  check("render: no queue draws as before", vim.deep_equal(plain, (CORE.render(entries, 0, "A", {}))))
  local lines, roles, name_end, at = CORE.render(entries, 0, "A", { { text = "first" }, { text = "second\nline", held = true } })
  local n = #plain
  check("render: queued messages after the conversation, in order",
    lines[n + 2]:find("^You  \u{00B7}  queued %(1 of 2%)") and lines[n + 3] == "first"
      and lines[n + 5]:find("^You  \u{00B7}  queued %(2 of 2%)") and lines[n + 6] == "second" and lines[n + 7] == "line",
    vim.inspect(lines))
  check("render: queued roles", roles[n + 2] == "queued_head" and roles[n + 3] == "queued" and name_end[n + 2] == 3)
  check("render: queued lines map to q<n>", at[n + 2] == "q1" and at[n + 3] == "q1" and at[n + 7] == "q2" and at[n + 1] == nil)
  check("render: the keys on a queued message", lines[n + 2]:find("dd cancels, cc edits", 1, true) ~= nil, lines[n + 2])
  check("render: a held one says how to send it", lines[n + 5]:find("held - <CR> sends it", 1, true) ~= nil
    and not lines[n + 2]:find("held", 1, true), lines[n + 5])
  lines = CORE.render(entries, 0, "A", { { text = "x", editing = true } })
  check("render: one being edited says so", lines[n + 2]:find("editing in the input box", 1, true) ~= nil, lines[n + 2])
end

-- --- the status strip ---------------------------------------------------------------
do
  local CORE = require("azure-cli.chat.core")
  check("strip_text: nothing to say", CORE.strip_text({}) == "")
  check("strip_text: all three", CORE.strip_text({ running = { frame = "*", label = "Copilot", seconds = 4 }, question = true,
    waiting = { "#3002" } }) == "* Copilot 4s  \u{00B7}  \u{26A0} a question waits for you  \u{00B7}  \u{25CF} plan #3002 waits for you")
  check("strip_text: several plans", CORE.strip_text({ waiting = { "#1", "PR !2" } }) == "\u{25CF} 2 plans wait for you")
  check("strip_text: one agent of several", CORE.strip_text({ frame = "*", working = { { label = "Claude #7", seconds = 3 } } })
    == "* Claude #7 3s")
  check("strip_text: agents, queue, questions", CORE.strip_text({ frame = "*", working = { {}, {} }, queued = 1, question = true,
    more_questions = 1 }) == "* 2 agents working  \u{00B7}  \u{231B} 1 queued  \u{00B7}  \u{26A0} 2 questions wait for you")
  -- One question at a time: a second one waits for the first's answer.
  local UI = require("azure-cli.ui")
  local real = UI.choose
  local asked = {}
  -- Its popup (ui.lua's M.choose): button 1 Allow, 2 Deny.
  UI.choose = function(o, cb) asked[#asked + 1] = { o.lines[1], function(yes) cb(yes and 1 or 2) end } end
  local answers = {}
  CHAT.confirm("[#1] push?", function(y) answers[#answers + 1] = "1:" .. tostring(y) end)
  CHAT.confirm("[#2] vote?", function(y) answers[#answers + 1] = "2:" .. tostring(y) end)
  check("confirm: the second question waits", #asked == 1 and asked[1][1] == "[#1] push?")
  asked[1][2](true)
  vim.wait(200, function() return #asked == 2 end, 10)
  check("confirm: then it's asked", #asked == 2 and asked[2][1] == "[#2] vote?" and answers[1] == "1:true")
  asked[2][2](false)
  check("confirm: each answer to its own question", answers[2] == "2:false")
  UI.choose = real
end

-- --- desktop toasts for what waits for you ----------------------------------------
do
  local NOTIFY = require("azure-cli.notify")
  local real = NOTIFY.toast
  local toasts = {}
  NOTIFY.toast = function(title, body) toasts[#toasts + 1] = title .. ": " .. body end
  require("azure-cli").setup({ chat = { agent = { cmd = { "x" } } } })
  CHAT._set_focused(true)
  check("alert: not while you're looking (default unfocused)", CHAT.alert("t", "b") == false and #toasts == 0)
  vim.api.nvim_exec_autocmds("FocusLost", {})
  check("alert: once Neovim loses focus", CHAT.alert("t", "b") == true and toasts[1] == "t: b")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  check("alert: not again once it's back", CHAT.alert("t", "b") == false and #toasts == 1)
  require("azure-cli").setup({ chat = { agent = { cmd = { "x" } }, toasts = "always" } })
  check("alert: always", CHAT.alert("t", "c") == true and #toasts == 2)
  require("azure-cli").setup({ chat = { agent = { cmd = { "x" } }, toasts = false } })
  CHAT._set_focused(false)
  check("alert: off", CHAT.alert("t", "d") == false and #toasts == 2)
  local okc = pcall(require("azure-cli").setup, { chat = { toasts = "sometimes" } })
  check("alert: a bad setting is refused", not okc)
  CHAT._set_focused(true)
  NOTIFY.toast = real
  require("azure-cli").setup({})
end

-- --- cost --------------------------------------------------------------------------
do
  local CORE = require("azure-cli.chat.core")
  local r = CORE.stream_new()
  CORE.stream_feed(r, { '{"type":"result","result":"ok","total_cost_usd":0.25,"usage":{"input_tokens":3,"output_tokens":4,'
    .. '"cache_read_input_tokens":10,"cache_creation_input_tokens":20}}', "" }, vim.json.decode)
  check("stream: the result's running cost and its tokens", r.cost_total == 0.25 and r.tokens == 37, vim.inspect({ r.cost_total, r.tokens }))
  check("cost_of: the answers' costs", CORE.cost_of({ { cost = 0.1 }, { text = "x" }, { cost = 0.05 } }) == 0.15000000000000002
    or math.abs(CORE.cost_of({ { cost = 0.1 }, { cost = 0.05 } }) - 0.15) < 1e-9)
  check("cost_of: none reported", CORE.cost_of({ { text = "x" } }) == nil)
  check("money", CORE.money(0.4249) == "$0.42" and CORE.money(0.001) == "<$0.01" and CORE.money(0) == "$0.00" and CORE.money(nil) == "")
end

-- --- why_message ---------------------------------------------------------------
do
  local CORE = require("azure-cli.chat.core")
  local m = CORE.why_message("  \u{270E} create_branch (name=x)  ", "step", "make a branch", "Why from main?")
  check("why_message: the step quoted, the question it answered, the question",
    m:find('About your step to my "make a branch":\n> \u{270E} create_branch (name=x)\n\nWhy from main?', 1, true) ~= nil, m)
  check("why_message: a long question is cut", CORE.why_message("x", "line", string.rep("q", 200), "?")
    :find("...\":", 1, true) ~= nil)
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
  -- Issue #65: Claude Code's answer to an interrupt, and the interrupted
  -- turn's result - which has no `result` text.
  local i = CORE.stream_new()
  CORE.stream_feed(i, { '{"type":"assistant","message":{"content":[{"type":"text","text":"Half an answer"}]}}', "" }, dec)
  check("stream: interrupt ack is recorded by request id", CORE.stream_feed(i,
    { '{"type":"control_response","response":{"subtype":"success","request_id":"azvicli-int-1","response":{}}}', "" }, dec)
    and i.control["azvicli-int-1"] == "success" and not i.ended, vim.inspect(i.control))
  check("stream: a result without text ends the turn", CORE.stream_feed(i, { '{"type":"result","subtype":"error_during_execution",'
    .. '"is_error":true,"session_id":"s-1","total_cost_usd":0.5}', "" }, dec) and i.ended and i.final == nil and i.cost_total == 0.5)
  check("stream: and keeps what was streamed", CORE.stream_text(i) == "Half an answer", CORE.stream_text(i))
  check("interrupt_line", vim.deep_equal(dec(CORE.interrupt_line("azvicli-int-7")),
    { type = "control_request", request_id = "azvicli-int-7", request = { subtype = "interrupt" } }), CORE.interrupt_line("azvicli-int-7"))
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
  -- An "ask" tool that's been allowed some other way (preapproved) runs
  -- without the question - unless chat.permissions says "ask" for it.
  do
    local stub = { name = "stub_push", risk = "ask", schema = { type = "object" },
      preapproved = function(_, cb) cb(true, "the plan") end,
      run = function(_, _, done) done("pushed") end }
    TOOLS.by_name.stub_push = stub
    local asked, logged, got = 0, {}, nil
    local env = { log = function(l) logged[#logged + 1] = l end, confirm = function(_, cb) asked = asked + 1; cb(true) end }
    TOOLS.call("stub_push", {}, env, function(text) got = text end)
    check("preapproved: no question, says why", asked == 0 and got == "pushed"
      and table.concat(logged, "|"):find("allowed by the plan", 1, true) ~= nil, table.concat(logged, "|"))
    stub.preapproved = function(_, cb) cb(false) end
    TOOLS.call("stub_push", {}, env, function() end)
    check("preapproved: not this time -> asks", asked == 1)
    stub.preapproved = function(_, cb) cb(true, "the plan") end
    require("azure-cli").setup({ chat = { agent = { cmd = { "x" } }, permissions = { stub_push = "ask" } } })
    TOOLS.call("stub_push", {}, env, function() end)
    check("preapproved: an explicit \"ask\" in chat.permissions still asks", asked == 2)
    TOOLS.by_name.stub_push = nil
  end
  require("azure-cli").setup({})
  do
    local CH = require("azure-cli.chat")
    check("status: empty while idle", CH.status() == "")
    local cst = require("azure-cli.state").chat
    cst.running = { tick = 0, entry = { started = os.time() } }
    local a = CH.status()
    cst.running.tick = 1
    local b = CH.status()
    cst.running = nil
    check("status: a spinner frame that turns with the tick", a ~= "" and b ~= "" and a ~= b and a:find(" 0s$"), a .. " / " .. b)
  end
  do
    local CHG = require("azure-cli.chat.changes")
    local f = CHG.files({ "diff --git a/x.cs b/x.cs", "index 1..2 100644", "--- a/x.cs", "+++ b/x.cs", "@@ -1 +1 @@", "-a", "+b",
      "diff --git a/n.md b/n.md", "new file mode 100644", "--- /dev/null", "+++ b/n.md", "@@ -0,0 +1 @@", "+hi",
      "diff --git a/d.txt b/d.txt", "deleted file mode 100644", "--- a/d.txt", "+++ /dev/null", "@@ -1 +0,0 @@", "-bye" })
    check("changes: files in diff order with their status", #f == 3 and f[1].path == "x.cs" and f[1].status == "M"
      and f[2].path == "n.md" and f[2].status == "A" and f[3].path == "d.txt" and f[3].status == "D", vim.inspect(f))
  end
  do
    local FIX = require("azure-cli.chat.tools_fix")
    local wt = "/c/wt/App-wi1"
    check("delete_fix_file: paths inside the worktree", FIX.inside(wt, "src/a.cs") == "src/a.cs"
      and FIX.inside(wt, "src\\b.cs") == "src/b.cs" and FIX.inside(wt, "./x/../y.cs") == "y.cs"
      and FIX.inside(wt, wt .. "/docs/m.md") == "docs/m.md")
    check("delete_fix_file: and nothing outside it", FIX.inside(wt, "../other/a.cs") == nil
      and FIX.inside(wt, "/c/wt/App-wi10/a.cs") == nil and FIX.inside(wt, "/etc/passwd") == nil
      and FIX.inside(wt, "x/../../a") == nil and FIX.inside(wt, ".git/config") == nil and FIX.inside(wt, ".") == nil
      and FIX.inside(wt, "") == nil)
    -- show_fix / commit_and_push_fix: the PR's CI (#51).
    local S = require("azure-cli.state")
    local saved = S.PR_LIST_CACHE
    S.PR_LIST_CACHE = { prs = { { id = 120, source = "feature/x", buildStatus = "failed" },
      { id = 121, source = "github-host", buildStatus = "" } } }
    local by_id, by_branch = FIX.ci(120, "whatever"), FIX.ci(nil, "github-host")
    check("ci: a fix's PR by id, with its build", by_id and by_id.pr == 120 and by_id.build == "failed"
      and by_id.note:find("get_build_log", 1, true) ~= nil, vim.inspect(by_id))
    check("ci: a story's PR by its branch, no build reads none", by_branch and by_branch.pr == 121
      and by_branch.build == "none", vim.inspect(by_branch))
    check("ci: nothing without a PR", FIX.ci(nil, "feature/none") == nil and FIX.ci(nil, nil) == nil)
    S.PR_LIST_CACHE = saved
  end
  do
    -- find_implementations / find_definition's patterns against real git grep.
    local C = require("azure-cli.chat.tools_code")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/src", "p")
    vim.fn.writefile({
      "public interface IGripper : IDevice { bool Grip(); }",
      "public class AcsGripper : GripperBase, IGripper",
      "{",
      "    public bool Grip() { return true; }",
      "    internal int LoadPort = 3;",
      "}",
      "public sealed class AdamGripper : IGripper { }",
      "public class FastAcsGripper : AcsGripper { }",
      "class Generic<T> : IGripper<T> where T : class { }",
      "public class Other : IGripperFactory { }",
      "var g = new AcsGripper();",
      "return g.Grip();",
    }, dir .. "/src/G.cs")
    vim.fn.writefile({ "public class JGripper extends Base implements Runnable, IGripper {", "}" }, dir .. "/src/J.java")
    vim.fn.writefile({ "class PyGripper(Base, IGripper):", "    pass" }, dir .. "/src/g.py")
    vim.fn.system({ "git", "-C", dir, "init", "-q" })
    local function grep(pats, name, defs)
      local argv = { "git", "-C", dir, "grep", "-n", "-I", "-E", "--untracked" }
      for _, p in ipairs(pats) do vim.list_extend(argv, { "-e", p }) end
      local types = {}
      for _, h in ipairs(C.parse_hits(vim.fn.system(argv), nil, name, defs)) do
        types[#types + 1] = defs and (h.file .. ":" .. h.line) or C.declared_type(h.text)
      end
      table.sort(types)
      return table.concat(types, ",")
    end
    check("find_implementations: C#, generics, Java and Python, not look-alike names",
      grep(C.implements_patterns("IGripper"), "IGripper") == "AcsGripper,AdamGripper,Generic,JGripper,PyGripper",
      grep(C.implements_patterns("IGripper"), "IGripper"))
    check("find_implementations: the next level down", grep(C.implements_patterns("AcsGripper"), "AcsGripper") == "FastAcsGripper")
    check("find_definition: members and types, not calls", grep(C.definition_patterns("Grip"), "Grip", true) == "src/G.cs:1,src/G.cs:4"
      and grep(C.definition_patterns("LoadPort"), "LoadPort", true) == "src/G.cs:5"
      and grep(C.definition_patterns("AcsGripper"), "AcsGripper", true) == "src/G.cs:2",
      grep(C.definition_patterns("Grip"), "Grip", true))
    vim.fn.delete(dir, "rf")
  end
  do
    -- The change viewer previews the row the cursor settles on, not every
    -- row it passes (debounced like the reviewer's file list).
    local CHG = require("azure-cli.chat.changes")
    local raw = {}
    for f = 1, 3 do
      vim.list_extend(raw, { "diff --git a/f" .. f .. ".txt b/f" .. f .. ".txt", "--- a/f" .. f .. ".txt",
        "+++ b/f" .. f .. ".txt", "@@ -1 +1 @@", "-old" .. f, "+new" .. f })
    end
    local here = vim.api.nvim_get_current_tabpage()
    CHG.open("Proposed change - test", vim.fn.tempname(), raw)
    local lw = vim.fn.win_findbuf(vim.fn.bufnr("azure-cli://changes"))[1]
    local tab = vim.api.nvim_win_get_tabpage(lw)
    local dw
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do if w ~= lw then dw = w end end
    local function shown() return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(dw), 0, -1, false), " ") end
    vim.api.nvim_set_current_win(lw)
    for _, row in ipairs({ 2, 3 }) do
      vim.api.nvim_win_set_cursor(lw, { row, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(lw) })
    end
    local at_once = shown()
    vim.wait(1000, function() return shown():find("new3", 1, true) ~= nil end, 10)
    check("changes: j/k don't wait for each file's diff; the row it rests on is shown",
      at_once:find("new1", 1, true) and shown():find("new3", 1, true), at_once .. " / " .. shown())
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    vim.api.nvim_set_current_tabpage(here)
  end
  do
    -- diffbuf.lua: what the reviewer and the change viewer both move by.
    local D = require("azure-cli.diffbuf")
    local c, a, d = { kind = "ctx" }, { kind = "add" }, { kind = "del" }
    local map = { c, d, a, c, c, a, a, c }  -- blocks at 2-3 and 6-7
    check("diffbuf: ]c / [c inside a file", D.next_change(map, 1, 1) == 2 and D.next_change(map, 2, 1) == 6
      and D.next_change(map, 6, 1) == nil and D.next_change(map, 8, -1) == 6 and D.next_change(map, 7, -1) == 2
      and D.next_change(map, 3, -1) == nil)
    check("diffbuf: where ]c / [c land entering a file", D.edge_change(map, 1) == 2 and D.edge_change(map, -1) == 6
      and D.edge_change({ c, c }, 1) == nil)
    check("diffbuf: winbar stats", D.stats(map) == " (+3 \u{2212}1)" and D.stats(nil) == "")
    check("diffbuf: filetype", D.ft_for_path("src/A.cs") == "cs" and D.ft_for_path("x.cshtml") ~= nil)
  end
  do
    -- The agent CLI's own step log, dimmed apart from its answer.
    local r = require("azure-cli.chat.core").answer_roles({
      "Looking at it.", "", "\u{25CF} Read StubCamera.cs", "  \u{2502} fix-worktrees\\StubCamera.cs", "  \u{2514} 35 lines read",
      "", "Confirmed: use the 3-arg constructor.", "\u{00D7} Run full suite (shell)", "  \u{2514} Permission denied",
      "", "All green.",
    })
    check("answer_roles: steps and what's under them dimmed, failures marked, the answer left alone",
      r[1] == "agent" and r[3] == "agent_log" and r[4] == "agent_log" and r[5] == "agent_log" and r[7] == "agent"
        and r[8] == "tool_err" and r[9] == "tool_err" and r[11] == "agent", vim.inspect(r))
  end
  check("tools: the groups are all there", TOOLS.by_name.start_fix and TOOLS.by_name.start_story and TOOLS.by_name.get_build_log and TOOLS.by_name.get_test_results
    and TOOLS.by_name.move_to_sprint and TOOLS.by_name.open_in_ui and TOOLS.by_name.annotate_code)
  check("tools: every undo op has an undoer", TOOLS.undoers.unlink and TOOLS.undoers.delete_branch and TOOLS.undoers.drop_draft
    and TOOLS.undoers.set_field and TOOLS.undoers.set_parent and TOOLS.undoers.thread_status)
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

-- --- chat/watch.lua: the chat's PRs, watched for new comments --------------------------
do
  local W = require("azure-cli.chat.watch")
  local CH = require("azure-cli.chat")
  local T = require("azure-cli.chat.tools")
  local AG = require("azure-cli.chat.agents")
  local ST = require("azure-cli.state")
  local orig = { agent = CH.current_agent, note = CH.note, alert = CH.alert, provider = T.provider,
    start = AG.start_for_prs }
  local notes, started, busy, status = {}, {}, false, "active"
  local threads = { { id = 1, comments = { { id = 1, author = { id = "me" }, content = "mine" } } } }
  local function comment(tid, cid, who)
    for _, t in ipairs(threads) do
      if t.id == tid then table.insert(t.comments, { id = cid, author = { id = who }, content = "c" }) return end
    end
    table.insert(threads, { id = tid, comments = { { id = cid, author = { id = who }, content = "c" } } })
  end
  CH.current_agent = function() return { name = "x" } end
  CH.note = function(t) notes[#notes + 1] = t end
  CH.alert = function() end
  T.provider = function(argv, _, cb)
    if argv[1] == "--get-pr" then
      return cb(true, vim.json.encode({ id = 500, title = "T", state = status, org = "o", project = "p", repo = "r" }), "")
    end
    cb(true, vim.json.encode({ value = threads }), "")
  end
  AG.start_for_prs = function(prs, of)
    if busy then return "busy", {} end
    started[#started + 1] = { id = prs[1].id, threads = of[prs[1].id] }
    return "ok", { "PR !500" }
  end
  ST.whoami = { ["o|p"] = { id = "me" } }
  W._reset()
  pcall(vim.fn.delete, require("azure-cli.chat.store").root() .. "/watched.json")
  require("azure-cli.config").setup({})
  W.add({ id = 500, org = "o", project = "p", repo = "r" })
  W.poll()
  check("watch: what's there when it starts isn't new", W.watched(500) and #notes == 0 and #started == 0)
  comment(2, 1, "alice")
  W.poll()
  check("watch: new ones wait for a quiet poll", #notes == 0)
  W.poll()
  check("watch: then the chat says so (suggest)", #notes == 1 and notes[1]:find("1 new comment", 1, true) ~= nil
    and notes[1]:find("/triage", 1, true) ~= nil and #started == 0, vim.inspect(notes))
  comment(1, 2, "me")
  W.poll(); W.poll()
  check("watch: my own comments don't count", #notes == 1, vim.inspect(notes))
  require("azure-cli.config").setup({ chat = { on_new_comments = "plan" } })
  comment(1, 3, "bob"); comment(3, 1, "carol")
  busy = true
  W.poll(); W.poll()
  check("watch: plan - its agent busy, it waits", #started == 0 and #notes == 1)
  W._reset()  -- a restart in between: what's pending is kept
  busy = false
  W.poll()
  check("watch: plan - an agent for just the new threads", #started == 1 and vim.deep_equal(started[1].threads, { 1, 3 })
    and notes[2] and notes[2]:find("2 new comments", 1, true) ~= nil and notes[2]:find("planning", 1, true) ~= nil,
    vim.inspect({ started, notes }))
  -- Its plans: the PR's own, and a story's that opened it (link_pr).
  local PL = require("azure-cli.chat.plan")
  PL.save({ key = "pr-500", target = { pr_id = 500 }, status = "approved", revisions = {}, threads = {} })
  PL.save({ key = "wi-77", target = { work_item_id = 77 }, status = "done", revisions = {}, threads = {} })
  PL.save({ key = "wi-78", target = { work_item_id = 78 }, status = "done", revisions = {}, threads = {} })
  PL.link_pr({ 77 }, "feature/none", { id = 500, org = "o", project = "p" })
  check("link_pr: the story's plan knows its PR", PL.load("wi-77").pr.id == 500 and PL.load("wi-78").pr == nil)
  status = "completed"
  W.poll()
  check("watch: a completed PR isn't watched any more", not W.watched(500))
  check("watch: its plans are finished", PL.load("pr-500").pr_state == "completed"
    and PL.load("wi-77").pr_state == "completed" and PL.load("wi-77").closed_at and PL.load("wi-78").pr_state == nil)
  check("finished: the plan's status says so", (PL.status_label(PL.load("wi-77"))):find("PR merged", 1, true) ~= nil)
  for _, k in ipairs({ "pr-500", "wi-77", "wi-78" }) do pcall(vim.fn.delete, PL.root() .. "/" .. k .. ".json") end
  W._reset()
  CH.current_agent, CH.note, CH.alert, T.provider, AG.start_for_prs = orig.agent, orig.note, orig.alert, orig.provider,
    orig.start
  require("azure-cli.config").setup({})
end

-- --- a PR an agent opened: its comments go back to that agent ------------------------
do
  local PL = require("azure-cli.chat.plan")
  local AG = require("azure-cli.chat.agents")
  local CH = require("azure-cli.chat")
  PL.save({ key = "wi-91", target = { work_item_id = 91 }, title = "Lockout", status = "done", revisions = {}, threads = {},
    pr = { id = 610 } })
  check("owner_of_pr: the plan that opened it", (PL.owner_of_pr(610) or {}).key == "wi-91" and PL.owner_of_pr(611) == nil)
  local TF = require("azure-cli.chat.tools_fix")
  local orig_find = TF.find_story
  TF.find_story = function(id) if tostring(id) == "92" then return "/w/r-wi92", "feature/92-old" end end
  PL.save({ key = "wi-92", target = { work_item_id = 92 }, status = "done", revisions = {}, threads = {} })
  check("owner_of_pr: an older PR, by its story's branch", (PL.owner_of_pr(700, "feature/92-old") or {}).key == "wi-92"
    and PL.owner_of_pr(700, "feature/other") == nil)
  TF.find_story = orig_find
  pcall(vim.fn.delete, PL.root() .. "/wi-92.json")
  local orig = { send = CH.send, agent = CH.current_agent }
  local sent = {}
  CH.current_agent = function() return { name = "x" } end
  CH.send = function(text, o) sent[#sent + 1] = { text = text, key = o.conv.plan_key or o.conv.key, display = o.display } return {} end
  AG.start_for_prs({ { id = 610, title = "T" }, { id = 611, title = "U" } }, { [610] = { 4 } })
  local by = {}
  for _, s in ipairs(sent) do by[s.key or "?"] = s end
  check("start_for_prs: an agent's own PR goes to its conversation, as a new revision of its plan", by["wi-91"] ~= nil
    and by["wi-91"].text:find("work_item_id 91", 1, true) ~= nil and by["wi-91"].text:find("thread 4", 1, true) ~= nil
    and by["wi-91"].text:find("^/plan ") ~= nil, vim.inspect(sent))
  check("start_for_prs: anyone else's PR gets an agent of its own", by["pr-611"] ~= nil, vim.inspect(sent))
  CH.send, CH.current_agent = orig.send, orig.agent
  AG.reset()
  pcall(vim.fn.delete, PL.root() .. "/wi-91.json")
end

-- --- chat/notes.lua: annotate_code's notes, kept across restarts ----------------------
do
  local NOTES = require("azure-cli.chat.notes")
  local STATE = require("azure-cli.state")
  local n = NOTES.add(4242, { file = "a.py", line = 3, side = "R", text = "look", kind = "info" })
  STATE.chat_notes["4242"][1].code = "x = 1"
  NOTES.save(4242)
  STATE.chat_notes = nil  -- a restart
  local back = NOTES.get(4242)
  check("notes: saved and read back after a restart", n == 1 and #back == 1 and back[1].text == "look"
    and back[1].code == "x = 1", vim.inspect(back))
  check("notes: moved once the line reads differently", NOTES.moved(back[1], "x = 2")
    and not NOTES.moved(back[1], "  x =  1 ") and not NOTES.moved({ text = "t" }, "anything"))
  NOTES.clear(4242)
  STATE.chat_notes = nil
  check("notes: clear forgets them on disk too", #NOTES.get(4242) == 0)
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
  local notes = { { file = "a.py", line = 11 }, { file = "a.py", line = 11, side = "L" }, { file = "c.py", line = 1 } }
  local rows = RCHAT.note_rows(notes, "a.py", map)
  check("note_rows: each side's line, in order", vim.deep_equal(rows, { 2, 3 }), vim.inspect(rows))
  check("next_row: past the cursor either way", RCHAT.next_row(rows, 2, 1) == 3 and RCHAT.next_row(rows, 3, -1) == 2
    and RCHAT.next_row(rows, 3, 1) == nil and RCHAT.next_row(rows, 1, -1) == nil)
  local order = { "a.py", "b.py", "c.py" }
  check("next_note_file: skips files without notes", RCHAT.next_note_file(notes, order, 1, 1) == 3
    and RCHAT.next_note_file(notes, order, 3, -1) == 1 and RCHAT.next_note_file(notes, order, 3, 1) == nil
    and RCHAT.next_note_file(notes, order, nil, 1) == 1 and RCHAT.next_note_file(notes, order, nil, -1) == 3)
end

if fails > 0 then
  print(fails .. " failure(s)")
  vim.cmd("cq")
end
print("all chat tests passed")
vim.cmd("qa!")
