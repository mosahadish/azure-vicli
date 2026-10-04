-- lua/azure-cli/chat/view.lua: "what the user is looking at", for the chat.
--
-- Every screen registers a describer in STATE.chat_views - the PR dashboard
-- and the two work-item screens under their filetype, the reviewer under
-- "review:<pr id>" (review/chat.lua). A describer takes the window the user
-- was last in (not the chat panel) and returns a plain table: the screen,
-- the PR / work item / file / line / thread under the cursor, a visual
-- selection. M.snapshot picks the right one; M.text turns it into the few
-- lines sent with each chat message, and the current_view tool returns the
-- table itself.
local M = {}

local function views()
  local STATE = require("azure-cli.state")
  STATE.chat_views = STATE.chat_views or {}
  return STATE.chat_views
end

-- Registers describer `fn(win) -> table|nil` under `key`.
function M.register(key, fn)
  views()[key] = fn
end

-- The PR the reviewer in `win`'s tab is showing, or nil: its file-list
-- buffer carries vim.b.azure_cli_pr.
local function reviewer_pr(win)
  local ok, tab = pcall(vim.api.nvim_win_get_tabpage, win)
  if not ok then return nil end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == "azurecli-files" then
      local id = vim.b[b].azure_cli_pr
      if id then return tostring(id) end
    end
  end
  return nil
end

-- The snapshot for `win` (default: the current window). `sel` ({ buf,
-- from, to, text }, from gq in visual mode) is handed to the describer,
-- which can say where it is (the reviewer maps it to file lines); the text
-- is added when the describer didn't.
function M.snapshot(win, sel)
  win = win or vim.api.nvim_get_current_win()
  if not (win and vim.api.nvim_win_is_valid(win)) then return { screen = "unknown" } end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  local fn = views()[ft]
  local key = ft
  if not fn then
    local pr = reviewer_pr(win)
    if pr then
      key = "review:" .. pr
      fn = views()[key]
    end
  end
  if not fn then return { screen = "other", filetype = ft, selection = sel and sel.text or nil } end
  local ok, snap = pcall(fn, win, sel)
  if not ok or type(snap) ~= "table" then snap = { screen = key, error = ok and "nothing to describe" or tostring(snap) } end
  if sel and snap.selection == nil then snap.selection = sel.text end
  return snap
end

local function pr_line(pr)
  if type(pr) ~= "table" then return nil end
  local s = "PR #" .. tostring(pr.id) .. (pr.title and (" \"" .. pr.title .. "\"") or "")
  if pr.repo then s = s .. " in " .. pr.repo end
  if pr.source and pr.target then s = s .. " (" .. pr.source .. " -> " .. pr.target .. ")" end
  return s
end

local function wi_line(wi)
  if type(wi) ~= "table" then return nil end
  return "work item #" .. tostring(wi.id) .. (wi.type and (" " .. wi.type) or "")
    .. (wi.title and (" \"" .. wi.title .. "\"") or "") .. (wi.state and (" [" .. wi.state .. "]") or "")
end

-- A few lines describing `snap` for the agent. Pure.
function M.text(snap)
  snap = snap or {}
  local out = { "Screen: " .. tostring(snap.screen or "?") }
  local p = pr_line(snap.pr)
  if p then out[#out + 1] = "Pull request: " .. p end
  local w = wi_line(snap.work_item)
  if w then out[#out + 1] = "Work item: " .. w end
  if snap.file then
    out[#out + 1] = "File: " .. snap.file .. (snap.line and (" line " .. snap.line .. " (" .. (snap.side == "L" and "target" or "source") .. " side)") or "")
  end
  if snap.code_line then out[#out + 1] = "Code on that line: " .. snap.code_line end
  if type(snap.thread) == "table" then
    local t = snap.thread
    local first = t.comments and t.comments[1]
    out[#out + 1] = "Comment thread #" .. tostring(t.id) .. " [" .. tostring(t.status or "?") .. "]"
      .. (first and (" started by " .. tostring(first.author) .. ": " .. tostring(first.content):gsub("%s+", " "):sub(1, 200)) or "")
  end
  if snap.selection then
    out[#out + 1] = "Selected" .. (snap.selection_lines and (" (lines " .. snap.selection_lines .. ")") or "") .. ":\n"
      .. snap.selection
  elseif snap.hunk then
    out[#out + 1] = "The change around the cursor:\n" .. snap.hunk
  end
  if snap.note then out[#out + 1] = snap.note end
  return table.concat(out, "\n")
end

return M
