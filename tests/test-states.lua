-- test-states.lua: unit tests for lua/azure-cli/workitems/states.lua's pure
-- M.build/M.rank/M.hl - the work_items.states: rank/highlight mapping
-- shared by workitems/dashboard.lua (section sort order) and
-- workitems/view.lua ([state] token colour). Pure Lua, no vim, so it runs
-- directly under plain luajit.
--
-- Usage: luajit test-states.lua <workitems/states.lua path>

local path = arg[1]
assert(path, "usage: luajit test-states.lua <workitems/states.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- fallback (no states: configured) ---------------------------------------

do
  local built = M.build(nil)
  check("fallback: Active ranks 1", M.rank(built, "Active") == 1)
  check("fallback: In Progress ranks 1 (alias of Active)", M.rank(built, "In Progress") == 1)
  check("fallback: New ranks 2", M.rank(built, "New") == 2)
  check("fallback: Removed ranks last (6)", M.rank(built, "Removed") == 6)
  check("fallback: Active highlight", M.hl(built, "Active") == "AzureCliWiActive")
  check("fallback: In Progress highlight (alias)", M.hl(built, "In Progress") == "AzureCliWiActive")
  check("fallback: New highlight", M.hl(built, "New") == "AzureCliWiNew")
  check("fallback: Implemented highlight", M.hl(built, "Implemented") == "AzureCliWiImplemented")
  check("fallback: Resolved highlight", M.hl(built, "Resolved") == "AzureCliWiResolved")
  check("fallback: Closed highlight", M.hl(built, "Closed") == "AzureCliWiClosed")
  check("fallback: Removed highlight", M.hl(built, "Removed") == "AzureCliWiRemoved")
  check("fallback: unknown state ranks last", M.rank(built, "Frobnicated") == 9999)
  check("fallback: unknown state neutral colour", M.hl(built, "Frobnicated") == "AzureCliWiOther")
end

-- An empty states list is treated exactly like nil (falls back).
do
  local built = M.build({})
  check("empty list: falls back to defaults", M.rank(built, "Active") == 1)
end

-- --- a configured states: list -----------------------------------------------

do
  local built = M.build({ "New", "Active", "Implemented", "Resolved", "Closed", "Removed" })
  check("custom: order = rank (1)", M.rank(built, "New") == 1)
  check("custom: order = rank (2)", M.rank(built, "Active") == 2)
  check("custom: order = rank (3)", M.rank(built, "Implemented") == 3)
  check("custom: order = rank (4)", M.rank(built, "Resolved") == 4)
  check("custom: order = rank (5)", M.rank(built, "Closed") == 5)
  check("custom: order = rank (6, last)", M.rank(built, "Removed") == 6)

  check("custom: index 1 -> AzureCliWiNew", M.hl(built, "New") == "AzureCliWiNew")
  check("custom: index 2 -> AzureCliWiActive", M.hl(built, "Active") == "AzureCliWiActive")
  check("custom: last -> AzureCliWiRemoved", M.hl(built, "Removed") == "AzureCliWiRemoved")
  check("custom: second-to-last -> AzureCliWiClosed", M.hl(built, "Closed") == "AzureCliWiClosed")
  check("custom: others (middle) -> AzureCliWiImplemented", M.hl(built, "Implemented") == "AzureCliWiImplemented")
  check("custom: others (middle) -> AzureCliWiImplemented (Resolved)", M.hl(built, "Resolved") == "AzureCliWiImplemented")

  check("custom: a state not in the list ranks last", M.rank(built, "Backlog") == 9999)
  check("custom: a state not in the list is neutral", M.hl(built, "Backlog") == "AzureCliWiOther")
end

-- A short custom list still resolves every position rule (1, 2, last,
-- second-to-last all distinct only once the list is >= 4 long - a shorter
-- one exercises the "first rule wins" precedence: index 1 beats "also the
-- last element" for a 1-long list, index 2 beats "also last" for a 2-long
-- one, etc).
do
  local built = M.build({ "Todo", "Doing", "Done" })
  check("3-item: index 1 -> New", M.hl(built, "Todo") == "AzureCliWiNew")
  check("3-item: index 2 -> Active", M.hl(built, "Doing") == "AzureCliWiActive")
  check("3-item: last (3, second-to-last tie broken by last rule order) -> Removed",
    M.hl(built, "Done") == "AzureCliWiRemoved")
end

-- A duplicate name in the list keeps its first position's rank/colour.
do
  local built = M.build({ "Active", "Active", "Closed" })
  check("duplicate name keeps first rank", M.rank(built, "Active") == 1)
  check("duplicate name keeps first highlight", M.hl(built, "Active") == "AzureCliWiNew")
end

print()
if fails == 0 then
  print("all ok")
  os.exit(0)
else
  print(fails .. " failure(s)")
  os.exit(1)
end
