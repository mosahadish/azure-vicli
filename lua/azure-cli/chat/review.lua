-- lua/azure-cli/chat/review.lua: a second agent looks at a plan agent's
-- change before the user does (setup({ chat = { self_review = true } })).
--
-- The first show_fix under an approved plan revision doesn't announce the
-- change: it starts a reviewer - a read-only conversation of its own, keyed
-- "review-<plan key>", its target { review_of = <plan key> }, on
-- agent.reviewer_model when set - that reads the plan and `git diff HEAD` in
-- the worktree. Its findings go back to the implementing agent as a message
-- in its own conversation, and its next show_fix announces the change as
-- usual. Once per approved revision (rec.reviewed_rev). A reviewer that
-- fails or times out doesn't hold the change up: it's announced then, and
-- the implementer is told. The Agents screen has no row of the reviewer's;
-- its implementer's says "in review" (agents_view.lua).
--
--   M.on_show(target, dir, env, announce)  show_fix's step: the change
--                             announced (announce() called) or not, and
--                             what show_fix tells the agent - nil, or a note
--                             and whether it's in review
--   M.key(plan_key)           the reviewer's conversation key
--   M.running(plan_key)       whether plan `plan_key`'s reviewer is at it
--   M.prompt(rec, dir, plan_text)  the reviewer's message (pure)
--   M.findings_message(text)  what the implementer gets back (pure)
local M = {}

local function CHAT() return require("azure-cli.chat") end
local function PLAN() return require("azure-cli.chat.plan") end
local function config() return require("azure-cli.config").get().chat or {} end

-- How much of the reviewer's answer goes back to the implementer.
M.FINDINGS_MAX = 6000

function M.key(plan_key) return "review-" .. plan_key end

function M.running(plan_key)
  local c = CHAT().find_conversation(M.key(plan_key))
  return c ~= nil and c.running ~= nil
end

function M.prompt(rec, dir, plan_text)
  return "You are reviewing another agent's change before the user sees it. It implements the approved plan for "
    .. PLAN().target_label(rec.target) .. (rec.title and rec.title ~= "" and (" \"" .. rec.title .. "\"") or "")
    .. ", in the worktree " .. dir .. ". The plan (also in " .. PLAN().path(rec.key) .. "):\n\n" .. plan_text
    .. "\n\nRead the change with `git -C " .. dir .. " diff HEAD` (git diff, log and show only look, so they don't "
    .. "ask), and the files around it with Read/Grep under " .. dir .. ". You are read-only: don't edit files, "
    .. "commit, push or change anything on the server. Look for correctness bugs, missing or weak tests, and "
    .. "things the plan promised that the change doesn't do. Answer with a short list of findings - each with "
    .. "the file and line, what's wrong and why - or just \"No findings.\" Nothing else: your answer goes "
    .. "to the agent that made the change."
end

function M.findings_message(text)
  return "A reviewer looked at your change: " .. text .. "\n\nFix what you agree with, say why not for the rest, "
    .. "then call show_fix again."
end

-- Queues `text` in conversation `conv` - after its turn and what's queued
-- before it, as message_agent does - or sends it now.
local function deliver(conv, text, display)
  local opts = { conv = conv, display = display,
    done_note = (conv.label or conv.plan_key or "An agent") .. "'s agent answered (the Agents screen lists them)." }
  local snap
  for _, e in ipairs(conv.entries or {}) do if e.role == "you" and e.view then snap = e.view end end
  opts.snap = snap
  local pending = false
  for _, q in ipairs(conv.queue or {}) do if not q.held then pending = true end end
  if conv.running or pending then
    local RUN = require("azure-cli.chat.run")
    RUN.queue(conv, text, opts)
    if not conv.running then RUN.drain(conv) end
    return
  end
  CHAT().send(text, opts)
end

-- Starts plan `rec`'s reviewer on the change in `dir`; done(entry) when it
-- has answered. False when it couldn't start.
local function start(rec, dir, done)
  local key = M.key(rec.key)
  -- A fresh one each time: an earlier revision's review isn't this one's.
  local old = CHAT().find_conversation(key)
  if old then
    pcall(require("azure-cli.chat.run").stop_persistent, old)
    CHAT().drop_conversation(key)
  end
  local rev = PLAN().revision(rec, rec.approved_rev)
  local text = rev and rev.markdown or table.concat(PLAN().lines(rec), "\n")
  local label = PLAN().target_label(rec.target)
  local conv = CHAT().conversation(key, { label = label .. " review", title = rec.title,
    target = { review_of = rec.key } })
  local entry = CHAT().send(M.prompt(rec, dir, text), {
    conv = conv, quiet = true, display = "Review the change for " .. label,
    snap = { screen = "review (this agent reviews another agent's change before the user sees it)" },
    on_done = function(e)
      done(e)
      -- Its process isn't needed any more, nor its conversation.
      vim.schedule(function()
        pcall(require("azure-cli.chat.run").stop_persistent, conv)
        if CHAT().find_conversation(key) == conv then CHAT().drop_conversation(key) end
      end)
    end,
  })
  if not entry then CHAT().drop_conversation(key) end
  return entry ~= nil
end

M.IN_REVIEW_NOTE = "The change went to a reviewer agent first - the user isn't told about it yet. End your turn "
  .. "saying it's in review; the reviewer's findings come as your next message."

function M.on_show(target, dir, env, announce)
  if config().self_review ~= true then announce() return nil end
  local rec = PLAN().load(PLAN().key(target))
  if not (rec and rec.status == "approved" and rec.approved_rev) then announce() return nil end
  if M.running(rec.key) then return "The reviewer is still at it. " .. M.IN_REVIEW_NOTE, true end
  if rec.reviewed_rev == rec.approved_rev then announce() return nil end
  local conv = CHAT().find_conversation(rec.key) or (env and env.conv)
  if not (conv and conv.plan_key) then announce() return nil end
  rec.reviewed_rev = rec.approved_rev
  PLAN().add_event(rec, "review", "Sent to a reviewer")
  PLAN().save(rec)
  local function failed(why)
    announce()
    PLAN().event_for_worktree(dir, "review", "No review: " .. why)
    return "The review didn't happen (" .. why .. "): the change went to the user as it is."
  end
  local ok = start(rec, dir, function(e)
    -- Its plan discarded meanwhile: nobody to tell.
    if CHAT().find_conversation(conv.plan_key) ~= conv then return end
    if e.status ~= "done" then
      return deliver(conv, failed(tostring(e.status)) .. " Don't call show_fix again for it.",
        "The review didn't happen (" .. tostring(e.status) .. ").")
    end
    local text = vim.trim(e.text or "")
    if #text > M.FINDINGS_MAX then text = text:sub(1, M.FINDINGS_MAX) .. "\n... (cut off)" end
    PLAN().event_for_worktree(dir, "review", "Reviewed")
    deliver(conv, M.findings_message(text), "From the reviewer: " .. text)
  end)
  if not ok then return failed("the reviewer couldn't start"), false end
  return M.IN_REVIEW_NOTE, true
end

return M
