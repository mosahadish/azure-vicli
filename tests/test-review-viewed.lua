-- test-review-viewed.lua: review/viewed.lua against an in-memory store.
-- Usage: luajit test-review-viewed.lua <viewed.lua path>
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local path = arg[1]
assert(path, "usage: luajit test-review-viewed.lua <viewed.lua>")
vim = nil
local V = dofile(path)
V.use_store({})

local fails = 0
local function check(name, cond)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name) end
end

local files = { "a.py", "b.txt", "c.md" }
check("nothing viewed at first", V.count(1, files, "t1") == 0)
V.set(1, "a.py", "t1", true)
check("set marks", V.is_viewed(1, "a.py", "t1"))
check("count", V.count(1, files, "t1") == 1)
check("a new push clears the mark", not V.is_viewed(1, "a.py", "t2"))
check("another PR is separate", not V.is_viewed(2, "a.py", "t1"))
check("toggle off", V.toggle(1, "a.py", "t1") == false and V.count(1, files, "t1") == 0)
check("toggle on", V.toggle(1, "a.py", "t1") == true)
check("next unviewed from a.py", V.next_unviewed(1, files, "t1", 1, 1) == 2)
check("prev unviewed wraps", V.next_unviewed(1, files, "t1", 1, -1) == 3)
V.set(1, "b.txt", "t1", true); V.set(1, "c.md", "t1", true)
check("all viewed -> nil", V.next_unviewed(1, files, "t1", 1, 1) == nil)

-- Remembered folds (review/folds.lua) share the store.
do
  local s = {}
  V.use_store(s)
  check("no folds at first", V.folds_get("org~p~7", "a.cs", "") == nil)
  V.folds_set("org~p~7", "a.cs", "", "h1", { { 10, 40 }, { 90, 120 } })
  local r = V.folds_get("org~p~7", "a.cs", "")
  check("folds round-trip", r and r.stamp == "h1" and #r.open == 2 and r.open[2][1] == 90)
  check("folds: another variant is separate", V.folds_get("org~p~7", "a.cs", "w") == nil)
  check("folds: another PR is separate", V.folds_get("org~p~8", "a.cs", "") == nil)
  V.set("org~p~7", "a.cs", "t1", true)
  check("folds and viewed marks don't interfere",
    V.is_viewed("org~p~7", "a.cs", "t1") and V.count("org~p~7", { "a.cs", "b.cs" }, "t1") == 1
    and V.folds_get("org~p~7", "a.cs", "").stamp == "h1")
  V.folds_set("org~p~7", "a.cs", "", "h1", {})
  check("folds: nothing open deletes the record", V.folds_get("org~p~7", "a.cs", "") == nil and s["\tfolds"] == nil)
  V.folds_set("org~p~7", "b.cs", "", "h2", { { 1, 9 } })
  V.folds_drop("org~p~7", "b.cs", "")
  check("folds_drop", V.folds_get("org~p~7", "b.cs", "") == nil)

  -- A store written before folds were remembered: marks only.
  V.use_store({ ["5\ta.py"] = "t1", ["5\tb.py"] = "t1" })
  check("an old viewed file still loads its marks", V.count(5, { "a.py", "b.py", "c.py" }, "t1") == 2)
  check("and has no folds", V.folds_get(5, "a.py", "") == nil)
end

print(fails == 0 and "test-review-viewed: all cases pass" or ("test-review-viewed: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
