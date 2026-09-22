-- lua/azure-cli/review/init.lua: Neovim PR reviewer.
--
-- Opened in-session by the dashboard (a new tab of the same nvim, via
-- require("azure-cli.review").open()) once the PR's branches are warm, or
-- directly by :AzureCli review <id> (lua/azure-cli/init.lua's open_review).
-- M.open() (re)builds the whole reviewer - file list, diff pane, Overview,
-- every keymap - so re-opening a PR within the same session starts fresh,
-- the same reset a `:luafile` re-source used to give for free; everything
-- below that used to be a module-level local declared once now lives
-- inside this one function's body instead (see init.lua's own header
-- comment for why require() needs this).
--
-- Consumes the AZVICLI_* environment variables and drives the whole review
-- inside Neovim with native vim navigation: a file list on the left (its
-- first row is always "Overview" - title, description, who pushed, and the
-- PR-level comments, opened by default) and the selected row's content on
-- the right (a file's full diff, fetched in the background and cached across
-- both this session and future ones for the same PR version so switching is
-- instant; or the Overview page), with inline commenting on the line/thread
-- under the cursor either way.
--
-- Keys
--   file list :  j/k move   <CR> open & focus   q quit
--                (row 1 is always "Overview"; files are the rest)
--   diff pane :  j/k/C-d/C-u move   ]c / [c next/prev change, crossing into the
--                next/previous file once the current one runs out
--                c  comment on the current line
--                c (visual mode)  comment on the selected range of lines
--                C  comment on the whole file (not tied to a line)
--                <BS> or C-w h  back to file list      q quit
--   Overview  :  c new PR-level comment   R reply   s set status   e/dd edit
--                or delete a comment of yours (on the thread/comment under
--                the cursor)   ]C/[C jump between threads - same keys as a
--                regular file's diff, just without ]c/[c (there's no diff to
--                jump changes in)
--   gA        :  toggle showing only active (unresolved) comments, hiding
--                fixed/won't-fix/closed ones (list + diff pane + Overview)
--   gF        :  manage text filters in a popup — a: add, p: toggle persistent
--                (survives across sessions/PRs), s: set a status on every
--                comment matching the filter under cursor (runs in the
--                background), dd/x: remove, q/<Esc>: close; hides threads
--                whose first comment contains any added string
--   gw        :  toggle ignoring whitespace in every diff shown (file list,
--                diff pane, Overview); persists for the rest of the session
--   gO        :  open azure-cli.yml (accounts/PAT/clones_dir config) in a new tab
--   gi        :  toggle "changes since my last review" - shows only the file
--                list/diffs for what's been pushed since your last comment or
--                vote on this PR, with target-side ("L") comments hidden
--                (list + diff pane + Overview)
--   gu        :  follow up on my comments - a picker of every thread I
--                started (source-side ones tagged changed/unchanged, a
--                target-side one n/a) for whether anything landed nearby
--                since my last review; <CR> opens the file on that line, K
--                shows the thread, R replies, s sets status (list + diff
--                pane + Overview)
--   gB        :  toggle batch review for this PR: while on, comments/replies
--                queue instead of sending right away (tagged "(queued)");
--                gQ lists the queue (dd removes an item), gS submits it all
--                with a vote (list + diff pane + Overview)
--   K         :  view comment(s) on the current line (in a regular file) in a
--                large float; R/s inside it reply / set status, e/dd edit /
--                delete a comment of yours, without closing the popup
--   gd / gr   :  go to the definition of / find references to the word under
--                the cursor, across the whole repo at the PR's revision (no
--                checkout or LSP needed: git grep + a definition heuristic).
--                Results show in a peek view - hits on the left, the file at
--                that revision previewed on the right as you move - and open
--                read-only at that revision on <CR>; keep pressing gd/gr
--                there to follow further, <BS> walks back one jump.
--   gf        :  open the current file at the PR's revision (read-only, on
--                the same line) to read around the change
--   gc        :  open the PR's commit list (file list / diff pane); <CR> on a
--                commit there, or on one in the Overview's "Commits (who
--                pushed):" block, shows its changed files, and <CR> on one of
--                those its diff for that commit alone (no comments - they
--                anchor to the PR's final diff, not a single commit)
--   g/        :  search text across the PR's changed files at the source
--                branch (git grep, case-insensitive unless the text has an
--                uppercase letter); hits show in the same peek view as
--                gd/gr, prefilled with the last search this session.
--   ?         :  show the keys for whichever buffer you're in (file list,
--                diff pane, Overview, or a revision buffer)

-- Shared per-PR content caches + prefetch pipeline.
local CACHE = require("azure-cli.cache")
local STATE = require("azure-cli.state")
local KEYS = require("azure-cli.keys")
local UI = require("azure-cli.ui")
-- Every surface's winbar-hint/help-line ordered action tables (see the
-- setup_*_keymaps/show_*_help/set_*_winbar functions below) live as fields
-- on this one table instead of their own top-level locals - this file is
-- already at LuaJIT's 200-local ceiling for its main chunk (see the
-- comment at EXT's own declaration), so a field costs nothing further.
local HELP = {}

local M = {}

function M.open()

local env       = vim.env
local ID        = env.AZVICLI_PR or "?"
local ORG       = env.AZVICLI_ORG or ""
local PROJECT   = env.AZVICLI_PROJECT or ""
local SOURCE    = env.AZVICLI_SOURCE or ""
local TARGET    = env.AZVICLI_TARGET or ""
local EXE       = env.AZVICLI_EXE or ""
-- Local clone the diffs come from. Normalise "/c/..." to "c:/..." so the
-- native git.exe understands it when we pass it via `git -C`.
local REPO_PATH = (env.AZVICLI_REPO_PATH or ""):gsub("^/([a-zA-Z])/", "%1:/")
-- When launched inside the running dashboard nvim (not as its own process),
-- quitting must close only this reviewer's tab, not the whole editor.
local EMBED     = env.AZVICLI_EMBED == "1"
local RANGE     = "origin/" .. TARGET .. "...origin/" .. SOURCE

-- Build a git argv rooted at the repo clone (cwd is not the clone when embedded).
local function git_args(...)
  local a = { "git" }
  if REPO_PATH ~= "" then
    a[#a + 1] = "-C"
    a[#a + 1] = REPO_PATH
  end
  for _, v in ipairs({ ... }) do
    a[#a + 1] = v
  end
  return a
end

-- Leave the reviewer: close the tab when embedded, else quit nvim. The
-- timers and scratch buffers this reviewer created go with it
-- (EXT.cleanup, assigned near the end of this file once everything it
-- has to reach exists) - they used to linger until their next tick /
-- forever.
local function leave(force)
  local function go()
    if STATE.review_cleanup then pcall(STATE.review_cleanup) end
    if EMBED then
      pcall(vim.cmd, "tabclose")
    else
      vim.cmd("qa!")
    end
  end
  if force == true then
    go()
    return
  end
  -- Queued batch items and cancelled-comment drafts live in memory: fine
  -- to close a tab over (they're still there when the PR is reopened this
  -- session), lost with the process in standalone mode - either way, say
  -- so before closing rather than after.
  local queued = (STATE.batch and STATE.batch[ID] and STATE.batch[ID].items) and #STATE.batch[ID].items or 0
  local drafts = 0
  for k in pairs(STATE.editor_drafts or {}) do
    if k:sub(1, #ID + 1) == ID .. "\0" then drafts = drafts + 1 end
  end
  if queued == 0 and drafts == 0 then
    go()
    return
  end
  local what = {}
  if queued > 0 then what[#what + 1] = queued .. " queued comment" .. (queued == 1 and "" or "s") .. " (gS submits)" end
  if drafts > 0 then what[#what + 1] = drafts .. " unsent draft" .. (drafts == 1 and "" or "s") end
  require("azure-cli.prompt").confirm({
    prompt = "PR #" .. ID .. " has " .. table.concat(what, " and ")
      .. (EMBED and ". Close the reviewer? (kept until Neovim exits)" or ". Quit? (they will be lost)"),
    yes = EMBED and "Close" or "Quit", no = "Stay",
  }, function(yes) if yes then go() end end)
end

-- Per-buffer state (kept in Lua tables to avoid vimscript serialization).
local maps_by_buf  = {}   -- diff bufnr -> { [bufline] = { side, lineno } }
local paths_by_buf = {}   -- diff bufnr -> repo-relative path
local diff_cache   = {}   -- path -> { buf, map }

-- Existing PR comments, fetched once at startup from Azure DevOps.
local threads_by_key      = {}   -- "path\tside\tlineno" -> { {status, comments}, ... }
local file_threads_by_path = {}  -- path -> file-level threads (no line anchor)
local general_threads     = {}   -- PR-level threads not anchored to a file
local comments_ns         = vim.api.nvim_create_namespace("azure_cli_comments")
local diff_ns             = vim.api.nvim_create_namespace("azure_cli_diff")
local comments_by_buf     = {}   -- diff bufnr -> { [bufline] = { {status, comments}, ... } }

-- Sentinel "path" used to mark the diff pane as showing the PR Overview page
-- (title/description/who-pushed/comments) rather than a real file's diff -
-- passed to mark_current_file/open_overview instead of a file path.
local OVERVIEW_MARK = {}

-- My identity (GUID + display name), resolved once via `azure-cli.exe --whoami`
-- and cached process-wide (identity never changes across PRs/sessions on the
-- same machine) so every future review avoids the extra round-trip. Used to
-- tell "my" threads/comments apart from everyone else's for new-comment
-- notifications: only comments on my own PR, on threads I've participated in,
-- or replies to my own comments should ever notify.
local my_id = nil
local function resolve_my_identity(on_done)
  STATE.whoami = STATE.whoami or {}
  local cache_key = ORG .. "|" .. PROJECT
  local cached = STATE.whoami[cache_key]
  if cached then
    my_id = cached.id
    if on_done then on_done() end
    return
  end
  -- The list feed (--list) already carries the identity each PR was fetched
  -- as; the dashboard hands the record over in STATE.PR_CURRENT. Using it here
  -- saves a --whoami spawn (a .NET start-up plus an ADO round-trip) per org.
  local rec = STATE.PR_CURRENT
  if rec and tostring(rec.id) == tostring(ID) and rec.myId and rec.myId ~= "" then
    STATE.whoami[cache_key] = { id = rec.myId, displayName = rec.myName or "" }
    my_id = rec.myId
    if on_done then on_done() end
    return
  end
  if EXE == "" or ORG == "" then
    if on_done then on_done() end
    return
  end
  local out = {}
  vim.fn.jobstart({ EXE, "--whoami", "--org", ORG, "--project", PROJECT }, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        local line = table.concat(out, "")
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" and rec.id then
          STATE.whoami[cache_key] = rec
          my_id = rec.id
        end
      end
      if on_done then on_done() end
    end,
  })
end

-- Kick this off immediately (async, non-blocking) so `my_id` is populated by
-- the time the first periodic poll runs, without delaying the reviewer's open.
resolve_my_identity()

-- Toggle: when true, every comment surface (gutter markers, K/R/s, ]C/[C, the
-- Overview page) only shows threads whose status is "active", hiding
-- fixed/won't-fix/closed ones. Flip with gA. Also affects the per-file
-- closed/total counts in the file list (both drop non-active threads).
local active_only = false

-- Toggle: when true, every diff (file list previews, the diff pane, and the
-- per-file build the code-navigation revision buffers decorate with) is
-- built with `git diff --ignore-all-space` instead of a plain diff. Flip
-- with gw. Kept in _G (like the whoami/badge-timer state below) so it
-- survives re-opening a PR within the same nvim session.
local ignore_ws = STATE.ignore_ws or false

-- Where persistent text filters are saved (nvim's per-user data dir), shared
-- across every PR review session on this machine.
local FILTERS_FILE = vim.fn.stdpath("data") .. "/azure-cli-comment-filters.json"

-- Reads the persisted filter strings from disk, or {} if none/unreadable.
-- Migrates the pre-rename data file (this plugin was once called pr-dash,
-- see migrate.lua) into FILTERS_FILE the first time it's needed, then
-- leaves it alone.
local function load_persistent_filters()
  require("azure-cli.migrate").ensure(vim.fn.stdpath("data") .. "/pr-dash-comment-filters.json", FILTERS_FILE)
  if vim.fn.filereadable(FILTERS_FILE) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, FILTERS_FILE)
  if not ok then return {} end
  local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok2 and type(decoded) == "table" then return decoded end
  return {}
end

-- Writes every currently-persistent filter's text to disk.
local function save_persistent_filters(ignore_texts)
  local texts = {}
  for _, f in ipairs(ignore_texts) do
    if f.persistent then texts[#texts + 1] = f.text end
  end
  pcall(vim.fn.writefile, { vim.json.encode(texts) }, FILTERS_FILE)
end

-- Text filters: threads whose FIRST comment contains ANY of these substrings
-- (case-insensitive) are hidden everywhere active_only is applied too — e.g.
-- a recurring boilerplate/bot comment like "Complete the task associated to
-- this 'TODO' comment" that you want out of the way. Managed via the gF popup
-- (add/remove multiple, tag individual ones as persistent with `p` so they
-- survive across sessions/PRs). Each entry is { text = "...", persistent = bool }.
local ignore_texts = {}
for _, text in ipairs(load_persistent_filters()) do
  ignore_texts[#ignore_texts + 1] = { text = text, persistent = true }
end

-- True when `t`'s first comment contains any entry in ignore_texts (case-insensitive).
local function thread_is_ignored(t)
  if #ignore_texts == 0 then return false end
  local c = t.comments and t.comments[1]
  local content = c and c.content
  if not content then return false end
  content = content:lower()
  for _, f in ipairs(ignore_texts) do
    if content:find(f.text, 1, true) then return true end
  end
  return false
end

-- All threads (across every file, line, and PR-level comment) whose first
-- comment contains `needle` (case-insensitive), regardless of active_only or
-- any other filter — used by the "set status for all matches" bulk action so
-- it always targets every comment matching the rule, not just currently-shown
-- ones.
local function threads_matching_text(needle)
  local matches = {}
  local function scan(list)
    for _, t in ipairs(list or {}) do
      local c = t.comments and t.comments[1]
      local content = c and c.content
      if content and content:lower():find(needle, 1, true) then
        matches[#matches + 1] = t
      end
    end
  end
  for _, list in pairs(threads_by_key) do scan(list) end
  for _, list in pairs(file_threads_by_path) do scan(list) end
  scan(general_threads)
  return matches
end

-- Winbar tag for the active text filters, or "" when none are set - one of
-- the bracketed strings UI.winbar's `tags` list takes (see set_list_winbar_impl/
-- set_diff_winbar below), so no leading space of its own.
local function ignore_texts_tag()
  if #ignore_texts == 0 then return "" end
  if #ignore_texts == 1 then return "[hiding: " .. ignore_texts[1].text .. "]" end
  return "[hiding " .. #ignore_texts .. " filters]"
end

-- True when `t` passes the current active-only / text filters (i.e. it would
-- be shown). Shared by `filtered()` (bulk list filtering) and the new-comment
-- notifier, so a thread hidden by a filter never triggers a notification either.
local function passes_filters(t)
  return (not active_only or t.status == "active") and not thread_is_ignored(t)
end

-- Returns `list` with non-active and/or ignored-text threads dropped
-- (depending on which filters are on), otherwise `list` unchanged (nil-safe).
local function filtered(list)
  if not list then return list end
  if not active_only and #ignore_texts == 0 then return list end
  local out = {}
  for _, t in ipairs(list) do
    if passes_filters(t) then
      out[#out + 1] = t
    end
  end
  return out
end

local list_win, diff_win
local nav_goto_definition, nav_find_references, nav_open_file, nav_search_files  -- code navigation (gd/gr/gf/g-slash); assigned once the nav block exists.
local fit_list_width   -- defined once the list window exists; re-fits its width.
local refresh_threads  -- re-fetches PR threads and re-decorates; assigned below.
local redraw_after_write  -- redraws every thread surface after an optimistic write; assigned below.
local set_list_winbar  -- rebuilds the file-list winbar; assigned once it exists.
local toggle_active_filter  -- flips active_only and redraws everything; assigned below.
local toggle_ignore_ws      -- flips ignore_ws and rebuilds the diffs on screen; assigned below.
local manage_ignore_texts   -- opens the add/remove text-filter popup; assigned below.
local refresh_file_rows  -- re-renders file-list rows with fresh counts; assigned once it exists.
local mark_current_file  -- highlights the file-list row for the shown diff; assigned once it exists.

-- pr-review.lua's main chunk sits at LuaJIT's hard limit of 200 active local
-- variables (luajit -bl fails past it - see tests/run.sh's syntax check and
-- README's Development section). This is the ONE remaining slot, spent once,
-- here, for good: every future reviewer feature (edit/delete comments below,
-- and whatever comes after) hangs off this single table instead of adding
-- its own top-level local. EXT.keys.<kind> / EXT.help.<kind> (kind is
-- "list" | "diff" | "overview" | "nav") are lists of { key, fn, desc }
-- consumed by the four keymap setup sites (the file-list `lopts` block,
-- setup_diff_keymaps, setup_overview_keymaps, setup_nav_keymaps) and their
-- `?` popups; a module registers into them via ctx.add_key, never by
-- declaring its own `local` here (see the closing `do...end` block at the
-- end of this file, which builds `ctx` and dofile()s each module).
-- EXT.notify / EXT.comments hold the loaded modules themselves.
-- EXT.on_comment_popup is a callback list show_comments_here (the K popup)
-- invokes with (fbuf, threads) after opening its float, since that surface
-- is a fresh buffer per view rather than one persistent buffer like the
-- other three, so it can't be reached through EXT.keys.*.
local EXT = { keys = { list = {}, diff = {}, overview = {}, nav = {} },
              help = { list = {}, diff = {}, overview = {}, nav = {} } }
EXT.on_comment_popup = {}
-- EXT.rpc is the shared daemon client for the data provider (azure-cli.py
-- --serve - see rpc.lua's own header comment): every
-- vim.fn.jobstart(EXT.provider(...), opts) below becomes
-- EXT.rpc.run(EXT.provider(...), opts) instead, which sends the request to
-- the already-running daemon when one is usable and falls back to a plain
-- jobstart otherwise. A statement, not a new top-level local - see EXT's
-- own comment above.
EXT.rpc = require("azure-cli.rpc")
-- EXT.provider builds the argv every PR-action/prefetch job runs: the
-- python data provider (azure-cli.py) directly, next to review-pr.sh's
-- old $BASH/$SCRIPT pair. AZVICLI_PY/AZVICLI_PROVIDER are exported by the
-- launcher (azure-cli.py's launch_dashboard); when nvim was started by
-- hand instead they default to whichever of python3/python
-- vim.fn.executable finds, and to azure-cli.py at the plugin root
-- (config.lua's provider_cmd - the same resolution the dashboard and
-- work-items surfaces use). A statement, not a new top-level local - see
-- EXT's own comment above.
EXT.provider = function(args)
  local argv = require("azure-cli.config").provider_cmd()
  for _, v in ipairs(args) do
    argv[#argv + 1] = v
  end
  return argv
end


local function notify(msg, level)
  require("azure-cli.notify").flash(msg, level or vim.log.levels.INFO)
end

-- Resolve azure-cli.yml's path - delegates to config.lua's M.config_path()
-- (AZVICLI_CONFIG override, else the platform default) so gO always opens
-- exactly what the provider itself would read. No new top-level local
-- here (this file is at LuaJIT's 200-local ceiling - see README's
-- "Extending the reviewer" section): require()'d inline, same as
-- EXT.provider below.
local function config_path()
  return require("azure-cli.config").config_path()
end

-- Open azure-cli.yml (accounts/PAT/clones_dir config) in a new tab for quick editing.
local function open_config_file()
  local notice = require("azure-cli.config").setup_accounts_notice()
  if notice then
    notify(notice)
    return
  end
  local path = config_path()
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "yaml"
  if vim.fn.filereadable(path) == 0 then
    notify("azure-cli.yml doesn't exist yet — save this buffer (:w) to create it at " .. path, vim.log.levels.WARN)
  end
end

-- Enable word-aware wrapping on a floating window so long comment/description
-- text always fits inside it (wraps at word boundaries, wrapped continuation
-- lines keep the original indent) instead of being clipped or requiring
-- horizontal scroll. Mirrors the file list's auto-fit-to-content idea, just
-- via wrapping since prose can't be width-capped the way file paths are.
local function set_float_wrap(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  UI.wo(win, "wrap", true)
  UI.wo(win, "linebreak", true)
  UI.wo(win, "breakindent", true)
end

-- Widen/narrow the file-list split (clamped to a usable minimum).
local function resize_list(delta)
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    local w = math.max(20, vim.api.nvim_win_get_width(list_win) + delta)
    pcall(vim.api.nvim_win_set_width, list_win, w)
  end
end

-- Parse the Azure DevOps threads JSON (from the --threads subcommand) into
-- the given target tables (keyed the same way as threads_by_key /
-- file_threads_by_path / general_threads). Indexes file-anchored threads by
-- path/side/line so they render next to the matching diff lines. System
-- comments (votes, policy, etc.) and empty/deleted comments are ignored.
-- Building into caller-supplied tables (rather than always mutating the
-- module-level ones) lets refresh_threads parse each poll into a scratch copy
-- and diff it against the previous snapshot before swapping it in, instead of
-- wiping and rebuilding the live tables unconditionally on every poll.
local function parse_threads(json, by_key, file_by_path, general)
  if not json or json:gsub("%s", "") == "" then
    return
  end
  local ok, decoded = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return
  end
  local list = decoded.value or decoded
  if type(list) ~= "table" then
    return
  end

  for _, thread in ipairs(list) do
    local comments = {}
    for _, c in ipairs(thread.comments or {}) do
      local ctype = c.commentType
      if ctype ~= "system" and type(c.content) == "string" and c.content:gsub("%s", "") ~= "" then
        comments[#comments + 1] = {
          id = c.id,
          author = (c.author and c.author.displayName) or "?",
          authorId = c.author and c.author.id,
          content = c.content,
        }
      end
    end

    if #comments > 0 then
      local entry = { id = thread.id, status = thread.status, comments = comments }
      local ctx = thread.threadContext
      local side, lineno, end_lineno
      if ctx and ctx.rightFileStart then
        side, lineno = "R", ctx.rightFileStart.line
        if ctx.rightFileEnd and ctx.rightFileEnd.line and ctx.rightFileEnd.line > lineno then
          end_lineno = ctx.rightFileEnd.line
        end
      elseif ctx and ctx.leftFileStart then
        side, lineno = "L", ctx.leftFileStart.line
        if ctx.leftFileEnd and ctx.leftFileEnd.line and ctx.leftFileEnd.line > lineno then
          end_lineno = ctx.leftFileEnd.line
        end
      end

      if ctx and type(ctx.filePath) == "string" then
        local path = ctx.filePath:gsub("^/", "")
        entry.path, entry.side, entry.lineno, entry.end_lineno = path, side, lineno, end_lineno
        if side and lineno then
          local key = path .. "\t" .. side .. "\t" .. lineno
          by_key[key] = by_key[key] or {}
          table.insert(by_key[key], entry)
        else
          -- File-level comment (anchored to the file, not a line).
          file_by_path[path] = file_by_path[path] or {}
          table.insert(file_by_path[path], entry)
        end
      else
        general[#general + 1] = entry
      end
    end
  end
end

-- Snapshots thread.id -> comment count from a set of parsed thread tables
-- (the same shape threads_by_key/file_threads_by_path/general_threads use).
-- Used by refresh_threads to diff a freshly parsed poll against what's
-- currently on screen, instead of unconditionally treating every poll as a
-- full replace.
local function snapshot_comment_counts(by_key, file_by_path, general)
  local counts = {}
  local function scan(list)
    for _, t in ipairs(list or {}) do counts[t.id] = #t.comments end
  end
  for _, list in pairs(by_key) do scan(list) end
  for _, list in pairs(file_by_path) do scan(list) end
  scan(general)
  return counts
end

-- True when `t` has at least one comment authored by me (my_id) - i.e. I
-- started it or replied in it. Used so a reply from someone else landing in
-- a thread I've participated in still notifies, regardless of who owns the PR.
local function thread_involves_me(t)
  if not my_id then return false end
  for _, c in ipairs(t.comments) do
    if c.authorId == my_id then return true end
  end
  return false
end

-- Diffs a freshly parsed set of thread tables against `prev_counts` (from
-- snapshot_comment_counts on the previous poll) and returns the list of newly
-- appeared comments worth notifying about: authored by someone else, on a
-- thread that is either on my own pull request or one I've participated in,
-- and not currently hidden by the active-only/text filters (mirrors
-- passes_filters/filtered so a filtered-out comment never notifies).
local function find_new_comments(prev_counts, is_my_pr, by_key, file_by_path, general)
  local events = {}
  local function scan(list)
    for _, t in ipairs(list or {}) do
      local prev = prev_counts[t.id]
      local is_new_thread = prev == nil
      if (is_new_thread or #t.comments > prev) and passes_filters(t)
        and (is_my_pr or thread_involves_me(t)) then
        for i = (prev or 0) + 1, #t.comments do
          local c = t.comments[i]
          if c.authorId ~= my_id then
            events[#events + 1] = { author = c.author, path = t.path, side = t.side, lineno = t.lineno }
          end
        end
      end
    end
  end
  for _, list in pairs(by_key) do scan(list) end
  for _, list in pairs(file_by_path) do scan(list) end
  scan(general)
  return events
end

-- Turns a list of find_new_comments() events into a single notification, so
-- five comments landing in the same poll produce one message instead of five.
local function notify_new_comments(events)
  if #events == 0 then return end
  if #events == 1 then
    local e = events[1]
    local where = (e.path and (e.path .. (e.lineno and (":" .. e.lineno) or "")))
      or "a PR-level comment"
    local msg = "New comment from " .. e.author .. " on " .. where .. "."
    notify(msg)
    if EXT.notify then EXT.notify.toast("PR #" .. ID, msg) end
    return
  end
  local authors = {}
  for _, e in ipairs(events) do authors[e.author] = true end
  local names = {}
  for name in pairs(authors) do names[#names + 1] = name end
  table.sort(names)
  local msg = #events .. " new comments (" .. table.concat(names, ", ") .. ") on threads involving you."
  notify(msg)
  if EXT.notify then EXT.notify.toast("PR #" .. ID, msg) end
end


local function big_float_dims()
  local width = math.min(math.max(70, math.floor(vim.o.columns * 0.7)), 110)
  local height = math.min(math.max(18, math.floor(vim.o.lines * 0.65)), 34)
  return width, height
end

-- Open a scratch floating window showing the given text lines. focus defaults
-- to true; pass false to keep the cursor where it is. opts.min_width /
-- opts.min_height set a floor so short content still gets a roomy window;
-- opts.big forces the window to the shared large size (see big_float_dims),
-- centred over the editor instead of anchored to the cursor.
-- Returns the window id.
local function open_float(lines, focus, opts)
  opts = opts or {}
  opts.focus = focus
  return UI.open_float(lines, opts)
end

-- Shared one-line notes reused by the `?` help popups below, so the
-- code-navigation and optimistic-write behaviour is described the same way
-- everywhere it applies instead of being retyped per buffer.
local HELP_NOTE_NAV =
  "gd/gr open a peek view (hits on the left, the file at that revision previewed on the right); <CR> opens the hit read-only at that revision, q closes the peek. Inside an opened revision gd/gr keep working and <BS> walks back one jump. gf opens the current file at the PR's revision, read-only, on the same line."
local HELP_NOTE_SENDING =
  "Comments, replies and status changes appear instantly, tagged \"(sending\u{2026})\" until the server confirms; if the call fails the entry is removed and the prompt reopens with your text so nothing is lost."

-- Find this PR's record (stashed by the dashboard) to read metadata like the
-- description and build status. The cache is consulted first because the
-- dashboard refreshes it on its poll, whereas PR_CURRENT is frozen at open time.
local function current_pr_record()
  local cache = STATE.PR_LIST_CACHE
  if cache and cache.prs then
    for _, p in ipairs(cache.prs) do
      if tostring(p.id) == tostring(ID) then
        return p
      end
    end
  end
  local cur = STATE.PR_CURRENT
  if cur and tostring(cur.id) == tostring(ID) then
    return cur
  end
  return cur
end

-- Whether I authored this PR, computed once (state doesn't change during a
-- review session). Any new comment on my own PR is notification/highlight
-- worthy regardless of which thread it lands in.
local IS_MY_PR = (function()
  local pr = current_pr_record()
  return pr ~= nil and pr.state == "Created"
end)()

-- Persistent per-thread "seen" comment counts (nvim's per-user data dir, so
-- read state survives quitting and reopening this PR later): thread id (as a
-- string) -> how many comments it had the last time it was actually viewed
-- (K, or landing on it via the Overview page). Drives the "new" comment
-- highlight in the diff/file-list/Overview views, cleared per-thread once
-- you've looked at it.
local SEEN_THREADS_FILE = vim.fn.stdpath("data") .. "/azure-cli-seen-threads.json"
-- Migrates the pre-rename data file (this plugin was once called pr-dash,
-- see migrate.lua) into SEEN_THREADS_FILE the first time it's needed, then
-- leaves it alone.
local function load_seen_threads()
  require("azure-cli.migrate").ensure(vim.fn.stdpath("data") .. "/pr-dash-seen-threads.json", SEEN_THREADS_FILE)
  if vim.fn.filereadable(SEEN_THREADS_FILE) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, SEEN_THREADS_FILE)
  if not ok then return {} end
  local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok2 and type(decoded) == "table" then return decoded end
  return {}
end
local seen_threads = load_seen_threads()
local function save_seen_threads()
  pcall(vim.fn.writefile, { vim.json.encode(seen_threads) }, SEEN_THREADS_FILE)
end

-- True when `t` is "new": in my scope (my own PR, or a thread I've
-- participated in - same rule as the poll notifications) AND has more
-- comments than were recorded the last time I looked at it.
local function thread_is_new(t)
  if t.pending then return false end  -- my own, still being sent
  if not (IS_MY_PR or thread_involves_me(t)) then return false end
  local seen_count = seen_threads[tostring(t.id)]
  return (seen_count or 0) < #t.comments
end

-- Records `t`'s current comment count as seen, clearing its "new" highlight.
local function mark_thread_read(t)
  local key = tostring(t.id)
  if seen_threads[key] == #t.comments then return end
  seen_threads[key] = #t.comments
  save_seen_threads()
end

-- Marks every thread in `list` (and nested per-line lists) as read.
local function mark_threads_read(list)
  for _, t in ipairs(list or {}) do
    mark_thread_read(t)
  end
end

-- Compact build-validation label for the winbar, or nil when unknown/none
-- (merge.lua's M.build_label, so the complete dialog and the winbar agree).
local function build_status_label()
  return require("azure-cli.merge").build_label(current_pr_record())
end

-- Merge-conflict label for the winbar, or nil when there is no conflict.
local function merge_conflict_label()
  local pr = current_pr_record()
  if pr and pr.mergeConflict then return "conflict \u{26A0}" end
  return nil
end

-- Auto-complete label for the winbar, or nil when it isn't set on this PR.
local function auto_complete_label()
  local pr = current_pr_record()
  if pr and pr.autoComplete then return "auto-complete" end
  return nil
end

-- Render a list of threads into flat text lines for a floating window.
-- Optimistic writes ---------------------------------------------------------
-- Comments, replies and status changes show up the instant they're submitted
-- (tagged "(sending…)") and are confirmed or rolled back when the REST call
-- returns, instead of waiting a round-trip - or, for new comments, a
-- round-trip plus a full thread refetch - before anything appeared. A thread
-- refetch that lands while a write is still unconfirmed re-applies it
-- (reapply_pending), so nothing blinks out; once confirmed, the next refetch
-- replaces the synthetic entry with the server's copy.
local pending_threads = {}  -- { entry, bucket = "line"|"file"|"general", where }
local pending_replies = {}  -- { thread_id, comment }
local pending_status = {}   -- thread id -> status key
local pending_seq = 0

local function my_display_name()
  local rec = STATE.PR_CURRENT
  if rec and tostring(rec.id) == tostring(ID) and rec.myName and rec.myName ~= "" then
    return rec.myName
  end
  local w = STATE.whoami and STATE.whoami[ORG .. "|" .. PROJECT]
  if w and w.displayName and w.displayName ~= "" then return w.displayName end
  return "You"
end

local function sending_tag(x)
  if x and x.queued then return "  (queued)" end
  return (x and (x.pending or x.status_pending)) and "  (sending\u{2026})" or ""
end

local function bucket_list(bucket, where, create)
  if bucket == "general" then return general_threads end
  local tbl = bucket == "line" and threads_by_key or file_threads_by_path
  if create and not tbl[where] then tbl[where] = {} end
  return tbl[where]
end

local function remove_entry(list, entry)
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == entry then table.remove(list, i) end
  end
end

local function find_thread(id)
  local function scan(list)
    for _, t in ipairs(list or {}) do
      if tostring(t.id) == tostring(id) then return t end
    end
  end
  for _, list in pairs(threads_by_key) do
    local t = scan(list)
    if t then return t end
  end
  for _, list in pairs(file_threads_by_path) do
    local t = scan(list)
    if t then return t end
  end
  return scan(general_threads)
end

-- Show a new thread now; returns the pending record to confirm or drop.
local function add_pending_thread(text, bucket, where, path, side, lineno, end_lineno)
  pending_seq = pending_seq + 1
  local entry = {
    id = "pending-" .. pending_seq, status = "active", pending = true,
    path = path, side = side, lineno = lineno, end_lineno = end_lineno,
    comments = { { author = my_display_name(), authorId = my_id, content = text, pending = true } },
  }
  local p = { entry = entry, bucket = bucket, where = where }
  table.insert(bucket_list(bucket, where, true), entry)
  pending_threads[#pending_threads + 1] = p
  return p
end
local function drop_pending_thread(p)
  remove_entry(bucket_list(p.bucket, p.where, false), p.entry)
  remove_entry(pending_threads, p)
end
-- Confirmed: stop tracking it (the refetch will swap in the server's copy)
-- but leave it showing, untagged, until then.
local function confirm_pending_thread(p)
  p.entry.pending = nil
  p.entry.comments[1].pending = nil
  remove_entry(pending_threads, p)
end

-- After a refetch replaced the live tables, put every unconfirmed write back.
local function reapply_pending()
  for _, p in ipairs(pending_threads) do
    table.insert(bucket_list(p.bucket, p.where, true), p.entry)
  end
  for _, r in ipairs(pending_replies) do
    local t = find_thread(r.thread_id)
    if t then
      local present = false
      for _, c in ipairs(t.comments) do
        if c == r.comment then present = true break end
      end
      if not present then table.insert(t.comments, r.comment) end
    end
  end
  for id, key in pairs(pending_status) do
    local t = find_thread(id)
    if t then
      t.status = key
      t.status_pending = true
    end
  end
end

-- Run a provider write in the background: on_ok() on success, else
-- on_fail(details). Detached so the write completes even if the PR is
-- left before it returns.
local function run_write(args, on_ok, on_fail)
  local out = {}
  EXT.rpc.run(EXT.provider(args), {
    detach = true,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        on_ok()
        return
      end
      -- The full raw text (often a multi-line python traceback) goes to the
      -- session log; every caller here only ever sees LOG.summary's one
      -- line, with a pointer back to the rest - see log.lua's own header
      -- comment and README's Troubleshooting. Joined with "\n" (not " " as
      -- before), since LOG.summary's traceback detection needs real line
      -- breaks to find the "Traceback (most recent call last):" header.
      local raw = table.concat(vim.tbl_filter(function(x) return x ~= "" end, out), "\n")
      local msg = "exit " .. code
      if raw ~= "" then
        local LOG = require("azure-cli.log")
        LOG.record("PR #" .. ID, raw)
        msg = msg .. ": " .. LOG.summary(raw, vim.o.columns) .. "  (:AzureCli log)"
      end
      on_fail(msg)
    end,
  })
end

-- After a failed write, offer the same prompt again with the text prefilled
-- so a flaky call never eats what was typed. Scheduled, since input() can't
-- run from inside a job callback.
local function retry_prompt(prompt, text, resend)
  vim.schedule(function()
    -- `prompt` is one of this file's own "Retry ...: " labels - strip the
    -- trailing ": " for the floating editor's title, which reads like a
    -- name rather than a colon-terminated cmdline prompt.
    require("azure-cli.editor").open({
      title = (prompt:gsub("%s*:%s*$", "")),
      initial = text,
      anchor = "center",
      on_submit = resend,
      on_cancel = function() notify("Discarded.") end,
    })
  end)
end

local function redraw()
  if redraw_after_write then redraw_after_write() end
end

-- The comment text is always the last script argument; swap it for a retry.
local function args_with_text(args, text)
  local a = vim.list_slice(args, 1, #args - 1)
  a[#a + 1] = text
  return a
end

-- Post a new thread (line-anchored, file-level or PR-level), shown at once.
local function post_new_thread(args, bucket, where, path, side, lineno, text, label, retry_label, end_lineno)
  -- review/batch.lua (EXT.batch, when batch mode is on for this PR)
  -- gets first refusal: it returns true once it's taken the write over (the
  -- item is queued instead of sent), in which case nothing below runs. Checked
  -- BEFORE add_pending_thread so a queued item never gets pr-review.lua's own
  -- "(sending...)" pending entry - the module adds its own via
  -- ctx.add_pending_thread, tagged queued = true.
  if EXT.batch and EXT.batch.intercept then
    if EXT.batch.intercept("thread", {
      args = args, bucket = bucket, where = where, path = path, side = side,
      lineno = lineno, text = text, label = label, retry_label = retry_label,
      end_lineno = end_lineno,
    }) then
      return
    end
  end
  local p = add_pending_thread(text, bucket, where, path, side, lineno, end_lineno)
  redraw()
  run_write(args, function()
    confirm_pending_thread(p)
    notify(label .. " posted.")
    if refresh_threads then refresh_threads() end
  end, function(msg)
    drop_pending_thread(p)
    redraw()
    notify(label .. " failed (" .. msg .. ").", vim.log.levels.ERROR)
    retry_prompt("Retry " .. retry_label .. ": ", text, function(again)
      post_new_thread(args_with_text(args, again), bucket, where, path, side, lineno, again, label, retry_label, end_lineno)
    end)
  end)
end

-- comment_map (2nd return): bufline -> { thread = t, comment = c } for every
-- comment's "│ author:" header line, in the same order/positions these
-- lines render at - built by the same loop that builds `lines`, so a caller
-- wanting "the comment under this line" always matches what's on screen
-- exactly. Existing callers only use the first return, so this is additive.
local function threads_to_lines(threads)
  local lines = {}
  local comment_map = {}
  for ti, t in ipairs(threads) do
    if ti > 1 then
      lines[#lines + 1] = ""
    end
    local loc = ""
    if t.end_lineno and t.lineno and t.end_lineno > t.lineno then
      loc = "  lines " .. t.lineno .. "–" .. t.end_lineno
    end
    lines[#lines + 1] = "┌─ thread [" .. tostring(t.status or "?") .. "]" .. loc .. sending_tag(t)
    for _, c in ipairs(t.comments) do
      lines[#lines + 1] = "│ " .. c.author .. ":" .. sending_tag(c)
      comment_map[#lines] = { thread = t, comment = c }
      for _, cl in ipairs(vim.split(c.content, "\n", { plain = true })) do
        lines[#lines + 1] = "│   " .. cl
      end
    end
  end
  return lines, comment_map
end

-- Build the lines for the PR "Overview" page (see open_overview further
-- below, once its dependencies - comment_on_pr, pick_thread, jump_comment,
-- cast_vote, complete_pr - are all defined) and the per-file diff pane.

-- Produce the diff lines for a file plus a per-line {side, lineno} map so a
-- comment on any buffer line anchors to the correct file/side. Line numbers
-- are derived from the hunk headers (@@ -a,b +c,d @@); header/metadata lines
-- get a nil side (not commentable).
-- Map a repo path to a bundled Vim syntax name so diff buffers get language
-- syntax colouring (no LSP). nil = leave unhighlighted.
local FT_BY_EXT = {
  cs = "cs", lua = "lua", py = "python", js = "javascript", jsx = "javascriptreact",
  ts = "typescript", tsx = "typescriptreact", c = "c", h = "c", cpp = "cpp",
  cc = "cpp", cxx = "cpp", hpp = "cpp", java = "java", go = "go", rb = "ruby",
  rs = "rust", php = "php", sh = "sh", bash = "sh", ps1 = "ps1", psm1 = "ps1",
  json = "json", yaml = "yaml", yml = "yaml", xml = "xml", html = "html",
  htm = "html", css = "css", scss = "scss", md = "markdown", sql = "sql",
  proto = "proto", toml = "toml", ini = "dosini", vim = "vim", kt = "kotlin",
  swift = "swift", scala = "scala", pl = "perl", r = "r", dart = "dart",
  fs = "fsharp", gradle = "groovy", groovy = "groovy", cshtml = "html",
}
local function ft_for_path(path)
  -- Neovim's own detection first (Dockerfile, Makefile, *.tf, *.vue,
  -- *.csproj, ... - anything its filetype tables know); the extension
  -- table is the fallback for the few it doesn't.
  if vim.filetype and vim.filetype.match then
    local ok, ft = pcall(vim.filetype.match, { filename = path })
    if ok and ft and ft ~= "" then return ft end
  end
  local ext = (path or ""):match("%.([%w_]+)$")
  if not ext then return nil end
  return FT_BY_EXT[ext:lower()]
end

-- Parses one file's raw `git diff` output into display lines plus the
-- per-line {side, lineno} map (see cache.lua).
local parse_diff_output = CACHE.parse_diff

-- Builds one file's diff on its own, for a cache miss (the dashboard's
-- prefetch normally has every file ready before the PR is even opened).
-- want_ws adds --ignore-all-space, matching whichever content_cache variant
-- (see below) the caller is currently filling. Diffs the "changes since my
-- last review" range (EXT.since.range) instead of the PR's whole RANGE when
-- that mode is on - see review/since.lua and README's "Changes since
-- my last review".
local function build_diff_async(path, want_ws, cb)
  local out = {}
  local range = (EXT.since and EXT.since.range) or RANGE
  local args = want_ws
    and git_args("diff", "--unified=100000", "--ignore-all-space", range, "--", path)
    or git_args("diff", "--unified=100000", range, "--", path)
  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, _code)
      local lines, map = parse_diff_output(out)
      vim.schedule(function() cb(lines, map) end)
    end,
  })
end

-- Built diffs {lines, map} keyed by file path, held in the shared cache
-- (cache.lua) so they stay warm across leaving and re-entering this
-- PR and are shared with the dashboard's background prefetch. Namespaced per
-- PR + its updatedIso so a new push invalidates the cache instead of showing
-- a stale diff.
local function diff_cache_key()
  local pr = current_pr_record()
  return CACHE.key(ID, pr and pr.updatedIso or "")
end
local cache_key = diff_cache_key()
-- path -> {lines, map} for the current ignore_ws variant; reassigned by
-- toggle_ignore_ws (below), which updates every closure that captured this
-- local the same way apply_threads_json swaps in a fresh threads_by_key.
local content_cache = CACHE.diffs(cache_key, ignore_ws)

-- Fetches (or joins an in-flight fetch of) a file's diff content, calling
-- cb(lines, map) once available. Serves from content_cache instantly when
-- warm; otherwise de-dupes concurrent requests for the same path so opening
-- a file that's already being prefetched doesn't spawn a second git process.
-- Keyed by path *and* the requested variant so a build started just before a
-- gw toggle can't have its result delivered to (or stored under) the other
-- variant once it lands; each build snapshots its own target bucket instead
-- of reading content_cache again from the completion callback.
local diff_content_cbs = {}  -- "path\tvariant" -> pending callbacks while a fetch is in flight
local function ensure_diff_content(path, cb)
  local cached = content_cache[path]
  if cached then
    cb(cached.lines, cached.map)
    return
  end
  local want_ws, bucket = ignore_ws, content_cache
  -- The since-mode variant (if any) is part of the key too: unlike a gw
  -- toggle (which always flips want_ws, naturally changing this key), gi can
  -- turn since-mode on/off without touching want_ws, so the variant has to
  -- be included explicitly or a build already in flight for the old bucket
  -- could have its result joined - and delivered - to a caller waiting on
  -- the new one.
  -- cache_key is in the key for the same reason: EXT.reload_after_push
  -- re-keys it to the new source SHA when a push lands, and a build already
  -- in flight against the old ref must not be joined by a caller waiting on
  -- the new one - it would hand back the pre-push lines.
  local dkey = cache_key .. "\t" .. path .. "\t" .. tostring(want_ws)
    .. "\t" .. tostring(EXT.since and EXT.since.variant or "")
  diff_content_cbs[dkey] = diff_content_cbs[dkey] or {}
  table.insert(diff_content_cbs[dkey], cb)
  if #diff_content_cbs[dkey] > 1 then return end  -- already in flight
  build_diff_async(path, want_ws, function(lines, map)
    bucket[path] = { lines = lines, map = map }
    local cbs = diff_content_cbs[dkey] or {}
    diff_content_cbs[dkey] = nil
    for _, f in ipairs(cbs) do f(lines, map) end
  end)
end

-- Prompt for and post a comment on the diff line under the cursor.
local function comment_here()
  local buf = vim.api.nvim_get_current_buf()
  local map = maps_by_buf[buf]
  local path = paths_by_buf[buf]
  if not map or not path then
    notify("Not a diff buffer.", vim.log.levels.WARN)
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local m = map[lnum]
  if not m or not m.side then
    notify("This line can't be commented on.", vim.log.levels.WARN)
    return
  end
  local where = path .. "\t" .. m.side .. "\t" .. m.lineno
  -- Reviewer entries as { name, id } for the floating editor's "@" mention
  -- completion (see editor.lua's own header comment) - built fresh here
  -- rather than off a shared top-level local (this file is at LuaJIT's
  -- 200-local ceiling for M.open's own chunk - see the comment at EXT's
  -- declaration further up), same small snippet repeated at every comment/
  -- reply call site below.
  local mentions = {}
  do
    local pr = current_pr_record()
    for _, r in ipairs((pr and pr.reviewers) or {}) do
      if r.name and r.name ~= "" then mentions[#mentions + 1] = { name = r.name, id = r.id } end
    end
  end
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("line", { path = path, lineno = m.lineno }),
    context_lines = { (vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false))[1] or "" },
    anchor = { win = diff_win, row = lnum },
    mentions = mentions,
    draft_key = EDITOR.draft_key(ID, "line", where),
    on_submit = function(text)
      post_new_thread({ "--post", path, m.side, tostring(m.lineno), text }, "line", where,
        path, m.side, m.lineno, text,
        "Comment on " .. path .. " " .. m.side .. ":" .. m.lineno,
        "comment (" .. path .. " " .. m.side .. ":" .. m.lineno .. ")")
    end,
  })
end

-- Post a file-level comment (not tied to a line) on the given repo-relative path.
local function comment_on_file(path)
  if not path or path == "" then
    notify("No file selected.", vim.log.levels.WARN)
    return
  end
  local mentions = {}
  do
    local pr = current_pr_record()
    for _, r in ipairs((pr and pr.reviewers) or {}) do
      if r.name and r.name ~= "" then mentions[#mentions + 1] = { name = r.name, id = r.id } end
    end
  end
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("file", { path = path }),
    anchor = "center",
    mentions = mentions,
    draft_key = EDITOR.draft_key(ID, "file", path),
    on_submit = function(text)
      post_new_thread({ "--file-comment", path, text }, "file", path, path, nil, nil, text,
        "File comment on " .. path, "file comment (" .. path .. ")")
    end,
  })
end

-- Post a PR-level (general) comment, not tied to any file or line.
local function comment_on_pr()
  local mentions = {}
  do
    local pr = current_pr_record()
    for _, r in ipairs((pr and pr.reviewers) or {}) do
      if r.name and r.name ~= "" then mentions[#mentions + 1] = { name = r.name, id = r.id } end
    end
  end
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("pr", {}),
    anchor = "center",
    mentions = mentions,
    draft_key = EDITOR.draft_key(ID, "pr", ""),
    on_submit = function(text)
      post_new_thread({ "--pr-comment", text }, "general", nil, nil, nil, nil, text,
        "PR comment", "PR comment (#" .. ID .. ")")
    end,
  })
end

-- A changed line is one the diff marked as added or removed (tracked in the map,
-- since the +/- prefixes are stripped from the displayed text).
local function is_change_line(buf, i)
  local m = maps_by_buf[buf]
  local e = m and m[i]
  return (e ~= nil and (e.kind == "add" or e.kind == "del")) or false
end

-- Jump to the start of the next (dir=1) or previous (dir=-1) block of changed
-- lines, skipping over the contiguous change block the cursor is currently in.
-- Once that runs past the last (or before the first) hunk in this file,
-- continues into the next/previous file in the PR's file list instead of
-- just reporting "no further changes" - landing on that file's first hunk
-- for ]c, its last hunk for [c - skipping over any file with no changes at
-- all, and only falling back to the notice once no such file remains.
-- `files` and `open_file`, which know the file order and how to show one,
-- are declared much further down this chunk, so this function can't close
-- over them; it goes through EXT.file_index / EXT.file_count /
-- EXT.open_file_at, which the closing loader defines once they exist.
local function jump_change(dir)
  local buf = vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(buf)
  local i = vim.api.nvim_win_get_cursor(0)[1]
  while i >= 1 and i <= total and is_change_line(buf, i) do i = i + dir end
  while i >= 1 and i <= total and not is_change_line(buf, i) do i = i + dir end
  if i >= 1 and i <= total then
    if dir < 0 then
      while i - 1 >= 1 and is_change_line(buf, i - 1) do i = i - 1 end
    end
    vim.api.nvim_win_set_cursor(0, { i, 0 })
    vim.cmd("normal! zz")
    return
  end

  local function no_more()
    notify(dir > 0 and "No further changes." or "No previous changes.")
  end
  local cur_idx = EXT.file_index and paths_by_buf[buf] and EXT.file_index(paths_by_buf[buf])
  if not cur_idx then
    no_more()
    return
  end
  local last_idx = EXT.file_count()

  -- Open the file at file-list index `idx` (focusing the diff pane, same as
  -- <CR> there) and land on its first/last hunk, or move on to idx+dir if it
  -- turns out to have no changes at all.
  local function try_index(idx)
    if idx < 1 or idx > last_idx then
      no_more()
      return
    end
    local path = EXT.open_file_at(idx)
    if not (path and diff_win and vim.api.nvim_win_is_valid(diff_win)) then
      no_more()
      return
    end
    local dbuf = vim.api.nvim_win_get_buf(diff_win)
    -- ensure_diff_content calls back at once when the diff is already
    -- cached; otherwise once the background `git diff` for it lands.
    ensure_diff_content(path, function(_, map)
      vim.schedule(function()
        if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
        if vim.api.nvim_win_get_buf(diff_win) ~= dbuf then return end  -- moved on meanwhile
        local first, last
        for ln, m in ipairs(map) do
          if m.kind == "add" or m.kind == "del" then
            first = first or ln
            last = ln
          end
        end
        if not first then
          try_index(idx + dir)
          return
        end
        local target = dir > 0 and first or last
        if dir < 0 then
          while target - 1 >= 1 and map[target - 1] and
            (map[target - 1].kind == "add" or map[target - 1].kind == "del") do
            target = target - 1
          end
        end
        vim.api.nvim_win_set_cursor(diff_win, { target, 0 })
        vim.api.nvim_win_call(diff_win, function() vim.cmd("normal! zz") end)
      end)
    end)
  end

  try_index(cur_idx + dir)
end

-- Tag diff-buffer lines that carry existing PR comments: index them by buffer
-- line and add an end-of-line virtual note with the comment count and author.
-- Threads are passed through `filtered()` so lines with only non-active
-- threads are skipped entirely when active_only is on. In since-mode
-- (EXT.since), "L" (target-branch) threads are skipped outright: their line
-- number is relative to the target branch's copy of the file, which has
-- nothing to do with the since-range's base commit, so mapping it onto this
-- diff would land on the wrong line (or none) instead of just being absent -
-- see review/since.lua and README's "Changes since my last review".
local function decorate_comments(buf, path, map)
  local per_line = {}
  -- Reverse index (side/lineno -> buffer line) so a range thread's
  -- end_lineno can be mapped back onto the buffer to highlight the rest
  -- of its span, below.
  local bl_by_loc = {}
  for bl, m in ipairs(map) do
    if m.side and m.lineno then
      bl_by_loc[m.side .. "\t" .. m.lineno] = bl
    end
  end
  for bl, m in ipairs(map) do
    if m.side and m.lineno and not (EXT.since and m.side == "L") then
      local key = path .. "\t" .. m.side .. "\t" .. m.lineno
      local threads = filtered(threads_by_key[key])
      if threads and #threads > 0 then
        per_line[bl] = threads
        local count = 0
        local any_new = false
        for _, t in ipairs(threads) do
          count = count + #t.comments
          if thread_is_new(t) then any_new = true end
          if t.end_lineno and t.lineno and t.end_lineno > t.lineno then
            for ln = t.lineno + 1, t.end_lineno do
              local rbl = bl_by_loc[m.side .. "\t" .. ln]
              if rbl then
                vim.api.nvim_buf_set_extmark(buf, comments_ns, rbl - 1, 0, {
                  line_hl_group = "AzureCliCommentRange",
                })
              end
            end
          end
        end
        local author = threads[1].comments[1].author
        -- Resolved and active threads used to look identical here; now
        -- the status rides along and a fully-resolved line is dimmed.
        local all_resolved = true
        for _, t in ipairs(threads) do
          if t.status == "active" or t.status == "pending" or t.status == nil then all_resolved = false end
        end
        local status = all_resolved and "resolved" or (#threads == 1 and tostring(threads[1].status or "active") or "active")
        local label = string.format("  ▌ %s%d comment%s — %s [%s]", any_new and "🆕 " or "", count,
          count > 1 and "s" or "", author, status)
        local group = any_new and "AzureCliCommentNew" or (all_resolved and "AzureCliCommentResolved" or "AzureCliComment")
        local mark = { virt_text = { { label, group } }, virt_text_pos = "eol" }
        -- <Tab> (EXT.toggle_inline) expands the thread right under its
        -- line, as virtual lines, instead of a popup over the diff.
        if EXT.inline_open and EXT.inline_open[buf] and EXT.inline_open[buf][bl] then
          local virt = {}
          local tl = threads_to_lines(threads)
          for _, l in ipairs(tl) do virt[#virt + 1] = { { "      " .. l, "AzureCliInline" } } end
          mark.virt_lines = virt
        end
        vim.api.nvim_buf_set_extmark(buf, comments_ns, bl - 1, 0, mark)
      end
    end
  end

  -- File-level comments (no line anchor) are surfaced on the first line.
  local file_threads = filtered(file_threads_by_path[path])
  if file_threads and #file_threads > 0 and #map >= 1 then
    per_line[1] = per_line[1] or {}
    for i = #file_threads, 1, -1 do
      table.insert(per_line[1], 1, file_threads[i])
    end
    local count = 0
    local any_new = false
    for _, t in ipairs(file_threads) do
      count = count + #t.comments
      if thread_is_new(t) then any_new = true end
    end
    local label = string.format("  ▌ %s%d file comment%s", any_new and "🆕 " or "", count, count > 1 and "s" or "")
    vim.api.nvim_buf_set_extmark(buf, comments_ns, 0, 0, {
      virt_text = { { label, any_new and "AzureCliCommentNew" or "AzureCliComment" } },
      virt_text_pos = "eol",
    })
  end

  comments_by_buf[buf] = per_line
  -- Commented lines never fold away (see review/pane.lua).
  local PANE = require("azure-cli.review.pane")
  PANE.set_keep(buf, per_line)
  PANE.refresh(diff_win, buf)
end

-- Clear and re-apply comment decorations on every currently open diff buffer.
-- Used both after a fresh --threads fetch and when the active-only filter (gA)
-- is toggled, so already-open diffs immediately reflect the new state.
local function redecorate_all()
  for path, entry in pairs(diff_cache) do
    if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      vim.api.nvim_buf_clear_namespace(entry.buf, comments_ns, 0, -1)
      decorate_comments(entry.buf, path, entry.map)
    end
  end
end

-- Launched with `-u <this file>` the user's colourscheme isn't loaded, so nvim's
-- minimal built-in default leaves keywords/types/constants the plain foreground.
-- When no real colourscheme is active, colour the standard syntax groups with the
-- same catppuccin-mocha palette as the diff markers so code reads like an editor.
if vim.g.colors_name == nil then
  local code_hl = {
    Comment = { fg = "#7f849c", italic = true },
    Constant = { fg = "#fab387" }, Number = { fg = "#fab387" },
    Boolean = { fg = "#fab387" }, Float = { fg = "#fab387" },
    String = { fg = "#a6e3a1" }, Character = { fg = "#a6e3a1" },
    Identifier = { fg = "#cdd6f4" }, Function = { fg = "#89b4fa" },
    Statement = { fg = "#cba6f7" }, Keyword = { fg = "#cba6f7" },
    Conditional = { fg = "#cba6f7" }, Repeat = { fg = "#cba6f7" },
    Label = { fg = "#cba6f7" }, Exception = { fg = "#cba6f7" },
    Operator = { fg = "#89dceb" },
    Type = { fg = "#f9e2af" }, StorageClass = { fg = "#f9e2af" },
    Structure = { fg = "#f9e2af" }, Typedef = { fg = "#f9e2af" },
    PreProc = { fg = "#f5c2e7" }, Include = { fg = "#f5c2e7" },
    Define = { fg = "#f5c2e7" }, Macro = { fg = "#f5c2e7" },
    Special = { fg = "#94e2d5" },
  }
  for group, spec in pairs(code_hl) do
    pcall(vim.api.nvim_set_hl, 0, group, spec)
  end
end

-- Diff add/remove markers: a gutter sign + subtle full-line background, so the
-- code keeps its language syntax colours while changes stay obvious now that the
-- +/- prefixes are stripped. Kept in its own namespace so a thread refresh
-- (which only clears comments_ns) never wipes them. Linked to the standard
-- DiffAdd/DiffDelete/DiffText groups with `default = true` (see dashboard.lua's
-- define_hl for why), so plugin mode picks up the active colorscheme's own
-- diff colours and standalone/init.lua's explicit palette (applied after
-- this, non-default) still wins there.
pcall(vim.api.nvim_set_hl, 0, "AzureCliDiffAddBg",   { default = true, link = "DiffAdd" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliDiffDelBg",   { default = true, link = "DiffDelete" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliDiffAddSign", { default = true, link = "DiffAdd" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliDiffDelSign", { default = true, link = "DiffDelete" })
-- Word-level highlight inside a changed line pair (see CACHE.word_diff):
-- the same hue as the line background, stronger and bold, so a one-token
-- edit on a long line stands out instead of the whole line reading as
-- uniformly changed. DiffText is exactly vim's own "changed text within a
-- changed line" group.
pcall(vim.api.nvim_set_hl, 0, "AzureCliDiffAddWord", { default = true, link = "DiffText" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliDiffDelWord", { default = true, link = "DiffText" })
local function decorate_diff(buf, lines, map)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  for bl, m in ipairs(map) do
    if m.kind == "add" or m.kind == "del" then
      local is_add = m.kind == "add"
      vim.api.nvim_buf_set_extmark(buf, diff_ns, bl - 1, 0, {
        sign_text = is_add and "+" or "-",
        sign_hl_group = is_add and "AzureCliDiffAddSign" or "AzureCliDiffDelSign",
        line_hl_group = is_add and "AzureCliDiffAddBg" or "AzureCliDiffDelBg",
      })
    end
  end
  -- Narrow modified-block line pairs down to the bytes that actually
  -- changed (CACHE.word_diff pairs the i-th deleted line with the i-th
  -- added line of each such block), so a one-token change on a long line
  -- stands out instead of the whole line reading uniformly green/red.
  for _, w in ipairs(CACHE.word_diff(lines, map)) do
    vim.api.nvim_buf_set_extmark(buf, diff_ns, w.line - 1, w.s, {
      end_col = w.e,
      hl_group = w.kind == "add" and "AzureCliDiffAddWord" or "AzureCliDiffDelWord",
    })
  end
end

-- Pick a thread to act on: if there's exactly one, use it; otherwise prompt.
local function pick_thread(threads, cb, prompt)
  if not threads or #threads == 0 then
    return
  end
  if #threads == 1 then
    cb(threads[1])
    return
  end
  local items = {}
  for _, t in ipairs(threads) do
    local first = t.comments[1]
    local preview = first.content:gsub("%s+", " "):sub(1, 40)
    items[#items + 1] = { label = first.author .. " - " .. preview, thread = t }
  end
  require("azure-cli.prompt").select({ prompt = prompt or "Which thread?", items = items }, function(choice)
    if choice then cb(choice.thread) end
  end)
end

-- Post a reply to a specific thread. Shows the thread (unfocused) while typing,
-- posts via the --reply subcommand, and on success appends the reply locally
-- and calls on_success so the caller can refresh its view.
-- Send a reply that's already shown in `target`; confirm or roll back.
local function send_reply(target, comment, text, on_success)
  -- Same interceptor as post_new_thread, for replies - reply_to_thread has
  -- already appended `comment` to `target.comments` (optimistic, tagged
  -- pending) before calling here, so the module only needs to mark it
  -- queued = true and track it, not add anything new.
  if EXT.batch and EXT.batch.intercept then
    if EXT.batch.intercept("reply", { target = target, comment = comment, text = text, on_success = on_success }) then
      return
    end
  end
  local rec = { thread_id = target.id, comment = comment }
  pending_replies[#pending_replies + 1] = rec
  run_write({ "--reply", tostring(target.id), text }, function()
    comment.pending = nil
    remove_entry(pending_replies, rec)
    notify("Reply posted to thread " .. target.id .. ".")
    redraw()
  end, function(msg)
    remove_entry(pending_replies, rec)
    local t = find_thread(target.id) or target
    remove_entry(t.comments, comment)
    redraw()
    notify("Reply failed (" .. msg .. ").", vim.log.levels.ERROR)
    retry_prompt("Retry reply to thread " .. target.id .. ": ", text, function(again)
      local c = { author = my_display_name(), authorId = my_id, content = again, pending = true }
      local live = find_thread(target.id) or target
      table.insert(live.comments, c)
      mark_thread_read(live)
      if on_success then on_success() end
      send_reply(live, c, again, on_success)
    end)
  end)
end

local function reply_to_thread(target, on_success)
  if not target or not target.id then
    notify("Thread id unknown; cannot reply.", vim.log.levels.ERROR)
    return
  end
  if target.pending then
    notify("That comment is still being sent; reply once it's confirmed.", vim.log.levels.WARN)
    return
  end

  -- Show the thread (unfocused) so it stays visible while typing the reply -
  -- the floating editor opens anchored just below it (see EDITOR.open's
  -- `anchor`), so a reply typed from the K popup never hides what's being
  -- replied to.
  local thread_lines = threads_to_lines({ target })
  local fwin = open_float(thread_lines, false)
  local function close_thread_float()
    if fwin and vim.api.nvim_win_is_valid(fwin) then
      pcall(vim.api.nvim_win_close, fwin, true)
    end
  end

  local mentions = {}
  do
    local pr = current_pr_record()
    for _, r in ipairs((pr and pr.reviewers) or {}) do
      if r.name and r.name ~= "" then mentions[#mentions + 1] = { name = r.name, id = r.id } end
    end
  end
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("reply", { author = target.comments[1] and target.comments[1].author }),
    anchor = fwin and { win = fwin, row = #thread_lines + 1 } or "center",
    mentions = mentions,
    draft_key = EDITOR.draft_key(ID, "reply", tostring(target.id)),
    on_submit = function(text)
      close_thread_float()
      -- Show the reply at once; the write confirms or removes it.
      local comment = { author = my_display_name(), authorId = my_id, content = text, pending = true }
      table.insert(target.comments, comment)
      mark_thread_read(target)
      if on_success then on_success() end
      send_reply(target, comment, text, on_success)
    end,
    on_cancel = close_thread_float,
  })
end

-- Reply to an existing thread anchored to the diff line under the cursor. If
-- the line has more than one thread, prompt for which one.
local function reply_here()
  local buf = vim.api.nvim_get_current_buf()
  local per_line = comments_by_buf[buf]
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local threads = per_line and per_line[lnum]
  if not threads then
    notify("No comment thread on this line to reply to.", vim.log.levels.WARN)
    return
  end

  pick_thread(threads, function(target)
    reply_to_thread(target, function()
      if vim.api.nvim_buf_is_valid(buf) and paths_by_buf[buf] and maps_by_buf[buf] then
        vim.api.nvim_buf_clear_namespace(buf, comments_ns, 0, -1)
        decorate_comments(buf, paths_by_buf[buf], maps_by_buf[buf])
      end
    end)
  end, "Reply to which thread?")
end

-- ADO comment-thread statuses the reviewer can set, in menu order. The keyword
-- is what review-pr.sh --status expects; the label is what the menu shows.
local STATUS_OPTIONS = {
  { key = "active",   label = "Active" },
  { key = "fixed",    label = "Resolved (fixed)" },
  { key = "wontfix",  label = "Won't fix" },
  { key = "closed",   label = "Closed" },
  { key = "bydesign", label = "By design" },
  { key = "pending",  label = "Pending" },
}

-- PATCH a thread's status via the --status subcommand. On success updates the
-- thread's status locally and calls on_success.
-- Change a thread's status: shown at once, confirmed or reverted on return.
-- on_done(ok) (optional) runs when the write returns; the optimistic redraw
-- happens via on_apply (optional) right away.
local function set_status_optimistic(target, status, on_apply, on_done)
  if target.pending then
    notify("That comment is still being sent; set its status once it's confirmed.", vim.log.levels.WARN)
    if on_done then on_done(false) end
    return
  end
  local prev = target.status
  target.status = status.key
  target.status_pending = true
  pending_status[tostring(target.id)] = status.key
  if on_apply then on_apply() end
  run_write({ "--status", tostring(target.id), status.key }, function()
    pending_status[tostring(target.id)] = nil
    local t = find_thread(target.id) or target
    t.status_pending = nil
    if on_done then on_done(true) end
  end, function(msg)
    pending_status[tostring(target.id)] = nil
    local t = find_thread(target.id) or target
    t.status, t.status_pending = prev, nil
    notify("Status update failed (" .. msg .. "); reverted.", vim.log.levels.ERROR)
    if on_done then on_done(false) end
  end)
end

local function apply_status(target, status, on_success)
  set_status_optimistic(target, status, on_success, function(ok)
    if ok then notify("Thread " .. target.id .. " -> " .. status.label .. ".") end
    redraw()
  end)
end

-- Same as apply_status but without the per-thread "Setting status to..." /
-- success notifications (used for bulk operations so applying a status to
-- many comments at once doesn't spam notifications) — calls on_done(ok) when
-- that one PATCH finishes. Each call is fully async/detached, so firing off
-- many of these in a loop runs them all in the background concurrently.
local function apply_status_quiet(target, status, on_done)
  set_status_optimistic(target, status, nil, on_done)
end

-- Kick off a background status change for every thread in `matches`, without
-- waiting for any of them — reports one summary notification once they've
-- all finished (not one per thread), then redraws via on_change.
local function apply_status_to_matches(matches, status, label, on_change)
  local total = #matches
  if total == 0 then
    notify("No comments currently match " .. label .. ".", vim.log.levels.WARN)
    return
  end
  notify("Setting " .. total .. " comment(s) matching " .. label .. " to " .. status.label
    .. " in the background…")
  local done, failed = 0, 0
  for _, t in ipairs(matches) do
    apply_status_quiet(t, status, function(ok)
      done = done + 1
      if not ok then failed = failed + 1 end
      if done == total then
        vim.schedule(function()
          if on_change then on_change() end
          if failed == 0 then
            notify("Done: " .. total .. " comment(s) set to " .. status.label .. ".")
          else
            notify(failed .. "/" .. total .. " failed to update (network/permission?); check them individually.",
              vim.log.levels.WARN)
          end
        end)
      end
    end)
  end
end

-- Prompt for a status and apply it to the given thread. When `host` is given
-- (host.buf/host.win of an already-open float, e.g. the K popup, plus
-- host.restore() to redraw that float's normal content and host.close() to
-- close it), the picker is shown inline inside that same window instead of
-- nvim's cmdline inputlist, so you never leave the comment you're looking at.
-- Falls back to inputlist when there's no host float (e.g. `s` on the diff
-- line directly).
local function set_thread_status(target, on_success, host)
  if not target or not target.id then
    notify("Thread id unknown; cannot set status.", vim.log.levels.ERROR)
    return
  end

  if host and host.buf and vim.api.nvim_buf_is_valid(host.buf)
    and host.win and vim.api.nvim_win_is_valid(host.win) then
    local numkeys = {}
    local kopts = { buffer = host.buf, silent = true, nowait = true }
    -- Restore whatever q/Esc normally do for this popup (close it), since we
    -- temporarily repurpose them to cancel the status menu below. Without
    -- this, q/Esc would be left unbound after picking a status, and there'd
    -- be no way to close the popup from the keyboard.
    local function rebind_close()
      if host.close then
        vim.keymap.set("n", "q", host.close, kopts)
        vim.keymap.set("n", "<Esc>", host.close, kopts)
      end
    end
    local function cleanup()
      for _, k in ipairs(numkeys) do pcall(vim.keymap.del, "n", k, { buffer = host.buf }) end
    end
    local function finish(status)
      cleanup()
      rebind_close()
      if status then
        apply_status(target, status, on_success)
      end
      if host.restore then host.restore() end
    end

    local lines = { "Set thread " .. target.id .. " status:", "" }
    for i, o in ipairs(STATUS_OPTIONS) do
      lines[#lines + 1] = string.format("  %d. %s%s", i, o.label,
        (target.status == o.key) and "  (current)" or "")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "(1-" .. #STATUS_OPTIONS .. ": choose   q/Esc: cancel)"
    vim.bo[host.buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, host.buf, 0, -1, false, lines)
    vim.bo[host.buf].modifiable = false

    for i, status in ipairs(STATUS_OPTIONS) do
      local key = tostring(i)
      numkeys[#numkeys + 1] = key
      vim.keymap.set("n", key, function() finish(status) end, kopts)
    end
    vim.keymap.set("n", "q", function() finish(nil) end, kopts)
    vim.keymap.set("n", "<Esc>", function() finish(nil) end, kopts)
    return
  end

  require("azure-cli.prompt").select({ prompt = "Set thread " .. target.id .. " status", items = STATUS_OPTIONS,
    current = function(o) return target.status == o.key end }, function(o)
    if o then apply_status(target, o, on_success) end
  end)
end

-- Show the comment thread(s) anchored to the diff line under the cursor, in a
-- large float. R replies and s sets status right there (picking a thread
-- first if there's more than one on the line) without having to close the
-- popup and re-find the line.
local function show_comments_here()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local threads = (comments_by_buf[buf] or {})[lnum]
  if not threads then
    notify("No comments on this line.")
    return
  end
  -- Viewing the thread(s) on this line is "going to them" - mark read and
  -- immediately clear their 🆕 highlight (diff marker + file-list row).
  mark_threads_read(threads)
  if paths_by_buf[buf] and maps_by_buf[buf] then
    vim.api.nvim_buf_clear_namespace(buf, comments_ns, 0, -1)
    decorate_comments(buf, paths_by_buf[buf], maps_by_buf[buf])
  end
  refresh_file_rows()
  local win = open_float(threads_to_lines(threads), true, { big = true })
  if not win then return end
  local fbuf = vim.api.nvim_win_get_buf(win)

  -- Redraw the popup with the current `threads` (used after a cancelled
  -- status change, and as the tail of refresh() below).
  local function show_threads()
    if not vim.api.nvim_buf_is_valid(fbuf) then return end
    vim.bo[fbuf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, fbuf, 0, -1, false, threads_to_lines(threads))
    vim.bo[fbuf].modifiable = false
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  -- Re-decorate the diff + sidebar after an action, then either refresh the
  -- popup with the (possibly now-filtered) threads or close it if none remain.
  local function refresh()
    if vim.api.nvim_buf_is_valid(buf) and paths_by_buf[buf] and maps_by_buf[buf] then
      vim.api.nvim_buf_clear_namespace(buf, comments_ns, 0, -1)
      decorate_comments(buf, paths_by_buf[buf], maps_by_buf[buf])
    end
    refresh_file_rows()
    if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(fbuf)) then return end
    local fresh = (comments_by_buf[buf] or {})[lnum]
    if not fresh or #fresh == 0 then
      notify("No more comments on this line.")
      pcall(vim.api.nvim_win_close, win, true)
      return
    end
    threads = fresh
    show_threads()
  end

  local kopts = { buffer = fbuf, silent = true, nowait = true }
  vim.keymap.set("n", "R", function()
    pick_thread(threads, function(target)
      reply_to_thread(target, refresh)
    end, "Reply to which thread?")
  end, kopts)
  vim.keymap.set("n", "s", function()
    pick_thread(threads, function(target)
      set_thread_status(target, refresh, { buf = fbuf, win = win, restore = show_threads, close = close })
    end, "Set status on which thread?")
  end, kopts)
  -- Let reviewer-feature modules (see EXT near the top) bind their own keys
  -- into this popup - it's a fresh float/buffer per view, unlike the file
  -- list/diff/Overview/nav buffers, so it can't be reached through
  -- EXT.keys.*; each callback gets (fbuf, threads) and does its own
  -- vim.keymap.set(buffer = fbuf, ...) with them.
  for _, f in ipairs(EXT.on_comment_popup) do
    f(fbuf, threads)
  end
end

-- Set status on a thread anchored to the diff line under the cursor.
local function set_status_here()
  local buf = vim.api.nvim_get_current_buf()
  local per_line = comments_by_buf[buf]
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local threads = per_line and per_line[lnum]
  if not threads then
    notify("No comment thread on this line to update.", vim.log.levels.WARN)
    return
  end
  pick_thread(threads, function(target)
    set_thread_status(target, function()
      if vim.api.nvim_buf_is_valid(buf) and paths_by_buf[buf] and maps_by_buf[buf] then
        vim.api.nvim_buf_clear_namespace(buf, comments_ns, 0, -1)
        decorate_comments(buf, paths_by_buf[buf], maps_by_buf[buf])
      end
      -- The thread's status changed, so its file's (closed/total) count in the
      -- sidebar is now stale — re-render the file rows to pick up the new tally.
      refresh_file_rows()
    end, "Set status on which thread?")
  end)
end

-- PR-level votes the reviewer can cast, in menu order. The key is the numeric
-- vote review-pr.sh --vote expects (ADO: 10 approve, 5 approve w/ suggestions,
-- -5 wait for author, -10 reject, 0 reset).
local VOTE_OPTIONS = {
  { key = "10",  label = "Approve" },
  { key = "5",   label = "Approve with suggestions" },
  { key = "-5",  label = "Wait for author" },
  { key = "-10", label = "Reject" },
  { key = "0",   label = "Reset (no vote)" },
}

-- Prompt for a vote and cast it on the PR via the --vote subcommand.
local function cast_vote()
  local rec = current_pr_record()
  local PRS = require("azure-cli.prs")
  local cur = rec and PRS.my_vote_key(rec) or nil
  require("azure-cli.prompt").select({ prompt = "Your vote on PR #" .. ID .. ((rec and rec.title) and ("  " .. rec.title) or ""),
    items = VOTE_OPTIONS,
    current = function(o) return cur ~= nil and tostring(o.key) == cur end },
    function(vote)
  if not vote then return end
  local function go()
  notify("Voting: " .. vote.label .. "...")
  local out = {}
  EXT.rpc.run(EXT.provider({ "--vote", vote.key }), {
    detach = true,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("PR #" .. ID .. " vote set: " .. vote.label .. ".")
        -- Reflect it now: the Overview's Votes line and the winbar badges
        -- read the shared cached record, which only the dashboard's next
        -- poll would otherwise update.
        if rec then PRS.apply_my_vote(rec, tonumber(vote.key) or 0) end
        if EXT.render_overview then pcall(EXT.render_overview) end
        if set_list_winbar then pcall(set_list_winbar) end
      else
        local raw = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), "\n")
        local LOG = require("azure-cli.log")
        LOG.record("PR #" .. ID .. " vote", raw)
        notify("Vote failed (exit " .. code .. "): " .. LOG.summary(raw, vim.o.columns) .. "  (:AzureCli log)",
          vim.log.levels.ERROR)
      end
    end,
  })
  end
  if vote.key == "-10" then
    require("azure-cli.prompt").confirm({ prompt = "Reject PR #" .. ID .. "?", yes = "Reject", no = "Cancel" },
      function(yes) if yes then go() end end)
  else
    go()
  end
  end)
end

-- Complete (merge) the PR: the shared dialog (lua/azure-cli/merge.lua -
-- the dashboard's gm opens the same one) with this reviewer's live thread
-- counts, then --complete with what was picked.
local function complete_pr()
  local rec = current_pr_record()
  local unresolved = 0
  local function count(list)
    for _, t in ipairs(list or {}) do
      if t.status == "active" or t.status == "pending" then unresolved = unresolved + 1 end
    end
  end
  for _, list in pairs(threads_by_key) do count(list) end
  for _, list in pairs(file_threads_by_path) do count(list) end
  count(general_threads)

  require("azure-cli.merge").dialog({
    id = ID,
    title = rec and rec.title or "",
    source = SOURCE,
    target = TARGET,
    build_label = build_status_label(),
    conflict = merge_conflict_label() ~= nil,
    unresolved = unresolved,
    vote_ratio = rec and rec.voteRatio or nil,
  }, function(mt, delete_branch, work_items)
    notify("Completing PR #" .. ID .. " (" .. mt.label .. ")...")
    local out = {}
    EXT.rpc.run(EXT.provider({
      "--complete", mt.key,
      tostring(delete_branch), tostring(work_items),
    }), {
      detach = true,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
      on_stderr = function(_, d) if d then vim.list_extend(out, d) end end,
      on_exit = function(_, code)
        if code == 0 then
          notify("PR #" .. ID .. " completed (" .. mt.label .. ").")
          -- It's gone from the active list: drop it from the dashboard's
          -- cache and close this reviewer rather than leaving it open on a
          -- PR that no longer exists.
          local cache = STATE.PR_LIST_CACHE
          if cache and cache.prs then
            for i, p in ipairs(cache.prs) do
              if tostring(p.id) == tostring(ID) then table.remove(cache.prs, i) break end
            end
          end
          vim.schedule(function() leave(true) end)
        else
          local raw = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), "\n")
          local LOG = require("azure-cli.log")
          LOG.record("PR #" .. ID .. " complete", raw)
          notify("Complete failed (exit " .. code .. "): " .. LOG.summary(raw, vim.o.columns) .. "  (:AzureCli log)",
            vim.log.levels.ERROR)
        end
      end,
    })
  end)
end

-- Jump to the next (dir=1) / previous (dir=-1) diff line that has comments.
-- Jump to the next (dir=1) / previous (dir=-1) commented line in this
-- file. Past the last (or before the first) one it continues into the
-- next/previous file that has comments (per the active gA/gF filters),
-- landing on that file's first/last thread - the same way ]c/[c cross
-- files - and only reports "no further comments" once no such file is
-- left. File-list access goes through the EXT.file_* accessors the
-- closing loader defines, since `files`/`open_file` are declared later.
local function jump_comment(dir)
  local buf = vim.api.nvim_get_current_buf()
  local per_line = comments_by_buf[buf]
  local total = vim.api.nvim_buf_line_count(buf)
  local i = vim.api.nvim_win_get_cursor(0)[1] + dir
  while per_line and i >= 1 and i <= total do
    if per_line[i] then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! zz")
      return
    end
    i = i + dir
  end

  local function no_more()
    notify(dir > 0 and "No further comments." or "No previous comments.")
  end
  local cur_idx = EXT.file_index and paths_by_buf[buf] and EXT.file_index(paths_by_buf[buf])
  if not cur_idx then
    no_more()
    return
  end
  -- Next file (in list order) that has any thread showing under the
  -- current filters; skip the rest without opening them.
  local idx = cur_idx + dir
  local last_idx = EXT.file_count()
  while idx >= 1 and idx <= last_idx and not EXT.file_has_comments(idx) do idx = idx + dir end
  if idx < 1 or idx > last_idx then
    no_more()
    return
  end
  local path = EXT.open_file_at(idx)
  if not (path and diff_win and vim.api.nvim_win_is_valid(diff_win)) then
    no_more()
    return
  end
  local dbuf = vim.api.nvim_win_get_buf(diff_win)
  -- The diff content (and with it the comment decorations) may still be
  -- loading; ensure_diff_content calls back once it's there, after
  -- open_file's own callback has decorated the buffer.
  local function land(tries)
    if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
    if vim.api.nvim_win_get_buf(diff_win) ~= dbuf then return end  -- moved on meanwhile
    local lines = comments_by_buf[dbuf]
    if not lines then
      if tries > 0 then
        vim.defer_fn(function() land(tries - 1) end, 50)
      end
      return
    end
    local n = vim.api.nvim_buf_line_count(dbuf)
    local target
    if dir > 0 then
      for ln = 1, n do if lines[ln] then target = ln break end end
    else
      for ln = n, 1, -1 do if lines[ln] then target = ln break end end
    end
    if not target then return end
    vim.api.nvim_win_set_cursor(diff_win, { target, 0 })
    vim.api.nvim_win_call(diff_win, function() vim.cmd("normal! zz") end)
  end
  ensure_diff_content(path, function()
    vim.schedule(function() land(10) end)
  end)
end

-- Build the Overview page's lines plus a per-line thread map (one entry per
-- thread, on its "┌─ thread" header line) so R/s/]C/[C work on it exactly
-- like they do for a commented line in a regular file's diff.
local overview_buf  -- created once by open_overview; content rebuilt in place.
-- Commits between the target and source branches, shown on the Overview page.
-- nil until the background `git log` (load_overview_commits) has returned,
-- then a list (possibly empty). Fetched once: the branches don't move within
-- a review session.
local overview_commits = nil

local function build_overview()
  local pr = current_pr_record()
  local lines = {}
  local thread_map = {}
  -- comment_map (3rd return): bufline -> { thread = t, comment = c } for
  -- every comment's "│ author:" header line - same idea as
  -- threads_to_lines' own comment_map, for the Overview page's rendering.
  local comment_map = {}

  local title = pr and pr.title or ""
  lines[#lines + 1] = "PR #" .. ID .. (title ~= "" and ("  " .. title) or "")
  lines[#lines + 1] = SOURCE .. " -> " .. TARGET
  if pr then
    local meta = "Author: " .. ((pr.author and pr.author ~= "") and pr.author or "?")
    if pr.voteRatio and pr.voteRatio ~= "" then
      meta = meta .. "    Votes: " .. pr.voteRatio
    end
    lines[#lines + 1] = meta
    if pr.reviewerSummary and pr.reviewerSummary ~= "" then
      lines[#lines + 1] = "Reviewers: " .. pr.reviewerSummary
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Description:"
  local desc = pr and pr.description or ""
  if desc == nil or vim.trim(desc) == "" then
    lines[#lines + 1] = "  (no description)"
  else
    desc = desc:gsub("\r\n", "\n"):gsub("\r", "\n")
    for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. l
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Commits (who pushed):"
  if overview_commits == nil then
    lines[#lines + 1] = "  (loading…)"
  elseif #overview_commits == 0 then
    lines[#lines + 1] = "  (none found - branch may not be fetched yet)"
  else
    for _, c in ipairs(overview_commits) do
      lines[#lines + 1] = "  " .. c
    end
  end

  if EXT.since then
    lines[#lines + 1] = ""
    local n = EXT.since.new_iterations
    local fc = EXT.since.file_count or 0
    lines[#lines + 1] = "Since your last review (" .. (EXT.since.at and EXT.since.at:sub(1, 10) or "?") .. "): "
      .. n .. " new iteration" .. (n == 1 and "" or "s") .. ", " .. fc .. " file" .. (fc == 1 and "" or "s")
  end

  lines[#lines + 1] = ""
  local comments = filtered(general_threads)
  lines[#lines + 1] = "Comments (" .. #comments .. "):"
  if #comments == 0 then
    lines[#lines + 1] = "  (none — press c to add one)"
  else
    for _, t in ipairs(comments) do
      lines[#lines + 1] = ""
      thread_map[#lines + 1] = { t }
      lines[#lines + 1] = "┌─ thread [" .. tostring(t.status or "?") .. "]" .. sending_tag(t) .. (thread_is_new(t) and "  🆕" or "")
      for _, c in ipairs(t.comments) do
        lines[#lines + 1] = "│ " .. c.author .. ":" .. sending_tag(c)
        comment_map[#lines] = { thread = t, comment = c }
        for _, cl in ipairs(vim.split(c.content, "\n", { plain = true })) do
          lines[#lines + 1] = "│   " .. cl
        end
      end
    end
  end

  return lines, thread_map, comment_map
end

-- (Re)render the Overview buffer in place. Cheap (pure in-memory: no git or
-- network calls), so safe to call on every open plus after every
-- comment/reply/status change and thread poll. Also marks every shown
-- PR-level thread read, since seeing it here is "going to" it.
local function render_overview()
  if not (overview_buf and vim.api.nvim_buf_is_valid(overview_buf)) then
    return
  end
  local lines, thread_map = build_overview()
  comments_by_buf[overview_buf] = thread_map
  vim.bo[overview_buf].modifiable = true
  vim.api.nvim_buf_set_lines(overview_buf, 0, -1, false, lines)
  vim.bo[overview_buf].modifiable = false
  mark_threads_read(filtered(general_threads))
end

-- Fetch the PR's commit list for the Overview page in the background and
-- re-render it once it lands. This used to be a blocking `git log` inside
-- build_overview, i.e. on every Overview render including the very first
-- one at open - a ~300ms freeze under git-bash before anything was drawn.
local function load_overview_commits()
  local cached = CACHE.commits(cache_key)
  if cached then
    overview_commits = cached
    render_overview()
    return
  end
  local out = {}
  vim.fn.jobstart(git_args("log", "--format=%h  %ad  %an: %s", "--date=short",
      "origin/" .. TARGET .. "..origin/" .. SOURCE), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          overview_commits = vim.tbl_filter(function(l) return l ~= "" end, out)
          CACHE.set_commits(cache_key, overview_commits)
        else
          overview_commits = {}
        end
        render_overview()
      end)
    end,
  })
end

-- Reply to / set the status of the thread anchored to the Overview line under
-- the cursor - same shape as reply_here/set_status_here for a regular file,
-- just re-rendering the Overview page afterwards instead of a diff buffer.
local function reply_overview_here()
  local threads = (comments_by_buf[overview_buf] or {})[vim.api.nvim_win_get_cursor(0)[1]]
  if not threads then
    notify("No comment thread on this line to reply to.", vim.log.levels.WARN)
    return
  end
  pick_thread(threads, function(target)
    reply_to_thread(target, render_overview)
  end, "Reply to which thread?")
end

local function set_status_overview_here()
  local threads = (comments_by_buf[overview_buf] or {})[vim.api.nvim_win_get_cursor(0)[1]]
  if not threads then
    notify("No comment thread on this line to update.", vim.log.levels.WARN)
    return
  end
  pick_thread(threads, function(target)
    set_thread_status(target, render_overview)
  end)
end

-- Ordered { action, desc } pairs for the `?` popup below - real key(s)
-- resolved through KEYS (lua/azure-cli/keys.lua) every time, never
-- hard-coded. A field on HELP, not its own local - see HELP's own
-- declaration above. No longer feeds the winbar itself (see
-- set_overview_winbar below, and lua/azure-cli/ui.lua's UI.winbar) - `?`
-- already lists every key, so the winbar shows context instead.
HELP.overview_help = {
  "Navigate",
  { "open_commit", "on a commit line: that commit's changed files" },
  { "next_comment", "next thread (continues into the next file with comments)" },
  { "prev_comment", "previous thread (continues into the previous file with comments)" },
  { "search", "search text across the PR's changed files" },
  { "back", "back to the file list" },
  "Comment",
  { "comment", "new PR-level comment" },
  { "reply", "reply to the thread under the cursor" },
  { "status", "set the thread's status" },
  { "edit_comment", "edit a comment of yours" }, { "delete_comment", "delete a comment of yours" },
  "Review",
  { "vote", "vote" }, { "complete", "complete" },
  "Modes",
  { "active_filter", "toggle active (unresolved) comments only" },
  { "filters", "manage text filters that hide matching threads" },
  { "ignore_ws", "toggle ignoring whitespace in diffs" },
  "Session",
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "config", "open the config file" },
  { "quit", "close the reviewer" },
  { "help", "this help" },
}

local function set_overview_winbar()
  if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
  UI.wo(diff_win, "winbar", UI.winbar({ "Overview", "PR #" .. ID }, EXT.mode_tags and EXT.mode_tags() or {}))
end

-- Overview keys, shown by `?` there.
local function show_overview_help()
  open_float(KEYS.help_lines("overview", "Overview keys", HELP.overview_help, {
    now = EXT.mode_tags and EXT.mode_tags() or {},
    fixed = { "  j / k       move" },
    extra = EXT.help.overview, extra_title = "Features", notes = { HELP_NOTE_SENDING },
  }), true, { min_width = 60 })
end

local function setup_overview_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  KEYS.bind(buf, "overview", "comment", comment_on_pr, { desc = "new PR-level comment" })
  KEYS.bind(buf, "overview", "reply", reply_overview_here, { desc = "reply to the thread under the cursor" })
  KEYS.bind(buf, "overview", "status", set_status_overview_here, { desc = "set the thread's status" })
  KEYS.bind(buf, "overview", "next_comment", function() jump_comment(1) end, { desc = "next thread" })
  KEYS.bind(buf, "overview", "prev_comment", function() jump_comment(-1) end, { desc = "previous thread" })
  KEYS.bind(buf, "overview", "search", function() nav_search_files() end, { desc = "search text across the PR's changed files" })
  KEYS.bind(buf, "overview", "vote", cast_vote, { desc = "vote" })
  KEYS.bind(buf, "overview", "complete", complete_pr, { desc = "complete" })
  KEYS.bind(buf, "overview", "active_filter", toggle_active_filter, { desc = "toggle active (unresolved) comments only" })
  KEYS.bind(buf, "overview", "filters", manage_ignore_texts, { desc = "manage text filters that hide matching threads" })
  KEYS.bind(buf, "overview", "ignore_ws", toggle_ignore_ws, { desc = "toggle ignoring whitespace in diffs" })
  KEYS.bind(buf, "overview", "config", open_config_file, { desc = "open the config file" })
  KEYS.bind(buf, "overview", "resize_less", function() resize_list(-5) end, { desc = "shrink the file list" })
  KEYS.bind(buf, "overview", "resize_more", function() resize_list(5) end, { desc = "grow the file list" })
  KEYS.bind(buf, "overview", "back", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_set_current_win(list_win)
    end
  end, { desc = "back to the file list" })
  KEYS.bind(buf, "overview", "help", show_overview_help, { desc = "this help" })
  KEYS.bind(buf, "overview", "quit", leave, { desc = "close the reviewer" })
  -- Reviewer-feature keys registered via ctx.add_key("overview", ...) - see
  -- EXT near the top of this file. ctx.add_key already resolved the real
  -- key(s) through KEYS at registration time (an action name, not a literal
  -- key, since stage 2) - this just applies them.
  for _, e in ipairs(EXT.keys.overview) do
    vim.keymap.set(e.mode or "n", e.key, e.fn, vim.tbl_extend("force", opts, { desc = e.desc }))
  end
end

-- Show the Overview page in the diff pane (creating its buffer the first
-- time), exactly like opening a regular file - just with PR metadata and
-- comments instead of a diff. focus=true moves the cursor into it.
local function open_overview(focus)
  if not overview_buf or not vim.api.nvim_buf_is_valid(overview_buf) then
    overview_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[overview_buf].buftype = "nofile"
    vim.bo[overview_buf].filetype = "markdown"
    setup_overview_keymaps(overview_buf)
  end
  render_overview()
  if diff_win and vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_win_set_buf(diff_win, overview_buf)
    UI.plain_window(diff_win, {})
    UI.wo(diff_win, "wrap", true)
    UI.wo(diff_win, "linebreak", true)
    set_overview_winbar()
    if mark_current_file then mark_current_file(OVERVIEW_MARK) end
    if focus then
      vim.api.nvim_set_current_win(diff_win)
      vim.api.nvim_win_set_cursor(diff_win, { 1, 0 })
    end
  end
end

-- Diff-pane keys, shown by `?` there.
HELP.diff_help = {
  "Navigate",
  { "next_hunk", "next change (continues into the next file)" },
  { "prev_hunk", "previous change (continues into the previous file)" },
  { "next_comment", "next thread (continues into the next file with comments)" },
  { "prev_comment", "previous thread (continues into the previous file with comments)" },
  { "next_unviewed", "next file not yet viewed" },
  { "prev_unviewed", "previous file not yet viewed" },
  { "search", "search text across the PR's changed files" },
  { "goto_definition", "definition of the identifier under the cursor (peek)" },
  { "find_references", "references to the identifier under the cursor (peek)" },
  { "open_file", "this file at the PR's revision, on the same line" },
  { "back", "back to the file list" },
  "Comment",
  { "comment", "comment on the current line (or on a visual selection)" },
  { "comment_file", "comment on the whole file" },
  { "view_comments", "view the comments on the current line in a popup (R/s work inside it; e/dd edit/delete a comment of yours)" },
  { "expand_thread", "expand/collapse the thread on this line under it" },
  { "reply", "reply to the thread on the current line" },
  { "status", "set the thread's status" },
  "Review",
  { "toggle_viewed", "toggle this file's viewed mark" },
  { "vote", "vote" }, { "complete", "complete" },
  "Modes",
  { "active_filter", "toggle active (unresolved) comments only" },
  { "filters", "manage text filters that hide matching threads" },
  { "ignore_ws", "toggle ignoring whitespace in diffs" },
  "Session",
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "config", "open the config file" },
  { "quit", "close the reviewer" },
  { "help", "this help" },
}

local function show_diff_help()
  local lines = KEYS.help_lines("diff", "Diff pane keys", HELP.diff_help, {
    now = EXT.mode_tags and EXT.mode_tags() or {},
    fixed = { "  j / k / C-d / C-u   move", "  zR / zM     unfold / fold every run of unchanged lines" },
    extra = EXT.help.diff, extra_title = "Features",
  })
  lines[#lines + 1] = ""
  lines[#lines + 1] = HELP_NOTE_NAV
  lines[#lines + 1] = ""
  lines[#lines + 1] = HELP_NOTE_SENDING
  open_float(lines, true, { min_width = 60 })
end

local function setup_diff_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  KEYS.bind(buf, "diff", "comment", comment_here, { desc = "comment on the current line" })
  KEYS.bind(buf, "diff", "comment_file", function() comment_on_file(paths_by_buf[buf]) end, { desc = "comment on the whole file" })
  KEYS.bind(buf, "diff", "next_hunk", function() jump_change(1) end, { desc = "next change" })
  KEYS.bind(buf, "diff", "prev_hunk", function() jump_change(-1) end, { desc = "previous change" })
  KEYS.bind(buf, "diff", "view_comments", show_comments_here, { desc = "view the comments on the current line" })
  KEYS.bind(buf, "diff", "reply", reply_here, { desc = "reply to the thread on the current line" })
  KEYS.bind(buf, "diff", "expand_thread", function() EXT.toggle_inline() end,
    { desc = "expand/collapse the thread on this line under it" })
  KEYS.bind(buf, "diff", "toggle_viewed", function() EXT.toggle_viewed(paths_by_buf[buf]) end,
    { desc = "toggle this file's viewed mark" })
  KEYS.bind(buf, "diff", "next_unviewed", function() EXT.jump_unviewed(1) end, { desc = "next file not yet viewed" })
  KEYS.bind(buf, "diff", "prev_unviewed", function() EXT.jump_unviewed(-1) end, { desc = "previous file not yet viewed" })
  KEYS.bind(buf, "diff", "status", set_status_here, { desc = "set the thread's status" })
  KEYS.bind(buf, "diff", "vote", cast_vote, { desc = "vote" })
  KEYS.bind(buf, "diff", "complete", complete_pr, { desc = "complete" })
  KEYS.bind(buf, "diff", "next_comment", function() jump_comment(1) end, { desc = "next thread" })
  KEYS.bind(buf, "diff", "prev_comment", function() jump_comment(-1) end, { desc = "previous thread" })
  KEYS.bind(buf, "diff", "active_filter", toggle_active_filter, { desc = "toggle active (unresolved) comments only" })
  KEYS.bind(buf, "diff", "filters", manage_ignore_texts, { desc = "manage text filters that hide matching threads" })
  KEYS.bind(buf, "diff", "ignore_ws", toggle_ignore_ws, { desc = "toggle ignoring whitespace in diffs" })
  KEYS.bind(buf, "diff", "config", open_config_file, { desc = "open the config file" })
  KEYS.bind(buf, "diff", "goto_definition", function() nav_goto_definition() end, { desc = "go to definition" })
  KEYS.bind(buf, "diff", "find_references", function() nav_find_references() end, { desc = "find references" })
  KEYS.bind(buf, "diff", "open_file", function() nav_open_file() end, { desc = "open the current file at the PR's revision" })
  KEYS.bind(buf, "diff", "search", function() nav_search_files() end, { desc = "search text across the PR's changed files" })
  KEYS.bind(buf, "diff", "resize_less", function() resize_list(-5) end, { desc = "shrink the file list" })
  KEYS.bind(buf, "diff", "resize_more", function() resize_list(5) end, { desc = "grow the file list" })
  KEYS.bind(buf, "diff", "back", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_set_current_win(list_win)
    end
  end, { desc = "back to the file list" })
  KEYS.bind(buf, "diff", "help", show_diff_help, { desc = "this help" })
  KEYS.bind(buf, "diff", "quit", leave, { desc = "close the reviewer" })
  -- Reviewer-feature keys registered via ctx.add_key("diff", ...) - see EXT
  -- near the top of this file (this also carries review/range.lua's
  -- visual-mode "comment_range" - mode "x" - registered as an EXT.keys.diff
  -- entry the same way, not a literal vim.keymap.set here).
  for _, e in ipairs(EXT.keys.diff) do
    vim.keymap.set(e.mode or "n", e.key, e.fn, vim.tbl_extend("force", opts, { desc = e.desc }))
  end
end

-- Build the diff-pane winbar for `path`: the path plus its (+adds -dels)
-- tally (from the diff already parsed into diff_cache - blank until that's
-- landed), then the active-only/ignore-ws/since/text-filter/batch tags.
-- The mode tags every reviewer winbar shows (file list, diff pane,
-- Overview, revision buffers alike - the Overview used to show none, so
-- the page you land on first never said since-mode or a filter was on):
-- [active-only] [ignore-ws] [since …] [filter …] [batch: N], plus how many
-- threads the active filters are hiding right now.
EXT.mode_tags = function()
  local tags = {}
  if active_only then tags[#tags + 1] = "[active-only]" end
  if ignore_ws then tags[#tags + 1] = "[ignore-ws]" end
  if EXT.since then
    tags[#tags + 1] = "[since " .. EXT.since.short .. " \u{00B7} " .. EXT.since.new_iterations
      .. " new iteration" .. (EXT.since.new_iterations == 1 and "" or "s") .. "]"
  end
  local it = ignore_texts_tag()
  if it ~= "" then tags[#tags + 1] = it end
  if EXT.batch and EXT.batch.tag then
    -- EXT.batch.tag() itself returns "  [batch: N]" (leading spaces, tested
    -- verbatim by tests/test-review-batch.lua) - trimmed here rather than
    -- changed there, since UI.winbar's `tags` list does its own spacing.
    local bt = (EXT.batch.tag() or ""):gsub("^%s+", "")
    if bt ~= "" then tags[#tags + 1] = bt end
  end
  if active_only or it ~= "" then
    local total, shown = 0, 0
    local function count(list)
      total = total + #list
      shown = shown + #(filtered(list) or {})
    end
    for _, list in pairs(threads_by_key) do count(list) end
    for _, list in pairs(file_threads_by_path) do count(list) end
    count(general_threads)
    if total > shown then tags[#tags + 1] = "[" .. (total - shown) .. " hidden]" end
  end
  return tags
end

local function set_diff_winbar(path)
  if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
  local stats = ""
  local entry = diff_cache[path]
  if entry and entry.map then
    local adds, dels = 0, 0
    for _, m in ipairs(entry.map) do
      if m.kind == "add" then adds = adds + 1
      elseif m.kind == "del" then dels = dels + 1 end
    end
    stats = " (+" .. adds .. " \u{2212}" .. dels .. ")"
  end

  UI.wo(diff_win, "winbar", UI.winbar({ path .. stats }, EXT.mode_tags()))
end

-- Show a file's diff in the right window. focus=true moves the cursor into
-- it immediately (showing a "Loading diff…" placeholder on a cache miss,
-- since the content is now fetched in the background instead of blocking).
local function open_file(path, focus)
  if not path or path == "" then return end
  local entry = diff_cache[path]
  if not entry then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = ft_for_path(path) or "text"
    paths_by_buf[buf] = path
    setup_diff_keymaps(buf)
    entry = { buf = buf, map = {}, loaded = false }
    diff_cache[path] = entry

    local cached = content_cache[path]
    if cached then
      entry.loaded = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, cached.lines)
      vim.bo[buf].modifiable = false
      entry.map = cached.map
      maps_by_buf[buf] = cached.map
      require("azure-cli.review.pane").register(buf, cached.map)
      decorate_diff(buf, cached.lines, cached.map)
      decorate_comments(buf, path, cached.map)
    else
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading diff…" })
      vim.bo[buf].modifiable = false
      ensure_diff_content(path, function(lines, map)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        entry.loaded = true
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        entry.map = map
        maps_by_buf[buf] = map
        local PANE = require("azure-cli.review.pane")
        PANE.register(buf, map)
        decorate_diff(buf, lines, map)
        decorate_comments(buf, path, map)
        PANE.refresh(diff_win, buf)
      end)
    end
  end
  if diff_win and vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_win_set_buf(diff_win, entry.buf)
    -- Window options are re-initialised from the global values whenever a
    -- window shows a buffer for the first time, so they're (re)applied
    -- after every buffer switch, not once at window creation: the old/new
    -- line-number gutter and the unchanged-context folds live in
    -- review/pane.lua.
    UI.plain_window(diff_win, {})
    require("azure-cli.review.pane").apply(diff_win)
    set_diff_winbar(path)
    if mark_current_file then mark_current_file(path) end
    if focus then
      vim.api.nvim_set_current_win(diff_win)
      vim.api.nvim_win_set_cursor(diff_win, { 1, 0 })
      if EXT.mark_viewed then EXT.mark_viewed(path) end
    end
  end
end

-- Code navigation (no LSP needed) ------------------------------------------
-- Works on any ref without checking it out: `git grep` finds every use of
-- a word across the whole repo at the PR's revision, a small heuristic
-- ranks the definition-looking hits for gd, and `git show` opens a file at
-- that revision read-only for gf and for every jump. Available in diff
-- buffers and in the revision buffers they open, so you can keep following
-- code; <BS> walks back one jump at a time, q drops back to the diff.
local NAV_REF = { R = "origin/" .. SOURCE, L = "origin/" .. TARGET }
local nav_meta = {}   -- revision bufnr -> { ref, path }
local nav_bufs = {}   -- "ref\tpath" -> bufnr, reused across jumps
local nav_stack = {}  -- { buf, cursor } to return to on <BS>
local NAV_MAX_HITS = 2000

local function set_nav_winbar(buf)
  if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
  local meta = nav_meta[buf]
  UI.wo(diff_win, "winbar", UI.winbar({ "[" .. meta.ref .. "] " .. meta.path }, EXT.mode_tags and EXT.mode_tags() or {}))
end

-- Winbar + file-list highlight for whatever buffer the diff window shows now.
local function nav_restore_chrome(buf)
  if nav_meta[buf] then
    set_nav_winbar(buf)
  elseif buf == overview_buf then
    set_overview_winbar()
    if mark_current_file then mark_current_file(OVERVIEW_MARK) end
  elseif paths_by_buf[buf] then
    set_diff_winbar(paths_by_buf[buf])
    if mark_current_file then mark_current_file(paths_by_buf[buf]) end
  elseif EXT.commits and EXT.commits.nav_restore then
    -- A buffer none of the three kinds above recognise: give
    -- review/commits.lua (if loaded) a chance to own it (its
    -- commit-list/files/diff buffers share this same nav_stack via
    -- ctx.nav_show/ctx.nav_back, so <BS>/nav_back can land back on one).
    EXT.commits.nav_restore(buf)
  end
end

-- What's under the cursor in `buf` as (ref, path, lineno-or-nil): a
-- revision buffer maps 1:1; a diff buffer maps through its side/lineno
-- table (deleted lines belong to the target branch, all else to source).
local function nav_context(buf)
  local meta = nav_meta[buf]
  if meta then
    return meta.ref, meta.path, vim.api.nvim_win_get_cursor(0)[1]
  end
  local path = paths_by_buf[buf]
  if not path then return nil end
  local m = (maps_by_buf[buf] or {})[vim.api.nvim_win_get_cursor(0)[1]]
  local side = (m and m.side) or "R"
  return NAV_REF[side], path, m and m.lineno or nil
end

-- Show `buf` in the diff window, remembering where we came from.
local function nav_show(buf, lnum)
  if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
  local cur = vim.api.nvim_win_get_buf(diff_win)
  if cur ~= buf then
    nav_stack[#nav_stack + 1] = { buf = cur, cursor = vim.api.nvim_win_get_cursor(diff_win) }
    vim.api.nvim_win_set_buf(diff_win, buf)
  end
  vim.api.nvim_set_current_win(diff_win)
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, diff_win, { math.max(1, lnum), 0 })
    vim.cmd("normal! zz")
  end
end

local function nav_back()
  local top = table.remove(nav_stack)
  while top and not vim.api.nvim_buf_is_valid(top.buf) do top = table.remove(nav_stack) end
  if not top then
    notify("Nothing to go back to.")
    return
  end
  vim.api.nvim_win_set_buf(diff_win, top.buf)
  pcall(vim.api.nvim_win_set_cursor, diff_win, top.cursor)
  nav_restore_chrome(top.buf)
end

-- Pop every revision buffer, landing on the diff/Overview we started from.
local function nav_back_to_diff()
  repeat nav_back() until #nav_stack == 0 or not nav_meta[vim.api.nvim_win_get_buf(diff_win)]
end

local setup_nav_keymaps  -- below (needs the nav functions)

-- Colour a revision buffer the way the diff pane is coloured, so a preview
-- or a gd/gr/gf jump still shows what the PR changed: in the source-branch
-- copy of a file the PR touches, added lines get the green background and
-- the lines the PR removed appear in red as virtual lines where they used
-- to be; in the target-branch copy it's the reverse. Files the PR doesn't
-- touch are left plain. Uses the same parsed diff the diff pane uses (from
-- the shared cache, fetched on demand for a miss).
local function decorate_revision(buf)
  local meta = nav_meta[buf]
  if not meta or not meta.loaded then return end
  local pr_files = CACHE.files(cache_key)
  if not pr_files or not vim.tbl_contains(pr_files, meta.path) then return end
  ensure_diff_content(meta.path, function(lines, map)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    local own_side = (meta.ref == NAV_REF.L) and "L" or "R"
    local own_kind = own_side == "R" and "add" or "del"
    local own_bg = own_side == "R" and "AzureCliDiffAddBg" or "AzureCliDiffDelBg"
    local own_sign = own_side == "R" and "AzureCliDiffAddSign" or "AzureCliDiffDelSign"
    local other_bg = own_side == "R" and "AzureCliDiffDelBg" or "AzureCliDiffAddBg"
    local n = vim.api.nvim_buf_line_count(buf)

    -- Walk the diff in order keeping both sides' line counters, so every
    -- entry has a position in this buffer's numbering: own-side changes
    -- highlight that line, the other side's changes stack up as virtual
    -- lines above the next own-side line (or below the last one).
    local old, new = 0, 0
    local pending = {}
    local function flush(anchor)
      if #pending == 0 then return end
      local virt = {}
      for _, t in ipairs(pending) do virt[#virt + 1] = { { t, other_bg } } end
      local above = anchor <= n
      pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, math.max(0, math.min(anchor, n) - 1), 0,
        { virt_lines = virt, virt_lines_above = above })
      pending = {}
    end
    for i, m in ipairs(map) do
      if m.kind == "add" then
        new = new + 1
      elseif m.kind == "del" then
        old = old + 1
      elseif m.kind == "ctx" then
        new, old = new + 1, old + 1
      end
      local own_line = own_side == "R" and new or old
      if m.kind == own_kind then
        flush(own_line)
        pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, own_line - 1, 0, {
          sign_text = own_side == "R" and "+" or "-",
          sign_hl_group = own_sign,
          line_hl_group = own_bg,
        })
      elseif m.kind == "ctx" then
        flush(own_line)
      elseif m.kind then
        pending[#pending + 1] = lines[i]
      end
    end
    flush(n + 1)

    -- Word-level highlights on real lines only: the other side above is
    -- shown as virtual text (virt_lines can't carry extmarks), so only the
    -- own-side half of a CACHE.word_diff pair ever applies here. Walks the
    -- map a second time for its own line-position counters rather than
    -- reusing the walk above, which only leaves `old`/`new` at their final
    -- totals once it's done.
    local word_marks = CACHE.word_diff(lines, map)
    if #word_marks > 0 then
      local by_line = {}
      for _, w in ipairs(word_marks) do
        if w.kind == own_kind then by_line[w.line] = w end
      end
      local wold, wnew = 0, 0
      for i, m in ipairs(map) do
        if m.kind == "add" then
          wnew = wnew + 1
        elseif m.kind == "del" then
          wold = wold + 1
        elseif m.kind == "ctx" then
          wnew, wold = wnew + 1, wold + 1
        end
        local w = by_line[i]
        if w then
          local own_line = own_side == "R" and wnew or wold
          pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, own_line - 1, w.s, {
            end_col = w.e,
            hl_group = w.kind == "add" and "AzureCliDiffAddWord" or "AzureCliDiffDelWord",
          })
        end
      end
    end
  end)
end

-- Load (or reuse) the read-only buffer holding `path` as it is at `ref`,
-- without showing it. Contents arrive asynchronously; see when_loaded.
local function ensure_revision_buf(ref, path)
  local key = ref .. "\t" .. path
  local buf = nav_bufs[key]
  if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = ft_for_path(path) or "text"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "(loading " .. path .. " @ " .. ref .. "\u{2026})" })
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "[" .. ref .. "] " .. path)
  nav_meta[buf] = { ref = ref, path = path, loaded = false, waiters = {} }
  nav_bufs[key] = buf
  setup_nav_keymaps(buf)

  local out = {}
  vim.fn.jobstart(git_args("show", ref .. ":" .. path), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        if code ~= 0 then
          nav_bufs[key] = nil
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "(could not read " .. path .. " at " .. ref .. ")" })
        else
          if out[#out] == "" then out[#out] = nil end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
        end
        vim.bo[buf].modifiable = false
        local meta = nav_meta[buf]
        meta.loaded = true
        if code == 0 then decorate_revision(buf) end
        local waiters = meta.waiters
        meta.waiters = {}
        for _, f in ipairs(waiters) do f(buf) end
      end)
    end,
  })
  return buf
end

-- cb(buf) once the revision buffer's contents are in (at once if they are).
local function when_loaded(buf, cb)
  local meta = nav_meta[buf]
  if not meta or meta.loaded then cb(buf) return end
  table.insert(meta.waiters, cb)
end

-- Open `path` as it is at `ref` in the diff window, read-only, on line
-- `lnum` (when given).
local function open_revision(ref, path, lnum)
  local buf = ensure_revision_buf(ref, path)
  nav_show(buf, nil)
  set_nav_winbar(buf)
  if not lnum then return end
  when_loaded(buf, function(b)
    if diff_win and vim.api.nvim_win_is_valid(diff_win) and vim.api.nvim_win_get_buf(diff_win) == b then
      pcall(vim.api.nvim_win_set_cursor, diff_win, { math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(b))), 0 })
      vim.api.nvim_win_call(diff_win, function() vim.cmd("normal! zz") end)
    end
  end)
end

-- `git grep` for `text` at `ref`: cb(hits, truncated) with
-- hits = { {path, lnum, text}, ... }. Fixed-string throughout (-F) so
-- identifiers/search text with regex characters are safe; -I skips
-- binaries. `opts` (all optional):
--   whole_word  false for a plain substring search (the g/ command);
--               defaults to true (-w), matching whole identifiers only.
--   extra       extra flags spliced in before `-e`, e.g. {"-i"} for a
--               case-insensitive search.
--   pathspecs   file list appended after `--`, restricting the search to
--               those files; when omitted greps the whole tree at `ref`.
local function git_grep(text, ref, cb, opts)
  opts = opts or {}
  -- Built inline (rather than through git_args, which only takes varargs)
  -- since the flag/pathspec count varies per caller.
  local argv = { "git" }
  if REPO_PATH ~= "" then
    argv[#argv + 1] = "-C"
    argv[#argv + 1] = REPO_PATH
  end
  argv[#argv + 1] = "grep"
  argv[#argv + 1] = "-n"
  argv[#argv + 1] = "-I"
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "--no-color"
  if opts.whole_word ~= false then argv[#argv + 1] = "-w" end
  for _, flag in ipairs(opts.extra or {}) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = text
  argv[#argv + 1] = ref
  argv[#argv + 1] = "--"
  for _, p in ipairs(opts.pathspecs or {}) do argv[#argv + 1] = p end
  local out = {}
  vim.fn.jobstart(argv, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function()
      vim.schedule(function()
        local hits, truncated = {}, false
        local prefix = ref .. ":"
        for _, l in ipairs(out) do
          if l:sub(1, #prefix) == prefix then
            local path, lnum, line_text = l:sub(#prefix + 1):match("^(.-):(%d+):(.*)$")
            if path then
              if #hits >= NAV_MAX_HITS then truncated = true break end
              hits[#hits + 1] = { path = path, lnum = tonumber(lnum), text = line_text }
            end
          end
        end
        cb(hits, truncated)
      end)
    end,
  })
end

-- Rank a grep hit by how much it looks like `word`'s definition rather than
-- a use. Language-agnostic and deliberately simple: a declaring keyword
-- before the word, or a type-like token before it with a signature /
-- property / assignment shape after it. Comments score below zero.
local DEF_KEYWORDS = {
  "class", "struct", "interface", "enum", "record", "delegate", "def", "function",
  "func", "fn", "type", "trait", "impl", "module", "namespace", "typedef", "event",
}
local DECL_MODIFIERS = {
  "public", "private", "protected", "internal", "static", "const", "let", "var",
  "local", "val", "readonly", "override", "virtual", "abstract", "export", "final",
}
local NOT_A_TYPE = {
  "await", "return", "new", "throw", "yield", "case", "in", "not", "and", "or",
  "if", "elseif", "else", "while", "for", "do", "then", "using", "goto", "echo",
  "is", "as", "typeof", "sizeof", "nameof", "delete", "print", "assert",
}
local function def_score(word, text)
  local esc = vim.pesc(word)
  local before = text:match("^(.-)%f[%w_]" .. esc .. "%f[^%w_]")
  if not before then return 0 end
  local after = text:sub(#before + #word + 1)
  if before:match("^%s*//") or before:match("^%s*#") or before:match("^%s*%-%-")
      or before:match("^%s*%*") or before:match("^%s*/%*") then
    return -1
  end
  local score = 0
  for _, kw in ipairs(DEF_KEYWORDS) do
    if before:match("%f[%w_]" .. kw .. "%f[^%w_]") then score = score + 6 break end
  end
  for _, kw in ipairs(DECL_MODIFIERS) do
    if before:match("%f[%w_]" .. kw .. "%f[^%w_]") then score = score + 2 break end
  end
  -- "Type Name(" / "Type Name {" / "Type Name =" / "name:" shapes, where
  -- something type-like sits right before the word - not "." / "=" / "("
  -- and not a keyword that merely precedes a use (await, return, new, ...).
  local typed = before:match("[%w_>%]%*&%?]%s+$") ~= nil
  if typed then
    for _, kw in ipairs(NOT_A_TYPE) do
      if before:match("%f[%w_]" .. kw .. "%s+$") then typed = false break end
    end
  end
  if typed then
    if after:match("^%s*%(") then score = score + 4
    elseif after:match("^%s*{") or after:match("^%s*=[^=]") or after:match("^%s*:") then score = score + 3 end
  end
  return score
end

-- Peek picker, like an IDE's "peek references": the hits on the left, and
-- on the right the file at that revision centred on the hit under the
-- cursor, with the line and every occurrence highlighted - whole-word for
-- gd/gr, any substring (case-insensitively when smart case says so) for the
-- g/ search. Moving through the list re-previews (debounced); <CR> opens the
-- hit in the diff window, q/<Esc> (or leaving the list) closes both panes.
-- Hits are ordered same file first, then same extension, then by path.
pcall(vim.api.nvim_set_hl, 0, "AzureCliPeekLine", { default = true, link = "Visual" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliPeekWord", { default = true, link = "Search" })
local peek_ns = vim.api.nvim_create_namespace("azure_cli_peek")

-- nvim_open_win with a border title where supported (0.9+), plain otherwise.
local function open_peek_win(buf, focus, cfg, title)
  local with_title = vim.tbl_extend("force", cfg, { title = " " .. title .. " ", title_pos = "left" })
  local ok, win = pcall(vim.api.nvim_open_win, buf, focus, with_title)
  if ok then return win end
  return vim.api.nvim_open_win(buf, focus, cfg)
end

local function show_hits(title, hits, ref, current_path, truncated, word, search_opts)
  local ext = (current_path or ""):match("%.([%w_]+)$")
  local function rank(h)
    if h.path == current_path then return 0 end
    if ext and h.path:sub(-(#ext + 1)) == "." .. ext then return 1 end
    return 2
  end
  table.sort(hits, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    if a.path ~= b.path then return a.path < b.path end
    return a.lnum < b.lnum
  end)

  -- Geometry: one wide box, list taking ~40% (capped), preview the rest.
  local total_w = math.min(vim.o.columns - 4, math.max(80, math.floor(vim.o.columns * 0.92)))
  local height = math.min(vim.o.lines - 6, math.max(16, math.floor(vim.o.lines * 0.72)))
  local list_w = math.min(64, math.floor(total_w * 0.4))
  local prev_w = math.max(20, total_w - list_w - 2)
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_w) / 2))

  local lines = {}
  for _, h in ipairs(hits) do
    lines[#lines + 1] = string.format("%s:%d  %s", h.path, h.lnum, vim.trim(h.text))
  end
  local lbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
  vim.bo[lbuf].modifiable = false
  vim.bo[lbuf].buftype = "nofile"
  local lwin = open_peek_win(lbuf, true, {
    relative = "editor", row = row, col = col, width = list_w, height = height,
    style = "minimal", border = "rounded",
  }, title .. (truncated and ("  (first " .. #hits .. ")") or ""))
  UI.wo(lwin, "cursorline", true)
  UI.wo(lwin, "wrap", false)

  local pwin = open_peek_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor", row = row, col = col + list_w + 2, width = prev_w, height = height,
    style = "minimal", border = "rounded", focusable = false,
  }, "preview")
  UI.wo(pwin, "number", true)
  UI.wo(pwin, "wrap", false)
  UI.wo(pwin, "cursorline", false)

  local function clear_marks()
    for _, b in pairs(nav_bufs) do
      if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_clear_namespace(b, peek_ns, 0, -1) end
    end
  end

  local function highlight(buf, h)
    clear_marks()
    local line = vim.api.nvim_buf_get_lines(buf, h.lnum - 1, h.lnum, false)[1]
    if not line then return end
    pcall(vim.api.nvim_buf_set_extmark, buf, peek_ns, h.lnum - 1, 0, { line_hl_group = "AzureCliPeekLine", priority = 300 })
    if not word then return end
    if search_opts and search_opts.plain then
      -- g/: highlight every substring occurrence (not just whole words),
      -- case-insensitively when the search itself was (smart case).
      local hay = search_opts.case_insensitive and line:lower() or line
      local needle = search_opts.case_insensitive and word:lower() or word
      local from = 1
      while true do
        local s, e = hay:find(needle, from, true)
        if not s then break end
        pcall(vim.api.nvim_buf_set_extmark, buf, peek_ns, h.lnum - 1, s - 1,
          { end_col = e, hl_group = "AzureCliPeekWord", priority = 200 })
        from = e + 1
      end
      return
    end
    local from = 1
    while true do
      local s, e = line:find(word, from, true)
      if not s then break end
      if not line:sub(s - 1, s - 1):match("[%w_]") and not line:sub(e + 1, e + 1):match("[%w_]") then
        pcall(vim.api.nvim_buf_set_extmark, buf, peek_ns, h.lnum - 1, s - 1,
          { end_col = e, hl_group = "AzureCliPeekWord", priority = 200 })
      end
      from = e + 1
    end
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    clear_marks()
    if vim.api.nvim_win_is_valid(pwin) then pcall(vim.api.nvim_win_close, pwin, true) end
    if vim.api.nvim_win_is_valid(lwin) then pcall(vim.api.nvim_win_close, lwin, true) end
  end

  local function selected()
    if not vim.api.nvim_win_is_valid(lwin) then return nil end
    return hits[vim.api.nvim_win_get_cursor(lwin)[1]]
  end

  local function preview()
    local h = selected()
    if not h or not vim.api.nvim_win_is_valid(pwin) then return end
    local buf = ensure_revision_buf(ref, h.path)
    if vim.api.nvim_win_get_buf(pwin) ~= buf then vim.api.nvim_win_set_buf(pwin, buf) end
    pcall(vim.api.nvim_win_set_config, pwin, { title = " " .. h.path .. ":" .. h.lnum .. " ", title_pos = "left" })
    when_loaded(buf, function(b)
      if closed or selected() ~= h or not vim.api.nvim_win_is_valid(pwin)
          or vim.api.nvim_win_get_buf(pwin) ~= b then
        return
      end
      pcall(vim.api.nvim_win_set_cursor, pwin, { math.max(1, math.min(h.lnum, vim.api.nvim_buf_line_count(b))), 0 })
      vim.api.nvim_win_call(pwin, function() vim.cmd("normal! zz") end)
      highlight(b, h)
    end)
  end

  local preview_timer
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = lbuf,
    callback = function()
      if preview_timer then vim.fn.timer_stop(preview_timer) end
      preview_timer = vim.fn.timer_start(40, function() preview() end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, { buffer = lbuf, once = true, callback = close })
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(lwin), once = true, callback = close })

  local kopts = { buffer = lbuf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local h = selected()
    if not h then return end
    close()
    open_revision(ref, h.path, h.lnum)
  end, kopts)
  vim.keymap.set("n", "q", close, kopts)
  vim.keymap.set("n", "<Esc>", close, kopts)

  preview()
end

local function nav_word()
  local word = vim.fn.expand("<cword>")
  if not word or not word:match("^[%w_]+$") then
    notify("No identifier under the cursor.", vim.log.levels.WARN)
    return nil
  end
  return word
end

nav_find_references = function()
  local word = nav_word()
  if not word then return end
  local ref, path = nav_context(vim.api.nvim_get_current_buf())
  if not ref then return end
  notify("Searching references to '" .. word .. "' at " .. ref .. "\u{2026}")
  git_grep(word, ref, function(hits, truncated)
    if #hits == 0 then
      notify("No references to '" .. word .. "' at " .. ref .. ".")
      return
    end
    show_hits("References to '" .. word .. "' @ " .. ref .. " (" .. #hits .. ")", hits, ref, path, truncated, word)
  end)
end

nav_goto_definition = function()
  local word = nav_word()
  if not word then return end
  local ref, path = nav_context(vim.api.nvim_get_current_buf())
  if not ref then return end
  notify("Looking for the definition of '" .. word .. "' at " .. ref .. "\u{2026}")
  git_grep(word, ref, function(hits, truncated)
    if #hits == 0 then
      notify("No occurrences of '" .. word .. "' at " .. ref .. ".")
      return
    end
    local best, candidates = 0, {}
    for _, h in ipairs(hits) do
      h.score = def_score(word, h.text)
      if h.score > best then best = h.score end
    end
    if best >= 4 then
      for _, h in ipairs(hits) do
        if h.score == best then candidates[#candidates + 1] = h end
      end
    end
    if #candidates == 1 then
      open_revision(ref, candidates[1].path, candidates[1].lnum)
    elseif #candidates > 1 then
      show_hits("Definition candidates for '" .. word .. "' @ " .. ref .. " (" .. #candidates .. ")",
        candidates, ref, path, false, word)
    else
      notify("No definition-looking line for '" .. word .. "'; showing all " .. #hits .. " references.")
      show_hits("References to '" .. word .. "' @ " .. ref .. " (" .. #hits .. ")", hits, ref, path, truncated, word)
    end
  end)
end

nav_open_file = function()
  local buf = vim.api.nvim_get_current_buf()
  if nav_meta[buf] then return end  -- already a revision buffer
  local ref, path, lnum = nav_context(buf)
  if not ref then
    notify("Not a diff buffer.", vim.log.levels.WARN)
    return
  end
  open_revision(ref, path, lnum)
end

-- Revision-buffer keys, shown by `?` there.
HELP.nav_help = {
  "Navigate",
  { "goto_definition", "definition from here" }, { "find_references", "references from here" },
  { "search", "search text across the PR's changed files" },
  { "back", "walk back one jump" },
  { "back_to_diff", "back to the diff" },
  "Session",
  { "config", "open the config file" },
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "help", "this help" },
}

local function show_nav_help()
  open_float(KEYS.help_lines("nav", "Revision buffer keys", HELP.nav_help, {
    fixed = { "  j / k       move" },
    extra = EXT.help.nav, extra_title = "Features", notes = { HELP_NOTE_NAV },
  }), true, { min_width = 60 })
end

setup_nav_keymaps = function(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  KEYS.bind(buf, "nav", "goto_definition", function() nav_goto_definition() end, { desc = "go to definition" })
  KEYS.bind(buf, "nav", "find_references", function() nav_find_references() end, { desc = "find references" })
  KEYS.bind(buf, "nav", "search", function() nav_search_files() end, { desc = "search text across the PR's changed files" })
  KEYS.bind(buf, "nav", "back", nav_back, { desc = "walk back one jump" })
  KEYS.bind(buf, "nav", "back_to_diff", nav_back_to_diff, { desc = "back to the diff" })
  KEYS.bind(buf, "nav", "config", open_config_file, { desc = "open the config file" })
  KEYS.bind(buf, "nav", "resize_less", function() resize_list(-5) end, { desc = "shrink the file list" })
  KEYS.bind(buf, "nav", "resize_more", function() resize_list(5) end, { desc = "grow the file list" })
  KEYS.bind(buf, "nav", "help", show_nav_help, { desc = "this help" })
  -- Reviewer-feature keys registered via ctx.add_key("nav", ...) - see EXT
  -- near the top of this file.
  for _, e in ipairs(EXT.keys.nav) do
    vim.keymap.set(e.mode or "n", e.key, e.fn, vim.tbl_extend("force", opts, { desc = e.desc }))
  end
end

-- ---------------------------------------------------------------------------
-- Highlight for the inline comment markers.
pcall(vim.api.nvim_set_hl, 0, "AzureCliComment", { default = true, link = "Comment" })
-- Highlight for comment markers with unread comments (see thread_is_new).
pcall(vim.api.nvim_set_hl, 0, "AzureCliCommentNew", { default = true, link = "WarningMsg" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliCommentResolved", { default = true, link = "Comment" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliInline", { default = true, link = "NonText" })
-- Subtle full-line background over lines lineno+1..end_lineno of a range
-- comment (see decorate_comments and review/range.lua).
pcall(vim.api.nvim_set_hl, 0, "AzureCliCommentRange", { default = true, link = "Visual" })
-- Highlight for the file-list row of whichever file is currently shown in the
-- diff pane. Unlike relying on the cursor/'cursorline', this stays visible
-- even once focus has moved into the diff pane (where the list, now an
-- inactive window, would otherwise show no cursor at all).
pcall(vim.api.nvim_set_hl, 0, "AzureCliCurrentFile", { default = true, link = "CursorLine" })
local current_file_ns = vim.api.nvim_create_namespace("azure_cli_current_file")

-- The PR's changed files, filled in asynchronously by load_files (below, at
-- startup) so the reviewer opens before git has answered. Empty until then;
-- files_loaded tells the placeholder row apart from a genuinely empty PR.
local files = {}
local files_loaded = false

-- g/: search plain text across the PR's changed files at the source branch
-- (unlike gd/gr, which search the whole repo for a single identifier). The
-- last search is kept in _G, like the ignore-whitespace toggle, rather than
-- a local, so it prefills the prompt across PRs opened in the same nvim
-- session without adding another top-level local (this file's already near
-- LuaJIT's 200-local-per-function ceiling for its main chunk).
nav_search_files = function()
  if not files_loaded or #files == 0 then
    notify("No changed files to search yet.", vim.log.levels.WARN)
    return
  end
  require("azure-cli.prompt").input({ prompt = "Search PR files:", default = STATE.last_search or "" }, function(text)
  if not text then return end
  STATE.last_search = text
  -- Smart case: an uppercase letter in the query makes the search
  -- case-sensitive; otherwise it's case-insensitive.
  local case_insensitive = not text:find("%u")
  notify("Searching \"" .. text .. "\" in " .. #files .. " changed files\u{2026}")
  git_grep(text, NAV_REF.R, function(hits, truncated)
    if #hits == 0 then
      notify("No hits for \"" .. text .. "\" in the changed files.")
      return
    end
    show_hits('Search "' .. text .. '" in ' .. #files .. ' changed files (' .. #hits .. ")",
      hits, NAV_REF.R, nil, truncated, text, { plain = true, case_insensitive = case_insensitive })
  end, { whole_word = false, pathspecs = files, extra = case_insensitive and { "-i" } or nil })
  end)
end

-- Warm content_cache for every file still missing, with a single git run
-- over the whole range (see cache.lua), so switching between files
-- (j/k in the file list) is instant. Usually a no-op: the dashboard's
-- hover/warm-all prefetch has normally filled the cache before the PR is
-- opened. Files opened explicitly meanwhile are fetched on their own by
-- ensure_diff_content, which de-dupes against its own in-flight builds.
local function prefetch_all_diffs()
  local pr = current_pr_record()
  CACHE.prefetch({
    id = ID, updatedIso = pr and pr.updatedIso or "",
    source = SOURCE, target = TARGET, repo = REPO_PATH, ignore_ws = ignore_ws,
    range = EXT.since and EXT.since.range or nil,
    variant = EXT.since and EXT.since.variant or nil,
  }, function()
    -- Every file's diff (and with it the +/- stats review/filelist.lua's
    -- model reads from content_cache) just landed - re-render the file-list
    -- rows so they pick up real stats instead of "(?)".
    if refresh_file_rows then refresh_file_rows() end
  end)
end

-- Count comment threads anchored to a file: line-anchored threads (keyed
-- "path\tside\tline") plus file-level ones. Returns (closed, total), where
-- "closed" is every thread whose status isn't "active" (fixed/won't-fix/closed).
-- Respects the gA active-only filter, same as the diff view and PR comments:
-- when active_only is on, non-active threads are dropped before counting, so
-- e.g. "1 active, 1 closed" (0/2) becomes "0/1" instead of "0/2".
local function file_thread_count(path)
  local closed, total = 0, 0
  local function tally(list)
    for _, t in ipairs(filtered(list) or {}) do
      total = total + 1
      if t.status ~= "active" then closed = closed + 1 end
    end
  end
  local prefix = path .. "\t"
  for key, list in pairs(threads_by_key) do
    if key:sub(1, #prefix) == prefix then
      tally(list)
    end
  end
  local fl = file_threads_by_path[path]
  if fl then tally(fl) end
  return closed, total
end

-- True when any (filter-passing) thread anchored to this file is "new" (see
-- thread_is_new) - drives the 🆕 marker on the file-list row.
local function file_has_new(path)
  local function any_new(list)
    for _, t in ipairs(filtered(list) or {}) do
      if thread_is_new(t) then return true end
    end
    return false
  end
  local prefix = path .. "\t"
  for key, list in pairs(threads_by_key) do
    if key:sub(1, #prefix) == prefix and any_new(list) then return true end
  end
  return any_new(file_threads_by_path[path])
end

-- Label for the pinned first row that opens the PR Overview page.
local function overview_row_label(n)
  local prefix = ""
  for _, t in ipairs(filtered(general_threads) or {}) do
    if thread_is_new(t) then prefix = "🆕 "; break end
  end
  if n == nil then return prefix .. "Overview (loading...)" end
  if n == 0 then return prefix .. "Overview" end
  return prefix .. "Overview  (" .. n .. " comment" .. (n > 1 and "s" or "") .. ")"
end

-- Left window: the file list, with the Overview row pinned at the top (line
-- 1) so it's always the first "file" you land on, same as Azure DevOps's own
-- Overview tab. Files occupy lines 2.. from there, grouped by directory with
-- status letters and +/- stats - see review/filelist.lua's own header
-- comment for the model it builds (row_to_file/file_to_row/ordered_files),
-- which EXT.filelist (below) holds the live copy of.
local list_buf = vim.api.nvim_create_buf(false, true)
vim.b[list_buf].azure_cli_pr = tostring(ID)  -- lets the dashboard find this tab again
local OVERVIEW_ROW = 1
local current_file_path  -- path (or OVERVIEW_MARK) currently shown in the diff pane, for re-marking after redraws.
local function list_lines()
  local out = { overview_row_label(nil) }
  if not files_loaded then
    out[#out + 1] = "  (loading files…)"
    return out
  end
  if EXT.filelist then vim.list_extend(out, EXT.filelist.lines) end
  return out
end

-- Rebuilds and redraws the file-list rows (directory-grouped, with status
-- letters and +/- stats) from the current `files`, `EXT.file_status`
-- (load_files' background `git diff --name-status` fetch fills this in
-- after an instant open from the dashboard's plain-paths cache) and the
-- per-file diff/thread state already in scope here. A field on EXT (see
-- EXT's own declaration far above - this file is at LuaJIT's 200-local
-- ceiling for its main chunk), not a new top-level local, so apply_files
-- and refresh_file_rows (below) both just call this instead of duplicating
-- it.
EXT.file_status = EXT.file_status or {}
EXT.refresh_file_list = function()
  if not vim.api.nvim_buf_is_valid(list_buf) then return end
  local FILELIST = require("azure-cli.review.filelist")
  local stats, threads_info = {}, {}
  for _, f in ipairs(files) do
    local entry = content_cache[f]
    if entry and entry.map then stats[f] = FILELIST.diff_stats(entry.map) end
    local closed, total = file_thread_count(f)
    threads_info[f] = { closed = closed, total = total, new = file_has_new(f),
      viewed = EXT.viewed_stamp and require("azure-cli.review.viewed").is_viewed(ID, f, EXT.viewed_stamp()) or false }
  end
  EXT.filelist = FILELIST.build(files, stats, EXT.file_status, threads_info)
  FILELIST.render(list_buf, EXT.filelist)
  if fit_list_width then fit_list_width() end
  if mark_current_file then mark_current_file(current_file_path) end
end

-- Highlight the file-list row for `path` (the diff pane's current file, or
-- OVERVIEW_MARK) and remember it so refresh_file_rows can re-apply it after
-- redrawing the rows.
mark_current_file = function(path)
  current_file_path = path
  if not vim.api.nvim_buf_is_valid(list_buf) then return end
  vim.api.nvim_buf_clear_namespace(list_buf, current_file_ns, 0, -1)
  if path == OVERVIEW_MARK then
    pcall(vim.api.nvim_buf_add_highlight, list_buf, current_file_ns, "AzureCliCurrentFile", 0, 0, -1)
    return
  end
  if not path then return end
  local row = EXT.filelist and EXT.filelist.file_to_row[path]
  if row then
    pcall(vim.api.nvim_buf_add_highlight, list_buf, current_file_ns, "AzureCliCurrentFile", row, 0, -1)
  end
end
-- Re-render the file rows with fresh comment counts/stats/status, e.g. after
-- threads or a diff load asynchronously. Leaves the pinned Overview row
-- alone (see refresh_overview_row).
refresh_file_rows = function()
  EXT.refresh_file_list()
end
-- Re-render just the pinned Overview row (line 1) with a fresh comment count.
local function refresh_overview_row()
  if not vim.api.nvim_buf_is_valid(list_buf) then return end
  vim.bo[list_buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, list_buf, OVERVIEW_ROW - 1, OVERVIEW_ROW, false,
    { overview_row_label(#filtered(general_threads)) })
  vim.bo[list_buf].modifiable = false
end
vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines())
vim.bo[list_buf].modifiable = false
vim.bo[list_buf].buftype = "nofile"
vim.bo[list_buf].filetype = "azurecli-files"

vim.api.nvim_win_set_buf(0, list_buf)
list_win = vim.api.nvim_get_current_win()
UI.plain_window(list_win, { cursorline = true })

-- Rebuild the file-list winbar: "PR #123 · feature/x -> main · N files",
-- the live build/conflict/auto-complete badges (read from the
-- dashboard-maintained cache) and the active-only/ignore-ws/since/
-- text-filter/batch tags, then "?: help".
local function set_list_winbar_impl()
  if not (list_win and vim.api.nvim_win_is_valid(list_win)) then return end
  local blabel = build_status_label()
  local clabel = merge_conflict_label()
  local alabel = auto_complete_label()

  local parts = { "PR #" .. ID, SOURCE .. " \u{2192} " .. TARGET }
  if files_loaded then
    local viewed = EXT.viewed_count and EXT.viewed_count() or nil
    parts[#parts + 1] = #files .. " files" .. (viewed and (", " .. viewed .. " viewed") or "")
    -- The directory prefix every changed file shares (see
    -- review/filelist.lua's M.build) is trimmed off every file-list row and
    -- shown here once instead.
    if EXT.filelist and EXT.filelist.prefix ~= "" then
      parts[#parts + 1] = EXT.filelist.prefix
    end
  end

  local tags = {}
  if blabel then tags[#tags + 1] = "[" .. blabel .. "]" end
  if clabel then tags[#tags + 1] = "[" .. clabel .. "]" end
  if alabel then tags[#tags + 1] = "[" .. alabel .. "]" end
  vim.list_extend(tags, EXT.mode_tags())

  pcall(function()
    UI.wo(list_win, "winbar", UI.winbar(parts, tags))
  end)
end
set_list_winbar = set_list_winbar_impl
set_list_winbar()

-- Refresh the build badge from the shared cache (which the dashboard polls).
-- No extra API calls here; it just re-reads the record. Standalone runs have no
-- cache, so the badge stays hidden and this is a cheap no-op.
if STATE.review_badge_timer then pcall(vim.fn.timer_stop, STATE.review_badge_timer) end
STATE.review_badge_timer = vim.fn.timer_start(10000, function()
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    set_list_winbar()
  else
    pcall(vim.fn.timer_stop, STATE.review_badge_timer)
    STATE.review_badge_timer = nil
  end
end, { ["repeat"] = -1 })

vim.cmd("rightbelow vsplit")
diff_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(diff_win, vim.api.nvim_create_buf(false, true))
UI.plain_window(diff_win, { number = true })
vim.api.nvim_set_current_win(list_win)

-- Size the list to the longest row so file names aren't truncated, but keep it
-- within sane bounds so the diff pane still has room. +5 for sign/gutter/pad.
function fit_list_width()
  if not (list_win and vim.api.nvim_win_is_valid(list_win)) then return end
  local longest = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line))
  end
  local cap = math.max(20, math.floor(vim.o.columns * 0.6))
  local w = math.min(cap, math.max(20, longest + 5))
  pcall(vim.api.nvim_win_set_width, list_win, w)
end
fit_list_width()

-- Redraw everything that depends on the active-only / ignore-text filters:
-- the diff decorations, the Overview row's comment count (and its content, if
-- currently shown), the per-file (closed/total) rows, and both winbars.
-- Shared by toggle_active_filter and manage_ignore_texts.
local function refresh_after_filter_change()
  redecorate_all()
  refresh_overview_row()
  render_overview()
  refresh_file_rows()
  set_list_winbar()
  if diff_win and vim.api.nvim_win_is_valid(diff_win) then
    local path = paths_by_buf[vim.api.nvim_win_get_buf(diff_win)]
    if path then set_diff_winbar(path) end
  end
end

redraw_after_write = refresh_after_filter_change

-- Flip the active-only filter and redraw everything that depends on it.
toggle_active_filter = function()
  active_only = not active_only
  refresh_after_filter_change()
  notify("Comment filter: " .. (active_only and "active only" or "all statuses") .. ".")
end

-- Flip ignore-whitespace (gw) and rebuild every diff currently on screen for
-- it. Switches content_cache to the other cached variant (cache.lua
-- keeps both warm side by side), then drops every per-path diff buffer:
-- ones not currently shown are deleted outright (nothing is looking at
-- them); the one currently shown is rebuilt through open_file so the diff
-- pane refreshes in place, and only then is its old buffer deleted, so the
-- window is never left pointing at a dead buffer. Comments still decorate by
-- (path, side, lineno) and keep working - -w only changes which lines count
-- as changed, not the line numbers of lines that didn't change. Also
-- re-decorates any already-open revision buffer (gd/gr/gf), which reads
-- through ensure_diff_content and so follows the new mode once redecorated.
--
-- This body is also exactly what "changes since my last review" (gi) needs
-- to rebuild for - review/since.lua's toggle just flips EXT.since
-- instead of ignore_ws - so it's factored out as EXT.rebuild_view (built in
-- the closing `do...end` block below, once the rest of this file's locals
-- it closes over - content_cache, diff_cache, open_file, load_files,
-- prefetch_all_diffs, etc. - all exist). EXT.rebuild_view doesn't exist yet
-- if gw is somehow pressed before that block runs (it can't be in practice -
-- nothing reaches user input until the whole file, including that block,
-- has loaded - but this guard costs nothing and keeps this function correct
-- on its own even if that ever changed), so this keeps its own copy of the
-- same steps as a fallback.
toggle_ignore_ws = function()
  ignore_ws = not ignore_ws
  STATE.ignore_ws = ignore_ws

  if EXT.rebuild_view then
    EXT.rebuild_view()
    notify("Diffs: " .. (ignore_ws and "ignoring whitespace" or "showing whitespace") .. ".")
    return
  end

  content_cache = CACHE.diffs(cache_key, ignore_ws)

  local shown = current_file_path
  local shown_entry = nil
  for path, entry in pairs(diff_cache) do
    if entry.buf then
      maps_by_buf[entry.buf] = nil
      paths_by_buf[entry.buf] = nil
      comments_by_buf[entry.buf] = nil
    end
    if path == shown then
      shown_entry = entry
    elseif entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
    end
  end
  diff_cache = {}
  if shown and shown ~= OVERVIEW_MARK and files_loaded then
    open_file(shown, false)
  end
  if shown_entry and shown_entry.buf and vim.api.nvim_buf_is_valid(shown_entry.buf) then
    pcall(vim.api.nvim_buf_delete, shown_entry.buf, { force = true })
  end

  prefetch_all_diffs()
  refresh_after_filter_change()

  for _, buf in pairs(nav_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then decorate_revision(buf) end
  end

  notify("Diffs: " .. (ignore_ws and "ignoring whitespace" or "showing whitespace") .. ".")
end

-- Manage the list of comment text filters in a small floating popup: `a` adds
-- a new one (prompts for text), `p` toggles persistence for the filter under
-- the cursor (persistent ones are saved to FILTERS_FILE and reloaded in every
-- future review session), `dd`/`x` removes the one under the cursor, `q`/<Esc>
-- closes. Each change immediately redraws everything that depends on the
-- filters via refresh_after_filter_change above. Pass on_change to also
-- refresh a caller-specific view (e.g. the K popup underneath) after every
-- add/remove/toggle.
manage_ignore_texts = function(on_change)
  local width = math.max(50, math.min(90, math.floor(vim.o.columns * 0.5)))
  local height = math.min(20, math.max(8, #ignore_texts + 6))

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype = "nofile"

  -- 1-based buffer line -> index into ignore_texts (nil on header/footer rows).
  local row_idx = {}
  local function render()
    row_idx = {}
    local lines = { "Comment text filters (hide threads whose first comment contains any of these):", "" }
    if #ignore_texts == 0 then
      lines[#lines + 1] = "  (none — press a to add one)"
    else
      for i, f in ipairs(ignore_texts) do
        lines[#lines + 1] = "  " .. i .. ". " .. (f.persistent and "[P] " or "") .. f.text
        row_idx[#lines] = i
      end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "(a: add   p: persistent [P]   s: set status for all matches   dd/x: remove   q/<Esc>: close)"
    return lines
  end

  local function draw()
    if not vim.api.nvim_buf_is_valid(fbuf) then return end
    vim.bo[fbuf].modifiable = true
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, render())
    vim.bo[fbuf].modifiable = false
  end
  draw()

  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })
  set_float_wrap(win)

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local kopts = { buffer = fbuf, silent = true, nowait = true }
  vim.keymap.set("n", "a", function()
    require("azure-cli.prompt").input({ prompt = "Add text filter:", silent = true }, function(input)
      if input then
        table.insert(ignore_texts, { text = input:lower(), persistent = false })
        refresh_after_filter_change()
        if on_change then on_change() end
        notify("Added text filter: " .. input .. " (not persistent — press p on it to keep it across sessions).")
      end
      draw()
    end)
  end, kopts)
  vim.keymap.set("n", "p", function()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local idx = row_idx[lnum]
    if not idx then
      notify("Not on a filter row.", vim.log.levels.WARN)
      return
    end
    local f = ignore_texts[idx]
    f.persistent = not f.persistent
    save_persistent_filters(ignore_texts)
    if f.persistent then
      notify("'" .. f.text .. "' will persist across sessions.")
    else
      notify("'" .. f.text .. "' is no longer persistent.")
    end
    draw()
  end, kopts)
  vim.keymap.set("n", "s", function()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local idx = row_idx[lnum]
    if not idx then
      notify("Not on a filter row.", vim.log.levels.WARN)
      return
    end
    local f = ignore_texts[idx]
    local matches = threads_matching_text(f.text)
    require("azure-cli.prompt").select({
      prompt = "Set status for " .. #matches .. " comment(s) matching '" .. f.text .. "'",
      items = STATUS_OPTIONS,
    }, function(o)
      if not o then return end
      apply_status_to_matches(matches, o, "'" .. f.text .. "'", function()
        refresh_after_filter_change()
        if on_change then on_change() end
        draw()
      end)
    end)
  end, kopts)
  local function remove_under_cursor()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local idx = row_idx[lnum]
    if not idx then
      notify("Not on a filter row.", vim.log.levels.WARN)
      return
    end
    local removed = table.remove(ignore_texts, idx)
    if removed.persistent then save_persistent_filters(ignore_texts) end
    refresh_after_filter_change()
    if on_change then on_change() end
    notify("Removed text filter: " .. removed.text)
    draw()
  end
  vim.keymap.set("n", "dd", remove_under_cursor, kopts)
  vim.keymap.set("n", "x", remove_under_cursor, kopts)
  vim.keymap.set("n", "q", close, kopts)
  vim.keymap.set("n", "<Esc>", close, kopts)
end

-- Jump to the next (dir=1) / previous (dir=-1) file row that has at least
-- one comment thread once the gA active-only / gF text filters are applied -
-- same "filtered" total used for each row's "(closed/total)" suffix, so
-- this only stops on files whose badge is actually showing. Walks
-- EXT.filelist's own row numbering (directory headers included, skipped
-- over silently since they're never in row_to_file) rather than `files`
-- directly, since the grouped/sorted display order can now differ from it.
-- Cursor lines are offset by +1 versus model row numbers since the Overview
-- row is pinned at line 1.
local function jump_file_with_comments(dir)
  local model = EXT.filelist
  if not model or #model.ordered_files == 0 then
    notify("No files in this PR.")
    return
  end
  local i = (vim.api.nvim_win_get_cursor(0)[1] - 1) + dir
  while i >= 1 and i <= #model.lines do
    local path = model.row_to_file[i]
    if path then
      local _, total = file_thread_count(path)
      if total > 0 then
        vim.api.nvim_win_set_cursor(0, { i + 1, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
    i = i + dir
  end
  notify(dir > 0 and "No further files with comments." or "No previous files with comments.")
end

HELP.list_help = {
  "Navigate",
  { "open", "open and focus the file" },
  { "next_file_with_comments", "next file with comments" }, { "prev_file_with_comments", "previous file with comments" },
  { "next_unviewed", "next file not yet viewed" },
  { "prev_unviewed", "previous file not yet viewed" },
  { "search", "search text across the PR's changed files" },
  "Comment",
  { "comment_file", "comment on the whole file" },
  { "pr_comment", "new PR-level comment" },
  "Review",
  { "toggle_viewed", "toggle the file's viewed mark" },
  { "vote", "vote" }, { "complete", "complete" },
  "Modes",
  { "active_filter", "toggle active (unresolved) comments only" },
  { "filters", "manage text filters that hide matching threads" },
  { "ignore_ws", "toggle ignoring whitespace in diffs" },
  "Session",
  { "resize_less", "shrink the list" }, { "resize_more", "grow the list" },
  { "config", "open the config file" },
  { "back", "back to the PR list" },
  { "quit", "close the reviewer" },
  { "help", "this help" },
}

-- File-list keys, shown by `?` there.
local function show_file_list_help()
  open_float(KEYS.help_lines("list", "File list keys", HELP.list_help, {
    now = EXT.mode_tags and EXT.mode_tags() or {},
    fixed = { "  j / k       move; the right pane previews the file as you go" },
    extra = EXT.help.list, extra_title = "Features",
  }), true, { min_width = 60 })
end

-- File-list keymaps. Line 1 is the pinned Overview row; files (and, now,
-- their directory header rows - see review/filelist.lua) occupy the rest.
-- EXT.filelist.row_to_file[line - 1] is the row->file map every site below
-- that used to index `files` by row now goes through instead - nil on a
-- directory header row, same as it used to be nil on nothing (there were no
-- unselectable rows before).
KEYS.bind(list_buf, "list", "open", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if line == OVERVIEW_ROW then
    open_overview(true)
    return
  end
  if not files_loaded then
    notify("Still loading the file list…")
    return
  end
  local path = EXT.filelist and EXT.filelist.row_to_file[line - 1]
  if not path then
    notify("That's a directory header, not a file.", vim.log.levels.WARN)
    return
  end
  open_file(path, true)
end, { desc = "open and focus the file" })
KEYS.bind(list_buf, "list", "toggle_viewed", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  EXT.toggle_viewed(EXT.filelist and EXT.filelist.row_to_file[line - 1])
end, { desc = "toggle the file's viewed mark" })
KEYS.bind(list_buf, "list", "next_unviewed", function() EXT.jump_unviewed(1) end, { desc = "next file not yet viewed" })
KEYS.bind(list_buf, "list", "prev_unviewed", function() EXT.jump_unviewed(-1) end, { desc = "previous file not yet viewed" })
KEYS.bind(list_buf, "list", "back", leave, { desc = "back to the PR list" })
KEYS.bind(list_buf, "list", "quit", leave, { desc = "close the reviewer" })
KEYS.bind(list_buf, "list", "pr_comment", comment_on_pr, { desc = "new PR-level comment" })
KEYS.bind(list_buf, "list", "search", function() nav_search_files() end, { desc = "search text across the PR's changed files" })
KEYS.bind(list_buf, "list", "active_filter", toggle_active_filter, { desc = "toggle active (unresolved) comments only" })
KEYS.bind(list_buf, "list", "filters", manage_ignore_texts, { desc = "manage text filters that hide matching threads" })
KEYS.bind(list_buf, "list", "ignore_ws", toggle_ignore_ws, { desc = "toggle ignoring whitespace in diffs" })
KEYS.bind(list_buf, "list", "config", open_config_file, { desc = "open the config file" })
KEYS.bind(list_buf, "list", "vote", cast_vote, { desc = "vote" })
KEYS.bind(list_buf, "list", "complete", complete_pr, { desc = "complete" })
KEYS.bind(list_buf, "list", "next_file_with_comments", function() jump_file_with_comments(1) end, { desc = "next file with comments" })
KEYS.bind(list_buf, "list", "prev_file_with_comments", function() jump_file_with_comments(-1) end, { desc = "previous file with comments" })
KEYS.bind(list_buf, "list", "resize_less", function() resize_list(-5) end, { desc = "shrink the list" })
KEYS.bind(list_buf, "list", "resize_more", function() resize_list(5) end, { desc = "grow the list" })
KEYS.bind(list_buf, "list", "comment_file", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if line == OVERVIEW_ROW then
    notify("Open the Overview page (<CR>) and press c to add a PR-level comment.", vim.log.levels.WARN)
    return
  end
  local path = EXT.filelist and EXT.filelist.row_to_file[line - 1]
  if not path then
    notify("That's a directory header, not a file.", vim.log.levels.WARN)
    return
  end
  comment_on_file(path)
end, { desc = "comment on the whole file" })
KEYS.bind(list_buf, "list", "help", show_file_list_help, { desc = "this help" })
-- Reviewer-feature keys registered via ctx.add_key("list", ...) - see EXT
-- near the top of this file.
for _, e in ipairs(EXT.keys.list) do
  vim.keymap.set(e.mode or "n", e.key, e.fn, { buffer = list_buf, silent = true, nowait = true, desc = e.desc })
end

-- Preview-on-move: scrolling the list updates the diff pane (Overview or a
-- file's diff) without stealing focus. Debounced (like the dashboard's own
-- hover-prefetch) so holding j/k / scrolling past several rows doesn't
-- build/switch content for every intermediate row — only the one the cursor
-- actually settles on. A directory header row (see review/filelist.lua)
-- isn't a "file" any handler here can act on, so the cursor never rests on
-- one: landing there (j/k, gg/G, a search, a mouse click) hops it to the
-- next file row in the direction it was travelling - or back the other
-- way at the list's edge. EXT.list_last_line remembers the previous row so
-- the direction is known (a field on EXT, not a new top-level local).
local preview_timer
vim.api.nvim_create_autocmd("CursorMoved", {
  buffer = list_buf,
  callback = function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local model = EXT.filelist
    if model and line ~= OVERVIEW_ROW and not model.row_to_file[line - 1] then
      local prev = EXT.list_last_line or OVERVIEW_ROW
      local dir = line >= prev and 1 or -1
      local total = vim.api.nvim_buf_line_count(list_buf)
      local target
      local i = line + dir
      while i >= OVERVIEW_ROW and i <= total do
        if i == OVERVIEW_ROW or model.row_to_file[i - 1] then target = i break end
        i = i + dir
      end
      if not target then
        i = line - dir
        while i >= OVERVIEW_ROW and i <= total do
          if i == OVERVIEW_ROW or model.row_to_file[i - 1] then target = i break end
          i = i - dir
        end
      end
      if target and target ~= line then
        -- Moving the cursor from inside this callback does not fire another
        -- CursorMoved, so fall through and preview the row we hopped to.
        vim.api.nvim_win_set_cursor(0, { target, 0 })
        line = target
      end
    end
    EXT.list_last_line = line
    if preview_timer then vim.fn.timer_stop(preview_timer) end
    preview_timer = vim.fn.timer_start(80, function()
      if line == OVERVIEW_ROW then
        open_overview(false)
        return
      end
      local path = EXT.filelist and EXT.filelist.row_to_file[line - 1]
      if path then open_file(path, false) end
    end)
  end,
})

-- Start on the Overview row and prime it in the diff pane, same as any file.
-- A VimEnter autocmd re-applies the cursor because Neovim resets it to line 1
-- after sourcing the init script (which happens to already be the Overview
-- row here, but keep this explicit rather than relying on the coincidence).
pcall(vim.api.nvim_win_set_cursor, list_win, { OVERVIEW_ROW, 0 })
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      pcall(vim.api.nvim_set_current_win, list_win)
      pcall(vim.api.nvim_win_set_cursor, list_win, { OVERVIEW_ROW, 0 })
    end
  end,
})
open_overview(false)
load_overview_commits()

-- Populate the file list in the background. This used to be a blocking
-- `git diff --name-only` plus two blocking rev-parse checks before anything
-- was drawn - three git spawns, close to a second under git-bash, during
-- which the editor was frozen. The window now opens immediately with a
-- "loading" row and fills in when git returns. A non-zero exit is git's
-- "unknown revision" (128): the branch was deleted, or this PR's repo isn't
-- the clone we're pointed at - the same cases the rev-parse pair guarded.
-- `status` (path -> "A"/"M"/"D"/"R", see load_files below) is optional -
-- nil the first time this is called from the dashboard's plain-paths cache
-- (status letters aren't part of that cache), filled in moments later by
-- load_files' own background `--name-status` fetch re-calling this.
local function apply_files(list, status)
  if not vim.api.nvim_buf_is_valid(list_buf) then return end
  files = list
  files_loaded = true
  EXT.file_status = status or {}
  -- Since-mode's file_count (read by build_overview and the winbar tags) -
  -- the count of files actually changed in the since-range, which is
  -- exactly what `files` holds whenever EXT.since is on (load_files/
  -- apply_files diff EXT.since.range instead of RANGE below).
  if EXT.since then EXT.since.file_count = #files end
  if #files == 0 then
    -- In since-mode, an empty sub-range is a normal outcome (e.g. a
    -- force-push that touched no files, or a merge with nothing new) rather
    -- than a broken PR - show an empty (but valid) file list instead of the
    -- "no changed files at all"/EMBED-closing treatment below, which is only
    -- ever right for the PR's real (non-since) range.
    EXT.refresh_file_list()
    if EXT.since then
      notify("No files changed since your last review.")
      set_list_winbar()
      return
    end
    notify("No changed files in this PR (range " .. RANGE .. ").", vim.log.levels.WARN)
    if EMBED then leave() end
    return
  end
  EXT.refresh_file_list()
  set_list_winbar()
  prefetch_all_diffs()
  notify("PR #" .. ID .. ": " .. #files
    .. " files. j/k move, <CR> open, c comment, K view, R reply. Overview is the first row.")
end
-- `git diff --name-status` (not just --name-only) so the file list can show
-- each file's A/M/D/R status letter (review/filelist.lua) - status is part
-- of the SAME fetch as the path list here, but the dashboard's own prefetch
-- cache (CACHE.files, checked first below) only ever has plain paths from
-- its own --name-only warm, so a cache hit paints instantly with blank
-- status letters and this still runs in the background to fill them in.
local function load_files()
  local range = (EXT.since and EXT.since.range) or RANGE
  local variant = EXT.since and EXT.since.variant or nil
  local cached = CACHE.files(cache_key, variant)
  if cached then
    apply_files(cached, nil)
  end
  local out, err = {}, {}
  vim.fn.jobstart(git_args("diff", "--name-status", range), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(list_buf) then return end
        if code ~= 0 then
          if cached then return end  -- already showing the cached list; the status refresh alone failing isn't fatal
          notify("Cannot diff PR #" .. ID .. " (" .. range .. "): branch not found in "
            .. (REPO_PATH ~= "" and REPO_PATH or "the current repo")
            .. ". It may be deleted, or repo '" .. (env.AZVICLI_REPO or "?")
            .. "' isn't cloned here.", vim.log.levels.ERROR)
          if EMBED then leave() end
          return
        end
        -- git's raw --name-status/--name-status-style plumbing shape
        -- ("STATUS<TAB>path", or "R100<TAB>old<TAB>new" for a rename) -
        -- review/commits.lua's M.parse_name_status already parses exactly
        -- this (its own `git show --name-status`), reused here rather than
        -- duplicated; require()d inline (costs no top-level local - see
        -- this file's own 200-local comment).
        local entries = require("azure-cli.review.commits").parse_name_status(out)
        local list, status = {}, {}
        for _, e in ipairs(entries) do
          list[#list + 1] = e.path
          status[e.path] = e.status
        end
        if not cached then
          CACHE.set_files(cache_key, list, variant)
        end
        apply_files(list, status)
      end)
    end,
  })
end
load_files()

-- The shared body toggle_ignore_ws (gw) and review/since.lua's gi
-- both rebuild the reviewer for: recompute the active content_cache bucket
-- (ignore_ws and/or EXT.since's variant - see cache.lua's M.diffs),
-- drop every diff buffer (the shown one is rebuilt in place via open_file,
-- others are deleted outright), optionally reload the file list (load_files
-- - a since-range change can add/drop files, unlike a plain gw toggle) or
-- just re-run prefetch_all_diffs, then refresh every winbar/decoration.
-- Assigned to EXT.rebuild_view (never a new top-level local - see EXT's own
-- comment) as its own top-level function, right here rather than nested
-- inside the closing `do...end` IIFE that builds ctx: that IIFE already
-- closes over most of this file's locals to populate ctx, close enough to
-- LuaJIT's 60-upvalues-per-function ceiling that nesting this function's
-- body inside it (another dozen-plus outer locals of its own) pushed it
-- over; declared here instead, at the main chunk's top level like
-- toggle_ignore_ws itself, it only pulls in the upvalues it actually needs.
EXT.rebuild_view = function(reload_files)
  content_cache = CACHE.diffs(cache_key,
    EXT.since and (EXT.since.variant .. (ignore_ws and ":iws" or "")) or ignore_ws)

  local shown = current_file_path
  local shown_entry = nil
  for path, entry in pairs(diff_cache) do
    if entry.buf then
      maps_by_buf[entry.buf] = nil
      paths_by_buf[entry.buf] = nil
      comments_by_buf[entry.buf] = nil
    end
    if path == shown then
      shown_entry = entry
    elseif entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
    end
  end
  diff_cache = {}

  if reload_files then
    load_files()
  end

  if shown and shown ~= OVERVIEW_MARK and files_loaded then
    open_file(shown, false)
  end
  if shown_entry and shown_entry.buf and vim.api.nvim_buf_is_valid(shown_entry.buf) then
    pcall(vim.api.nvim_buf_delete, shown_entry.buf, { force = true })
  end

  if not reload_files then
    prefetch_all_diffs()
  end
  refresh_after_filter_change()

  for _, buf in pairs(nav_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then decorate_revision(buf) end
  end
end

-- Re-fetch PR comment threads from ADO and re-decorate every open diff buffer
-- plus the Overview row/page. Called at startup and after posting a comment so
-- new comments show without leaving and re-entering the PR. Pass announce=true
-- to notify how many threads loaded.
--
-- Parses each poll into a scratch copy of the thread tables and diffs it
-- against the live ones (by thread id + comment count) instead of always
-- wiping and rebuilding them: the live tables are only swapped in, and the
-- UI only redecorated, when something actually changed. On top of that, any
-- newly-appeared comments authored by someone else are checked against "my"
-- scope (my own pull request, or a thread I've participated in) and the
-- current active-only/text filters, and surfaced as a notification when they
-- qualify - so posting your own comment, someone else commenting on a PR/
-- thread that isn't yours, or a filtered-out comment never notifies.
local threads_baseline_established = false
-- Apply a thread-list JSON payload: parse, diff against what's shown, swap in
-- and redecorate only on change, notify on qualifying new comments. Shared by
-- the network fetch below and the cache seed at open. opts.seed marks a
-- payload that came from the dashboard's prefetch cache: it's shown at once
-- for a first paint but never becomes the notification baseline, so anything
-- that arrived since the cache was filled still notifies when the real fetch
-- lands rather than being silently absorbed.
local function apply_threads_json(json, opts)
      opts = opts or {}
      -- Parse into a scratch copy first so we can diff before touching the
      -- live tables the decoration closures read from.
      local new_by_key, new_file_by_path, new_general = {}, {}, {}
      parse_threads(json, new_by_key, new_file_by_path, new_general)

      local prev_counts = snapshot_comment_counts(threads_by_key, file_threads_by_path, general_threads)
      local new_counts = snapshot_comment_counts(new_by_key, new_file_by_path, new_general)

      local changed = false
      for id, n in pairs(new_counts) do
        if prev_counts[id] ~= n then changed = true break end
      end
      if not changed then
        for id in pairs(prev_counts) do
          if new_counts[id] == nil then changed = true break end
        end
      end

      if changed then
        -- Reassigning these (module-level) locals updates every closure that
        -- captured them as an upvalue, so this is a safe swap-in even though
        -- decoration code elsewhere holds no separate reference to copy.
        threads_by_key, file_threads_by_path, general_threads = new_by_key, new_file_by_path, new_general
        reapply_pending()

        if threads_baseline_established then
          -- Only notify once we have a real baseline to diff against, so the
          -- very first load of a PR's existing comments doesn't spam a
          -- notification for every pre-existing thread.
          local events = find_new_comments(prev_counts, IS_MY_PR, new_by_key, new_file_by_path, new_general)
          notify_new_comments(events)
        end

        redecorate_all()
        refresh_overview_row()
        refresh_file_rows()
        render_overview()
      end
      if not opts.seed then threads_baseline_established = true end

      if opts.announce then
        local n = #general_threads
        for _, t in pairs(threads_by_key) do n = n + #t end
        if n > 0 then
          notify(n .. " comment thread(s) loaded.")
        end
      end
end

refresh_threads = function(opts)
  opts = opts or {}
  local chunks = {}
  local err_chunks = {}
  EXT.rpc.run(EXT.provider({ "--threads" }), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(chunks, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err_chunks, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then
        -- Surface the failure instead of silently showing zero comments -
        -- e.g. a bad/expired PAT, network error, or misconfigured account
        -- would otherwise look identical to "this PR has no comments".
        local raw = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err_chunks), "\n")
        local LOG = require("azure-cli.log")
        local shown
        if raw ~= "" then
          LOG.record("PR #" .. ID .. " comments", raw)
          shown = ": " .. LOG.summary(raw, vim.o.columns) .. "  (:AzureCli log)"
        else
          shown = " - check azure-cli.yml (PAT/org_url) and connectivity."
        end
        notify("Failed to load PR comments (exit " .. code .. ")" .. shown, vim.log.levels.ERROR)
        if opts.on_done then opts.on_done() end
        return
      end

      local json = table.concat(chunks, "\n")
      -- Keep the shared cache current so re-opening this PR (or the
      -- dashboard's next prefetch) starts from what was just fetched.
      local pr = current_pr_record()
      CACHE.set_threads(ID, json, pr and pr.totalThreads or nil)
      apply_threads_json(json, opts)
      if opts.on_done then opts.on_done() end
    end,
  })
end

-- Paint the comments straight from the dashboard's prefetch cache when it
-- has them (normally the case: filled while the cursor rested on the PR),
-- then fetch for real in the background so the view is authoritative within
-- a round-trip either way. Without a cached copy the first fetch announces.
-- Periodic check for a new push (the poll's other job, alongside comment
-- threads below): a force-push or plain push adds a new iteration, and that
-- should surface the same way a new comment does (notify_new_comments,
-- above) instead of sitting unnoticed until gi or a reopen happens to
-- catch it - and the new diff should then load by itself, rather than
-- leaving a notification that only tells you to go press something.
--
-- Two separate signals, deliberately, because they become true at
-- different times:
--
--   the notification  fires off ADO's own --iterations count (a push adds
--                     one), so it's immediate and authoritative.
--   the reload        waits until origin/<source> has actually moved in
--                     the local clone. Nothing in this file ever runs `git
--                     fetch` - the dashboard owns that (its warm_all pass,
--                     keyed on each PR's updatedIso, with its own
--                     per-clone coalescing so two fetches never fight over
--                     ref locks), and it keeps running while a PR is open
--                     in an embedded reviewer tab. Rebuilding the moment
--                     ADO says "pushed" would just re-diff the same stale
--                     ref and throw the reader's position away for
--                     nothing, so the SHA check below is what gates it:
--                     one poll later, once the fetch has landed, the
--                     rebuild has something new to show. If the dashboard
--                     was swapped away entirely no fetch ever happens, the
--                     SHA never moves, and this stays a notification only.
--
-- State lives on EXT (never a new top-level local - see EXT's own comment
-- near its declaration) since this file is already at LuaJIT's 200-local
-- ceiling for its main chunk.
EXT.iteration_count = nil  -- nil until the first successful fetch establishes a baseline
EXT.iterations_inflight = false
EXT.source_sha = nil       -- origin/<source> the shown diffs were built against
EXT.check_new_push = function()
  if EXT.iterations_inflight then return end
  EXT.iterations_inflight = true
  local chunks = {}
  EXT.rpc.run(EXT.provider({ "--iterations" }), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(chunks, d) end end,
    on_exit = function(_, code)
      EXT.iterations_inflight = false
      if code ~= 0 then return end
      local ok, decoded = pcall(vim.json.decode, table.concat(chunks, "\n"),
        { luanil = { object = true, array = true } })
      if not ok or type(decoded) ~= "table" then return end
      local list = decoded.value or decoded
      if type(list) ~= "table" then return end
      local n = #list
      if EXT.iteration_count == nil then
        EXT.iteration_count = n
        return
      end
      if n > EXT.iteration_count then
        local added = n - EXT.iteration_count
        EXT.iteration_count = n
        local msg = added .. " new push" .. (added == 1 and "" or "es") .. " on PR #" .. ID
          .. " \u{2014} fetching\u{2026}"
        notify(msg)
        if EXT.notify then EXT.notify.toast("PR #" .. ID, msg) end
        vim.schedule(EXT.fetch_new_commits)
      end
    end,
  })
end

-- Fetches the commits ADO just told us about, instead of waiting for the
-- dashboard's own poll to get round to it.
--
-- The dashboard is still the component that owns fetching (warm_pr runs
-- this same provider prefetch), and this deliberately runs the identical
-- job rather than its own `git fetch`, taking part in the same
-- STATE.warm.warming mutex so the two never fetch one clone at once and
-- fight over ref locks. What it doesn't do is wait for the dashboard's
-- timer: that's a separate 30s cycle from this one, so relying on it left
-- up to a minute of nothing visible between "new push" and the diff
-- changing - long enough that quitting and reopening looks like the only
-- thing that works.
--
-- The PR's own env is passed explicitly (opts.env wins over the ambient
-- AZVICLI_* the daemon otherwise forwards) because vim.env follows
-- whichever PR the dashboard opened most recently - with a second reviewer
-- tab open, inheriting it would fetch the other PR's branches.
EXT.fetch_new_commits = function()
  local warm = STATE.warm
  local warming = warm and warm.warming
  if warming and warming[tostring(ID)] then return end  -- dashboard already on it
  if EXT.fetch_inflight then return end
  EXT.fetch_inflight = true
  if warming then warming[tostring(ID)] = true end
  local function done()
    EXT.fetch_inflight = false
    if warming then warming[tostring(ID)] = nil end
  end
  local ok = pcall(EXT.rpc.run, EXT.provider({}), {
    env = {
      AZVICLI_PREFETCH = "1",
      AZVICLI_PR = tostring(ID),
      AZVICLI_ORG = ORG,
      AZVICLI_PROJECT = PROJECT,
      AZVICLI_REPO = env.AZVICLI_REPO or "",
      AZVICLI_SOURCE = SOURCE,
      AZVICLI_TARGET = TARGET,
      AZVICLI_REPO_PATH = REPO_PATH,
    },
    on_exit = function(_, code)
      done()
      if code == 0 then EXT.check_source_sha() end
    end,
  })
  if not ok then done() end
end

-- True while pulling the view out from under the user would lose something
-- they're in the middle of: any focusable floating window (the comment
-- editor, a prompt/select, an expanded thread) or a non-normal mode. The
-- flashes notify() puts in the corner are non-focusable, so this session's
-- own "new push" notification never blocks its own reload. Nothing is
-- dropped when this defers - the SHA comparison below simply doesn't match
-- yet on this tick, and the next poll tries again.
EXT.reload_would_interrupt = function()
  local mode = vim.fn.mode()
  if mode ~= "n" and mode ~= "" then return true end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative ~= "" and cfg.focusable ~= false then return true end
  end
  return false
end

-- Rebuilds the file list and diffs for commits that have landed in the
-- clone since this view was built, putting the reader back on the source
-- line they were on rather than at the top of the file: the line numbers
-- shift when the diff changes, so the cursor is re-anchored by the
-- {side, lineno} the old buffer's map had under it (the same way
-- review/followup.lua's open_at_line lands on a thread's line), not by
-- physical buffer line. A line that the push rewrote away simply isn't
-- found and the file opens at the top.
EXT.reload_after_push = function()
  -- Re-key the caches first, or the rebuild below just re-reads the bucket
  -- it already filled at open and repaints the identical diff - visibly
  -- reloading while changing nothing, which is exactly how this failed the
  -- first time it ran live.
  --
  -- cache_key is per PR + version precisely so a push invalidates it, but
  -- it's computed once when the reviewer opens and diff_cache_key() derives
  -- the version from current_pr_record().updatedIso - which only changes
  -- after the *dashboard* has polled. Keying on the source SHA instead uses
  -- what this module just fetched and knows to be current, so re-keying
  -- never waits on another component. A fresh key means empty files/diffs/
  -- commits buckets, so load_files and ensure_diff_content re-run git
  -- against the new origin/<source> rather than serving the old lines.
  -- Reassigning this local updates every closure that captured it, the same
  -- way rebuild_view swaps content_cache.
  if EXT.source_sha then cache_key = CACHE.key(ID, EXT.source_sha) end

  local path = current_file_path
  local anchor, want_path = nil, nil
  if path and path ~= OVERVIEW_MARK and diff_win and vim.api.nvim_win_is_valid(diff_win) then
    local buf = vim.api.nvim_win_get_buf(diff_win)
    local map = maps_by_buf[buf]
    local got, cur = pcall(vim.api.nvim_win_get_cursor, diff_win)
    if got and map and map[cur[1]] then
      want_path = path
      anchor = { side = map[cur[1]].side, lineno = map[cur[1]].lineno }
    end
  end

  EXT.rebuild_view(true)

  if not (want_path and anchor) then return end
  ensure_diff_content(want_path, function()
    vim.schedule(function()
      if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
      local buf = vim.api.nvim_win_get_buf(diff_win)
      if paths_by_buf[buf] ~= want_path then return end  -- moved on meanwhile
      local map = maps_by_buf[buf]
      if not map then return end
      for i, m in ipairs(map) do
        if m.side == anchor.side and m.lineno == anchor.lineno then
          pcall(vim.api.nvim_win_set_cursor, diff_win, { i, 0 })
          pcall(vim.api.nvim_win_call, diff_win, function() vim.cmd("normal! zz") end)
          return
        end
      end
    end)
  end)
end

-- The reload half of the poll: cheap local `git rev-parse` (no network -
-- see EXT.check_new_push's comment for why the fetch isn't ours to run),
-- rebuilding only once the ref the diffs are built from has actually
-- moved.
EXT.check_source_sha = function()
  if SOURCE == "" or EXT.sha_inflight then return end
  EXT.sha_inflight = true
  local out = {}
  -- jobstart answers <= 0 when the spawn itself failed, and then never
  -- calls on_exit - without clearing the flag here the guard above would
  -- latch and this check would be dead for the rest of the session.
  local job = vim.fn.jobstart(git_args("rev-parse", "origin/" .. SOURCE), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      EXT.sha_inflight = false
      if code ~= 0 then return end
      local sha = vim.trim(table.concat(out, ""))
      if sha == "" then return end
      -- Decide and act in one scheduled context: EXT.source_sha must only
      -- move when the rebuild actually happens, or a push deferred for
      -- being mid-edit would be marked as shown and never reloaded.
      vim.schedule(function()
        if EXT.source_sha == nil then
          EXT.source_sha = sha  -- baseline: what the view already shows
          return
        end
        if sha == EXT.source_sha then return end
        if EXT.reload_would_interrupt() then return end  -- try again next poll
        EXT.source_sha = sha
        notify("New commits pulled in \u{2014} reloading the diff\u{2026}")
        EXT.reload_after_push()
      end)
    end,
  })
  if job <= 0 then EXT.sha_inflight = false end
end

do
  local cached = CACHE.threads(ID)
  if cached then
    apply_threads_json(cached.json, { announce = true, seed = true })
  end
  refresh_threads({ announce = cached == nil })
  EXT.check_new_push()
  EXT.check_source_sha()
end

-- Periodic auto-refresh (silent): comment threads, the new-push
-- notification, and the reload that follows the commits into the view once
-- they're in the clone - so per-file closed/total counts, the Overview
-- row/page and the diffs themselves all stay current while this view sits
-- open. See config.lua's timing.poll_seconds for the interval. Each of the
-- three guards its own in-flight flag (refresh_threads_inflight,
-- EXT.iterations_inflight, EXT.sha_inflight) so a slow one is skipped
-- rather than stacked (matches review-pr's other polling timers). Stops
-- itself once the file-list window is gone.
local refresh_threads_inflight = false
local base_refresh_threads = refresh_threads
refresh_threads = function(opts)
  if refresh_threads_inflight then return end
  refresh_threads_inflight = true
  local ok, err = pcall(base_refresh_threads, vim.tbl_extend("force", opts or {}, {
    on_done = function() refresh_threads_inflight = false end,
  }))
  if not ok then
    refresh_threads_inflight = false
    error(err)
  end
end

if STATE.review_threads_timer then pcall(vim.fn.timer_stop, STATE.review_threads_timer) end
STATE.review_threads_timer = vim.fn.timer_start(
  require("azure-cli.config").get().timing.poll_seconds * 1000, function()
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    refresh_threads()
    EXT.check_new_push()
    EXT.check_source_sha()
  else
    pcall(vim.fn.timer_stop, STATE.review_threads_timer)
    STATE.review_threads_timer = nil
  end
end, { ["repeat"] = -1 })

-- The file list keeps its absolute width across a terminal resize
-- otherwise, with the diff pane absorbing all of the change.
vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("AzureCliReviewResize", { clear = true }),
  callback = function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then fit_list_width() end
  end,
})

-- review/followup.lua ("follow up on my comments", gu) needs open_file,
-- ensure_diff_content, reply_to_thread, apply_status and STATUS_OPTIONS on
-- ctx, none of which any earlier module needed - assigned onto EXT here
-- (never a new top-level local - see EXT's own comment), at the main
-- chunk's top level rather than inside the closing `do...end` IIFE below,
-- for exactly the reason EXT.rebuild_view (above) already isn't nested
-- there: that IIFE closes over most of this file's locals to populate
-- `ctx` and sits close to LuaJIT's 60-upvalues-per-function ceiling, so
-- ctx.open_file/etc are wired as `ctx.X = EXT.X` inside the IIFE instead
-- (see the block right before `local ctx = {}` there) - reading them off
-- EXT, which the IIFE already closes over for a dozen other fields, costs
-- it no additional upvalues at all.
STATE.review_cleanup = function()
  for _, name in ipairs({ "review_threads_timer", "review_badge_timer" }) do
    if STATE[name] then pcall(vim.fn.timer_stop, STATE[name]); STATE[name] = nil end
  end
  local bufs = {}
  for _, entry in pairs(diff_cache) do bufs[#bufs + 1] = entry.buf end
  for _, b in pairs(nav_bufs) do bufs[#bufs + 1] = b end
  if overview_buf then bufs[#bufs + 1] = overview_buf end
  bufs[#bufs + 1] = list_buf
  vim.schedule(function()
    for _, b in ipairs(bufs) do
      if b and vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
  end)
end
-- "Viewed" files (review/viewed.lua) - marked when a file is opened with
-- focus, toggled by hand, counted in the winbar, skipped by ]m/[m.
EXT.viewed_stamp = function()
  local rec = current_pr_record()
  return (rec and rec.updatedIso) or ""
end
EXT.viewed_count = function()
  return require("azure-cli.review.viewed").count(ID, files, EXT.viewed_stamp())
end
EXT.mark_viewed = function(path)
  local VIEWED = require("azure-cli.review.viewed")
  if not path or path == OVERVIEW_MARK then return end
  if VIEWED.is_viewed(ID, path, EXT.viewed_stamp()) then return end
  VIEWED.set(ID, path, EXT.viewed_stamp(), true)
  if refresh_file_rows then refresh_file_rows() end
  if set_list_winbar then set_list_winbar() end
end
EXT.toggle_viewed = function(path)
  if not path or path == OVERVIEW_MARK then
    notify("Not on a file.", vim.log.levels.WARN)
    return
  end
  local on = require("azure-cli.review.viewed").toggle(ID, path, EXT.viewed_stamp())
  notify((on and "Viewed: " or "Not viewed: ") .. path)
  if refresh_file_rows then refresh_file_rows() end
  if set_list_winbar then set_list_winbar() end
end
EXT.jump_unviewed = function(dir)
  local model = EXT.filelist
  if not (model and #model.ordered_files > 0) then return end
  local from = (current_file_path and current_file_path ~= OVERVIEW_MARK and EXT.file_index(current_file_path)) or 0
  local idx = require("azure-cli.review.viewed").next_unviewed(ID, model.ordered_files, EXT.viewed_stamp(), from, dir)
  if not idx then
    notify("Every file is marked viewed.")
    return
  end
  EXT.open_file_at(idx)
end
-- <Tab> in the diff pane: expand/collapse the thread(s) on this line as
-- virtual lines under it (see decorate_comments).
EXT.inline_open = {}
EXT.toggle_inline = function()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local per_line = comments_by_buf[buf]
  if not (per_line and per_line[lnum]) then
    notify("No comments on this line.")
    return
  end
  EXT.inline_open[buf] = EXT.inline_open[buf] or {}
  EXT.inline_open[buf][lnum] = not EXT.inline_open[buf][lnum] or nil
  if EXT.inline_open[buf][lnum] then mark_threads_read(per_line[lnum]) end
  if paths_by_buf[buf] and maps_by_buf[buf] then
    vim.api.nvim_buf_clear_namespace(buf, comments_ns, 0, -1)
    decorate_comments(buf, paths_by_buf[buf], maps_by_buf[buf])
  end
end

EXT.cleanup = STATE.review_cleanup
EXT.render_overview = render_overview
EXT.open_file = open_file
EXT.ensure_diff_content = ensure_diff_content
EXT.reply_to_thread = reply_to_thread
EXT.apply_status = apply_status
EXT.STATUS_OPTIONS = STATUS_OPTIONS

-- Reviewer-feature wiring: build `ctx` (the surface every review/*.lua
-- module gets) and load the modules themselves. This has to be the very last
-- thing in the file - every local above already exists by the time this
-- runs, and everything in here is scoped to this immediately-invoked
-- function (a nested function has its own 200-local budget, unlike a
-- `do...end` block, whose locals still count toward the main chunk's
-- limit - see EXT's own comment), so this is where new functionality gets
-- to use as many helper locals as it needs.
--
-- The leading semicolon is required: Neovim's Lua treats a statement that
-- starts with "(" right after another statement as ambiguous syntax and
-- refuses to load the file (standalone luajit accepts it, which is why the
-- luajit -bl check alone didn't catch this - tests/run.sh now also loads
-- every file with a real nvim when one is available).
;(function()
  -- Binds every { key, fn, desc } a module registered under EXT.keys[kind]
  -- (via ctx.add_key) onto an already-existing buffer of that kind. The four
  -- setup_*_keymaps sites do this themselves for buffers they create AFTER
  -- modules are loaded (they read EXT.keys.* live, right there); this is
  -- only needed for the buffers created earlier in the file - the file list
  -- and the Overview page always are, and a diff/revision buffer opened by
  -- an early preview would be too.
  local function apply_ext_keys(kind, buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
    for _, e in ipairs(EXT.keys[kind] or {}) do
      vim.keymap.set(e.mode or "n", e.key, e.fn, { buffer = buf, silent = true, nowait = true, desc = e.desc })
    end
  end

  -- The surface a reviewer-feature module gets. Values pr-review.lua
  -- reassigns later (files, threads_by_key/file_threads_by_path/
  -- general_threads, list_win/diff_win, overview_buf) are exposed as
  -- accessor functions rather than captured directly, so a module always
  -- reads the live value instead of whatever it was when ctx was built.
  local ctx = {}

  ctx.ID, ctx.ORG, ctx.PROJECT, ctx.SOURCE, ctx.TARGET = ID, ORG, PROJECT, SOURCE, TARGET
  ctx.REPO_PATH, ctx.EMBED = REPO_PATH, EMBED
  ctx.provider = EXT.provider
  ctx.rpc = EXT.rpc

  ctx.git_args = git_args
  ctx.notify = notify
  ctx.open_float = open_float
  ctx.run_write = run_write
  ctx.retry_prompt = retry_prompt
  ctx.redraw = redraw
  ctx.refresh_threads = function(...) return refresh_threads(...) end
  ctx.show_hits = show_hits
  ctx.open_revision = open_revision
  ctx.ensure_revision_buf = ensure_revision_buf
  ctx.when_loaded = when_loaded
  ctx.nav_context = nav_context
  ctx.find_thread = find_thread
  ctx.my_id = function() return my_id end
  ctx.my_display_name = my_display_name
  ctx.current_pr_record = current_pr_record
  ctx.files = function() return files end
  ctx.threads = function() return threads_by_key, file_threads_by_path, general_threads end
  ctx.comments_by_buf = comments_by_buf
  ctx.maps_by_buf = maps_by_buf
  ctx.paths_by_buf = paths_by_buf
  ctx.diff_win = function() return diff_win end
  ctx.list_win = function() return list_win end
  ctx.overview_buf = function() return overview_buf end
  ctx.threads_to_lines = threads_to_lines
  ctx.build_overview = build_overview
  ctx.post_new_thread = post_new_thread
  ctx.add_pending_thread = add_pending_thread

  -- Extra fields review/batch.lua needs to intercept/queue an
  -- optimistic write instead of sending it, and to submit a queue later:
  -- the pending-thread confirm/drop pair (add_pending_thread's own confirm/
  -- revert, reused so a queued-then-submitted thread behaves exactly like a
  -- directly-posted one once it lands), the live pending_threads/
  -- pending_replies tables (as accessors, like files()/threads() above, so
  -- reapply_pending - run after every thread refetch - keeps carrying a
  -- queued item's synthetic entry the same way it already does for an
  -- in-flight optimistic write), remove_entry for pulling a dropped queued
  -- item's synthetic thread/comment back out, and VOTE_OPTIONS so the
  -- submit-with-a-vote prompt offers the same choices cast_vote does.
  ctx.confirm_pending_thread = confirm_pending_thread
  ctx.drop_pending_thread = drop_pending_thread
  ctx.pending_threads = function() return pending_threads end
  ctx.pending_replies = function() return pending_replies end
  ctx.remove_entry = remove_entry
  ctx.VOTE_OPTIONS = VOTE_OPTIONS

  -- Extra fields review/commits.lua needed that weren't already
  -- above: decorate_diff/ft_for_path/CACHE.parse_diff to build and colour a
  -- commit's own diff the same way a normal one is, nav_show/nav_back so its
  -- buffers share the gd/gr/gf jump stack (and its winbar restore - see
  -- nav_restore_chrome's EXT.commits.nav_restore branch), mark_current_file
  -- to clear the file-list highlight while one of its buffers is shown, and
  -- overview_commits (reassigned once load_overview_commits' background log
  -- fetch returns, so exposed as an accessor like files/list_win/etc above).
  ctx.decorate_diff = decorate_diff
  ctx.ft_for_path = ft_for_path
  ctx.parse_diff = CACHE.parse_diff
  ctx.nav_show = nav_show
  ctx.nav_back = nav_back
  ctx.mark_current_file = mark_current_file
  ctx.overview_commits = function() return overview_commits end

  -- Fields review/since.lua ("changes since my last review", gi)
  -- needs: EXT.since is the mode's live state (nil when off, else
  -- { range, variant, short, base, new_iterations, at, file_count } - see
  -- that module's header comment), read directly by everywhere in this file
  -- that already reads RANGE/ignore_ws (build_diff_async, load_files,
  -- prefetch_all_diffs, decorate_comments, the winbar builders,
  -- build_overview) since those live in this same chunk; the module itself
  -- runs as a separate one (dofile), so it goes through these two accessors
  -- instead of touching EXT.since directly. ctx.rebuild_view is
  -- EXT.rebuild_view - defined as its own top-level `EXT.rebuild_view =
  -- function...` near toggle_ignore_ws/load_files, NOT nested in here: this
  -- IIFE's own upvalue count (one per outer local it already closes over to
  -- build ctx) is close enough to LuaJIT's 60-upvalue-per-function ceiling
  -- that nesting rebuild_view's body inside it (needing another dozen-plus
  -- outer locals of its own) pushed it over. A function declared directly at
  -- the main chunk's top level, like toggle_ignore_ws itself, only counts
  -- the upvalues IT needs, so that's where it lives instead - wrapped here
  -- only so a module can call it through ctx even on the (practically
  -- impossible, see toggle_ignore_ws's own comment) chance it isn't set yet.
  -- reload_files is true whenever the file list itself might have changed
  -- (entering/leaving/re-picking a since-range) and false for a plain gw
  -- toggle, which never changes which files are in the PR.
  ctx.since = function() return EXT.since end
  ctx.set_since = function(v) EXT.since = v end
  ctx.rebuild_view = function(reload_files)
    if EXT.rebuild_view then EXT.rebuild_view(reload_files) end
  end

  -- Fields review/followup.lua ("follow up on my comments", gu) needs on
  -- top of the above, all read off EXT rather than closed over directly -
  -- see the comment where EXT.open_file/etc are assigned, right before this
  -- IIFE, for why. open_file/ensure_diff_content let it open a thread's
  -- file and land the cursor on its line the same way the diff pane's own
  -- ]c/]C cross-file stepping does; reply_to_thread/apply_status/
  -- STATUS_OPTIONS let its picker's R/s keys reuse the exact same
  -- optimistic-write flow every other reply/status change in this file
  -- goes through, instead of reimplementing it.
  ctx.open_file = EXT.open_file
  ctx.ensure_diff_content = EXT.ensure_diff_content
  ctx.reply_to_thread = EXT.reply_to_thread
  ctx.apply_status = EXT.apply_status
  ctx.STATUS_OPTIONS = EXT.STATUS_OPTIONS

  -- Registers { key = key, fn = fn, desc = desc } for surface `kind`
  -- ("list" | "diff" | "overview" | "nav") into EXT.keys[kind]/EXT.help[kind].
  -- `action` is an action name resolved through KEYS (lua/azure-cli/keys.lua)
  -- against config.lua's defaults for that surface - NOT a literal key -
  -- since stage 2, so a module never hard-codes its own key either; see
  -- config.lua's DEFAULT_KEYS for each module's action name(s) (commits,
  -- since, batch_toggle/batch_queue/batch_submit, edit_comment/
  -- delete_comment, open_commit, comment_range). An unbound action
  -- (resolves to nil - `false` in the user's config) registers nothing at
  -- all, same as any other action. A multi-key action registers one
  -- EXT.keys[kind] entry per key (so every key actually binds) but a single
  -- EXT.help[kind] entry (so the `?` popup shows one "key1 / key2" line,
  -- not a duplicate). Call while a module loads (below) - before the
  -- re-apply pass a few lines down, and before any buffer of that kind
  -- created afterwards (which reads EXT.keys.<kind> itself when it's set up).
  ctx.add_key = function(kind, action, fn, desc, mode)
    local keyspec = KEYS.resolve(kind, action)
    if not keyspec then return end
    local keylist = type(keyspec) == "table" and keyspec or { keyspec }
    for _, k in ipairs(keylist) do
      table.insert(EXT.keys[kind], { key = k, fn = fn, desc = desc, mode = mode or "n" })
    end
    table.insert(EXT.help[kind], { key = table.concat(keylist, " / "), desc = desc })
  end

  -- Registers a callback the K popup (show_comments_here) invokes with
  -- (fbuf, threads) right after it opens its float - see the call site's
  -- comment for why that surface can't be reached through EXT.keys.*.
  ctx.on_comment_popup = function(fn)
    table.insert(EXT.on_comment_popup, fn)
  end

  EXT.notify = require("azure-cli.notify")
  EXT.comments = require("azure-cli.review.comments")(ctx)
  EXT.commits = require("azure-cli.review.commits")(ctx)
  EXT.range = require("azure-cli.review.range")(ctx)
  EXT.batch = require("azure-cli.review.batch")(ctx)
  -- Named EXT.since_mod, not EXT.since (see the module's own header comment
  -- and ctx.since/ctx.set_since just above): EXT.since is the mode's live
  -- state, not this module.
  EXT.since_mod = require("azure-cli.review.since")(ctx)
  -- review/followup.lua ("follow up on my comments", gu) reuses
  -- review/since.lua's M.fetch_base to find the same base commit `gi`
  -- would diff from - see that function's own comment - rather than
  -- re-running the --threads/--iterations/`git cat-file` sequence itself.
  ctx.fetch_since_base = EXT.since_mod.fetch_base
  EXT.followup = require("azure-cli.review.followup")(ctx)

  -- File-list access for code defined before `files`/`open_file` exist
  -- (jump_change's cross-file stepping - ]c/]C crossing from the last/first
  -- hunk or comment of one file into the next/previous one). Indexed over
  -- EXT.filelist.ordered_files - the grouped/sorted DISPLAY order - rather
  -- than `files`' own (git-reported) order, so "next file" matches what
  -- ]c/]C actually shows moving down the file list.
  EXT.file_index = function(path)
    local model = EXT.filelist
    if not model then return nil end
    for i, f in ipairs(model.ordered_files) do
      if f == path then return i end
    end
    return nil
  end
  EXT.file_count = function() return EXT.filelist and #EXT.filelist.ordered_files or 0 end
  EXT.file_has_comments = function(idx)
    local model = EXT.filelist
    local path = model and model.ordered_files[idx]
    if not path then return false end
    local _, total = file_thread_count(path)
    return total > 0
  end
  EXT.open_file_at = function(idx)
    local model = EXT.filelist
    local path = model and model.ordered_files[idx]
    if not path then return nil end
    open_file(path, true)
    -- Keep the file list's cursor (and scroll) on the file ]c/]C just
    -- walked into, or <BS> + j would preview from wherever it was left.
    local row = model.file_to_row[path]
    if row and list_win and vim.api.nvim_win_is_valid(list_win) then
      EXT.list_last_line = row + 1
      pcall(vim.api.nvim_win_set_cursor, list_win, { row + 1, 0 })
    end
    return path
  end

  -- Re-apply to every buffer of each kind that already exists at this point:
  -- the file list and the Overview page are always created earlier in this
  -- file (before modules load), and a diff/revision buffer might already
  -- exist too (e.g. an early background preview) - kept general so this
  -- stays correct even if that ever changes.
  apply_ext_keys("list", list_buf)
  apply_ext_keys("overview", overview_buf)
  for _, entry in pairs(diff_cache) do
    if entry.buf then apply_ext_keys("diff", entry.buf) end
  end
  for _, buf in pairs(nav_bufs) do
    apply_ext_keys("nav", buf)
  end
end)()

end  -- M.open()

return M
