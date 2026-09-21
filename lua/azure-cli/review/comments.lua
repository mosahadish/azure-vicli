-- lua/azure-cli/review/comments.lua: edit/delete your own PR comments - the first
-- feature module built on pr-review.lua's EXT extension mechanism (see the
-- comment at EXT's declaration there for why this exists as a separate
-- require()'d module instead of new code in pr-review.lua itself: that file is
-- at LuaJIT's 200-local ceiling for its main chunk).
--
-- Wired in by pr-review.lua's closing `do...end` block as
-- EXT.comments = require(this file)(ctx) - `ctx` is the surface pr-review.lua
-- exposes (see its comment for the full field list). This file's `return`
-- is a table with a __call metamethod, so require(path)(ctx) both runs the
-- setup below AND leaves the table's own fields (the pure helpers) reachable
-- via `local M = require(path)` without calling it at all - that's what
-- tests/test-review-comments.lua exercises, without nvim or a real `ctx`.
--
-- Surfaces: the Overview page and the K popup (a comment thread's own
-- floating view, opened from a diff line). Both get `e` (edit) and `dd`
-- (delete) on a comment authored by me (comment.authorId == ctx.my_id());
-- pressing either on someone else's comment just warns instead of doing
-- nothing silently.
--
-- Finding "the comment under the cursor" differs by surface, deliberately:
--   Overview   its comments pass through pr-review.lua's active-only/text
--              filters, so this re-renders with ctx.build_overview() (which
--              applies those filters itself) and reads its 3rd return - a
--              bufline -> {thread, comment} map already built the same way
--              the buffer's own content was - rather than reimplementing
--              that filtering here against ctx.threads()'s raw tables.
--   K popup    show_comments_here already filtered its thread list before
--              handing it to ctx.on_comment_popup's callback (see below), so
--              there's no filtering left to replicate. This module scans the
--              popup's OWN rendered lines instead (M.build_comment_map, a
--              pure helper - see its comment), so it only depends on the
--              "│ " comment-header convention pr-review.lua's
--              threads_to_lines uses, not on any of that function's other
--              formatting (wrapping, the sending tag, ...).
--
-- Optimistic apply/revert follows the rest of the reviewer: an edit shows at
-- once (tagged "(sending...)" via the same c.pending flag threads_to_lines/
-- build_overview already render specially for a brand-new comment/reply),
-- and rolls back with an error notification if the REST call fails - a
-- failed edit also reopens the prompt with the text prefilled
-- (ctx.retry_prompt), matching comment_here/reply_to_thread elsewhere in
-- pr-review.lua. A delete just restores the comment (and its thread, if the
-- comment was the thread's only one) on failure; there's no text to lose the
-- way there is for an edit, so no retry prompt.

local M = {}

-- Flattens `threads` (a list of { comments = { {...}, ... }, ... }) into the
-- (thread, comment) pairs in the exact order threads_to_lines/build_overview
-- walk them: thread 1's comments in order, then thread 2's, and so on.
function M.flatten_comments(threads)
  local flat = {}
  for _, t in ipairs(threads or {}) do
    for _, c in ipairs(t.comments or {}) do
      flat[#flat + 1] = { thread = t, comment = c }
    end
  end
  return flat
end

-- Maps each line of an already-rendered threads_to_lines popup (`lines`, a
-- plain list of strings - the buffer's current content) to the (thread,
-- comment) it belongs to. Scans for a comment header line: "│ "
-- followed immediately by a non-space character (the author's first
-- letter) - a content-continuation line always has a SECOND space there too
-- ("│   " - see threads_to_lines), so the two never collide. Each
-- header line found is paired, in order, with the N-th (thread, comment)
-- pair M.flatten_comments walks to - the two orders are identical by
-- construction (both walk threads, then each thread's comments, in order),
-- so this is an exact match to what's on screen rather than a guess at its
-- content. Deliberately does NOT re-derive line numbers from
-- threads_to_lines' own layout rules (blank separators, content wrapping,
-- the sending-tag suffix...) - matching the rendered text directly means
-- none of that can silently drift this out of sync.
function M.build_comment_map(lines, threads)
  local flat = M.flatten_comments(threads)
  local map, i = {}, 0
  for lnum, line in ipairs(lines) do
    if line:match("^\226\148\130 %S") then
      i = i + 1
      if flat[i] then map[lnum] = flat[i] end
    end
  end
  return map
end

-- Optimistically edits comment `c` (in thread `t`) to `text`: applies it
-- (and tags it c.pending, same as a brand-new comment/reply) before
-- run_write even starts, reverting to the saved content on failure.
-- run_write(args, on_ok, on_fail) is injected rather than read off a `ctx`
-- so this is directly unit-testable with a fake. on_change (optional) is
-- called once right after the optimistic apply and again once the write
-- settles - with an error message on failure, nothing on success - so a
-- caller can redraw/notify without this function knowing about vim at all.
function M.apply_edit(t, c, text, run_write, on_change)
  local prev = c.content
  c.content = text
  c.pending = true
  if on_change then on_change() end
  run_write({ "--edit-comment", tostring(t.id), tostring(c.id), text },
    function()
      c.pending = nil
      if on_change then on_change() end
    end,
    function(msg)
      c.content = prev
      c.pending = nil
      if on_change then on_change(msg) end
    end)
end

-- Optimistically deletes comment `c` from thread `t`. If `c` was the
-- thread's only comment, `t` itself is removed from `bucket` too (the array
-- it currently lives in - one of ctx.threads()'s three tables, or a
-- sub-list of the first two; the caller resolves which one, since that's
-- ctx-shaped work, not pure - see locate_bucket below). Reverts (reinserting
-- at the same position/index) on failure. run_write/on_change as in
-- M.apply_edit.
function M.apply_delete(t, c, bucket, run_write, on_change)
  local comment_idx
  for i, cc in ipairs(t.comments) do
    if cc == c then comment_idx = i break end
  end
  if not comment_idx then return end
  table.remove(t.comments, comment_idx)

  local thread_idx
  if #t.comments == 0 and bucket then
    for i, tt in ipairs(bucket) do
      if tt == t then thread_idx = i break end
    end
    if thread_idx then table.remove(bucket, thread_idx) end
  end

  if on_change then on_change() end
  run_write({ "--delete-comment", tostring(t.id), tostring(c.id) },
    function()
      if on_change then on_change() end
    end,
    function(msg)
      table.insert(t.comments, comment_idx, c)
      if thread_idx and bucket then table.insert(bucket, thread_idx, t) end
      if on_change then on_change(msg) end
    end)
end

-- Finds which of ctx.threads()'s tables/sub-lists `t` currently lives in, by
-- the same key shape pr-review.lua's own (private) bucket_list() uses:
-- line-anchored threads under "path\tside\tlineno", file-anchored under
-- "path", everything else in the general list.
local function locate_bucket(ctx, t)
  local by_key, file_by_path, general = ctx.threads()
  if t.path and t.side and t.lineno then
    return by_key[t.path .. "\t" .. t.side .. "\t" .. t.lineno]
  elseif t.path then
    return file_by_path[t.path]
  end
  return general
end

-- Prompts for new text (prefilled with the current content) and runs
-- M.apply_edit, notifying and offering a prefilled retry on failure -
-- mirrors comment_here/reply_to_thread's own retry_prompt use in
-- pr-review.lua. on_change is called immediately (optimistic) and again once
-- the write settles, so the caller can redraw its view of the comment.
local function do_edit(ctx, t, c, on_change)
  if c.pending or not c.id then
    ctx.notify("Still sending; try again once it's confirmed.", vim.log.levels.WARN)
    return
  end
  local function attempt(value)
    M.apply_edit(t, c, value, ctx.run_write, function(err)
      if on_change then on_change() end
      if err then
        ctx.notify("Edit failed (" .. err .. "); reverted.", vim.log.levels.ERROR)
        ctx.retry_prompt("Retry edit: ", value, attempt)
      elseif not c.pending then
        ctx.notify("Comment updated.")
      end
    end)
  end
  -- Floating editor, prefilled with the current text (see editor.lua's own
  -- header comment) - a submit with the text unchanged just re-sends it
  -- (harmless: the server gets a PATCH with the same content), rather than
  -- the old input()'s special-cased silent no-op for that case.
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("edit", {}),
    initial = c.content,
    anchor = "center",
    on_submit = attempt,
  })
end

-- Confirms (inputlist, same style as pr-review.lua's other menus) and runs
-- M.apply_delete. No retry on failure - a delete either lands or it doesn't;
-- there's no text to lose the way there is for an edit.
local function do_delete(ctx, t, c, on_change)
  if c.pending or not c.id then
    ctx.notify("Still sending; try again once it's confirmed.", vim.log.levels.WARN)
    return
  end
  require("azure-cli.prompt").confirm({ prompt = "Delete this comment?", yes = "Delete", no = "Keep" }, function(yes)
    if not yes then
      ctx.notify("Cancelled.")
      return
    end
    local bucket = (#t.comments == 1) and locate_bucket(ctx, t) or nil
    M.apply_delete(t, c, bucket, ctx.run_write, function(err)
      if on_change then on_change() end
      if err then
        ctx.notify("Delete failed (" .. err .. "); restored.", vim.log.levels.ERROR)
      else
        ctx.notify("Comment deleted.")
      end
    end)
  end)
end

-- The comment under the cursor on the Overview page - see the module
-- comment above for why this re-renders with ctx.build_overview() rather
-- than scanning, the way the K popup binding below does.
local function overview_hit(ctx)
  local ov = ctx.overview_buf()
  if not (ov and vim.api.nvim_buf_is_valid(ov)) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local _, _, comment_map = ctx.build_overview()
  return comment_map[lnum]
end

local function setup(ctx)
  ctx.add_key("overview", "edit_comment", function()
    local hit = overview_hit(ctx)
    if not hit then
      ctx.notify("No comment on this line.", vim.log.levels.WARN)
      return
    end
    if hit.comment.authorId ~= ctx.my_id() then
      ctx.notify("You can only edit your own comments.", vim.log.levels.WARN)
      return
    end
    do_edit(ctx, hit.thread, hit.comment, ctx.redraw)
  end, "edit your own comment")

  ctx.add_key("overview", "delete_comment", function()
    local hit = overview_hit(ctx)
    if not hit then
      ctx.notify("No comment on this line.", vim.log.levels.WARN)
      return
    end
    if hit.comment.authorId ~= ctx.my_id() then
      ctx.notify("You can only delete your own comments.", vim.log.levels.WARN)
      return
    end
    do_delete(ctx, hit.thread, hit.comment, ctx.redraw)
  end, "delete your own comment")

  -- The K popup is a fresh float/buffer per view (see the module comment
  -- above), so its keys are bound here instead of through ctx.add_key.
  ctx.on_comment_popup(function(fbuf, threads)
    local kopts = { buffer = fbuf, silent = true, nowait = true }

    local function current()
      if not vim.api.nvim_buf_is_valid(fbuf) then return nil end
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
      return M.build_comment_map(lines, threads)[lnum]
    end

    -- Redraws the diff/Overview/file-list behind the popup (ctx.redraw) and
    -- this popup's own float: drops any thread this popup's local `threads`
    -- snapshot now has zero comments left in (a whole-thread delete), then
    -- either re-renders or - if nothing's left on this line - notifies and
    -- closes it, mirroring show_comments_here's own refresh() in
    -- pr-review.lua for the same "no more comments" case.
    local function redraw_popup()
      ctx.redraw()
      if not vim.api.nvim_buf_is_valid(fbuf) then return end
      for i = #threads, 1, -1 do
        if #threads[i].comments == 0 then table.remove(threads, i) end
      end
      if #threads == 0 then
        ctx.notify("No more comments on this line.")
        local win = vim.fn.win_findbuf(fbuf)[1]
        if win then pcall(vim.api.nvim_win_close, win, true) end
        return
      end
      vim.bo[fbuf].modifiable = true
      pcall(vim.api.nvim_buf_set_lines, fbuf, 0, -1, false, (ctx.threads_to_lines(threads)))
      vim.bo[fbuf].modifiable = false
    end

    vim.keymap.set("n", "e", function()
      local hit = current()
      if not hit then
        ctx.notify("No comment on this line.", vim.log.levels.WARN)
        return
      end
      if hit.comment.authorId ~= ctx.my_id() then
        ctx.notify("You can only edit your own comments.", vim.log.levels.WARN)
        return
      end
      do_edit(ctx, hit.thread, hit.comment, redraw_popup)
    end, kopts)

    vim.keymap.set("n", "dd", function()
      local hit = current()
      if not hit then
        ctx.notify("No comment on this line.", vim.log.levels.WARN)
        return
      end
      if hit.comment.authorId ~= ctx.my_id() then
        ctx.notify("You can only delete your own comments.", vim.log.levels.WARN)
        return
      end
      do_delete(ctx, hit.thread, hit.comment, redraw_popup)
    end, kopts)
  end)

  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
