-- lua/azure-cli/review/chat.lua: the chat panel in the reviewer - a
-- reviewer-feature module (see docs/development.md, "Extending the
-- reviewer").
--
--   gq           goes to the chat panel (lua/azure-cli/chat/) from the file
--                list, the diff pane, the Overview and the revision buffers;
--                on a visual selection it sends the selected lines along
--   describer    what the chat is told the reviewer shows (chat/view.lua):
--                the PR, and the file, line, code, change and comment thread
--                under the cursor - or the selection, mapped to file lines
--   opener       STATE.review_openers[id](path, side, line): the chat's
--                open_in_ui tool showing this PR at a file and line
--   notes        the agent's annotate_code notes (STATE.chat_notes[id]),
--                drawn as virtual lines under their lines in the diff;
--                review/init.lua's decorate_comments calls M.decorate
--   ]a / [a      the next / previous of those notes, on into the next file
--                (in the file list's order) that has any
local M = {}

-- A thread (review/init.lua's parse_threads shape) as the chat sees it.
function M.thread(t)
  local comments = {}
  for _, c in ipairs(t.comments or {}) do
    comments[#comments + 1] = { author = c.author, content = c.content }
  end
  return { id = t.id, status = t.status, file = t.path, side = t.side, line = t.lineno, comments = comments }
end

-- The changed lines around buffer line `lnum` of a diff (one hunk: the run
-- of added/removed lines it's in), as "+"/"-" lines, or nil on an
-- unchanged line. `map` is the buffer's line map, `lines` its text. Pure.
function M.hunk(map, lines, lnum, max)
  local function changed(i) local m = map[i]; return m and (m.kind == "add" or m.kind == "del") end
  if not changed(lnum) then return nil end
  local a, b = lnum, lnum
  while a > 1 and changed(a - 1) do a = a - 1 end
  while b < #lines and changed(b + 1) do b = b + 1 end
  local out = {}
  for i = a, math.min(b, a + (max or 60) - 1) do
    out[#out + 1] = (map[i].kind == "add" and "+" or "-") .. (lines[i] or "")
  end
  return table.concat(out, "\n")
end

-- The file lines a selection of buffer lines `from`..`to` covers on one
-- side: "12-18" (source side preferred), or nil. Pure.
function M.selection_lines(map, from, to)
  local lo, hi, side = nil, nil, nil
  for _, want in ipairs({ "R", "L" }) do
    for i = from, to do
      local m = map[i]
      if m and m.side == want and m.lineno then
        lo = lo and math.min(lo, m.lineno) or m.lineno
        hi = hi and math.max(hi, m.lineno) or m.lineno
        side = want
      end
    end
    if lo then break end
  end
  if not lo then return nil end
  return (lo == hi and tostring(lo) or (lo .. "-" .. hi)), side
end

-- The rows of a diff buffer (line map `map`, for file `path`) that the
-- agent's notes are under, in order, each once. Pure.
function M.note_rows(notes, path, map)
  local want, rows = {}, {}
  for _, n in ipairs(notes or {}) do
    if n.file == path then want[(n.side or "R") .. "\t" .. n.line] = true end
  end
  for i, m in ipairs(map or {}) do
    if m.side and m.lineno and want[m.side .. "\t" .. m.lineno] then rows[#rows + 1] = i end
  end
  return rows
end

-- The first of `rows` past `cur` going `dir` (1 / -1), or nil. Pure.
function M.next_row(rows, cur, dir)
  for k = dir > 0 and 1 or #rows, dir > 0 and #rows or 1, dir do
    if (rows[k] - cur) * dir > 0 then return rows[k] end
  end
end

-- The index into `ordered` (the file list's files) of the next file going
-- `dir` from `cur` (nil: from before the first / after the last) that has
-- any of `notes`, or nil. Pure.
function M.next_note_file(notes, ordered, cur, dir)
  local has = {}
  for _, n in ipairs(notes or {}) do has[n.file] = true end
  local i = (cur or (dir > 0 and 0 or #ordered + 1)) + dir
  while i >= 1 and i <= #ordered do
    if has[ordered[i]] then return i end
    i = i + dir
  end
end

local NOTE_HL = { info = "DiagnosticInfo", warning = "DiagnosticWarn", issue = "DiagnosticError" }

local function setup(ctx)
  local STATE = require("azure-cli.state")
  local ID = tostring(ctx.ID)
  local notes_ns = vim.api.nvim_create_namespace("azure_cli_chat_notes")
  for _, kind in ipairs({ "list", "diff", "overview", "nav" }) do
    ctx.add_key(kind, "chat", function() require("azure-cli.chat").toggle() end, "go to the chat panel")
    ctx.add_key(kind, "chat", function() require("azure-cli.chat").capture_selection() end,
      "ask the chat about the selected lines", "x")
    -- gP: an agent plans the fix of this PR's review comments - on a
    -- thread, that one; elsewhere every active one (chat/agents.lua).
    if kind ~= "nav" then
      ctx.add_key(kind, "plan_agents", function() require("azure-cli.chat").plan_agents_here(0) end,
        "an agent plans the fix of this PR's comments (on a thread: that one)")
    end
  end

  -- ]a / [a: the agent's next / previous note - in this file's diff,
  -- else the first (last) one in the next (previous) file that has any.
  local function jump_note(dir)
    local notes = (STATE.chat_notes or {})[ID] or {}
    if #notes == 0 then return ctx.notify("The agent left no notes on this PR.") end
    local buf = vim.api.nvim_get_current_buf()
    local path = ctx.paths_by_buf[buf]
    if path then
      local row = M.next_row(M.note_rows(notes, path, ctx.maps_by_buf[buf]), vim.api.nvim_win_get_cursor(0)[1], dir)
      if row then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
    local model = ctx.ext.filelist
    local ordered = model and model.ordered_files or {}
    local cur
    for i, f in ipairs(ordered) do if f == path then cur = i end end
    local idx = M.next_note_file(notes, ordered, cur, dir)
    if not idx then return ctx.notify(dir > 0 and "No further notes from the agent." or "No previous notes from the agent.") end
    local opened = ctx.ext.open_file_at(idx)
    if not opened then return end
    ctx.ensure_diff_content(opened, function()
      vim.schedule(function()
        local dw = ctx.diff_win()
        if not (dw and vim.api.nvim_win_is_valid(dw)) then return end
        local b = vim.api.nvim_win_get_buf(dw)
        if ctx.paths_by_buf[b] ~= opened then return end  -- moved on meanwhile
        local rows = M.note_rows(notes, opened, ctx.maps_by_buf[b])
        local row = dir > 0 and rows[1] or rows[#rows]
        if not row then return ctx.notify("The agent's note in " .. opened .. " is on a line the diff doesn't show.") end
        vim.api.nvim_set_current_win(dw)
        pcall(vim.api.nvim_win_set_cursor, dw, { row, 0 })
        vim.api.nvim_win_call(dw, function() vim.cmd("normal! zz") end)
      end)
    end)
  end
  ctx.add_key("diff", "next_note", function() jump_note(1) end,
    "the agent's next note (on into the next file with notes)")
  ctx.add_key("diff", "prev_note", function() jump_note(-1) end, "the agent's previous note")

  require("azure-cli.chat.view").register("review:" .. ID, function(win, sel)
    local buf = vim.api.nvim_win_get_buf(win)
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local pr = { id = tonumber(ID) or ID, source = ctx.SOURCE, target = ctx.TARGET }
    local rec = ctx.current_pr_record()
    if rec and tostring(rec.id) == ID then pr.title, pr.repo, pr.author = rec.title, rec.repo, rec.author end
    local snap = { screen = "reviewer", pr = pr }
    local path = ctx.paths_by_buf[buf]
    if path then
      snap.screen = "reviewer: a file's diff"
      snap.file = path
      local map = ctx.maps_by_buf[buf] or {}
      local m = map[lnum]
      if m and m.lineno then snap.side, snap.line = m.side, m.lineno end
      snap.code_line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
      snap.hunk = M.hunk(map, vim.api.nvim_buf_get_lines(buf, 0, -1, false), lnum)
      if sel and sel.buf == buf then
        local range, side = M.selection_lines(map, sel.from, sel.to)
        snap.selection_lines, snap.side = range, side or snap.side
      end
    elseif buf == ctx.overview_buf() then
      snap.screen = "reviewer: Overview (description, commits, PR-level comments)"
    elseif vim.bo[buf].filetype == "azurecli-files" then
      snap.screen = "reviewer: file list"
      local f = ctx.ext.filelist and ctx.ext.filelist.row_to_file[lnum - 1]
      if f then snap.file = f end
    end
    local threads = (ctx.comments_by_buf[buf] or {})[lnum]
    if threads and threads[1] and type(threads[1].id) == "number" then
      snap.thread = M.thread(threads[1])
      if #threads > 1 then snap.note = #threads .. " threads are on this line; get_pr_threads lists them all." end
    end
    return snap
  end)

  -- The chat's open_in_ui: this reviewer's tab, then the file at the line
  -- (or the Overview without a path). False once the reviewer is gone.
  local function reviewer_tab()
    local lw = ctx.list_win()
    if not (lw and vim.api.nvim_win_is_valid(lw)) then return nil end
    return vim.api.nvim_win_get_tabpage(lw)
  end
  STATE.review_openers = STATE.review_openers or {}
  STATE.review_openers[ID] = function(path, side, line)
    local tab = reviewer_tab()
    if not tab then return false end
    vim.api.nvim_set_current_tabpage(tab)
    if not path then
      if ctx.open_overview then ctx.open_overview(true) end
      return true
    end
    ctx.open_file(path, true)
    if line then
      ctx.ensure_diff_content(path, function()
        vim.schedule(function()
          local dw = ctx.diff_win()
          if not (dw and vim.api.nvim_win_is_valid(dw)) then return end
          local b = vim.api.nvim_win_get_buf(dw)
          for i, m in ipairs(ctx.maps_by_buf[b] or {}) do
            if m.side == (side or "R") and m.lineno == line then
              pcall(vim.api.nvim_win_set_cursor, dw, { i, 0 })
              vim.api.nvim_win_call(dw, function() vim.cmd("normal! zz") end)
              return
            end
          end
        end)
      end)
    end
    return true
  end

  -- The agent's notes on this PR's lines.
  function M.decorate(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, notes_ns, 0, -1)
    local path = ctx.paths_by_buf[buf]
    local notes = (STATE.chat_notes or {})[ID]
    if not (path and notes and #notes > 0) then return end
    local by_loc = {}
    for _, n in ipairs(notes) do
      if n.file == path then
        local k = (n.side or "R") .. "\t" .. n.line
        by_loc[k] = by_loc[k] or {}
        table.insert(by_loc[k], n)
      end
    end
    for bl, m in ipairs(ctx.maps_by_buf[buf] or {}) do
      local list = m.side and m.lineno and by_loc[m.side .. "\t" .. m.lineno]
      if list then
        local virt = {}
        for _, n in ipairs(list) do
          for i, l in ipairs(vim.split(n.text, "\n", { plain = true })) do
            virt[#virt + 1] = { { (i == 1 and "    \u{2726} " or "      ") .. l, NOTE_HL[n.kind] or "DiagnosticInfo" } }
          end
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, notes_ns, bl - 1, 0, { virt_lines = virt })
      end
    end
  end
  STATE.review_redecorate = STATE.review_redecorate or {}
  STATE.review_redecorate[ID] = function()
    for b in pairs(ctx.paths_by_buf) do M.decorate(b) end
  end
  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
