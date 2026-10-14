-- lua/azure-cli/chat/agents.lua: several agents at once - one per plan.
--
-- gP on the work-items board (on one item, or on a visual selection of
-- rows) hands each work item to an agent of its own: a conversation of
-- its own (chat/init.lua's CHAT.conversation, keyed by the item's plan
-- key) that starts with /plan, so each writes its plan while you carry on.
-- At most chat.max_agents (default 3) work at once; the rest wait here and
-- start as others finish. Once a plan is in, you review it as usual - its
-- tab's chat is that agent's conversation, so approving it there sets that
-- agent going.
--
--   M.start_for_items(items, extra)  queues { id, title, type, state } work
--                             items; `extra` = what the user added, passed on
--   M.start_for_prs(prs, threads_of, extra)  queues PRs: each agent plans
--                             fixes for the given thread ids (default: every
--                             active one); a PR an agent opened for a work
--                             item (plan.owner_of_pr) goes back to that
--                             agent, as a new revision of its plan
--     (both return what they did, as a sentence, and the labels started)
--   M.start_for(text, snap)   the main chat's /plan: the work items and PRs
--                             `text` names, else the one in view `snap`
--   M.pump()                  starts queued ones while there's room
--                             (chat/init.lua calls it after every answer)
--   M.queued()                the waiting ones, in order
--   M.max()                   chat.max_agents
--   M.plan_prompt(item)       the first message (pure)
local M = {}

local queue = {}  -- { { key, item } } in order

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function CHAT() return require("azure-cli.chat") end

function M.max()
  local n = tonumber((require("azure-cli.config").get().chat or {}).max_agents)
  return (n and n >= 1) and math.floor(n) or 3
end

function M.queued()
  local out = {}
  for _, q in ipairs(queue) do out[#out + 1] = q end
  return out
end

-- How many conversations have a message in flight.
function M.working()
  local n = 0
  for _, c in ipairs(CHAT().conversations()) do if c.running then n = n + 1 end end
  return n
end

function M.plan_prompt(item)
  if item.board == "github" then
    return "/plan GitHub issue #" .. tostring(item.id) .. (item.repo and (" in " .. item.repo) or "")
      .. (item.title and (" \"" .. item.title .. "\"") or "")
      .. ": read it (get_work_item with board = \"github\"), look at the code it touches, then write the plan for it "
      .. "with submit_plan (work_item_id " .. tostring(item.id) .. "). Pass board = \"github\" to every work-item "
      .. "tool for it. You were started from the Issues board, one agent per issue - this conversation is about "
      .. "this one only."
  end
  return "/plan Work item #" .. tostring(item.id) .. (item.title and (" \"" .. item.title .. "\"") or "")
    .. ": read it, look at the code it touches, then write the plan for it with submit_plan (work_item_id "
    .. tostring(item.id) .. "). You were started from the board, one agent per work item - this conversation is "
    .. "about this one only."
end

-- The view a board-started agent is told about: just its work item (and
-- on GitHub its board, which the board tools then default to).
local function snap_for(item)
  if item.board == "github" then
    return { screen = "issues dashboard (this agent was started for one issue)", board = "github",
      work_item = { id = item.id, type = item.type, title = item.title, state = item.state, board = "github",
        repo = item.repo, key = item.key } }
  end
  return { screen = "work items dashboard (this agent was started for one work item)",
    work_item = { id = item.id, type = item.type, title = item.title, state = item.state } }
end

-- A queued job: { key, label, title, target, prompt, display, snap }.
local function start(q)
  local conv = CHAT().conversation(q.key, { label = q.label, title = q.title, target = q.target })
  if conv.running then return false end
  local entry = CHAT().send(q.prompt, {
    conv = conv, snap = q.snap, display = q.display,
    done_note = q.label .. "'s agent answered (the Agents screen lists them).",
  })
  return entry ~= nil
end

-- What the user added to a /plan, passed on to each agent it starts.
local function with_extra(prompt, extra)
  extra = extra and vim.trim(extra) or ""
  return extra ~= "" and (prompt .. "\n\nThe user adds: " .. extra) or prompt
end

local function job_for_item(it, extra)
  return { key = "wi-" .. tostring(it.id), label = "#" .. tostring(it.id), title = it.title,
    target = { work_item_id = it.id }, prompt = with_extra(M.plan_prompt(it), extra), display = "/plan #" .. tostring(it.id),
    snap = snap_for(it) }
end

-- The first message of an agent started for a PR's review comments:
-- `threads` = the thread ids to fix (nil: every active one). Pure.
function M.pr_prompt(pr, threads)
  local which = (threads and #threads > 0)
    and ("the review comment" .. (#threads == 1 and "" or "s") .. " in thread" .. (#threads == 1 and " " or "s ")
      .. table.concat(vim.tbl_map(tostring, threads), ", "))
    or "its open review comments (every active thread)"
  return "/plan PR !" .. tostring(pr.id) .. (pr.title and (" \"" .. pr.title .. "\"") or "") .. ": plan how to fix "
    .. which .. ". Read them with get_pr_threads and look at the code they're on, then write one plan for the fix "
    .. "with submit_plan (pr_id " .. tostring(pr.id) .. "). You were started for this PR only."
end

-- The same, for the agent whose plan for work item `wi` opened the PR:
-- it plans the fix as a new revision of that plan and pushes to its own
-- branch. Pure.
function M.pr_followup_prompt(pr, threads, wi)
  local which = (threads and #threads > 0)
    and ("the review comment" .. (#threads == 1 and "" or "s") .. " in thread" .. (#threads == 1 and " " or "s ")
      .. table.concat(vim.tbl_map(tostring, threads), ", "))
    or "its open review comments (every active thread)"
  return "/plan Reviewers commented on PR !" .. tostring(pr.id) .. (pr.title and (" \"" .. pr.title .. "\"") or "")
    .. ", which you opened for #" .. tostring(wi) .. ". Plan how to fix " .. which .. ": read them with "
    .. "get_pr_threads (pr_id " .. tostring(pr.id) .. ") and look at the code they're on, then write the plan for "
    .. "this round with submit_plan (work_item_id " .. tostring(wi) .. ") - a new revision of your plan. Once it's "
    .. "approved, make the change in your story's worktree (start_story for #" .. tostring(wi) .. " reuses it) and "
    .. "push it with commit_and_push_fix (work_item_id " .. tostring(wi) .. "): the PR picks it up."
end

local function job_for_pr(pr, threads, extra)
  -- A PR one of the agents opened goes back to that agent, with its plan
  -- and its conversation.
  local owner = require("azure-cli.chat.plan").owner_of_pr(pr.id, pr.source)
  local wi = owner and owner.target and owner.target.work_item_id
  if wi then
    return { key = owner.key, label = "#" .. tostring(wi), title = owner.title or pr.title, target = owner.target,
      prompt = with_extra(M.pr_followup_prompt(pr, threads, wi), extra),
      display = "/plan PR !" .. tostring(pr.id) .. "'s comments" .. ((threads and #threads > 0) and (" (thread "
        .. table.concat(vim.tbl_map(tostring, threads), ", ") .. ")") or ""),
      snap = { screen = "pull request (the PR this agent opened for #" .. tostring(wi) .. " got review comments)",
        pr = pr } }
  end
  return { key = "pr-" .. tostring(pr.id), label = "PR !" .. tostring(pr.id), title = pr.title,
    target = { pr_id = pr.id }, prompt = with_extra(M.pr_prompt(pr, threads), extra),
    display = "/plan PR !" .. tostring(pr.id) .. ((threads and #threads > 0) and (" (thread "
      .. table.concat(vim.tbl_map(tostring, threads), ", ") .. ")") or ""),
    snap = { screen = "pull request (this agent was started for one PR's review comments)", pr = pr } }
end

-- Neovim is quitting: start nothing more (stopping an agent finishes its
-- answer, which would otherwise start the next queued one mid-exit - a
-- process Neovim then waits for).
local function exiting() return vim.v.exiting ~= vim.NIL end

function M.pump()
  if exiting() then queue = {} return end
  while #queue > 0 and M.working() < M.max() do
    local q = table.remove(queue, 1)
    start(q)
  end
end

-- Queues `jobs` (ones already queued or working are skipped), then starts
-- as many as there's room for. Says what it did (a toast), and returns it:
-- the sentence, and the labels it started or queued.
local function enqueue(jobs, nothing)
  local function say(msg, level)
    notify(msg, level)
    return msg, {}
  end
  if not CHAT().current_agent() then
    return say("No chat agent is configured (docs/chat.md).", vim.log.levels.WARN)
  end
  local added, skipped = {}, {}
  for _, job in ipairs(jobs) do
    local busy = false
    for _, q in ipairs(queue) do if q.key == job.key then busy = true end end
    local conv = CHAT().find_conversation(job.key)
    if conv and conv.running then busy = true end
    if busy then skipped[#skipped + 1] = job.label else
      queue[#queue + 1] = job
      added[#added + 1] = job.label
    end
  end
  if #added == 0 then
    return say(#skipped > 0 and ("Already working on " .. table.concat(skipped, ", ") .. ".") or nothing)
  end
  M.pump()
  local waiting = #queue
  local msg = "Planning " .. table.concat(added, ", ") .. " - one agent each"
    .. (waiting > 0 and (", " .. waiting .. " waiting for an agent (chat.max_agents = " .. M.max() .. ")") or "")
    .. (#skipped > 0 and ("; already working on " .. table.concat(skipped, ", ")) or "")
    .. ". The Agents screen lists them."
  notify(msg)
  return msg, added
end

-- Queues `items` (work items from the board; nil entries skipped);
-- `board` "github" when they're the Issues board's.
function M.start_for_items(items, extra, board)
  local jobs = {}
  for _, it in ipairs(items or {}) do
    if type(it) == "table" and it.id then
      if board then it = vim.tbl_extend("force", it, { board = board }) end
      jobs[#jobs + 1] = job_for_item(it, extra)
    end
  end
  return enqueue(jobs, "Put the cursor on a work item (or select some rows).")
end

-- Queues PRs `prs` (dashboard rows, or the one in the reviewer), each
-- planning fixes for `threads_of[pr.id]` (thread ids) or its active threads.
function M.start_for_prs(prs, threads_of, extra)
  local jobs = {}
  for _, pr in ipairs(prs or {}) do
    if type(pr) == "table" and pr.id then jobs[#jobs + 1] = job_for_pr(pr, (threads_of or {})[pr.id], extra) end
  end
  return enqueue(jobs, "Put the cursor on a pull request (or select some rows).")
end

-- The main chat's /plan (chat/run.lua): an agent for each work item and PR
-- `text` names (#3001, !101), else for the work item or PR in view `snap`
-- (on a review thread: that thread). The rest of `text` goes to each agent.
-- Returns what it did, as a sentence.
function M.start_for(text, snap)
  local REFS = require("azure-cli.chat.refs")
  local items, prs = {}, {}
  local extra = text
  for _, ref in ipairs(require("azure-cli.chat.core").find_refs(text or "")) do
    local r = REFS.resolve(ref)
    if r.kind == "pr" then
      prs[#prs + 1] = r.pr or require("azure-cli.chat.tools").pr_record(r.id) or { id = r.id }
    else
      items[#items + 1] = vim.tbl_extend("force", r.item or { id = r.id }, { board = r.board })
    end
  end
  local threads_of = {}
  snap = snap or {}
  if #items == 0 and #prs == 0 then
    if type(snap.work_item) == "table" and snap.work_item.id then
      items[1] = snap.work_item
    elseif type(snap.pr) == "table" and snap.pr.id then
      prs[1] = require("azure-cli.chat.tools").pr_record(snap.pr.id) or snap.pr
      if type(snap.thread) == "table" and snap.thread.id then threads_of[snap.pr.id] = { snap.thread.id } end
    else
      return "/plan starts an agent for the work item or pull request on screen, or the ones you name "
        .. "(/plan #3001 !101) - there's none here."
    end
  end
  local said = {}
  if #items > 0 then said[#said + 1] = (M.start_for_items(items, extra)) end
  if #prs > 0 then said[#said + 1] = (M.start_for_prs(prs, threads_of, extra)) end
  return table.concat(said, " ")
end

-- For tests: forget the queue.
function M.reset() queue = {} end

return M
