-- test-review-pane.lua: review/pane.lua's pure fold-level and gutter
-- computations. Usage: luajit test-review-pane.lua <pane.lua path>
local path = arg[1]
assert(path, "usage: luajit test-review-pane.lua <pane.lua>")
vim = { api = {}, v = {} }  -- only the option callbacks touch vim; not exercised here
local P = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

local function ctx(n) return { side = "R", lineno = n, kind = "ctx" } end
-- 12 context lines, a change at 13/14, 12 more context lines.
local map = {}
for i = 1, 12 do map[#map + 1] = ctx(i) end
map[#map + 1] = { side = "L", lineno = 13, kind = "del" }
map[#map + 1] = { side = "R", lineno = 13, kind = "add" }
for i = 14, 25 do map[#map + 1] = ctx(i) end

local levels = P.compute_levels(map, {}, 3)
check("levels: far context folds", levels[1] == 1 and levels[5] == 1 and levels[9] == 1)
check("levels: 3 lines before a change stay", levels[10] == 0 and levels[11] == 0 and levels[12] == 0)
check("levels: the change stays", levels[13] == 0 and levels[14] == 0)
check("levels: 3 lines after stay", levels[15] == 0 and levels[17] == 0)
check("levels: far context after folds", levels[18] == 1 and levels[26] == 1)

local levels2 = P.compute_levels(map, { [4] = true }, 3)
check("levels: a commented line and its context stay", levels2[4] == 0 and levels2[1] == 0 and levels2[7] == 0)
-- Lines 8-9 are the only foldable run left between the kept line's
-- context and the change's: two lines, not worth a fold.
check("levels: a too-short run is unfolded", levels2[8] == 0 and levels2[9] == 0)

-- Gutter: old/new numbering across a hunk with adds and dels.
local m2 = { ctx(10), { side = "L", lineno = 11, kind = "del" }, { side = "R", lineno = 11, kind = "add" },
  { side = "R", lineno = 12, kind = "add" }, ctx(13), ctx(14) }
local entry = P.register(1, m2)
check("register: ctx old numbers", m2[1].old == 10 and m2[5].old == 12 and m2[6].old == 13)
check("gutter: context shows both", P.gutter_text(entry, 1) == "10 10 ")
check("gutter: deleted shows old only", P.gutter_text(entry, 2) == "11    ")
check("gutter: added shows new only", P.gutter_text(entry, 3) == "   11 ")
check("gutter: widths follow the max", entry.old_w == 2 and entry.new_w == 2)
check("gutter: unmapped line is blank", P.gutter_text(entry, 99) == "      ")
P.set_keep(1, { [5] = true })
check("set_keep: recomputes levels", P.entry(1).levels[5] == 0)
P.forget(1)
check("forget", P.entry(1) == nil)

print(fails == 0 and "test-review-pane: all cases pass" or ("test-review-pane: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
