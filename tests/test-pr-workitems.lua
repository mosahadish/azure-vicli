-- test-pr-workitems.lua: lua/azure-cli/pr_workitems.lua's pure helpers
-- (a PR row's linked-work-item badge and gW's picker lines).
-- Usage: luajit test-pr-workitems.lua <pr_workitems.lua path>
local path = arg[1]
assert(path, "usage: luajit test-pr-workitems.lua <pr_workitems.lua path>")
local PW = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

check("label: none", PW.label(nil) == "" and PW.label({}) == "")
check("label: one", PW.label({ { id = 3001 } }) == "#3001")
check("label: several", PW.label({ { id = 3001 }, { id = 7 } }) == "#3001 +1")
check("describe: full", PW.describe({ id = 3001, state = "Active", type = "User Story", title = "Throttle" })
  == "#3001  [Active]  User Story  Throttle", PW.describe({ id = 3001, state = "Active", type = "User Story", title = "Throttle" }))
check("describe: id only", PW.describe({ id = 5 }) == "#5")
check("popup_line: with assignee", PW.popup_line({ id = 7, state = "New", type = "Bug", title = "b", assignedTo = "Alice" })
  == "  #7  [New]  Bug  b  \u{00B7} Alice")
check("popup_line: unassigned", PW.popup_line({ id = 7 }) == "  #7")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
