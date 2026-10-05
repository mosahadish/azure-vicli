-- lua/azure-cli/chat/changes.lua: the agent's proposed change (show_fix),
-- shown the way the reviewer shows a PR: a tab with the changed files on the
-- left and one file's diff on the right, built from the reviewer's own parts
-- (cache.lua's parse_diff/split_diff/word_diff, review/pane.lua's line
-- numbers and folds, the same diff colours) and bound through the same
-- keys.lua surfaces ("list" for the file list, "diff" for the diff pane), so
-- ]c / [c, <CR>, <BS>, gf, < / > and q work as they do there - remapped ones
-- included.
--
--   M.open(title, dir, raw)   shows `raw` (`git diff` output of worktree
--                             `dir`), reusing the tab when it's still open
--   M.files(raw)              the changed files in diff order: { path,
--                             status = "A"|"D"|"R"|"M" } (pure)
local M = {}

local ns = vim.api.nvim_create_namespace("azure_cli_chat_changes")

local view = nil  -- { tab, list_win, diff_win, list_buf, files, diffs, bufs, title, dir }

local function KEYS() return require("azure-cli.keys") end
local function UI() return require("azure-cli.ui") end
local function notify(msg) require("azure-cli.shell").notify(msg) end

function M.files(raw)
  local out = {}
  local cur
  for _, l in ipairs(raw) do
    local a, b = l:match("^diff %-%-git a/(.-) b/(.*)$")
    if a then
      cur = { path = b, status = "M" }
      out[#out + 1] = cur
    elseif cur then
      if l:match("^new file") then cur.status = "A"
      elseif l:match("^deleted file") then cur.status = "D"
      elseif l:match("^rename from") then cur.status = "R" end
      local plus = l:match("^%+%+%+ b/(.*)$")
      local minus = l:match("^%-%-%- a/(.*)$")
      if plus then cur.path = plus elseif minus and cur.status == "D" then cur.path = minus end
    end
  end
  return out
end

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end

local function is_change(map, i)
  local m = map[i]
  return m ~= nil and (m.kind == "add" or m.kind == "del")
end

-- The same marks the reviewer puts on a diff (review/init.lua's
-- decorate_diff): a +/- sign and line colour, the changed words stronger.
local function decorate(buf, lines, map)
  local CACHE = require("azure-cli.cache")
  for bl, m in ipairs(map) do
    if m.kind == "add" or m.kind == "del" then
      local add = m.kind == "add"
      vim.api.nvim_buf_set_extmark(buf, ns, bl - 1, 0, {
        sign_text = add and "+" or "-",
        sign_hl_group = add and "AzureCliDiffAddSign" or "AzureCliDiffDelSign",
        line_hl_group = add and "AzureCliDiffAddBg" or "AzureCliDiffDelBg",
      })
    end
  end
  for _, w in ipairs(CACHE.word_diff(lines, map)) do
    vim.api.nvim_buf_set_extmark(buf, ns, w.line - 1, w.s, {
      end_col = w.e, hl_group = w.kind == "add" and "AzureCliDiffAddWord" or "AzureCliDiffDelWord",
    })
  end
end

local LIST_HELP = {
  "Files",
  { "open", "show the file's change" },
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "quit", "close" }, { "help", "this help" },
}
local DIFF_HELP = {
  "Navigate",
  { "next_hunk", "next change (continues into the next file)" },
  { "prev_hunk", "previous change (continues into the previous file)" },
  { "back", "back to the file list" },
  { "open_file", "edit the file in the worktree, at this line" },
  "Window",
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "quit", "close" }, { "help", "this help" },
}

local function help(surface, tbl)
  UI().open_float(KEYS().help_lines(surface, "Proposed change keys", tbl,
    { fixed = { KEYS().line_raw("j / k", "move") } }), { title = "Keys" })
end

local function close()
  if view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab) then
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(view.tab))
    end
  end
end

local function resize(delta)
  if not (view and valid_win(view.list_win)) then return end
  view.width = math.max(15, vim.api.nvim_win_get_width(view.list_win) + delta)
  pcall(vim.api.nvim_win_set_width, view.list_win, view.width)
end

local function set_diff_winbar(path)
  if not valid_win(view.diff_win) then return end
  local K = KEYS()
  local hints = {}
  for _, h in ipairs({ K.label("diff", "next_hunk", "next change"), K.label("diff", "back", "files"),
    K.label("diff", "open_file", "edit"), K.label("diff", "help", "keys") }) do
    if h ~= "" then hints[#hints + 1] = h end
  end
  pcall(UI().wo, view.diff_win, "winbar", "%#Title# " .. path:gsub("%%", "%%%%") .. "%* %#Comment#  "
    .. table.concat(hints, "  "))
end

local jump  -- forward

-- The diff buffer for file `idx` (built once per open).
local function diff_buf(idx)
  local f = view.files[idx]
  if view.bufs[f.path] and vim.api.nvim_buf_is_valid(view.bufs[f.path]) then return view.bufs[f.path] end
  local CACHE = require("azure-cli.cache")
  local lines, map = CACHE.parse_diff(view.diffs[f.path] or {})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ok, ft = pcall(vim.filetype.match, { filename = f.path })
  if ok and ft then pcall(function() vim.bo[buf].syntax = ft end) end
  pcall(vim.treesitter.start, buf, ok and ft and vim.treesitter.language.get_lang(ft) or nil)
  decorate(buf, lines, map)
  require("azure-cli.review.pane").register(buf, map)
  view.bufs[f.path] = buf
  view.maps = view.maps or {}
  view.maps[buf] = { idx = idx, map = map }
  local K = KEYS()
  K.bind(buf, "diff", "next_hunk", function() jump(1) end, { desc = "next change" })
  K.bind(buf, "diff", "prev_hunk", function() jump(-1) end, { desc = "previous change" })
  K.bind(buf, "diff", "back", function()
    if valid_win(view.list_win) then vim.api.nvim_set_current_win(view.list_win) end
  end, { desc = "back to the file list" })
  K.bind(buf, "diff", "open_file", function()
    local m = map[vim.api.nvim_win_get_cursor(0)[1]] or {}
    local line = m.side == "R" and m.lineno or 1
    vim.cmd("tabedit " .. vim.fn.fnameescape(view.dir .. "/" .. f.path))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end, { desc = "edit the file in the worktree" })
  K.bind(buf, "diff", "resize_less", function() resize(-5) end, { desc = "shrink the file list" })
  K.bind(buf, "diff", "resize_more", function() resize(5) end, { desc = "grow the file list" })
  K.bind(buf, "diff", "quit", close, { desc = "close" })
  K.bind(buf, "diff", "help", function() help("diff", DIFF_HELP) end, { desc = "keys" })
  return buf
end

-- Shows file `idx` in the diff pane; focus moves there when `focus`.
local function show(idx, focus)
  if not (view and view.files[idx] and valid_win(view.diff_win)) then return nil end
  local buf = diff_buf(idx)
  vim.api.nvim_win_set_buf(view.diff_win, buf)
  require("azure-cli.review.pane").apply(view.diff_win)
  set_diff_winbar(view.files[idx].path)
  view.current = idx
  if valid_win(view.list_win) then pcall(vim.api.nvim_win_set_cursor, view.list_win, { idx, 0 }) end
  if focus then vim.api.nvim_set_current_win(view.diff_win) end
  return buf
end

-- ]c / [c: the next/previous block of changed lines, crossing into the
-- next/previous file once this one runs out (as in the reviewer).
jump = function(dir)
  local cur = view and view.maps and view.maps[vim.api.nvim_get_current_buf()]
  if not cur then return end
  local function land(map, i)
    if dir < 0 then while i > 1 and is_change(map, i - 1) do i = i - 1 end end
    vim.api.nvim_win_set_cursor(0, { i, 0 })
    vim.cmd("normal! zvzz")
  end
  local map, n = cur.map, #cur.map
  local i = vim.api.nvim_win_get_cursor(0)[1]
  while i >= 1 and i <= n and is_change(map, i) do i = i + dir end
  while i >= 1 and i <= n and not is_change(map, i) do i = i + dir end
  if i >= 1 and i <= n then return land(map, i) end
  local idx = cur.idx + dir
  while view.files[idx] do
    local buf = diff_buf(idx)
    local m = view.maps[buf].map
    local first, last
    for ln = 1, #m do
      if is_change(m, ln) then first = first or ln; last = ln end
    end
    if first then
      show(idx, true)
      return land(m, dir > 0 and first or last)
    end
    idx = idx + dir
  end
  notify(dir > 0 and "No further changes." or "No previous changes.")
end

local function list_lines()
  local lines = {}
  for _, f in ipairs(view.files) do lines[#lines + 1] = " " .. f.status .. "  " .. f.path end
  if #lines == 0 then lines = { " (no changes yet)" } end
  return lines
end

local function setup_list(buf)
  local K = KEYS()
  local function under() return vim.api.nvim_win_get_cursor(0)[1] end
  K.bind(buf, "list", "open", function() show(under(), true) end, { desc = "show the file's change" })
  K.bind(buf, "list", "resize_less", function() resize(-5) end, { desc = "shrink the file list" })
  K.bind(buf, "list", "resize_more", function() resize(5) end, { desc = "grow the file list" })
  K.bind(buf, "list", "quit", close, { desc = "close" })
  K.bind(buf, "list", "help", function() help("list", LIST_HELP) end, { desc = "keys" })
  -- Moving through the list previews each file's change.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local i = under()
      if view and i ~= view.current and view.files[i] then show(i, false) end
    end,
  })
end

function M.open(title, dir, raw)
  for group, link in pairs({ AzureCliDiffAddBg = "DiffAdd", AzureCliDiffDelBg = "DiffDelete",
    AzureCliDiffAddSign = "DiffAdd", AzureCliDiffDelSign = "DiffDelete",
    AzureCliDiffAddWord = "DiffText", AzureCliDiffDelWord = "DiffText" }) do
    pcall(vim.api.nvim_set_hl, 0, group, { default = true, link = link })
  end
  local CACHE = require("azure-cli.cache")
  local width = view and view.width or 40
  if view then
    for _, b in pairs(view.bufs or {}) do
      if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
  end
  local reuse = view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab) and valid_win(view.list_win)
    and valid_win(view.diff_win)
  local old = reuse and view or nil
  view = { files = M.files(raw), diffs = CACHE.split_diff(raw), bufs = {}, maps = {}, title = title, dir = dir,
    width = width }
  if old then
    view.tab, view.list_win, view.diff_win, view.list_buf = old.tab, old.list_win, old.diff_win, old.list_buf
    vim.api.nvim_set_current_tabpage(view.tab)
  else
    vim.cmd("tabnew")
    view.tab = vim.api.nvim_get_current_tabpage()
    view.list_win = vim.api.nvim_get_current_win()
    view.list_buf = vim.api.nvim_get_current_buf()
    vim.bo[view.list_buf].buftype = "nofile"
    vim.bo[view.list_buf].bufhidden = "wipe"
    vim.bo[view.list_buf].filetype = "azurecli-changes"
    pcall(vim.api.nvim_buf_set_name, view.list_buf, "azure-cli://changes")
    setup_list(view.list_buf)
    vim.cmd("belowright vsplit")
    view.diff_win = vim.api.nvim_get_current_win()
    UI().plain_window(view.list_win, { cursorline = true })
    pcall(vim.api.nvim_win_set_width, view.list_win, width)
  end
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, list_lines())
  vim.bo[view.list_buf].modifiable = false
  pcall(UI().wo, view.list_win, "winbar", "%#Title# " .. title:gsub("%%", "%%%%") .. "%* %#Comment#"
    .. #view.files .. " file" .. (#view.files == 1 and "" or "s"))
  if #view.files > 0 then
    show(1, false)
    vim.api.nvim_set_current_win(view.diff_win)
    local m = view.maps[vim.api.nvim_win_get_buf(view.diff_win)].map
    for ln = 1, #m do
      if is_change(m, ln) then vim.api.nvim_win_set_cursor(view.diff_win, { ln, 0 }) vim.cmd("normal! zvzz") break end
    end
  end
  -- The diff pane gets the focus - again after the chat panel has followed
  -- into this tab (it opens on a scheduled callback and moves the cursor).
  local function focus()
    local w = #view.files > 0 and view.diff_win or view.list_win
    if valid_win(w) then vim.api.nvim_set_current_win(w) end
  end
  focus()
  vim.schedule(function() vim.schedule(focus) end)
  return view.tab
end

return M
