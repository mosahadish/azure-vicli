-- lua/azure-cli/review/pane.lua: what the diff pane needs computed per
-- buffer line from Neovim's option callbacks - the 'statuscolumn' (the
-- file's own line numbers, where plain 'number' used to show buffer lines
-- that matched neither) and the 'foldexpr'/'foldtext' that collapse long runs
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

local by_buf = {}  -- bufnr -> { map, keep, levels, w }
local on_refresh = {}  -- bufnr -> fn(win, buf), run after M.refresh re-folds

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

-- The gutter text for line `lnum` of a registered entry: one number,
-- right-aligned - the new file's for a context or added line, the old
-- file's for a removed one (M.statuscolumn dims that). Display only:
-- comments anchor through the map's side/lineno, never through this.
function M.gutter_text(entry, lnum)
  local m = entry.map[lnum]
  if not m or not m.lineno then
    return string.rep(" ", entry.w + 1)
  end
  return string.format("%" .. entry.w .. "s ", tostring(m.lineno))
end

-- The highlight group for line `lnum`'s number: a removed line's old
-- number is dimmed.
function M.gutter_group(entry, lnum)
  local m = entry.map[lnum]
  return (m and m.kind == "del") and "AzureCliGutterOld" or "LineNr"
end

-- Registers `map` (cache.lua's parse_diff map, plus `old` filled in for
-- context lines below) for `buf`.
function M.register(buf, map)
  -- parse_diff records one lineno per line (the new side for a context
  -- line); old = new - (adds so far - dels so far) recovers a context
  -- line's old number exactly, across hunk boundaries. The gutter's one
  -- column is as wide as the larger side needs.
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
  entry.w = digits(math.max(maxo, maxn))
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
  on_refresh[buf] = nil
end

-- `fn(win, buf)` runs after every M.refresh of `buf` - review/folds.lua
-- reopens the folds you had open, since the refresh's zX folds them all.
function M.on_refresh(buf, fn)
  on_refresh[buf] = fn
end

-- Option callbacks (evaluated with the window's buffer current). ---------

function M.statuscolumn()
  -- The window being drawn, not the current one: with a float focused (K)
  -- the current buffer is the float's, and the diff's numbers went blank.
  local win = vim.g.statusline_winid
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win or 0)
  local entry = by_buf[ok and buf or vim.api.nvim_get_current_buf()]
  local lnum = vim.v.lnum
  if not entry then return "%s%l " end
  if vim.v.virtnum and vim.v.virtnum ~= 0 then
    return "%s" .. string.rep(" ", entry.w + 1)
  end
  return "%s%#" .. M.gutter_group(entry, lnum) .. "#" .. M.gutter_text(entry, lnum) .. "%*"
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
  pcall(vim.api.nvim_set_hl, 0, "AzureCliGutterOld", { link = "Comment", default = true })
  local ok = pcall(UI.wo, win, "statuscolumn", "%!v:lua.require'azure-cli.review.pane'.statuscolumn()")
  UI.wo(win, "number", not ok)  -- Neovim < 0.9: fall back to plain numbers
  UI.wo(win, "signcolumn", "yes:1")
  pcall(UI.wo, win, "foldmethod", "expr")
  pcall(UI.wo, win, "foldexpr", "v:lua.require'azure-cli.review.pane'.foldexpr(v:lnum)")
  pcall(UI.wo, win, "foldtext", "v:lua.require'azure-cli.review.pane'.foldtext()")
  pcall(UI.wo, win, "foldenable", true)
  pcall(UI.wo, win, "foldlevel", 0)
  pcall(UI.wo, win, "foldminlines", 2)
  pcall(UI.wo, win, "fillchars", "fold: ,eob: ")
end

-- Re-evaluates the folds in `win` when it shows `buf` (after the map or
-- keep set changed, or the buffer came back into the window), then runs
-- the buffer's M.on_refresh hook. zX, not zx: zx also opens the fold the
-- cursor is in (zv), which would then be remembered as one you opened.
function M.refresh(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if vim.api.nvim_win_get_buf(win) ~= buf then return end
  pcall(vim.api.nvim_win_call, win, function() vim.cmd("silent! normal! zX") end)
  if on_refresh[buf] and by_buf[buf] then pcall(on_refresh[buf], win, buf) end
end

return M
