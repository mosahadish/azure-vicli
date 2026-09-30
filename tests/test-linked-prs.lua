-- test-linked-prs.lua: lua/azure-cli/workitems/linked_prs.lua's pure
-- helpers (the dashboard's PR marker, the detail view's PR lines).
-- Usage: luajit test-linked-prs.lua <linked_prs.lua path>
local path = arg[1]
assert(path, "usage: luajit test-linked-prs.lua <linked_prs.lua path>")
local LP = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

check("marker: none", LP.marker(nil) == "" and LP.marker({}) == "")
check("marker: one", LP.marker({ { id = 101 } }) == "!101")
check("marker: several", LP.marker({ { id = 101 }, { id = 7 }, { id = 8 } }) == "!101 +2")

check("status: active", LP.status({ status = "active" }) == "active")
check("status: draft", LP.status({ status = "active", isDraft = true }) == "draft")
check("status: a completed draft is completed", LP.status({ status = "completed", isDraft = true }) == "completed")
check("status: unread", LP.status({ id = 1 }) == "")

local l = LP.lines({ id = 101, status = "active", title = "Throttle failed logins", repo = "widgets",
  source = "feature/x", target = "main", author = "Alice" })
check("lines: head", l[1] == "  !101    active     Throttle failed logins", l[1])
check("lines: where", l[2] == "           widgets  feature/x \u{2192} main  \u{00B7}  Alice", l[2])
l = LP.lines({ id = 9 })
check("lines: unread PR is just its id", #l == 1 and l[1] == "  !9", l[1])
l = LP.lines({ id = 9, status = "abandoned", title = "t", repo = "r", source = "a", target = "b" })
check("lines: no author", l[2] == "           r  a \u{2192} b", l[2])

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
