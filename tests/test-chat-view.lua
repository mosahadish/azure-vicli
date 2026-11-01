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

if fails > 0 then
  print(fails .. " chat view test(s) failed")
  os.exit(1)
end
print("all chat view tests passed")
