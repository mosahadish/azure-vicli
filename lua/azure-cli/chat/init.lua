-- lua/azure-cli/chat/init.lua: the chat panel - an agent (Claude Code, the
-- Copilot CLI, ...) you talk to from inside azure-vicli, which sees what you
-- see and can act on it. docs/chat.md is the user-facing description.
--
-- The panel is a split next to whatever azure-vicli screen you're on (the
-- conversation on top, an input box below) that follows you into every
-- azure-vicli tab while shown. gq on a screen takes you to it (opening it
-- if needed); gq/q inside it hides it. gq on a visual selection sends the
-- selected lines along with the next message.
--
-- The chosen agent (chat.agent, or one of chat.agents - gM switches) runs
-- headless and stays running for the whole conversation: either a CLI
-- reading one stream-json request per message on stdin (Claude Code's
-- --input-format stream-json), its events read as they arrive by
-- chat/core.lua's stream reader, or (agent.acp) an Agent Client Protocol
-- session (chat/acp.lua). Each message carries a description of what's
-- under the cursor (chat/view.lua) and of the PRs/work items it names
-- (chat/refs.lua); a process started mid-conversation (gM, gh, gm) gets
-- the conversation so far replayed to it. Conversations are saved
-- (chat/store.lua): the last one comes back after a restart, gh opens an
-- older one.
--
-- The agent's tools (chat/tools*.lua) reach Neovim through `azure-cli.py
-- --mcp` and chat/bridge.lua; their calls show in the conversation as they
-- happen, every change lands in an audit log (gH, u undoes), and the ones
-- that ask pop up a prompt (with the diff/text they'd send, when there is
-- one).
--
-- This file: the conversations, the panel and drawing it, confirming tool
-- calls. Running the agent is chat/run.lua (send, cancel), what the panel's
-- keys do is chat/actions.lua; both reach this file's state through M._.
local M = {}

local CORE = require("azure-cli.chat.core")
for _, k in ipairs({ "PREAMBLE", "compose", "parse_answer", "expand", "render", "models" }) do
  M[k] = CORE[k]
end

-- STATE.chat is the main conversation (the one the panel shows outside a
-- plan) and everything the panel shares between conversations: its
-- windows, size, the messages sent, the selection, the agent and models
-- picked. A plan's own agent has a conversation of its own
-- (MAIN().convs[plan key], made by M.conversation): a table with just
-- CONV_FIELDS, falling back to STATE.chat for the rest. STATE() is the
-- conversation the panel shows now - a plan's, in that plan's tabs (see
-- M.sync_active), else the main one. A message keeps the conversation it
-- was sent in (send's opts.conv), whatever the panel shows by the time it
-- answers.
local CONV_FIELDS = {
  entries = true, session_id = true, conv_id = true, created = true, running = true, persistent_job = true,
  plan_key = true, agent_id = true, label = true, bridge_entry = true, mcp_path = true, target = true, title = true,
  model = true, model_agent = true, queue = true, queue_editing = true,
}

local function MAIN()
  local S = require("azure-cli.state")
  S.chat = S.chat or {
    entries = {},        -- { role = "you"|"agent"|"note", text, where, view, tools, status, label, ... }
    session_id = nil,
    conv_id = nil,       -- chat/store.lua's id for the conversation in the panel
    visible = false,
    wins = {},           -- tabpage -> { log = win, input = win }
    main_win = {},       -- tabpage -> the last non-chat window
    running = nil,       -- { job, turn, timer, tick, cancelled } - the message in flight
    persistent_job = nil, -- { job, agent_name, conv_id, turn, stale } - the agent's running process
    queue = nil,         -- { { text, snap, view_win, at, held, editing } } sent while it ran (chat/run.lua)
    queue_editing = nil, -- the queued message in the input box (cc), until sent again
    models = {},         -- agent name -> model picked with gm
    agent_name = nil,    -- picked with gM
    sent = {},           -- what was sent, for <Up>/<Down> in the input box
    selection = nil,     -- { win, buf, from, to, text } from gq in visual mode
    restored = false,
    convs = {},          -- plan key -> that plan's own conversation
    active = nil,        -- the plan key whose conversation the panel shows, or nil (the main one)
  }
  S.chat.convs = S.chat.convs or {}
  return S.chat
end

-- The agent popup (M.popup): { log, input, key, log_buf, input_buf,
-- entry_at, role_at } while it's open - buffers of its own, so the panel
-- beside it keeps its conversation and what's typed in it (issue #78).
local popup

local function on_popup(b)
  b = b or vim.api.nvim_get_current_buf()
  return popup ~= nil and (b == popup.log_buf or b == popup.input_buf)
end

-- The conversation the panel shows.
local function panel_state()
  local main = MAIN()
  return (main.active and main.convs[main.active]) or main
end

-- The conversation the keys pressed now act on: the popup's in the popup,
-- else the panel's.
local function STATE()
  if on_popup() then return MAIN().convs[popup.key] or panel_state() end
  return panel_state()
end

-- A plan's own conversation (made the first time): `key` = the plan's key
-- ("wi-3001"), `fields` = { target, label } for a new one.
function M.conversation(key, fields)
  local main = MAIN()
  if main.convs[key] then return main.convs[key] end
  local c = { entries = {}, plan_key = key, agent_id = require("azure-cli.chat.bridge").new_id(),
    conv_id = require("azure-cli.chat.store").new_id(), created = os.time() }
  for k, v in pairs(fields or {}) do c[k] = v end
  setmetatable(c, {
    __index = function(_, k) if CONV_FIELDS[k] then return nil end return main[k] end,
    __newindex = function(tbl, k, v) if CONV_FIELDS[k] then rawset(tbl, k, v) else main[k] = v end end,
  })
  main.convs[key] = c
  return c
end

-- A plan's own conversation, or nil (never makes one).
function M.find_conversation(key) return MAIN().convs[key] end

-- Every conversation: the main one first, then the plans' (by key).
function M.conversations()
  local main = MAIN()
  local out = { main }
  local keys = vim.tbl_keys(main.convs)
  table.sort(keys)
  for _, k in ipairs(keys) do out[#out + 1] = main.convs[k] end
  return out
end

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function config() return require("azure-cli.config").get().chat or {} end

-- ---------------------------------------------------------------------------
-- Agents and models.

-- Every configured agent, name -> spec: chat.agents, or the one chat.agent
-- (named by its label).
function M.agents()
  local cfg = config()
  if cfg.agents and not vim.tbl_isempty(cfg.agents) then return cfg.agents end
  if cfg.agent then return { [cfg.agent.label or "agent"] = cfg.agent } end
  return {}
end

-- The agent in use: name, spec - the one picked with gM, else
-- chat.default_agent, else the first by name.
function M.current_agent()
  local agents = M.agents()
  local st = STATE()
  if st.agent_name and agents[st.agent_name] then return st.agent_name, agents[st.agent_name] end
  local d = config().default_agent
  if d and agents[d] then return d, agents[d] end
  local names = vim.tbl_keys(agents)
  table.sort(names)
  if names[1] then return names[1], agents[names[1]] end
  return nil, nil
end

local function agent_label()
  local name, a = M.current_agent()
  return (a and a.label) or name or "Agent"
end
M.agent_label = agent_label

-- Whether a message is in flight (a new one has to wait).
function M.busy() return STATE().running ~= nil end

-- The model conversation `st` (default: the panel's) uses on `agent`: the
-- one picked there with gm, else its stage's - a plan's own agent is on
-- agent.planner_model until you approve its plan, then on
-- agent.implementer_model - else agent.model, else the first of
-- agent.models, else nil.
function M.current_model(agent, st)
  st = st or STATE()
  if st.model then
    for name, a in pairs(M.agents()) do
      if a == agent and st.model_agent == name then return st.model end
    end
  end
  if agent and st.plan_key and (agent.planner_model or agent.implementer_model) then
    local rec = require("azure-cli.chat.plan").load(st.plan_key)
    local approved = rec and (rec.status == "approved" or rec.status == "done")
    local staged = approved and agent.implementer_model or (not approved and agent.planner_model)
    if staged then return staged end
  end
  if agent and agent.model then return agent.model end
  local list = CORE.models(agent)
  return list[1] and list[1].value or nil
end

-- ---------------------------------------------------------------------------
-- Conversation persistence.

local function save(st)
  st = st or STATE()
  if #st.entries == 0 then return end
  st.conv_id = st.conv_id or require("azure-cli.chat.store").new_id()
  st.created = st.created or os.time()
  pcall(require("azure-cli.chat.store").save, { id = st.conv_id, created = st.created, entries = st.entries,
    session_id = st.session_id, agent = (M.current_agent()), model = M.current_model(select(2, M.current_agent()), st),
    plan = st.plan_key })
end

local function load_conversation(rec, st)
  st = st or STATE()
  st.entries = rec.entries or {}
  st.session_id = rec.session_id
  st.conv_id = rec.id
  st.created = rec.created
  if rec.agent and M.agents()[rec.agent] then st.agent_name = rec.agent end
end

-- The plans' own conversations as they were before a restart: the newest
-- saved one per plan (whose plan is still there), back in MAIN().convs.
-- Their agents aren't running any more - the next message starts one and
-- replays the conversation to it. Once per session.
function M.restore_plans()
  local main = MAIN()
  if main.plans_restored then return end
  main.plans_restored = true
  local STORE = require("azure-cli.chat.store")
  local PLAN = require("azure-cli.chat.plan")
  local seen = {}
  for _, s in ipairs(STORE.list()) do  -- newest first
    if s.plan and not seen[s.plan] and not main.convs[s.plan] then
      seen[s.plan] = true
      local plan = PLAN.load(s.plan)
      local rec = plan and STORE.load(s.id)
      if rec then
        local c = M.conversation(s.plan, { label = PLAN.target_label(plan.target), target = plan.target, title = plan.title })
        c.entries, c.conv_id, c.created, c.session_id = rec.entries or {}, rec.id, rec.created, rec.session_id
      end
    end
  end
  -- A plan no agent's conversation has (the main chat wrote it before it
  -- had to hand planning on, or its conversation was pruned): an idle one
  -- of its own, so the Agents screen lists it and approving it goes to an
  -- agent rather than the main chat (#86). Finished ones stay as they are.
  local adopted = {}
  for _, f in ipairs(vim.fn.glob(PLAN.root() .. "/*.json", false, true)) do
    local key = vim.fn.fnamemodify(f, ":t:r")
    if (key:match("^wi%-%d+$") or key:match("^pr%-%d+$")) and not main.convs[key] then
      local plan = PLAN.load(key)
      if plan and type(plan.target) == "table"
          and (plan.status == "draft" or plan.status == "changes_requested" or plan.status == "approved") then
        local label = PLAN.target_label(plan.target)
        local c = M.conversation(key, { label = label, target = plan.target, title = plan.title })
        c.entries[#c.entries + 1] = { role = "note", text = "This plan was written in the main chat, before planning "
          .. "moved to agents. " .. (plan.status == "approved"
            and "Tell this agent to carry it out (or ask the main chat to message_agent it), "
            or "Approve it (gA) to hand it to an agent, ")
          .. "or discard it (dd on the Agents screen, or ask the main chat to discard_plan it)." }
        adopted[#adopted + 1] = label
      end
    end
  end
  if #adopted > 0 then
    table.sort(adopted)
    notify("Plan" .. (#adopted == 1 and " " or "s ") .. table.concat(adopted, ", ") .. " had no agent - "
      .. (#adopted == 1 and "it's" or "they're") .. " on the Agents screen now: approve to hand on, or dd there to discard.")
  end
end

-- Forgets plan `key`'s conversation (discard_plan); its saved file stays.
function M.drop_conversation(key)
  MAIN().convs[key] = nil
end

local function restore_once()
  local st = MAIN()
  if st.restored then return end
  st.restored = true
  pcall(M.restore_plans)
  if #st.entries > 0 then return end
  local rec = require("azure-cli.chat.store").load_current()
  if rec then load_conversation(rec, st) end
end

-- ---------------------------------------------------------------------------
-- Rendering.

-- Foreground-only on purpose: the panel's background stays whatever the
-- window's is (a group with a background painted bands across the text).
local HL = {
  AzureCliChatYou = "Function", AzureCliChatYouText = "Function", AzureCliChatAgent = "String", AzureCliChatMeta = "Comment",
  AzureCliChatToolRead = "Comment", AzureCliChatToolWrite = "DiagnosticWarn", AzureCliChatToolErr = "DiagnosticError",
  AzureCliChatNote = "DiagnosticInfo", AzureCliChatRef = "Underlined",
}
local BAR = {
  you_head = "AzureCliChatYou", you = "AzureCliChatYou",
  agent_head = "AzureCliChatAgent", agent = "AzureCliChatAgent",
  tool_read = "AzureCliChatAgent", tool_write = "AzureCliChatAgent", tool_err = "AzureCliChatAgent",
  agent_log = "AzureCliChatAgent",
  note = "AzureCliChatNote", intro = "AzureCliChatAgent", fold = "AzureCliChatAgent",
  queued_head = "AzureCliChatMeta", queued = "AzureCliChatMeta",
}
local LINE_HL = {
  -- Your messages in your colour, the agent's own step log dimmed, so its
  -- answer stands out from both.
  you = "AzureCliChatYouText", agent_log = "AzureCliChatToolRead",
  tool_read = "AzureCliChatToolRead", tool_write = "AzureCliChatToolWrite", tool_err = "AzureCliChatToolErr",
  note = "AzureCliChatNote", intro = "AzureCliChatMeta", fold = "AzureCliChatMeta",
  -- A message queued while the agent answers: dimmed until it goes out.
  queued = "AzureCliChatMeta",
}

local log_buf, input_buf
local ns = vim.api.nvim_create_namespace("azure_cli_chat")
local entry_at = {}
local role_at = {}  -- conversation line -> its role (core.render's)

local function is_chat_buf(b) return b ~= nil and (b == log_buf or b == input_buf or on_popup(b)) end
M.is_chat_buf = is_chat_buf

-- The input box / line maps of the buffers you're in: the popup's or the panel's.
local function cur_input_buf() return on_popup() and popup.input_buf or input_buf end
local function cur_entry_at() return on_popup() and (popup.entry_at or {}) or entry_at end
local function cur_role_at() return on_popup() and (popup.role_at or {}) or role_at end

-- Conversation `st` into log buffer `buf`: its lines, and which role and
-- entry each line shows.
local function draw(buf, st)
  local lines, roles, name_end, at = CORE.render(st.entries, os.time(), agent_label(), st.queue)
  vim.bo[buf].modifiable = true
  -- render never returns a line with a newline (#101); should one slip
  -- through anyway, it's drawn with spaces instead of failing the redraw.
  local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  if not ok then
    for i, l in ipairs(lines) do lines[i] = tostring(l):gsub("[\r\n]", " ") end
    ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  end
  vim.bo[buf].modifiable = false
  if not ok then error("chat: couldn't draw the conversation", 0) end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local function mark(row, col, opts) pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts) end
  for i = 1, #lines do
    local role = roles[i]
    if role then
      mark(i - 1, 0, { sign_text = "\u{258E}", sign_hl_group = BAR[role] or "AzureCliChatAgent", priority = 10 })
      if role == "you_head" or role == "agent_head" or role == "queued_head" then
        local cut = name_end[i] or #lines[i]
        mark(i - 1, 0, { end_col = cut, hl_group = role == "agent_head" and "AzureCliChatAgent" or "AzureCliChatYou", priority = 200 })
        mark(i - 1, 0, { end_col = cut, hl_group = "AzureCliChatName", priority = 201 })
        if cut < #lines[i] then mark(i - 1, cut, { end_col = #lines[i], hl_group = "AzureCliChatMeta", priority = 200 }) end
      elseif LINE_HL[role] then
        mark(i - 1, 0, { end_col = #lines[i], hl_group = LINE_HL[role], priority = 200 })
      end
      if role == "agent" or role == "you" or role == "note" then
        -- !101 / #3001: <CR> opens them.
        local _, all = CORE.find_refs(lines[i])
        for _, r in ipairs(all) do mark(i - 1, r.s - 1, { end_col = r.e, hl_group = "AzureCliChatRef", priority = 210 }) end
      end
    end
  end
  return lines, roles, at
end

-- draw, but a conversation that can't be drawn only warns (once for it)
-- and returns nil: render is called from send, the queue and tool logs,
-- and must never stop a message going out (#101).
local function safe_draw(buf, st)
  local ok, lines, roles, at = pcall(draw, buf, st)
  if ok then return lines, roles, at end
  if not st.draw_warned then
    st.draw_warned = true
    vim.notify("azure-cli chat: couldn't redraw the conversation: " .. tostring(lines), vim.log.levels.WARN)
  end
end

local function render()
  local c = popup and MAIN().convs[popup.key]
  if c and vim.api.nvim_buf_is_valid(popup.log_buf) then
    local lines, roles, at = safe_draw(popup.log_buf, c)
    if lines then
      popup.role_at, popup.entry_at = roles, at
      if vim.api.nvim_win_is_valid(popup.log) and vim.api.nvim_get_current_win() ~= popup.log then
        pcall(vim.api.nvim_win_set_cursor, popup.log, { #lines, 0 })
      end
    end
  end
  if not (log_buf and vim.api.nvim_buf_is_valid(log_buf)) then return end
  local st = panel_state()
  local lines, roles, at = safe_draw(log_buf, st)
  if not lines then return pcall(M.set_winbars) end
  role_at, entry_at = roles, at
  for _, w in pairs(st.wins) do
    if w.log and vim.api.nvim_win_is_valid(w.log) and vim.api.nvim_get_current_win() ~= w.log then
      pcall(vim.api.nvim_win_set_cursor, w.log, { #lines, 0 })
    end
  end
  M.set_winbars()
end
M.render_now = render

-- Coalesces bursts of output into one redraw per 80ms.
local render_pending = false
local function render_soon()
  if render_pending then return end
  render_pending = true
  vim.defer_fn(function()
    render_pending = false
    render()
  end, 80)
end

-- A spinner frame while the agent runs (advanced by send's timer), else nil.
local SPINNER = { "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" }
local function spinner(st)
  local run = (st or STATE()).running
  if not run then return nil end
  return SPINNER[(run.tick or 0) % #SPINNER + 1]
end

-- For a statusline: "<spinner> Copilot 42s" while the agent runs, else "".
-- e.g. lualine: { function() return require("azure-cli.chat").status() end }
function M.status()
  local run = STATE().running
  if not run then return "" end
  return spinner() .. " " .. agent_label() .. " " .. math.max(0, os.time() - (run.entry.started or os.time())) .. "s"
end

-- The status strip: the agent working, a question waiting for your yes or
-- no, plans waiting for your review - "" when there's none. The standalone
-- launcher's tab line shows it on the right; for your own statusline:
-- { function() return require("azure-cli.chat").strip() end }.
function M.strip()
  local main = MAIN()
  local s = { question = main.question ~= nil, more_questions = main.questions_waiting or 0, working = {} }
  for _, c in ipairs(M.conversations()) do
    if c.running then
      local label = agent_label() .. (c.label and (" " .. c.label) or "")
      table.insert(s.working, { label = label,
        seconds = math.max(0, os.time() - ((c.running.entry or {}).started or os.time())) })
    end
  end
  s.frame = SPINNER[math.floor((vim.uv or vim.loop).now() / 120) % #SPINNER + 1]
  local okq, q = pcall(function() return #require("azure-cli.chat.agents").queued() end)
  s.queued = okq and q or 0
  local ok, waiting = pcall(function() return require("azure-cli.chat.plan").waiting() end)
  s.waiting = ok and waiting or {}
  return CORE.strip_text(s)
end

function M.set_winbars()
  local st = panel_state()
  local tags = {}
  local _, agent = M.current_agent()
  local model = M.current_model(agent, st)
  if model then tags[#tags + 1] = "[" .. model .. "]" end
  -- What this conversation has used: its cost when the agent reports one,
  -- else its premium requests; and how full the agent's context is.
  local CORE = require("azure-cli.chat.core")
  local cost = CORE.cost_of(st.entries)
  local used = cost and CORE.money(cost) or CORE.requests_label(CORE.requests_of(st.entries))
  local ctx
  for i = #st.entries, 1, -1 do
    if st.entries[i].context then ctx = CORE.context_label(st.entries[i].context) break end
  end
  local usage = table.concat(vim.tbl_filter(function(x) return x and x ~= "" end, { used, ctx }), " \u{00B7} ")
  if usage ~= "" then tags[#tags + 1] = "[" .. usage .. "]" end
  if st.running then tags[#tags + 1] = "[" .. spinner(st) .. " working]" end
  if #(st.queue or {}) > 0 then tags[#tags + 1] = "[\u{231B} " .. #st.queue .. " queued]" end
  if st.selection then tags[#tags + 1] = "[selection: " .. (st.selection.to - st.selection.from + 1) .. " lines]" end
  local UI = require("azure-cli.ui")
  for _, w in pairs(st.wins) do
    if w.log and vim.api.nvim_win_is_valid(w.log) then
      pcall(UI.wo, w.log, "winbar", UI.winbar({ "Chat", agent_label(), st.label }, tags))
    end
    if w.input and vim.api.nvim_win_is_valid(w.input) then
      local KEYS = require("azure-cli.keys")
      local send = KEYS.resolve("chat", "send")
      if type(send) == "table" then send = send[1] end
      local newline = KEYS.resolve("chat", "newline")
      if type(newline) == "table" then newline = table.concat(newline, "/") end
      pcall(UI.wo, w.input, "winbar", "%#AzureCliWinbarHelp# " .. (send and (send .. " sends") or "")
        .. (newline and (" \u{00B7} " .. newline .. " new line") or "")
        .. " \u{00B7} /prompt \u{00B7} !PR #item \u{00B7} ? keys%<")
    end
  end
  pcall(vim.cmd, "redrawstatus!")  -- for M.status() / M.strip() in a statusline
  pcall(vim.cmd, "redrawtabline")
end

-- The window the user was last in, in the current tab (never the panel).
function M.main_win()
  local st = STATE()
  local tab = vim.api.nvim_get_current_tabpage()
  local w = st.main_win[tab]
  -- A split briefly shows the buffer it was split from, so a WinEnter on it
  -- can have recorded a window that became the chat's a moment later.
  if w and vim.api.nvim_win_is_valid(w) and not is_chat_buf(vim.api.nvim_win_get_buf(w)) then return w end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if not is_chat_buf(vim.api.nvim_win_get_buf(win)) and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return vim.api.nvim_get_current_win()
end

-- ---------------------------------------------------------------------------
-- Buffers, keys and windows.

local send, cancel, new_chat, show_help, pick_model, pick_agent, pick_prompt, pick_history, show_audit,
  use_as_reply, open_ref, history_step, ask_why  -- forward

local function input_text()
  local ib = cur_input_buf()
  if not (ib and vim.api.nvim_buf_is_valid(ib)) then return "" end
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(ib, 0, -1, false), "\n"))
end

-- i / a in the conversation (and cc on a queued message): into the input
-- box next to it - the popup's, from the popup - typing.
local function focus_input()
  local w = (STATE().wins[vim.api.nvim_get_current_tabpage()] or {}).input
  if popup and vim.api.nvim_get_current_win() == popup.log then w = popup.input end
  if w and vim.api.nvim_win_is_valid(w) then
    vim.api.nvim_set_current_win(w)
    vim.cmd("startinsert!")
  end
end

-- A conversation and an input box with the chat's keys, named `name` and
-- `name`-input: the panel's, or an agent popup's.
local function make_bufs(name)
  local KEYS = require("azure-cli.keys")
  local log_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[log_buf].buftype = "nofile"
  vim.bo[log_buf].filetype = "markdown"
  vim.bo[log_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, log_buf, name)
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, input_buf, name .. "-input")
  vim.b[log_buf].azure_cli_chat = true
  vim.b[input_buf].azure_cli_chat = true
  require("azure-cli.ui").link_hl(HL)
  vim.api.nvim_set_hl(0, "AzureCliChatName", { default = true, bold = true })
  -- The agent answers in markdown: render it with Neovim's bundled parser.
  pcall(vim.treesitter.start, log_buf, "markdown")

  for _, b in ipairs({ log_buf, input_buf }) do
    KEYS.bind(b, "chat", "new_chat", function() new_chat() end, { desc = "start a new conversation" })
    KEYS.bind(b, "chat", "cancel", function() cancel() end, { desc = "stop the agent" })
    KEYS.bind(b, "chat", "hide", function() M.hide() end, { desc = "hide the chat" })
    KEYS.bind(b, "chat", "toggle", function() M.hide() end, { desc = "hide the chat" })
    KEYS.bind(b, "chat", "help", function() show_help() end, { desc = "chat keys" })
    KEYS.bind(b, "chat", "model", function() pick_model() end, { desc = "choose the model" })
    KEYS.bind(b, "chat", "agent", function() pick_agent() end, { desc = "choose the agent" })
    KEYS.bind(b, "chat", "prompts", function() pick_prompt() end, { desc = "run a saved prompt" })
    KEYS.bind(b, "chat", "history", function() pick_history() end, { desc = "open an earlier conversation" })
    KEYS.bind(b, "chat", "audit", function() show_audit() end, { desc = "what the agent changed (u undoes)" })
    KEYS.bind(b, "chat", "changes", function() M.show_changes() end, { desc = "the agent's change, file by file" })
    KEYS.bind(b, "chat", "resize_less", function() M.resize(-1) end, { desc = "make the chat smaller" })
    KEYS.bind(b, "chat", "resize_more", function() M.resize(1) end, { desc = "make the chat bigger" })
    KEYS.bind(b, "chat", "back", function()
      local w = M.main_win()
      if w and vim.api.nvim_win_is_valid(w) then vim.api.nvim_set_current_win(w) end
    end, { desc = "back to the screen next to the chat" })
  end
  KEYS.bind(log_buf, "chat", "focus_input", focus_input, { desc = "type a message" })
  KEYS.bind(log_buf, "chat", "open_ref", function() open_ref() end,
    { desc = "open the PR/work item under the cursor (on a queued message: send it)" })
  KEYS.bind(log_buf, "chat", "queue_drop", function() require("azure-cli.chat.actions").queue_drop() end,
    { desc = "cancel the queued message" })
  KEYS.bind(log_buf, "chat", "queue_edit", function() require("azure-cli.chat.actions").queue_edit() end,
    { desc = "edit the queued message" })
  KEYS.bind(log_buf, "chat", "use_as_reply", function() use_as_reply() end, { desc = "draft this answer as a reply" })
  KEYS.bind(log_buf, "chat", "why", function() ask_why() end, { desc = "ask the agent why it did this" })
  -- Not in the input box: A there is Vim's own "append at the end".
  KEYS.bind(log_buf, "chat", "agents", function() require("azure-cli.home").go("agents") end,
    { desc = "every plan's agent (the Agents screen)" })
  KEYS.bind(log_buf, "chat", "expand", function()
    -- <Tab>: all of this turn's tool calls and answer, or folded again.
    local st = STATE()
    local idx = cur_entry_at()[vim.api.nvim_win_get_cursor(0)[1]]
    local e = idx and st.entries[idx]
    if not (e and e.role == "agent") then return end
    e.open = not e.open or nil
    render()
    local roles = cur_role_at()
    for row, i in pairs(cur_entry_at()) do
      if i == idx and roles[row] == "agent_head" then pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 }) end
    end
  end, { desc = "unfold / fold this answer and its tool calls" })
  KEYS.bind(input_buf, "chat", "send", function() send() end, { desc = "send the message" })
  -- While typing: send, unless the completion menu is open (<CR> there
  -- accepts the /prompt, !PR or #item); newline breaks the line instead.
  local send_insert = KEYS.resolve("chat", "send_insert")
  for _, k in ipairs(type(send_insert) == "table" and send_insert or { send_insert }) do
    vim.keymap.set("i", k, function()
      if vim.fn.pumvisible() == 1 then return vim.api.nvim_replace_termcodes(k, true, false, true) end
      vim.schedule(function() vim.cmd("stopinsert") send() end)
      return ""
    end, { buffer = input_buf, expr = true, silent = true, desc = "send the message" })
  end
  local newline = KEYS.resolve("chat", "newline")
  for _, k in ipairs(type(newline) == "table" and newline or { newline }) do
    vim.keymap.set("i", k, "<CR>", { buffer = input_buf, silent = true, desc = "a new line in the message" })
  end
  KEYS.bind(input_buf, "chat", "prev_message", function() history_step(-1) end, { desc = "the previous message sent" })
  KEYS.bind(input_buf, "chat", "next_message", function() history_step(1) end, { desc = "the next message sent" })
  -- The same keys while typing, unless the completion menu is open.
  for action, dir in pairs({ prev_message = -1, next_message = 1 }) do
    local key = KEYS.resolve("chat", action)
    for _, k in ipairs(type(key) == "table" and key or { key }) do
      if k then
        vim.keymap.set("i", k, function()
          if vim.fn.pumvisible() == 1 then return vim.api.nvim_replace_termcodes(k, true, false, true) end
          vim.schedule(function() history_step(dir) end)
          return ""
        end, { buffer = input_buf, expr = true, silent = true })
      end
    end
  end
  -- !<digits> / #<digits>: complete PRs and work items as they're typed.
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = input_buf,
    callback = function()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local before = vim.api.nvim_get_current_line():sub(1, col)
      local sigil, digits = before:match("([!#])(%d*)$")
      if not sigil then return end
      local prev = before:sub(-#digits - 2, -#digits - 2)
      if prev ~= "" and prev:match("[%w_]") then return end
      local items = require("azure-cli.chat.refs").complete(sigil, digits)
      if #items > 0 then vim.fn.complete(col - #digits, items) end
    end,
  })
  return log_buf, input_buf
end

local function ensure_bufs()
  if log_buf and vim.api.nvim_buf_is_valid(log_buf) and input_buf and vim.api.nvim_buf_is_valid(input_buf) then return end
  restore_once()
  log_buf, input_buf = make_bufs("azure-cli://chat")
  render()
end

-- The tabs the panel belongs in: azure-vicli's own screens.
local PLUGIN_FT = {
  ["azurecli-dashboard"] = true, ["azurecli-files"] = true, ["azurecli-workitems"] = true, ["azurecli-workitem"] = true,
  ["azurecli-changes"] = true, ["azurecli-plan"] = true, ["azurecli-agents"] = true,
}
local function plugin_tab(tab)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if PLUGIN_FT[vim.bo[vim.api.nvim_win_get_buf(w)].filetype] then return true end
  end
  return false
end

local function panel_open_in(tab)
  local w = STATE().wins[tab]
  return w and w.log and vim.api.nvim_win_is_valid(w.log)
end

local function open_here(focus)
  local st = STATE()
  local tab = vim.api.nvim_get_current_tabpage()
  if panel_open_in(tab) then
    if focus then
      vim.api.nvim_set_current_win(st.wins[tab].input)
      vim.cmd("startinsert!")
    end
    return
  end
  ensure_bufs()
  local cfg = config()
  local pos = cfg.position or "right"
  local prev = vim.api.nvim_get_current_win()
  if not is_chat_buf(vim.api.nvim_win_get_buf(prev)) then st.main_win[tab] = prev end
  local vertical = pos == "right" or pos == "left"
  local cmd = ({ right = "botright vsplit", left = "topleft vsplit", bottom = "botright split", top = "topleft split" })[pos]
    or "botright vsplit"
  vim.cmd(cmd)
  local log = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(log, log_buf)
  local size = st.size or cfg.size or (vertical and 0.35 or 0.3)
  local total = vertical and vim.o.columns or vim.o.lines
  if size <= 1 then size = math.floor(total * size) end
  size = math.max(vertical and 30 or 8, math.floor(size))
  if vertical then pcall(vim.api.nvim_win_set_width, log, size) else pcall(vim.api.nvim_win_set_height, log, size) end
  vim.cmd("belowright split")
  local input = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input, input_buf)
  pcall(vim.api.nvim_win_set_height, input, cfg.input_height or 3)
  local UI = require("azure-cli.ui")
  for _, w in ipairs({ log, input }) do
    UI.plain_window(w, {})
    UI.wo(w, "wrap", true)
    UI.wo(w, "linebreak", true)
    UI.wo(w, vertical and "winfixwidth" or "winfixheight", true)
  end
  -- The speaker bars live in the sign column; markdown's ** and ` markers
  -- are hidden except on the cursor line.
  UI.wo(log, "signcolumn", "yes:1")
  UI.wo(log, "conceallevel", 2)
  UI.wo(log, "concealcursor", "")
  UI.wo(input, "winfixheight", true)
  st.wins[tab] = { log = log, input = input }
  -- The splits above fired WinEnter while still showing the screen's
  -- buffer: what the chat describes is the window gq was pressed in.
  if not is_chat_buf(vim.api.nvim_win_get_buf(prev)) then st.main_win[tab] = prev end
  render()
  if focus then
    vim.api.nvim_set_current_win(input)
    vim.cmd("startinsert!")
  elseif vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  -- The dashboards centre themselves in their window: let them re-fit.
  pcall(vim.api.nvim_exec_autocmds, "VimResized", {})
end

-- < / >: the panel narrower or wider (shorter or taller at the top or
-- bottom). The size sticks for the session, in every tab it follows into.
local function resize(dir)
  local st = STATE()
  local w = st.wins[vim.api.nvim_get_current_tabpage()]
  if not (w and w.log and vim.api.nvim_win_is_valid(w.log)) then return end
  local pos = config().position or "right"
  if pos == "right" or pos == "left" then
    st.size = math.max(30, vim.api.nvim_win_get_width(w.log) + dir * 5)
    pcall(vim.api.nvim_win_set_width, w.log, st.size)
  else
    st.size = math.max(8, vim.api.nvim_win_get_height(w.log) + dir * 2)
    pcall(vim.api.nvim_win_set_height, w.log, st.size)
  end
  pcall(vim.api.nvim_exec_autocmds, "VimResized", {})
end

local function close_here()
  local st = STATE()
  local tab = vim.api.nvim_get_current_tabpage()
  local w = st.wins[tab]
  if not w then return end
  for _, win in ipairs({ w.input, w.log }) do
    if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(tab) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  st.wins[tab] = nil
  pcall(vim.api.nvim_exec_autocmds, "VimResized", {})
end

M.resize = resize

-- gd: the agent's change (start_fix / start_story) in the change viewer.
function M.show_changes()
  require("azure-cli.chat.tools_fix").open_latest(require("azure-cli.chat.tools").git, function(err)
    if err then notify(err) end
  end)
end

function M.show(focus)
  STATE().visible = true
  open_here(focus)
end

-- Closes the agent popup and wipes its buffers.
local function close_popup()
  if not popup then return end
  local p = popup
  popup = nil
  for _, w in ipairs({ p.log, p.input }) do
    if vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  for _, b in ipairs({ p.log_buf, p.input_buf }) do
    if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  MAIN().popup_key = nil
end

-- A plan's agent's conversation in a popup over the current screen (ga on
-- the PR dashboard): buffers of its own with the chat's keys - i to type,
-- <CR> sends to that agent, q (or leaving it) closes - while the panel
-- keeps showing its own conversation (issue #78).
function M.popup(key)
  local main = MAIN()
  pcall(M.restore_plans)
  local c = main.convs[key]
  if not c then return notify("No agent conversation for " .. tostring(key) .. ".") end
  close_popup()
  ensure_bufs()
  main.popup_key = key
  local plog, pinput = make_bufs("azure-cli://chat-popup")
  local UI = require("azure-cli.ui")
  local width, height = UI.big_dims()
  local ih = math.max(1, config().input_height or 3)
  height = math.max(6, math.min(height, vim.o.lines - ih - 8))
  local row = math.max(0, math.floor((vim.o.lines - height - ih - 4) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local rec = require("azure-cli.chat.plan").load(key)
  local title = (c.label or key) .. " \u{00B7} " .. agent_label()
  local what = (rec and rec.title) or c.title
  if what and what ~= "" then title = title .. " \u{00B7} " .. what end
  local function open(buf, enter, cfg)
    cfg.relative, cfg.style, cfg.border, cfg.col, cfg.width = "editor", "minimal", UI.border(), col, width
    local ok, w = pcall(vim.api.nvim_open_win, buf, enter, cfg)
    if not ok then
      cfg.title, cfg.title_pos, cfg.footer, cfg.footer_pos = nil, nil, nil, nil
      w = vim.api.nvim_open_win(buf, enter, cfg)
    end
    UI.wo(w, "wrap", true)
    UI.wo(w, "linebreak", true)
    UI.float_hl(w)
    return w
  end
  local log = open(plog, true, { row = row, height = height, title = " " .. UI.fit(title, width - 4) .. " ",
    title_pos = "left" })
  UI.wo(log, "signcolumn", "yes:1")
  UI.wo(log, "conceallevel", 2)
  UI.wo(log, "concealcursor", "")
  local KEYS = require("azure-cli.keys")
  local input = open(pinput, false, { row = row + height + 2, height = ih, footer = " " .. KEYS.name("chat", "focus_input")
    .. " types \u{00B7} " .. KEYS.name("chat", "send") .. " sends \u{00B7} " .. KEYS.name("chat", "hide") .. " closes ",
    footer_pos = "right" })
  popup = { log = log, input = input, key = key, log_buf = plog, input_buf = pinput }
  render()
  pcall(vim.api.nvim_win_set_cursor, log, { vim.api.nvim_buf_line_count(plog), 0 })
  local function gone(ev)
    if not popup then return true end
    local w = tonumber(ev.match) or vim.api.nvim_get_current_win()
    if ev.event == "WinClosed" and (w == popup.log or w == popup.input) then
      vim.schedule(close_popup)
      return true
    end
    -- A question popping up over it (ui.lua's M.choose) isn't leaving it:
    -- answered, the focus comes back here (issue #55).
    if ev.event == "WinEnter" and not require("azure-cli.ui").choosing() then
      local cur = vim.api.nvim_get_current_win()
      if cur ~= popup.log and cur ~= popup.input then
        vim.schedule(close_popup)
        return true
      end
    end
  end
  vim.api.nvim_create_autocmd({ "WinClosed", "WinEnter" },
    { group = vim.api.nvim_create_augroup("AzureCliChatPopup", { clear = true }), callback = gone })
  return log, input
end

-- Tests: the popup's windows, or nil.
function M.popup_wins() return popup end

function M.hide()
  if popup then
    local cur = vim.api.nvim_get_current_win()
    if cur == popup.log or cur == popup.input then return close_popup() end
  end
  STATE().visible = false
  local main = M.main_win()
  close_here()
  if main and vim.api.nvim_win_is_valid(main) then pcall(vim.api.nvim_set_current_win, main) end
end

-- gq: from a screen, opens the panel - or, when it's already showing,
-- jumps into its input box - ready to type; from inside the panel, hides it.
function M.toggle()
  local st = STATE()
  if st.visible and panel_open_in(vim.api.nvim_get_current_tabpage())
      and is_chat_buf(vim.api.nvim_get_current_buf()) then
    return M.hide()
  end
  M.show(true)
end

-- gq in visual mode: remember the selected lines for the next message,
-- then go to the chat.
function M.capture_selection()
  local buf = vim.api.nvim_get_current_buf()
  local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
  if a > b then a, b = b, a end
  STATE().selection = {
    win = vim.api.nvim_get_current_win(), buf = buf, from = a, to = b,
    text = table.concat(vim.api.nvim_buf_get_lines(buf, a - 1, b, false), "\n"),
  }
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  M.show(true)
  M.set_winbars()
end

local group = vim.api.nvim_create_augroup("AzureCliChat", { clear = true })
vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local b = vim.api.nvim_get_current_buf()
    if is_chat_buf(b) then return end
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_config(win).relative ~= "" then return end
    STATE().main_win[vim.api.nvim_get_current_tabpage()] = win
  end,
})
-- The conversation the panel shows: in a plan's tab (its plan window or
-- change viewer: vim.t.azure_cli_plan_key) that plan's own one, if its
-- agent has one; the main one everywhere else. Redraws when it changes.
function M.sync_active()
  local main = MAIN()
  pcall(M.restore_plans)
  local ok, key = pcall(vim.api.nvim_tabpage_get_var, 0, "azure_cli_plan_key")
  local want = (ok and key and main.convs[key]) and key or nil
  if want ~= main.active then
    main.active = want
    if log_buf and vim.api.nvim_buf_is_valid(log_buf) then render() end
  end
end

vim.api.nvim_create_autocmd({ "TabEnter", "BufWinEnter" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      M.sync_active()
      -- A question's popup (its own BufWinEnter brings us here) would be
      -- split from and left, which answers it: follow once it's answered.
      require("azure-cli.ui").after_choose(function()
        local st = STATE()
        local tab = vim.api.nvim_get_current_tabpage()
        if st.visible and not panel_open_in(tab) and plugin_tab(tab) then open_here(false) end
      end)
    end)
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(ev)
    local closed = tonumber(ev.match)
    for tab, w in pairs(STATE().wins) do
      if w.log == closed or w.input == closed then
        vim.schedule(function()
          for _, win in ipairs({ w.log, w.input }) do
            if win ~= closed and win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
          end
          -- Closed by hand while its tab lives on: that's hiding it.
          if vim.api.nvim_tabpage_is_valid(tab) then STATE().visible = false end
        end)
        STATE().wins[tab] = nil
      end
    end
  end,
})

-- ---------------------------------------------------------------------------
-- Talking to the agent.

-- A float with `lines` next to a yes/no question (the diff a push would
-- send, the text a comment would post), closed once answered.
-- A desktop notification (notify.lua's toast) about something waiting for
-- you: chat.toasts = "unfocused" (default: only while Neovim isn't the
-- focused window - the terminal has to report focus) | "always" | false.
local focused = true
function M.alert(title, body)
  local mode = config().toasts
  if mode == nil then mode = "unfocused" end
  if mode == false or (mode == "unfocused" and focused) then return false end
  pcall(function() require("azure-cli.notify").toast(title, body) end)
  return true
end
M._set_focused = function(v) focused = v end  -- tests
vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
  group = group,
  callback = function(ev) focused = ev.event == "FocusGained" end,
})

-- One question at a time: with several agents, another one asking while
-- you answer waits here, so each answer goes to the question you read.
-- `ask(release)` puts its question up once none is open (`question`: the
-- winbar's and the toast's text); release(fn) once it's answered runs fn
-- and lets the next one ask.
local asking, waiting_questions = false, {}
local function one_at_a_time(question, ask)
  if asking then
    table.insert(waiting_questions, { question, ask })
    MAIN().questions_waiting = #waiting_questions
    M.set_winbars()
    return
  end
  asking = true
  notify(question .. " (answer in the prompt)")
  M.alert("azure-vicli: a question for you", question)
  MAIN().question = question
  M.set_winbars()
  ask(function(fn)
    MAIN().question = nil
    asking = false
    if fn then fn() end
    local nxt = table.remove(waiting_questions, 1)
    MAIN().questions_waiting = #waiting_questions
    M.set_winbars()
    if nxt then vim.schedule(function() one_at_a_time(nxt[1], nxt[2]) end) end
  end)
end

-- `extra`: a third button's label (an "always" for this kind of request);
-- picking it calls cb(true, true). `full`: what o in the popup opens (the
-- request as it is; default: the details).
local function confirm(question, cb, details, extra, full)
  one_at_a_time(question, function(release)
    local is_diff = details and (("\n" .. table.concat(details, "\n")):find("\ndiff ")) and "diff" or nil
    -- It can pop up while you're typing something else: Deny is focused, and
    -- keys only count after a moment (ui.lua's M.choose).
    require("azure-cli.ui").choose({ title = "The agent asks", lines = { question },
      buttons = extra and { "Allow", "Deny", extra } or { "Allow", "Deny" },
      default = 2, keys = extra and { y = 1, n = 2, a = 3 } or { y = 1, n = 2 }, cancel = 2, details = details,
      details_ft = is_diff, arm_ms = 400, full = full,
      hint = extra and "y allow \u{00B7} n deny \u{00B7} a " .. extra:lower() .. " \u{00B7} Esc deny \u{00B7} Tab moves"
        .. ((details and #details > 0) and " \u{00B7} o shows all" or "") or nil },
    function(i)
      release(function() cb(i == 1 or i == 3, i == 3) end)
    end)
  end)
end
M.confirm = confirm

-- Claude Code's AskUserQuestion (issue #31): each of `questions` ({
-- question, header, options = { { label, description } }, multiSelect })
-- as a popup of its own, in order - its options as buttons (1-9 press
-- them; ticked with multiSelect, then Done), Other... for your own words
-- (the comment editor), Cancel / Esc declining them all. cb(picks): per
-- question the labels picked (your own words last), or nil when declined.
-- `conv`'s label leads each title, like confirm_for's.
function M.ask_questions(conv, questions, cb)
  local UI = require("azure-cli.ui")
  local who = (conv and conv.label) and ("[" .. conv.label .. "] ") or ""
  local first = type(questions[1]) == "table" and tostring(questions[1].question or "") or ""
  one_at_a_time(who .. "The agent asks: " .. first, function(release)
    local picks = {}
    local ask
    ask = function(n, ticks)
      local q = questions[n]
      if q == nil then return release(function() cb(picks) end) end
      q = type(q) == "table" and q or { question = tostring(q) }
      local opts = type(q.options) == "table" and q.options or {}
      local multi = q.multiSelect == true
      local lines, buttons, keys = { tostring(q.question or "") }, {}, {}
      if #opts > 0 then lines[#lines + 1] = "" end
      for i, o in ipairs(opts) do
        o = type(o) == "table" and o or { label = tostring(o) }
        local label = tostring(o.label or ("Option " .. i))
        buttons[i] = label
        local d = o.description and tostring(o.description) or ""
        lines[#lines + 1] = i .. ". " .. label .. (d ~= "" and (" - " .. d) or "")
        if i <= 9 then keys[tostring(i)] = i end
      end
      local other = #buttons + 1
      buttons[other] = "Other\u{2026}"
      local done_i = multi and other + 1 or nil
      if done_i then buttons[done_i] = "Done" end
      buttons[#buttons + 1] = "Cancel"
      local cancel = #buttons
      if multi then lines[#lines + 1] = "(Pick any number of them.)" end
      local checks
      if multi then
        checks = {}
        for i = 1, #opts do checks[i] = ticks and ticks[i] or false end
      end
      local keys_hint = #opts > 1 and ("1-" .. math.min(#opts, 9)) or "1"
      local hint = (multi and (keys_hint .. " / Space tick \u{00B7} Done answers") or (keys_hint .. " picks \u{00B7} Enter picks"))
        .. " \u{00B7} Tab moves \u{00B7} Esc declines"
      local title = who .. tostring(q.header or "The agent asks")
        .. (#questions > 1 and (" (" .. n .. "/" .. #questions .. ")") or "")
      local function ticked(ch)
        local out = {}
        for i = 1, #opts do if ch and ch[i] then out[#out + 1] = buttons[i] end end
        return out
      end
      UI.choose({ title = title, lines = lines, buttons = buttons, keys = keys, cancel = cancel, stack = true,
        checks = checks, arm_ms = 400, hint = hint },
      function(i, ch)
        if i == nil or i == cancel then return release(function() cb(nil) end) end
        if i <= #opts then
          -- (with ui.confirm = "select" a multiSelect pick is just that one)
          picks[n] = { buttons[i] }
          return ask(n + 1)
        end
        if i == other then
          return require("azure-cli.editor").open({ title = "Your answer \u{00B7} " .. tostring(q.header or "the agent's question"),
            initial = "", context_lines = { tostring(q.question or "") },
            on_submit = function(text)
              text = vim.trim(text or "")
              if text == "" then return ask(n, ch) end
              local p = multi and ticked(ch) or {}
              p[#p + 1] = text
              picks[n] = p
              ask(n + 1)
            end,
            -- Backing out of your own words asks the question again.
            on_cancel = function() ask(n, ch) end })
        end
        -- Done: what's ticked (nothing ticked asks again).
        local p = ticked(ch)
        if #p == 0 then
          notify("Tick at least one, or pick Other\u{2026} - Esc declines.")
          return ask(n, ch)
        end
        picks[n] = p
        ask(n + 1)
      end)
    end
    ask(1)
  end)
end

-- A question from conversation `conv`'s agent says whose it is: "[#3001] ...".
local function confirm_for(conv)
  return function(question, cb, details, extra, full)
    confirm(((conv and conv.label) and ("[" .. conv.label .. "] ") or "") .. question, cb, details, extra, full)
  end
end

local function tool_env(entry, conv)
  return {
    -- The conversation this call comes from, and whether the panel is
    -- showing another one right now (a plan's agent working in the
    -- background): such a call shouldn't pull you into a tab.
    conv = conv,
    -- The main chat's own calls come without a conversation (chat/run.lua's
    -- BRIDGE.handler); planning and code changes refuse them (#86).
    main_chat = conv == nil,
    background = function()
      return conv ~= nil and STATE() ~= conv and not (popup and MAIN().convs[popup.key] == conv)
    end,
    main_win = function() return entry.view_win and vim.api.nvim_win_is_valid(entry.view_win) and entry.view_win or M.main_win() end,
    -- What the user was looking at when they sent the message (selection
    -- included) - current_view answers with it.
    view = function() return entry.snap end,
    log = function(line)
      entry.tools = entry.tools or {}
      table.insert(entry.tools, CORE.tool_line(line))
      render_soon()
    end,
    confirm = confirm_for(conv),
  }
end

-- ---------------------------------------------------------------------------
-- Talking to the agent (chat/run.lua) and what the panel's keys do
-- (chat/actions.lua), reached when first used.

local function RUN() return require("azure-cli.chat.run") end
local function ACT() return require("azure-cli.chat.actions") end

send = function(text, opts) return RUN().send(text, opts) end
cancel = function(st) return RUN().cancel(st) end
M.send = send
function M.stop_tree(job) return RUN().stop_tree(job) end
-- Stops what conversation `c`'s agent is doing (the Agents screen's <C-c>).
function M.cancel_conversation(c) cancel(c) end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    pcall(function() require("azure-cli.chat.agents").reset() end)
    for _, c in ipairs(M.conversations()) do RUN().stop_persistent(c) end
    pcall(function() require("azure-cli.chat.bridge").stop() end)
  end,
})

new_chat = function(quiet) return ACT().new_chat(quiet) end
M.new_chat = new_chat
pick_model = function() return ACT().pick_model() end
M.pick_model = pick_model
history_step = function(dir) return ACT().history_step(dir) end
open_ref = function() return ACT().open_ref() end
ask_why = function() return ACT().ask_why() end
use_as_reply = function() return ACT().use_as_reply() end
show_help = function() return ACT().show_help() end
pick_agent = function() return ACT().pick_agent() end
pick_prompt = function() return ACT().pick_prompt() end
pick_history = function() return ACT().pick_history() end
show_audit = function() return ACT().show_audit() end

-- Binds the chat key on a screen's buffer (every azure-vicli screen calls
-- this for its own surface): normal mode goes to the chat, visual mode
-- sends the selection along with the next message.
function M.bind_toggle(buf, surface)
  local KEYS = require("azure-cli.keys")
  KEYS.bind(buf, surface, "chat", function() M.toggle() end, { desc = "go to the chat panel (opening it if needed)" })
  KEYS.bind(buf, surface, "chat", function() M.capture_selection() end,
    { desc = "ask the chat about the selected lines", mode = "x" })
  -- gP (the PR dashboard and the reviewer; the work-items board binds its
  -- own): an agent plans the fix of the PR's review comments.
  if surface ~= "workitems" and KEYS.resolve(surface, "plan_agents") then
    KEYS.bind(buf, surface, "plan_agents", function() M.plan_agents_here(0) end,
      { desc = "an agent plans the fix of this PR's comments (on a thread: that one)" })
    KEYS.bind(buf, surface, "plan_agents", function()
      local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
      if a > b then a, b = b, a end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      M.plan_agents_here(0, a, b)
    end, { desc = "an agent per selected PR, each planning the fix of its comments", mode = "x" })
  end
end

-- gP on a screen: the PR (and the comment thread, in the reviewer) under
-- the cursor - or every PR on rows `from`..`to` - each handed to an agent
-- of its own that plans the fix of its review comments (chat/agents.lua).
function M.plan_agents_here(win, from, to)
  win = (win == 0 or not win) and vim.api.nvim_get_current_win() or win
  local VIEW = require("azure-cli.chat.view")
  local prs, threads_of, seen = {}, {}, {}
  local cur = vim.api.nvim_win_get_cursor(win)
  for row = from or cur[1], to or cur[1] do
    if from then pcall(vim.api.nvim_win_set_cursor, win, { row, 0 }) end
    local snap = VIEW.snapshot(win)
    local pr = type(snap.pr) == "table" and snap.pr or nil
    if pr and pr.id and not seen[pr.id] then
      seen[pr.id] = true
      prs[#prs + 1] = require("azure-cli.chat.tools").pr_record(pr.id) or pr
      if not from and type(snap.thread) == "table" and snap.thread.id then threads_of[pr.id] = { snap.thread.id } end
    end
  end
  if from then pcall(vim.api.nvim_win_set_cursor, win, cur) end
  require("azure-cli.chat.agents").start_for_prs(prs, threads_of)
end

-- ---------------------------------------------------------------------------
-- Proactive.

-- A note in the conversation (no agent run).
function M.note(text)
  local st = STATE()
  restore_once()
  table.insert(st.entries, { role = "note", text = text })
  render()
  save()
end

-- The dashboard saw new comments on one of my PRs: suggest a triage in the
-- chat (chat.suggest_on_new_comments, on by default when an agent is set).
function M.on_new_comments(pr, count)
  if config().suggest_on_new_comments == false or not M.current_agent() then return end
  -- The chat's own PRs: chat/watch.lua says it (or plans the fix) itself.
  if require("azure-cli.chat.watch").watched(pr.id) then return end
  M.note("!" .. tostring(pr.id) .. " \"" .. tostring(pr.title or "") .. "\" got " .. tostring(count)
    .. " new comment" .. (count == 1 and "" or "s") .. " - open it and send /triage, or ask here.")
end

-- The PR dashboard loaded: once a day (chat.daily_summary), run /standup
-- in a fresh conversation and say it's ready.
function M.on_dashboard_loaded(dash_win)
  if not config().daily_summary or not M.current_agent() then return end
  local STORE = require("azure-cli.chat.store")
  local stamp = STORE.root() .. "/daily"
  local today = os.date("%Y-%m-%d")
  local ok, lines = pcall(vim.fn.readfile, stamp)
  if ok and lines[1] == today then return end
  if STATE().running then return end
  vim.fn.mkdir(STORE.root(), "p")
  pcall(vim.fn.writefile, { today }, stamp)
  new_chat(true)
  send("/standup", { view_win = dash_win, on_done = function()
    notify("Your daily summary is ready in the chat (" .. require("azure-cli.keys").name("dashboard", "chat") .. ").")
  end })
end

-- What chat/run.lua and chat/actions.lua need of this file's own (M._,
-- their I()): the conversation, drawing it, keeping it, confirming a tool
-- call, the input box and which entry / role a conversation line shows.
M._ = {
  state = STATE, render = render, render_soon = render_soon, save = save, confirm_for = confirm_for,
  ask_questions = M.ask_questions,
  tool_env = tool_env, input_text = input_text, restore_once = restore_once, group = group,
  load_conversation = load_conversation, focus_input = focus_input,
  input_buf = cur_input_buf,
  entry_at = cur_entry_at,
  role_at = cur_role_at,
}

return M
