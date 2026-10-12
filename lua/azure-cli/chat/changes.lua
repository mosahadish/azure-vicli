-- lua/azure-cli/chat/changes.lua: the agent's proposed change (show_fix),
-- shown the way the reviewer shows a PR: a tab with the changed files on the
-- left and one file's diff on the right, built from the same parts as the
-- reviewer's diff pane - diffbuf.lua (filetype, diff marks, ]c / [c, winbar
-- stats, preview-on-move delay), cache.lua's parse_diff/split_diff,
-- review/pane.lua's line numbers and folds - and bound through the same
-- keys.lua surfaces ("list" for the file list, "diff" for the diff pane), so
-- ]c / [c, <CR>, <BS>, gf, < / > and q work as they do there - remapped ones
-- included.
--
--   M.open(title, dir, raw, keep)  shows `raw` (`git diff` output of
--                             worktree `dir`), reusing the tab when it's
--                             still open; `keep` = { path, line, list } puts
--                             the cursor back where it was
--   M.refresh()               the same worktree again (r), staying on the
--                             file and line
--   M.jump_to(path, line)        file `path` at line `line` of its new version
--                             (the plan's gd)
--
-- gq goes to the chat, as on every other screen, and the chat describes
-- the file and line under the cursor here (M.describe). ga on a line asks
-- the agent about it ("why did you choose this here?"); the answer shows
-- under the line (chat/threads.lua) - <Tab> unfolds it, K shows it whole,
-- ]C / [C go from one to the next. Those questions are kept per worktree,
-- under stdpath("data")/azure-cli-chat/why/.
--   M.list_lines(files, check)  the file list's lines and highlights: with
--                             a plan (chat/plan.lua's check_change), the
--                             files it doesn't list are marked, and the
--                             ones it lists but the change didn't touch
--                             follow (pure)
--   M.files(raw)              the changed files in diff order: { path,
--                             status = "A"|"D"|"R"|"M" } (pure)
local M = {}

local DIFFBUF = require("azure-cli.diffbuf")
local current_ns = vim.api.nvim_create_namespace("azure_cli_chat_changes_current")
local list_ns = vim.api.nvim_create_namespace("azure_cli_chat_changes_list")
local link_ns = vim.api.nvim_create_namespace("azure_cli_chat_changes_links")
local hunk_ns = vim.api.nvim_create_namespace("azure_cli_chat_changes_hunks")

-- One view per change (per worktree) - its own tab - so several agents'
-- changes can be open at once. `view` is the one being worked on: every
-- key, autocmd and callback points it at its own change's view first.
local view = nil  -- { tab, list_win, diff_win, list_buf, files, diffs, bufs, title, dir }
local views = {}  -- worktree dir -> its view
local by_buf = {} -- buffer -> the view it belongs to

local function KEYS() return require("azure-cli.keys") end
local function THREADS() return require("azure-cli.chat.threads") end
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

-- One file's diff (`raw`: its section of `git diff`, header included) cut
-- into hunks: { header = { lines before the first @@ }, hunks = { { lines
-- (the @@ line and its body, as git wrote them), first, last (the rows
-- cache.parse_diff shows it on), key (stable across refreshes: its text) } } }.
-- Counts rows exactly as parse_diff does (the same lines dropped), so a
-- row of the diff pane finds its hunk. Pure.
local function is_meta(l)
  return l:match("^%+%+%+") or l:match("^%-%-%-") or l:match("^diff ") or l:match("^index ")
    or l:match("^new file") or l:match("^deleted file") or l:match("^old mode") or l:match("^new mode")
    or l:match("^rename ") or l:match("^similarity ") or l:match("^copy ") or l:match("^Binary files ")
    or l:match("^\\")
end

function M.hunks(raw)
  local out = { header = {}, hunks = {} }
  local row, cur = 0, nil
  for _, l in ipairs(raw or {}) do
    if l:match("^@@") then
      cur = { lines = { l }, first = row + 1, last = row }
      out.hunks[#out.hunks + 1] = cur
    elseif not cur then
      out.header[#out.header + 1] = l
      if not is_meta(l) then row = row + 1 end
    else
      cur.lines[#cur.lines + 1] = l
      if not is_meta(l) then
        row = row + 1
        cur.last = row
      end
    end
  end
  for _, h in ipairs(out.hunks) do h.key = table.concat(h.lines, "\n") end
  return out
end

-- The hunk shown on `row`, or nil. Pure.
function M.hunk_at(parsed, row)
  for i, h in ipairs(parsed.hunks) do
    if row >= h.first and row <= h.last then return h, i end
  end
  return nil
end

-- A patch of just hunk `h` of `parsed` (git apply takes it). Pure.
function M.hunk_patch(parsed, h)
  local out = vim.list_extend(vim.list_slice(parsed.header, 1, #parsed.header), h.lines)
  return table.concat(out, "\n") .. "\n"
end

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end

local LIST_HELP = {
  "Files",
  { "open", "show the file's change" },
  "The change",
  { "run_tests", "run the plan's tests on the change (asks), or see the last run" },
  { "refresh", "refresh (the agent may have changed more)" },
  { "chat", "go to the chat" },
  "Window",
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "quit", "close" }, { "help", "this help" },
}
local DIFF_HELP = {
  "Navigate",
  { "next_hunk", "next change (continues into the next file)" },
  { "prev_hunk", "previous change (continues into the previous file)" },
  { "next_comment", "next question" }, { "prev_comment", "previous question" },
  { "goto_plan", "the plan line this code carries out (or the plan's entry for the file)" },
  { "back", "back to the file list" },
  { "open_file", "edit the file in the worktree, at this line" },
  "Ask the agent",
  { "ask", "ask about this line (\"why did you choose this here?\") - the answer shows under it" },
  { "expand_thread", "show all of the answer under this line / fold it again" },
  { "view_comments", "the question and answer in a popup" },
  { "comment", "queue a change on this line (in visual mode: these lines) for the agent" },
  { "batch_submit", "send the queued changes to the agent, in one message" },
  { "delete_thread", "forget the question or queued change under this line" },
  { "chat", "go to the chat (in visual mode: send the selected lines)" },
  "The change",
  { "accept_hunk", "accept the change under the cursor - a \u{2713} beside it (again: take it back)" },
  { "reject_hunk", "take the change under the cursor out of the worktree (asks)" },
  { "run_tests", "run the plan's tests on the change (asks), or see the last run" },
  { "refresh", "refresh (the agent may have changed more)" },
  "Window",
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "quit", "close" }, { "help", "this help" },
}

local function help(surface, tbl)
  UI().open_float(KEYS().help_lines(surface, "Proposed change keys", tbl,
    -- The reviewer's surfaces, but nothing here touches Azure DevOps.
    { fixed = { KEYS().line_raw("j / k", "move") }, writes = {} }), { title = "Keys" })
end

local function alive(v)
  return v and v.tab and vim.api.nvim_tabpage_is_valid(v.tab) and v.list_win and vim.api.nvim_win_is_valid(v.list_win)
    and v.diff_win and vim.api.nvim_win_is_valid(v.diff_win)
end

local function use_buf(buf) if by_buf[buf] then view = by_buf[buf] end end

-- Points `view` at worktree `dir`'s view: true when it's open.
local function use_dir(dir)
  if not alive(views[dir]) then return false end
  view = views[dir]
  return true
end

local function view_of_tab(tab)
  for _, v in pairs(views) do if v.tab == tab and alive(v) then return v end end
  return nil
end

-- KEYS().bind on a buffer of one change's view: the key works on that view.
local function bind(buf, surface, action, fn, opts)
  KEYS().bind(buf, surface, action, function(...)
    use_buf(buf)
    return fn(...)
  end, opts)
end

local function close()
  if view then views[view.dir] = nil end
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

-- The file list, then what's worth pressing now (KEYS.hint_lines): the
-- diff's keys, "send" while changes are queued, the plan's tests when there
-- are some. Rows 1..#files stay the files.
local function render_list()
  if not (view and view.list_buf and vim.api.nvim_buf_is_valid(view.list_buf)) then return end
  local lines, hls = M.list_lines(view.files, view.check)
  local _, queued = THREADS().counts(view.threads)
  local hints = { { "diff", "ask", "ask about a line" }, { "diff", "comment", "queue a change on a line" } }
  if queued > 0 then hints[#hints + 1] = { "diff", "batch_submit", "send the " .. queued .. " queued" } end
  hints[#hints + 1] = { "diff", "accept_hunk", "accept a hunk" }
  hints[#hints + 1] = { "diff", "reject_hunk", "take a hunk out" }
  if view.plan then hints[#hints + 1] = { "diff", "goto_plan", "the plan step it carries out" } end
  local tail = {}
  if view.has_tests then tail[#tail + 1] = { "list", "run_tests", "run the plan's tests" } end
  tail[#tail + 1] = { "list", "help", "all keys" }
  local hl1, hh1 = KEYS().hint_lines(hints)
  local hl2, hh2 = KEYS().hint_lines(tail)
  if #hl1 + #hl2 > 0 then lines[#lines + 1] = "" end
  if #hl1 > 0 then
    lines[#lines + 1] = " In the diff:"
    hls[#hls + 1] = { #lines - 1, 0, #lines[#lines], "AzureCliMuted" }
  end
  for _, part in ipairs({ { hl1, hh1 }, { hl2, hh2 } }) do
    local at = #lines
    for _, l in ipairs(part[1]) do lines[#lines + 1] = l end
    for _, h in ipairs(part[2]) do hls[#hls + 1] = { at + h[1], h[2], h[3], h[4] } end
  end
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, lines)
  vim.bo[view.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.list_buf, list_ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, view.list_buf, list_ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

-- The reviewer's winbar: the path and its +adds -dels.
local function set_diff_winbar(path, map)
  render_list()
  if not valid_win(view.diff_win) then return end
  local mine = {}
  for _, th in ipairs(view.threads or {}) do if th.file == path then mine[#mine + 1] = th end end
  local nq = THREADS().counts(mine)
  local _, queued = THREADS().counts(view.threads)
  local nh, na = 0, 0
  local accepted = view.accepted and view.accepted[path] or {}
  for _, h in ipairs(M.hunks(view.diffs[path] or {}).hunks) do
    nh = nh + 1
    if accepted[h.key] then na = na + 1 end
  end
  local tags = {}
  if nq > 0 then tags[#tags + 1] = "[" .. THREADS().count_label(nq) .. "]" end
  if queued > 0 then tags[#tags + 1] = "[\u{270E}" .. queued .. " queued - " .. KEYS().name("diff", "batch_submit") .. " sends]" end
  if na > 0 then tags[#tags + 1] = "[\u{2713} " .. na .. "/" .. nh .. " accepted]" end
  -- The plan's tests (gb), here rather than above the narrow file list.
  local TR = require("azure-cli.chat.tests_run")
  local tests_tag = TR.label(TR.load(view.dir), view.fp, TR.running(view.dir))
  if tests_tag then tags[#tags + 1] = tests_tag end
  pcall(UI().wo, view.diff_win, "winbar", UI().winbar({ path .. DIFFBUF.stats(map) }, tags))
end

-- The file-list row of the file in the diff pane, marked as the reviewer
-- marks it (it stays visible while the focus is in the diff pane).
local function mark_current(idx)
  if not (view.list_buf and vim.api.nvim_buf_is_valid(view.list_buf)) then return end
  vim.api.nvim_buf_clear_namespace(view.list_buf, current_ns, 0, -1)
  if idx then pcall(vim.api.nvim_buf_add_highlight, view.list_buf, current_ns, "AzureCliCurrentFile", idx - 1, 0, -1) end
end

-- The questions asked about worktree `dir`'s change: { file, line, side,
-- anchor, question, answer, ... } (chat/threads.lua).
local function why_path(dir)
  return require("azure-cli.chat.store").root() .. "/why/" .. vim.fn.fnamemodify(dir, ":t"):gsub("[^%w%._%-]", "_") .. ".json"
end

local function why_load(dir)
  local ok, lines = pcall(vim.fn.readfile, why_path(dir))
  local okd, list = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return okd and type(list) == "table" and list or {}
end

local function why_save()
  if not view then return end
  local path = why_path(view.dir)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(view.threads) }, path)
end

-- The diff row thread `th` sits under in file `idx`'s buffer, or nil.
local function thread_row(idx, th)
  local f = view.files[idx]
  local cur = f and view.bufs[f.path] and view.maps[view.bufs[f.path]]
  if not (cur and th.file == f.path) then return nil end
  local near, near_d
  for row, m in ipairs(cur.map) do
    if m.lineno == th.line and m.side == (th.side or "R") then return row end
    if th.outdated and m.side == "R" and m.lineno then
      local d = math.abs(m.lineno - th.line)
      if not near_d or d < near_d then near, near_d = row, d end
    end
  end
  return near
end

-- "◂ plan:7" at the end of each line a step of the plan starts at
-- (show_fix's `steps`, kept on the plan).
local function draw_links(idx)
  local f = view and view.files[idx]
  local buf = f and view.bufs[f.path]
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_clear_namespace(buf, link_ns, 0, -1)
  if not view.plan then return end
  local PLAN = require("azure-cli.chat.plan")
  local lines = PLAN.lines(view.plan)
  local map = view.maps[buf].map
  for _, k in ipairs(view.plan.links or {}) do
    if k.file == f.path then
      local pl = PLAN.resolve_line(lines, k.plan_line, k.plan_anchor)
      for row, m in ipairs(map) do
        if m.side == "R" and m.lineno == k.line and pl then
          pcall(vim.api.nvim_buf_set_extmark, buf, link_ns, row - 1, 0, {
            virt_text = { { "  \u{25C2} plan:" .. pl .. (k.note and (" " .. k.note) or ""), "AzureCliMuted" } },
            virt_text_pos = "eol" })
        end
      end
    end
  end
end

-- gp on a line of the change: the plan line it carries out - the step
-- link at or above it in this file, else the file's Files entry.
local function goto_plan(idx)
  if not view.plan then return notify("This change has no plan.") end
  local PLAN = require("azure-cli.chat.plan")
  local f = view.files[idx]
  local m = view.maps[view.bufs[f.path]].map[vim.api.nvim_win_get_cursor(0)[1]] or {}
  local lines = PLAN.lines(view.plan)
  local k = m.lineno and m.side == "R" and PLAN.link_for_code(view.plan.links, f.path, m.lineno)
  local line = k and PLAN.resolve_line(lines, k.plan_line, k.plan_anchor) or PLAN.file_entry_line(lines, f.path)
  if not line then return notify("The plan doesn't mention " .. f.path .. ".") end
  PLAN.open(view.plan.key, line)
end

-- The hunks you accepted (gy), per worktree: { [path] = { [hunk key] = true } }.
local function hunks_path(dir) return (why_path(dir):gsub("%.json$", ".hunks.json")) end
local function hunks_load(dir)
  local ok, lines = pcall(vim.fn.readfile, hunks_path(dir))
  local okd, t = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return okd and type(t) == "table" and t or {}
end
local function hunks_save()
  local path = hunks_path(view.dir)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(view.accepted) }, path)
end

-- File `idx`'s hunks, and how many of them you accepted.
local function file_hunks(idx)
  local f = view.files[idx]
  local parsed = M.hunks(view.diffs[f.path] or {})
  local mine, n = view.accepted[f.path] or {}, 0
  for _, h in ipairs(parsed.hunks) do if mine[h.key] then n = n + 1 end end
  return parsed, n
end

-- A ✓ beside each hunk you accepted.
local function draw_hunks(idx)
  local f = view and view.files[idx]
  local buf = f and view.bufs[f.path]
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_clear_namespace(buf, hunk_ns, 0, -1)
  local parsed = file_hunks(idx)
  local mine = view.accepted[f.path] or {}
  for _, h in ipairs(parsed.hunks) do
    if mine[h.key] then
      for r = h.first, h.last do
        pcall(vim.api.nvim_buf_set_extmark, buf, hunk_ns, r - 1, 0,
          { sign_text = r == h.first and "\u{2713}" or "\u{2502}", sign_hl_group = "AzureCliStatusOk", priority = 20 })
      end
    end
  end
end

-- gy: accept the hunk under the cursor (gy again takes it back).
local function accept_hunk(idx)
  local f = view.files[idx]
  local h = M.hunk_at(file_hunks(idx), vim.api.nvim_win_get_cursor(0)[1])
  if not h then return notify("Put the cursor on a change.") end
  view.accepted[f.path] = view.accepted[f.path] or {}
  view.accepted[f.path][h.key] = (not view.accepted[f.path][h.key]) or nil
  hunks_save()
  draw_hunks(idx)
  set_diff_winbar(f.path, view.maps[view.bufs[f.path]].map)
end

-- gn: take the hunk under the cursor back out of the worktree (asks).
local function reject_hunk(idx)
  local f = view.files[idx]
  if view.title:find("(last commit)", 1, true) then
    return notify("This is the pushed commit - there's nothing uncommitted to take back.", vim.log.levels.WARN)
  end
  local parsed = file_hunks(idx)
  local h = M.hunk_at(parsed, vim.api.nvim_win_get_cursor(0)[1])
  if not h then return notify("Put the cursor on a change.") end
  local dir, label = view.dir, f.path .. " (" .. h.lines[1]:match("^(@@.-@@)") .. ")"
  require("azure-cli.prompt").confirm({ title = "Revert this?", prompt = "This change to " .. label
    .. " goes from the worktree.", details = h.lines,
    details_ft = "diff" }, function(yes)
    if not yes then return end
    local tmp = vim.fn.tempname()
    vim.fn.writefile(vim.split(M.hunk_patch(parsed, h), "\n", { plain = true }), tmp)
    require("azure-cli.chat.tools").git({ "git", "-C", dir, "apply", "-R", tmp }, function(ok, _, err)
      pcall(vim.fn.delete, tmp)
      if not ok then return notify("Couldn't take it out: " .. tostring(err), vim.log.levels.WARN) end
      require("azure-cli.chat").note("You took a change out of the agent's work: " .. label .. ".")
      pcall(require("azure-cli.chat.plan").event_for_worktree, dir, "took_out", "You took out a change to " .. label)
      M.refresh(dir)
    end)
  end)
end

local function draw_threads(idx)
  local f = view and view.files[idx]
  local buf = f and view.bufs[f.path]
  if not buf then return end
  THREADS().draw(buf, view.diff_win, view.threads, function(th) return thread_row(idx, th) end,
    { send = KEYS().name("diff", "batch_submit") })
end

-- Every file's added and kept lines (new-side line number -> text), so the
-- questions find their lines again after the agent changed more.
local function reanchor()
  local CACHE = require("azure-cli.cache")
  for _, f in ipairs(view.files) do
    local mine = false
    for _, th in ipairs(view.threads) do if th.file == f.path then mine = true end end
    if mine then
      local lines, map = CACHE.parse_diff(view.diffs[f.path] or {})
      local by_line = {}
      for i, m in ipairs(map) do if m.side == "R" and m.lineno then by_line[m.lineno] = lines[i] end end
      THREADS().reanchor(view.threads, by_line, function(th) return th.file ~= f.path or th.side == "L" end)
    end
  end
end

local function thread_here(idx)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, th in ipairs(view.threads) do
    if thread_row(idx, th) == row then return th end
  end
  return nil
end

-- What gS sends: every change queued on lines of the agent's change
-- (`queued`: request threads { file, line, anchor, question }), with your
-- note. Pure.
function M.fix_message(what, note, queued)
  local parts = { "Please change these in " .. what .. ":" }
  for _, r in ipairs(queued) do
    parts[#parts + 1] = "- " .. tostring(r.file) .. " line " .. tostring(r.line)
      .. (r.side == "L" and " (a line you removed)" or "")
      .. (r.anchor and r.anchor ~= "" and (" `" .. r.anchor .. "`") or "") .. ": " .. r.question
  end
  if note and vim.trim(note) ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = note
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Then show_fix it to me again."
  return table.concat(parts, "\n")
end

local function what_label()
  return "your change " .. view.title:gsub("^Proposed change %- ", "for "):gsub(" %(last commit%)$", "")
    .. " (worktree " .. view.dir .. ")"
end

-- c: queue a change on this line (or these lines) of the agent's change,
-- for gS.
local function comment_here(idx, from, to)
  local f = view.files[idx]
  local buf = view.bufs[f.path]
  local map = view.maps[buf].map
  local m = map[to] or {}
  if not m.lineno then return notify("Put the cursor on a line of the change.") end
  local lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
  local dir = view.dir
  require("azure-cli.editor").open({
    title = "Change \u{00B7} " .. vim.fn.fnamemodify(f.path, ":t") .. ":" .. m.lineno .. " (queued for " .. KEYS().name("diff", "batch_submit") .. ")",
    initial = "", anchor = { win = vim.api.nvim_get_current_win(), row = to }, context_lines = lines,
    on_submit = function(text)
      if not use_dir(dir) then return end
      table.insert(view.threads, { id = tostring(os.time()) .. "-" .. math.random(1000, 9999), kind = "request",
        file = f.path, line = m.lineno, side = m.side, anchor = vim.trim(lines[#lines] or ""), question = text,
        status = "queued", at = os.time() })
      why_save()
      draw_threads(idx)
      set_diff_winbar(f.path, map)
    end,
  })
end

-- gb: run the plan's tests on this change (asks), or see the last run's
-- output.
local function run_tests()
  local TR = require("azure-cli.chat.tests_run")
  local dir, fp, title = view.dir, view.fp, view.title
  local cmd, source = TR.command(dir, view.plan)
  local last = TR.load(dir)
  if TR.running(dir) then return notify("The tests are running - their result shows in the winbar.") end
  local function go()
    if not cmd then
      return notify("No test command: set chat.test_cmd for this repository, or the plan's Test plan section needs "
        .. "a sh code block.", vim.log.levels.WARN)
    end
    -- Your own command (chat.test_cmd) runs straight away; the agent's asks.
    local runner = source == "config" and TR.run or TR.ask_and_run
    runner(dir, cmd, fp, function(r, err)
      if not r then
        if err ~= "declined" then notify("The tests didn't run: " .. tostring(err), vim.log.levels.WARN) end
        return
      end
      require("azure-cli.chat").note("Tests on " .. title:gsub("^Proposed change %- ", "") .. " (" .. cmd .. "): "
        .. (TR.label(r) or ""):gsub("^%[", ""):gsub("%]$", "") .. ".")
      if use_dir(dir) then M.refresh(dir) end
      if r.code ~= 0 then TR.show(r) else notify("Tests passed.") end
    end)
    if use_dir(dir) and view.current then
      local f = view.files[view.current]
      set_diff_winbar(f.path, view.maps[view.bufs[f.path]].map)
    end
  end
  if not last then return go() end
  require("azure-cli.prompt").select({ prompt = "Tests " .. (TR.label(last, fp) or ""),
    items = { "Run them again", "Show the last output" } }, function(choice)
    if choice == "Run them again" then go() elseif choice then TR.show(last) end
  end)
end

-- gS: send every queued change to the agent in one message.
local function submit_changes()
  local queued = {}
  for _, th in ipairs(view.threads) do
    if th.kind == "request" and th.status ~= "sent" then queued[#queued + 1] = th end
  end
  if #queued == 0 then return notify("Nothing queued - c on a line queues a change.") end
  local CHAT = require("azure-cli.chat")
  if CHAT.busy() then return notify("The agent is still answering - send these once it's done.", vim.log.levels.WARN) end
  local dir = view.dir
  require("azure-cli.editor").open({
    title = "Send " .. #queued .. " change" .. (#queued == 1 and "" or "s") .. " to the agent",
    initial = "Please make these changes.", anchor = "center",
    on_submit = function(note)
      if not use_dir(dir) then return end
      local entry = CHAT.send(M.fix_message(what_label(), note, queued), {
        view_win = valid_win(view.diff_win) and view.diff_win or nil,
        display = note .. " (+" .. #queued .. " on lines of the change)" })
      if not entry then return end
      for _, th in ipairs(queued) do th.status = "sent" end
      why_save()
      if view.current then
        draw_threads(view.current)
        local f = view.files[view.current]
        set_diff_winbar(f.path, view.maps[view.bufs[f.path]].map)
      end
    end,
  })
end

-- dd: forget the question or queued change under the cursor.
local function delete_here(idx)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i, th in ipairs(view.threads) do
    if thread_row(idx, th) == row then
      table.remove(view.threads, i)
      why_save()
      draw_threads(idx)
      return
    end
  end
  notify("Nothing under this line.")
end

local function ask_here(idx)
  local f = view.files[idx]
  local buf = view.bufs[f.path]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local m = view.maps[buf].map[row] or {}
  if not m.lineno then return notify("Put the cursor on a line of the change.") end
  local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local name = vim.fn.fnamemodify(f.path, ":t")
  local dir = view.dir
  THREADS().ask({
    win = vim.api.nvim_get_current_win(), row = row, line = m.lineno, anchor = vim.trim(text),
    file = f.path, side = m.side,
    ctx = { what = "your change " .. view.title:gsub("^Proposed change %- ", "for "):gsub(" %(last commit%)$", "")
      .. " (worktree " .. dir .. ")",
      where = f.path .. " line " .. m.lineno .. (m.side == "L" and " (a line you removed)" or "") },
    label = name .. ":" .. m.lineno,
    threads = view.threads,
    changed = function()
      if not use_dir(dir) then return end
      why_save()
      if view.current then draw_threads(view.current) end
    end,
  })
end

local function jump_thread(idx, dir)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, th in ipairs(view.threads) do
    local r = thread_row(idx, th)
    if r and ((dir > 0 and r > row and (not best or r < best)) or (dir < 0 and r < row and (not best or r > best))) then
      best = r
    end
  end
  if not best then return notify(dir > 0 and "No further questions in this file." or "No earlier questions in this file.") end
  vim.api.nvim_win_set_cursor(0, { best, 0 })
end

local jump  -- forward

-- gq / r on both panes.
local function bind_common(buf, surface)
  bind(buf, surface, "chat", function() require("azure-cli.chat").toggle() end, { desc = "go to the chat" })
  bind(buf, surface, "chat", function() require("azure-cli.chat").capture_selection() end,
    { desc = "send the selected lines to the chat", mode = "x" })
  bind(buf, surface, "refresh", function() M.refresh() end, { desc = "refresh the change" })
  bind(buf, surface, "run_tests", function() run_tests() end, { desc = "run the plan's tests on the change" })
end

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
  -- The file's own filetype, as the reviewer sets it; the chat finds this
  -- screen by the buffer variable instead.
  vim.b[buf].azure_cli_view = "azurecli-changes"
  vim.b[buf].azure_cli_keys_local = true  -- c / gS / dd go to the agent, not Azure DevOps
  vim.b[buf].azure_cli_title = f.path
  vim.bo[buf].filetype = DIFFBUF.ft_for_path(f.path) or "text"
  DIFFBUF.decorate(buf, lines, map)
  require("azure-cli.review.pane").register(buf, map)
  view.bufs[f.path] = buf
  by_buf[buf] = view
  view.maps = view.maps or {}
  view.maps[buf] = { idx = idx, map = map }
  bind(buf, "diff", "next_hunk", function() jump(1) end, { desc = "next change" })
  bind(buf, "diff", "prev_hunk", function() jump(-1) end, { desc = "previous change" })
  bind(buf, "diff", "back", function()
    if valid_win(view.list_win) then vim.api.nvim_set_current_win(view.list_win) end
  end, { desc = "back to the file list" })
  bind(buf, "diff", "open_file", function()
    local m = map[vim.api.nvim_win_get_cursor(0)[1]] or {}
    local line = m.side == "R" and m.lineno or 1
    vim.cmd("tabedit " .. vim.fn.fnameescape(view.dir .. "/" .. f.path))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end, { desc = "edit the file in the worktree" })
  bind(buf, "diff", "resize_less", function() resize(-5) end, { desc = "shrink the file list" })
  bind(buf, "diff", "resize_more", function() resize(5) end, { desc = "grow the file list" })
  bind(buf, "diff", "quit", close, { desc = "close" })
  bind(buf, "diff", "help", function() help("diff", DIFF_HELP) end, { desc = "keys" })
  bind(buf, "diff", "ask", function() ask_here(idx) end, { desc = "ask the agent about this line" })
  bind(buf, "diff", "goto_plan", function() goto_plan(idx) end, { desc = "the plan line this carries out" })
  bind(buf, "diff", "comment", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    comment_here(idx, r, r)
  end, { desc = "queue a change on this line for the agent" })
  bind(buf, "diff", "comment_range", function()
    local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    comment_here(idx, a, b)
  end, { desc = "queue a change on these lines for the agent", mode = "x" })
  bind(buf, "diff", "batch_submit", submit_changes, { desc = "send the queued changes to the agent" })
  bind(buf, "diff", "accept_hunk", function() accept_hunk(idx) end, { desc = "accept this change (again: undo)" })
  bind(buf, "diff", "reject_hunk", function() reject_hunk(idx) end, { desc = "take this change out of the worktree" })
  bind(buf, "diff", "delete_thread", function() delete_here(idx) end, { desc = "forget what's under this line" })
  bind(buf, "diff", "expand_thread", function()
    local th = thread_here(idx)
    if not th then return notify("No question on this line (" .. (KEYS().first("diff", "ask") or "ga") .. " asks one).") end
    THREADS().toggle(th)
    draw_threads(idx)
  end, { desc = "show all of the answer / fold it" })
  bind(buf, "diff", "view_comments", function() THREADS().show(thread_here(idx),
    { send = KEYS().name("diff", "batch_submit"), ask = KEYS().name("diff", "ask") }) end, { desc = "the question and answer" })
  bind(buf, "diff", "next_comment", function() jump_thread(idx, 1) end, { desc = "next question" })
  bind(buf, "diff", "prev_comment", function() jump_thread(idx, -1) end, { desc = "previous question" })
  bind_common(buf, "diff")
  return buf
end

-- Shows file `idx` in the diff pane; focus moves there when `focus`.
local function show(idx, focus)
  if not (view and view.files[idx] and valid_win(view.diff_win)) then return nil end
  local buf = diff_buf(idx)
  vim.api.nvim_win_set_buf(view.diff_win, buf)
  -- Window options reset when a window shows a buffer for the first time:
  -- (re)applied after every switch, as the reviewer does.
  UI().plain_window(view.diff_win, {})
  require("azure-cli.review.pane").apply(view.diff_win)
  set_diff_winbar(view.files[idx].path, view.maps[buf].map)
  mark_current(idx)
  view.current = idx
  draw_threads(idx)
  draw_links(idx)
  draw_hunks(idx)
  -- Again once the window has drawn its gutter: the answers wrap to what's
  -- left of the width.
  vim.schedule(function() if view and view.current == idx then draw_threads(idx) end end)
  if valid_win(view.list_win) then pcall(vim.api.nvim_win_set_cursor, view.list_win, { idx, 0 }) end
  if focus then vim.api.nvim_set_current_win(view.diff_win) end
  return buf
end

-- ]c / [c: the next/previous block of changed lines, crossing into the
-- next/previous file once this one runs out (as in the reviewer).
jump = function(dir)
  local cur = view and view.maps and view.maps[vim.api.nvim_get_current_buf()]
  if not cur then return end
  local i = DIFFBUF.next_change(cur.map, vim.api.nvim_win_get_cursor(0)[1], dir)
  if i then
    vim.api.nvim_win_set_cursor(0, { i, 0 })
    vim.cmd("normal! zz")
    return
  end
  local idx = cur.idx + dir
  while view.files[idx] do
    local target = DIFFBUF.edge_change(view.maps[diff_buf(idx)].map, dir)
    if target then
      show(idx, true)
      vim.api.nvim_win_set_cursor(view.diff_win, { target, 0 })
      vim.api.nvim_win_call(view.diff_win, function() vim.cmd("normal! zz") end)
      return
    end
    idx = idx + dir
  end
  notify(dir > 0 and "No further changes." or "No previous changes.")
end

-- The file list: one row per changed file (in view.files' order, so row i
-- is file i); with a plan, the files it doesn't list are marked, and the
-- ones it lists but the change doesn't touch follow below. Returns the
-- lines and their highlights { row0, col, end_col, group }. Pure.
function M.list_lines(files, check)
  local lines, hls = {}, {}
  local off = {}
  for _, p in ipairs(check and check.unplanned or {}) do off[p] = true end
  for _, f in ipairs(files) do
    local l = " " .. f.status .. "  " .. f.path
    if off[f.path] then
      hls[#hls + 1] = { #lines, #l, #l + #"  \u{2717} not in the plan", "AzureCliStatusBad" }
      l = l .. "  \u{2717} not in the plan"
    end
    lines[#lines + 1] = l
  end
  if #lines == 0 then lines = { " (no changes yet)" } end
  local missing = check and check.missing or {}
  if #missing > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = " In the plan, not changed:"
    hls[#hls + 1] = { #lines - 1, 0, #lines[#lines], "AzureCliMuted" }
    for _, p in ipairs(missing) do
      lines[#lines + 1] = "    " .. p
      hls[#hls + 1] = { #lines - 1, 0, #lines[#lines], "AzureCliStatusDraft" }
    end
  end
  return lines, hls
end

local function setup_list(buf)
  local function under() return vim.api.nvim_win_get_cursor(0)[1] end
  bind(buf, "list", "open", function() show(under(), true) end, { desc = "show the file's change" })
  bind(buf, "list", "resize_less", function() resize(-5) end, { desc = "shrink the file list" })
  bind(buf, "list", "resize_more", function() resize(5) end, { desc = "grow the file list" })
  bind(buf, "list", "quit", close, { desc = "close" })
  bind(buf, "list", "help", function() help("list", LIST_HELP) end, { desc = "keys" })
  bind_common(buf, "list")
  -- Moving through the list previews each file's change, debounced like
  -- the reviewer's file list: only the row the cursor settles on is shown,
  -- so j/k stay instant while skipping past files.
  local timer = (vim.uv or vim.loop).new_timer()
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      timer:stop()
      timer:start(DIFFBUF.PREVIEW_MS, 0, vim.schedule_wrap(function()
        use_buf(buf)
        if not (view and vim.api.nvim_buf_is_valid(buf) and valid_win(view.list_win)) then return end
        if vim.api.nvim_win_get_buf(view.list_win) ~= buf then return end
        local i = vim.api.nvim_win_get_cursor(view.list_win)[1]
        if i ~= view.current and view.files[i] then show(i, false) end
      end))
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function() timer:stop() timer:close() end })
end

function M.open(title, dir, raw, keep)
  DIFFBUF.setup_hl()
  local CACHE = require("azure-cli.cache")
  local width = view and view.width or 40
  -- This worktree's tab when it's open (a refresh), else a new one - the
  -- other changes' tabs stay as they are. Its previous diff buffers go
  -- once the new ones are on screen (deleting the one a window shows would
  -- close that window).
  local old = alive(views[dir]) and views[dir] or nil
  local stale = old and vim.tbl_values(old.bufs or {}) or {}
  view = { files = M.files(raw), diffs = CACHE.split_diff(raw), bufs = {}, maps = {}, title = title, dir = dir,
    width = width, threads = (old and old.dir == dir) and old.threads or why_load(dir),
    accepted = (old and old.dir == dir) and old.accepted or hunks_load(dir) }
  views[dir] = view
  reanchor()
  -- The plan this change was made from, if any: which files it doesn't list.
  local paths = {}
  for _, f in ipairs(view.files) do paths[#paths + 1] = f.path end
  local okp, PLAN = pcall(require, "azure-cli.chat.plan")
  view.plan = okp and PLAN.for_worktree(dir) or nil
  view.fp = require("azure-cli.chat.tests_run").fingerprint(table.concat(raw, "\n"))
  view.check = okp and PLAN.check_change(view.plan, paths) or nil
  view.has_tests = require("azure-cli.chat.tests_run").command(dir, view.plan) ~= nil
  if old then
    view.tab, view.list_win, view.diff_win, view.list_buf = old.tab, old.list_win, old.diff_win, old.list_buf
    by_buf[view.list_buf] = view
    vim.api.nvim_set_current_tabpage(view.tab)
  else
    vim.cmd("tabnew")
    view.tab = vim.api.nvim_get_current_tabpage()
    view.list_win = vim.api.nvim_get_current_win()
    view.list_buf = vim.api.nvim_get_current_buf()
    by_buf[view.list_buf] = view
    vim.bo[view.list_buf].buftype = "nofile"
    vim.bo[view.list_buf].bufhidden = "wipe"
    vim.bo[view.list_buf].filetype = "azurecli-changes"
    vim.b[view.list_buf].azure_cli_keys_local = true
    pcall(vim.api.nvim_buf_set_name, view.list_buf, "azure-cli://changes/" .. vim.fn.fnamemodify(dir, ":t"))
    local lb = view.list_buf
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = lb, once = true, callback = function()
      by_buf[lb] = nil
      if views[dir] and views[dir].list_buf == lb then views[dir] = nil end
    end })
    setup_list(view.list_buf)
    vim.cmd("belowright vsplit")
    view.diff_win = vim.api.nvim_get_current_win()
    UI().plain_window(view.list_win, { cursorline = true })
    pcall(vim.api.nvim_win_set_width, view.list_win, width)
  end
  vim.t[view.tab].azure_cli_title = "Change " .. (title:match("([#!]%d+)") or "")
  vim.t[view.tab].azure_cli_plan_key = view.plan and view.plan.key or nil
  pcall(function() require("azure-cli.chat").sync_active() end)
  render_list()
  local ctags = {}
  if view.check and #view.check.unplanned > 0 then ctags[#ctags + 1] = "[" .. #view.check.unplanned .. " off plan]" end
  if view.check and #view.check.missing > 0 then ctags[#ctags + 1] = "[" .. #view.check.missing .. " untouched]" end
  pcall(UI().wo, view.list_win, "winbar", UI().winbar({ (title:gsub("^Proposed change %- ", "Change ")) }, ctags))
  local at
  for i, f in ipairs(view.files) do if keep and f.path == keep.path then at = i end end
  if at then
    -- A refresh: the same file, the same line (or the nearest one left).
    show(at, false)
    local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(view.diff_win))
    pcall(vim.api.nvim_win_set_cursor, view.diff_win, { math.max(1, math.min(keep.line or 1, n)), 0 })
    vim.api.nvim_win_call(view.diff_win, function() vim.cmd("normal! zv") end)
  elseif #view.files > 0 then
    show(1, false)
    vim.api.nvim_set_current_win(view.diff_win)
    local first = DIFFBUF.edge_change(view.maps[vim.api.nvim_win_get_buf(view.diff_win)].map, 1)
    if first then
      vim.api.nvim_win_set_cursor(view.diff_win, { first, 0 })
      vim.cmd("normal! zz")
    end
  end
  -- The diff pane gets the focus - again after the chat panel has followed
  -- into this tab (it opens on a scheduled callback and moves the cursor).
  for _, b in ipairs(stale) do
    if vim.api.nvim_buf_is_valid(b) and #vim.fn.win_findbuf(b) == 0 then
      pcall(require("azure-cli.review.pane").forget, b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  local function focus()
    local w = (#view.files > 0 and not (keep and keep.list)) and view.diff_win or view.list_win
    if valid_win(w) then vim.api.nvim_set_current_win(w) end
  end
  focus()
  vim.schedule(function() vim.schedule(focus) end)
  return view.tab
end

-- Shows file `path` of the open change, at line `line` of its new version
-- (else its first change). False when the change has no such file.
function M.jump_to(path, line)
  if not view then return false end
  for i, f in ipairs(view.files) do
    if f.path == path or f.path:sub(-#path - 1) == "/" .. path then
      local buf = show(i, true)
      local map = view.maps[buf].map
      local row = DIFFBUF.edge_change(map, 1) or 1
      if line then
        local best
        for r, m in ipairs(map) do
          if m.side == "R" and m.lineno and (not best or math.abs(m.lineno - line) < math.abs(map[best].lineno - line)) then
            best = r
          end
        end
        row = best or row
      end
      pcall(vim.api.nvim_win_set_cursor, view.diff_win, { row, 0 })
      vim.api.nvim_win_call(view.diff_win, function() vim.cmd("normal! zvzz") end)
      return true
    end
  end
  return false
end

-- `dir`: the worktree whose change to refresh (default: the one being
-- worked on - the key's own).
function M.refresh(dir)
  if dir and not use_dir(dir) then return end
  if not (view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab)) then return end
  local cur = view.files[view.current or 0]
  local keep = {
    path = cur and cur.path,
    line = valid_win(view.diff_win) and vim.api.nvim_win_get_cursor(view.diff_win)[1] or 1,
    list = vim.api.nvim_get_current_win() == view.list_win,
  }
  local title = view.title:gsub(" %(last commit%)$", "")
  dir = view.dir
  require("azure-cli.chat.tools_fix").load(dir, require("azure-cli.chat.tools").git, function(ok, diff, last)
    if not ok then return notify("Refreshing failed: " .. tostring(diff)) end
    M.open(title .. (last and " (last commit)" or ""), dir, vim.split(diff, "\n", { plain = true }), keep)
    notify("Refreshed: " .. #view.files .. " file" .. (#view.files == 1 and "" or "s") .. " changed.")
  end)
end

-- The chat's description of this screen: the change, and the file and line
-- under the cursor (the line number in the new version of the file).
function M.describe(win)
  local v = by_buf[vim.api.nvim_win_get_buf(win)] or view_of_tab(vim.api.nvim_win_get_tabpage(win))
  if not v then return nil end
  view = v
  local files = {}
  for _, f in ipairs(view.files) do files[#files + 1] = f.status .. " " .. f.path end
  local snap = { screen = "change viewer", change = view.title, worktree = view.dir, files = files,
    note = "Looking at " .. view.title .. " (worktree " .. view.dir .. "): " .. table.concat(files, ", ") }
  local buf = vim.api.nvim_win_get_buf(win)
  local cur = view.maps[buf]
  if cur then
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local m = cur.map[row] or {}
    snap.file, snap.line, snap.side = view.files[cur.idx].path, m.lineno, m.side
    snap.code_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  elseif buf == view.list_buf then
    local f = view.files[vim.api.nvim_win_get_cursor(win)[1]]
    snap.file = f and f.path
  end
  return snap
end

require("azure-cli.chat.view").register("azurecli-changes", function(win) return M.describe(win) end)

return M
