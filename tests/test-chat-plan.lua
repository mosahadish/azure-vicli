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

-- --- the Agents screen's rows ---------------------------------------------------------------
do
  local AV = require("azure-cli.chat.agents_view")
  local convs = {
    { entries = {} },  -- the main conversation: no row
    { plan_key = "wi-1", label = "#1", title = "One", running = {}, entries = { { started = 90, tools = { "\u{270E} start_story (x)" } } } },
    { plan_key = "wi-2", label = "#2", entries = { { started = 40, status = "done" } } },
    { plan_key = "wi-4", label = "#4", entries = { { started = 95, status = "failed (exit 1)" } } },
  }
  local plans = { ["wi-2"] = { status = "draft", title = "Two" } }
  local rows = AV.rows(convs, { { key = "wi-3", item = { id = 3, title = "Three" } }, { key = "wi-1", item = { id = 1 } } },
    function(k) return plans[k] end, 100, "*")
  check("agents rows: one per plan's agent, then the queued ones not running", #rows == 4, #rows)
  check("agents rows: working, with its last step", rows[1].state == "* working" and rows[1].detail == "\u{270E} start_story (x)"
    and rows[1].ago == "10s" and rows[1].title == "One")
  check("agents rows: a plan waiting for you, titled from the plan", rows[2].state:find("plan waits for you", 1, true)
    and rows[2].title == "Two" and rows[2].ago == "1m")
  check("agents rows: a failed answer", rows[3].state:find("failed (exit 1)", 1, true) ~= nil)
  check("agents rows: queued", rows[4].label == "#3" and rows[4].state:find("waiting for an agent", 1, true) ~= nil)
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
