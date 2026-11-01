-- test-chat-view.lua: chat/view.lua's describers - what the chat is told
-- about the screen you're on: ordinary code files, the reviewer's Overview
-- and Commits views, a work item's sections, the Agents screen, what's
-- visible, where you just were, and the label the input bar shows. Needs
-- vim.api, treesitter and vim.diagnostic, so it runs under a real headless
-- Neovim:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-view.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local VIEW = require("azure-cli.chat.view")

local function real(p) return (vim.loop.fs_realpath(p) or p):gsub("[/\\]$", "") end

-- A fresh directory holding `files` ({ name = text }), as a git repository
-- on branch `branch` when one is given.
local function workdir(files, branch)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for name, text in pairs(files) do
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
  end
  if branch then
    vim.fn.system({ "git", "-C", dir, "init", "-q" })
    vim.fn.system({ "git", "-C", dir, "checkout", "-q", "-b", branch })
  end
  return real(dir)
end

-- Opens `path` in the current window as filetype `ft`, cursor on `line`.
local function open(path, ft, line)
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  if ft then vim.bo.filetype = ft end
  pcall(vim.api.nvim_win_set_cursor, 0, { line or 1, 0 })
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

-- --- ordinary code files -----------------------------------------------------
do
  local dir = workdir({ ["a.lua"] = "local function foo()\n  return 1\nend\n" }, "topic")
  local win, buf = open(dir .. "/a.lua", "lua", 2)
  local snap = VIEW.snapshot(win)
  check("code: screen", snap.screen == "code", snap.screen)
  check("code: file relative to the repository", snap.file == "a.lua", snap.file)
  check("code: repository", snap.repo == dir, tostring(snap.repo) .. " vs " .. dir)
  check("code: branch", snap.branch == "topic", snap.branch)
  check("code: line and its code", snap.line == 2 and snap.code_line == "  return 1", snap.code_line)
  check("code: the function it's in", type(snap.symbol) == "table" and snap.symbol.name == "foo",
    vim.inspect(snap.symbol))
  local t = VIEW.text(snap)
  check("code: text names the file without a diff side", t:find("File: a.lua line 2\n", 1, true) ~= nil, t)
  check("code: text names the repository and branch", t:find("Repository: " .. dir .. " (branch topic)", 1, true) ~= nil, t)
  check("code: text names the function", t:find("Inside: foo (function_declaration)", 1, true) ~= nil, t)

  local ns = vim.api.nvim_create_namespace("test_chat_view")
  vim.diagnostic.set(ns, buf, {
    { lnum = 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = "bad" },
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.WARN, message = "meh" },
  })
  snap = VIEW.snapshot(win)
  check("code: diagnostics on the line", #(snap.diagnostics or {}) == 1 and snap.diagnostics[1].message == "bad"
    and snap.diagnostics[1].severity == "ERROR", vim.inspect(snap.diagnostics))
  check("code: diagnostics in the file", snap.diagnostic_counts and snap.diagnostic_counts.errors == 1
    and snap.diagnostic_counts.warnings == 1, vim.inspect(snap.diagnostic_counts))
  t = VIEW.text(snap)
  check("code: text has the line's diagnostic", t:find("Diagnostic on this line (ERROR): bad", 1, true) ~= nil, t)
  check("code: text has the file's counts", t:find("Diagnostics in the file: 1 errors, 1 warnings", 1, true) ~= nil, t)
  check("code: unchanged buffer", not snap.modified and not t:find("Unsaved", 1, true))

  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "end -- edited" })
  snap = VIEW.snapshot(win)
  check("code: unsaved changes", snap.modified == true and VIEW.text(snap):find("Unsaved changes in this buffer", 1, true) ~= nil)

  snap = VIEW.snapshot(win, { buf = buf, win = win, from = 1, to = 2, text = "x" })
  check("code: a selection's lines", snap.selection_lines == "1-2" and snap.selection == "x", vim.inspect(snap.selection_lines))
  vim.cmd("silent! %bwipeout!")
end

do
  local dir = workdir({ ["notes.txt"] = "hello\nworld\n" })
  local win = open(dir .. "/notes.txt", "text", 1)
  local snap = VIEW.snapshot(win)
  check("code: outside a repository the path is absolute", snap.screen == "code" and snap.file == dir .. "/notes.txt",
    snap.file)
  check("code: outside a repository no repo or branch", snap.repo == nil and snap.branch == nil)
  check("code: no parser, no symbol", snap.symbol == nil)
  vim.cmd("silent! %bwipeout!")
end

do
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, scratch)
  check("code: a scratch buffer stays other", VIEW.snapshot(0).screen == "other")
  local unnamed = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, unnamed)
  check("code: an unnamed buffer stays other", VIEW.snapshot(0).screen == "other")
  vim.cmd("silent! %bwipeout!")
end

-- --- the reviewer's Overview and Commits views --------------------------------
do
  local RCHAT = require("azure-cli.review.chat")
  local COMMITS = require("azure-cli.review.commits")
  local t1 = { id = 1, status = "active", comments = { { author = "Ann", content = "first" } } }
  local t2 = { id = 2, status = "fixed", comments = { { author = "Bob", content = "second" } } }
  local lines = {
    "PR #42  Add widgets", "master -> feature/widgets", "",
    "Description:", "  some text", "",
    "Commits (who pushed):", "  a1b2c3d  2024-01-15  John Doe: Fix the thing", "",
    "Comments (2):", "", "┌─ thread [active]", "│ Ann:", "│   first", "", "┌─ thread [fixed]", "│ Bob:", "│   second",
  }
  local thread_map = { [12] = { t1 }, [16] = { t2 } }
  local at = RCHAT.overview_at(lines, thread_map, 5)
  check("overview: in the description", at.section == "Description" and at.commit == nil and at.thread == nil,
    vim.inspect(at))
  at = RCHAT.overview_at(lines, thread_map, 8)
  check("overview: on a commit", at.section == "Commits" and at.commit == "a1b2c3d", vim.inspect(at))
  at = RCHAT.overview_at(lines, thread_map, 18)
  check("overview: inside a thread's body", at.section == "Comments" and at.thread and at.thread.id == 2,
    vim.inspect(at))
  at = RCHAT.overview_at(lines, thread_map, 11)
  check("overview: above the first thread", at.section == "Comments" and at.thread == nil, vim.inspect(at))
  at = RCHAT.overview_at(lines, thread_map, 1)
  check("overview: the header has no section", at.section == nil)

  local row = COMMITS.describe_row({ kind = "list" }, "  a1b2c3d  2024-01-15  John Doe: Fix the thing")
  check("commits: the list's row", row.kind == "list" and row.commit == "a1b2c3d" and row.file == nil, vim.inspect(row))
  check("commits: the list's title row", COMMITS.describe_row({ kind = "list" }, "PR #42 commits").commit == nil)
  row = COMMITS.describe_row({ kind = "files", sha = "a1b2c3d" }, "  M  src/a.lua", "src/a.lua")
  check("commits: a commit's file", row.kind == "files" and row.commit == "a1b2c3d" and row.file == "src/a.lua",
    vim.inspect(row))
  row = COMMITS.describe_row({ kind = "diff", sha = "a1b2c3d", path = "src/a.lua" }, "x = 1")
  check("commits: a commit's diff", row.commit == "a1b2c3d" and row.file == "src/a.lua" and row.code_line == "x = 1",
    vim.inspect(row))

  -- Diff rows 2..6 show source lines 10-13 (row 4 is a removed target line).
  local map = { {}, { side = "R", lineno = 10 }, { side = "R", lineno = 11 }, { side = "L", lineno = 7 },
    { side = "R", lineno = 12 }, { side = "R", lineno = 13 }, { side = "R", lineno = 14 } }
  check("diff: visible source lines", RCHAT.visible_lines(map, 1, 6, "R") == "10-13", RCHAT.visible_lines(map, 1, 6, "R"))
  check("diff: visible target lines", RCHAT.visible_lines(map, 1, 6, "L") == "7-7")
  check("diff: nothing on that side", RCHAT.visible_lines(map, 1, 1, "R") == nil)

  local t = VIEW.text({ section = "Comments", commit = "a1b2c3d" })
  check("view: section and commit", t:find("Section: Comments", 1, true) and t:find("Commit: a1b2c3d", 1, true), t)
end

-- --- a work item's sections -----------------------------------------------------
do
  local lines = { "#1 Story", "Title", "", "Description", "───────────", "  text", "",
    "Discussion (2)", "─────────────", "Bob  1d", "  hi" }
  check("section: the header fields have none", VIEW.section_at(lines, 2) == nil)
  check("section: in the description", VIEW.section_at(lines, 6) == "Description")
  check("section: on its title", VIEW.section_at(lines, 4) == "Description")
  check("section: the count goes", VIEW.section_at(lines, 11) == "Discussion", VIEW.section_at(lines, 11))
  local t = VIEW.text({ section = "Discussion", comment_author = "Bob" })
  check("view: comment author", t:find("Comment by Bob", 1, true) ~= nil, t)
end

-- --- the Agents screen --------------------------------------------------------
do
  local AV = require("azure-cli.chat.agents_view")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "PR !7 fix", "#3001 story" })
  vim.bo[buf].filetype = "azurecli-agents"
  vim.api.nvim_win_set_buf(0, buf)
  AV._set_view({ rows = {
    { label = "PR !7", state = "working", pr_id = 7, pr_key = "7", target = { pr_id = 7 } },
    { label = "#3001", state = "PR !9 open", pr_id = 9, pr_key = "9", target = { work_item_id = 3001 } },
  } })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local snap = VIEW.snapshot(0)
  check("agents: a PR agent's PR", type(snap.pr) == "table" and snap.pr.id == 7, vim.inspect(snap.pr))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  snap = VIEW.snapshot(0)
  check("agents: a story agent's item and the PR its plan opened",
    snap.work_item and snap.work_item.id == 3001 and type(snap.pr) == "table" and snap.pr.id == 9, vim.inspect(snap))
  AV._set_view(nil)
  vim.cmd("silent! %bwipeout!")
end

-- --- the label, what's visible, where you just were ---------------------------
do
  check("label: PR, file, thread", VIEW.label({ pr = { id = 101 }, file = "src/auth.py", line = 12, thread = { id = 5000 } })
    == "on PR !101 \u{00B7} auth.py:12 \u{00B7} thread 5000", VIEW.label({ pr = { id = 101 }, file = "src/auth.py", line = 12, thread = { id = 5000 } }))
  check("label: a screen", VIEW.label({ screen = "PR dashboard" }) == "on the PR dashboard")
  check("label: other has none", VIEW.label({ screen = "other" }) == nil)
  check("label: a commit", VIEW.label({ commit = "abcdef1234" }) == "on commit abcdef1", VIEW.label({ commit = "abcdef1234" }))

  local text = {}
  for i = 1, 100 do text[i] = "line " .. i end
  local dir = workdir({ ["long.txt"] = table.concat(text, "\n") .. "\n", ["b.txt"] = "b\n", ["c.txt"] = "c\n" })
  local win = open(dir .. "/long.txt", "text", 45)
  vim.api.nvim_win_set_height(win, 21)
  vim.fn.winrestview({ topline = 40, lnum = 45 })
  local snap = VIEW.snapshot(win)
  check("visible: a code window's lines", snap.visible == "40-60", snap.visible)
  check("view: visible", VIEW.text({ visible = "40-60" }):find("Visible: lines 40-60", 1, true) ~= nil)

  VIEW._forget()
  VIEW.remember(win)                       -- long.txt:45
  open(dir .. "/b.txt", "text", 1)
  VIEW.remember(0)                         -- b.txt:1
  open(dir .. "/c.txt", "text", 1)
  VIEW.remember(0)                         -- c.txt:1
  VIEW.remember(0)                         -- again: collapsed
  local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
    { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
  VIEW.remember(float)
  vim.api.nvim_win_close(float, true)
  local scratch = vim.api.nvim_create_buf(false, true)
  open(dir .. "/b.txt", "text", 1)
  local recent = VIEW.snapshot(0).recent or {}
  check("trail: most recent first, not where you are", #recent == 2 and recent[1] == "on c.txt:1" and recent[2] == "on long.txt:45",
    vim.inspect(recent))
  vim.api.nvim_win_set_buf(0, scratch)
  VIEW.remember(0)
  check("trail: a buffer that describes as other isn't kept", #VIEW.recent() == 3, vim.inspect(VIEW.recent()))
  for _ = 1, 6 do
    open(dir .. "/long.txt", "text", math.random(1, 100))
    VIEW.remember(0)
  end
  check("trail: five at most", #VIEW.recent() == 5)
  local t = VIEW.text({ recent = { "on a.lua:3", "on PR !1" } })
  check("view: recently", t:find("Recently: a.lua:3; PR !1", 1, true) ~= nil, t)

  -- Leaving a window remembers it on its own.
  VIEW._forget()
  open(dir .. "/c.txt", "text", 1)
  vim.cmd("silent split " .. vim.fn.fnameescape(dir .. "/b.txt"))
  check("trail: leaving a window remembers it", VIEW.recent()[1] == "on c.txt:1", vim.inspect(VIEW.recent()))
  vim.cmd("only")
  vim.cmd("silent! %bwipeout!")
end

-- --- review fixes -------------------------------------------------------------
do
  -- The function around a method call is the symbol, not the call.
  local dir = workdir({ ["m.lua"] = "local function foo()\n  local x = self:bar()\n  return x\nend\n" }, "main")
  local win = open(dir .. "/m.lua", "lua", 2)
  vim.api.nvim_win_set_cursor(win, { 2, 18 })
  local snap = VIEW.snapshot(win)
  check("fix: a call isn't the symbol", snap.symbol and snap.symbol.name == "foo", vim.inspect(snap.symbol))

  -- A light snapshot (the trail's, the label's) asks git and treesitter nothing.
  local light = VIEW.snapshot(win, nil, { light = true })
  check("fix: a light snapshot skips branch, symbol, diagnostics",
    light.file == "m.lua" and light.line == 2 and light.branch == nil and light.symbol == nil and light.diagnostics == nil,
    vim.inspect(light))
  VIEW._forget()
  local spawned, real_systemlist = 0, vim.fn.systemlist
  vim.fn.systemlist = function(...) spawned = spawned + 1 return real_systemlist(...) end
  VIEW.remember(win)
  vim.fn.systemlist = real_systemlist
  check("fix: remembering a window runs no git", spawned == 0 and VIEW.recent()[1] == "on m.lua:2", spawned)

  -- A describer that fails on a code file still lets the message go.
  local real_get = vim.diagnostic.get
  vim.diagnostic.get = function() error("broken") end
  local ok, s = pcall(VIEW.snapshot, win)
  vim.diagnostic.get = real_get
  check("fix: a failing code describer doesn't throw", ok and type(s) == "table", tostring(s))
  vim.cmd("silent! %bwipeout!")

end

-- --- the input bar's label ------------------------------------------------------
do
  local CHAT = require("azure-cli.chat")
  local dir = workdir({ ["m.txt"] = "one\ntwo\nthree\n" })
  local win = open(dir .. "/m.txt", "text", 2)
  CHAT.show(false)
  local input
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) ~= vim.api.nvim_win_get_buf(win) and vim.wo[w].winbar:find("sends", 1, true) then input = w end
  end
  check("label: the panel's input is open", input ~= nil)
  check("label: what will be sent", CHAT.view_label() == "on m.txt:2", CHAT.view_label())
  check("label: in the input bar", input and vim.wo[input].winbar:find("on m.txt:2", 1, true) ~= nil,
    input and vim.wo[input].winbar)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  local moved = vim.wait(1000, function() return vim.wo[input].winbar:find("on m.txt:3", 1, true) ~= nil end, 20)
  check("label: follows the cursor", moved, vim.wo[input].winbar)

  -- The input bar reads a label worked out when you move, not on every
  -- redraw (the spinner's are 8 a second).
  local calls = 0
  VIEW.register("test-counting", function() calls = calls + 1 return { screen = "counting" } end)
  local cbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[cbuf].filetype = "test-counting"
  vim.api.nvim_win_set_buf(win, cbuf)
  CHAT.refresh_label()
  calls = 0
  for _ = 1, 5 do CHAT.set_winbars() end
  check("fix: redrawing the bar describes nothing", calls == 0, calls)

  VIEW.register("test-broken", function() error("boom") end)
  local ok = pcall(function() vim.bo.filetype = "test-broken" end)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].filetype = "test-broken"
  vim.api.nvim_win_set_buf(win, scratch)
  check("label: a failing describer gives none", ok and CHAT.view_label() == "", CHAT.view_label())
  CHAT.hide()
  vim.cmd("silent! %bwipeout!")
end

if fails > 0 then
  print(fails .. " chat view test(s) failed")
  os.exit(1)
end
print("all chat view tests passed")
