-- lua/azure-cli/review/folds.lua: remembers which "· N unchanged lines ·"
-- folds (review/pane.lua) you opened in a PR file's diff - when you come
-- back to the file, reopen the PR, or restart Neovim - and the diff pane's
-- toggle_fold key.
--
-- A fold is a run of level-1 lines in pane.lua's levels, identified by the
-- new-side line numbers of its first and last line (folded lines are all
-- context lines, so they have one): buffer line numbers would change with
-- every comment that keeps lines in view. Restoring opens each fold that
-- overlaps a remembered range, so one split or shifted by a new comment
-- still opens.
--
-- Saved in review/viewed.lua's file, per PR key, path and diff variant,
-- stamped with a hash of the diff it was made on (M.stamp): a push that
-- changes the file changes its diff, and its folds are dropped the next
-- time it's shown; a file the push left alone keeps them. Captured right
-- after toggle_fold and Vim's own za/zo/zO/zc/zC/zA/zR/zM, and when the
-- file leaves the window (folds opened by a search or `l` on the way).
-- The pure parts (M.runs, M.to_open, M.stamp's fallback) run under plain
-- luajit in tests/test-review-folds.lua.
local M = {}

-- Vim's own fold keys, wrapped so what they do is remembered too.
M.VIM_KEYS = { "za", "zo", "zO", "zc", "zC", "zA", "zR", "zM" }

-- The folds of a registered buffer: { first, last (buffer lines), s, e
-- (new-side line numbers) } per run of level-1 lines.
function M.runs(levels, map)
  local out = {}
  local n = #(levels or {})
  local i = 1
  while i <= n do
    if levels[i] == 1 then
      local j = i
      while j + 1 <= n and levels[j + 1] == 1 do j = j + 1 end
      local a, b = map[i], map[j]
      if a and b and a.lineno and b.lineno then
        out[#out + 1] = { first = i, last = j, s = a.lineno, e = b.lineno }
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return out
end

-- The runs overlapping any of the remembered `open` ranges ({ {s, e}, ... }).
function M.to_open(runs, open)
  local out = {}
  for _, r in ipairs(runs) do
    for _, o in ipairs(open or {}) do
      if type(o) == "table" and tonumber(o[1]) and tonumber(o[2])
          and r.s <= tonumber(o[2]) and tonumber(o[1]) <= r.e then
        out[#out + 1] = r
        break
      end
    end
  end
  return out
end

-- Identifies a diff's text: sha256 in Neovim, a plain 32-bit hash where
-- there's none (the luajit tests).
function M.stamp(lines)
  local text = table.concat(lines or {}, "\n")
  if vim and vim.fn and vim.fn.sha256 then return vim.fn.sha256(text) end
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%d:%08x", #text, h)
end

-- Neovim side ---------------------------------------------------------------

local info_by_buf = {}  -- bufnr -> { key, path, variant, tick, stamp }

local function PANE() return require("azure-cli.review.pane") end
local function VIEWED() return require("azure-cli.review.viewed") end

local function buf_stamp(buf, info)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if info.tick ~= tick then
    info.tick = tick
    info.stamp = M.stamp(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end
  return info.stamp
end

-- The window showing `buf` with the pane's folds on it, if any.
local function pane_win(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.wo[w].foldmethod == "expr" and tostring(vim.wo[w].foldexpr):find("review.pane", 1, true) then
      return w
    end
  end
  return nil
end

-- Records which of `buf`'s folds are open in its window.
function M.capture(buf)
  local info = info_by_buf[buf]
  local entry = PANE().entry(buf)
  if not (info and entry and vim.api.nvim_buf_is_valid(buf)) then return end
  local win = pane_win(buf)
  if not win then return end
  local open = {}
  vim.api.nvim_win_call(win, function()
    for _, r in ipairs(M.runs(entry.levels, entry.map)) do
      if vim.fn.foldclosed(r.first) == -1 then open[#open + 1] = { r.s, r.e } end
    end
  end)
  VIEWED().folds_set(info.key, info.path, info.variant, buf_stamp(buf, info), open)
end

-- Reopens the remembered folds in `win` (which shows `buf`, just re-folded
-- by pane.refresh) - or drops them when the diff changed under them.
function M.restore(win, buf)
  local info = info_by_buf[buf]
  local entry = PANE().entry(buf)
  if not (info and entry) then return end
  local rec = VIEWED().folds_get(info.key, info.path, info.variant)
  if type(rec) ~= "table" then return end
  if rec.stamp ~= buf_stamp(buf, info) then
    VIEWED().folds_drop(info.key, info.path, info.variant)
    return
  end
  local runs = M.to_open(M.runs(entry.levels, entry.map), rec.open)
  if #runs == 0 then return end
  vim.api.nvim_win_call(win, function()
    for _, r in ipairs(runs) do
      vim.cmd(("silent! %d,%dfoldopen"):format(r.first, r.last))
    end
  end)
end

-- toggle_fold: opens / closes the fold under the cursor; nothing on a line
-- that isn't in one.
function M.toggle(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if vim.fn.foldlevel(lnum) > 0 then
    vim.cmd("silent! normal! za")
    M.capture(buf)
  end
end

-- Sets `buf` (a reviewer diff buffer) up: info = { key (HOSTS.key), path,
-- variant }. Call before the buffer's own keymaps, so toggle_fold's keys
-- (za by default) win over the wrappers here.
function M.attach(buf, info)
  info_by_buf[buf] = { key = info.key, path = info.path, variant = info.variant or "" }
  for _, k in ipairs(M.VIM_KEYS) do
    vim.keymap.set("n", k, function()
      local c = vim.v.count
      vim.cmd("silent! normal! " .. (c > 0 and tostring(c) or "") .. k)
      M.capture(buf)
    end, { buffer = buf, silent = true, nowait = true, desc = "fold keys (remembered)" })
  end
  PANE().on_refresh(buf, function(win) M.restore(win, buf) end)
  vim.api.nvim_create_autocmd("BufWinLeave", { buffer = buf,
    callback = function() pcall(M.capture, buf) end })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true,
    callback = function() info_by_buf[buf] = nil end })
end

return M
