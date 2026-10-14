-- test-merge.lua: lua/azure-cli/merge.lua's pure helpers (the complete-PR
-- dialog's build label, warnings and rendered lines).
-- Usage: luajit test-merge.lua <merge.lua path>
local path = arg[1]
assert(path, "usage: luajit test-merge.lua <merge.lua path>")
local MG = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

check("build_label: succeeded", MG.build_label({ buildStatus = "succeeded" }) == "build \u{2713}")
check("build_label: failed", MG.build_label({ buildStatus = "failed" }) == "build \u{2717}")
check("build_label: expired", MG.build_label({ buildStatus = "expired" }) == "build \u{21BB}")
check("build_label: running", MG.build_label({ buildStatus = "running", queuePosition = -1 }) == "build \u{25CF}")
check("build_label: queued", MG.build_label({ buildStatus = "running", queuePosition = 2 }) == "build \u{25CF} (queue #2)")
check("build_label: none", MG.build_label({ buildStatus = "none" }) == nil)
check("build_label: nil record", MG.build_label(nil) == nil)

check("warnings: all clear", #MG.warnings({ build_label = "build \u{2713}", conflict = false, unresolved = 0 }) == 0)
check("warnings: unknown threads is not a warning", #MG.warnings({ unresolved = nil }) == 0)
local w = MG.warnings({ build_label = "build \u{2717}", conflict = true, unresolved = 1 })
check("warnings: all three", table.concat(w, ", ") == "build \u{2717}, merge conflict, 1 unresolved thread", table.concat(w, ", "))
check("warnings: plural", MG.warnings({ unresolved = 3 })[1] == "3 unresolved threads")

local st = { merge = 1, work_items = true, delete_branch = true }
local lines = MG.lines({ id = 42, title = "Fix it", source = "feat/x", target = "main",
  build_label = "build \u{2713}", conflict = false, unresolved = 0, vote_ratio = "1 / 2" }, st)
check("lines: title", lines[1] == "Complete PR #42  Fix it", lines[1])
check("lines: branches", lines[2] == "  feat/x \u{2192} main", lines[2])
check("lines: merge type", lines[4] == "Merge type: Squash commit", lines[4])
check("lines: work items on", lines[5] == "[x] Complete associated work items", lines[5])
check("lines: delete branch names it", lines[6] == "[x] Delete source branch (feat/x)", lines[6])
check("lines: auto-complete off", lines[7] == "[ ] Auto-complete when policies pass", lines[7])
check("lines: summary", lines[9] == "Build: \u{2713}   Threads: 0 unresolved   Votes: 1 / 2", lines[9])
check("lines: no warning line", #lines == 11 and lines[11]:find("^<Space>: toggle"), #lines)
check("lines: hint completes, no x", lines[11] == "<Space>: toggle   m: merge type   <CR>: complete   q: close", lines[11])
check("rows: match the rendered lines", lines[MG.ROW.merge]:find("^Merge type") and lines[MG.ROW.work_items]:find("work items")
  and lines[MG.ROW.delete_branch]:find("source branch") and lines[MG.ROW.auto]:find("^%[ %] Auto%-complete"))

local ts = { merge = 4, work_items = true, delete_branch = false }
check("toggle: work items row", MG.toggle(ts, MG.ROW.work_items) and ts.work_items == false)
check("toggle: delete branch row", MG.toggle(ts, MG.ROW.delete_branch) and ts.delete_branch == true)
check("toggle: auto row", MG.toggle(ts, MG.ROW.auto) and ts.auto == true)
check("toggle: merge row wraps", MG.toggle(ts, MG.ROW.merge) and ts.merge == 1)
check("toggle: other row is a no-op", MG.toggle(ts, 1) == false and ts.merge == 1 and ts.work_items == false)

st = { merge = 3, work_items = false, delete_branch = false }
lines = MG.lines({ id = 7, unresolved = 2, conflict = true }, st)
check("lines: bare spec title", lines[1] == "Complete PR #7", lines[1])
check("lines: bare branches", lines[2] == "   \u{2192} ", lines[2])
check("lines: merge type cycles", lines[4] == "Merge type: Rebase and fast-forward", lines[4])
check("lines: work items off", lines[5] == "[ ] Complete associated work items", lines[5])
check("lines: delete branch off, no name", lines[6] == "[ ] Delete source branch", lines[6])
check("lines: build none, votes ?", lines[9] == "Build: none   Threads: 2 unresolved   Votes: ?", lines[9])
check("lines: warning line", lines[10] == "\u{26A0} merge conflict, 2 unresolved threads - merge anyway?", lines[10])
check("lines: unknown threads", MG.lines({ id = 1 }, st)[9]:find("Threads: ? unresolved", 1, true) ~= nil)

-- Auto-complete: already on (checked, says by whom, x offered); a red build
-- is no warning when setting it, since waiting for the build is the point.
local aspec = { id = 5, build_label = "build \u{2717}", conflict = true, auto_on = true, auto_by = "Doe, Jane" }
local ast = { merge = 1, work_items = true, delete_branch = true, auto = true }
lines = MG.lines(aspec, ast)
check("auto: on, set by", lines[7] == "[x] Auto-complete when policies pass (on, set by Doe, Jane)", lines[7])
check("auto: build not a warning", lines[10] == "\u{26A0} merge conflict - set auto-complete anyway?", lines[10])
check("auto: hint sets it, offers x", lines[12] == "<Space>: toggle   m: merge type   <CR>: set auto-complete   x: cancel auto-complete   q: close", lines[12])
ast.auto = false
lines = MG.lines(aspec, ast)
check("auto: unchecked completes, build warns again", lines[10] == "\u{26A0} build \u{2717}, merge conflict - merge anyway?"
  and lines[12]:find("<CR>: complete", 1, true) ~= nil, lines[10])
check("auto: on without a name", MG.lines({ id = 5, auto_on = true }, ast)[7] == "[ ] Auto-complete when policies pass (on)")

check("MERGE_TYPES: four ADO strategies", #MG.MERGE_TYPES == 4 and MG.MERGE_TYPES[1].key == "squash" and MG.MERGE_TYPES[4].key == "rebaseMerge")

-- Rows from the spec: Azure has them all (M.ROW); GitHub has no work-items
-- row, and a repo without auto-merge no auto row.
local R = MG.rows({})
check("rows: azure", R.merge == 4 and R.work_items == 5 and R.delete_branch == 6 and R.auto == 7 and R.last == 7)
check("rows: M.ROW is azure's", MG.ROW.work_items == 5 and MG.ROW.auto == 7)
R = MG.rows({ work_items = false })
check("rows: no work items", R.work_items == nil and R.delete_branch == 5 and R.auto == 6, vim and vim.inspect(R))
R = MG.rows({ work_items = false, auto = false })
check("rows: no work items, no auto", R.auto == nil and R.delete_branch == 5 and R.last == 5)
ts = { merge = 1, work_items = false, delete_branch = true, auto = false }
check("toggle: spec's rows", MG.toggle(ts, 6, { work_items = false }) and ts.auto == true
  and MG.toggle(ts, 5, { work_items = false }) and ts.delete_branch == false)
check("toggle: a row the spec lacks", MG.toggle(ts, 7, { work_items = false }) == false)

-- GitHub: its words, the checks, and what blocks a merge.
local GH = { { key = "squash", label = "Squash and merge" }, { key = "merge", label = "Create a merge commit" } }
local gspec = { id = 7, host = "github", ref = "doohickeys#7", title = "Wobble", source = "fix/w", target = "github-host",
  work_items = false, delete_on_merge = false, build_label = "build \u{2717}", unresolved = 0,
  blockers = { "required check `ci / test` failed" }, warnings = { "check `docs` failed (not required)" },
  checks = { { name = "ci / test", state = "failed", required = true }, { name = "lint", state = "pending", required = false } } }
local gst = { merge = 1, work_items = false, delete_branch = true, auto = false, methods = GH }
lines = MG.lines(gspec, gst)
check("github: title", lines[1] == "Merge PR doohickeys#7  Wobble", lines[1])
check("github: no work items row", lines[5] == "[x] Delete source branch (fix/w)", lines[5])
check("github: auto row", lines[6] == "[ ] Auto-merge when requirements pass", lines[6])
check("github: required check", lines[9] == "  \u{2717} ci / test  (required)", lines[9])
check("github: optional check", lines[10] == "  \u{25CF} lint", lines[10])
check("github: blocker", lines[11] == "\u{26D4} Can't merge: required check `ci / test` failed", lines[11])
check("github: warnings, no 'merge anyway' while blocked",
  lines[12] == "\u{26A0} build \u{2717}, check `docs` failed (not required)", lines[12])
check("github: hint merges", lines[14] == "<Space>: toggle   m: merge type   <CR>: merge   q: close", lines[14])
local can, why = MG.confirm_allowed(gspec, gst)
check("github: blocked <CR> refused", can == false and why == "Can't merge: required check `ci / test` failed", why)
gst.auto = true
check("github: auto-merge allowed while blocked", MG.confirm_allowed(gspec, gst) == true)
lines = MG.lines(gspec, gst)
check("github: auto deletes by the repo's setting", lines[5] == "[-] Delete source branch: the repo's setting decides (off)", lines[5])
check("github: auto waits for the blockers", lines[11] == "Auto-merge waits for: required check `ci / test` failed", lines[11])
check("github: auto hint", lines[14]:find("<CR>: set auto-merge", 1, true) ~= nil, lines[14])
gspec.conflict = true
check("github: a conflict blocks auto-merge too", MG.confirm_allowed(gspec, gst) == false)
check("azure: a conflict doesn't block auto-complete", MG.confirm_allowed({ conflict = true }, { auto = true }) == true)
check("azure: no blockers, <CR> completes", MG.confirm_allowed({ id = 1 }, { auto = false }) == true)
lines = MG.lines({ id = 8, host = "github", ref = "r#8", work_items = false, auto = false }, { merge = 1, delete_branch = true, methods = GH })
check("github: no auto row when the repo disallows it", #lines == 9 and lines[5]:find("Delete source branch", 1, true) ~= nil
  and lines[6]:find("^\u{2500}") ~= nil, table.concat(lines, "|"))

if fails > 0 then os.exit(1) end
print("all ok")
