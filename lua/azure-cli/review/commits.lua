-- lua/azure-cli/review/commits.lua: per-commit diffs from the Overview's commit
-- list - a reviewer-feature module built on pr-review.lua's EXT extension
-- mechanism (see the comment at EXT's declaration there, and README's
-- "Extending the reviewer", for why this lives in its own require()'d module
-- instead of new code in pr-review.lua itself: that file is at LuaJIT's
-- 200-local ceiling for its main chunk).
--
-- Wired in by pr-review.lua's closing `do...end` block as
-- EXT.commits = require(this file)(ctx) - `ctx` is the surface pr-review.lua
-- exposes, plus the extra fields this module needed that weren't already on
-- it (see that block's comment for the full list): decorate_diff,
-- ft_for_path, parse_diff (CACHE.parse_diff), nav_show, nav_back,
-- mark_current_file, overview_commits (an accessor, since pr-review.lua
-- reassigns it once the background `git log` for the Overview's commit list
-- returns - see load_overview_commits there).
--
-- Like review/comments.lua, this file's `return` is a table with a
-- __call metamethod: `require(path)` alone leaves the pure helpers below
-- reachable without a real `ctx` (what tests/test-review-commits.lua does),
-- and `require(path)(ctx)` additionally wires everything into the reviewer.
--
-- What this adds:
--   * <CR> on a commit line in the Overview's "Commits (who pushed):" block
--     opens that commit's changed files (a small scratch buffer: one row
--     per changed path, its status letter from `git show --name-status`).
--   * <CR> on one of those opens that file's diff FOR THAT COMMIT ALONE
--     (`git diff <sha>^..<sha> -- path`, or for a root commit - which has no
--     `<sha>^` - `git show <sha> -- path`) in the diff window, decorated the
--     same way a normal diff is (line + word highlights via
--     ctx.decorate_diff), so the PR's own diff pane is untouched.
--   * `gc` (file list / diff pane) opens the same commit list as its own
--     buffer, for browsing without going via the Overview.
--   * `<BS>` throughout walks back one step (ctx.nav_back, the same stack
--     gd/gr/gf use), landing back on the Overview or the commit list it came
--     from; `q` walks all the way back to whatever's underneath.
--   * Comments never show in a commit diff - they're anchored to the PR's
--     final diff (target...source), not any one commit along the way - and
--     the winbar says so.
--
-- Per (sha, path) diffs, a commit's file list, and whether a sha is a root
-- commit are cached in module-level tables (fine here - this file is its own
-- function, not pr-review.lua's main chunk - see the 200-local comment
-- above), so re-opening any of them within the session is instant.

local UI = require("azure-cli.ui")

local M = {}

-- Buffers, keyed the way each surface naturally is: one commit-list buffer
-- for the whole PR, one file-list buffer per commit (by sha), one diff
-- buffer per (sha, path). buf_meta is the reverse index (bufnr -> { kind,
-- sha, path }) nav_restore (below) and the shared <BS>/q/gc keymaps read to
-- tell the three kinds apart and to know what to rebuild/show.
local commit_list_buf
local commit_files_bufs = {}      -- sha -> bufnr
local commit_diff_bufs  = {}      -- "sha\tpath" -> bufnr
local buf_meta          = {}      -- bufnr -> { kind = "list"|"files"|"diff", sha, path }
local files_line_paths  = {}      -- commit-files bufnr -> { [lnum] = path }
local is_root_cache     = {}      -- sha -> bool, from one `git rev-list --parents` per commit
local diff_content_cache = {}     -- "sha\tpath" -> { lines, map }

-- ---------------------------------------------------------------------------
-- Pure helpers - no vim/ctx, so tests/test-review-commits.lua exercises them
-- directly under plain luajit.

-- Parses one raw commit summary the way `git log --format="%h  %ad  %an: %s"`
-- prints it (no leading whitespace) - exactly what ctx.overview_commits()
-- holds, and load_overview_commits in pr-review.lua fetches the Overview's
-- own "Commits (who pushed):" block from - into
-- { sha, date, author, subject }. Returns nil if `raw` doesn't have that
-- shape.
function M.parse_commit(raw)
  local sha, date, rest = (raw or ""):match("^(%x+)  (%d%d%d%d%-%d%d%-%d%d)  (.*)$")
  if not sha then return nil end
  local author, subject = rest:match("^(.-): (.*)$")
  return { sha = sha, date = date, author = author or rest, subject = subject or "" }
end

-- Recognises a commit row exactly as the Overview page renders one (build_overview:
-- `lines[#lines + 1] = "  " .. c`) - two spaces, then M.parse_commit's shape - and
-- this module's own commit-list buffer renders its rows the same way. Returns
-- the short sha, or nil if `line` isn't that shape.
function M.commit_line_sha(line)
  local rest = (line or ""):match("^  (.*)$")
  local c = rest and M.parse_commit(rest)
  return c and c.sha
end

-- Finds the commit under cursor line `lnum` of the Overview page's OWN
-- rendered lines (as ctx.build_overview() returns them): nil unless `lnum`
-- falls inside the "Commits (who pushed):" block AND that line has a
-- commit's shape. Scoping to the block, not just the line's shape, means a
-- description or comment line that happens to start with two spaces, a hex
-- run and something date-shaped can never be mistaken for a commit row.
function M.overview_commit_at(lines, lnum)
  local start
  for i, l in ipairs(lines or {}) do
    if l == "Commits (who pushed):" then
      start = i + 1
      break
    end
  end
  if not start then return nil end
  local i = start
  while lines[i] and lines[i] ~= "" do
    if i == lnum then return M.commit_line_sha(lines[i]) end
    i = i + 1
  end
  return nil
end

-- Parses `git show --format= --name-status <sha>` output into a list of
-- { status, path }, one per changed file. A rename/copy line has 3
-- tab-separated fields (e.g. "R100<TAB>old<TAB>new"); the destination path -
-- what the file is called after this commit - is what's kept, and `status`
-- is always just its leading letter (R100 -> "R").
function M.parse_name_status(lines)
  local out = {}
  for _, l in ipairs(lines or {}) do
    if l ~= "" then
      local status, rest = l:match("^(%S+)\t(.*)$")
      if status then
        local _, dest = rest:match("^(.-)\t(.*)$")
        out[#out + 1] = { status = status:sub(1, 1), path = (dest and dest ~= "") and dest or rest }
      end
    end
  end
  return out
end

-- Whether `sha` is a root commit (no parents), from the one-line output of
-- `git rev-list --parents -n1 <sha>` (the commit's own sha, then its
-- parents', space-separated - so a root commit's line is just the one sha).
-- A root commit has no `<sha>^`, so its per-file diff needs `git show`
-- instead of `git diff <sha>^..<sha>` (see build_commit_diff below).
function M.is_root_commit(parents_line)
  local n = 0
  for _ in (parents_line or ""):gmatch("%S+") do n = n + 1 end
  return n <= 1
end

-- ---------------------------------------------------------------------------
-- ctx-dependent setup, wired in from pr-review.lua's closing block.

-- Finds `sha`'s subject from ctx.overview_commits() (the same array the
-- Overview's block renders from), or nil if it isn't loaded yet or the sha
-- isn't in range (origin/target..origin/source) for some reason.
local function commit_subject(ctx, sha)
  local commits = ctx.overview_commits()
  if not commits then return nil end
  for _, raw in ipairs(commits) do
    local c = M.parse_commit(raw)
    if c and c.sha == sha then return c.subject end
  end
  return nil
end

-- Winbar text for one of this module's buffers, from its buf_meta - built
-- through UI.winbar (lua/azure-cli/ui.lua) like every other surface's now:
-- context (what commit/file you're looking at), then tags, then "?: help" -
-- see the module comment above for why a commit diff's tag notes comments
-- aren't shown there (they anchor to the PR's final diff, not any one
-- commit along the way).
local function winbar_for(ctx, buf)
  local meta = buf_meta[buf]
  if not meta then return nil end
  if meta.kind == "list" then
    local commits = ctx.overview_commits()
    local parts = { "Commits", "PR #" .. ctx.ID }
    if commits then parts[#parts + 1] = #commits .. " commits" end
    return UI.winbar(parts, {})
  elseif meta.kind == "files" then
    return UI.winbar({ "commit " .. meta.sha, commit_subject(ctx, meta.sha) or "" }, {})
  elseif meta.kind == "diff" then
    return UI.winbar({ "commit " .. meta.sha, meta.path, commit_subject(ctx, meta.sha) or "" },
      { "(no comments shown)" })
  end
  return nil
end

-- Sets the winbar for one of this module's buffers and clears the file-list
-- "current file" highlight (none of these are a real file or the Overview).
-- Called both right after opening one (ctx.nav_show) and from nav_restore
-- (below) when <BS>/nav_back lands back on one.
local function set_chrome(ctx, buf)
  local dw = ctx.diff_win()
  if not (dw and vim.api.nvim_win_is_valid(dw)) then return end
  local bar = winbar_for(ctx, buf)
  if bar then UI.wo(dw, "winbar", bar) end
  if ctx.mark_current_file then ctx.mark_current_file(nil) end
end

-- Pops ctx.nav_back() until the diff window shows something outside this
-- module's own buffers (a real diff, the Overview, or a revision buffer) -
-- mirrors pr-review.lua's own nav_back_to_diff for the revision-buffer
-- stack, just scoped to buf_meta instead of nav_meta.
local function back_to_root(ctx)
  local dw = ctx.diff_win()
  -- Bounded defensively: every push onto the shared nav_stack a step into
  -- this module makes has a matching pop back out of it, so this always
  -- terminates well under the cap in normal use - the cap just keeps a
  -- future bug elsewhere on the shared stack from hanging nvim here.
  local guard = 0
  while dw and vim.api.nvim_win_is_valid(dw) and buf_meta[vim.api.nvim_win_get_buf(dw)] and guard < 100 do
    ctx.nav_back()
    guard = guard + 1
  end
end

local function show_commit_help(ctx, kind)
  local lines = { "Commit " .. kind .. " keys", "", "  j / k      move" }
  if kind == "list" then
    vim.list_extend(lines, {
      "  <CR>       open the commit's changed files",
    })
  elseif kind == "files" then
    vim.list_extend(lines, {
      "  <CR>       open this file's diff for the commit alone",
      "  gc         open the PR's commit list",
    })
  else
    vim.list_extend(lines, {
      "  gc         open the PR's commit list",
    })
  end
  vim.list_extend(lines, {
    "  <BS>       back",
    "  q          back to the diff/Overview",
    "  ?          this help",
  })
  if kind == "diff" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Comments aren't shown here - they anchor to the PR's final diff"
    lines[#lines + 1] = "(target...source), not any single commit along the way."
  end
  ctx.open_float(lines, true, { min_width = 50 })
end

local open_commit_list, open_commit_files, open_commit_diff  -- forward-declared: mutually referenced by keymaps below

-- Builds (or serves from diff_content_cache) the diff for `path` as changed
-- BY `sha` alone. Root commits (no `<sha>^`) fall back to `git show`; every
-- other commit is diffed against its parent. `is_root_cache[sha]` is filled
-- once per commit (a single `git rev-list --parents` covers every file in
-- it), not once per file.
local function build_commit_diff(ctx, sha, path, cb)
  local key = sha .. "\t" .. path
  local cached = diff_content_cache[key]
  if cached then
    cb(cached.lines, cached.map)
    return
  end
  local function fetch(is_root)
    local args = is_root
      and ctx.git_args("show", "--format=", "--unified=100000", sha, "--", path)
      or ctx.git_args("diff", "--unified=100000", sha .. "^.." .. sha, "--", path)
    local out = {}
    vim.fn.jobstart(args, {
      stdout_buffered = true,
      on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
      on_exit = function(_, _code)
        vim.schedule(function()
          local lines, map = ctx.parse_diff(out)
          diff_content_cache[key] = { lines = lines, map = map }
          cb(lines, map)
        end)
      end,
    })
  end
  if is_root_cache[sha] ~= nil then
    fetch(is_root_cache[sha])
    return
  end
  local pout = {}
  vim.fn.jobstart(ctx.git_args("rev-list", "--parents", "-n1", sha), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(pout, d) end end,
    on_exit = function(_, _code)
      vim.schedule(function()
        local root = M.is_root_commit(pout[1])
        is_root_cache[sha] = root
        fetch(root)
      end)
    end,
  })
end

local function setup_diffbuf_keymaps(ctx, buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<BS>", function() ctx.nav_back() end, opts)
  vim.keymap.set("n", "gc", function() open_commit_list(ctx) end, opts)
  vim.keymap.set("n", "q", function() back_to_root(ctx) end, opts)
  vim.keymap.set("n", "?", function() show_commit_help(ctx, "diff") end, opts)
end

-- Loads (or reuses) the read-only diff buffer for `path` as changed by `sha`
-- alone, fetching its content in the background on a miss (a "Loading…"
-- placeholder shows meanwhile, same idea as pr-review.lua's own open_file).
local function ensure_commit_diff_buf(ctx, sha, path)
  local key = sha .. "\t" .. path
  local buf = commit_diff_bufs[key]
  if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = ctx.ft_for_path(path) or "text"
  buf_meta[buf] = { kind = "diff", sha = sha, path = path }
  commit_diff_bufs[key] = buf
  setup_diffbuf_keymaps(ctx, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading commit diff\u{2026}" })
  vim.bo[buf].modifiable = false
  build_commit_diff(ctx, sha, path, function(lines, map)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    ctx.decorate_diff(buf, lines, map)
  end)
  return buf
end

open_commit_diff = function(ctx, sha, path)
  local buf = ensure_commit_diff_buf(ctx, sha, path)
  ctx.nav_show(buf)
  set_chrome(ctx, buf)
end

local function setup_files_keymaps(ctx, buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local path = (files_line_paths[buf] or {})[lnum]
    if not path then
      ctx.notify("Not a file line.", vim.log.levels.WARN)
      return
    end
    open_commit_diff(ctx, buf_meta[buf].sha, path)
  end, opts)
  vim.keymap.set("n", "<BS>", function() ctx.nav_back() end, opts)
  vim.keymap.set("n", "gc", function() open_commit_list(ctx) end, opts)
  vim.keymap.set("n", "q", function() back_to_root(ctx) end, opts)
  vim.keymap.set("n", "?", function() show_commit_help(ctx, "files") end, opts)
end

-- Loads (or reuses) the file-list buffer for `sha`, fetching
-- `git show --format= --name-status <sha>` in the background on a miss.
local function ensure_commit_files_buf(ctx, sha)
  local buf = commit_files_bufs[sha]
  if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  buf_meta[buf] = { kind = "files", sha = sha }
  commit_files_bufs[sha] = buf
  setup_files_keymaps(ctx, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading " .. sha .. "\u{2026}" })
  vim.bo[buf].modifiable = false
  local out = {}
  vim.fn.jobstart(ctx.git_args("show", "--format=", "--name-status", sha), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, _code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local entries = M.parse_name_status(out)
        local subject = commit_subject(ctx, sha)
        local lines = { "[" .. sha .. "] " .. (subject or ""), "" }
        local line_paths = {}
        if #entries == 0 then
          lines[#lines + 1] = "  (no file changes)"
        else
          for _, e in ipairs(entries) do
            lines[#lines + 1] = string.format("  %s  %s", e.status, e.path)
            line_paths[#lines] = e.path
          end
        end
        files_line_paths[buf] = line_paths
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
      end)
    end,
  })
  return buf
end

open_commit_files = function(ctx, sha)
  local buf = ensure_commit_files_buf(ctx, sha)
  ctx.nav_show(buf)
  set_chrome(ctx, buf)
end

local function setup_list_keymaps(ctx, buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    local sha = M.commit_line_sha(line)
    if not sha then
      ctx.notify("Not a commit line.", vim.log.levels.WARN)
      return
    end
    open_commit_files(ctx, sha)
  end, opts)
  vim.keymap.set("n", "<BS>", function() ctx.nav_back() end, opts)
  vim.keymap.set("n", "gc", function() open_commit_list(ctx) end, opts)
  vim.keymap.set("n", "q", function() back_to_root(ctx) end, opts)
  vim.keymap.set("n", "?", function() show_commit_help(ctx, "list") end, opts)
end

-- (Re)renders the commit-list buffer in place - cheap and pure in-memory
-- (reads ctx.overview_commits(), never fetches), so safe to call every time
-- it's shown in case the background `git log` finished since it was built.
local function render_commit_list(ctx, buf)
  local commits = ctx.overview_commits()
  local lines = { "PR #" .. ctx.ID .. " commits (" .. ctx.SOURCE .. " -> " .. ctx.TARGET .. ")", "" }
  if commits == nil then
    lines[#lines + 1] = "  (loading\u{2026})"
  elseif #commits == 0 then
    lines[#lines + 1] = "  (none found - branch may not be fetched yet)"
  else
    for _, c in ipairs(commits) do
      lines[#lines + 1] = "  " .. c
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function ensure_commit_list_buf(ctx)
  if commit_list_buf and vim.api.nvim_buf_is_valid(commit_list_buf) then return commit_list_buf end
  commit_list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[commit_list_buf].buftype = "nofile"
  vim.bo[commit_list_buf].filetype = "markdown"
  buf_meta[commit_list_buf] = { kind = "list" }
  setup_list_keymaps(ctx, commit_list_buf)
  return commit_list_buf
end

open_commit_list = function(ctx)
  local buf = ensure_commit_list_buf(ctx)
  render_commit_list(ctx, buf)
  ctx.nav_show(buf)
  set_chrome(ctx, buf)
end

local function setup(ctx)
  ctx.add_key("overview", "open_commit", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local lines = (ctx.build_overview())
    local sha = M.overview_commit_at(lines, lnum)
    if not sha then return end  -- Overview binds no other <CR> today - nothing to fall back to.
    open_commit_files(ctx, sha)
  end, "open the commit under the cursor's changed files")

  ctx.add_key("list", "commits", function() open_commit_list(ctx) end, "open the PR's commit list")
  ctx.add_key("diff", "commits", function() open_commit_list(ctx) end, "open the PR's commit list")

  -- nav_restore_chrome (pr-review.lua) falls back to this for a buffer none
  -- of its own kinds recognise, right after ctx.nav_back() lands on it - see
  -- that function's comment.
  M.nav_restore = function(buf)
    if not buf_meta[buf] then return false end
    set_chrome(ctx, buf)
    return true
  end

  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
