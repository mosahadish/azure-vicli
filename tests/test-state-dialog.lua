-- test-state-dialog.lua: lua/azure-cli/workitems/state_dialog.lua's pure
-- helpers (gs's popup: how a child's state is mapped, the rendered lines,
-- and the "also set children" toggles).
-- Usage: luajit test-state-dialog.lua <state_dialog.lua path>
local path = arg[1]
assert(path, "usage: luajit test-state-dialog.lua <state_dialog.lua path>")
local SD = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

local TASK = { ["To Do"] = "Proposed", ["In Progress"] = "InProgress", Done = "Completed", Removed = "Removed" }
local TASK_FROM_TODO = { "In Progress", "Done", "Removed" }

-- child_target
local t, why = SD.child_target("Active", "Closed", "Completed", { "Resolved", "Closed" }, {})
check("child_target: same name when reachable", t == "Closed", t)
t = SD.child_target("To Do", "Closed", "Completed", TASK_FROM_TODO, TASK)
check("child_target: same category when the name doesn't exist", t == "Done", t)
t, why = SD.child_target("Done", "Closed", "Completed", { "In Progress", "To Do" }, TASK)
check("child_target: already in the category", t == nil and why == "already Done", why)
t, why = SD.child_target("Closed", "Closed", nil, {}, {})
check("child_target: already in the state", t == nil and why == "already Closed", why)
t, why = SD.child_target("To Do", "Resolved", "Resolved", TASK_FROM_TODO, TASK)
check("child_target: no state in the category", t == nil and why == "no matching state", why)
t, why = SD.child_target("To Do", "Closed", nil, TASK_FROM_TODO, {})
check("child_target: no categories means names only", t == nil and why == "no matching state", why)
t = SD.child_target("New", "Active", "InProgress", { "Active", "Removed" }, { New = "Proposed", Active = "InProgress" })
check("child_target: same type, same workflow", t == "Active", t)

-- default_on
check("default_on: mappable child", SD.default_on("Done", "Proposed") == true)
check("default_on: removed child stays off", SD.default_on("To Do", "Removed") == false)
check("default_on: nothing to map to", SD.default_on(nil, "Proposed") == false)
check("default_on: forward move", SD.default_on("Done", "InProgress", "Completed") == true)
check("default_on: backward move stays off", SD.default_on("In Progress", "Completed", "InProgress") == false)
check("default_on: same category, other name", SD.default_on("Doing", "InProgress", "InProgress") == true)
check("default_on: into Removed", SD.default_on("Removed", "InProgress", "Removed") == true)
check("default_on: no categories", SD.default_on("Done", nil, nil) == true)

-- reason_options
local ro = SD.reason_options({})
check("reason_options: none is just the default", #ro == 1 and ro[1].reason == "" and ro[1].label == SD.DEFAULT_REASON)
ro = SD.reason_options({ "Fixed" })
check("reason_options: one is just the default", #ro == 1 and ro[1].reason == "")
ro = SD.reason_options({ "Fixed", "Verified" })
check("reason_options: several, then default, then other", #ro == 4 and ro[1].reason == "Fixed"
  and ro[3].reason == "" and ro[4].other == true)

-- lines + toggles
local spec = { id = "3001", type = "User Story", state = "Active", title = "Throttle repeated login failures" }
local function kids()
  return {
    { id = "3011", type = "Task", state = "In Progress", title = "Count failed logins", target = "Done", on = true },
    { id = "3012", type = "Task", state = "To Do", title = "Tests", target = "Done", on = true },
    { id = "3013", type = "Task", state = "Done", title = "Design", why = "already Done", on = false },
  }
end
local st = { states = { { label = "Closed" }, { label = "Resolved" } }, si = 1, ropts = nil, ri = 1, all = false }
local lines, rows = SD.lines(spec, st)
check("lines: header", lines[1] == "Set #3001  User Story \u{00B7} Active", lines[1])
check("lines: title", lines[2] == "  Throttle repeated login failures", lines[2])
check("lines: state row", lines[4] == "State:   \u{2039} Closed \u{203A}   (1/2)" and rows[4].kind == "state", lines[4])
check("lines: reason loading", lines[5] == "Reason:  loading\u{2026}" and rows[5].kind == "reason", lines[5])
check("lines: children loading", lines[7] == "Children: loading\u{2026}" and rows[7] == nil, lines[7])

st.kids = {}
lines = SD.lines(spec, st)
check("lines: no children", lines[7] == "No children")

st.kids, st.ropts = kids(), SD.reason_options({ "Fixed", "Verified" })
lines, rows = SD.lines(spec, st)
check("lines: reason cycler", lines[5] == "Reason:  \u{2039} Fixed \u{203A}   (1/4)", lines[5])
check("lines: master starts unchecked", lines[7] == "[ ] Also set children (2 of 3)" and rows[7].kind == "all", lines[7])
check("lines: child unchecked while master is off", lines[8] == "    [ ] #3011 Task  In Progress \u{2192} Done  Count failed logins", lines[8])
check("lines: skipped child says why", lines[10] == "    [ ] #3013 Task  Done  (already Done)  Design", lines[10])
check("lines: child rows carry their index", rows[9].kind == "child" and rows[9].i == 2)
check("lines: hint last", lines[#lines]:find("<CR>: apply", 1, true) ~= nil)

check("toggle_all: turns on", SD.toggle_all(st) and st.all)
lines = SD.lines(spec, st)
check("lines: master on checks the mapped children", lines[8]:find("^    %[x%] #3011") and lines[9]:find("^    %[x%] #3012")
  and lines[10]:find("^    %[ %] #3013"), lines[8])
check("toggle_kid: skipped child can't be checked", SD.toggle_kid(st, 3) == false)
SD.toggle_kid(st, 1)
check("toggle_kid: uncheck one", SD.selected(st) == 1 and st.all)
SD.toggle_kid(st, 2)
check("toggle_kid: unchecking the last turns the master off", SD.selected(st) == 0 and not st.all)
SD.toggle_all(st)
check("toggle_all: on with nothing picked restores the defaults", st.all and SD.selected(st) == 2)

st.all, st.kids = false, kids()
SD.toggle_kid(st, 2)
check("toggle_kid: with the master off picks just that child", st.all and SD.selected(st) == 1 and st.kids[2].on
  and not st.kids[1].on)

st.kids[3].pending, st.kids[3].why = true, nil
lines = SD.lines(spec, st)
check("lines: pending child", lines[10] == "    [ ] #3013 Task  Done \u{2026}  Design", lines[10])

check("toggle_all: no children", SD.toggle_all({ kids = {} }) == false)

-- tree_order: parents before their children, depth set, strays dropped.
local ordered = SD.tree_order("1", {
  { id = 12, parentId = 1 }, { id = 30, parentId = 12 }, { id = 11, parentId = 1 }, { id = 99, parentId = 77 },
})
local shape = {}
for _, r in ipairs(ordered) do shape[#shape + 1] = r.id .. ":" .. r.depth end
check("tree_order: depth-first by id", table.concat(shape, " ") == "11:1 12:1 30:2", table.concat(shape, " "))

-- A grandchild's popup row is indented one more step.
st = { states = { { label = "Closed" } }, si = 1, ri = 1, all = true, kids = {
  { id = "12", type = "Task", state = "To Do", title = "a", target = "Done", on = true, depth = 1 },
  { id = "30", type = "Task", state = "To Do", title = "b", target = "Done", on = true, depth = 2 },
} }
lines = SD.lines(spec, st)
check("lines: grandchild indented", lines[9] == "      [x] #30 Task  To Do \u{2192} Done  b", lines[9])

-- progress: Completed counts as done, Removed doesn't count; names stand in
-- for a type whose categories aren't known.
local cats = function(t) return t == "Task" and TASK or nil end
local d, tot = SD.progress({
  { type = "Task", state = "Done" }, { type = "Task", state = "In Progress" }, { type = "Task", state = "Removed" },
  { type = "Bug", state = "Closed" }, { type = "Bug", state = "Active" },
}, cats)
check("progress: done/total", d == 2 and tot == 4, d .. "/" .. tot)
d, tot = SD.progress({}, cats)
check("progress: no children", d == 0 and tot == 0)

local long = { id = 1, type = "Bug", state = "New", title = string.rep("\u{00E9}", 70) }
lines = SD.lines(long, { states = { { label = "Active" } }, si = 1, ri = 1 })
check("lines: long title cut on a character", lines[2] == "  " .. string.rep("\u{00E9}", 60) .. "\u{2026}", #lines[2])
check("lines: single state has no counter", lines[4] == "State:   \u{2039} Active \u{203A}", lines[4])

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
