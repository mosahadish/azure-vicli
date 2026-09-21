-- lua/azure-cli/review/pane.lua: what the diff pane needs computed per
-- buffer line from Neovim's option callbacks - the 'statuscolumn' (old and
-- new line numbers, where plain 'number' used to show buffer lines that
-- matched neither) and the 'foldexpr'/'foldtext' that collapse long runs
-- of unchanged context to "· N unchanged lines ·" while keeping every
-- change, and every commented line, in view.
--
-- review/init.lua registers each diff buffer's per-line map here
-- (M.register) right after cache.lua's parse_diff builds it, and the
-- lines that carry comment threads (M.set_keep) once decorate_comments
-- has placed them; the option callbacks then look everything up by the
-- buffer they're evaluated for. The computations themselves are pure
-- (M.compute_levels, M.gutter_text) so tests/test-review-pane.lua runs
-- them under plain luajit.
local M = {}

-- How many unchanged lines to keep visible on each side of a change.
M.CONTEXT = 3

local by_buf = {}  -- bufnr -> { map, keep, levels, old_w, new_w }

-- Fold level per buffer line: 0 for a change, anything within CONTEXT of
-- one, a line in `keep` (a commented line) or CONTEXT around it; 1 for
-- the unchanged context beyond that - but only when the run is longer than
-- 2 lines, since a two-line fold saves nothing and reads worse.
function M.compute_levels(map, keep, context)
  context = context or M.CONTEXT
  keep = keep or {}
  local n = #map
  local anchor = {}
  for i, m in ipairs(map) do
    if (m.kind == "add" or m.kind == "del") or keep[i] then anchor[i] = true end
  end
  local levels = {}
  for i = 1, n do
    local near = false
    for j = math.max(1, i - context), math.min(n, i + context) do
      if anchor[j] then near = true break end
    end
    levels[i] = near and 0 or 1
  end
  -- Break up runs of level 1 that are too short to be worth folding.
  local i = 1
  while i <= n do
    if levels[i] == 1 then
      local j = i
      while j + 1 <= n and levels[j + 1] == 1 do j = j + 1 end
      if j - i + 1 <= 2 then
        for k = i, j do levels[k] = 0 end
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return levels
end

local function digits(n)
  return #tostring(math.max(1, n or 1))
end

-- The gutter text for line `lnum` of a registered entry: old number,
-- space, new number, each right-aligned in its column; an added line has
-- no old number and a deleted line no new one.
function M.gutter_text(entry, lnum)
  local m = entry.map[lnum]
  local ow, nw = entry.old_w, entry.new_w
  if not m or not m.lineno then
    return string.rep(" ", ow + 1 + nw + 1)
  end
  local old, new = "", ""
  if m.kind == "del" then
    old = tostring(m.lineno)
  elseif m.kind == "add" then
    new = tostring(m.lineno)
  else
    new = tostring(m.lineno)
    old = m.old and tostring(m.old) or ""
  end
  return string.format("%" .. ow .. "s %" .. nw .. "s ", old, new)
end

-- Registers `map` (cache.lua's parse_diff map, plus `old` filled in for
-- context lines below) for `buf`.
function M.register(buf, map)
  -- parse_diff records one lineno per line (the new side for a context
  -- line); the gutter wants both sides, and old = new - (adds so far -
  -- dels so far) recovers the old number exactly, across hunk boundaries.
  local maxo, maxn = 1, 1
  local adds, dels = 0, 0
  for _, m in ipairs(map) do
    if m.kind == "add" then
      adds = adds + 1
      maxn = math.max(maxn, m.lineno or 1)
    elseif m.kind == "del" then
      dels = dels + 1
      maxo = math.max(maxo, m.lineno or 1)
    elseif m.kind == "ctx" and m.lineno then
      m.old = m.lineno - adds + dels
      maxo = math.max(maxo, m.old)
      maxn = math.max(maxn, m.lineno)
    end
  end
  local entry = by_buf[buf] or {}
  entry.map = map
  entry.keep = entry.keep or {}
  entry.old_w = digits(maxo)
  entry.new_w = digits(maxn)
  entry.levels = M.compute_levels(map, entry.keep)
  by_buf[buf] = entry
  return entry
end

-- `keep`: buffer line -> truthy for lines that must never fold away (the
-- ones with comment threads).
function M.set_keep(buf, keep)
  local entry = by_buf[buf]
  if not entry then return end
  entry.keep = keep or {}
  entry.levels = M.compute_levels(entry.map, entry.keep)
end

function M.entry(buf)
  return by_buf[buf]
end

function M.forget(buf)
  by_buf[buf] = nil
end

-- Option callbacks (evaluated with the window's buffer current). ---------

function M.statuscolumn()
  local entry = by_buf[vim.api.nvim_get_current_buf()]
  local lnum = vim.v.lnum
  if not entry then return "%s%l " end
  if vim.v.virtnum and vim.v.virtnum ~= 0 then
    return "%s" .. string.rep(" ", entry.old_w + 1 + entry.new_w + 1)
  end
  return "%s%#LineNr#" .. M.gutter_text(entry, lnum) .. "%*"
end

function M.foldexpr(lnum)
  local entry = by_buf[vim.api.nvim_get_current_buf()]
  if not entry then return 0 end
  return entry.levels[lnum] or 0
end

function M.foldtext()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return "\u{00B7} " .. n .. " unchanged line" .. (n == 1 and "" or "s") .. " \u{00B7}"
end

-- Applies the pane's window options to `win` (called after every buffer
-- switch into a diff buffer - window options reset per new buffer).
function M.apply(win)
  local UI = require("azure-cli.ui")
  local ok = pcall(UI.wo, win, "statuscolumn", "%!v:lua.require'azure-cli.review.pane'.statuscolumn()")
  UI.wo(win, "number", not ok)  -- Neovim < 0.9: fall back to plain numbers
  UI.wo(win, "signcolumn", "yes:1")
  pcall(UI.wo, win, "foldmethod", "expr")
  pcall(UI.wo, win, "foldexpr", "v:lua.require'azure-cli.review.pane'.foldexpr(v:lnum)")
  pcall(UI.wo, win, "foldtext", "v:lua.require'azure-cli.review.pane'.foldtext()")
  pcall(UI.wo, win, "foldenable", true)
  pcall(UI.wo, win, "foldlevel", 0)
  pcall(UI.wo, win, "foldminlines", 2)
  pcall(UI.wo, win, "fillchars", "fold: ")
end

-- Re-evaluates the folds in `win` when it shows `buf` (after the map or
-- keep set changed).
function M.refresh(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if vim.api.nvim_win_get_buf(win) ~= buf then return end
  pcall(vim.api.nvim_win_call, win, function() vim.cmd("silent! normal! zx") end)
end

return M
