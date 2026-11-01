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

-- An ordinary file's window (a buffer with a name and no buftype): where it
-- is in its repository, the line, the function the cursor is in (from
-- treesitter, when there's a parser), the diagnostics your LSP put on it and
-- whether it has unsaved changes. Nil for anything else.
local git_cache = {}  -- root -> { branch, at }

local function git_root(path)
  local found = vim.fs.find(".git", { upward = true, path = vim.fs.dirname(path) })[1]
  return found and vim.fs.dirname(found) or nil
end

-- The branch checked out in `root`, asked of git at most every 5 seconds.
local function git_branch(root)
  local now = (vim.uv or vim.loop).now()
  local c = git_cache[root]
  if c and now - c.at < 5000 then return c.branch end
  -- symbolic-ref also knows a new repository's branch, before its first
  -- commit; a detached HEAD is named by its commit.
  local out = vim.fn.systemlist({ "git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD" })
  local branch = vim.v.shell_error == 0 and out[1] and out[1] ~= "" and out[1] or nil
  if not branch then
    out = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--short", "HEAD" })
    branch = vim.v.shell_error == 0 and out[1] and out[1] ~= "" and ("detached at " .. out[1]) or nil
  end
  git_cache[root] = { branch = branch, at = now }
  return branch
end

local SCOPES = { "function", "method", "class", "struct", "impl", "interface", "module" }
-- Node types that name a scope's word but use it rather than define it:
-- self:foo() is a method_index_expression, Java's foo() a
-- method_invocation; a class_body is inside its class.
local NOT_SCOPES = { "call", "expression", "invocation", "index", "reference", "body", "parameter", "argument" }

local function is_scope(kind)
  for _, s in ipairs(NOT_SCOPES) do
    if kind:find(s, 1, true) then return false end
  end
  for _, s in ipairs(SCOPES) do
    if kind:find(s, 1, true) then return true end
  end
  return false
end

-- The innermost function / class / ... around (row, col), as { kind, name }.
local function symbol_at(buf, row, col)
  local okp, parser = pcall(vim.treesitter.get_parser, buf)
  if not (okp and parser) then return nil end
  pcall(function() parser:parse() end)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col } })
  if not ok then return nil end
  while node do
    local kind = node:type()
    if is_scope(kind) then
      local name = node:field("name")[1]
      if not name then
        for child in node:iter_children() do
          local t = child:type()
          if t == "identifier" or t == "dot_index_expression" or t == "method_index_expression" then name = child break end
        end
      end
      if name then return { kind = kind, name = vim.treesitter.get_node_text(name, buf) } end
    end
    node = node:parent()
  end
  return nil
end

-- `light` (the trail's and the input bar's label, which only name the file
-- and line) skips the branch, the symbol and the diagnostics: no git, no
-- parsing on every window switch.
-- `path` relative to directory `root`, "/"-separated, or nil when it isn't
-- inside it. Either may use Windows' "\\" and a drive letter in any case.
-- Pure.
function M.relative(root, path)
  local function norm(p) return (p:gsub("\\", "/"):gsub("/+$", ""):gsub("^(%a):", function(d) return d:lower() .. ":" end)) end
  root, path = norm(root), norm(path)
  if path:sub(1, #root + 1) ~= root .. "/" then return nil end
  return path:sub(#root + 2)
end

-- `path` with symlinks resolved; for a file not yet written, its directory's.
local function resolved(path)
  local real = vim.loop.fs_realpath(path)
  if real then return real end
  local dir = vim.loop.fs_realpath(vim.fs.dirname(path))
  return dir and (dir .. "/" .. vim.fs.basename(path)) or path
end

function M.code(win, sel, light)
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" then return nil end
  local cur = vim.api.nvim_win_get_cursor(win)
  local snap = { screen = "code", file = name, line = cur[1],
    code_line = vim.api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1] }
  if sel and sel.buf == buf then snap.selection_lines = sel.from .. "-" .. sel.to end
  snap.visible = vim.fn.line("w0", win) .. "-" .. vim.fn.line("w$", win)
  local root = git_root(name)
  if root then
    root = vim.loop.fs_realpath(root) or root
    snap.file = M.relative(root, resolved(name)) or name
  end
  if light then return snap end
  if root then snap.repo, snap.branch = root, git_branch(root) end
  snap.symbol = symbol_at(buf, cur[1] - 1, cur[2])
  local here, counts = {}, { errors = 0, warnings = 0 }
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.severity == vim.diagnostic.severity.ERROR then counts.errors = counts.errors + 1
    elseif d.severity == vim.diagnostic.severity.WARN then counts.warnings = counts.warnings + 1 end
    if d.lnum == cur[1] - 1 then
      here[#here + 1] = { severity = vim.diagnostic.severity[d.severity], line = d.lnum + 1, message = d.message }
    end
  end
  snap.diagnostics, snap.diagnostic_counts = here, counts
  snap.modified = vim.bo[buf].modified
  return snap
end

-- The title of the section cursor line `lnum` is in, from `titles` (row ->
-- section title, as a view rendered them), with a trailing " (N)" count
-- dropped; nil above the first one. Pure.
function M.section_at(titles, lnum)
  for i = lnum, 1, -1 do
    if titles[i] then return (titles[i]:gsub(" %(%d+%)$", "")) end
  end
  return nil
end

-- The short "on PR !101 · auth.py:12 · thread 5000" for `snap`: a sent
-- message's heading in the conversation, the input bar's label, the trail
-- of places you were. Nil when there's nothing to say. Pure.
function M.label(snap)
  if snap.error then return nil end
  local bits = {}
  if type(snap.pr) == "table" then bits[#bits + 1] = "PR !" .. tostring(snap.pr.id) end
  if type(snap.work_item) == "table" then bits[#bits + 1] = "#" .. tostring(snap.work_item.id) end
  if snap.file then
    local range = snap.line and (":" .. snap.line) or ""
    if snap.selection_lines then range = ":" .. snap.selection_lines end
    bits[#bits + 1] = vim.fn.fnamemodify(snap.file, ":t") .. range
  elseif snap.selection then
    bits[#bits + 1] = "a selection"
  end
  if type(snap.thread) == "table" then bits[#bits + 1] = "thread " .. tostring(snap.thread.id) end
  if snap.commit then bits[#bits + 1] = "commit " .. tostring(snap.commit):sub(1, 7) end
  if snap.plan_line then bits[#bits + 1] = "plan:" .. snap.plan_line
  elseif snap.plan then bits[#bits + 1] = "the plan" end
  if #bits > 0 then return "on " .. table.concat(bits, " \u{00B7} ") end
  if snap.screen and snap.screen ~= "other" and snap.screen ~= "unknown" then return "on the " .. snap.screen end
  return nil
end

-- The places you were, as labels, most recent first: remembered as you
-- leave a window, each once (going back moves it to the front), five at
-- most.
local trail = {}
local TRAIL_MAX = 5

function M.recent() return vim.deepcopy(trail) end
M._forget = function() trail, git_cache = {}, {} end  -- tests

-- Remembers where window `win` is. Floating windows (popups) and whatever
-- describes as nothing in particular (the chat panel, a scratch buffer)
-- aren't kept.
function M.remember(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return end
  local ok, label = pcall(function() return M.label(M.snapshot(win, nil, { no_trail = true, light = true })) end)
  if not (ok and label) then return end
  for i = #trail, 1, -1 do
    if trail[i] == label then table.remove(trail, i) end
  end
  table.insert(trail, 1, label)
  while #trail > TRAIL_MAX do table.remove(trail) end
end

vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
  group = vim.api.nvim_create_augroup("AzureCliChatView", { clear = true }),
  callback = function() M.remember(vim.api.nvim_get_current_win()) end,
})

-- The snapshot for `win` (default: the current window). `sel` ({ buf,
-- from, to, text }, from <CR> in visual mode) is handed to the describer,
-- which can say where it is (the reviewer maps it to file lines); the text
-- is added when the describer didn't.
function M.snapshot(win, sel, opts)
  local snap = M.describe(win, sel, opts and opts.light)
  -- Where you were before, minus where you are.
  if not (opts and opts.no_trail) and #trail > 0 then
    local here = M.label(snap)
    local recent = {}
    for _, l in ipairs(trail) do
      if l ~= here then recent[#recent + 1] = l end
    end
    if #recent > 0 then snap.recent = recent end
  end
  return snap
end

function M.describe(win, sel, light)
  win = win or vim.api.nvim_get_current_win()
  if not (win and vim.api.nvim_win_is_valid(win)) then return { screen = "unknown" } end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  -- A buffer showing a file under its own filetype (the change viewer's
  -- diffs) names its screen in vim.b.azure_cli_view instead.
  local key = vim.b[buf].azure_cli_view or ft
  local fn = views()[key]
  if not fn then
    local pr = reviewer_pr(win)
    if pr then
      key = "review:" .. pr
      fn = views()[key]
    end
  end
  if not fn then
    local okc, snap = pcall(M.code, win, sel, light)
    if okc and snap then
      if sel then snap.selection = sel.text end
      return snap
    end
    return { screen = "other", filetype = ft, selection = sel and sel.text or nil }
  end
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
    out[#out + 1] = "File: " .. snap.file .. (snap.line and (" line " .. snap.line
      .. (snap.side and (" (" .. (snap.side == "L" and "target" or "source") .. " side)") or "")) or "")
  end
  if snap.section then out[#out + 1] = "Section: " .. snap.section end
  if snap.commit then out[#out + 1] = "Commit: " .. snap.commit end
  if snap.comment_author then out[#out + 1] = "Comment by " .. snap.comment_author end
  if snap.repo then out[#out + 1] = "Repository: " .. snap.repo .. (snap.branch and (" (branch " .. snap.branch .. ")") or "") end
  if snap.code_line then out[#out + 1] = "Code on that line: " .. snap.code_line end
  if type(snap.symbol) == "table" then out[#out + 1] = "Inside: " .. snap.symbol.name .. " (" .. snap.symbol.kind .. ")" end
  for _, d in ipairs(type(snap.diagnostics) == "table" and snap.diagnostics or {}) do
    out[#out + 1] = "Diagnostic on this line (" .. tostring(d.severity) .. "): " .. tostring(d.message)
  end
  local dc = snap.diagnostic_counts
  if type(dc) == "table" and ((dc.errors or 0) > 0 or (dc.warnings or 0) > 0) then
    out[#out + 1] = "Diagnostics in the file: " .. (dc.errors or 0) .. " errors, " .. (dc.warnings or 0) .. " warnings"
  end
  if snap.modified then out[#out + 1] = "Unsaved changes in this buffer" end
  if snap.plan_line then
    out[#out + 1] = "Plan line " .. snap.plan_line .. (snap.plan_section and (" (section \"" .. snap.plan_section .. "\")") or "")
      .. ": " .. tostring(snap.plan_text or "")
  end
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
  if snap.visible then out[#out + 1] = "Visible: lines " .. snap.visible end
  if snap.note then out[#out + 1] = snap.note end
  if type(snap.recent) == "table" and #snap.recent > 0 then
    local r = {}
    for i, l in ipairs(snap.recent) do r[i] = (tostring(l):gsub("^on ", "")) end
    out[#out + 1] = "Recently: " .. table.concat(r, "; ")
  end
  return table.concat(out, "\n")
end

return M
