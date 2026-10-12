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
        .. "on the Agents screen. `instructions` (optional) goes to each of them with its first message.",
      schema = { type = "object", properties = {
        work_item_ids = { type = "array", items = { type = "integer" } },
        pr_id = { type = "integer" },
        thread_ids = { type = "array", items = { type = "integer" } },
        instructions = { type = "string" },
      } },
      risk = "write",
      run = function(args, env, done)
        local why = main_only(env)
        if why then return done(nil, why) end
        local said = {}
        local items = {}
        for _, id in ipairs(type(args.work_item_ids) == "table" and args.work_item_ids or {}) do
          local ref = require("azure-cli.chat.refs").resolve({ kind = "any", id = id })
          items[#items + 1] = (ref.kind == "wi" and ref.item) or { id = id }
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
          out[#out + 1] = { agent = r.label, target = r.target, title = r.title, state = r.state,
            latest = r.detail ~= "" and r.detail or nil, started_ago = r.ago ~= "" and r.ago or nil,
            plan_waits_for_user = r.waiting }
        end
        done(#out > 0 and out or "No agents yet - start_agents starts some.")
      end,
    },
    {
      name = "message_agent",
      description = "Passes a message on to the agent for work_item_id or pr_id - the user's instructions, or a "
        .. "question - shown in that agent's own chat as coming from the main chat. It answers there, not here; "
        .. "list_agents / get_plan show what came of it. Refused while that agent is busy.",
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
        if conv.running then return done(nil, "that agent is busy - try again once it's done (list_agents)") end
        -- What it was started on stays its "current view".
        local snap
        for _, e in ipairs(conv.entries) do if e.role == "you" and e.view then snap = e.view end end
        local entry = CHAT().send("(From the user, through the main chat) " .. args.message, {
          conv = conv, snap = snap, display = "From the main chat: " .. args.message,
          done_note = (conv.label or key) .. "'s agent answered (the Agents screen lists them).",
        })
        if not entry then return done(nil, "couldn't send it (is a chat agent configured?)") end
        done("Sent to " .. (conv.label or key) .. "'s agent; it answers in its own chat.")
      end,
    },
  }
end
