-- lua/azure-cli/chat/tools_agents.lua: the main chat as the agents'
-- coordinator - it starts them (one per work item or PR, as gP does),
-- sees what each is doing, and passes the user's instructions on. The
-- agents themselves don't get to use these: only the main chat starts or
-- messages agents. Approving a plan stays the user's (no tool for it).
--
--   start_agents   an agent per work item, or for a PR's review comments
--   list_agents    each agent: what it's on, what it's doing, its plan's state
--   message_agent  a message to one agent, shown in its own chat
--
-- Returns function(T) -> list of tools, T being chat/tools.lua.
return function(T)
  local function AGENTS() return require("azure-cli.chat.agents") end
  local function CHAT() return require("azure-cli.chat") end
  local function PLAN() return require("azure-cli.chat.plan") end

  -- nil, or why a plan's own agent can't use these.
  local function main_only(env)
    if env.conv and env.conv.plan_key then
      return "only the main chat starts or messages agents - you are one, working on " .. env.conv.plan_key
    end
  end

  local function target_of(args)
    if args.work_item_id then return { work_item_id = args.work_item_id } end
    if args.pr_id then return { pr_id = args.pr_id } end
  end

  -- Work item `id` for start_agents, with the board its agent reads it
  -- from: args.board when given, else the board a list showed it on (a
  -- "#n" refs.resolve finds), else T.board_for's default. An item another
  -- board's list has under the same id isn't taken for it.
  local function item_on_board(id, args, env)
    local ref = require("azure-cli.chat.refs").resolve({ kind = "any", id = id })
    local item, board = ref.kind == "wi" and ref.item or nil, ref.kind == "wi" and ref.board or nil
    if args.board == "azure" or args.board == "github" then
      if item and (board or "azure") ~= args.board then item = nil end
      board = args.board
    elseif not item then
      board = T.board_for(args, env).host
    end
    if not item then
      for _, it in ipairs((require("azure-cli.workitems.board").get(board).state.WI_LIST_CACHE or {}).items or {}) do
        if type(it) == "table" and tostring(it.id) == tostring(id) then item = it break end
      end
    end
    item = vim.tbl_extend("force", {}, item or { id = id })
    item.board = board == "github" and "github" or nil
    return item
  end

  local target_props = {
    work_item_id = { type = "integer", description = "the agent's work item" },
    pr_id = { type = "integer", description = "the agent's pull request" },
  }

  return {
    {
      name = "start_agents",
      description = "Starts an agent of its own for each work item in work_item_ids (it reads the item, writes a "
        .. "plan for the user to approve, then implements it), and/or one for pull request pr_id's review comments "
        .. "(thread_ids, default every active one). At most chat.max_agents work at once; the rest queue. They show "
        .. "on the Agents screen. `instructions` (optional) goes to each of them with its first message. `board` "
        .. "says which board the work items are on, and each agent reads its item from there; without it, the "
        .. "board a list showed the item on, else the board the user is looking at.",
      schema = { type = "object", properties = {
        work_item_ids = { type = "array", items = { type = "integer" } },
        pr_id = { type = "integer" },
        thread_ids = { type = "array", items = { type = "integer" } },
        instructions = { type = "string" },
        board = T.board_props.board,
      } },
      risk = "write",
      run = function(args, env, done)
        local why = main_only(env)
        if why then return done(nil, why) end
        local said = {}
        local items = {}
        for _, id in ipairs(type(args.work_item_ids) == "table" and args.work_item_ids or {}) do
          items[#items + 1] = item_on_board(id, args, env)
        end
        if #items > 0 then said[#said + 1] = (AGENTS().start_for_items(items, args.instructions)) end
        if args.pr_id then
          local pr = T.pr_record(args.pr_id)
          if not pr then return done(nil, "PR !" .. tostring(args.pr_id) .. " isn't loaded - call get_pull_request first") end
          local threads = type(args.thread_ids) == "table" and #args.thread_ids > 0 and args.thread_ids or nil
          said[#said + 1] = (AGENTS().start_for_prs({ pr }, { [pr.id] = threads }, args.instructions))
        end
        if #said == 0 then return done(nil, "give work_item_ids or pr_id") end
        done(table.concat(said, " "))
      end,
    },
    {
      name = "list_agents",
      description = "Every agent: the work item or PR it's on, what it's doing (working, queued, its plan waiting "
        .. "for the user, approved, pushed), its latest step, and how long ago it started.",
      schema = { type = "object", properties = vim.empty_dict() },
      risk = "read",
      run = function(_, _, done)
        local rows = require("azure-cli.chat.agents_view").rows(CHAT().conversations(), AGENTS().queued(),
          PLAN().load, os.time())
        local out = {}
        for _, r in ipairs(rows) do
          local conv = r.key and CHAT().find_conversation(r.key)
          local waiting = conv and #(conv.queue or {}) or 0
          out[#out + 1] = { agent = r.label, target = r.target, title = r.title, state = r.state,
            latest = r.detail ~= "" and r.detail or nil, started_ago = r.ago ~= "" and r.ago or nil,
            plan_waits_for_user = r.waiting, queued_messages = waiting > 0 and waiting or nil }
        end
        done(#out > 0 and out or "No agents yet - start_agents starts some.")
      end,
    },
    {
      name = "message_agent",
      description = "Passes a message on to the agent for work_item_id or pr_id - the user's instructions, or a "
        .. "question - shown in that agent's own chat as coming from the main chat. It answers there, not here; "
        .. "list_agents / get_plan show what came of it. While that agent is mid-turn the message is queued, and "
        .. "goes to it (in order, one turn each) when the turn ends.",
      schema = { type = "object", properties = {
        work_item_id = target_props.work_item_id, pr_id = target_props.pr_id,
        message = { type = "string" },
      }, required = { "message" } },
      risk = "write",
      run = function(args, env, done)
        local why = main_only(env)
        if why then return done(nil, why) end
        local target = target_of(args)
        if not target then return done(nil, "give work_item_id or pr_id") end
        if type(args.message) ~= "string" or vim.trim(args.message) == "" then return done(nil, "the message is empty") end
        local key = PLAN().key(target)
        local conv = CHAT().find_conversation(key)
        if not conv then return done(nil, "no agent for " .. key .. " - start_agents starts one") end
        -- What it was started on stays its "current view".
        local snap
        for _, e in ipairs(conv.entries) do if e.role == "you" and e.view then snap = e.view end end
        local who = conv.label or key
        local text = "(From the user, through the main chat) " .. args.message
        local opts = { conv = conv, snap = snap, display = "From the main chat: " .. args.message,
          done_note = who .. "'s agent answered (the Agents screen lists them)." }
        -- Mid-turn: it waits in the agent's queue (#29's, chat/run.lua) for
        -- the turn to end, behind anything queued before it. So does one
        -- arriving while the queue still has messages to go (a turn just
        -- ended, its drain not yet run), not to jump ahead of them.
        local pending = false
        for _, q in ipairs(conv.queue or {}) do if not q.held then pending = true end end
        if conv.running or pending then
          local RUN = require("azure-cli.chat.run")
          local n = RUN.queue(conv, text, opts)
          local mine = conv.queue[n]
          if not conv.running then RUN.drain(conv) end
          if not vim.tbl_contains(conv.queue or {}, mine) then
            return done("Sent to " .. who .. "'s agent; it answers in its own chat.")
          end
          n = 0
          for i, q in ipairs(conv.queue) do if q == mine then n = i end end
          local editing = false
          for i = 1, n - 1 do if conv.queue[i].editing then editing = true end end
          return done("Queued for " .. who .. "'s agent (" .. n .. " of " .. #conv.queue .. ") - "
            .. (conv.running and "it's mid-turn; the message is delivered when that turn ends, in order"
              or "it goes after the messages queued before it, in order")
            .. (editing and ", once the user finishes editing the queued message before it" or "")
            .. ". It answers in its own chat.")
        end
        local entry = CHAT().send(text, opts)
        if not entry then return done(nil, "couldn't send it (is a chat agent configured?)") end
        done("Sent to " .. who .. "'s agent; it answers in its own chat.")
      end,
    },
  }
end
