-- test-review-bom.lua: review/bom.lua on real cache.lua parse_diff output -
-- a UTF-8 BOM on both sides, on one side only, none, and alongside a real
-- line-1 change - and that line 1 of a BOM file still anchors comments to
-- the file's line 1.
-- Usage: luajit test-review-bom.lua <bom.lua> <cache.lua> <pane.lua>
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
assert(arg[3], "usage: luajit test-review-bom.lua <bom.lua> <cache.lua> <pane.lua>")
local B = dofile(arg[1])
local CACHE = dofile(arg[2])
vim = { api = {}, v = {} }
local P = dofile(arg[3])
vim = nil

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

local BOM = "\239\187\191"
local HEAD = { "diff --git a/A.cs b/A.cs", "index 1111111..2222222 100644", "--- a/A.cs", "+++ b/A.cs" }
local function diff(body)
  local out = {}
  for _, l in ipairs(HEAD) do out[#out + 1] = l end
  for _, l in ipairs(body) do out[#out + 1] = l end
  return CACHE.parse_diff(out)
end
local function changes(map)
  local n = 0
  for _, m in ipairs(map) do if m.kind == "add" or m.kind == "del" then n = n + 1 end end
  return n
end

-- BOM on both sides, line 1 unchanged.
do
  local lines, map = B.normalize(diff({ "@@ -1,3 +1,3 @@", " " .. BOM .. "using Google.Protobuf;", " class A",
    "-  old", "+  new" }))
  check("both sides: line 1 reads without the BOM", lines[1] == "using Google.Protobuf;", lines[1])
  check("both sides: line 1 is context R:1", map[1].kind == "ctx" and map[1].side == "R" and map[1].lineno == 1)
  check("both sides: the real change stays", changes(map) == 2)
end

-- BOM added on the new side only: one unchanged line 1.
do
  local lines, map = B.normalize(diff({ "@@ -1,2 +1,2 @@", "-using X;", "+" .. BOM .. "using X;", " class A" }))
  check("new side only: one line 1, no change", #lines == 2 and lines[1] == "using X;" and changes(map) == 0,
    #lines .. " " .. changes(map))
  check("new side only: line 1 is R:1, line 2 R:2", map[1].side == "R" and map[1].lineno == 1
    and map[2].lineno == 2 and map[2].kind == "ctx")
end

-- BOM removed on the old side only, inside a longer removal.
do
  local lines, map = B.normalize(diff({ "@@ -1,3 +1,2 @@", "-" .. BOM .. "using X;", "-// gone", "+using X;", " class A" }))
  check("old side only: line 1 unchanged, the other removal stays",
    lines[1] == "using X;" and map[1].kind == "ctx" and map[1].lineno == 1
    and map[2].kind == "del" and map[2].lineno == 2 and lines[2] == "// gone" and changes(map) == 1,
    table.concat(lines, "|"))
  local e = P.register(1, map)
  check("old side only: gutter numbers still match the file",
    P.gutter_text(e, 1) == "1 " and P.gutter_text(e, 2) == "2 " and P.gutter_text(e, 3) == "2 "
    and map[3].old == 3, P.gutter_text(e, 3))
end

-- No BOM: the very same tables.
do
  local l0, m0 = diff({ "@@ -1,2 +1,2 @@", "-using X;", "+using Y;", " class A" })
  local l1, m1 = B.normalize(l0, m0)
  check("no BOM: untouched", l1 == l0 and m1 == m0)
  check("no placeholder trouble", B.normalize({ "(no textual diff for this file)" }, { {} }) ~= nil)
end

-- BOM plus a real change on line 1: still a change, both texts stripped.
do
  local lines, map = B.normalize(diff({ "@@ -1,1 +1,1 @@", "-" .. BOM .. "using X;", "+" .. BOM .. "using Y;" }))
  check("real change: a del/add pair without BOMs",
    changes(map) == 2 and lines[1] == "using X;" and lines[2] == "using Y;")
end

-- A comment on line 1 of a BOM file lands on buffer line 1, the way
-- review/init.lua's decorate_comments keys threads (path, side, lineno).
do
  local _, map = B.normalize(diff({ "@@ -1,2 +1,2 @@", "-using X;", "+" .. BOM .. "using X;", " class A" }))
  local threads = { ["A.cs\tR\t1"] = true }
  local at
  for bl, m in ipairs(map) do
    if m.side and threads["A.cs\t" .. m.side .. "\t" .. m.lineno] then at = bl end
  end
  check("a comment on line 1 lands on buffer line 1", at == 1, tostring(at))
end

-- fix(): a cache bucket's entry is normalized once, other fields kept.
do
  local l, m = diff({ "@@ -1,1 +1,1 @@", " " .. BOM .. "x" })
  local bucket = { ["A.cs"] = { lines = l, map = m, extra = 1 } }
  local e = B.fix(bucket, "A.cs")
  check("fix: in the bucket, once", e == bucket["A.cs"] and e.lines[1] == "x" and e.extra == 1
    and B.fix(bucket, "A.cs") == e)
end

print(fails == 0 and "test-review-bom: all cases pass" or ("test-review-bom: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
