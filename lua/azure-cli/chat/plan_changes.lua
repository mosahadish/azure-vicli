-- lua/azure-cli/chat/plan_changes.lua: the plan view's Changes section -
-- the agent's diff, next to the plan it carries out. When the plan's fix /
-- story worktree has a change, the section list gets "Changes (N files)"
-- with each file under it (+/- counts, A / D for new / deleted, the files
-- the plan doesn't list marked as the plan check marks them); selecting one
-- shows its diff in the plan pane, built from the change viewer's parts
-- (cache.lua's split_diff / parse_diff, diffbuf.lua, review/pane.lua). On
-- a diff line ga asks the agent about it and gc queues a change to the
-- code - both kept with the change viewer's questions (changes.why_load),
-- so gd shows them too - and gR sends the queued ones, as gS does in gd.
-- After a push it shows the pushed commit's diff; hidden while nothing
-- changed.
--
-- Keyed by plan key, apart from plan_view.lua's revisions and tab code. Its
-- interface to plan_view.lua (`v` is a plan view: { key, rec, plan_win,
-- plan_buf, list_win }):
--   M.hooks                   set by plan_view: bind(v, buf) binds the
--                             plan's own keys on a diff buffer, send(v,
--                             text, display) sends to the plan's agent,
--                             back(v) puts the plan text back
--   M.load(key, rec, on_change)  reads the worktree's diff (async), then
--                             on_change(key) when the files or the diff
--                             changed
--   M.state(key)              { dir, files, check, pushed } or nil
--   M.list_rows(key, width)   the section list's rows: lines, hls ({ row0,
--                             col, end_col, group }), rows (i -> { changes
--                             = true } / { file = path }); none while
--                             nothing changed
--   M.show(v, path, focus)    file `path`'s diff in the plan pane; false
--                             when the change has no such file
--   M.back(v)                 the plan text back in the plan pane: true
--                             when it wasn't there
--   M.showing(v)              the path whose diff the plan pane shows, or nil
--   M.winbar(v)               the plan pane's winbar while it shows a diff
--   M.describe(v, win)        the chat's file / line on a diff line, or nil
--   M.poke()                  reload every open plan's change, debounced
--                             (an agent's edit, a push)
--   M.forget(key, v)          the plan's tab went: its diff buffers go
--   pure: M.summarize(raw), M.pushed_sha(rec), M.title(st)
local M = {}

local DIFFBUF = require("azure-cli.diffbuf")
local function UI() return require("azure-cli.ui") end
local function KEYS() return require("azure-cli.keys") end
local function THREADS() return require("azure-cli.chat.threads") end
local function CHANGES() return require("azure-cli.chat.changes") end
local function PLAN() return require("azure-cli.chat.plan") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end
local function valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end

M.hooks = {}

-- plan key -> { dir, files, diffs, check, pushed, sig, seq, threads, bufs
-- (path -> diff buffer), maps (buf -> { path, map }), stale (buffers of an
-- earlier diff), on_change }
local states = {}

-- The changed files of `raw` (`git diff` output, a string or its lines) in
-- diff order, with their diffs: files = { { path, status, add, del } },
-- diffs = path -> its lines. Pure.
function M.summarize(raw)
  local lines = type(raw) == "table" and raw or vim.split(raw or "", "\n", { plain = true })
  local files = CHANGES().files(lines)
  local diffs = require("azure-cli.cache").split_diff(lines)
  for _, f in ipairs(files) do
    local add, del, body = 0, 0, false
    for _, l in ipairs(diffs[f.path] or {}) do
      if l:match("^@@") then body = true
      elseif body and l:sub(1, 1) == "+" then add = add + 1
      elseif body and l:sub(1, 1) == "-" then del = del + 1 end
    end
    f.add, f.del = add, del
  end
  return files, diffs
end

-- The commit the agent pushed for plan `rec` (its latest "pushed" event),
-- while the plan is done - else nil. Pure.
function M.pushed_sha(rec)
  if not (rec and rec.status == "done") then return nil end
  local events = rec.events or {}
  for i = #events, 1, -1 do
    local sha = events[i].kind == "pushed" and (events[i].text or ""):match("^Pushed (%x+)")
    if sha then return sha end
  end
  return nil
end

-- "Changes (2 files)" / "Changes (1 file, pushed abc1234)". Pure.
function M.title(st)
  local n = #st.files
  return "Changes (" .. n .. " file" .. (n == 1 and "" or "s") .. (st.pushed and (", pushed " .. st.pushed) or "") .. ")"
end

function M.state(key)
  local st = states[key]
  return (st and st.files and #st.files > 0) and st or nil
end

local function find(st, path)
  for i, f in ipairs(st and st.files or {}) do if f.path == path then return f, i end end
  return nil
end

local function unplanned(st, path)
  for _, p in ipairs(st.check and st.check.unplanned or {}) do if p == path then return true end end
  return false
end

function M.load(key, rec, on_change)
  local st = states[key] or { files = {}, diffs = {}, bufs = {}, maps = {}, stale = {}, seq = 0 }
  states[key] = st
  st.on_change = on_change
  st.seq = st.seq + 1
  local seq = st.seq
  local TF = require("azure-cli.chat.tools_fix")
  local dir = rec and rec.target and TF.dir_for(rec.target)
  local function done(raw, pushed)
    if st.seq ~= seq then return end  -- a later load is on its way
    local sig = (dir or "") .. "\0" .. (pushed or "") .. "\0" .. raw
    if sig == st.sig then return end
    st.sig, st.dir, st.pushed = sig, dir, pushed
    st.files, st.diffs = M.summarize(raw)
    if raw == "" then st.files, st.diffs = {}, {} end
    local paths = {}
    for _, f in ipairs(st.files) do paths[#paths + 1] = f.path end
    st.check = PLAN().check_change(rec, paths)
    st.threads = dir and CHANGES().why_load(dir) or {}
    -- The earlier diff's buffers go once nothing shows them (M.show).
    for _, b in pairs(st.bufs) do st.stale[#st.stale + 1] = b end
    st.bufs = {}
    on_change(key)
  end
  if not dir then return done("", nil) end
  local git = require("azure-cli.chat.tools").git
  -- The uncommitted change (new files included); once it's pushed, the
  -- pushed commit's - never the branch's own last commit before the agent
  -- changed anything.
  TF.diff(dir, function(ok, diff)
    if ok and vim.trim(diff or "") ~= "" then return done(diff, nil) end
    local sha = M.pushed_sha(rec)
    if not sha then return done("", nil) end
    git({ "git", "-C", dir, "diff", sha .. "~1", sha }, function(cok, out)
      done(cok and out or "", cok and sha or nil)
    end)
  end, git)
end

local timer
function M.poke()
  timer = timer or (vim.uv or vim.loop).new_timer()
  timer:stop()
  timer:start(300, 0, vim.schedule_wrap(function()
    for key, st in pairs(states) do
      if st.on_change then M.load(key, PLAN().load(key), st.on_change) end
    end
  end))
end

-- How many changes are queued on lines of the code (gc in a diff).
local function queued(st)
  local _, r = THREADS().counts(st and st.threads or {})
  return r
end

function M.list_rows(key, width)
  local st = M.state(key)
  local lines, hls, rows = {}, {}, {}
  if not st then return lines, hls, rows end
  local dw = vim.fn.strdisplaywidth
  local off = st.check and #st.check.unplanned or 0
  local badge = off > 0 and ("\u{2717}" .. off) or ""
  local head = UI().fit(M.title(st), math.max(8, width - 4 - dw(badge)))
  lines[#lines + 1] = "   " .. head .. badge
  if badge ~= "" then hls[#hls + 1] = { #lines - 1, #lines[#lines] - #badge, #lines[#lines], "AzureCliStatusBad" } end
  rows[#lines] = { changes = true }
  for _, f in ipairs(st.files) do
    local tail = "  +" .. f.add .. " \u{2212}" .. f.del
    local mark = unplanned(st, f.path) and "  \u{2717} not in the plan" or ""
    local name = UI().fit(f.status .. " " .. f.path, math.max(8, width - 6 - dw(tail) - dw(mark)))
    local l = "     " .. name
    local s_hl = f.status == "A" and "AzureCliStatusOk" or f.status == "D" and "AzureCliStatusBad" or nil
    if s_hl then hls[#hls + 1] = { #lines, 5, 6, s_hl } end
    hls[#hls + 1] = { #lines, #l, #l + #tail, "AzureCliMuted" }
    if mark ~= "" then hls[#hls + 1] = { #lines, #l + #tail, #l + #tail + #mark, "AzureCliStatusBad" } end
    lines[#lines + 1] = l .. tail .. mark
    rows[#lines] = { file = f.path }
  end
  local n = queued(st)
  if n > 0 then
    lines[#lines + 1] = "     " .. KEYS().name("plan", "revise") .. " in a diff sends " .. n .. " code change"
      .. (n == 1 and "" or "s")
    hls[#hls + 1] = { #lines - 1, 0, #lines[#lines], "AzureCliAccent" }
  end
  return lines, hls, rows
end

function M.showing(v)
  local st = v and states[v.key]
  if not (st and valid_win(v.plan_win)) then return nil end
  local m = st.maps[vim.api.nvim_win_get_buf(v.plan_win)]
  return m and m.path or nil
end

function M.winbar(v)
  local st = states[v.key]
  local path = M.showing(v)
  if not path then return end
  local m = st.maps[vim.api.nvim_win_get_buf(v.plan_win)]
  local tags = {}
  if unplanned(st, path) then tags[#tags + 1] = "[\u{2717} not in the plan]" end
  if st.pushed then tags[#tags + 1] = "[pushed " .. st.pushed .. "]" end
  local mine = {}
  for _, th in ipairs(st.threads or {}) do if th.file == path then mine[#mine + 1] = th end end
  local nq = THREADS().counts(mine)
  if nq > 0 then tags[#tags + 1] = "[" .. THREADS().count_label(nq) .. "]" end
  local n = queued(st)
  if n > 0 then
    tags[#tags + 1] = "[\u{270E}" .. n .. " queued - " .. KEYS().name("plan", "revise") .. " sends " .. n
      .. " code change" .. (n == 1 and "" or "s") .. "]"
  end
  pcall(UI().wo, v.plan_win, "winbar", UI().winbar({ path .. DIFFBUF.stats(m.map) }, tags))
end

-- The threads of file `path` under buffer row `row` of its diff.
local function threads_at(st, path, map, row)
  local out = {}
  for _, th in ipairs(st.threads or {}) do
    if th.file == path and CHANGES().row_of(map, th) == row then out[#out + 1] = th end
  end
  return out
end

local function draw_threads(v, buf)
  local st = states[v.key]
  local m = st and st.maps[buf]
  if not m then return end
  THREADS().draw(buf, v.plan_win, st.threads, function(th)
    return th.file == m.path and CHANGES().row_of(m.map, th) or nil
  end, { send = KEYS().name("plan", "revise"), drop = KEYS().first("plan", "delete_thread"),
    edit = KEYS().first("plan", "edit_request") })
end

local function saved(v, buf)
  local st = states[v.key]
  if st.dir then CHANGES().why_save(st.dir, st.threads) end
  if valid_buf(buf) then draw_threads(v, buf) end
  if M.showing(v) then M.winbar(v) end
  if M.hooks.redraw then M.hooks.redraw(v) end
end

local function what(v, st)
  return "your change for " .. PLAN().target_label(v.rec.target) .. " (worktree " .. tostring(st.dir) .. ")"
end

-- gR in a diff: every change queued on lines of the code, in one message
-- to the plan's agent (changes.fix_message, as gS sends them in gd).
local function send_code_changes(v)
  local st = states[v.key]
  local list = {}
  for _, th in ipairs(st.threads or {}) do
    if th.kind == "request" and th.status ~= "sent" then list[#list + 1] = th end
  end
  if #list == 0 then
    return notify("No code changes queued - " .. KEYS().name("plan", "request") .. " on a diff line queues one.")
  end
  require("azure-cli.editor").open({
    title = "Send " .. #list .. " code change" .. (#list == 1 and "" or "s") .. " to the agent",
    initial = "Please make these changes.", anchor = "center",
    on_submit = function(note)
      local sent = M.hooks.send and M.hooks.send(v, CHANGES().fix_message(what(v, st), note, list),
        note .. " (+" .. #list .. " on lines of the change)")
      if not sent then return end
      for _, th in ipairs(list) do th.status = "sent" end
      saved(v, vim.api.nvim_win_is_valid(v.plan_win) and vim.api.nvim_win_get_buf(v.plan_win) or nil)
    end,
  })
end

local function bind_diff(v, buf, path, map)
  local function bind(surface, action, fn, opts) KEYS().bind(buf, surface, action, fn, opts) end
  local function row() return vim.api.nvim_win_get_cursor(0)[1] end
  local function st() return states[v.key] end
  bind("diff", "next_hunk", function()
    local i = DIFFBUF.next_change(map, row(), 1)
    if i then vim.api.nvim_win_set_cursor(0, { i, 0 }) vim.cmd("normal! zz") else notify("No further changes in this file.") end
  end, { desc = "next change" })
  bind("diff", "prev_hunk", function()
    local i = DIFFBUF.next_change(map, row(), -1)
    if i then vim.api.nvim_win_set_cursor(0, { i, 0 }) vim.cmd("normal! zz") else notify("No previous changes in this file.") end
  end, { desc = "previous change" })
  bind("plan", "ask", function()
    local r = row()
    local m = map[r] or {}
    if not m.lineno then return notify("Put the cursor on a line of the change.") end
    local text = vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1] or ""
    THREADS().ask({
      win = vim.api.nvim_get_current_win(), row = r, line = m.lineno, anchor = vim.trim(text), file = path, side = m.side,
      ctx = { what = what(v, st()), where = path .. " line " .. m.lineno .. (m.side == "L" and " (a line you removed)" or "") },
      label = vim.fn.fnamemodify(path, ":t") .. ":" .. m.lineno,
      threads = st().threads,
      changed = function() saved(v, buf) end,
    })
  end, { desc = "ask the agent about this line of the change" })
  local function request(from, to)
    local m = map[to] or {}
    if not m.lineno then return notify("Put the cursor on a line of the change.") end
    local lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
    require("azure-cli.editor").open({
      title = "Code change \u{00B7} " .. vim.fn.fnamemodify(path, ":t") .. ":" .. m.lineno .. " (queued for "
        .. KEYS().name("plan", "revise") .. ")",
      initial = "", anchor = { win = vim.api.nvim_get_current_win(), row = to }, context_lines = lines,
      on_submit = function(text)
        table.insert(st().threads, { id = tostring(os.time()) .. "-" .. math.random(1000, 9999), kind = "request",
          file = path, line = m.lineno, side = m.side, anchor = vim.trim(lines[#lines] or ""), question = text,
          status = "queued", at = os.time() })
        saved(v, buf)
        local n = queued(st())
        notify(n .. " code change" .. (n == 1 and "" or "s") .. " queued - " .. KEYS().name("plan", "revise")
          .. " here sends " .. (n == 1 and "it" or "them") .. ".")
      end,
    })
  end
  bind("plan", "request", function() request(row(), row()) end, { desc = "queue a change on this line of the code" })
  bind("plan", "request", function()
    local a, b = vim.fn.getpos("v")[2], row()
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    request(a, b)
  end, { desc = "queue a change on these lines of the code", mode = "x" })
  -- dd / cc: a queued change first, then a question; a sent change stays.
  local function pick()
    local here = threads_at(st(), path, map, row())
    for _, th in ipairs(here) do if th.kind == "request" and th.status ~= "sent" then return th, "queued" end end
    for _, th in ipairs(here) do if th.kind ~= "request" then return th, "thread" end end
    if here[1] then return here[1], "sent" end
    return nil
  end
  local function remove(th)
    for i, t in ipairs(st().threads) do if t == th then table.remove(st().threads, i) break end end
    saved(v, buf)
  end
  bind("plan", "delete_thread", function()
    local th, kind = pick()
    if not th then return notify("Nothing under this line.") end
    if kind == "sent" then return notify("That change was sent to the agent already - it stays as history.") end
    if kind == "thread" then return remove(th) end
    require("azure-cli.prompt").confirm({ title = "Drop this queued change?", prompt = "It won't be sent to the agent.",
      details = th.question }, function(yes)
      if valid_win(v.plan_win) then pcall(vim.api.nvim_set_current_win, v.plan_win) end
      if yes then remove(th) end
    end)
  end, { desc = "drop the queued change (asks first) / forget the question here" })
  bind("plan", "edit_request", function()
    local th, kind = pick()
    if kind == "sent" then return notify("That change was sent to the agent already - it stays as history.") end
    if kind ~= "queued" then return notify("No queued change on this line.") end
    require("azure-cli.editor").open({
      title = "Code change \u{00B7} " .. vim.fn.fnamemodify(path, ":t") .. ":" .. tostring(th.line),
      initial = th.question or "", anchor = { win = vim.api.nvim_get_current_win(), row = row() },
      on_submit = function(text)
        th.question, th.at = text, os.time()
        saved(v, buf)
      end,
    })
  end, { desc = "edit the queued change under this line" })
  bind("plan", "expand_thread", function()
    local th = threads_at(st(), path, map, row())[1]
    if not th then return notify("No question on this line.") end
    THREADS().toggle(th)
    draw_threads(v, buf)
  end, { desc = "show all of the answer / fold it" })
  bind("plan", "view_thread", function()
    THREADS().show(threads_at(st(), path, map, row())[1],
      { send = KEYS().name("plan", "revise"), ask = KEYS().name("plan", "ask") })
  end, { desc = "the question and answer" })
  local function jump(dir)
    local r, best = row(), nil
    for _, th in ipairs(st().threads or {}) do
      local tr = th.file == path and CHANGES().row_of(map, th)
      if tr and ((dir > 0 and tr > r and (not best or tr < best)) or (dir < 0 and tr < r and (not best or tr > best))) then
        best = tr
      end
    end
    if not best then return notify(dir > 0 and "No further questions in this file." or "No earlier questions in this file.") end
    vim.api.nvim_win_set_cursor(0, { best, 0 })
  end
  bind("plan", "next_thread", function() jump(1) end, { desc = "next question in this file" })
  bind("plan", "prev_thread", function() jump(-1) end, { desc = "previous question in this file" })
  bind("plan", "revise", function() send_code_changes(v) end, { desc = "send the queued code changes" })
end

-- File `path`'s diff buffer (built once per diff).
local function diff_buf(v, st, path)
  if valid_buf(st.bufs[path]) then return st.bufs[path] end
  local lines, map = require("azure-cli.cache").parse_diff(st.diffs[path] or {})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.b[buf].azure_cli_view = "azurecli-plan"
  vim.b[buf].azure_cli_title = path
  vim.b[buf].azure_cli_keys_local = true
  vim.bo[buf].filetype = DIFFBUF.ft_for_path(path) or "text"
  DIFFBUF.decorate(buf, lines, map)
  require("azure-cli.review.pane").register(buf, map)
  st.bufs[path] = buf
  st.maps[buf] = { path = path, map = map }
  -- The plan's own keys first (gA, gq, <BS>, q, ...), then the diff's.
  if M.hooks.bind then M.hooks.bind(v, buf) end
  bind_diff(v, buf, path, map)
  return buf
end

local function drop_stale(st)
  local keep = {}
  for _, b in ipairs(st.stale) do
    if valid_buf(b) and #vim.fn.win_findbuf(b) > 0 then
      keep[#keep + 1] = b
    elseif valid_buf(b) then
      st.maps[b] = nil
      pcall(require("azure-cli.review.pane").forget, b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    else
      st.maps[b] = nil
    end
  end
  st.stale = keep
end

function M.show(v, path, focus)
  local st = states[v.key]
  if not (st and find(st, path) and valid_win(v.plan_win)) then return false end
  DIFFBUF.setup_hl()
  local buf = diff_buf(v, st, path)
  -- The plan's text stays loaded while a diff is in its window (it's
  -- wiped once nothing shows it, otherwise); M.back / M.forget put that back.
  if valid_buf(v.plan_buf) then vim.bo[v.plan_buf].bufhidden = "hide" end
  local was = vim.api.nvim_win_get_buf(v.plan_win)
  if was ~= buf then
    -- The same file after a reload: the same row (or the nearest left).
    local same = st.maps[was] and st.maps[was].path == path and vim.api.nvim_win_get_cursor(v.plan_win)[1]
    vim.api.nvim_win_set_buf(v.plan_win, buf)
    UI().plain_window(v.plan_win, {})
    require("azure-cli.review.pane").apply(v.plan_win)
    local row = same and math.min(same, vim.api.nvim_buf_line_count(buf)) or DIFFBUF.edge_change(st.maps[buf].map, 1)
    if row then pcall(vim.api.nvim_win_set_cursor, v.plan_win, { row, 0 }) end
  end
  drop_stale(st)
  M.winbar(v)
  draw_threads(v, buf)
  vim.schedule(function() if valid_buf(buf) and M.showing(v) == path then draw_threads(v, buf) end end)
  if focus then vim.api.nvim_set_current_win(v.plan_win) end
  return true
end

function M.back(v)
  if not (v and valid_win(v.plan_win) and valid_buf(v.plan_buf)) then return false end
  if vim.api.nvim_win_get_buf(v.plan_win) == v.plan_buf then return false end
  vim.api.nvim_win_set_buf(v.plan_win, v.plan_buf)
  vim.bo[v.plan_buf].bufhidden = "wipe"
  local st = states[v.key]
  if st then drop_stale(st) end
  return true
end

function M.describe(v, win)
  local st = states[v.key]
  local buf = valid_win(win) and vim.api.nvim_win_get_buf(win)
  local m = st and buf and st.maps[buf]
  if not m then return nil end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local e = m.map[row] or {}
  return { file = m.path, line = e.lineno, side = e.side, worktree = st.dir,
    code_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] }
end

function M.forget(key, v)
  local st = states[key]
  states[key] = nil
  if not st then return end
  for _, b in pairs(st.bufs) do st.stale[#st.stale + 1] = b end
  for _, b in ipairs(st.stale) do
    if valid_buf(b) then
      pcall(require("azure-cli.review.pane").forget, b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  -- The plan's text, kept loaded while a diff was in its window.
  if v and valid_buf(v.plan_buf) and #vim.fn.win_findbuf(v.plan_buf) == 0 then
    pcall(vim.api.nvim_buf_delete, v.plan_buf, { force = true })
  end
end

return M
