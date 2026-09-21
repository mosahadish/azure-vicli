-- lua/azure-cli/review/range.lua: comment on a range of lines - a reviewer-feature
-- module built on pr-review.lua's EXT extension mechanism (see the comment
-- at EXT's declaration there, and README's "Extending the reviewer", for why
-- this lives in its own require()'d module instead of new code in
-- pr-review.lua itself: that file is at LuaJIT's 200-local ceiling for its
-- main chunk).
--
-- Wired in by pr-review.lua's closing `do...end` block as
-- EXT.range = require(this file)(ctx) - `ctx` is the surface pr-review.lua
-- exposes (see its comment for the full field list), including
-- ctx.post_new_thread/ctx.add_pending_thread (exposed alongside the rest for
-- this module - post_new_thread now takes an optional trailing end_lineno,
-- threaded through to add_pending_thread's synthetic entry) and
-- ctx.maps_by_buf/ctx.paths_by_buf (already there for comment_here's own
-- single-line case, which this mirrors).
--
-- Like review/comments.lua/review/commits.lua, this file's
-- `return` is a table with a __call metamethod: `require(path)` alone leaves
-- the pure helpers below reachable without a real `ctx` (what
-- tests/test-review-range.lua does), and `require(path)(ctx)` additionally
-- wires everything into the reviewer.
--
-- What this adds: `c` in VISUAL mode ("x") on a diff buffer comments on the
-- whole selected range of lines instead of just the one under the cursor
-- (plain "c", still bound in setup_diff_keymaps itself, is unaffected - a
-- different mode, same key). Only the two ends of the selection have to be
-- commentable and on the same side of the diff (mirroring comment_here,
-- which only ever looks at the cursor line) - a single-line selection
-- collapses to a plain single-line comment. The thread posts optimistically
-- through ctx.post_new_thread with an extra endLine on --post's argv (see
-- the data provider's post_inline), and end_lineno on the synthetic pending
-- entry, so decorate_comments' range highlight (AzureCliCommentRange, in
-- pr-review.lua) shows immediately instead of waiting for the next thread
-- refetch to swap in the server's copy.

local M = {}

-- ---------------------------------------------------------------------------
-- Pure helpers - no vim/ctx, so tests/test-review-range.lua exercises them
-- directly under plain luajit.

-- Resolves a visual selection - the two buffer line numbers vim.fn.line("v")
-- and vim.fn.line(".") give, in whichever order the selection was made -
-- against a diff buffer's {side, lineno} map (the same shape
-- cache.lua's parse_diff produces and pr-review.lua's comment_here
-- reads) into { side, start, stop } - the file side and 1-based line
-- numbers to comment on - or nil plus a reason when the two ends can't be
-- commented on together: either one isn't mapped to a side/line at all (a
-- hunk-header or other metadata display line), or they're on opposite sides
-- of the diff (part of an added block, part of a removed one). Only the two
-- ends are checked, not everything visually between them - the same way
-- comment_here only ever looks at the cursor line.
function M.resolve_selection(map, a, b)
  local lo, hi = a, b
  if lo > hi then lo, hi = hi, lo end
  local from, to = map[lo], map[hi]
  if not (from and from.side and from.lineno) then
    return nil, "line " .. lo .. " can't be commented on"
  end
  if not (to and to.side and to.lineno) then
    return nil, "line " .. hi .. " can't be commented on"
  end
  if from.side ~= to.side then
    return nil, "selection spans both sides of the diff"
  end
  local start_lineno, end_lineno = from.lineno, to.lineno
  if start_lineno > end_lineno then start_lineno, end_lineno = end_lineno, start_lineno end
  return { side = from.side, start = start_lineno, stop = end_lineno }
end

-- Builds the --post argv for a (possibly collapsed) range comment: the
-- plain 4-arg form comment_here itself builds when stop == start, a 5th
-- endLine argument otherwise. Mirrors the data provider's post_inline/--post,
-- which only treats a 5th argument as a range when it's given and greater
-- than the start line.
function M.post_args(path, side, start, stop, text)
  if stop and stop > start then
    return { "--post", path, side, tostring(start), text, tostring(stop) }
  end
  return { "--post", path, side, tostring(start), text }
end

-- ---------------------------------------------------------------------------
-- ctx wiring.

-- Reads both ends of the visual selection while still IN visual mode -
-- line("v")/line(".") only mean anything there; the '</'> marks are only
-- set once visual mode has actually been left. Leaves visual mode
-- afterwards (a plain <Esc>, not a motion) so the input() prompt below runs
-- as an ordinary normal-mode one instead of being swallowed by the pending
-- visual selection.
local function selection_lines()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.cmd("normal! \27")
  return a, b
end

local function setup(ctx)
  -- "comment_range" - the diff surface's visual-mode "c", distinct from the
  -- normal-mode "comment" action pr-review.lua itself binds to the same
  -- default key (see config.lua's DEFAULT_KEYS.diff).
  ctx.add_key("diff", "comment_range", function()
    local buf = vim.api.nvim_get_current_buf()
    local map = ctx.maps_by_buf[buf]
    local path = ctx.paths_by_buf[buf]
    if not map or not path then
      ctx.notify("Not a diff buffer.", vim.log.levels.WARN)
      return
    end
    local a, b = selection_lines()
    local resolved, err = M.resolve_selection(map, a, b)
    if not resolved then
      ctx.notify("Can't comment on this selection: " .. err .. ".", vim.log.levels.WARN)
      return
    end
    local side, start, stop = resolved.side, resolved.start, resolved.stop
    local range_label = (stop > start) and (side .. ":" .. start .. "-" .. stop) or (side .. ":" .. start)
    local where = path .. "\t" .. side .. "\t" .. start
    local top_line = math.min(a, b)
    local context_lines = vim.api.nvim_buf_get_lines(buf, top_line - 1, math.max(a, b), false)

    local mentions = {}
    do
      local pr = ctx.current_pr_record()
      for _, r in ipairs((pr and pr.reviewers) or {}) do
        if r.name and r.name ~= "" then mentions[#mentions + 1] = { name = r.name, id = r.id } end
      end
    end
    local EDITOR = require("azure-cli.editor")
    EDITOR.open({
      title = EDITOR.format_title("range", { path = path, lineno = start, end_lineno = stop }),
      context_lines = context_lines,
      anchor = { win = ctx.diff_win(), row = top_line },
      mentions = mentions,
      draft_key = EDITOR.draft_key(ctx.ID, "line", where),
      on_submit = function(text)
        local args = M.post_args(path, side, start, stop, text)
        local end_lineno = (stop > start) and stop or nil
        ctx.post_new_thread(args, "line", where, path, side, start, text,
          "Comment on " .. path .. " " .. range_label,
          "comment (" .. path .. " " .. range_label .. ")", end_lineno)
      end,
    })
  end, "comment on the selected range of lines", "x")

  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
