-- lua/azure-cli/chat/run.lua: talking to the agent, for chat/init.lua -
-- send (one turn: the message, the agent's process or ACP session kept
-- warm between turns, streaming its answer into the conversation), cancel,
-- and what they need: the MCP config pointing the agent at the bridge, the
-- working directory, stopping a process tree.
--
-- chat/init.lua's own state comes through its M._ (I() here): the
-- conversation, rendering, saving, confirming a tool call. Both ways round
-- the require happens at call time, never while either file loads.
local M = {}

local CORE = require("azure-cli.chat.core")
local function CHAT() return require("azure-cli.chat") end
local function I() return require("azure-cli.chat")._ end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function config() return require("azure-cli.config").get().chat or {} end
local function STATE() return I().state() end
local function render() return I().render() end
local function render_soon() return I().render_soon() end
local function save(st) return I().save(st) end
local function agent_label() return CHAT().agent_label() end
local function confirm_for(conv) return I().confirm_for(conv) end
local function tool_env(entry, conv) return I().tool_env(entry, conv) end
local function input_text() return I().input_text() end
local function restore_once() return I().restore_once() end

local send, cancel  -- forward

-- The MCP server definition every agent gets: one stdio server,
-- `azure-cli.py --mcp`, with the bridge's address and token in its
-- environment. write_mcp_config (most agents: a file, `env` as an
-- object) and acp_mcp_server (session/new's `mcpServers`: inline, `env`
-- as a list and a `name` field required there) both build on this.
local function mcp_server_def(addr, token, agent_id)
  local CONFIG = require("azure-cli.config")
  local argv = CONFIG.provider_cmd()
  local env = { AZVICLI_CHAT_BRIDGE = addr, AZVICLI_CHAT_TOKEN = token, AZVICLI_CHAT_AGENT = agent_id }
  for _, k in ipairs({ "AZVICLI_CONFIG", "AZVICLI_ACCOUNTS_JSON", "AZVICLI_FAKE_WS" }) do
    if vim.env[k] and vim.env[k] ~= "" then env[k] = vim.env[k] end
  end
  return { command = argv[1], args = vim.list_extend(vim.list_slice(argv, 2), { "--mcp" }), env = env }
end

local function acp_mcp_server(addr, token, agent_id)
  local def = mcp_server_def(addr, token, agent_id)
  local env = {}
  for k, v in pairs(def.env) do table.insert(env, { name = k, value = v }) end
  return { name = "azure-vicli", command = def.command, args = def.args, env = env }
end

-- One file per agent: a plan's own agent gets its id in the relay's
-- environment (chat-mcp-<id>.json), the main chat chat-mcp.json.
local function write_mcp_config(addr, token, agent_id)
  local path = vim.fn.stdpath("cache") .. "/azure-cli/chat-mcp" .. (agent_id and ("-" .. agent_id) or "") .. ".json"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local cfg = { mcpServers = { ["azure-vicli"] = mcp_server_def(addr, token, agent_id) } }
  vim.fn.writefile({ vim.json.encode(cfg) }, path)
  return path
end

-- Where the agent runs: the clone of the PR in view (so a repository's own
-- agent instructions and skills apply), else Neovim's cache directory.
local function agent_cwd(snap)
  local pr = snap and snap.pr
  local TOOLS = require("azure-cli.chat.tools")
  if type(pr) == "table" then
    local clone = TOOLS.clone_path(TOOLS.pr_record(pr.id) or pr)
    if clone ~= "" and vim.fn.isdirectory(clone) == 1 then return clone end
  end
  -- A work item (an agent started from the board for one): the clone of a
  -- PR linked to it, else any local clone - so the agent can read the code
  -- it plans for, not just search it through azure-vicli's tools.
  local wi = snap and type(snap.work_item) == "table" and snap.work_item.id
  if wi then
    local PW = require("azure-cli.pr_workitems")
    local first
    for _, p in ipairs((require("azure-cli.state").PR_LIST_CACHE or {}).prs or {}) do
      local clone = TOOLS.clone_path(p)
      if clone ~= "" and vim.fn.isdirectory(clone) == 1 then
        first = first or clone
        for _, w in ipairs(PW.cached(p.id) or {}) do
          if tostring(w.id) == tostring(wi) then return clone end
        end
      end
    end
    if first then return first end
  end
  local dir = vim.fn.stdpath("cache") .. "/azure-cli"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function where_label(snap)
  local bits = {}
  if type(snap.pr) == "table" then bits[#bits + 1] = "PR !" .. tostring(snap.pr.id) end
  if type(snap.work_item) == "table" then bits[#bits + 1] = "#" .. tostring(snap.work_item.id) end
  if snap.file then
    local range = snap.line and (":" .. snap.line) or ""
    if snap.selection_lines then range = ":" .. snap.selection_lines end
    bits[#bits + 1] = vim.fn.fnamemodify(snap.file, ":t") .. range
  elseif snap.selection then
    bits[#bits + 1] = "a selection"
  end
  if type(snap.thread) == "table" then bits[#bits + 1] = "thread " .. tostring(snap.thread.id) end
  if snap.plan_line then bits[#bits + 1] = "plan:" .. snap.plan_line
  elseif snap.plan then bits[#bits + 1] = "the plan" end
  if #bits > 0 then return "on " .. table.concat(bits, " \u{00B7} ") end
  if snap.screen and snap.screen ~= "other" and snap.screen ~= "unknown" then return "on the " .. snap.screen end
  return nil
end

local function bridge_handler(entry_ref, conv)
  return function(req, reply)
    local TOOLS = require("azure-cli.chat.tools")
    if req.method == "list" then return reply({ tools = TOOLS.describe() }) end
    if req.method == "call" then
      local entry = entry_ref() or { tools = {} }
      return TOOLS.call(req.name, req.arguments, tool_env(entry, conv), function(text, is_err)
        reply({ text = text, error = is_err or nil })
      end)
    end
    reply({ text = "unknown request", error = true })
  end
end

local function panel_visible()
  for _, w in pairs(STATE().wins) do if w.log and vim.api.nvim_win_is_valid(w.log) then return true end end
  return false
end

-- Every agent keeps one process alive across messages (see send/send_acp):
-- stopped whenever the conversation it belongs to goes away from under it (gM, gh,
-- a new chat) or Neovim exits. An ACP connection's `.finish` (set by
-- send_acp's `running`) finalizes whatever message is still in flight -
-- stopping the process on its own would otherwise leave that entry's
-- status "running" forever, with `st.running` never cleared.
-- Stops job `job` and everything it started: an agent CLI runs its MCP
-- relay (azure-cli.py --mcp) as a child that shares its stderr, and a
-- relay left behind keeps that pipe - and with it Neovim's exit - open.
-- The agent leads its own process group (jobstart's), so the group goes.
local function stop_tree(job)
  local okp, pid = pcall(vim.fn.jobpid, job)
  local uv = vim.uv or vim.loop
  if okp and pid and pid > 0 and vim.fn.has("win32") == 0 then pcall(uv.kill, -pid, "sigterm") end
  pcall(vim.fn.jobstop, job)
end
M.stop_tree = stop_tree

local function stop_persistent(st)
  local pj = st.persistent_job
  st.persistent_job = nil
  if not pj then return end
  if pj.finish then pcall(pj.finish, "stopped") end
  if pj.job then stop_tree(pj.job) end
  -- A plan's agent's own MCP config file (write_mcp_config) goes with it.
  if st.agent_id then pcall(os.remove, vim.fn.stdpath("cache") .. "/azure-cli/chat-mcp-" .. st.agent_id .. ".json") end
end

-- Whether `st.persistent_job` is a live process for `agent_name`'s current
-- conversation - reusable as-is for the next message. `stale` (gm picked
-- another model) means the next message starts a new one instead.
local function persistent_alive(st, agent_name)
  local pj = st.persistent_job
  if not (pj and not pj.stale and pj.agent_name == agent_name and pj.conv_id == st.conv_id) then return false end
  if vim.fn.jobwait({ pj.job }, 0)[1] ~= -1 then return false end
  return true
end

-- A jobstart on_stdout for the agent's process: `get_turn()` names the
-- message in progress on it. A turn ends when the stream reports a
-- result, without the process exiting.
local function turn_on_stdout(get_turn)
  return function(_, d)
    local turn = get_turn()
    if not turn or turn.done then return end
    if d and CORE.stream_feed(turn.reader, d, vim.json.decode) then
      vim.schedule(function()
        turn.absorb()
        if turn.reader.final ~= nil then turn.finish(nil, false) end
        render_soon()
      end)
    end
  end
end

local function turn_on_stderr(get_turn)
  return function(_, d) local turn = get_turn(); if turn and d then vim.list_extend(turn.err, d) end end
end

-- The process's on_exit: finishes the turn still open, if it died
-- mid-answer, and forgets the process so the next message starts a new one.
local function turn_on_exit(get_turn, forget)
  return function(_, code)
    vim.schedule(function()
      local turn = get_turn()
      if forget then forget() end
      if not turn or turn.done then return end
      CORE.stream_finish(turn.reader, vim.json.decode)
      turn.finish(code, turn.cancelled)
    end)
  end
end

-- The spinner turns every 120ms (only the winbars and statuslines are
-- redrawn); the whole transcript, for the seconds count, once a second.
-- Shared by send and send_acp below - both just need `st.running` set.
local function start_spinner(st)
  st.running.tick = 0
  CHAT().set_winbars()
  st.running.timer = vim.fn.timer_start(120, function()
    local run = st.running
    if not run then return end
    run.tick = run.tick + 1
    if run.tick % 8 == 0 then render() else CHAT().set_winbars() end
  end, { ["repeat"] = -1 })
end

-- agent.acp: a CLI with an Agent Client Protocol server mode (`copilot
-- --acp`) - JSON-RPC 2.0 over stdio, newline-delimited (chat/acp.lua).
-- One connection per conversation (handshake + session/new done once,
-- reused across messages - see `reuse`); a `session/prompt` per message,
-- its `session/update`s streamed into `entry` as they arrive, and a
-- `session/request_permission` shown with the same confirm() popup as
-- azure-vicli's own tools. Unlike the stream-json path, there's no
-- `stdin` templating: the prompt text goes in `session/prompt`
-- directly, and the model (if any) through `session/set_config_option`.
local function send_acp(st, agent, agent_name, entry, message, snap, vars, reuse, opts)
  local ACP = require("azure-cli.chat.acp")
  local done = false
  local function finish(status, extra_text)
    if done then return end
    done = true
    if st.running and st.running.entry == entry then
      if st.running.timer then pcall(vim.fn.timer_stop, st.running.timer) end
      st.running = nil
    end
    entry.status = status
    if extra_text and extra_text ~= "" then
      entry.text = (entry.text ~= "" and (entry.text .. "\n\n") or "") .. extra_text
    end
    if entry.text == "" then entry.text = "_(no answer)_" end
    render()
    save(st)
    if not panel_visible() then notify(opts.done_note or (agent_label() .. " answered in the chat (" .. require("azure-cli.keys").name("dashboard", "chat")
      .. " shows it).")) end
    if st.plan_key and STATE() ~= st then
      CHAT().alert("azure-vicli: " .. (st.label or "an agent") .. " answered", (entry.text or ""):gsub("%s+", " "):sub(1, 160))
    end
    if opts.on_done then pcall(opts.on_done, entry) end
    -- An agent is free again: start the next plan waiting for one.
    pcall(function() require("azure-cli.chat.agents").pump() end)
  end

  local function on_update(method, params)
    if method ~= "session/update" then return end
    local u = params.update or {}
    if u.sessionUpdate == "agent_message_chunk" then
      local t = type(u.content) == "table" and u.content.text
      if type(t) == "string" then entry.text = entry.text .. t; render_soon() end
    elseif u.sessionUpdate == "tool_call" then
      table.insert(entry.tools, "\u{00B7} " .. (u.title or u.name or "tool"))
      render_soon()
    elseif u.sessionUpdate == "tool_call_update" and u.status == "failed" then
      table.insert(entry.tools, "\u{2717} " .. (u.title or "tool failed"))
      render_soon()
    end
  end

  -- The agent asking permission before a tool call: shown with the same
  -- yes/no popup azure-vicli's own tools use, the tool call's diff (if
  -- any) as the details. "Allow" picks the first allow_* option offered,
  -- "Deny" the first reject_*; azure-vicli can't tell "once" from
  -- "always" apart in that popup, so it always answers "once".
  local function on_permission(method, params, id, conn)
    if method ~= "session/request_permission" then return conn.respond(id, nil, "unsupported request") end
    local options = params.options or {}
    local tool = params.toolCall or {}
    local details = {}
    local diff = type(tool.rawInput) == "table" and tool.rawInput.diff
    if type(diff) == "string" then for l in (diff .. "\n"):gmatch("(.-)\n") do table.insert(details, l) end end
    confirm_for(st.plan_key and st or nil)((tool.title or "The agent") .. " wants to " .. (tool.kind or "act"), function(yes)
      local pick
      for _, o in ipairs(options) do
        if yes and (o.kind == "allow_once" or o.kind == "allow_always") then pick = pick or o.optionId end
        if not yes and (o.kind == "reject_once" or o.kind == "reject_always") then pick = pick or o.optionId end
      end
      pick = pick or (options[1] and options[1].optionId)
      if pick then conn.respond(id, { outcome = { outcome = "selected", optionId = pick } })
      else conn.respond(id, { outcome = { outcome = "cancelled" } }) end
    end, details)
  end

  local function send_prompt(pj)
    pj.conn.request("session/prompt", { sessionId = pj.acp_session_id, prompt = { { type = "text", text = message } } },
      function(result, err)
        if err then return finish("failed", "```\n" .. tostring(err) .. "\n```") end
        local reason = result and result.stopReason
        if reason == "cancelled" then finish("stopped")
        elseif reason and reason ~= "end_turn" then finish("failed (" .. reason .. ")")
        else finish("done") end
      end)
  end

  local function running(pj)
    -- The connection's on_notification/on_request/on_exit (below) are set
    -- up once, when it's first started, and outlive every `send_acp` call
    -- that reuses it - so they read this message's handlers through `pj`
    -- rather than closing over this call's `entry`/`finish`/etc, which a
    -- later message would otherwise still be pointing at.
    pj.on_update, pj.on_permission, pj.finish = on_update, on_permission, finish
    st.running = { acp = true, entry = entry, job = pj.job,
      cancel = function()
        pcall(pj.conn.notify, "session/cancel", { sessionId = pj.acp_session_id })
        vim.defer_fn(function()
          if st.running and st.running.entry == entry and not done then pcall(vim.fn.jobstop, pj.job) end
        end, 5000)
      end }
    start_spinner(st)
    local timeout = tonumber(agent.timeout_seconds) or 900
    vim.defer_fn(function()
      if st.running and st.running.entry == entry and not done then
        table.insert(entry.tools, "\u{2717} timed out after " .. timeout .. "s")
        st.running.cancel()
      end
    end, timeout * 1000)
  end

  if reuse then
    local pj = st.persistent_job
    running(pj)
    send_prompt(pj)
    return
  end

  local cmd = {}
  for i, a in ipairs(agent.cmd) do cmd[i] = CORE.expand(a, vars) end
  local exe = vim.fn.exepath(cmd[1])
  if exe == "" then entry.status, entry.text = "failed", "`" .. cmd[1] .. "` isn't on PATH."; return render() end
  cmd[1] = exe
  local env = {}
  for k, v in pairs(agent.env or {}) do env[k] = CORE.expand(tostring(v), vars) end

  local pj = { acp = true, agent_name = agent_name, conv_id = st.conv_id }
  local function live() return st.persistent_job == pj end
  local conn, cerr = ACP.connect(cmd, { cwd = agent_cwd(snap), env = next(env) and env or nil }, {
    on_notification = function(method, params) if live() and pj.on_update then pj.on_update(method, params) end end,
    on_request = function(method, params, id)
      if not live() then return end
      if pj.on_permission then pj.on_permission(method, params, id, pj.conn) else pj.conn.respond(id, nil, "no handler") end
    end,
    on_exit = function(code)
      local was_live = live()
      if was_live then st.persistent_job = nil end
      if was_live and pj.finish then pj.finish(code == 0 and "stopped" or ("failed (exit " .. code .. ")")) end
    end,
  })
  if not conn then
    entry.status, entry.text = "failed", tostring(cerr)
    return render()
  end
  pj.conn, pj.job = conn, conn.job
  st.persistent_job = pj
  running(pj)

  conn.request("initialize", { protocolVersion = 1, clientCapabilities = vim.empty_dict(),
    clientInfo = { name = "azure-vicli", version = "1" } }, function(init, ierr)
    if not live() then return end
    if ierr then return finish("failed", tostring(ierr)) end
    -- An agent that only takes http MCP servers (Copilot's --acp: no stdio
    -- in its mcpCapabilities) gets azure-cli.py --mcp-http instead.
    local caps = type(init) == "table" and type(init.agentCapabilities) == "table"
      and init.agentCapabilities.mcpCapabilities
    local function with_servers(next_step)
      if not vars.mcp_server then return next_step({}) end
      if not (type(caps) == "table" and caps.http) then return next_step({ vars.mcp_server }) end
      ACP.http_server(vars.mcp_server, function(server, herr)
        if not live() then return end
        if not server then
          table.insert(entry.tools, "\u{2717} azure-vicli's tools: " .. tostring(herr))
          return next_step({})
        end
        next_step({ server })
      end)
    end
    with_servers(function(servers)
      conn.request("session/new", { cwd = agent_cwd(snap), mcpServers = servers }, function(result, serr)
        if not live() then return end
        if serr or not (result and result.sessionId) then
          return finish("failed", tostring(serr or "the agent didn't return a session id"))
        end
        pj.acp_session_id = result.sessionId
        local model = CHAT().current_model(agent)
        if model then
          pcall(conn.request, "session/set_config_option",
            { sessionId = pj.acp_session_id, configId = "model", value = model }, function() end)
        end
        send_prompt(pj)
      end)
    end)
  end)
end

-- Sends `text` (default: the input box). opts.view_win overrides which
-- window "current view" describes; opts.display is what the conversation
-- shows as your message (default: `text`); opts.on_done(entry) runs once
-- the answer is complete, and opts.done_note replaces the "answered in the
-- chat" note shown while the panel is hidden. Returns the answer's entry
-- (its status "running" while the agent works), or nil when nothing was
-- sent - the agent busy, or none configured.
send = function(text, opts)
  opts = opts or {}
  restore_once()
  -- The conversation this message belongs to, for good: a reply arriving
  -- after the panel moved on to another plan still lands here.
  local st = opts.conv or STATE()
  local from_input = text == nil
  if from_input then text = input_text() end
  if text == "" then return end
  if vim.v.exiting ~= vim.NIL then return end  -- quitting: no new agent process
  if st.running then
    notify("The agent is still answering - wait, or stop it (<C-c>).", vim.log.levels.WARN)
    return
  end
  local agent_name, agent = CHAT().current_agent()
  if not agent then
    table.insert(st.entries, { role = "note", text = "No chat agent is configured - add setup({ chat = { agent = { ... } } }); docs/chat.md has examples." })
    render()
    return
  end
  local BRIDGE = require("azure-cli.chat.bridge")
  local addr, token = BRIDGE.ensure()
  if not addr then
    notify(token or "could not start the chat bridge", vim.log.levels.ERROR)
    return
  end
  if from_input and I().input_buf() and vim.api.nvim_buf_is_valid(I().input_buf()) then
    vim.api.nvim_buf_set_lines(I().input_buf(), 0, -1, false, { "" })
  end
  table.insert(st.sent, text)
  while #st.sent > 100 do table.remove(st.sent, 1) end
  st.sent_pos = nil

  local shown_text = opts.display or text
  local expanded = CORE.expand_prompt(text, CORE.prompts(config().prompts))

  local VIEW = require("azure-cli.chat.view")
  local view_win = opts.view_win or CHAT().main_win()
  local sel = st.selection
  if sel and not (vim.api.nvim_win_is_valid(sel.win) and sel.win == view_win) then sel = nil end
  st.selection = nil
  local snap = opts.snap or VIEW.snapshot(view_win, sel)
  local view_text = VIEW.text(snap)
  local history = {}
  for _, e in ipairs(st.entries) do if e.role ~= "note" then history[#history + 1] = e end end
  local first = #history == 0
  -- A conversation's id is otherwise only assigned lazily, the first time
  -- it's saved (after this message answers) - too late for the process
  -- started now to compare against on the next message, so it's fixed
  -- here instead, before anything reads it.
  if first then st.conv_id = st.conv_id or require("azure-cli.chat.store").new_id() end
  -- The agent's process from an earlier message of this conversation takes
  -- this one too; otherwise a new one starts, and - unless this is the
  -- first message - gets the conversation so far replayed to it.
  local reuse = persistent_alive(st, agent_name)
  if st.persistent_job and not reuse then stop_persistent(st) end
  local replay = not first and not reuse
  table.insert(st.entries, { role = "you", text = shown_text, where = where_label(snap), view = snap })
  local entry = { role = "agent", status = "running", started = os.time(), tools = {}, view_win = view_win, snap = snap,
    label = agent.label or agent_name, mode = replay and "replay" or nil, text = "" }
  table.insert(st.entries, entry)
  if st.agent_id then
    -- A plan's own agent: its tool calls come with its id (the relay's
    -- AZVICLI_CHAT_AGENT / X-Azvicli-Agent) and land in this conversation.
    st.bridge_entry = entry
    BRIDGE.route(st.agent_id, bridge_handler(function() return st.bridge_entry end, st))
  else
    BRIDGE.handler = bridge_handler(function() return entry end)
  end
  render()

  local message = CORE.compose(expanded, view_text, {
    first = first, history = replay and history or nil,
    refs = require("azure-cli.chat.refs").describe(expanded),
  })
  local vars = {
    message = message, message_json = vim.json.encode(message), text = expanded,
    model = CHAT().current_model(agent) or "",
    mcp_config = write_mcp_config(addr, token, st.agent_id),
    mcp_server = agent.acp and acp_mcp_server(addr, token, st.agent_id) or nil,
    view = view_text,
    fix_root = require("azure-cli.chat.tools_fix").root(),
  }
  vim.fn.mkdir(vars.fix_root, "p")

  if agent.acp then
    send_acp(st, agent, agent_name, entry, message, snap, vars, reuse, opts)
    return entry
  end

  local reader = CORE.stream_new(agent.strip)
  local seen_tools, err = 0, {}
  local function absorb()
    entry.text = CORE.stream_text(reader)
    for i = seen_tools + 1, #reader.tools do table.insert(entry.tools, "\u{00B7} " .. reader.tools[i]) end
    seen_tools = #reader.tools
  end
  local turn = { entry = entry, reader = reader, err = err, absorb = absorb, cancelled = false, done = false }
  function turn.finish(code, cancelled)
    if turn.done then return end
    turn.done = true
    absorb()
    if reader.session then st.session_id = reader.session end
    -- This answer's cost: the growth of its process's running total (a new
    -- process - a restart, a replay - starts again from 0).
    if reader.cost_total and turn.pj then
      entry.cost = math.max(0, reader.cost_total - (turn.pj.cost_seen or 0))
      turn.pj.cost_seen = reader.cost_total
    end
    entry.tokens = reader.tokens
    if reader.is_error and entry.text == "" then entry.text = "(the agent reported an error)" end
    if cancelled then
      entry.status = "stopped"
    elseif code and code ~= 0 then
      entry.status = "failed (exit " .. code .. ")"
      local tail = vim.tbl_filter(function(l) return l ~= "" end, err)
      if #tail > 0 then
        entry.text = (entry.text ~= "" and (entry.text .. "\n\n") or "") .. "```\n"
          .. table.concat(vim.list_slice(tail, math.max(1, #tail - 15)), "\n") .. "\n```"
      end
    elseif code then
      -- The process exited cleanly, but in the middle of a turn: a CLI
      -- that answers one message and quits isn't one that can stay running.
      entry.status = "failed (the agent exited)"
      if entry.text == "" then
        entry.text = "The agent exited after one message - its `cmd` has to keep it running and reading "
          .. "one request per line on stdin (Claude Code: `--input-format stream-json --output-format stream-json`), "
          .. "or set `acp = true` for a CLI with an ACP mode (`copilot --acp`)."
      end
    else
      entry.status = "done"
      if entry.text == "" then entry.text = "_(no answer)_" end
    end
    if st.running and st.running.turn == turn then
      if st.running.timer then pcall(vim.fn.timer_stop, st.running.timer) end
      st.running = nil
    end
    render()
    save(st)
    if not panel_visible() then notify(opts.done_note or (agent_label() .. " answered in the chat (" .. require("azure-cli.keys").name("dashboard", "chat")
      .. " shows it).")) end
    if st.plan_key and STATE() ~= st then
      CHAT().alert("azure-vicli: " .. (st.label or "an agent") .. " answered", (entry.text or ""):gsub("%s+", " "):sub(1, 160))
    end
    if opts.on_done then pcall(opts.on_done, entry) end
    -- An agent is free again: start the next plan waiting for one.
    pcall(function() require("azure-cli.chat.agents").pump() end)
  end

  local stdin_text = CORE.expand(agent.stdin or CORE.STREAM_JSON_STDIN, vars) .. "\n"
  local job
  if reuse then
    job = st.persistent_job.job
    st.persistent_job.turn = turn
  else
    local cmd
    if type(agent.cmd) == "table" then
      cmd = {}
      for i, a in ipairs(agent.cmd) do cmd[i] = CORE.expand(a, vars) end
      local exe = vim.fn.exepath(cmd[1])
      if exe == "" then
        entry.status, entry.text = "failed", "`" .. cmd[1] .. "` isn't on PATH."
        return render()
      end
      cmd[1] = exe
    else
      cmd = CORE.expand(agent.cmd, vars, vim.fn.shellescape)
    end
    local env = { AZVICLI_CHAT_BRIDGE = addr, AZVICLI_CHAT_TOKEN = token, AZVICLI_CHAT_AGENT = st.agent_id }
    for k, v in pairs(agent.env or {}) do env[k] = CORE.expand(tostring(v), vars) end
    -- The process's callbacks outlive this `send` call (the next message
    -- reuses it), so they read the turn in progress through its own `pj` -
    -- not through `st.persistent_job`, which stop_persistent clears before
    -- the process's on_exit runs, and that turn would then never finish.
    local pj = { agent_name = agent_name, conv_id = st.conv_id, turn = turn }
    local function get_turn() return pj.turn end
    local ok
    ok, job = pcall(vim.fn.jobstart, cmd, {
      cwd = agent_cwd(snap), env = env, stderr_buffered = false,
      on_stdout = turn_on_stdout(get_turn), on_stderr = turn_on_stderr(get_turn),
      on_exit = turn_on_exit(get_turn, function() if st.persistent_job == pj then st.persistent_job = nil end end),
    })
    if not ok or job <= 0 then
      entry.status, entry.text = "failed", "could not start the agent: " .. tostring(job)
      return render()
    end
    pj.job = job
    st.persistent_job = pj
  end
  pcall(vim.fn.chansend, job, stdin_text)

  turn.pj = st.persistent_job
  st.running = { job = job, turn = turn, entry = entry }
  start_spinner(st)
  local timeout = tonumber(agent.timeout_seconds) or 900
  vim.defer_fn(function()
    if st.running and st.running.turn == turn then
      turn.cancelled = true
      table.insert(entry.tools, "\u{2717} timed out after " .. timeout .. "s")
      pcall(vim.fn.jobstop, job)
    end
  end, timeout * 1000)
  return entry
end
M.send = send

cancel = function(st)
  st = st or STATE()
  if not st.running then return notify("The agent isn't running.") end
  if st.running.acp then return st.running.cancel() end
  if st.running.turn then st.running.turn.cancelled = true end
  pcall(vim.fn.jobstop, st.running.job)
end

-- Stops what conversation `c`'s agent is doing (the Agents screen's <C-c>).
function M.cancel_conversation(c) cancel(c) end

M.cancel = cancel
M.stop_persistent = stop_persistent

return M
