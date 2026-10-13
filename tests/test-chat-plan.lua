-- test-chat-plan.lua: the pure parts of the agent's plan (chat/plan.lua),
-- the questions under a line (chat/threads.lua) and the change viewer's
-- file list (chat/changes.lua). Needs vim.split/vim.fn, so it runs under a
-- real headless Neovim:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-plan.lua
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local PLAN = require("azure-cli.chat.plan")
local TH = require("azure-cli.chat.threads")
local CH = require("azure-cli.chat.changes")

local plan = vim.split(table.concat({
  "# Title", "", "## Goal", "x", "", "## Approach", "- one", "- two", "",
  "## Files", "- `src/auth.py` - the check", "- ./src/throttle.py: the counter", "* tests/test_x.py",
  "```", "## not a heading", "- `not/a/file.py`", "```", "", "## Risks", "- `src/other.py` isn't a planned file",
}, "\n"), "\n", { plain = true })

-- --- sections / section_at / missing ------------------------------------------
do
  local s = PLAN.sections(plan)
  local titles = {}
  for _, x in ipairs(s) do titles[#titles + 1] = x.title end
  check("sections: headings in order, fenced ones skipped", table.concat(titles, "|") == "Title|Goal|Approach|Files|Risks",
    table.concat(titles, "|"))
  check("sections: list items counted", s[3].items == 2 and s[4].items == 3, s[4].items)
  check("section_at", PLAN.section_at(s, 7).title == "Approach" and PLAN.section_at(s, 1).title == "Title")
  local miss = PLAN.missing(table.concat(plan, "\n"), PLAN.TEMPLATE)
  check("missing: the template's sections not there", table.concat(miss, "|") == "Test plan|Open questions",
    table.concat(miss, "|"))
end

-- --- planned_files / check_files ----------------------------------------------------
do
  local files = PLAN.planned_files(plan)
  check("planned_files: code spans, ./ dropped, punctuation off, only the Files section",
    table.concat(files, "|") == "src/auth.py|src/throttle.py|tests/test_x.py", table.concat(files, "|"))
  local c = PLAN.check_files({ "src/auth.py", "throttle.py", "docs/x.md" }, { "src/auth.py", "src/throttle.py", "config.py" })
  check("check_files: suffix matches, both directions",
    table.concat(c.unplanned, "|") == "config.py" and table.concat(c.missing, "|") == "docs/x.md",
    vim.inspect(c))
  check("check_files: partial names don't match", #PLAN.check_files({ "auth.py" }, { "src/oauth.py" }).missing == 1)
end

-- --- step links ------------------------------------------------------------------------
do
  check("resolve_line: by its text, nearest", PLAN.resolve_line({ "a", "x", "b", "x" }, 3, "x") == 2
    or PLAN.resolve_line({ "a", "x", "b", "x" }, 3, "x") == 4)
  check("resolve_line: text gone -> the line, if inside", PLAN.resolve_line({ "a", "b" }, 2, "zzz") == 2
    and PLAN.resolve_line({ "a" }, 5, "zzz") == nil)
  check("file_entry_line", PLAN.file_entry_line(plan, "throttle.py") == 12 and PLAN.file_entry_line(plan, "src/other.py") == nil,
    PLAN.file_entry_line(plan, "throttle.py"))
  check("file_at_line", PLAN.file_at_line(plan, 11) == "src/auth.py" and PLAN.file_at_line(plan, 7) == nil)
  local links = { { file = "src/a.py", line = 10, plan_line = 7, plan_anchor = "- one" },
    { file = "src/a.py", line = 30, plan_line = 8, plan_anchor = "- two" },
    { file = "b.py", line = 1, plan_line = 7, plan_anchor = "- one" } }
  check("links_on_plan_line", #PLAN.links_on_plan_line(links, plan, 7) == 2 and #PLAN.links_on_plan_line(links, plan, 9) == 0)
  check("link_for_code: the step at or above the line",
    PLAN.link_for_code(links, "src/a.py", 25).line == 10 and PLAN.link_for_code(links, "src/a.py", 30).line == 30
      and PLAN.link_for_code(links, "src/a.py", 5) == nil and PLAN.link_for_code(links, "a.py", 12).line == 10)
end

-- --- revision_changes -----------------------------------------------------------------
do
  local diff = vim.text and vim.text.diff or vim.diff
  local function changes(old, new)
    local h = diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", { result_type = "indices" })
    return PLAN.revision_changes(old, new, h)
  end
  local c = changes({ "a", "b", "c" }, { "a", "B", "c", "d" })
  check("revision_changes: changed and added lines", c.changed[2] and c.changed[4] and not c.changed[1]
    and next(c.removed) == nil, vim.inspect(c))
  c = changes({ "a", "b", "c" }, { "a", "c" })
  check("revision_changes: a removed line shows above the next one", c.removed[2] and c.removed[2][1] == "b"
    and next(c.changed) == nil, vim.inspect(c))
  c = changes({ "a", "b", "c" }, { "a" })
  check("revision_changes: removed at the end", c.removed[2] and #c.removed[2] == 2, vim.inspect(c))
  c = changes({ "a", "b", "c", "d" }, { "a", "X", "d" })
  check("revision_changes: two lines became one", c.changed[2] and c.removed[3] and c.removed[3][1] == "c",
    vim.inspect(c))
end

-- --- gate_check -------------------------------------------------------------------------
do
  local wi, pr = { work_item_id = 7 }, { pr_id = 9 }
  check("gate: off", PLAN.gate_check(nil, false, wi) == true)
  check("gate: stories only lets a fix through", PLAN.gate_check(nil, "stories", pr) == true)
  local ok, why = PLAN.gate_check(nil, "stories", wi)
  check("gate: stories only stops a story", ok == false and why:find("No plan for #7", 1, true))
  ok, why = PLAN.gate_check(nil, nil, pr)
  check("gate: default on, no plan", ok == false and why:find("PR !9", 1, true))
  check("gate: approved", PLAN.gate_check({ status = "approved" }, true, wi) == true)
  ok, why = PLAN.gate_check({ status = "draft" }, true, wi)
  check("gate: draft waits", ok == false and why:find("isn't approved yet", 1, true))
  ok, why = PLAN.gate_check({ status = "changes_requested" }, true, wi)
  check("gate: changes asked for", ok == false and why:find("Revise it", 1, true))
  ok, why = PLAN.gate_check({ status = "done" }, true, wi)
  check("gate: done needs a new plan", ok == false and why:find("new plan", 1, true))
end

-- --- push_check ------------------------------------------------------------------------
do
  local rec = { allow_push = true, status = "approved" }
  check("push_check: allowed, no test command", PLAN.push_check(rec, false) == true)
  check("push_check: not allowed", PLAN.push_check({ status = "approved" }, false) == false)
  check("push_check: not approved any more", PLAN.push_check({ allow_push = true, status = "draft" }, false) == false)
  check("push_check: tests needed but never ran", PLAN.push_check(rec, true, nil, "f") == false)
  check("push_check: tests on an older change", PLAN.push_check(rec, true, { code = 0, fingerprint = "old" }, "f") == false)
  check("push_check: tests failed", PLAN.push_check(rec, true, { code = 1, fingerprint = "f" }, "f") == false)
  check("push_check: tests passed on this change", PLAN.push_check(rec, true, { code = 0, fingerprint = "f" }, "f") == true)
end

-- --- run_log ---------------------------------------------------------------------------
do
  local rec = { target = { work_item_id = 9 }, title = "T", status = "approved", allow_push = true,
    revisions = { {}, {} },
    events = { { at = 30, text = "Approved revision 2" }, { at = 10, text = "Revision 1, by the agent" } },
    threads = { { at = 20, line = 4, question = "Why?", answer = "Because.", anchor = "x = 1" },
      { at = 25, kind = "request", line = 5, question = "Rename it" } } }
  local log = table.concat(PLAN.run_log(rec, {
    threads = { { at = 40, file = "a.py", line = 3, question = "And here?", answer = "So." } },
    audit = { { at = 15, tool = "start_story", summary = "{...}" } },
    tests = { cmd = "make test", code = 0, at = 50, output = { "ok" } },
    lines = { "# T", "## Goal", "g" },
  }, function(ts) return "t" .. ts end), "\n")
  check("run_log: one timeline, in order", log:find("- t10  Revision 1, by the agent\n- t15  Agent: start_story - {...}\n"
    .. "- t20  You asked about plan line 4: Why?\n- t25  You asked for a change on plan line 5: Rename it\n"
    .. "- t30  Approved revision 2\n- t40  You asked about a.py:3: And here?", 1, true) ~= nil, log)
  check("run_log: questions with their answers", log:find("### Plan line 4: Why?\n\n> x = 1\n\nBecause.", 1, true)
    and log:find("### a.py:3: And here?\n\nSo.", 1, true))
  check("run_log: status, tests, the plan one level down", log:find("Status: Approved (pushing allowed) · 2 revisions", 1, true)
    and log:find("`make test` - exit 0, t50", 1, true) and log:find("\n## T\n### Goal\ng", 1, true))
end

-- --- pull request description ------------------------------------------------------------
do
  local lines = { "# T", "", "## Goal", "", "Do x.", "", "## Approach", "Like this.", "### Detail", "more", "```sh",
    "## not a heading", "```", "", "## Files", "- a.py", "## Test plan", "Run it." }
  check("section_text: up to the next heading, sub-headings and fences kept",
    table.concat(PLAN.section_text(lines, "approach"), "|") == "Like this.|### Detail|more|```sh|## not a heading|```",
    table.concat(PLAN.section_text(lines, "approach"), "|"))
  local d = PLAN.pr_description({ target = { work_item_id = 4 }, revisions = { {}, {} },
    threads = { { answer = "a" }, { kind = "request", question = "q" } } }, lines)
  check("pr_description: Goal, Approach, Test plan (no Files), and where it came from",
    d:find("^## Goal\nDo x.\n\n## Approach\nLike this.") and not d:find("## Files", 1, true)
      and d:sub(-#"## Test plan\nRun it.\n\n_From the plan for #4 (revision 2, 1 question answered)._")
        == "## Test plan\nRun it.\n\n_From the plan for #4 (revision 2, 1 question answered)._", d)
end

-- --- chat/skills.lua: the agent's skills, and the ones you allowed ---------------------------
do
  local SK = require("azure-cli.chat.skills")
  local names = { "triage-pr-comments", "review" }
  check("skills: named as /x, the x skill, skill x, `x`", SK.named_in("/triage-pr-comments on this PR", names)
    == "triage-pr-comments" and SK.named_in("use the Triage-PR-Comments skill", names) == "triage-pr-comments"
    and SK.named_in("run skill: review now", names) == "review" and SK.named_in("try `review`", names) == "review")
  check("skills: not just a word in passing", SK.named_in("please review this", names) == nil
    and SK.named_in("/triage-pr-commentsx", names) == nil and SK.named_in("", names) == nil)
  check("skills: a tool call loading one", SK.in_tool_call({ title = "Skill", rawInput = { skill = "review" } }, names)
    == "review" and SK.in_tool_call({ title = "Read review.md" }, names) == nil)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.github/skills/deploy-check", "p")
  vim.fn.writefile({ "---", "name: deploy-check", "---" }, dir .. "/.github/skills/deploy-check/SKILL.md")
  vim.fn.mkdir(dir .. "/.claude/skills/not-a-skill", "p")
  check("skills: found where the agent runs", vim.tbl_contains(SK.available(dir), "deploy-check")
    and not vim.tbl_contains(SK.available(dir), "not-a-skill"))
  vim.fn.writefile({ "---", "name: deploy-check", "description: \"Checks a deploy\"", "---" },
    dir .. "/.github/skills/deploy-check/SKILL.md")
  vim.fn.mkdir(dir .. "/.claude/skills/notes", "p")
  vim.fn.writefile({ "# Takes notes", "", "body" }, dir .. "/.claude/skills/notes/SKILL.md")
  local by = {}
  for _, s in ipairs(SK.list(dir)) do by[s.name] = s end
  check("skills: a description from the front matter, else the first line",
    by["deploy-check"] and by["deploy-check"].description == "Checks a deploy" and by.notes
      and by.notes.description == "Takes notes", vim.inspect(by))
  local report = SK.report(dir)
  check("skills: /skills lists them", report:find("/deploy-check  - Checks a deploy", 1, true) ~= nil
    and report:find("/notes  - Takes notes", 1, true) ~= nil, report)
  vim.fn.mkdir(dir .. "/mine/own", "p")
  vim.fn.writefile({ "x" }, dir .. "/mine/own/SKILL.md")
  require("azure-cli").setup({ chat = { skill_dirs = { "mine", dir .. "/.claude/skills" } } })
  local found = SK.available(dir)
  check("skills: chat.skill_dirs replaces the folders, relative or absolute",
    vim.tbl_contains(found, "own") and vim.tbl_contains(found, "notes") and not vim.tbl_contains(found, "deploy-check"),
    vim.inspect(found))
  require("azure-cli").setup({ chat = { skill_dirs = { "mine" } } })
  check("skills: none found says where it looked", SK.report(vim.fn.tempname()):find("^No skills found%. Looked for %*/SKILL%.md in mine") ~= nil)
  check("skills: chat.skill_dirs must be folders", not pcall(require("azure-cli").setup, { chat = { skill_dirs = { 1 } } }))
  SK._reset()
  pcall(vim.fn.delete, require("azure-cli.chat.store").root() .. "/allowed_skills.json")
  require("azure-cli").setup({ chat = { allowed_skills = { "review" } } })
  check("skills: allowed in setup", SK.allowed("review") and not SK.allowed("deploy-check"))
  SK.allow("deploy-check")
  SK._reset()
  check("skills: allowed from the popup, kept", SK.allowed("deploy-check"))
  check("skills: disallowed again, kept", SK.disallow("deploy-check") and not SK.allowed("deploy-check")
    and (SK._reset() or true) and not SK.allowed("deploy-check"))
  check("skills: one allowed in setup can't be disallowed here", SK.disallow("review") == false and SK.allowed("review"))
  -- /skills' popup: <Space> allows / makes it ask again, <CR> uses one.
  local used
  local pwin, pbuf = SK.popup(dir, function(name) used = name end)
  local function key(k) vim.fn.maparg(k, "n", false, true).callback() end
  local plines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
  local drow
  for i, l in ipairs(plines) do if not drow and l:find("/deploy-check", 1, true) then drow = i end end
  check("skills popup: a row per skill with its description, then its folder", drow
    and plines[drow] == "   /deploy-check  Checks a deploy" and plines[drow + 1]:sub(-#"/skills/deploy-check") == "/skills/deploy-check", vim.inspect(plines))
  vim.api.nvim_win_set_cursor(pwin, { drow + 1, 0 })
  key("<Space>")
  check("skills popup: <Space> allows it (from its folder line too), shown and kept",
    SK.allowed("deploy-check") and vim.api.nvim_buf_get_lines(pbuf, drow - 1, drow, false)[1]:find("^ \u{2713} /deploy%-check") ~= nil,
    vim.api.nvim_buf_get_lines(pbuf, 0, -1, false))
  key("<Space>")
  check("skills popup: <Space> again makes it ask", not SK.allowed("deploy-check"))
  key("<CR>")
  check("skills popup: <CR> closes it and uses the skill", used == "deploy-check" and not vim.api.nvim_win_is_valid(pwin), used)
  check("skills popup: none found opens nothing", SK.popup(vim.fn.tempname(), function() end) == nil)
  require("azure-cli").setup({})
  pcall(vim.fn.delete, require("azure-cli.chat.store").root() .. "/allowed_skills.json")
  SK._reset()
end

-- --- approving with pushing allowed: the push and the PR without asking ----------------------
do
  local wi = { key = "wi-55", target = { work_item_id = 55 }, revisions = { { markdown = "x" } }, threads = {}, allow_push = true }
  local lines = { "## Test plan", "```sh", "dotnet test", "```" }
  local m = PLAN.approval_message(wi, lines)
  check("approval_message: may push - run_tests, push, then open the PR", m:find("run_tests", 1, true) ~= nil
    and m:find("commit_and_push_fix (work_item_id 55)", 1, true) ~= nil and m:find("create_pull_request", 1, true) ~= nil
    and m:find("not a draft", 1, true) ~= nil, m)
  local pr = { key = "pr-9", target = { pr_id = 9 }, revisions = { { markdown = "x" } }, threads = {}, allow_push = true }
  m = PLAN.approval_message(pr, {})
  check("approval_message: a PR's plan pushes (no tests to run), opens no PR", m:find("commit_and_push_fix (pr_id 9)", 1, true)
    ~= nil and not m:find("create_pull_request", 1, true) and not m:find("run_tests", 1, true), m)
  wi.allow_push = nil
  check("approval_message: plain approval says nothing of pushing", not PLAN.approval_message(wi, lines):find("push", 1, true))

  local TF = require("azure-cli.chat.tools_fix")
  local orig = TF.find_story
  TF.find_story = function(id) if tostring(id) == "55" then return "/w/r-wi55", "feature/55-x", "develop" end end
  PLAN.save({ key = "wi-55", target = { work_item_id = 55 }, status = "done", allow_push = true, revisions = {}, threads = {} })
  local function allowed(a)
    local r
    PLAN.pr_allowed(a, function(ok, why) r = { ok, why } end)
    return r
  end
  local good = { source = "feature/55-x", target = "develop", work_item_ids = { 55 } }
  check("pr_allowed: its PR, once pushed", allowed(good)[1] == true)
  check("pr_allowed: into another branch asks, saying why", allowed({ source = "feature/55-x", target = "main",
    work_item_ids = { 55 } })[2]:find("not develop", 1, true) ~= nil)
  check("pr_allowed: without linking the work item asks", allowed({ source = "feature/55-x", target = "develop" })[1] == false)
  local rec = PLAN.load("wi-55"); rec.status = "approved"; PLAN.save(rec)
  check("pr_allowed: before the push asks", allowed(good)[2] == "the plan's change isn't pushed yet")
  rec.status, rec.pr = "done", { id = 3 }; PLAN.save(rec)
  check("pr_allowed: a second PR asks", (allowed(good)[2] or ""):find("already opened PR !3", 1, true) ~= nil)
  rec.pr, rec.allow_push = nil, nil; PLAN.save(rec)
  local r = allowed(good)
  check("pr_allowed: not allowed - asks, nothing to explain", r[1] == false and r[2] == nil)
  TF.find_story = orig
  pcall(vim.fn.delete, PLAN.root() .. "/wi-55.json")
end

-- --- the Agents screen's rows ---------------------------------------------------------------
do
  local AV = require("azure-cli.chat.agents_view")
  local convs = {
    { entries = {} },  -- the main conversation: no row
    { plan_key = "wi-1", label = "#1", title = "One", running = {}, entries = { { started = 90, tools = { "\u{270E} start_story (x)" } } } },
    { plan_key = "wi-2", label = "#2", entries = { { started = 40, status = "done", cost = 0.3 }, { cost = 0.2 } } },
    { plan_key = "wi-4", label = "#4", entries = { { started = 95, status = "failed (exit 1)" } } },
  }
  local plans = { ["wi-2"] = { status = "draft", title = "Two" } }
  local rows = AV.rows(convs, { { key = "wi-3", label = "#3", title = "Three", target = { work_item_id = 3 } },
    { key = "wi-1", label = "#1", target = { work_item_id = 1 } } },
    function(k) return plans[k] end, 100, "*")
  check("agents rows: one per plan's agent, then the queued ones not running", #rows == 4, #rows)
  check("agents rows: working, with its last step", rows[1].state == "* working" and rows[1].detail == "\u{270E} start_story (x)"
    and rows[1].ago == "10s" and rows[1].title == "One")
  check("agents rows: a plan waiting for you, titled from the plan", rows[2].state:find("plan waits for you", 1, true)
    and rows[2].title == "Two")
  check("agents rows: a failed answer", rows[3].state:find("failed (exit 1)", 1, true) ~= nil)
  check("agents rows: what each cost", rows[2].cost == 0.5 and rows[1].cost == nil)
  check("agents rows: queued", rows[4].label == "#3" and rows[4].state:find("waiting for an agent", 1, true) ~= nil)
  local done = {
    { plan_key = "wi-5", label = "#5", entries = {} }, { plan_key = "wi-6", label = "#6", entries = {} },
    { plan_key = "pr-7", label = "!7", target = { pr_id = 7 }, entries = {} },
    { plan_key = "wi-8", label = "#8", entries = {} },
  }
  local recs = { ["wi-5"] = { status = "done", pr = { id = 50 } }, ["wi-6"] = { status = "done", pr = { id = 60 },
    pr_state = "completed" }, ["pr-7"] = { status = "approved", pr_state = "abandoned" }, ["wi-8"] = { status = "done" } }
  rows = AV.rows(done, {}, function(k) return recs[k] end, 100)
  check("agents rows: pushed with its PR open", rows[1].state:find("PR !50 open", 1, true) ~= nil, rows[1].state)
  check("agents rows: finished - its PR merged", rows[2].state:find("merged (PR !60)", 1, true) ~= nil, rows[2].state)
  check("agents rows: finished - its PR abandoned", rows[3].state:find("abandoned", 1, true) ~= nil, rows[3].state)
  check("agents rows: pushed, no PR yet", rows[4].state:find("pushed", 1, true) ~= nil, rows[4].state)
  -- Grouped: what needs you first, the most recent first in each group.
  local day = 86400
  local list = {
    { key = "a", group = 3, at = 10 }, { key = "b", group = 1, at = 5 }, { key = "c", group = 4, at = 1, closed_at = 1000 * day - 2 * day },
    { key = "d", group = 1, at = 9 }, { key = "e", group = 2, at = 0 }, { key = "f", group = 2, at = 0 },
    { key = "g", group = 4, at = 1, closed_at = 1000 * day - 8 * day },
  }
  local out, hidden = AV.arrange(list, 1000 * day)
  local got = {}
  for _, r in ipairs(out) do got[#got + 1] = r.header or r.key end
  check("arrange: groups in order with counts, newest first, queued in their order",
    table.concat(got, ",") == "Needs you (2),d,b,Working (2),e,f,In progress (1),a,Finished (1),c", table.concat(got, ","))
  check("arrange: finished over a week ago hidden", hidden == 1)
  out, hidden = AV.arrange(list, 1000 * day, true)
  check("arrange: all shows them", hidden == 0 and out[#out].key == "g" and out[#out - 2].header == "Finished (2)")
  local at = { [2] = true, [5] = true, [6] = true }  -- rows on lines 2, 5 and 6; headers and gaps between
  check("step_to_row: over a gap and a header, both ways", AV.step_to_row(at, 2, 3, 8) == 5
    and AV.step_to_row(at, 5, 4, 8) == 2 and AV.step_to_row(at, 5, 6, 8) == 6)
  check("step_to_row: nothing further - stays", AV.step_to_row(at, 6, 7, 8) == 6 and AV.step_to_row(at, 2, 1, 8) == 2)
  check("agents rows: their groups", rows[1].group == 3 and rows[2].group == 4 and rows[3].group == 4)
end

-- --- open questions and your answers ---------------------------------------------------------
do
  local lines = { "## Goal", "x?", "## Open questions", "- Should admins be exempt?", "1. Error or fallback?",
    "Is this a question?", "None", "plain note", "```", "- not one?", "```", "## Risks", "- r?" }
  local qs = PLAN.open_questions(lines)
  local got = {}
  for _, q in ipairs(qs) do got[#got + 1] = q.line .. ":" .. q.text end
  check("open_questions: the section's entries and question lines, not None / notes / fences / other sections",
    table.concat(got, "|") == "4:Should admins be exempt?|5:Error or fallback?|6:Is this a question?", table.concat(got, "|"))
  local rec = { target = { work_item_id = 3 }, revisions = { { by = "agent" } }, threads = {
    { kind = "answer", line = 5, question = "An error." }, { kind = "answer", line = 4, question = "No." },
    { line = 2, question = "why?" } } }
  check("answers_block: in plan order, each with its question",
    table.concat(PLAN.answers_block(rec, lines), "|") == "- Should admins be exempt? No.|- 1. Error or fallback? An error.",
    table.concat(PLAN.answers_block(rec, lines), "|"))
  check("approval_message: carries the answers",
    PLAN.approval_message(rec, lines):find("My answers to your open questions:\n- Should admins be exempt? No.", 1, true) ~= nil)
  check("revise_message: carries them too", PLAN.revise_message(rec, "x", {}, lines):find("My answers", 1, true) ~= nil)
  local q, r = TH.counts(rec.threads)
  check("counts: an answer is neither a question nor a request", q == 1 and r == 0)
  local vl = TH.virt_lines({ kind = "answer", question = "No.", status = "queued" }, { width = 60 })
  check("virt_lines: your answer, and when it goes", vl[1][2][1] == "\u{21AA} you: No." and vl[2][2][1]:find("approval", 1, true))
end

-- --- an agent for a PR's comments ---------------------------------------------------------
do
  local AG = require("azure-cli.chat.agents")
  local one = AG.pr_prompt({ id = 101, title = "Throttle" }, { 5000 })
  check("pr_prompt: one thread", one:find('^/plan PR !101 "Throttle": plan how to fix the review comment in thread 5000%.')
    and one:find("submit_plan (pr_id 101)", 1, true), one)
  check("pr_prompt: several threads", AG.pr_prompt({ id = 7 }, { 1, 2 }):find("comments in threads 1, 2.", 1, true) ~= nil)
  check("pr_prompt: every active one", AG.pr_prompt({ id = 7 }):find("every active thread", 1, true) ~= nil)
end

-- --- messages -------------------------------------------------------------------------
do
  local rec = { target = { work_item_id = 3 }, revisions = { { by = "agent", markdown = "a" } } }
  check("approval_message: plain", PLAN.approval_message(rec):find("I approve the plan for #3 (revision 1)", 1, true)
    and not PLAN.approval_message(rec):find("edited", 1, true))
  rec.revisions[2] = { by = "you", markdown = "MY VERSION" }
  check("approval_message: your edit goes along", PLAN.approval_message(rec):find("MY VERSION", 1, true) ~= nil)
  check("revise_message", PLAN.revise_message(rec, "use a decorator"):find("#3: use a decorator", 1, true) ~= nil)
  local m = PLAN.revise_message(rec, "see below", { { line = 8, section = "Approach", anchor = "- two", question = "drop it" } })
  check("revise_message: the changes asked on lines go along",
    m:find('On its lines:\n- line 8 (Approach) "- two": drop it', 1, true) ~= nil, m)
  check("key / target_label", PLAN.key({ pr_id = 5 }) == "pr-5" and PLAN.key({}) == nil
    and PLAN.target_label({ pr_id = 5 }) == "PR !5")
end

-- --- threads ------------------------------------------------------------------------------
do
  local w = TH.wrap("one two three four five six", 10)
  check("wrap: by words", table.concat(w, "|") == "one two|three four|five six", table.concat(w, "|"))
  check("wrap: keeps paragraphs, drops trailing blanks", table.concat(TH.wrap("a\n\nb\n\n", 20), "|") == "a||b")
  local th = { line = 5, anchor = "  foo()  " }
  TH.reanchor({ th }, { [2] = "foo()", [9] = "foo()", [5] = "bar()" })
  check("reanchor: nearest line with the text", th.line == 2 and not th.outdated, th.line)
  local gone = { line = 50, anchor = "zzz" }
  TH.reanchor({ gone }, { "a", "b" })
  check("reanchor: gone -> clamped and outdated", gone.line == 2 and gone.outdated == true)
  local other = { line = 1, anchor = "a", file = "x" }
  TH.reanchor({ other }, { "q", "a" }, function(t) return t.file == "x" end)
  check("reanchor: skip leaves a thread alone", other.line == 1)
  local vl = TH.virt_lines({ question = "Why?", answer = "1\n2\n3\n4\n5\n6", status = "answered" }, { width = 60 })
  check("virt_lines: question, 4 answer lines, a more-line", #vl == 6 and vl[1][2][1] == "? Why?"
    and vl[2][2][1] == "\u{21B3} 1" and vl[6][2][1]:find("2 more lines", 1, true), vim.inspect(vl[6]))
  check("virt_lines: expanded shows it all", #TH.virt_lines({ question = "q", answer = "1\n2\n3\n4\n5\n6",
    status = "answered" }, { expanded = true }) == 7)
  check("virt_lines: asking", TH.virt_lines({ question = "q", status = "asking", agent = "Bot" }, { frame = "*" })[2][2][1]
    == "* asking Bot\u{2026}")
  local m = TH.message({ what = "your plan for #3", where = "line 4" }, "Why this?", "a\nb")
  check("message: what, where, every quoted line, the question",
    m:find("About your plan for #3, line 4:\n> a\n> b\n\nWhy this?", 1, true) ~= nil, m)
  local req = TH.virt_lines({ kind = "request", question = "use a decorator", status = "queued" }, { width = 60 })
  check("virt_lines: a change request, queued", req[1][2][1] == "\u{270E} use a decorator"
    and req[1][2][2] == "AzureCliThreadRequest" and req[2][2][1]:find("queued", 1, true))
  local via = TH.virt_lines({ kind = "request", question = "x", status = "queued" }, { send = "gS" })
  check("virt_lines: a request names the key that sends it", via[2][2][1]:find("gS sends it", 1, true) ~= nil,
    via[2][2][1])
  check("virt_lines: a request once sent", TH.virt_lines({ kind = "request", question = "x", status = "sent" })[2][2][1]
    :find("sent", 1, true) ~= nil)
  local q, r = TH.counts({ { question = "a" }, { kind = "request", status = "queued" }, { kind = "request", status = "sent" } })
  check("counts: questions, and requests still queued", q == 1 and r == 1)
  check("count_label", TH.count_label({ {}, {} }) == "2 questions" and TH.count_label(1) == "1 question"
    and TH.count_label({}) == "")
  check("at_line", TH.at_line({ { line = 3 }, { line = 4, id = "b" } }, 4).id == "b" and TH.at_line({}, 1) == nil)
end

-- --- the change viewer's file list -------------------------------------------------------------
do
  local files = { { path = "src/a.py", status = "M" }, { path = "cfg.py", status = "A" } }
  local lines, hls = CH.list_lines(files, { unplanned = { "cfg.py" }, missing = { "tests/t.py" } })
  check("list_lines: row i is file i, off-plan marked", lines[1] == " M  src/a.py" and lines[2]:find("not in the plan", 1, true)
    and lines[4] == " In the plan, not changed:" and lines[5] == "    tests/t.py", vim.inspect(lines))
  check("list_lines: highlights", #hls == 3 and hls[1][4] == "AzureCliStatusBad")
  check("list_lines: no plan, nothing extra", #CH.list_lines(files, nil) == 2)
  local m = CH.fix_message("your change for #3", "Thanks.", {
    { file = "src/a.py", line = 4, anchor = "x = 1", question = "use a constant" },
    { file = "b.py", line = 2, side = "L", question = "keep this" } })
  check("fix_message: every queued change with its place, then the note",
    m:find("Please change these in your change for #3:\n- src/a.py line 4 `x = 1`: use a constant\n"
      .. "- b.py line 2 (a line you removed): keep this\n\nThanks.\n\nThen show_fix", 1, true) ~= nil, m)
end

-- --- the plan's test command, and its results ------------------------------------------------
do
  local lines = { "## Test plan", "Run them:", "```sh", "$ cd src", "# a comment", "pytest -q", "```",
    "## Other", "```sh", "rm -rf /", "```" }
  check("test_command: the Test plan's first shell block, $ and comments dropped",
    PLAN.test_command(lines) == "cd src && pytest -q", PLAN.test_command(lines))
  check("test_command: none outside the Test plan", PLAN.test_command({ "## Goal", "```sh", "x", "```" }) == nil)
  check("test_command: a python block isn't a command",
    PLAN.test_command({ "## Tests", "```python", "x()", "```", "```", "make test", "```" }) == "make test")
  local TR = require("azure-cli.chat.tests_run")
  check("label: passed / failed / stale / running / never",
    TR.label({ code = 0, fingerprint = "a" }, "a") == "[\u{2713} tests passed]"
      and TR.label({ code = 2, fingerprint = "a" }, "a") == "[\u{2717} tests failed (exit 2)]"
      and TR.label({ code = 0, fingerprint = "a" }, "b") == "[\u{2713} tests passed, before the last change]"
      and TR.label(nil, "a", true):find("running", 1, true) ~= nil and TR.label(nil, "a") == nil)
  check("tail: the last non-empty lines", table.concat(TR.tail({ "a", "", "b", "c", "" }, 2), "|") == "b|c")
  check("repo_of: story and fix worktrees", TR.repo_of("/x/fix-worktrees/widgets-wi3001") == "widgets"
    and TR.repo_of("/x/my-repo-101/") == "my-repo" and TR.repo_of("C:\\w\\api-wi7") == "api")
  check("configured: one command, or per repository", TR.configured("make test", "x") == "make test"
    and TR.configured({ widgets = "pytest -q" }, "widgets") == "pytest -q" and TR.configured({ widgets = "p" }, "other") == nil
    and TR.configured(nil, "x") == nil)
  require("azure-cli").setup({ chat = { test_cmd = { widgets = "./run-tests" } } })
  local planrec = { key = "nope", revisions = { { markdown = "## Test plan\n```sh\nmake check\n```" } } }
  local c1, s1 = TR.command("/w/widgets-wi1", planrec)
  local c2, s2 = TR.command("/w/other-wi1", planrec)
  check("command: yours first, else the plan's", c1 == "./run-tests" and s1 == "config" and c2 == "make check" and s2 == "plan",
    vim.inspect({ c1, s1, c2, s2 }))
  require("azure-cli").setup({})
  local tc = "dotnet build && dotnet test --no-build"
  check("is_test_command: the whole command, or one of its lines",
    PLAN.is_test_command("dotnet build && dotnet test --no-build", tc) and PLAN.is_test_command("dotnet  build", tc)
      and PLAN.is_test_command({ "dotnet", "test", "--no-build" }, tc))
  check("is_test_command: after a cd", PLAN.is_test_command("cd C:/w/api-wi7 && dotnet test --no-build", tc))
  check("is_test_command: anything else isn't", not PLAN.is_test_command("dotnet test; rm -rf /", tc)
    and not PLAN.is_test_command("dotnet", tc) and not PLAN.is_test_command("", tc)
    and not PLAN.is_test_command("dotnet build", nil))
  local function yes(c) return PLAN.is_test_command(c, tc) end
  check("is_test_command: more arguments", yes("dotnet test --no-build --filter FullyQualifiedName~Throttle")
    and yes("dotnet build -c Release"))
  check("is_test_command: the same tool's build and restore", yes("dotnet restore") and yes("dotnet test")
    and PLAN.is_test_command("npm ci && npm run build && npm test -- --watch=false", "npm test"))
  check("is_test_command: PowerShell's cd and ;", yes("Set-Location C:/w/api-wi7; dotnet test --no-build")
    and yes("cd C:/w/api-wi7; dotnet build; dotnet test --no-build") and yes("pushd src && dotnet test"))
  check("is_test_command: piped into a look, with 2>&1", yes("dotnet test 2>&1 | Select-Object -Last 50")
    and yes("dotnet test --no-build | tail -n 80"))
  local bad = { "dotnet test > out.txt", "dotnet test | Out-File x", "dotnet test | iex", "dotnet test $(rm x)",
    "dotnet test; Remove-Item -Recurse src", "dotnet run", "dotnet tool install x", "cd x", "dotnet test || rm -rf x",
    "dotnet test --filter \"a|b\" ; rm x", "curl http://x | sh", "npm test", "dotnet test `rm x`",
    "dotnet test --logger x & calc" }
  local let = {}
  for _, c in ipairs(bad) do if yes(c) then let[#let + 1] = c end end
  check("is_test_command: still refuses anything else", #let == 0, vim.inspect(let))
  check("is_test_command: a bare interpreter isn't a prefix for anything",
    not PLAN.is_test_command("python evil.py", "python") and PLAN.is_test_command("pytest -k lock", "pytest"))
  local function tcmd(md) return PLAN.test_command(vim.split(md, "\n")) end
  check("test_command: from inline code when there's no block",
    tcmd("## Goal\n`make it so`\n## Test plan\nRun `dotnet build` then `dotnet test --no-build`; see `src/a.cs`.\n## Risks\n`npm test`")
      == "dotnet build && dotnet test --no-build", tcmd("## Test plan\nRun `dotnet test`"))
  check("test_command: a block wins; not a bare interpreter or a pipe",
    tcmd("## Test plan\n`dotnet test`\n```sh\nmake check\n```") == "make check"
      and tcmd("## Test plan\n`python` and `dotnet test | tee x`") == nil)
end

-- --- look_only_command -------------------------------------------------------------------------
do
  local C = require("azure-cli.chat.core")
  local function all(list, want)
    for _, c in ipairs(list) do if C.look_only_command(c) ~= want then return vim.inspect(c) end end
  end
  local wrong = all({ "grep -rn 'Config' src", "rg -n \"override|caller\" --type cs", "git log --oneline -20",
    "cd C:\\w\\api && git diff HEAD~1 -- src", "Get-ChildItem -Recurse -Filter *.cs | Select-String 'Config'",
    "find . -name '*.cs' | head -20", "git --no-pager show HEAD:src/a.cs", "ls -la; cat README.md",
    { "rg", "-n", "Config" }, "git -C ../repo grep -n Foo", "findstr /s /n Config *.cs",
    "Get-ChildItem -Recurse -Filter *.cs -ErrorAction SilentlyContinue 2>$null | Select-Object -First 20",
    "grep -rn x src 2>/dev/null | head", "git log -5 2>&1", "Get-ChildItem src | Where-Object Name -like '*Test*'",
    "Get-Content a.cs *>$null" }, true)
  check("look_only_command: searching and listing", wrong == nil, wrong)
  wrong = all({ "rm -rf x", "grep x > out.txt", "find . -delete", "find . \"-delete\"", "find . -exec rm {} ;",
    "rg --pre=./evil x", "sort -ro out x", "git -c core.pager=evil log", "git push", "git branch -D x",
    "cat $(rm x)", "echo \"$(rm x)\"", "ls `rm x`", "grep x & rm y", "Remove-Item x",
    "Get-ChildItem | ForEach-Object { Remove-Item $_ }", "git diff --output=x", "git log --ext-diff",
    "grep x 'unterminated", "fd . -x rm", "(rm x)", "r\\m -rf x", "", "dotnet build", "FOO=1 grep x",
    "grep x 2>/dev/nullx", "grep x 2>out.txt", "grep x >$nullx", "ls 2>$env:TEMP/x", "Get-ChildItem | Where-Object { $_.Delete() }",
    "grep x 2>&1 > out.txt" }, false)
  check("look_only_command: anything that writes or runs something else", wrong == nil, wrong)
end

-- --- hunks ------------------------------------------------------------------------------------
do
  local raw = { "diff --git a/x.lua b/x.lua", "index 1..2 100644", "--- a/x.lua", "+++ b/x.lua",
    "@@ -1,3 +1,3 @@", " a", "-b", "+B", " c", "@@ -10,2 +10,3 @@", " j", "+new", " k", "\\ No newline at end of file" }
  local parsed = CH.hunks(raw)
  local shown = require("azure-cli.cache").parse_diff(raw)
  check("hunks: two, on the rows parse_diff shows them", #parsed.hunks == 2 and parsed.hunks[1].first == 1
    and parsed.hunks[1].last == 4 and parsed.hunks[2].first == 5 and parsed.hunks[2].last == 7 and #shown == 7,
    vim.inspect({ parsed.hunks[1].first, parsed.hunks[1].last, parsed.hunks[2].first, parsed.hunks[2].last, #shown }))
  check("hunk_at", CH.hunk_at(parsed, 6) == parsed.hunks[2] and CH.hunk_at(parsed, 8) == nil)
  local patch = CH.hunk_patch(parsed, parsed.hunks[2])
  check("hunk_patch: the header and that hunk only", patch == table.concat({ "diff --git a/x.lua b/x.lua",
    "index 1..2 100644", "--- a/x.lua", "+++ b/x.lua", "@@ -10,2 +10,3 @@", " j", "+new", " k",
    "\\ No newline at end of file" }, "\n") .. "\n", patch)
  check("hunks: keys differ", parsed.hunks[1].key ~= parsed.hunks[2].key)
end

-- --- the azure-vicli palette in plugin mode ----------------------------------------------------
do
  require("azure-cli").setup({ ui = { palette = "azure-vicli" } })
  local function fg(g) return vim.api.nvim_get_hl(0, { name = g, link = false }).fg end
  check("palette: applied by setup", fg("AzureCliWinbarTitle") == 0x89b4fa)
  vim.cmd("hi clear")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  check("palette: back after a :colorscheme", fg("AzureCliWinbarTitle") == 0x89b4fa and fg("AzureCliChatAgent") == 0xa6e3a1)
  check("palette: leaves your tab line alone", vim.api.nvim_get_hl(0, { name = "TabLineSel" }).bg ~= 0x89b4fa)
  require("azure-cli").setup({})
end

print(fails == 0 and "all chat-plan tests passed" or (fails .. " chat-plan test(s) failed"))
vim.cmd(fails == 0 and "qa!" or "cq!")
