-- test-split.lua: checks prdash-cache.lua's split_diff + parse_diff against
-- per-file `git diff` output, over a real range of this repo's own history
-- (many files, additions, deletions, a rename-free but otherwise ordinary
-- set of changes) rather than the tiny synthetic scratch repo the other
-- tests use.
--
-- Usage: luajit test-split.lua <prdash-cache.lua path> <git-range>
-- Run with cwd inside the repo whose history <git-range> refers to (run.sh
-- runs it from the real azure-vicli checkout).
--
-- For every file touched by <git-range>, splits the whole-range diff with
-- M.split_diff and compares M.parse_diff on that file's slice against
-- M.parse_diff on a `git diff` run for that single file directly. They must
-- agree line-for-line, including each line's side/lineno.

-- Minimal vim shim for the pure functions.
vim = { list_extend = function(a, b) for _, v in ipairs(b) do a[#a+1] = v end return a end,
        tbl_filter = function(f, t) local o = {} for _, v in ipairs(t) do if f(v) then o[#o+1] = v end end return o end,
        fn = { jobstart = function() error("no jobs in test") end }, schedule = function(f) f() end }

local M = dofile(arg[1])
local range = arg[2]
assert(range, "usage: luajit test-split.lua <prdash-cache.lua> <git-range>")

local function lines_of(cmd)
  local p = io.popen(cmd); local out = {} for l in p:lines() do out[#out+1] = l end p:close(); return out
end

local files = lines_of("git diff --name-only " .. range)
local whole = lines_of("git diff --unified=100000 " .. range)
local per = M.split_diff(whole)
local ok, bad = 0, 0
for _, f in ipairs(files) do
  local single = lines_of("git diff --unified=100000 " .. range .. " -- '" .. f .. "'")
  local l1, m1 = M.parse_diff(per[f] or {})
  local l2, m2 = M.parse_diff(single)
  local same = per[f] ~= nil and #l1 == #l2
  if same then for i = 1, #l1 do if l1[i] ~= l2[i] or m1[i].side ~= m2[i].side or m1[i].lineno ~= m2[i].lineno then same = false break end end end
  if same then ok = ok + 1 else bad = bad + 1; print("MISMATCH: " .. f .. " split=" .. tostring(per[f] and #per[f]) .. " single=" .. #single) end
end
print(string.format("files=%d match=%d mismatch=%d", #files, ok, bad))
assert(#files > 0, "range produced no files to check - widen the range")
if bad > 0 then os.exit(1) end
