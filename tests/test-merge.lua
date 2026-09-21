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
check("lines: summary", lines[8] == "Build: \u{2713}   Threads: 0 unresolved   Votes: 1 / 2", lines[8])
check("lines: no warning line", #lines == 10 and lines[10]:find("^m: merge type"), #lines)

st = { merge = 3, work_items = false, delete_branch = false }
lines = MG.lines({ id = 7, unresolved = 2, conflict = true }, st)
check("lines: bare spec title", lines[1] == "Complete PR #7", lines[1])
check("lines: bare branches", lines[2] == "   \u{2192} ", lines[2])
check("lines: merge type cycles", lines[4] == "Merge type: Rebase and fast-forward", lines[4])
check("lines: work items off", lines[5] == "[ ] Complete associated work items", lines[5])
check("lines: delete branch off, no name", lines[6] == "[ ] Delete source branch", lines[6])
check("lines: build none, votes ?", lines[8] == "Build: none   Threads: 2 unresolved   Votes: ?", lines[8])
check("lines: warning line", lines[9] == "\u{26A0} merge conflict, 2 unresolved threads - merge anyway?", lines[9])
check("lines: unknown threads", MG.lines({ id = 1 }, st)[8]:find("Threads: ? unresolved", 1, true) ~= nil)

check("MERGE_TYPES: four ADO strategies", #MG.MERGE_TYPES == 4 and MG.MERGE_TYPES[1].key == "squash" and MG.MERGE_TYPES[4].key == "rebaseMerge")

if fails > 0 then os.exit(1) end
print("all ok")
