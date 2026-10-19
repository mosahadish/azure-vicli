-- test-review-folds.lua: review/folds.lua's pure parts - fold runs and
-- their new-side ids, which runs a remembered set reopens, the diff stamp -
-- and the remember / drop rules against review/viewed.lua's in-memory store.
-- Usage: luajit test-review-folds.lua <folds.lua> <pane.lua> <viewed.lua>
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
assert(arg[3], "usage: luajit test-review-folds.lua <folds.lua> <pane.lua> <viewed.lua>")
vim = nil
local F = dofile(arg[1])
local P
do
  vim = { api = {}, v = {} }
  P = dofile(arg[2])
  vim = nil
end
local V = dofile(arg[3])

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

local function ctx(n) return { side = "R", lineno = n, kind = "ctx" } end
-- 20 context lines, a change (old 21 -> new 21), 20 more: two folds.
local map = {}
for i = 1, 20 do map[#map + 1] = ctx(i) end
map[#map + 1] = { side = "L", lineno = 21, kind = "del" }
map[#map + 1] = { side = "R", lineno = 21, kind = "add" }
for i = 22, 41 do map[#map + 1] = ctx(i) end
local levels = P.compute_levels(map, {}, 3)
local runs = F.runs(levels, map)
check("runs: one per fold", #runs == 2, #runs)
check("runs: ids are new-side line ranges", runs[1].s == 1 and runs[1].e == 17 and runs[2].s == 25 and runs[2].e == 41,
  runs[1].s .. "-" .. runs[1].e .. " " .. runs[2].s .. "-" .. runs[2].e)
check("runs: buffer lines kept for opening", runs[1].first == 1 and runs[2].first == 26 and runs[2].last == 42)

check("to_open: exact range", #F.to_open(runs, { { 25, 41 } }) == 1 and F.to_open(runs, { { 25, 41 } })[1] == runs[2])
check("to_open: nothing remembered", #F.to_open(runs, {}) == 0)
check("to_open: zR (every run) opens both", #F.to_open(runs, { { 1, 17 }, { 25, 41 } }) == 2)
check("to_open: junk ignored", #F.to_open(runs, { "x", { "a" } }) == 0)
-- A comment on new line 9 keeps 6..12 in view: the first fold splits in
-- two, and both halves still open from the one remembered range.
local runs2 = F.runs(P.compute_levels(map, { [9] = true }, 3), map)
check("split: the fold became two", #runs2 == 3, #runs2)
check("split: both halves reopen", #F.to_open(runs2, { { 1, 17 } }) == 2)

local a = { "using System;", "class A {}" }
check("stamp: same lines, same stamp", F.stamp(a) == F.stamp({ "using System;", "class A {}" }))
check("stamp: changed lines, new stamp", F.stamp(a) ~= F.stamp({ "using System;", "class B {}" }))

-- The rules restore / capture follow, through the store.
V.use_store({})
V.folds_set("k", "a.cs", "", F.stamp(a), { { 25, 41 } })
local rec = V.folds_get("k", "a.cs", "")
check("remembered under the diff's stamp", rec and rec.stamp == F.stamp(a))
check("an unchanged diff reopens them", rec.stamp == F.stamp(a) and #F.to_open(runs, rec.open) == 1)
check("a pushed change to the file doesn't match", rec.stamp ~= F.stamp({ "using System;", "class B {}" }))
V.folds_set("k", "a.cs", "", F.stamp(a), {})
check("zM (nothing open) forgets the file", V.folds_get("k", "a.cs", "") == nil)

print(fails == 0 and "test-review-folds: all cases pass" or ("test-review-folds: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
