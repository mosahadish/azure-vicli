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
local WD = require("azure-cli.chat.watchdog")
local function now() return (vim.uv or vim.loop).now() / 1000 end
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
local interrupt_seq = 0  -- control_request ids (send's turn.stop)

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

-- `confirm` (a tool_env's, a confirm_for's) that counts the popup's wait
-- as time asking you on turn watchdog `w` (nil: none).
local function asking_confirm(confirm, w)
  if not w then return confirm end
  return function(question, cb, ...)
    WD.asking(w, 1, now())
    return confirm(question, function(...) WD.asking(w, -1, now()); return cb(...) end, ...)
  end
end

-- Whether an agent may use one of its own tools (a shell command, a file
-- edit, ...): the rules every agent's requests go through, whatever its
-- protocol - ACP's session/request_permission (send_acp) and Claude Code's
-- --permission-prompt-tool (the bridge's "permission" call, below). `st`
-- is the conversation (nil: the main chat), `entry` the message being
-- answered, `tool` an ACP tool call ({ kind, title, rawInput, locations });
-- answer(yes) runs once it's decided - at once, or after the popup;
-- `w`, the turn's watchdog, counts the popup's wait as asking you.
--
local function decide_permission(st, entry, tool, answer, w)
  local function confirm_for(conv) return asking_confirm(I().confirm_for(conv), w) end
  st = st or {}
  local raw = type(tool.rawInput) == "table" and tool.rawInput or {}
  local cmd = raw.command or raw.cmd
  if type(cmd) == "table" then cmd = table.concat(vim.tbl_map(tostring, cmd), " ") end
  cmd = type(cmd) == "string" and vim.trim(cmd) or nil
  -- What a shell command was and what became of it, under the tool call
  -- in the chat (and so in the run log, gH).
  local function log_cmd(outcome, always)
    local one = cmd and cmd ~= "" and cmd:gsub("%s*\n%s*", " ; ") or nil
    if not one and always then
      local paths = CORE.tool_paths(tool)
      one = (tool.title or tool.kind or "tool") .. (#paths > 0 and (" " .. table.concat(paths, ", ")) or "")
    end
    if not one then return end
    table.insert(entry.tools, "  \u{21B3} " .. (cmd and cmd ~= "" and "$ " or "") .. (#one > 160 and (one:sub(1, 157) .. "...") or one)
      .. "  (" .. outcome .. ")")
    render_soon()
  end
  local function allow_quietly(why) log_cmd("allowed: " .. why); return answer(true) end
  if CORE.READ_ONLY_KINDS[tool.kind] then return answer(true) end
  if CORE.FILE_CHANGE_KINDS[tool.kind] then
    if entry.planning then
      table.insert(entry.tools, "\u{2717} " .. (tool.title or tool.kind) .. " (refused: planning changes no files)")
      render_soon()
      return answer(false)
    end
  end
  -- chat.permissions' "agent-commands" / "agent-edits" / "all": allowed
  -- or refused without asking.
  local said = require("azure-cli.chat.tools").agent_permission(tool.kind)
  if said == "allow" then log_cmd("allowed: chat.permissions", true); return answer(true) end
  if said == "deny" then log_cmd("refused: chat.permissions", true); return answer(false) end
  -- The popup shows what it would run (or the agent's whole input, when
  -- it isn't a command or a diff): the title is the agent's own words.
  -- All of it - the popup wraps it - and `full` as it is, for its o.
  local details, full = {}, nil
  local diff = raw.diff
  if type(diff) == "string" then
    for l in (diff .. "\n"):gmatch("(.-)\n") do table.insert(details, l) end
  elseif cmd and cmd ~= "" then
    table.insert(details, "Command:")
    full = {}
    for l in (cmd .. "\n"):gmatch("(.-)\n") do table.insert(details, "  " .. l) table.insert(full, l) end
  elseif next(raw) and not CORE.FILE_CHANGE_KINDS[tool.kind] then
    local ok, json = pcall(vim.json.encode, raw)
    if ok then
      details = { "Input:", "  " .. json }
      full = { json }
    end
  end
  local PLAN = require("azure-cli.chat.plan")
  local verdict, rec, rels = nil, nil, nil
  if CORE.FILE_CHANGE_KINDS[tool.kind] then verdict, rec, rels = PLAN.edit_check(CORE.tool_paths(tool)) end
  if verdict == "planned" then return answer(true) end
  -- Building and testing the way the approved plan's Test plan says.
  if tool.kind == "execute" and st.plan_key and PLAN.test_command_allowed(st.plan_key, raw.command or raw.cmd) then
    return allow_quietly("the plan's tests")
  end
  -- Searching and listing through the shell (grep, git log, ...).
  if tool.kind == "execute" and CORE.look_only_command(raw.command or raw.cmd) then return allow_quietly("only looks") end
  -- A skill you've allowed: whatever it does through the agent's tools.
  local SKILLS = require("azure-cli.chat.skills")
  if entry.skill and SKILLS.allowed(entry.skill) then
    log_cmd("allowed: skill " .. entry.skill, true)
    return answer(true)
  end
  -- Otherwise a third button allows that skill from now on.
  local extra = entry.skill and ("Allow all of skill " .. entry.skill) or nil
  local function remember(always) if always and entry.skill then SKILLS.allow(entry.skill) end end
  if verdict == "unplanned" then
    local question = "The agent wants to " .. tool.kind .. " " .. table.concat(rels, ", ") .. ", which the plan for "
      .. PLAN.target_label(rec.target) .. " doesn't include. Why: " .. CORE.last_reason(entry.text)
    return confirm_for(st.plan_key and st or nil)(question, function(yes, always)
      if yes then PLAN.allow_files(rec, rels) end
      remember(always)
      answer(yes)
    end, details, extra, full)
  end
  confirm_for(st.plan_key and st or nil)((tool.title or "The agent") .. " wants to " .. (tool.kind or "act")
    .. (entry.skill and (" (skill " .. entry.skill .. ")") or ""), function(yes, always)
    remember(always)
    log_cmd(always and ("you allowed skill " .. entry.skill) or (yes and "you allowed it" or "you denied it"))
    answer(yes)
  end, details, extra, full)
end
M.decide_permission = decide_permission

-- Claude Code's tools by the ACP kind decide_permission reads.
local CLAUDE_KINDS = {
  Bash = "execute", Edit = "edit", MultiEdit = "edit", Write = "edit", NotebookEdit = "edit",
  Read = "read", NotebookRead = "read", LS = "read", Glob = "search", Grep = "search",
  WebFetch = "fetch", WebSearch = "fetch",
}

-- A Claude Code permission request ({ tool_name, input }, what its
-- --permission-prompt-tool is called with) as the ACP tool call
-- decide_permission takes: the kind its tool name means, the input as
-- rawInput, and an edit's old/new text as a diff for the popup. Pure.
function M.claude_tool(args)
  args = type(args) == "table" and args or {}
  local name = tostring(args.tool_name or "")
  local input = type(args.input) == "table" and args.input or {}
  local raw = vim.deepcopy(input)
  local function lines(s) return vim.split(tostring(s or ""), "\n", { plain = true }) end
  local path = input.file_path or input.notebook_path
  local diff
  if name == "Edit" and input.old_string then
    diff = { "--- " .. tostring(path), "+++ " .. tostring(path) }
    for _, l in ipairs(lines(input.old_string)) do diff[#diff + 1] = "-" .. l end
    for _, l in ipairs(lines(input.new_string)) do diff[#diff + 1] = "+" .. l end
  elseif name == "Write" and input.content then
    diff = { "+++ " .. tostring(path) }
    for i, l in ipairs(lines(input.content)) do
      if i > 200 then diff[#diff + 1] = "+..."; break end
      diff[#diff + 1] = "+" .. l
    end
  end
  if diff then raw.diff = table.concat(diff, "\n") end
  local what = input.description or path or input.pattern or input.url
  return { kind = CLAUDE_KINDS[name] or "other", rawInput = raw,
    title = name .. (what and (": " .. tostring(what)) or "") }
end

-- What the permission tool answers Claude Code's AskUserQuestion with
-- (issue #31): the picks (chat/init.lua's ask_questions - per question
-- the labels picked, or your own words) as `updatedInput.answers`, keyed
-- by each question's text, several picks joined with ", " - which Claude
-- Code hands the tool as your answer. nil picks: declined. Pure.
function M.answers_for(input, picks)
  if not picks then return { behavior = "deny", message = "The user declined to answer the question(s)." } end
  local answers = {}
  for i, q in ipairs(input.questions or {}) do
    local text = type(q) == "table" and q.question or q
    answers[tostring(text)] = table.concat(picks[i] or {}, ", ")
  end
  -- (a shallow copy: 0.9's vim.deepcopy can't copy a JSON null, vim.NIL)
  local updated = {}
  for k, v in pairs(input) do updated[k] = v end
  updated.answers = answers
  return { behavior = "allow", updatedInput = updated }
end

-- Claude Code's AskUserQuestion, through its --permission-prompt-tool:
-- asked as the questions they are (not Allow/Deny), the answer replied in
-- the shape M.answers_for builds. Never answered for you - not by
-- chat.permissions, a skill or a plan: an allow without answers means
-- nothing. The question and what became of it go under the tool call.
local function ask_questions(conv, entry, input, reply, w)
  if w then WD.busy(w, 1, now()); WD.asking(w, 1, now()) end
  local first = type(input.questions[1]) == "table" and tostring(input.questions[1].question or "") or ""
  table.insert(entry.tools, "\u{00B7} AskUserQuestion: " .. first:gsub("%s+", " ")
    .. (#input.questions > 1 and (" (+" .. (#input.questions - 1) .. " more)") or ""))
  render_soon()
  I().ask_questions(conv, input.questions, function(picks)
    if w then WD.asking(w, -1, now()); WD.busy(w, -1, now()) end
    local said = {}
    for _, p in ipairs(picks or {}) do said[#said + 1] = table.concat(p, ", ") end
    table.insert(entry.tools, "  \u{21B3} " .. (picks and ("you answered: " .. table.concat(said, " / "):gsub("%s+", " "))
      or "you declined to answer"))
    render_soon()
    reply({ text = vim.json.encode(M.answers_for(input, picks)) })
  end)
end

-- The bridge's own tool for Claude Code's --permission-prompt-tool
-- (mcp__azure-vicli__permission): Claude Code asks it instead of refusing
-- what --allowedTools doesn't cover, and gets decide_permission's answer.
local PERMISSION_TOOL = {
  name = "permission",
  description = "azure-vicli's answer to Claude Code's own permission prompts (--permission-prompt-tool). "
    .. "Claude Code calls it; don't call it yourself.",
  inputSchema = { type = "object", properties = { tool_name = { type = "string" }, input = { type = "object" },
    tool_use_id = { type = "string" } }, required = { "tool_name", "input" } },
}

-- `run_st`: the conversation whose turn the calls belong to (the main
-- chat's state for the main chat, where `conv` is nil) - its watchdog
-- (st.running.watch) hears of each call, and waits while one runs.
local function bridge_handler(entry_ref, conv, run_st)
  return function(req, reply)
    local TOOLS = require("azure-cli.chat.tools")
    if req.method == "list" then
      local tools = TOOLS.describe()
      tools[#tools + 1] = PERMISSION_TOOL
      return reply({ tools = tools })
    end
    local w = run_st and run_st.running and run_st.running.watch
    if req.method == "call" and req.name == "permission" then
      local args = type(req.arguments) == "table" and req.arguments or {}
      if args.tool_name == "AskUserQuestion" and type(args.input) == "table"
          and type(args.input.questions) == "table" and #args.input.questions > 0 then
        return ask_questions(conv, entry_ref() or { tools = {} }, args.input, reply, w)
      end
      local input = type(args.input) == "table" and next(args.input) and args.input or vim.empty_dict()
      if w then WD.busy(w, 1, now()) end
      return decide_permission(conv, entry_ref() or { tools = {} }, M.claude_tool(args), function(yes)
        if w then WD.busy(w, -1, now()) end
        reply({ text = vim.json.encode(yes and { behavior = "allow", updatedInput = input }
          or { behavior = "deny", message = "The user didn't allow this." }) })
      end, w)
    end
    if req.method == "call" then
      local entry = entry_ref() or { tools = {} }
      local env = tool_env(entry, conv)
      env.confirm = asking_confirm(env.confirm, w)
      if w then WD.busy(w, 1, now()) end
      return TOOLS.call(req.name, req.arguments, env, function(text, is_err)
        if w then WD.busy(w, -1, now()) end
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
-- result (an interrupted one's too), without the process exiting.
local function turn_on_stdout(get_turn)
  return function(_, d)
    local turn = get_turn()
    if not turn or turn.done then return end
    if turn.watch and d and (d[2] ~= nil or (d[1] or "") ~= "") then WD.activity(turn.watch, now()) end
    if d and CORE.stream_feed(turn.reader, d, vim.json.decode) then
      vim.schedule(function()
        turn.absorb()
        if turn.reader.final ~= nil or turn.reader.ended then
          turn.finish(nil, false)
        elseif turn.interrupt_id and (turn.reader.control or {})[turn.interrupt_id] == "error" and turn.kill then
          turn.kill("the agent refused the interrupt, so it was killed")
        end
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
-- Once a second it also asks the turn's watchdog (`st.running.watch`)
-- whether it ran out of time, and if so calls `st.running.on_timeout`
-- with which limit fired - once.
local function start_spinner(st)
  st.running.tick = 0
  CHAT().set_winbars()
  st.running.timer = vim.fn.timer_start(120, function()
    local run = st.running
    if not run then return end
    run.tick = run.tick + 1
    if run.tick % 8 == 0 then
      local fired = run.watch and run.on_timeout and WD.check(run.watch, now())
      if fired then
        local on_timeout = run.on_timeout
        run.on_timeout = nil
        on_timeout(fired)
      end
      render()
    else
      CHAT().set_winbars()
    end
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
  -- This turn's idle timeout and cap (chat/watchdog.lua), and which of
  -- them stopped it, if one did.
  local w = WD.new(WD.limits(agent), now())
  local timed_out
  local function finish(status, extra_text)
    if done then return end
    done = true
    if st.running and st.running.entry == entry then
      if st.running.timer then pcall(vim.fn.timer_stop, st.running.timer) end
      st.running = nil
    end
    entry.status = timed_out and WD.status(timed_out, w) or status
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
    -- Free again: what you sent meanwhile goes next, then the next plan
    -- waiting for an agent starts.
    vim.schedule(function() M.drain(st) end)
    pcall(function() require("azure-cli.chat.agents").pump() end)
  end

  local function on_update(method, params)
    if method ~= "session/update" then return end
    WD.activity(w, now())
    local u = params.update or {}
    if u.sessionUpdate == "agent_message_chunk" then
      local t = type(u.content) == "table" and u.content.text
      if type(t) == "string" then entry.text = entry.text .. t; render_soon() end
    elseif u.sessionUpdate == "tool_call" then
      -- Our own azure-vicli tools are logged by the bridge already, with
      -- their arguments.
      local title = tostring(u.title or u.name or "tool")
      entry.skill = entry.skill or require("azure-cli.chat.skills").in_tool_call(u, entry.skill_names)
      if not title:find("azure%-vicli") then
        table.insert(entry.tools, "\u{00B7} " .. title)
        render_soon()
      end
    elseif u.sessionUpdate == "tool_call_update" and u.status == "failed" then
      table.insert(entry.tools, "\u{2717} " .. (u.title or "tool failed"))
      render_soon()
    elseif u.sessionUpdate == "usage_update" then
      -- How full its context is, and - when it says - the session's cost
      -- so far (cumulative: this answer's is what it grew by).
      if tonumber(u.used) and tonumber(u.size) then entry.context = { used = tonumber(u.used), size = tonumber(u.size) } end
      local cost = type(u.cost) == "table" and tonumber(u.cost.amount)
      local pj = st.persistent_job
      if cost and (u.cost.currency == nil or u.cost.currency == "USD") and pj then
        entry.cost = (entry.cost or 0) + math.max(0, cost - (pj.cost_seen or 0))
        pj.cost_seen = cost
      end
    end
  end

  -- The agent asking permission before a tool call: shown with the same
  -- yes/no popup azure-vicli's own tools use, the tool call's diff (if
  -- any, else the command it would run) as the details; each shell
  -- command is logged in the chat with its outcome. "Allow" picks the
  -- first allow_* option offered, "Deny" the first reject_*; azure-vicli
  -- can't tell "once" from "always" apart in that popup, so it always
  -- answers "once". Reading
  -- and searching never ask (CORE.READ_ONLY_KINDS); changing files
  -- (CORE.FILE_CHANGE_KINDS) is refused without asking while a /plan
  -- message runs, and allowed without asking when every file is in an
  -- approved plan, inside its worktree. A file the approved plan doesn't
  -- cover asks, with the agent's reason; allowing it adds it to the plan.
  -- Running the approved plan's Test plan command (or a line of it) in
  -- the agent's own shell doesn't ask either.
  local function on_permission(method, params, id, conn)
    if method ~= "session/request_permission" then return conn.respond(id, nil, "unsupported request") end
    local options = params.options or {}
    local tool = params.toolCall or {}
    local function answer(yes)
      local pick
      for _, o in ipairs(options) do
        if yes and (o.kind == "allow_once" or o.kind == "allow_always") then pick = pick or o.optionId end
        if not yes and (o.kind == "reject_once" or o.kind == "reject_always") then pick = pick or o.optionId end
      end
      pick = pick or (options[1] and options[1].optionId)
      if pick then conn.respond(id, { outcome = { outcome = "selected", optionId = pick } })
      else conn.respond(id, { outcome = { outcome = "cancelled" } }) end
    end
    WD.activity(w, now())
    decide_permission(st, entry, tool, answer, w)
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
    st.running = { acp = true, entry = entry, job = pj.job, watch = w,
      cancel = function()
        pcall(pj.conn.notify, "session/cancel", { sessionId = pj.acp_session_id })
        vim.defer_fn(function()
          if st.running and st.running.entry == entry and not done then pcall(vim.fn.jobstop, pj.job) end
        end, 5000)
      end }
    st.running.on_timeout = function(fired)
      if done then return end
      timed_out = fired
      table.insert(entry.tools, WD.line(fired, w))
      st.running.cancel()
    end
    start_spinner(st)
  end

  local model = vars.model ~= "" and vars.model or nil
  local function set_model(pj, next_step)
    if not model or pj.model == model then return next_step() end
    pj.model = model
    local ok = pcall(pj.conn.request, "session/set_config_option",
      { sessionId = pj.acp_session_id, configId = "model", value = model }, function() next_step() end)
    if not ok then next_step() end
  end

  if reuse then
    local pj = st.persistent_job
    running(pj)
    set_model(pj, function() send_prompt(pj) end)
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
        set_model(pj, function() if live() then send_prompt(pj) end end)
      end)
    end)
  end)
end

local function clear_input()
  local ib = I().input_buf()
  if ib and vim.api.nvim_buf_is_valid(ib) then vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "" }) end
end

-- Puts `text` at the end of conversation `st`'s queue, to go as a turn of
-- its own once the one running ends (M.drain) - nothing else: the input
-- box and what you sent before stay as they are, so the main chat's
-- message_agent can queue for another agent. opts: snap, display,
-- view_win, done_note (as send's). Returns its place in the queue.
function M.queue(st, text, opts)
  opts = opts or {}
  st.queue = st.queue or {}
  table.insert(st.queue, { text = text, display = opts.display, snap = opts.snap, view_win = opts.view_win,
    done_note = opts.done_note, at = os.time() })
  render()
  return #st.queue
end

-- What you type and send while the agent answers: queued (st.queue) with
-- what you were looking at then, and sent as a turn of its own once this
-- one ends (M.drain). Returns nil, like any send that started no turn.
local function enqueue(st, text, opts)
  local view_win = opts.view_win or CHAT().main_win()
  local sel = st.selection
  if sel and not (vim.api.nvim_win_is_valid(sel.win) and sel.win == view_win) then sel = nil end
  st.selection = nil
  local snap = opts.snap or require("azure-cli.chat.view").snapshot(view_win, sel)
  M.queue(st, text, { display = opts.display, snap = snap, view_win = view_win, done_note = opts.done_note })
  clear_input()
  table.insert(st.sent, text)
  while #st.sent > 100 do table.remove(st.sent, 1) end
  st.sent_pos = nil
  render()
  local KEYS = require("azure-cli.keys")
  notify("Queued - it goes to the agent when this answer is done (" .. KEYS.name("chat", "queue_drop")
    .. " on it in the chat cancels it, " .. KEYS.name("chat", "queue_edit") .. " edits it).")
end

-- Sending from the input box with a queued message in it (cc put it
-- there): it goes back in its place, changed - or, sent empty, stays as it
-- was, held until you send it. Gone from the queue meanwhile (dd'd, or
-- sent), what you typed is a message of its own.
local function requeue(st, text)
  local q = st.queue_editing
  st.queue_editing = nil
  q.editing = nil
  if not vim.tbl_contains(st.queue or {}, q) then return send() end
  clear_input()
  local KEYS = require("azure-cli.keys")
  if text == "" then
    q.held = true
    render()
    return notify("The queued message stays as it was, held - " .. KEYS.name("chat", "open_ref") .. " on it sends it.")
  end
  q.text, q.display, q.held = text, nil, nil
  render()
  if st.running then return notify("Changed the queued message - it goes when this answer is done.") end
  M.drain(st)
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
  if from_input and st.queue_editing then return requeue(st, text) end
  if text == "" then return end
  if vim.v.exiting ~= vim.NIL then return end  -- quitting: no new agent process
  if st.running then
    -- Typed: it waits its turn. The keys that send for you (gS, gR, ...)
    -- say so themselves before they get here.
    if from_input then return enqueue(st, text, opts) end
    notify("The agent is still answering - wait, or stop it (<C-c>).", vim.log.levels.WARN)
    return
  end
  -- /skills: the agent's skills where it would run (chat/skills.lua), in a
  -- popup that allows them and starts a message with one - nothing goes to
  -- the agent. With none found, the chat says where it looked.
  if text:match("^%s*/skills%s*$") then
    if from_input and I().input_buf() and vim.api.nvim_buf_is_valid(I().input_buf()) then
      vim.api.nvim_buf_set_lines(I().input_buf(), 0, -1, false, { "" })
    end
    local snap = opts.snap or require("azure-cli.chat.view").snapshot(opts.view_win or CHAT().main_win())
    local SKILLS = require("azure-cli.chat.skills")
    if SKILLS.popup(agent_cwd(snap), function(name)
      CHAT().show(true)
      local ib = I().input_buf()
      if ib and vim.api.nvim_buf_is_valid(ib) then
        vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "/" .. name .. " " })
        if vim.api.nvim_get_current_buf() == ib then pcall(vim.api.nvim_win_set_cursor, 0, { 1, #name + 2 }) end
      end
    end) then
      return
    end
    table.insert(st.entries, { role = "you", text = text, where = where_label(snap), view = snap })
    table.insert(st.entries, { role = "note", text = SKILLS.report(agent_cwd(snap)) })
    render()
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
  local expanded, prompt_name = CORE.expand_prompt(text, CORE.prompts(config().prompts))

  local VIEW = require("azure-cli.chat.view")
  local view_win = opts.view_win or CHAT().main_win()
  local sel = st.selection
  if sel and not (vim.api.nvim_win_is_valid(sel.win) and sel.win == view_win) then sel = nil end
  -- A queued message took its selection when you sent it (enqueue); the
  -- one there now is for your next.
  if not opts.keep_selection then st.selection = nil end
  local snap = opts.snap or VIEW.snapshot(view_win, sel)
  -- The main chat coordinates: its /plan starts an agent of its own for
  -- each work item or PR (chat/agents.lua), instead of planning here.
  if prompt_name == "plan" and not st.plan_key then
    table.insert(st.entries, { role = "you", text = shown_text, where = where_label(snap), view = snap })
    table.insert(st.entries, { role = "note", text = require("azure-cli.chat.agents").start_for(text:gsub("^%s*/plan%s*", ""), snap) })
    render()
    save(st)
    return
  end
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
  local model = CHAT().current_model(agent, st)
  local reuse = persistent_alive(st, agent_name)
  -- A different model than its process runs (its plan approved: planner ->
  -- implementer; or gm): an ACP agent switches in its session (send_acp),
  -- any other starts again on it.
  if reuse and not agent.acp and st.persistent_job.model ~= model then reuse = false end
  if st.persistent_job and not reuse then stop_persistent(st) end
  local replay = not first and not reuse
  table.insert(st.entries, { role = "you", text = shown_text, where = where_label(snap), view = snap })
  local entry = { role = "agent", status = "running", started = os.time(), tools = {}, view_win = view_win, snap = snap,
    label = agent.label or agent_name, mode = replay and "replay" or nil, text = "", planning = prompt_name == "plan" or nil,
    requests = CORE.request_multiplier(agent, model), model = model }
  table.insert(st.entries, entry)
  -- The agent's skills where it runs, and the one this message asks for
  -- (chat/skills.lua: an allowed one's permission prompts don't ask).
  local SKILLS = require("azure-cli.chat.skills")
  entry.skill_names = SKILLS.available(agent_cwd(snap))
  entry.skill = SKILLS.named_in(shown_text .. "\n" .. expanded, entry.skill_names)
  if st.agent_id then
    -- A plan's own agent: its tool calls come with its id (the relay's
    -- AZVICLI_CHAT_AGENT / X-Azvicli-Agent) and land in this conversation.
    st.bridge_entry = entry
    BRIDGE.route(st.agent_id, bridge_handler(function() return st.bridge_entry end, st, st))
  else
    BRIDGE.handler = bridge_handler(function() return entry end, nil, st)
  end
  render()

  local message = CORE.compose(expanded, view_text, {
    first = first, history = replay and history or nil, orchestrator = not st.plan_key,
    refs = require("azure-cli.chat.refs").describe(expanded),
  })
  local vars = {
    message = message, message_json = vim.json.encode(message), text = expanded,
    model = model or "",
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
  local turn = { entry = entry, reader = reader, err = err, absorb = absorb, cancelled = false, done = false,
    watch = WD.new(WD.limits(agent), now()) }
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
    if turn.interrupt_id then
      -- Interrupted (chat/run.lua's turn.stop): the process and its session
      -- go on, unless it had to be killed.
      if entry.text == "" then entry.text = "_(stopped before it answered)_" end
      if not turn.killed then
        table.insert(entry.tools, "\u{00B7} interrupted - the session stays, your next message continues it")
      end
    elseif reader.is_error and entry.text == "" then
      entry.text = "(the agent reported an error)"
    end
    if turn.timed_out then
      entry.status = WD.status(turn.timed_out, turn.watch, turn.killed)
    elseif cancelled or turn.cancelled then
      entry.status = turn.killed and "stopped (killed)" or "stopped"
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
    -- Free again: what you sent meanwhile goes next, then the next plan
    -- waiting for an agent starts.
    vim.schedule(function() M.drain(st) end)
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
    local pj = { agent_name = agent_name, conv_id = st.conv_id, turn = turn, model = model }
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
  st.running = { job = job, turn = turn, entry = entry, watch = turn.watch }

  -- Stopping this turn (a timeout, <C-c>). Claude Code - the default
  -- stream-json stdin - is interrupted with a control_request: the turn
  -- ends with a `result` (turn_on_stdout finishes it) and the process, its
  -- session and its worktree stay for your next message. If it doesn't end
  -- within interrupt_grace_seconds, or the agent refuses, or you stop it
  -- again, or its stdin is some other CLI's, the process is killed - and
  -- the next message replays the conversation to a new one.
  local interruptible = agent.stdin == nil
  local grace = tonumber(agent.interrupt_grace_seconds) or 5
  function turn.kill(why)
    if turn.done then return end
    if not turn.interrupt_id then return pcall(vim.fn.jobstop, job) end
    turn.killed = true
    table.insert(entry.tools, "\u{2717} " .. why .. " - your next message starts it again and replays the conversation")
    render_soon()
    stop_tree(job)
  end
  function turn.stop()
    if turn.done then return end
    if st.running and st.running.turn == turn then st.running.on_timeout = nil end
    if turn.interrupt_id then return turn.kill("stopped again while interrupting, so it was killed") end
    if not interruptible then return turn.kill() end
    interrupt_seq = interrupt_seq + 1
    turn.interrupt_id = "azvicli-int-" .. interrupt_seq
    table.insert(entry.tools, "\u{22EF} interrupting the turn")
    render_soon()
    pcall(vim.fn.chansend, job, CORE.interrupt_line(turn.interrupt_id) .. "\n")
    vim.defer_fn(function()
      turn.kill("the agent didn't stop within " .. WD.span(grace) .. " of the interrupt, so it was killed")
    end, math.floor(grace * 1000))
  end
  st.running.stop = turn.stop
  st.running.on_timeout = function(fired)
    if turn.done then return end
    turn.timed_out, turn.cancelled = fired, true
    table.insert(entry.tools, WD.line(fired, turn.watch))
    turn.stop()
  end
  start_spinner(st)
  return entry
end
M.send = send

-- The next queued message of conversation `st`, once it's free: in order,
-- each a turn of its own (whose end drains the next). One being edited
-- (cc) holds up the rest; held ones (you stopped the agent with <C-c>)
-- stay until you send them.
function M.drain(st)
  while not st.running and vim.v.exiting == vim.NIL do
    local pick
    for i, q in ipairs(st.queue or {}) do
      if q.editing then return end
      if not q.held then pick = i break end
    end
    if not pick then return end
    M.send_queued(st, pick)
  end
end

-- Sends the n-th of `st`'s queued messages now; it leaves the queue.
function M.send_queued(st, n)
  local q = table.remove(st.queue, n)
  if not q then return end
  render()
  return send(q.text, { conv = st, snap = q.snap, display = q.display, done_note = q.done_note, keep_selection = true,
    view_win = (q.view_win and vim.api.nvim_win_is_valid(q.view_win)) and q.view_win or nil })
end

cancel = function(st)
  st = st or STATE()
  if not st.running then return notify("The agent isn't running.") end
  -- You stopped it for a reason: what you queued waits for you to send it.
  for _, q in ipairs(st.queue or {}) do q.held = true end
  if st.running.acp then return st.running.cancel() end
  if st.running.turn then st.running.turn.cancelled = true end
  -- Claude Code's turn is interrupted, its session kept (send's turn.stop).
  if st.running.stop then return st.running.stop() end
  pcall(vim.fn.jobstop, st.running.job)
end

-- Stops what conversation `c`'s agent is doing (the Agents screen's <C-c>).
function M.cancel_conversation(c) cancel(c) end

M.cancel = cancel
M.stop_persistent = stop_persistent

return M
