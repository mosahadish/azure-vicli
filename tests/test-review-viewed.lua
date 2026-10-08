-- test-review-viewed.lua: review/viewed.lua against an in-memory store.
-- Usage: luajit test-review-viewed.lua <viewed.lua path>
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

print(fails == 0 and "test-review-viewed: all cases pass" or ("test-review-viewed: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
