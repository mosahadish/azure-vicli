-- lua/azure-cli/review/followup.lua: "follow up on my comments" (gu) - a
-- reviewer-feature module built on pr-review.lua's EXT extension mechanism
-- (see the comment at EXT's declaration there, and README's "Extending the
-- reviewer", for why this lives in its own require()'d module instead of new
-- code in pr-review.lua itself: that file is at LuaJIT's 200-local ceiling
-- for its main chunk).
--
-- Wired in by pr-review.lua's closing `do...end` block as
-- EXT.followup = require(this file)(ctx), after EXT.since_mod - it reuses
-- review/since.lua's M.fetch_base (exposed on ctx as ctx.fetch_since_base)
-- to find the same base commit `gi` would diff from, so both features agree
-- on "since my last review" without duplicating the --threads/--iterations/
-- `git cat-file` dance.
--
-- What this answers: for every review thread I started myself, "did the
-- author touch anything near what I commented on, since I left that
-- comment?" `gu` (list/diff/overview) opens a two-pane picker - my threads
-- on the left (rows tagged changed/unchanged/n/a), a preview of the file at
-- origin/<SOURCE> on the right, centred on the (mapped) line with the
-- since-range's own changed lines highlighted.
--
-- Where "my threads" comes from: every thread (any status) whose FIRST
-- comment is mine (ctx.my_id()), taken from ctx.threads() - the same
-- already-parsed tables pr-review.lua's own decorate_comments/build_overview
-- read, so this never re-fetches or re-parses the thread JSON itself (unlike
-- review/since.lua's own M.last_review_point, which needs the RAW JSON
-- because it also needs a vote's system comment - a plain review comment
-- thread never is one, so the already-filtered tables are exactly right
-- here). A thread anchored to a file+line ("R" or "L" side - see
-- pr-review.lua's parse_threads) is "anchored"; a file-level or PR-level one
-- is "unanchored" and listed at the end of the picker instead of being
-- classified.
--
-- Changed/unchanged/n/a, and the line-mapping rule: for each anchored
-- thread on the SOURCE ("R") side, this module runs one
-- `git diff --unified=0 <base>..origin/<SOURCE> -- <path>` per distinct
-- path (async, cached per base+path at the module level below - see
-- hunks_cache - the same "cache by stable key, share across PRs/opens"
-- approach review/commits.lua's own per-sha caches use), parses the
-- "@@ -a,b +c,d @@" hunk headers out of it (M.parse_hunks) and marks the
-- thread "changed" when any hunk's NEW-side range comes within 3 lines of
-- the thread's own line (M.window_overlaps), else "unchanged" - a file with
-- no hunks at all in that diff (untouched since the base) also reads as
-- "unchanged", per M.classify. A thread on the TARGET ("L") side is marked
-- "n/a": its line is relative to the target branch's copy of the file, which
-- has nothing to do with this diff's source-branch side (the exact same
-- reason review/since.lua's own decorate_comments hides "L" threads outright
-- while `gi` is on - see that module's header comment).
--
-- The line-mapping rule this compares against needs no translation of the
-- thread's OWN line: an "R"-side thread.lineno is already expressed in
-- origin/<SOURCE>'s CURRENT tip numbering - Azure DevOps keeps
-- threadContext.rightFileStart tracked to the latest iteration itself,
-- which is exactly the "new" side of the <base>..origin/<SOURCE> diff this
-- module runs (the same assumption pr-review.lua's own decorate_comments
-- relies on for the whole-PR diff: it indexes straight off thread.lineno
-- with no translation there either). M.map_old_to_new below is the general
-- old-side -> new-side rule anyway (tested in
-- tests/test-review-followup.lua) - it walks a hunk list accumulating each
-- earlier hunk's (new_count - old_count) shift, returning nil when the given
-- old-side line itself was inside a deleted/replaced range - kept here as
-- the documented, tested primitive for a caller that DOES start from an
-- old-side line number (a future feature comparing against the target
-- side, say), even though classifying an "R" thread never needs to call it.
--
-- The comment filters apply here too: a thread the active-only filter (gA)
-- or a gF text filter hides is hidden in this picker exactly as it is in
-- the diff, the file list's counts and the Overview page - this was the one
-- surface that still listed threads the rest of the reviewer was treating
-- as not there. gA is bound inside the picker as well, and flips the
-- reviewer's own filter rather than a private copy, so the diff and
-- Overview behind it follow along and pressing it here means the same
-- thing as pressing it anywhere else. Every one of my threads is classified
-- before the picker opens and filtered at render time, so toggling the
-- filter off in there puts rows back without re-running the since-diff.
--
-- Keys (list/diff/overview - see ctx.add_key's kinds): gu opens the picker.
-- Inside it: <CR> jumps to the thread, K shows it, R replies, s sets its
-- status, gA toggles the active-only filter, q/<Esc> close.

local M = {}

-- Per-(base,path) parsed hunks, and in-flight de-duping - module-level (not
-- inside setup(ctx)) so, like review/commits.lua's own sha-keyed caches, it
-- stays warm across re-opening the picker (or even a different PR - a base
-- sha is effectively unique to the local clone) within the same session.
local hunks_cache   = {}  -- "base\tpath" -> hunks list (M.parse_hunks' return)
local hunks_waiters = {}  -- "base\tpath" -> { cb, ... } while a fetch is in flight

-- The window's own extmark namespace for the since-range hunk highlight in
-- the preview pane - created lazily (see open_picker) so requiring this
-- module standalone (tests/test-review-followup.lua) never touches vim.
local followup_ns

-- ---------------------------------------------------------------------------
-- Pure helpers - no vim/ctx, so tests/test-review-followup.lua exercises
-- them directly under plain luajit, the same way review/since.lua's are.

-- The first real (already-parsed, so never a system comment - see the
-- module comment above) comment of thread `t`, or nil for a thread with none
-- (shouldn't happen for anything ctx.threads() hands back, but pure
-- functions stay defensive).
function M.first_comment(t)
  return t and t.comments and t.comments[1]
end

-- True when thread `t`'s first comment is authored by `my_id` - i.e. I
-- started it (a reply of mine to someone else's thread doesn't count; this
-- is specifically "threads I opened", matching the picker's whole premise
-- of "did the author address what I asked").
function M.is_mine(t, my_id)
  if not my_id then return false end
  local c = M.first_comment(t)
  return c ~= nil and c.authorId == my_id
end

-- The first `limit` (default 80) characters of `content`, whitespace runs
-- (including embedded newlines) collapsed to a single space - the same idea
-- as pr-review.lua's own pick_thread preview, just a longer cut (80 vs. 40)
-- since the picker has a whole row to itself rather than sharing an
-- inputlist choice line.
function M.preview_text(content, limit)
  limit = limit or 80
  return (content or ""):gsub("%s+", " "):sub(1, limit)
end

-- Drops the rows whose thread the reviewer's comment filters currently
-- hide - `passes` is ctx.passes_filters, the same predicate the diff
-- decoration, the file list's counts and the Overview page all run threads
-- through, so "my comments" lists exactly the comments the rest of the
-- reviewer admits exist. A row carrying no thread of its own is kept:
-- there's nothing to filter on.
function M.visible(rows, passes)
  local out = {}
  for _, r in ipairs(rows or {}) do
    if not r.thread or passes(r.thread) then out[#out + 1] = r end
  end
  return out
end

-- Splits a flat list of thread entries (ctx.threads()'s three tables,
-- flattened - each entry shaped like pr-review.lua's parse_threads builds:
-- { id, status, comments, path, side, lineno, end_lineno }) into the
-- threads I started (M.is_mine), further split into `anchored` (path+side+
-- lineno all present - a real file+line comment) and `unanchored`
-- (everything else: a file-level comment, or a PR-level one with no path at
-- all). Each returned entry is a fresh row record, never the thread table
-- itself, so classifying/sorting/formatting never mutates ctx.threads()'s
-- own live data: { thread = t, path = t.path, side = t.side,
-- lineno = t.lineno, status = t.status, preview = <first 80 chars of my
-- comment>, replies = <comment count - 1> }.
function M.select_my_threads(list, my_id)
  local anchored, unanchored = {}, {}
  for _, t in ipairs(list or {}) do
    if M.is_mine(t, my_id) then
      local row = {
        thread = t, path = t.path, side = t.side, lineno = t.lineno,
        status = t.status, preview = M.preview_text(M.first_comment(t).content),
        replies = math.max(0, #t.comments - 1),
      }
      if t.path and t.side and t.lineno then
        anchored[#anchored + 1] = row
      else
        unanchored[#unanchored + 1] = row
      end
    end
  end
  return anchored, unanchored
end

-- Parses the "@@ -a[,b] +c[,d] @@" hunk headers out of raw
-- `git diff --unified=0` output lines into { old_start, old_count,
-- new_start, new_count } (b/d default to 1 when the diff omits them, same
-- as a normal unified diff - a hunk touching exactly one line on that side
-- prints just its start). Order matches the diff's own (hunks appear in
-- increasing line order within one file's section), which M.map_old_to_new
-- below relies on.
function M.parse_hunks(lines)
  local hunks = {}
  for _, l in ipairs(lines or {}) do
    local os_, oc, ns, nc = l:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os_ then
      hunks[#hunks + 1] = {
        old_start = tonumber(os_), old_count = (oc ~= "" and tonumber(oc) or 1),
        new_start = tonumber(ns), new_count = (nc ~= "" and tonumber(nc) or 1),
      }
    end
  end
  return hunks
end

-- The inclusive new-side line range hunk `h` touches. A pure deletion
-- (new_count == 0 - every changed line was on the old side only) has no
-- new-side lines of its own; git's convention is that new_start still names
-- the new-file position the deletion happened at (the line immediately
-- before it), so that single line is what "nearby" is measured against.
function M.hunk_new_range(h)
  if h.new_count <= 0 then return h.new_start, h.new_start end
  return h.new_start, h.new_start + h.new_count - 1
end

-- True when any hunk's new-side range (M.hunk_new_range) comes within
-- `window` (default 3) lines of `line` - the "line-3, line+3" test.
function M.window_overlaps(hunks, line, window)
  window = window or 3
  for _, h in ipairs(hunks or {}) do
    local first, last = M.hunk_new_range(h)
    if first <= line + window and last >= line - window then
      return true
    end
  end
  return false
end

-- The general old-side -> new-side line-mapping rule (see the module
-- comment above for why classifying an "R"-side thread never actually calls
-- this - its own anchor is already new-side). Walks `hunks` (assumed in
-- file order, as M.parse_hunks preserves) accumulating each earlier hunk's
-- (new_count - old_count) shift; returns nil when `old_line` itself falls
-- inside a hunk's deleted/replaced old-side range (old_count > 0), since no
-- single new-side line corresponds to a line that no longer exists.
function M.map_old_to_new(hunks, old_line)
  local shift = 0
  for _, h in ipairs(hunks or {}) do
    local old_end = h.old_count > 0 and (h.old_start + h.old_count - 1) or h.old_start
    if h.old_count > 0 and old_line >= h.old_start and old_line <= old_end then
      return nil
    end
    if old_line > old_end then
      shift = shift + (h.new_count - h.old_count)
    end
  end
  return old_line + shift
end

-- Classifies one anchored row: "n/a" for a target-side ("L") thread (can't
-- be tracked - see the module comment), "unchanged" for a source-side ("R")
-- thread whose file has no hunks at all in the since-range diff (untouched,
-- or the diff simply doesn't mention it - same verdict either way) or whose
-- line has no hunk within `window` lines, else "changed".
function M.classify(side, hunks, lineno, window)
  if side ~= "R" then return "n/a" end
  if not hunks or #hunks == 0 then return "unchanged" end
  if M.window_overlaps(hunks, lineno, window) then return "changed" end
  return "unchanged"
end

local CLASS_ICON  = { changed = "\u{2713}", unchanged = "\u{2013}", ["n/a"] = "?" }
local CLASS_WORD  = { changed = "changed", unchanged = "unchanged", ["n/a"] = "n/a" }
local CLASS_RANK  = { changed = 0, unchanged = 1, ["n/a"] = 2 }

-- One picker row's display text: "<icon> <word>  <where>  [<status>]
-- "<preview>"  (N replies)" - `where` is "path:line" for an anchored row,
-- "path  (file)" for an unanchored file-level one, or "(PR-level)" for a
-- general comment with no path at all. An unanchored row (row.classification
-- is nil) gets its own icon/word ("\u{00B7}"/"unanchored") rather than one
-- of the three tracked states.
function M.format_row(row)
  local icon = CLASS_ICON[row.classification] or "\u{00B7}"
  local word = CLASS_WORD[row.classification] or "unanchored"
  local where
  if row.lineno then
    where = row.path .. ":" .. row.lineno
  elseif row.path then
    where = row.path .. "  (file)"
  else
    where = "(PR-level)"
  end
  return string.format('%s %-9s  %-42s  [%s]  "%s"  (%d repl%s)',
    icon, word, where, row.status or "?", row.preview or "",
    row.replies or 0, (row.replies == 1) and "y" or "ies")
end

-- Sorts a copy of `rows` (anchored rows, each carrying `.classification`)
-- changed first, then unchanged, then n/a, and within a classification by
-- path then line number - never mutates the input list.
function M.sort_rows(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r end
  table.sort(out, function(a, b)
    local ra, rb = CLASS_RANK[a.classification] or 9, CLASS_RANK[b.classification] or 9
    if ra ~= rb then return ra < rb end
    if a.path ~= b.path then return (a.path or "") < (b.path or "") end
    return (a.lineno or 0) < (b.lineno or 0)
  end)
  return out
end

-- Builds the picker's full line list (the summary line, a blank, one row
-- per anchored thread, then - only if any exist - a blank, a header and one
-- row per unanchored thread) plus `rows_by_line` (buffer line number -> the
-- row record it renders, so a keymap can read `rows_by_line[cursor line]`
-- without re-deriving it - header/blank lines are simply absent from this
-- map). `anchored` is expected already classified and sorted (M.sort_rows).
function M.build_lines(new_iterations, review_point, anchored, unanchored)
  local changed_n = 0
  for _, r in ipairs(anchored) do
    if r.classification == "changed" then changed_n = changed_n + 1 end
  end
  local date = (review_point and #review_point >= 10) and review_point:sub(1, 10) or "?"
  local lines = {
    string.format("Since %s (%d new iteration%s): %d of %d thread%s have nearby changes",
      date, new_iterations, (new_iterations == 1) and "" or "s",
      changed_n, #anchored, (#anchored == 1) and "" or "s"),
    "",
  }
  local rows_by_line = {}
  for _, r in ipairs(anchored) do
    lines[#lines + 1] = M.format_row(r)
    rows_by_line[#lines] = r
  end
  if #unanchored > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Unanchored (file/PR-level comments):"
    for _, r in ipairs(unanchored) do
      lines[#lines + 1] = M.format_row(r)
      rows_by_line[#lines] = r
    end
  end
  return lines, rows_by_line
end

-- ---------------------------------------------------------------------------
-- ctx-dependent pieces. Defined at module level (like review/commits.lua's
-- own buffer-building functions), taking `ctx` as an explicit argument
-- rather than closing over it, since only functions actually CALLED at
-- require()-without-a-real-ctx time (none of these are - they're only ever
-- reached through the gu keymap setup(ctx) registers below) need to avoid
-- vim/ctx; this keeps hunks_cache/hunks_waiters usefully shared across
-- however many times setup(ctx) itself runs (once per M.open() - a fresh PR
-- review - since require() caches this module's chunk, not just the plain
-- pure-function definitions in it).

-- Fetches (or joins an in-flight fetch of) the since-range hunks for `path`
-- against `base`, calling cb(hunks) - never fails outright: a `git diff`
-- that errors (e.g. the path didn't exist at `base`) is treated the same as
-- "no hunks", which M.classify already reads as "unchanged", matching the
-- spec's "file absent from the since-diff -> unchanged".
local function ensure_hunks(ctx, base, path, cb)
  local key = base .. "\t" .. path
  local cached = hunks_cache[key]
  if cached then
    cb(cached)
    return
  end
  local waiters = hunks_waiters[key]
  if waiters then
    table.insert(waiters, cb)
    return
  end
  hunks_waiters[key] = { cb }
  local out = {}
  vim.fn.jobstart(ctx.git_args("diff", "--unified=0", base .. "..origin/" .. ctx.SOURCE, "--", path), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, _code)
      vim.schedule(function()
        local hunks = M.parse_hunks(out)
        hunks_cache[key] = hunks
        local cbs = hunks_waiters[key] or {}
        hunks_waiters[key] = nil
        for _, f in ipairs(cbs) do f(hunks) end
      end)
    end,
  })
end

-- Fetches every distinct source-side path `anchored` needs (one `git diff`
-- each, de-duped/cached via ensure_hunks above) and calls
-- cb(hunks_by_path) once they've all landed. A thread list with no "R"-side
-- anchored rows at all (every one of my threads is on the target side, or
-- there are none) skips straight to cb({}) - nothing to fetch.
local function fetch_all_hunks(ctx, base, anchored, cb)
  local paths, total = {}, 0
  for _, row in ipairs(anchored) do
    if row.side == "R" and row.path and not paths[row.path] then
      paths[row.path] = true
      total = total + 1
    end
  end
  local hunks_by_path = {}
  if total == 0 then
    cb(hunks_by_path)
    return
  end
  local pending = total
  for path in pairs(paths) do
    ensure_hunks(ctx, base, path, function(hunks)
      hunks_by_path[path] = hunks
      pending = pending - 1
      if pending == 0 then cb(hunks_by_path) end
    end)
  end
end

-- Opens `path` in the diff window and, when `lineno`/`side` are given, lands
-- the cursor on the buffer line that (side, lineno) maps to - found through
-- ctx.maps_by_buf's own per-buffer-line {side, lineno} table (the same
-- reverse lookup pr-review.lua's decorate_comments builds for a range
-- thread's highlight), since a diff buffer's PHYSICAL line numbers aren't
-- the file's line numbers once deletions are interleaved with the file's
-- unchanged/added lines. Waits on ctx.ensure_diff_content so this still
-- lands correctly even when the diff wasn't already cached/shown.
local function open_at_line(ctx, path, side, lineno)
  ctx.open_file(path, true)
  if not (side and lineno) then return end
  ctx.ensure_diff_content(path, function()
    vim.schedule(function()
      local dw = ctx.diff_win()
      if not (dw and vim.api.nvim_win_is_valid(dw)) then return end
      local buf = vim.api.nvim_win_get_buf(dw)
      if ctx.paths_by_buf[buf] ~= path then return end  -- moved on meanwhile
      local map = ctx.maps_by_buf[buf]
      local bl
      if map then
        for i, m in ipairs(map) do
          if m.side == side and m.lineno == lineno then bl = i break end
        end
      end
      if bl then
        pcall(vim.api.nvim_win_set_cursor, dw, { bl, 0 })
        vim.api.nvim_win_call(dw, function() vim.cmd("normal! zz") end)
      end
    end)
  end)
end

-- Opens the two-pane picker: `lines`/`rows_by_line` (M.build_lines) on the
-- left, a revision-buffer preview (ctx.ensure_revision_buf/when_loaded, the
-- same primitives show_hits (pr-review.lua) previews gd/gr/g/ hits with) on
-- the right, mirroring that peek layout closely enough to feel like the
-- same feature without actually calling show_hits itself - show_hits is
-- built around a flat {path, lnum, text} hit list, a single word to
-- highlight and a single `ref`, none of which fit a row that also carries a
-- thread, a per-row classification, a per-row side (source vs. target ref),
-- and its own since-range hunk highlight, so this builds its own float
-- instead (see the module comment / task's own note on this).
-- `kind` is the surface gu was pressed from ("list" | "diff" | "overview"),
-- used only to resolve that surface's own active_filter key below.
-- `anchored`/`unanchored` are every one of my threads, already classified -
-- the picker filters them at render time rather than being handed a
-- pre-filtered list, so toggling a comment filter in here can put rows back
-- without re-running the since-diff.
local function open_picker(ctx, kind, new_iterations, review_point, anchored, unanchored, hunks_by_path, base)
  followup_ns = followup_ns or vim.api.nvim_create_namespace("azure_cli_followup")

  -- The reviewer's own comment filters (gA's active-only, gF's
  -- ignore-texts) decide what shows here too: a thread hidden in the diff
  -- and on the Overview page was still listed in this picker, which is the
  -- one place "my comments" could disagree with every other surface about
  -- which comments there are.
  local lines, rows_by_line
  local function build()
    local shown = M.visible(anchored, ctx.passes_filters)
    local shown_un = M.visible(unanchored, ctx.passes_filters)
    lines, rows_by_line = M.build_lines(new_iterations, review_point, shown, shown_un)
    if #shown == 0 and #shown_un == 0 then
      lines[#lines + 1] = "(every comment of yours is hidden by the active-only filter)"
    end
  end
  build()

  local total_w = math.min(vim.o.columns - 4, math.max(80, math.floor(vim.o.columns * 0.92)))
  local height = math.min(vim.o.lines - 6, math.max(16, math.floor(vim.o.lines * 0.72)))
  local list_w = math.min(78, math.floor(total_w * 0.55))
  local prev_w = math.max(20, total_w - list_w - 2)
  local row0 = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_w) / 2))

  local lbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
  vim.bo[lbuf].modifiable = false
  vim.bo[lbuf].buftype = "nofile"
  -- The title carries the active-only state, the way every other surface's
  -- winbar carries its "[active-only]" tag - otherwise toggling the filter
  -- in here just makes rows appear and disappear with nothing saying why.
  local function title_text()
    if ctx.active_only() then return " Follow up on my comments \u{00B7} active only " end
    return " Follow up on my comments "
  end
  local ok, lwin = pcall(vim.api.nvim_open_win, lbuf, true, {
    relative = "editor", row = row0, col = col, width = list_w, height = height,
    style = "minimal", border = "rounded", title = title_text(), title_pos = "left",
  })
  if not ok then
    lwin = vim.api.nvim_open_win(lbuf, true, {
      relative = "editor", row = row0, col = col, width = list_w, height = height,
      style = "minimal", border = "rounded",
    })
  end
  require("azure-cli.ui").wo(lwin, "cursorline", true)
  require("azure-cli.ui").wo(lwin, "wrap", false)

  local pbuf = vim.api.nvim_create_buf(false, true)
  local pwin = vim.api.nvim_open_win(pbuf, false, {
    relative = "editor", row = row0, col = col + list_w + 2, width = prev_w, height = height,
    style = "minimal", border = "rounded", focusable = false,
  })
  require("azure-cli.ui").wo(pwin, "number", true)
  require("azure-cli.ui").wo(pwin, "wrap", false)
  require("azure-cli.ui").wo(pwin, "cursorline", false)

  local first_line
  for ln in pairs(rows_by_line) do
    if not first_line or ln < first_line then first_line = ln end
  end
  if first_line then pcall(vim.api.nvim_win_set_cursor, lwin, { first_line, 0 }) end

  local function selected()
    if not vim.api.nvim_win_is_valid(lwin) then return nil end
    return rows_by_line[vim.api.nvim_win_get_cursor(lwin)[1]]
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(pwin) then pcall(vim.api.nvim_win_close, pwin, true) end
    if vim.api.nvim_win_is_valid(lwin) then pcall(vim.api.nvim_win_close, lwin, true) end
  end

  local function preview()
    local row = selected()
    if not vim.api.nvim_win_is_valid(pwin) then return end
    if not row or not row.path then
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false,
        { row and "(PR-level comment \u{2014} no file)" or "(nothing selected)" })
      vim.bo[buf].modifiable = false
      vim.api.nvim_win_set_buf(pwin, buf)
      return
    end
    -- An "L" (target-side) row previews the target branch's copy - that's
    -- where its line actually lives; every other row (an "R" thread, or an
    -- unanchored file-level comment) previews the source tip, same as the
    -- since-range diff's own new side.
    local ref = (row.side == "L") and ("origin/" .. ctx.TARGET) or ("origin/" .. ctx.SOURCE)
    local buf = ctx.ensure_revision_buf(ref, row.path)
    if vim.api.nvim_win_get_buf(pwin) ~= buf then vim.api.nvim_win_set_buf(pwin, buf) end
    pcall(vim.api.nvim_win_set_config, pwin,
      { title = " " .. row.path .. (row.lineno and (":" .. row.lineno) or "") .. " ", title_pos = "left" })
    ctx.when_loaded(buf, function(b)
      if closed or selected() ~= row or vim.api.nvim_win_get_buf(pwin) ~= b then return end
      pcall(vim.api.nvim_buf_clear_namespace, b, followup_ns, 0, -1)
      local n = vim.api.nvim_buf_line_count(b)
      if row.lineno then
        local target_line = math.max(1, math.min(row.lineno, n))
        pcall(vim.api.nvim_win_set_cursor, pwin, { target_line, 0 })
        vim.api.nvim_win_call(pwin, function() vim.cmd("normal! zz") end)
        pcall(vim.api.nvim_buf_set_extmark, b, followup_ns, target_line - 1, 0,
          { line_hl_group = "AzureCliPeekLine", priority = 300 })
      end
      if row.side == "R" then
        for _, h in ipairs(hunks_by_path[row.path] or {}) do
          local first, last = M.hunk_new_range(h)
          for ln = first, math.min(last, n) do
            pcall(vim.api.nvim_buf_set_extmark, b, followup_ns, ln - 1, 0,
              { line_hl_group = "AzureCliDiffAddBg", priority = 200 })
          end
        end
      end
    end)
  end

  -- Forward-declared: the R/s keymaps below call it once their write
  -- confirms, but it also needs `lines` (redefined here, closed over by
  -- both) to stay current for the next redraw.
  local redraw_rows
  redraw_rows = function()
    if not vim.api.nvim_buf_is_valid(lbuf) then return end
    local cur = vim.api.nvim_win_is_valid(lwin) and vim.api.nvim_win_get_cursor(lwin) or nil
    for i, row in pairs(rows_by_line) do
      lines[i] = M.format_row(row)
    end
    vim.bo[lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
    vim.bo[lbuf].modifiable = false
    if cur then pcall(vim.api.nvim_win_set_cursor, lwin, cur) end
  end

  -- Re-filter and re-render the whole list (a comment filter changed), as
  -- opposed to redraw_rows above, which only re-formats the rows already
  -- shown after a reply or a status change.
  local function rerender()
    if not vim.api.nvim_buf_is_valid(lbuf) then return end
    build()
    vim.bo[lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
    vim.bo[lbuf].modifiable = false
    local first
    for ln in pairs(rows_by_line) do
      if not first or ln < first then first = ln end
    end
    if vim.api.nvim_win_is_valid(lwin) then
      if first then pcall(vim.api.nvim_win_set_cursor, lwin, { first, 0 }) end
      pcall(vim.api.nvim_win_set_config, lwin, { title = title_text(), title_pos = "left" })
    end
    preview()
  end

  local preview_timer
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = lbuf,
    callback = function()
      if preview_timer then vim.fn.timer_stop(preview_timer) end
      preview_timer = vim.fn.timer_start(40, preview)
    end,
  })
  -- Close when focus goes to a real window - but not when K or R opens a
  -- float on top (the thread popup, the reply editor), or the picker
  -- would vanish after every reply and lose your place.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = lbuf,
    callback = function()
      vim.schedule(function()
        if not (lwin and vim.api.nvim_win_is_valid(lwin)) then return end
        local cur = vim.api.nvim_get_current_win()
        if cur == lwin then return end
        local cfg = vim.api.nvim_win_get_config(cur)
        if cfg.relative ~= "" then return end
        close()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(lwin), once = true, callback = close })

  local kopts = { buffer = lbuf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local row = selected()
    if not row then return end
    close()
    if row.path then open_at_line(ctx, row.path, row.side, row.lineno) end
  end, kopts)
  vim.keymap.set("n", "K", function()
    local row = selected()
    if not (row and row.thread) then return end
    ctx.open_float(ctx.threads_to_lines({ ctx.find_thread(row.thread.id) or row.thread }), true, { big = true })
  end, kopts)
  vim.keymap.set("n", "R", function()
    local row = selected()
    if not (row and row.thread) then return end
    local target = ctx.find_thread(row.thread.id) or row.thread
    ctx.reply_to_thread(target, function()
      row.replies = math.max(0, #target.comments - 1)
      row.status = target.status
      redraw_rows()
    end)
  end, kopts)
  vim.keymap.set("n", "s", function()
    local row = selected()
    if not (row and row.thread) then return end
    local target = ctx.find_thread(row.thread.id) or row.thread
    require("azure-cli.prompt").select({ prompt = "Set thread " .. tostring(target.id) .. " status",
      items = ctx.STATUS_OPTIONS,
      current = function(o) return target.status == o.key end }, function(o)
      if not o then return end
      ctx.apply_status(target, o, function()
        row.status = target.status
        redraw_rows()
      end)
    end)
  end, kopts)
  -- gA here is the same gA as everywhere else: it flips the reviewer's own
  -- active-only filter, so the diff, the Overview page and the file list
  -- behind this picker follow along and the filter still means one thing
  -- wherever it's pressed. Resolved against the surface gu was pressed
  -- from, so a user who rebound active_filter (or unbound it) gets that
  -- here too instead of a hard-coded "gA".
  require("azure-cli.keys").bind(lbuf, kind, "active_filter", function()
    ctx.toggle_active_filter()
    rerender()
  end, { desc = "toggle active (unresolved) comments only" })
  vim.keymap.set("n", "q", close, kopts)
  vim.keymap.set("n", "<Esc>", close, kopts)

  preview()
end

-- ---------------------------------------------------------------------------

local function setup(ctx)
  -- Guards against a second gu press racing an in-flight lookup - same idea
  -- as review/since.lua's own `finding`.
  local finding = false

  -- `kind` is the surface the key was pressed from; it only travels this far
  -- so the picker can resolve that surface's own active_filter key.
  local function open_followup(kind)
    if finding then
      ctx.notify("Still checking your comments\u{2026}", vim.log.levels.WARN)
      return
    end
    local my_id = ctx.my_id()
    if not my_id then
      ctx.notify("Your identity hasn't resolved yet; try again in a moment.", vim.log.levels.WARN)
      return
    end

    local by_key, file_by_path, general = ctx.threads()
    local flat = {}
    for _, list in pairs(by_key) do
      for _, t in ipairs(list) do flat[#flat + 1] = t end
    end
    for _, list in pairs(file_by_path) do
      for _, t in ipairs(list) do flat[#flat + 1] = t end
    end
    for _, t in ipairs(general) do flat[#flat + 1] = t end

    local anchored, unanchored = M.select_my_threads(flat, my_id)
    if #anchored == 0 and #unanchored == 0 then
      ctx.notify("You have no comments on this PR yet.", vim.log.levels.WARN)
      return
    end

    finding = true
    ctx.notify("Checking your comments for nearby changes\u{2026}")
    ctx.fetch_since_base(function(base_sha, a, b)
      if not base_sha then
        finding = false
        ctx.notify(a, b)
        return
      end
      local new_iterations, review_point = a, b
      fetch_all_hunks(ctx, base_sha, anchored, function(hunks_by_path)
        finding = false
        for _, row in ipairs(anchored) do
          row.classification = M.classify(row.side, hunks_by_path[row.path], row.lineno, 3)
        end
        -- Every one of my threads goes to the picker, classified; which of
        -- them actually show is the picker's own call, since a comment
        -- filter can be toggled while it's open.
        open_picker(ctx, kind, new_iterations, review_point,
          M.sort_rows(anchored), unanchored, hunks_by_path, base_sha)
      end)
    end)
  end

  for _, kind in ipairs({ "list", "diff", "overview" }) do
    ctx.add_key(kind, "followup", function() open_followup(kind) end,
      "follow up on my comments: which threads have nearby changes since my last review")
  end

  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
