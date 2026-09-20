-- pr-dash Neovim PR reviewer.
--
-- Launched by review-pr.sh:  nvim -u <this file>
-- Consumes the PRDASH_* environment variables and drives the whole review
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
--   diff pane :  j/k/C-d/C-u move   ]c / [c next/prev change
--                c  comment on the current line
--                cf comment on the whole file (not tied to a line)
--                <BS> or C-w h  back to file list      q quit
--   Overview  :  c new PR-level comment   R reply   s set status (on the
--                thread under the cursor)   ]C/[C jump between threads -
--                same keys as a regular file's diff, just without ]c/[c
--                (there's no diff to jump changes in)
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
--   K         :  view comment(s) on the current line (in a regular file) in a
--                large float; R/s inside it reply / set status without
--                closing the popup
--   gd / gr   :  go to the definition of / find references to the word under
--                the cursor, across the whole repo at the PR's revision (no
--                checkout or LSP needed: git grep + a definition heuristic).
--                Results show in a peek view - hits on the left, the file at
--                that revision previewed on the right as you move - and open
--                read-only at that revision on <CR>; keep pressing gd/gr
--                there to follow further, <BS> walks back one jump.
--   gf        :  open the current file at the PR's revision (read-only, on
--                the same line) to read around the change
--   ?         :  show the keys for whichever buffer you're in (file list,
--                diff pane, Overview, or a revision buffer)

vim.o.compatible = false
vim.o.number = true
vim.o.signcolumn = "no"
vim.o.hidden = true
vim.o.termguicolors = true
vim.o.laststatus = 2
vim.o.mouse = "a"
vim.cmd("syntax on")

-- Shared per-PR content caches + prefetch pipeline (next to this file).
local function script_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(path, ":p:h")
end
local CACHE = dofile((script_dir() .. "/prdash-cache.lua"):gsub("\\", "/"))

local env       = vim.env
local ID        = env.PRDASH_ID or "?"
local ORG       = env.PRDASH_ORG or ""
local PROJECT   = env.PRDASH_PROJECT or ""
local SOURCE    = env.PRDASH_SOURCE or ""
local TARGET    = env.PRDASH_TARGET or ""
local SCRIPT    = env.PRDASH_SCRIPT or ""
local BASH      = env.PRDASH_BASH or "bash"
local EXE       = env.PRDASH_EXE or ""
-- Local clone the diffs come from. Normalise "/c/..." to "c:/..." so the
-- native git.exe understands it when we pass it via `git -C`.
local REPO_PATH = (env.PRDASH_REPO_PATH or ""):gsub("^/([a-zA-Z])/", "%1:/")
-- When launched inside the running dashboard nvim (not as its own process),
-- quitting must close only this reviewer's tab, not the whole editor.
local EMBED     = env.PRDASH_EMBED == "1"
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

-- Leave the reviewer: close the tab when embedded, else quit nvim.
local function leave()
  if EMBED then
    pcall(vim.cmd, "tabclose")
  else
    vim.cmd("qa!")
  end
end

-- Per-buffer state (kept in Lua tables to avoid vimscript serialization).
local maps_by_buf  = {}   -- diff bufnr -> { [bufline] = { side, lineno } }
local paths_by_buf = {}   -- diff bufnr -> repo-relative path
local diff_cache   = {}   -- path -> { buf, map }

-- Existing PR comments, fetched once at startup from Azure DevOps.
local threads_by_key      = {}   -- "path\tside\tlineno" -> { {status, comments}, ... }
local file_threads_by_path = {}  -- path -> file-level threads (no line anchor)
local general_threads     = {}   -- PR-level threads not anchored to a file
local comments_ns         = vim.api.nvim_create_namespace("prdash_comments")
local diff_ns             = vim.api.nvim_create_namespace("prdash_diff")
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
  _G.PRDASH_WHOAMI = _G.PRDASH_WHOAMI or {}
  local cache_key = ORG .. "|" .. PROJECT
  local cached = _G.PRDASH_WHOAMI[cache_key]
  if cached then
    my_id = cached.id
    if on_done then on_done() end
    return
  end
  -- The list feed (--list) already carries the identity each PR was fetched
  -- as; the dashboard hands the record over in _G.PR_CURRENT. Using it here
  -- saves a --whoami spawn (a .NET start-up plus an ADO round-trip) per org.
  local rec = _G.PR_CURRENT
  if rec and tostring(rec.id) == tostring(ID) and rec.myId and rec.myId ~= "" then
    _G.PRDASH_WHOAMI[cache_key] = { id = rec.myId, displayName = rec.myName or "" }
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
          _G.PRDASH_WHOAMI[cache_key] = rec
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
local ignore_ws = _G.PRDASH_IGNORE_WS or false

-- Where persistent text filters are saved (nvim's per-user data dir), shared
-- across every PR review session on this machine.
local FILTERS_FILE = vim.fn.stdpath("data") .. "/pr-dash-comment-filters.json"

-- Reads the persisted filter strings from disk, or {} if none/unreadable.
local function load_persistent_filters()
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

-- Winbar tag for the active text filters, or "" when none are set.
local function ignore_texts_tag()
  if #ignore_texts == 0 then return "" end
  if #ignore_texts == 1 then return "  [hiding: " .. ignore_texts[1].text .. "]" end
  return "  [hiding " .. #ignore_texts .. " filters]"
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
local nav_goto_definition, nav_find_references, nav_open_file  -- code navigation (gd/gr/gf); assigned once the nav block exists.
local fit_list_width   -- defined once the list window exists; re-fits its width.
local refresh_threads  -- re-fetches PR threads and re-decorates; assigned below.
local redraw_after_write  -- redraws every thread surface after an optimistic write; assigned below.
local set_list_winbar  -- rebuilds the file-list winbar; assigned once it exists.
local toggle_active_filter  -- flips active_only and redraws everything; assigned below.
local toggle_ignore_ws      -- flips ignore_ws and rebuilds the diffs on screen; assigned below.
local manage_ignore_texts   -- opens the add/remove text-filter popup; assigned below.
local refresh_file_rows  -- re-renders file-list rows with fresh counts; assigned once it exists.
local mark_current_file  -- highlights the file-list row for the shown diff; assigned once it exists.


local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

-- Resolve azure-cli.yml's path (matches Config.ConfigPath in the C# source):
-- %APPDATA%\azure-cli.yml on Windows, $XDG_CONFIG_HOME/azure-cli.yml (default
-- ~/.config) elsewhere - the same place .NET's ApplicationData resolves to.
local function config_path()
  if vim.fn.has("win32") == 1 then
    return (vim.env.APPDATA or vim.fn.expand("$APPDATA")) .. "\\azure-cli.yml"
  end
  local xdg = vim.env.XDG_CONFIG_HOME
  if not xdg or xdg == "" then xdg = vim.fn.expand("~/.config") end
  return xdg .. "/azure-cli.yml"
end

-- Open azure-cli.yml (accounts/PAT/clones_dir config) in a new tab for quick editing.
local function open_config_file()
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
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
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
          author = (c.author and c.author.displayName) or "?",
          authorId = c.author and c.author.id,
          content = c.content,
        }
      end
    end

    if #comments > 0 then
      local entry = { id = thread.id, status = thread.status, comments = comments }
      local ctx = thread.threadContext
      local side, lineno
      if ctx and ctx.rightFileStart then
        side, lineno = "R", ctx.rightFileStart.line
      elseif ctx and ctx.leftFileStart then
        side, lineno = "L", ctx.leftFileStart.line
      end

      if ctx and type(ctx.filePath) == "string" then
        local path = ctx.filePath:gsub("^/", "")
        entry.path, entry.side, entry.lineno = path, side, lineno
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
    notify("New comment from " .. e.author .. " on " .. where .. ".")
    return
  end
  local authors = {}
  for _, e in ipairs(events) do authors[e.author] = true end
  local names = {}
  for name in pairs(authors) do names[#names + 1] = name end
  table.sort(names)
  notify(#events .. " new comments (" .. table.concat(names, ", ") .. ") on threads involving you.")
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
  if #lines == 0 then
    return
  end
  opts = opts or {}
  local width, height
  if opts.big then
    width, height = big_float_dims()
  else
    width = opts.min_width or 20
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.min(width, 110)
    height = math.min(math.max(#lines, opts.min_height or 1), 28)
  end
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].buftype = "nofile"
  local win_opts
  if opts.big then
    win_opts = {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
    }
  else
    win_opts = {
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
    }
  end
  local win = vim.api.nvim_open_win(fbuf, focus ~= false, win_opts)
  set_float_wrap(win)
  if focus ~= false then
    local opts2 = { buffer = fbuf, silent = true, nowait = true }
    vim.keymap.set("n", "q", "<Cmd>close<CR>", opts2)
    vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", opts2)
  end
  return win
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
  local cache = _G.PR_LIST_CACHE
  if cache and cache.prs then
    for _, p in ipairs(cache.prs) do
      if tostring(p.id) == tostring(ID) then
        return p
      end
    end
  end
  local cur = _G.PR_CURRENT
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
local SEEN_THREADS_FILE = vim.fn.stdpath("data") .. "/pr-dash-seen-threads.json"
local function load_seen_threads()
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

-- Compact build-validation label for the winbar, or nil when unknown/none.
local function build_status_label()
  local pr = current_pr_record()
  local s = pr and pr.buildStatus or nil
  if s == "succeeded" then return "build \u{2713}" end
  if s == "failed" then return "build \u{2717}" end
  if s == "expired" then return "build \u{21BB}" end
  if s == "running" then
    if pr and type(pr.queuePosition) == "number" and pr.queuePosition > 0 then
      return "build \u{25CF} (queue #" .. tostring(pr.queuePosition) .. ")"
    end
    return "build \u{25CF}"
  end
  return nil
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
  local rec = _G.PR_CURRENT
  if rec and tostring(rec.id) == tostring(ID) and rec.myName and rec.myName ~= "" then
    return rec.myName
  end
  local w = _G.PRDASH_WHOAMI and _G.PRDASH_WHOAMI[ORG .. "|" .. PROJECT]
  if w and w.displayName and w.displayName ~= "" then return w.displayName end
  return "You"
end

local function sending_tag(x)
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
local function add_pending_thread(text, bucket, where, path, side, lineno)
  pending_seq = pending_seq + 1
  local entry = {
    id = "pending-" .. pending_seq, status = "active", pending = true,
    path = path, side = side, lineno = lineno,
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

-- Run a review-pr.sh write in the background: on_ok() on success, else
-- on_fail(details). Detached so the write completes even if the PR is
-- left before it returns.
local function run_write(args, on_ok, on_fail)
  local out = {}
  local cmd = { BASH, SCRIPT }
  vim.list_extend(cmd, args)
  vim.fn.jobstart(cmd, {
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
      local msg = table.concat(vim.tbl_filter(function(x) return x ~= "" end, out), " ")
      on_fail("exit " .. code .. (msg ~= "" and (": " .. msg) or ""))
    end,
  })
end

-- After a failed write, offer the same prompt again with the text prefilled
-- so a flaky call never eats what was typed. Scheduled, since input() can't
-- run from inside a job callback.
local function retry_prompt(prompt, text, resend)
  vim.schedule(function()
    local again = vim.fn.input(prompt, text)
    if again and again:gsub("%s", "") ~= "" then
      resend(again)
    else
      notify("Discarded.")
    end
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
local function post_new_thread(args, bucket, where, path, side, lineno, text, label, retry_label)
  local p = add_pending_thread(text, bucket, where, path, side, lineno)
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
      post_new_thread(args_with_text(args, again), bucket, where, path, side, lineno, again, label, retry_label)
    end)
  end)
end

local function threads_to_lines(threads)
  local lines = {}
  for ti, t in ipairs(threads) do
    if ti > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "┌─ thread [" .. tostring(t.status or "?") .. "]" .. sending_tag(t)
    for _, c in ipairs(t.comments) do
      lines[#lines + 1] = "│ " .. c.author .. ":" .. sending_tag(c)
      for _, cl in ipairs(vim.split(c.content, "\n", { plain = true })) do
        lines[#lines + 1] = "│   " .. cl
      end
    end
  end
  return lines
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
  local ext = (path or ""):match("%.([%w_]+)$")
  if not ext then return nil end
  return FT_BY_EXT[ext:lower()]
end

-- Parses one file's raw `git diff` output into display lines plus the
-- per-line {side, lineno} map (see prdash-cache.lua).
local parse_diff_output = CACHE.parse_diff

-- Builds one file's diff on its own, for a cache miss (the dashboard's
-- prefetch normally has every file ready before the PR is even opened).
-- want_ws adds --ignore-all-space, matching whichever content_cache variant
-- (see below) the caller is currently filling.
local function build_diff_async(path, want_ws, cb)
  local out = {}
  local args = want_ws
    and git_args("diff", "--unified=100000", "--ignore-all-space", RANGE, "--", path)
    or git_args("diff", "--unified=100000", RANGE, "--", path)
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
-- (prdash-cache.lua) so they stay warm across leaving and re-entering this
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
  local dkey = path .. "\t" .. tostring(want_ws)
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
  local text = vim.fn.input("Comment (" .. path .. " " .. m.side .. ":" .. m.lineno .. "): ")
  if not text or text:gsub("%s", "") == "" then
    notify("Cancelled.")
    return
  end
  local where = path .. "\t" .. m.side .. "\t" .. m.lineno
  post_new_thread({ "--post", path, m.side, tostring(m.lineno), text }, "line", where,
    path, m.side, m.lineno, text,
    "Comment on " .. path .. " " .. m.side .. ":" .. m.lineno,
    "comment (" .. path .. " " .. m.side .. ":" .. m.lineno .. ")")
end

-- Post a file-level comment (not tied to a line) on the given repo-relative path.
local function comment_on_file(path)
  if not path or path == "" then
    notify("No file selected.", vim.log.levels.WARN)
    return
  end
  local text = vim.fn.input("File comment (" .. path .. "): ")
  if not text or text:gsub("%s", "") == "" then
    notify("Cancelled.")
    return
  end
  post_new_thread({ "--file-comment", path, text }, "file", path, path, nil, nil, text,
    "File comment on " .. path, "file comment (" .. path .. ")")
end

-- Post a PR-level (general) comment, not tied to any file or line.
local function comment_on_pr()
  local text = vim.fn.input("PR comment (#" .. ID .. "): ")
  if not text or text:gsub("%s", "") == "" then
    notify("Cancelled.")
    return
  end
  post_new_thread({ "--pr-comment", text }, "general", nil, nil, nil, nil, text,
    "PR comment", "PR comment (#" .. ID .. ")")
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
local function jump_change(dir)
  local buf = vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(buf)
  local i = vim.api.nvim_win_get_cursor(0)[1]
  while i >= 1 and i <= total and is_change_line(buf, i) do i = i + dir end
  while i >= 1 and i <= total and not is_change_line(buf, i) do i = i + dir end
  if i < 1 or i > total then
    notify(dir > 0 and "No further changes." or "No previous changes.")
    return
  end
  if dir < 0 then
    while i - 1 >= 1 and is_change_line(buf, i - 1) do i = i - 1 end
  end
  vim.api.nvim_win_set_cursor(0, { i, 0 })
  vim.cmd("normal! zz")
end

-- Tag diff-buffer lines that carry existing PR comments: index them by buffer
-- line and add an end-of-line virtual note with the comment count and author.
-- Threads are passed through `filtered()` so lines with only non-active
-- threads are skipped entirely when active_only is on.
local function decorate_comments(buf, path, map)
  local per_line = {}
  for bl, m in ipairs(map) do
    if m.side and m.lineno then
      local key = path .. "\t" .. m.side .. "\t" .. m.lineno
      local threads = filtered(threads_by_key[key])
      if threads and #threads > 0 then
        per_line[bl] = threads
        local count = 0
        local any_new = false
        for _, t in ipairs(threads) do
          count = count + #t.comments
          if thread_is_new(t) then any_new = true end
        end
        local author = threads[1].comments[1].author
        local label = string.format("  ▌ %s%d comment%s — %s", any_new and "🆕 " or "", count, count > 1 and "s" or "", author)
        vim.api.nvim_buf_set_extmark(buf, comments_ns, bl - 1, 0, {
          virt_text = { { label, any_new and "AzureCliCommentNew" or "AzureCliComment" } },
          virt_text_pos = "eol",
        })
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
-- (which only clears comments_ns) never wipes them.
pcall(vim.api.nvim_set_hl, 0, "PrDiffAddBg",   { bg = "#20302a" })
pcall(vim.api.nvim_set_hl, 0, "PrDiffDelBg",   { bg = "#332329" })
pcall(vim.api.nvim_set_hl, 0, "PrDiffAddSign", { fg = "#a6e3a1", bg = "#20302a", bold = true })
pcall(vim.api.nvim_set_hl, 0, "PrDiffDelSign", { fg = "#f38ba8", bg = "#332329", bold = true })
local function decorate_diff(buf, map)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  for bl, m in ipairs(map) do
    if m.kind == "add" or m.kind == "del" then
      local is_add = m.kind == "add"
      vim.api.nvim_buf_set_extmark(buf, diff_ns, bl - 1, 0, {
        sign_text = is_add and "+" or "-",
        sign_hl_group = is_add and "PrDiffAddSign" or "PrDiffDelSign",
        line_hl_group = is_add and "PrDiffAddBg" or "PrDiffDelBg",
      })
    end
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
  local choices = { prompt or "Which thread?" }
  for i, t in ipairs(threads) do
    local first = t.comments[1]
    local preview = first.content:gsub("%s+", " "):sub(1, 40)
    choices[#choices + 1] = i .. ": " .. first.author .. " - " .. preview
  end
  local idx = tonumber(vim.fn.inputlist(choices))
  if not idx or idx < 1 or idx > #threads then
    notify("Cancelled.")
    return
  end
  cb(threads[idx])
end

-- Post a reply to a specific thread. Shows the thread (unfocused) while typing,
-- posts via the --reply subcommand, and on success appends the reply locally
-- and calls on_success so the caller can refresh its view.
-- Send a reply that's already shown in `target`; confirm or roll back.
local function send_reply(target, comment, text, on_success)
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

  -- Show the thread (unfocused) so it stays visible while typing the reply.
  -- Force a redraw so the float paints before the blocking input() prompt.
  local fwin = open_float(threads_to_lines({ target }), false)
  vim.cmd("redraw")
  local text = vim.fn.input("Reply to thread " .. target.id .. ": ")
  if fwin and vim.api.nvim_win_is_valid(fwin) then
    vim.api.nvim_win_close(fwin, true)
  end
  if not text or text:gsub("%s", "") == "" then
    notify("Cancelled.")
    return
  end

  -- Show the reply at once; the write confirms or removes it.
  local comment = { author = my_display_name(), authorId = my_id, content = text, pending = true }
  table.insert(target.comments, comment)
  mark_thread_read(target)
  if on_success then on_success() end
  send_reply(target, comment, text, on_success)
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

  local choices = { "Set thread " .. target.id .. " status:" }
  for i, o in ipairs(STATUS_OPTIONS) do
    choices[#choices + 1] = i .. ": " .. o.label
  end
  local idx = tonumber(vim.fn.inputlist(choices))
  if not idx or idx < 1 or idx > #STATUS_OPTIONS then
    notify("Cancelled.")
    return
  end
  apply_status(target, STATUS_OPTIONS[idx], on_success)
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
  local choices = { "Your vote on PR #" .. ID .. ":" }
  for i, o in ipairs(VOTE_OPTIONS) do
    choices[#choices + 1] = i .. ": " .. o.label
  end
  local idx = tonumber(vim.fn.inputlist(choices))
  if not idx or idx < 1 or idx > #VOTE_OPTIONS then
    notify("Cancelled.")
    return
  end
  local vote = VOTE_OPTIONS[idx]
  notify("Voting: " .. vote.label .. "...")
  local out = {}
  vim.fn.jobstart({ BASH, SCRIPT, "--vote", vote.key }, {
    detach = true,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("PR #" .. ID .. " vote set: " .. vote.label .. ".")
      else
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), " ")
        notify("Vote failed (exit " .. code .. "): " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
end

-- Merge strategies offered when completing a PR (label + ADO strategy key).
local MERGE_TYPES = {
  { key = "squash",       label = "Squash commit" },
  { key = "noFastForward", label = "Merge (no fast forward)" },
  { key = "rebase",       label = "Rebase and fast-forward" },
  { key = "rebaseMerge",  label = "Semi-linear merge" },
}

-- Show a small window to complete (merge) the PR: pick a merge type and toggle
-- the post-completion options, then confirm to run --complete.
local function complete_pr()
  local st = { merge = 1, work_items = true, delete_branch = true }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"

  local function render()
    return {
      "Complete PR #" .. ID,
      "────────────────────────────────────────",
      "Merge type: " .. MERGE_TYPES[st.merge].label,
      (st.work_items and "[x]" or "[ ]") .. " Complete associated work items",
      (st.delete_branch and "[x]" or "[ ]") .. " Delete source branch"
        .. (SOURCE ~= "" and (" (" .. SOURCE .. ")") or ""),
      "────────────────────────────────────────",
      "m: merge type   w/d: toggle   <CR>: complete   q: cancel",
    }
  end

  local function draw()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render())
    vim.bo[buf].modifiable = false
  end
  draw()

  local lines = render()
  local width = 20
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
  })
  set_float_wrap(win)

  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "m", function()
    st.merge = st.merge % #MERGE_TYPES + 1
    draw()
  end, kopts)
  vim.keymap.set("n", "w", function() st.work_items = not st.work_items; draw() end, kopts)
  vim.keymap.set("n", "d", function() st.delete_branch = not st.delete_branch; draw() end, kopts)
  vim.keymap.set("n", "q", "<Cmd>close<CR>", kopts)
  vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", kopts)
  vim.keymap.set("n", "<CR>", function()
    local mt = MERGE_TYPES[st.merge]
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    notify("Completing PR #" .. ID .. " (" .. mt.label .. ")...")
    local out = {}
    vim.fn.jobstart({
      BASH, SCRIPT, "--complete", mt.key,
      tostring(st.delete_branch), tostring(st.work_items),
    }, {
      detach = true,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
      on_stderr = function(_, d) if d then vim.list_extend(out, d) end end,
      on_exit = function(_, code)
        if code == 0 then
          notify("PR #" .. ID .. " completed (" .. mt.label .. ").")
        else
          local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), " ")
          notify("Complete failed (exit " .. code .. "): " .. msg, vim.log.levels.ERROR)
        end
      end,
    })
  end, kopts)
end

-- Jump to the next (dir=1) / previous (dir=-1) diff line that has comments.
local function jump_comment(dir)
  local buf = vim.api.nvim_get_current_buf()
  local per_line = comments_by_buf[buf]
  if not per_line then
    notify("No comments in this file.")
    return
  end
  local total = vim.api.nvim_buf_line_count(buf)
  local i = vim.api.nvim_win_get_cursor(0)[1] + dir
  while i >= 1 and i <= total do
    if per_line[i] then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! zz")
      return
    end
    i = i + dir
  end
  notify(dir > 0 and "No further comments." or "No previous comments.")
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
        for _, cl in ipairs(vim.split(c.content, "\n", { plain = true })) do
          lines[#lines + 1] = "│   " .. cl
        end
      end
    end
  end

  return lines, thread_map
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

local function set_overview_winbar()
  if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
  vim.wo[diff_win].winbar = "Overview: PR #" .. ID .. "  " .. SOURCE .. " -> " .. TARGET
    .. "   (c: new PR comment  R: reply  s: status  gv: vote  gm: complete  gA: active-only  gF: hide text  gw: whitespace  ]C/[C: comment  </>: resize  <BS>: files  ?: help)"
end

-- Overview keys, shown by `?` there.
local function show_overview_help()
  open_float({
    "Overview keys",
    "",
    "  j / k      move",
    "  c          new PR-level comment",
    "  R          reply to the thread under the cursor",
    "  s          set the thread's status",
    "  ]C / [C    next / previous thread",
    "  gv / gm    vote / complete",
    "  gA         toggle active (unresolved) comments only",
    "  gF         manage text filters that hide matching threads",
    "  gw         toggle ignoring whitespace in diffs",
    "  gO         open the config file",
    "  < / >      resize the file list",
    "  <BS>       back to the file list",
    "  q          close the reviewer",
    "  ?          this help",
    "",
    HELP_NOTE_SENDING,
  }, true, { min_width = 60 })
end

local function setup_overview_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "c", comment_on_pr, opts)
  vim.keymap.set("n", "R", reply_overview_here, opts)
  vim.keymap.set("n", "s", set_status_overview_here, opts)
  vim.keymap.set("n", "]C", function() jump_comment(1) end, opts)
  vim.keymap.set("n", "[C", function() jump_comment(-1) end, opts)
  vim.keymap.set("n", "gv", cast_vote, opts)
  vim.keymap.set("n", "gm", complete_pr, opts)
  vim.keymap.set("n", "gA", toggle_active_filter, opts)
  vim.keymap.set("n", "gF", manage_ignore_texts, opts)
  vim.keymap.set("n", "gw", toggle_ignore_ws, opts)
  vim.keymap.set("n", "gO", open_config_file, opts)
  vim.keymap.set("n", "<", function() resize_list(-5) end, opts)
  vim.keymap.set("n", ">", function() resize_list(5) end, opts)
  vim.keymap.set("n", "<BS>", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_set_current_win(list_win)
    end
  end, opts)
  vim.keymap.set("n", "?", show_overview_help, opts)
  vim.keymap.set("n", "q", leave, opts)
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
    vim.wo[diff_win].signcolumn = "no"
    set_overview_winbar()
    if mark_current_file then mark_current_file(OVERVIEW_MARK) end
    if focus then
      vim.api.nvim_set_current_win(diff_win)
      vim.api.nvim_win_set_cursor(diff_win, { 1, 0 })
    end
  end
end

-- Diff-pane keys, shown by `?` there.
local function show_diff_help()
  open_float({
    "Diff pane keys",
    "",
    "  j / k / C-d / C-u   move",
    "  ]c / [c    next / previous change",
    "  c          comment on the current line",
    "  cf         comment on the whole file",
    "  K          view the comments on the current line in a popup (R/s work inside it)",
    "  R          reply to the thread on the current line",
    "  s          set the thread's status",
    "  ]C / [C    next / previous thread",
    "  gd / gr / gf   code navigation, see below",
    "  gv / gm    vote / complete",
    "  gA         toggle active (unresolved) comments only",
    "  gF         manage text filters that hide matching threads",
    "  gw         toggle ignoring whitespace in diffs",
    "  gO         open the config file",
    "  < / >      resize the file list",
    "  <BS>       back to the file list",
    "  q          close the reviewer",
    "  ?          this help",
    "",
    HELP_NOTE_NAV,
    "",
    HELP_NOTE_SENDING,
  }, true, { min_width = 60 })
end

local function setup_diff_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "c", comment_here, opts)
  vim.keymap.set("n", "cf", function() comment_on_file(paths_by_buf[buf]) end, opts)
  vim.keymap.set("n", "]c", function() jump_change(1) end, opts)
  vim.keymap.set("n", "[c", function() jump_change(-1) end, opts)
  vim.keymap.set("n", "K", show_comments_here, opts)
  vim.keymap.set("n", "R", reply_here, opts)
  vim.keymap.set("n", "s", set_status_here, opts)
  vim.keymap.set("n", "gv", cast_vote, opts)
  vim.keymap.set("n", "gm", complete_pr, opts)
  vim.keymap.set("n", "]C", function() jump_comment(1) end, opts)
  vim.keymap.set("n", "[C", function() jump_comment(-1) end, opts)
  vim.keymap.set("n", "gA", toggle_active_filter, opts)
  vim.keymap.set("n", "gF", manage_ignore_texts, opts)
  vim.keymap.set("n", "gw", toggle_ignore_ws, opts)
  vim.keymap.set("n", "gO", open_config_file, opts)
  vim.keymap.set("n", "gd", function() nav_goto_definition() end, opts)
  vim.keymap.set("n", "gr", function() nav_find_references() end, opts)
  vim.keymap.set("n", "gf", function() nav_open_file() end, opts)
  vim.keymap.set("n", "<", function() resize_list(-5) end, opts)
  vim.keymap.set("n", ">", function() resize_list(5) end, opts)
  vim.keymap.set("n", "<BS>", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_set_current_win(list_win)
    end
  end, opts)
  vim.keymap.set("n", "?", show_diff_help, opts)
  vim.keymap.set("n", "q", leave, opts)
end

-- Build the diff-pane winbar for `path`, including the active-only/ignore-ws/
-- text-filter tags when set.
local function set_diff_winbar(path)
  if not (diff_win and vim.api.nvim_win_is_valid(diff_win)) then return end
  vim.wo[diff_win].winbar = path
    .. (active_only and "  [active-only]" or "")
    .. (ignore_ws and "  [ignore-ws]" or "")
    .. ignore_texts_tag()
    .. "   (c: comment  cf: file comment  K: view  R: reply  s: status  gd/gr/gf: definition/references/file  gv: vote  gm: complete  gA: active-only  gF: hide text  gw: whitespace  gO: config  ]c/[c: change  ]C/[C: comment  </>: resize  <BS>: files  ?: help)"
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
      decorate_diff(buf, cached.map)
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
        decorate_diff(buf, map)
        decorate_comments(buf, path, map)
      end)
    end
  end
  if diff_win and vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_win_set_buf(diff_win, entry.buf)
    vim.wo[diff_win].signcolumn = "yes:1"
    set_diff_winbar(path)
    if mark_current_file then mark_current_file(path) end
    if focus then
      vim.api.nvim_set_current_win(diff_win)
      vim.api.nvim_win_set_cursor(diff_win, { 1, 0 })
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
  vim.wo[diff_win].winbar = "[" .. meta.ref .. "] " .. meta.path
    .. "   (gd: definition  gr: references  <BS>: back  q: back to diff  ?: help)"
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
    local own_bg = own_side == "R" and "PrDiffAddBg" or "PrDiffDelBg"
    local own_sign = own_side == "R" and "PrDiffAddSign" or "PrDiffDelSign"
    local other_bg = own_side == "R" and "PrDiffDelBg" or "PrDiffAddBg"
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

-- `git grep` for the whole word `word` at `ref`: cb(hits, truncated) with
-- hits = { {path, lnum, text}, ... }. Fixed-string so identifiers with
-- regex characters are safe; -I skips binaries.
local function git_grep(word, ref, cb)
  local out = {}
  vim.fn.jobstart(git_args("grep", "-n", "-w", "-I", "-F", "--no-color", "-e", word, ref, "--"), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function()
      vim.schedule(function()
        local hits, truncated = {}, false
        local prefix = ref .. ":"
        for _, l in ipairs(out) do
          if l:sub(1, #prefix) == prefix then
            local path, lnum, text = l:sub(#prefix + 1):match("^(.-):(%d+):(.*)$")
            if path then
              if #hits >= NAV_MAX_HITS then truncated = true break end
              hits[#hits + 1] = { path = path, lnum = tonumber(lnum), text = text }
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
-- cursor, with the line and every whole-word occurrence highlighted. Moving
-- through the list re-previews (debounced); <CR> opens the hit in the diff
-- window, q/<Esc> (or leaving the list) closes both panes. Hits are ordered
-- same file first, then same extension, then by path.
pcall(vim.api.nvim_set_hl, 0, "AzureCliPeekLine", { bg = "#45475a" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliPeekWord", { bg = "#f9e2af", fg = "#1e1e2e", bold = true })
local peek_ns = vim.api.nvim_create_namespace("prdash_peek")

-- nvim_open_win with a border title where supported (0.9+), plain otherwise.
local function open_peek_win(buf, focus, cfg, title)
  local with_title = vim.tbl_extend("force", cfg, { title = " " .. title .. " ", title_pos = "left" })
  local ok, win = pcall(vim.api.nvim_open_win, buf, focus, with_title)
  if ok then return win end
  return vim.api.nvim_open_win(buf, focus, cfg)
end

local function show_hits(title, hits, ref, current_path, truncated, word)
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
  vim.wo[lwin].cursorline = true
  vim.wo[lwin].wrap = false

  local pwin = open_peek_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor", row = row, col = col + list_w + 2, width = prev_w, height = height,
    style = "minimal", border = "rounded", focusable = false,
  }, "preview")
  vim.wo[pwin].number = true
  vim.wo[pwin].wrap = false
  vim.wo[pwin].cursorline = false

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
local function show_nav_help()
  open_float({
    "Revision buffer keys",
    "",
    "  j / k      move",
    "  gd / gr    definition / references from here",
    "  <BS>       walk back one jump",
    "  q          back to the diff",
    "  gO         open the config file",
    "  < / >      resize the file list",
    "  ?          this help",
    "",
    HELP_NOTE_NAV,
  }, true, { min_width = 60 })
end

setup_nav_keymaps = function(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "gd", function() nav_goto_definition() end, opts)
  vim.keymap.set("n", "gr", function() nav_find_references() end, opts)
  vim.keymap.set("n", "<BS>", nav_back, opts)
  vim.keymap.set("n", "q", nav_back_to_diff, opts)
  vim.keymap.set("n", "gO", open_config_file, opts)
  vim.keymap.set("n", "<", function() resize_list(-5) end, opts)
  vim.keymap.set("n", ">", function() resize_list(5) end, opts)
  vim.keymap.set("n", "?", show_nav_help, opts)
end

-- ---------------------------------------------------------------------------
-- Highlight for the inline comment markers.
pcall(vim.api.nvim_set_hl, 0, "AzureCliComment", { fg = "#e5c07b", bold = true })
-- Highlight for comment markers with unread comments (see thread_is_new).
pcall(vim.api.nvim_set_hl, 0, "AzureCliCommentNew", { fg = "#f38ba8", bold = true })
-- Highlight for the file-list row of whichever file is currently shown in the
-- diff pane. Unlike relying on the cursor/'cursorline', this stays visible
-- even once focus has moved into the diff pane (where the list, now an
-- inactive window, would otherwise show no cursor at all).
pcall(vim.api.nvim_set_hl, 0, "AzureCliCurrentFile", { bg = "#313244", bold = true })
local current_file_ns = vim.api.nvim_create_namespace("prdash_current_file")

-- The PR's changed files, filled in asynchronously by load_files (below, at
-- startup) so the reviewer opens before git has answered. Empty until then;
-- files_loaded tells the placeholder row apart from a genuinely empty PR.
local files = {}
local files_loaded = false

-- Warm content_cache for every file still missing, with a single git run
-- over the whole range (see prdash-cache.lua), so switching between files
-- (j/k in the file list) is instant. Usually a no-op: the dashboard's
-- hover/warm-all prefetch has normally filled the cache before the PR is
-- opened. Files opened explicitly meanwhile are fetched on their own by
-- ensure_diff_content, which de-dupes against its own in-flight builds.
local function prefetch_all_diffs()
  local pr = current_pr_record()
  CACHE.prefetch({
    id = ID, updatedIso = pr and pr.updatedIso or "",
    source = SOURCE, target = TARGET, repo = REPO_PATH, ignore_ws = ignore_ws,
  })
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

-- File row text: the path, with a "(closed/total)" suffix when it has comment
-- threads, prefixed with 🆕 when any of them are new/unread.
local function file_label(path)
  local closed, total = file_thread_count(path)
  local prefix = file_has_new(path) and "🆕 " or ""
  if total > 0 then
    return prefix .. path .. "  (" .. closed .. "/" .. total .. ")"
  end
  return prefix .. path
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
-- Overview tab. Files occupy lines 2..#files+1.
local list_buf = vim.api.nvim_create_buf(false, true)
local OVERVIEW_ROW = 1
local current_file_path  -- path (or OVERVIEW_MARK) currently shown in the diff pane, for re-marking after redraws.
local function list_lines()
  local out = { overview_row_label(nil) }
  if not files_loaded then
    out[#out + 1] = "  (loading files…)"
    return out
  end
  for _, f in ipairs(files) do
    out[#out + 1] = file_label(f)
  end
  return out
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
  for i, f in ipairs(files) do
    if f == path then
      pcall(vim.api.nvim_buf_add_highlight, list_buf, current_file_ns, "AzureCliCurrentFile", i, 0, -1)
      break
    end
  end
end
-- Re-render just the file rows (lines 2..#files+1) with fresh comment counts,
-- e.g. after threads load asynchronously. Leaves the pinned Overview row alone
-- (see refresh_overview_row).
refresh_file_rows = function()
  if not vim.api.nvim_buf_is_valid(list_buf) then return end
  local rows = {}
  for _, f in ipairs(files) do
    rows[#rows + 1] = file_label(f)
  end
  vim.bo[list_buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, list_buf, 1, #files + 1, false, rows)
  vim.bo[list_buf].modifiable = false
  if fit_list_width then fit_list_width() end
  mark_current_file(current_file_path)
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
vim.bo[list_buf].filetype = "prfiles"

vim.api.nvim_win_set_buf(0, list_buf)
list_win = vim.api.nvim_get_current_win()

-- Rebuild the file-list winbar, including the live build badge read from the
-- dashboard-maintained cache.
local function set_list_winbar_impl()
  if not (list_win and vim.api.nvim_win_is_valid(list_win)) then return end
  local blabel = build_status_label()
  local clabel = merge_conflict_label()
  local alabel = auto_complete_label()
  pcall(function()
    vim.wo[list_win].winbar = "PR #" .. ID .. "  " .. SOURCE .. " -> " .. TARGET
      .. (blabel and ("  [" .. blabel .. "]") or "")
      .. (clabel and ("  [" .. clabel .. "]") or "")
      .. (alabel and ("  [" .. alabel .. "]") or "")
      .. (active_only and "  [active-only]" or "")
      .. (ignore_ws and "  [ignore-ws]" or "")
      .. ignore_texts_tag()
      .. "   (<CR>: open  cf: file comment  gC: new PR comment  gA: active-only  gF: hide text  gw: whitespace  gO: config  gv: vote  gm: complete  ]C/[C: file w/comments  </>: resize  <BS>: back to PR list  q: quit  ?: help)"
  end)
end
set_list_winbar = set_list_winbar_impl
set_list_winbar()

-- Refresh the build badge from the shared cache (which the dashboard polls).
-- No extra API calls here; it just re-reads the record. Standalone runs have no
-- cache, so the badge stays hidden and this is a cheap no-op.
if _G.PRDASH_REVIEW_BADGE_TIMER then pcall(vim.fn.timer_stop, _G.PRDASH_REVIEW_BADGE_TIMER) end
_G.PRDASH_REVIEW_BADGE_TIMER = vim.fn.timer_start(10000, function()
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    set_list_winbar()
  else
    pcall(vim.fn.timer_stop, _G.PRDASH_REVIEW_BADGE_TIMER)
    _G.PRDASH_REVIEW_BADGE_TIMER = nil
  end
end, { ["repeat"] = -1 })

vim.cmd("rightbelow vsplit")
diff_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(diff_win, vim.api.nvim_create_buf(false, true))
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
-- it. Switches content_cache to the other cached variant (prdash-cache.lua
-- keeps both warm side by side), then drops every per-path diff buffer:
-- ones not currently shown are deleted outright (nothing is looking at
-- them); the one currently shown is rebuilt through open_file so the diff
-- pane refreshes in place, and only then is its old buffer deleted, so the
-- window is never left pointing at a dead buffer. Comments still decorate by
-- (path, side, lineno) and keep working - -w only changes which lines count
-- as changed, not the line numbers of lines that didn't change. Also
-- re-decorates any already-open revision buffer (gd/gr/gf), which reads
-- through ensure_diff_content and so follows the new mode once redecorated.
toggle_ignore_ws = function()
  ignore_ws = not ignore_ws
  _G.PRDASH_IGNORE_WS = ignore_ws
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
    local input = vim.fn.input("Add text filter: ")
    if input ~= "" then
      table.insert(ignore_texts, { text = input:lower(), persistent = false })
      refresh_after_filter_change()
      if on_change then on_change() end
      notify("Added text filter: " .. input .. " (not persistent — press p on it to keep it across sessions).")
    end
    draw()
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
    local choices = { "Set status for " .. #matches .. " comment(s) matching '" .. f.text .. "':" }
    for i, o in ipairs(STATUS_OPTIONS) do
      choices[#choices + 1] = i .. ": " .. o.label
    end
    local sel = tonumber(vim.fn.inputlist(choices))
    if not sel or sel < 1 or sel > #STATUS_OPTIONS then
      notify("Cancelled.")
      return
    end
    apply_status_to_matches(matches, STATUS_OPTIONS[sel], "'" .. f.text .. "'", function()
      refresh_after_filter_change()
      if on_change then on_change() end
      draw()
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

-- Jump to the next (dir=1) / previous (dir=-1) file that has at least one
-- comment thread once the gA active-only / gF text filters are applied - same
-- "filtered" total used for each row's "(closed/total)" suffix, so this only
-- stops on files whose badge is actually showing. Cursor lines are offset by
-- +1 versus file indices since the Overview row is pinned at line 1.
local function jump_file_with_comments(dir)
  if #files == 0 then
    notify("No files in this PR.")
    return
  end
  local i = (vim.api.nvim_win_get_cursor(0)[1] - 1) + dir
  while i >= 1 and i <= #files do
    local _, total = file_thread_count(files[i])
    if total > 0 then
      vim.api.nvim_win_set_cursor(0, { i + 1, 0 })
      vim.cmd("normal! zz")
      return
    end
    i = i + dir
  end
  notify(dir > 0 and "No further files with comments." or "No previous files with comments.")
end

-- File-list keys, shown by `?` there.
local function show_file_list_help()
  open_float({
    "File list keys",
    "",
    "  j / k      move; the right pane previews the file as you go",
    "  <CR>       open and focus the file",
    "  cf         comment on the whole file",
    "  gC         new PR-level comment",
    "  ]C / [C    next / previous file with comments",
    "  gA         toggle active (unresolved) comments only",
    "  gF         manage text filters that hide matching threads",
    "  gw         toggle ignoring whitespace in diffs",
    "  gO         open the config file",
    "  gv / gm    vote / complete",
    "  < / >      resize the list",
    "  <BS>       back to the PR list",
    "  q          close the reviewer",
    "  ?          this help",
  }, true, { min_width = 60 })
end

-- File-list keymaps. Line 1 is the pinned Overview row; files occupy lines
-- 2..#files+1.
local lopts = { buffer = list_buf, silent = true, nowait = true }
vim.keymap.set("n", "<CR>", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if line == OVERVIEW_ROW then
    open_overview(true)
    return
  end
  if not files_loaded then
    notify("Still loading the file list…")
    return
  end
  open_file(files[line - 1], true)
end, lopts)
vim.keymap.set("n", "<BS>", leave, lopts)
vim.keymap.set("n", "q", leave, lopts)
vim.keymap.set("n", "gC", comment_on_pr, lopts)
vim.keymap.set("n", "gA", toggle_active_filter, lopts)
vim.keymap.set("n", "gF", manage_ignore_texts, lopts)
vim.keymap.set("n", "gw", toggle_ignore_ws, lopts)
vim.keymap.set("n", "gO", open_config_file, lopts)
vim.keymap.set("n", "gv", cast_vote, lopts)
vim.keymap.set("n", "gm", complete_pr, lopts)
vim.keymap.set("n", "]C", function() jump_file_with_comments(1) end, lopts)
vim.keymap.set("n", "[C", function() jump_file_with_comments(-1) end, lopts)
vim.keymap.set("n", "<", function() resize_list(-5) end, lopts)
vim.keymap.set("n", ">", function() resize_list(5) end, lopts)
vim.keymap.set("n", "cf", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if line == OVERVIEW_ROW then
    notify("Open the Overview page (<CR>) and press c to add a PR-level comment.", vim.log.levels.WARN)
    return
  end
  comment_on_file(files[line - 1])
end, lopts)
vim.keymap.set("n", "?", show_file_list_help, lopts)

-- Preview-on-move: scrolling the list updates the diff pane (Overview or a
-- file's diff) without stealing focus. Debounced (like the dashboard's own
-- hover-prefetch) so holding j/k / scrolling past several rows doesn't
-- build/switch content for every intermediate row — only the one the cursor
-- actually settles on.
local preview_timer
vim.api.nvim_create_autocmd("CursorMoved", {
  buffer = list_buf,
  callback = function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    if preview_timer then vim.fn.timer_stop(preview_timer) end
    preview_timer = vim.fn.timer_start(80, function()
      if line == OVERVIEW_ROW then
        open_overview(false)
      else
        open_file(files[line - 1], false)
      end
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
local function apply_files(list)
  if not vim.api.nvim_buf_is_valid(list_buf) then return end
  files = list
  files_loaded = true
  if #files == 0 then
    notify("No changed files in this PR (range " .. RANGE .. ").", vim.log.levels.WARN)
    if EMBED then leave() end
    return
  end
  local rows = {}
  for _, f in ipairs(files) do rows[#rows + 1] = file_label(f) end
  vim.bo[list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(list_buf, 1, -1, false, rows)
  vim.bo[list_buf].modifiable = false
  fit_list_width()
  mark_current_file(current_file_path)
  prefetch_all_diffs()
  notify("PR #" .. ID .. ": " .. #files
    .. " files. j/k move, <CR> open, c comment, K view, R reply. Overview is the first row.")
end
local function load_files()
  -- Prefetched by the dashboard (hover / warm-all)? Then there's nothing to wait for.
  local cached = CACHE.files(cache_key)
  if cached then
    apply_files(cached)
    return
  end
  local out, err = {}, {}
  vim.fn.jobstart(git_args("diff", "--name-only", RANGE), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(list_buf) then return end
        if code ~= 0 then
          notify("Cannot diff PR #" .. ID .. " (" .. RANGE .. "): branch not found in "
            .. (REPO_PATH ~= "" and REPO_PATH or "the current repo")
            .. ". It may be deleted, or repo '" .. (env.PRDASH_REPO or "?")
            .. "' isn't cloned here.", vim.log.levels.ERROR)
          if EMBED then leave() end
          return
        end
        local list = vim.tbl_filter(function(f) return f ~= "" end, out)
        CACHE.set_files(cache_key, list)
        apply_files(list)
      end)
    end,
  })
end
load_files()

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
  vim.fn.jobstart({ BASH, SCRIPT, "--threads" }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(chunks, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err_chunks, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then
        -- Surface the failure instead of silently showing zero comments -
        -- e.g. a bad/expired PAT, network error, or misconfigured account
        -- would otherwise look identical to "this PR has no comments".
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err_chunks), " ")
        notify("Failed to load PR comments (exit " .. code .. ")"
          .. (msg ~= "" and (": " .. msg) or " - check azure-cli.yml (PAT/org_url) and connectivity."),
          vim.log.levels.ERROR)
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
do
  local cached = CACHE.threads(ID)
  if cached then
    apply_threads_json(cached.json, { announce = true, seed = true })
  end
  refresh_threads({ announce = cached == nil })
end

-- Periodic auto-refresh of comment threads (silent, once a minute), so per-file
-- closed/total counts and the Overview row/page stay current even if someone
-- else updates a thread while this view is open. Guarded by refresh_threads_inflight so an
-- overlapping fetch is skipped rather than stacking (matches review-pr's other
-- polling timers). Stops itself once the file-list window is gone.
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

if _G.PRDASH_REVIEW_THREADS_TIMER then pcall(vim.fn.timer_stop, _G.PRDASH_REVIEW_THREADS_TIMER) end
_G.PRDASH_REVIEW_THREADS_TIMER = vim.fn.timer_start(60000, function()
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    refresh_threads()
  else
    pcall(vim.fn.timer_stop, _G.PRDASH_REVIEW_THREADS_TIMER)
    _G.PRDASH_REVIEW_THREADS_TIMER = nil
  end
end, { ["repeat"] = -1 })

