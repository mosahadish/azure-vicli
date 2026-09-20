-- test-decorate.lua: extracts the revision-decoration line walk out of
-- pr-review.lua (the loop that turns a parsed diff into own-side
-- highlights plus other-side virtual lines for a revision buffer) and
-- checks it against a real diff, for both sides.
--
-- Usage: luajit test-decorate.lua <prdash-cache.lua path> <pr-review.lua path> <scratch repo dir>
--
-- f.txt in the scratch repo: tgt = {a, b}; src = {a, B, c}. So on the
-- source side line 2 (B) and line 3 (c) are additions, with the deleted "b"
-- floating as a virtual line above line 2; on the target side line 2 (b) is
-- a deletion, with B and c appearing as two virtual lines below it (nothing
-- follows on that side, so they anchor below the last line).

local marks = {}
vim = {
  list_extend = function(a, b) for _, v in ipairs(b) do a[#a+1] = v end return a end,
  tbl_filter = function(f, t) local o = {} for _, v in ipairs(t) do if f(v) then o[#o+1] = v end end return o end,
  api = { nvim_buf_set_extmark = function(_, _, row, _, o) marks[#marks+1] = { row = row, o = o } end },
}

local M = dofile(arg[1])
local pr_review_path = arg[2]
local repo = arg[3]
assert(pr_review_path and repo, "usage: luajit test-decorate.lua <prdash-cache.lua> <pr-review.lua> <scratch repo dir>")

local src = io.open(pr_review_path):read("*a")
local walk = src:match("(    local old, new = 0, 0\n.-    flush%(n %+ 1%)\n)")
assert(walk, "walk not found")
local function run(raw, own_side, n)
  marks = {}
  local lines, map = M.parse_diff(raw)
  local env = { lines = lines, map = map, n = n, own_side = own_side, buf = 1, diff_ns = 1,
    own_kind = own_side == "R" and "add" or "del", own_bg = "OWN", own_sign = "S", other_bg = "OTHER",
    ipairs = ipairs, math = math, pcall = pcall, vim = vim }
  local f = assert(load(walk, "walk", "t", env))
  f()
  return marks
end
local p = io.popen("git -C " .. repo .. " diff --unified=100000 origin/tgt...origin/src -- f.txt")
local raw = {} for l in p:lines() do raw[#raw+1] = l end p:close()
-- f.txt: tgt = {a, b}; src = {a, B, c}  => src side: line 2 (B) add, line 3 (c) add, deleted "b" above line 2
local m = run(raw, "R", 3)
local adds, virt = {}, {}
for _, x in ipairs(m) do
  if x.o.line_hl_group then adds[#adds+1] = x.row + 1 end
  if x.o.virt_lines then virt[#virt+1] = { row = x.row + 1, above = x.o.virt_lines_above, text = x.o.virt_lines[1][1][1] } end
end
assert(table.concat(adds, ",") == "2,3", "adds " .. table.concat(adds, ","))
for _, v in ipairs(virt) do print("virt:", v.row, v.above, v.text) end; print("adds:", table.concat(adds, ",")); assert(#virt == 1 and virt[1].row == 2 and virt[1].above == true and virt[1].text == "b", "virt mismatch")
-- target side: line 2 (b) deleted, added B and c appear as virtual lines below the last line? B,c come after b in the diff, then nothing -> anchored at end (below line 2)
m = run(raw, "L", 2)
local dels, virt2 = {}, {}
for _, x in ipairs(m) do
  if x.o.line_hl_group then dels[#dels+1] = x.row + 1 end
  if x.o.virt_lines then virt2[#virt2+1] = { row = x.row + 1, above = x.o.virt_lines_above, n = #x.o.virt_lines } end
end
assert(table.concat(dels, ",") == "2", "dels " .. table.concat(dels, ","))
assert(#virt2 == 1 and virt2[1].n == 2 and virt2[1].above == false and virt2[1].row == 2, "virt2")
print("decorate walk ok: source adds=" .. table.concat(adds, ",") .. " removed-virtual above line " .. virt[1].row .. "; target dels=" .. table.concat(dels, ",") .. " added-virtual below line " .. virt2[1].row)
