-- lua/azure-cli/review/batch.lua: batched review - queue comments instead of
-- sending each one the instant Enter is pressed, then submit them all
-- together with a vote (the same shape a GitHub "Start a review" does) - a
-- reviewer-feature module built on pr-review.lua's EXT extension mechanism
-- (see the comment at EXT's declaration there, and README's "Extending the
-- reviewer", for why this lives in its own require()'d module instead of new
-- code in pr-review.lua itself: that file is at LuaJIT's 200-local ceiling
-- for its main chunk).
--
-- Wired in by pr-review.lua's closing `do...end` block as
-- EXT.batch = require(this file)(ctx), right after EXT.range - `ctx` is the
-- surface pr-review.lua exposes (see its comment for the full field list).
-- Like review/range.lua/review/comments.lua, this file's
-- `return` is a table with a __call metamethod: `require(path)` alone leaves
-- the pure helpers below reachable without a real `ctx` (what
-- tests/test-review-batch.lua does), and `require(path)(ctx)` additionally
-- wires everything into the reviewer and attaches two more fields to the
-- same table - `intercept` and `tag`, both consulted straight off EXT.batch
-- by pr-review.lua itself (post_new_thread/send_reply/sending_tag/
-- set_list_winbar/set_diff_winbar), not through ctx.add_key, since none of
-- those are "a key a module binds" - see the module comment at EXT's
-- declaration in pr-review.lua for that contract.
--
-- How it hooks in: pr-review.lua's post_new_thread and send_reply each call
-- EXT.batch.intercept(kind, info) as the very first thing they do (before
-- post_new_thread adds its own pending entry, and after reply_to_thread has
-- already appended the reply's comment to its thread). When batch mode is
-- on for this PR, intercept() takes the write over - it builds its own
-- synthetic "queued" entry (a thread) or tags the one already there
-- (a reply) and returns true, so the caller returns immediately without
-- ever touching run_write. When batch mode is off (or the module hasn't
-- loaded yet), it returns false and the write goes out exactly as it always
-- has. A queued entry renders with a "(queued)" tag instead of
-- "(sending...)" (see pr-review.lua's sending_tag) until gS actually sends
-- it.
--
-- State: state.lua's STATE.batch[pr id] = { on = bool, items = {...} }, so leaving
-- and re-opening the same PR within one nvim session keeps the queue (this
-- module's setup() re-creates every item's synthetic entry from scratch on
-- load - see rehydrate() below - since the diff buffers and thread tables
-- it hung off are themselves rebuilt from scratch on reopen). Each item is
-- either { kind = "thread", args, bucket, where, path, side, lineno,
-- end_lineno, text, label, pending = <ctx.add_pending_thread's return> } or
-- { kind = "reply", thread_id, text, comment, thread }; `pending`/`comment`/
-- `thread` are this-session-only bookkeeping, rebuilt by rehydrate() rather
-- than persisted verbatim.
--
-- Keys (list/diff/overview - see ctx.add_key's kinds): gB toggles batch mode
-- for this PR, gQ opens a float listing the queue (dd on a line removes that
-- item, q/<Esc> closes), gS submits the whole queue in order plus an
-- optional vote and turns batch mode back off once everything's landed.

local M = {}

-- ---------------------------------------------------------------------------
-- Pure helpers - no vim/ctx, so tests/test-review-batch.lua exercises them
-- directly under plain luajit, the same way review/range.lua/
-- review/comments.lua's pure helpers are tested.

-- Winbar tag for a PR's batch state, or "" when batch mode is off - what
-- pr-review.lua's set_list_winbar/set_diff_winbar splice in via
-- EXT.batch.tag() (see setup() below, which wraps this against the live
-- per-PR state instead of taking one as an argument).
function M.tag(state)
  if not (state and state.on) then return "" end
  return "  [batch: " .. #state.items .. "]"
end

-- Appends a queued "new thread" item (a line/file/PR-level comment) to
-- state.items and returns it. `info` is the table post_new_thread's
-- interceptor call receives: args (the argv the write would have run),
-- bucket/where/path/side/lineno/end_lineno (add_pending_thread's own
-- parameters), text and label.
function M.queue_thread(state, info)
  local item = {
    kind = "thread", args = info.args, bucket = info.bucket, where = info.where,
    path = info.path, side = info.side, lineno = info.lineno,
    end_lineno = info.end_lineno, text = info.text, label = info.label,
  }
  table.insert(state.items, item)
  return item
end

-- Appends a queued "reply" item. `comment` is the live comment table
-- reply_to_thread already appended to the thread before send_reply's
-- interceptor call - kept on the item so the very same object can be
-- retagged queued/sending/confirmed in place, without hunting through the
-- thread's comments again to find it.
function M.queue_reply(state, info)
  local item = { kind = "reply", thread_id = info.thread_id, text = info.text, comment = info.comment }
  table.insert(state.items, item)
  return item
end

-- Removes `item` from state.items by identity. Returns true if it was there.
function M.remove_item(state, item)
  for i, it in ipairs(state.items) do
    if it == item then
      table.remove(state.items, i)
      return true
    end
  end
  return false
end

-- The argv a queued item's write submits when gS sends it: a thread item's
-- stored args as-is (built by comment_here/comment_on_file/comment_on_pr/
-- review/range.lua exactly as if it had gone out immediately), a
-- reply item's --reply call (the data provider's --reply subcommand: thread id,
-- text - the same two arguments send_reply itself would have passed).
function M.item_args(item)
  if item.kind == "reply" then
    return { "--reply", tostring(item.thread_id), item.text }
  end
  return item.args
end

-- Submits every item currently in state.items, in order, through
-- run_write(args, on_ok, on_fail) (the same shape as ctx.run_write, injected
-- rather than read off a ctx so this is directly unit-testable with a fake -
-- mirrors M.apply_edit/M.apply_delete in review/comments.lua).
-- Sequential: item i+1 only starts once item i's write has returned, so a
-- submit reads top-to-bottom the same order the gQ float lists the queue in,
-- and no later item's confirm can land before an earlier one's failure is
-- known. A confirmed item is removed from state.items; a failed one is left
-- in place (still queued) so both the summary and a later gS see it.
--
-- hooks.before(item) runs right before that item's own write starts (flip
-- its tag from queued to sending); hooks.after(item, ok, err) once it
-- settles (confirm on success, restore the queued tag on failure - neither
-- of those is this function's job, it only reports what happened). Once
-- every item has settled, the vote is sent last through the same run_write -
-- only when `vote` (a { key, label } pair) is non-nil, i.e. was actually
-- chosen, never a "no vote" submit. hooks.done(results, vote_err) runs last,
-- with results = { {item = item, ok = bool, err = msg-or-nil}, ... } in
-- submission order and vote_err = nil when there was no vote to send or it
-- succeeded, the failure message otherwise.
function M.submit(state, run_write, vote, hooks)
  hooks = hooks or {}
  local before = hooks.before or function() end
  local after = hooks.after or function() end
  local done = hooks.done or function() end

  -- Snapshot the queue order up front: state.items is mutated (confirmed
  -- items removed) as submission proceeds, so walking it directly would
  -- skip whatever the removal just shifted into the current index.
  local items = {}
  for _, it in ipairs(state.items) do items[#items + 1] = it end

  local results = {}
  local function do_vote()
    if not vote then
      done(results, nil)
      return
    end
    run_write({ "--vote", vote.key }, function()
      done(results, nil)
    end, function(msg)
      done(results, msg)
    end)
  end

  local i = 0
  local function step()
    i = i + 1
    local item = items[i]
    if not item then
      do_vote()
      return
    end
    before(item)
    run_write(M.item_args(item), function()
      M.remove_item(state, item)
      results[#results + 1] = { item = item, ok = true }
      after(item, true)
      step()
    end, function(msg)
      results[#results + 1] = { item = item, ok = false, err = msg }
      after(item, false, msg)
      step()
    end)
  end
  step()
end

-- ---------------------------------------------------------------------------
-- ctx wiring.

-- Display line for one queued item in the gQ float: "kind  location  text".
local function item_location(item)
  if item.kind == "reply" then
    return "reply -> thread " .. tostring(item.thread_id)
  end
  if item.bucket == "general" then
    return "PR comment"
  end
  if item.bucket == "file" then
    return item.path .. " (file)"
  end
  local loc = tostring(item.path) .. " " .. tostring(item.side) .. ":" .. tostring(item.lineno)
  if item.end_lineno and item.lineno and item.end_lineno > item.lineno then
    loc = loc .. "-" .. item.end_lineno
  end
  return loc
end

local function render_queue(state)
  local lines = { string.format("%-6s  %-32s  %s", "kind", "location", "text"), "" }
  for _, item in ipairs(state.items) do
    local text = (item.text or ""):gsub("%s+", " ")
    if #text > 60 then text = text:sub(1, 57) .. "..." end
    lines[#lines + 1] = string.format("%-6s  %-32s  %s", item.kind, item_location(item), text)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "(dd: remove   q/<Esc>: close)"
  return lines
end

local function setup(ctx)
  -- require()d here rather than at the top of the file: tests/test-review-
  -- batch.lua require()s this module directly, without ever calling setup(),
  -- to exercise the pure helpers above under plain luajit (see the module
  -- comment) - lazily requiring state.lua only when a real ctx wires this
  -- module in keeps that test path free of needing a require() shim.
  local STATE = require("azure-cli.state")
  STATE.batch = STATE.batch or {}

  -- This PR's persisted batch state - created once and kept in state.lua so
  -- leaving and re-opening the PR (within the same nvim session/tab) finds
  -- the same queue again, the same way the ignore-whitespace toggle and
  -- last-search text already do (see review/init.lua's own STATE use).
  local function state()
    local s = STATE.batch[ctx.ID]
    if not s then
      s = { on = false, items = {} }
      STATE.batch[ctx.ID] = s
    end
    return s
  end

  -- Captured before setup() overwrites M.tag with the zero-argument, this-PR
  -- bound version pr-review.lua's winbars call (EXT.batch.tag()) - keeps the
  -- pure two-argument M.tag(state) above intact for tests/test-review-batch.lua,
  -- which require()s this module without ever calling setup().
  local tag_text = M.tag

  -- Drops a queued item: pulls its synthetic entry back out (a pending
  -- thread via ctx.drop_pending_thread; a queued reply's comment straight
  -- out of its thread's comments and out of ctx.pending_replies()) and
  -- removes the item itself from state.items. Used by `dd` in the gQ float,
  -- and by rehydrate() below for a reply whose thread has disappeared by
  -- the time the PR is reopened.
  local function drop_item(s, item)
    if item.kind == "thread" then
      if item.pending then ctx.drop_pending_thread(item.pending) end
    elseif item.kind == "reply" then
      if item.thread and item.comment then
        ctx.remove_entry(item.thread.comments, item.comment)
      end
      local reps = ctx.pending_replies()
      for i = #reps, 1, -1 do
        if reps[i].comment == item.comment then table.remove(reps, i) end
      end
    end
    M.remove_item(s, item)
  end

  -- Re-creates the synthetic pending entries for every item already queued
  -- for this PR. Reopening a PR rebuilds the diff buffers and thread tables
  -- from scratch, so whatever synthetic entry a previous visit's intercept()
  -- call made is gone even though the item itself survived in _G. A thread
  -- item just re-runs ctx.add_pending_thread the same way intercept() did;
  -- a reply item looks its target thread back up by id and, if it's still
  -- there, appends a fresh queued comment to it (registered with
  -- ctx.pending_replies() too, so a background refresh keeps carrying it the
  -- same way an in-flight reply already would be) - if the thread is gone,
  -- the item is dropped and this says so.
  local function rehydrate()
    local s = state()
    for i = #s.items, 1, -1 do
      local item = s.items[i]
      if item.kind == "thread" then
        local p = ctx.add_pending_thread(item.text, item.bucket, item.where,
          item.path, item.side, item.lineno, item.end_lineno)
        p.entry.queued = true
        p.entry.comments[1].queued = true
        item.pending = p
      elseif item.kind == "reply" then
        local t = ctx.find_thread(item.thread_id)
        if not t then
          table.remove(s.items, i)
          ctx.notify("Dropped a queued reply to thread " .. tostring(item.thread_id)
            .. ": it no longer exists.", vim.log.levels.WARN)
        else
          local c = {
            author = ctx.my_display_name(), authorId = ctx.my_id(),
            content = item.text, pending = true, queued = true,
          }
          table.insert(t.comments, c)
          table.insert(ctx.pending_replies(), { thread_id = t.id, comment = c })
          item.comment, item.thread = c, t
        end
      end
    end
  end
  rehydrate()

  -- Takes over a write post_new_thread/send_reply would otherwise send right
  -- away: queues it instead, tags its already-shown optimistic entry
  -- "(queued)" (pr-review.lua's sending_tag checks x.queued before the
  -- pending/sending case), and returns true so the caller does nothing
  -- further. Returns false when batch mode is off for this PR, so a plain
  -- comment/reply still goes out immediately - see the module comment above
  -- for the full contract pr-review.lua's two call sites rely on.
  local function intercept(kind, info)
    local s = state()
    if not s.on then return false end
    if kind == "thread" then
      local item = M.queue_thread(s, info)
      local p = ctx.add_pending_thread(info.text, info.bucket, info.where,
        info.path, info.side, info.lineno, info.end_lineno)
      p.entry.queued = true
      p.entry.comments[1].queued = true
      item.pending = p
      ctx.redraw()
      ctx.notify("Queued: " .. info.label .. " (" .. #s.items .. " queued).")
      return true
    elseif kind == "reply" then
      local item = M.queue_reply(s, { thread_id = info.target.id, text = info.text, comment = info.comment })
      info.comment.queued = true
      table.insert(ctx.pending_replies(), { thread_id = info.target.id, comment = info.comment })
      item.thread = info.target
      ctx.redraw()
      ctx.notify("Queued: reply to thread " .. tostring(info.target.id) .. " (" .. #s.items .. " queued).")
      return true
    end
    return false
  end

  -- gB: toggle batch mode for this PR.
  local function toggle_batch()
    local s = state()
    s.on = not s.on
    ctx.notify("Batch review: " .. (s.on and "on" or "off")
      .. (#s.items > 0 and (" (" .. #s.items .. " queued)") or "") .. ".")
    ctx.redraw()
  end

  -- gQ: float listing the queue; dd removes the item under the cursor.
  local function open_queue()
    local s = state()
    if #s.items == 0 then
      ctx.notify("No queued comments (gB to turn batch mode on, then comment as usual).")
      return
    end
    local win = ctx.open_float(render_queue(s), true, { min_width = 60 })
    if not win then return end
    local fbuf = vim.api.nvim_win_get_buf(win)
    local kopts = { buffer = fbuf, silent = true, nowait = true }
    local function redraw_float()
      if not vim.api.nvim_buf_is_valid(fbuf) then return end
      if #s.items == 0 then
        pcall(vim.api.nvim_win_close, win, true)
        return
      end
      vim.bo[fbuf].modifiable = true
      pcall(vim.api.nvim_buf_set_lines, fbuf, 0, -1, false, render_queue(s))
      vim.bo[fbuf].modifiable = false
    end
    vim.keymap.set("n", "dd", function()
      -- Two header lines (title + blank) before the first item row.
      local idx = vim.api.nvim_win_get_cursor(win)[1] - 2
      local item = s.items[idx]
      if not item then
        ctx.notify("Not on a queued item.", vim.log.levels.WARN)
        return
      end
      drop_item(s, item)
      ctx.notify("Removed from the queue.")
      redraw_float()
      ctx.redraw()
    end, kopts)
  end

  -- gS: prompt for a vote (same choices as cast_vote, plus "No vote"), then
  -- submit the whole queue through M.submit, turning batch mode back off
  -- once everything landed cleanly.
  local function submit_batch()
    local s = state()
    if #s.items == 0 then
      ctx.notify("No queued comments to submit.", vim.log.levels.WARN)
      return
    end
    local items = {}
    for _, o in ipairs(ctx.VOTE_OPTIONS) do items[#items + 1] = o end
    items[#items + 1] = { label = "No vote", none = true }
    require("azure-cli.prompt").select({ prompt = "Submit " .. #s.items .. " queued comment(s) - vote",
      items = items }, function(choice)
    if not choice then return end
    local vote = (not choice.none) and choice or nil

    ctx.notify("Submitting " .. #s.items .. " queued item(s)"
      .. (vote and (", then voting " .. vote.label) or "") .. "\u{2026}")

    M.submit(s, ctx.run_write, vote, {
      before = function(item)
        if item.kind == "thread" and item.pending then
          item.pending.entry.queued = nil
          if item.pending.entry.comments[1] then item.pending.entry.comments[1].queued = nil end
        elseif item.kind == "reply" and item.comment then
          item.comment.queued = nil
        end
        ctx.redraw()
      end,
      after = function(item, ok)
        if item.kind == "thread" then
          if ok then
            if item.pending then ctx.confirm_pending_thread(item.pending) end
          elseif item.pending then
            item.pending.entry.queued = true
            if item.pending.entry.comments[1] then item.pending.entry.comments[1].queued = true end
          end
        elseif item.kind == "reply" then
          if ok then
            if item.comment then item.comment.pending = nil end
            local reps = ctx.pending_replies()
            for i = #reps, 1, -1 do
              if reps[i].comment == item.comment then table.remove(reps, i) end
            end
          elseif item.comment then
            item.comment.queued = true
          end
        end
        ctx.redraw()
      end,
      done = function(results, vote_err)
        local ok_n, fail_n = 0, 0
        for _, r in ipairs(results) do
          if r.ok then ok_n = ok_n + 1 else fail_n = fail_n + 1 end
        end
        if fail_n == 0 then s.on = false end
        ctx.refresh_threads()
        local msg = "Submitted " .. ok_n .. " comment" .. (ok_n == 1 and "" or "s")
        if vote then
          if vote_err then
            msg = msg .. "; vote failed (" .. vote_err .. ")"
          else
            msg = msg .. " and voted " .. vote.label
          end
        end
        if fail_n > 0 then
          msg = msg .. "; " .. fail_n .. " failed and stayed queued"
        end
        ctx.notify(msg .. ".", fail_n > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
        ctx.redraw()
      end,
    })
    end)
  end

  for _, kind in ipairs({ "list", "diff", "overview" }) do
    ctx.add_key(kind, "batch_toggle", toggle_batch, "toggle batch review (queue comments, submit together with a vote)")
    ctx.add_key(kind, "batch_queue", open_queue, "show the queued batch-review items")
    ctx.add_key(kind, "batch_submit", submit_batch, "submit the queued batch-review items, with a vote")
  end

  M.intercept = intercept
  M.tag = function() return tag_text(state()) end
  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
