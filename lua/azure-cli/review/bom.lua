-- lua/azure-cli/review/bom.lua: a leading UTF-8 byte-order mark (common in
-- Visual Studio's C# files) would show as "<feff>" at the start of line 1
-- in the diff, and a BOM on one side only would make line 1 a change.
-- M.normalize strips it from both sides' line 1 of a parsed diff (cache.lua's
-- parse_diff {lines, map}) and, when that leaves the removed and added line
-- 1 equal, folds the pair into one context line. Only display text changes:
-- every map entry keeps its side and lineno, so comments still anchor to
-- the file's real lines. Pure, so tests/test-review-bom.lua runs it under
-- plain luajit.
local M = {}

M.BOM = "\239\187\191"

local function strip(s)
  if type(s) == "string" and s:sub(1, 3) == M.BOM then return s:sub(4), true end
  return s, false
end

-- Returns `lines, map` with the BOM gone - the same tables when there's
-- none, so calling it again (or on a clean diff) costs a look at the first
-- few entries. Git lists a hunk's removed lines before its added ones, so
-- old line 1 (if removed) is the first entry and new line 1 the first one
-- that isn't a removal.
function M.normalize(lines, map)
  if type(lines) ~= "table" or type(map) ~= "table" then return lines, map end
  local del_i, new_i
  local first = map[1]
  if first and first.kind == "del" and first.lineno == 1 then del_i = 1 end
  for i, m in ipairs(map) do
    if m.kind ~= "del" then
      if m.lineno == 1 and (m.kind == "add" or m.kind == "ctx") then new_i = i end
      break
    end
  end
  local dl, dhas = strip(del_i and lines[del_i])
  local nl, nhas = strip(new_i and lines[new_i])
  if not (dhas or nhas) then return lines, map end
  local L, Mp = {}, {}
  for i = 1, #lines do L[i] = lines[i] end
  for i = 1, #map do Mp[i] = map[i] end
  if del_i then L[del_i] = dl end
  if new_i then L[new_i] = nl end
  -- Only the BOM differed: one unchanged line 1, where the removal was.
  if del_i and new_i and new_i > del_i and map[new_i].kind == "add" and dl == nl then
    Mp[del_i] = { side = "R", lineno = 1, kind = "ctx" }
    table.remove(L, new_i)
    table.remove(Mp, new_i)
  end
  return L, Mp
end

-- Normalizes `bucket[path]` ({lines, map}, a review/init.lua content cache
-- entry) in place, once, and returns it.
function M.fix(bucket, path)
  local e = bucket and bucket[path]
  if not (e and e.lines and e.map) then return e end
  local lines, map = M.normalize(e.lines, e.map)
  if lines ~= e.lines then
    local copy = {}
    for k, v in pairs(e) do copy[k] = v end
    copy.lines, copy.map = lines, map
    e = copy
    bucket[path] = e
  end
  return e
end

return M
