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
--   M.start_for_items(items)  queues { id, title, type, state } work items
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
  return "/plan Work item #" .. tostring(item.id) .. (item.title and (" \"" .. item.title .. "\"") or "")
    .. ": read it, look at the code it touches, then write the plan for it with submit_plan (work_item_id "
    .. tostring(item.id) .. "). You were started from the board, one agent per work item - this conversation is "
    .. "about this one only."
end

-- The view a board-started agent is told about: just its work item.
local function snap_for(item)
  return { screen = "work items dashboard (this agent was started for one work item)",
    work_item = { id = item.id, type = item.type, title = item.title, state = item.state } }
end

local function start(q)
  local item = q.item
  local conv = CHAT().conversation(q.key, { label = "#" .. tostring(item.id), title = item.title,
    target = { work_item_id = item.id } })
  if conv.running then return false end
  local entry = CHAT().send(M.plan_prompt(item), {
    conv = conv, snap = snap_for(item), display = "/plan #" .. tostring(item.id),
    done_note = "#" .. tostring(item.id) .. "'s agent answered (the Agents screen lists them).",
  })
  return entry ~= nil
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

-- Queues `items` (work items from the board; nil entries and ones already
-- queued or working are skipped), then starts as many as there's room for.
function M.start_for_items(items)
  if not CHAT().current_agent() then
    return notify("No chat agent is configured (docs/chat.md).", vim.log.levels.WARN)
  end
  local added, skipped = {}, {}
  for _, it in ipairs(items or {}) do
    if type(it) == "table" and it.id then
      local key = "wi-" .. tostring(it.id)
      local busy = false
      for _, q in ipairs(queue) do if q.key == key then busy = true end end
      local conv = CHAT().find_conversation(key)
      if conv and conv.running then busy = true end
      if busy then skipped[#skipped + 1] = "#" .. it.id else
        queue[#queue + 1] = { key = key, item = it }
        added[#added + 1] = "#" .. it.id
      end
    end
  end
  if #added == 0 then
    return notify(#skipped > 0 and ("Already working on " .. table.concat(skipped, ", ") .. ".")
      or "Put the cursor on a work item (or select some rows).")
  end
  M.pump()
  local waiting = #queue
  notify("Planning " .. table.concat(added, ", ") .. " - one agent each"
    .. (waiting > 0 and (", " .. waiting .. " waiting for an agent (chat.max_agents = " .. M.max() .. ")") or "")
    .. ". The Agents screen lists them.")
end

-- For tests: forget the queue.
function M.reset() queue = {} end

return M
