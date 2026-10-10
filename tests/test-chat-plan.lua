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

-- --- messages -------------------------------------------------------------------------
do
  local rec = { target = { work_item_id = 3 }, revisions = { { by = "agent", markdown = "a" } } }
  check("approval_message: plain", PLAN.approval_message(rec):find("I approve the plan for #3 (revision 1)", 1, true)
    and not PLAN.approval_message(rec):find("edited", 1, true))
  rec.revisions[2] = { by = "you", markdown = "MY VERSION" }
  check("approval_message: your edit goes along", PLAN.approval_message(rec):find("MY VERSION", 1, true) ~= nil)
  check("revise_message", PLAN.revise_message(rec, "use a decorator"):find("#3: use a decorator", 1, true) ~= nil)
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
  check("count_label", TH.count_label({ 1, 2 }) == "2 questions" and TH.count_label(1) == "1 question"
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
end

print(fails == 0 and "all chat-plan tests passed" or (fails .. " chat-plan test(s) failed"))
vim.cmd(fails == 0 and "qa!" or "cq!")
