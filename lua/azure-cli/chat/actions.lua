-- lua/azure-cli/chat/actions.lua: what the chat panel's keys do, for
-- chat/init.lua (which binds them): a new conversation, stepping through
-- what you sent before, opening a reference, asking why about a step,
-- drafting an answer as a reply, the help, the model / agent / prompt /
-- history pickers and the audit log with its undo.
--
-- chat/init.lua's own state comes through its M._ (I() here), the agent
-- through chat/run.lua - at call time, never while a file loads.
local M = {}

local CORE = require("azure-cli.chat.core")
local function CHAT() return require("azure-cli.chat") end
local function I() return require("azure-cli.chat")._ end
local function RUN() return require("azure-cli.chat.run") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function config() return require("azure-cli.config").get().chat or {} end
local function STATE() return I().state() end
local function render() return I().render() end
local function save(st) return I().save(st) end
local function agent_label() return CHAT().agent_label() end
local function send(text, opts) return RUN().send(text, opts) end
local function cancel(st) return RUN().cancel(st) end
local function stop_persistent(st) return RUN().stop_persistent(st) end

local new_chat, history_step, open_ref, ask_why, use_as_reply, show_help, pick_model, pick_agent,
  pick_prompt, pick_history, show_audit  -- forward

-- Forgets what's queued in conversation `st` (it's going away), saying so.
local function drop_queue(st, quiet)
  local n = #(st.queue or {})
  st.queue, st.queue_editing = nil, nil
  if n > 0 and not quiet then
    notify("Dropped " .. n .. " queued message" .. (n == 1 and "" or "s") .. " (<Up> in the input box brings "
      .. (n == 1 and "it" or "them") .. " back).")
  end
end

-- A fresh conversation (the current one stays in the history - gh).
new_chat = function(quiet)
  local st = STATE()
  if st.running then cancel() end
  stop_persistent(st)
  save()
  drop_queue(st, quiet)
  st.entries, st.session_id, st.conv_id, st.created = {}, nil, nil, nil
  require("azure-cli.chat.store").forget_current()
  render()
  if not quiet then notify("New conversation.") end
end
M.new_chat = new_chat

-- <Up>/<Down> in the input box: step through what was sent.
history_step = function(dir)
  local st = STATE()
  if #st.sent == 0 then return end
  local pos = (st.sent_pos or (#st.sent + 1)) + dir
  pos = math.max(1, math.min(#st.sent + 1, pos))
  st.sent_pos = pos
  local text = st.sent[pos] or ""
  vim.api.nvim_buf_set_lines(I().input_buf(), 0, -1, false, vim.split(text, "\n", { plain = true }))
  local w = (st.wins[vim.api.nvim_get_current_tabpage()] or {}).input
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_set_cursor, w, { vim.api.nvim_buf_line_count(I().input_buf()), #vim.api.nvim_buf_get_lines(I().input_buf(), -2, -1, false)[1] })
  end
end

-- The queued message under the cursor in the conversation (core.render's
-- "q<n>" lines): its index in st.queue and itself, or nil.
local function queued_here()
  local st = STATE()
  local at = I().entry_at()[vim.api.nvim_win_get_cursor(0)[1]]
  local n = type(at) == "string" and tonumber(at:match("^q(%d+)$"))
  local q = n and (st.queue or {})[n]
  if q then return n, q, st end
end

-- dd on a queued message: it won't be sent.
function M.queue_drop()
  local n, q, st = queued_here()
  if not n then return notify("Put the cursor on a queued message.") end
  table.remove(st.queue, n)
  if st.queue_editing == q then st.queue_editing = nil end
  render()
  notify("Cancelled the queued message.")
  -- One being edited might have been holding up the rest.
  RUN().drain(st)
end

-- cc on a queued message: back in the input box to change; sent again, it
-- keeps its place in the queue (chat/run.lua's requeue).
function M.queue_edit()
  local n, q, st = queued_here()
  if not n then return notify("Put the cursor on a queued message.") end
  local ib = I().input_buf()
  if not (ib and vim.api.nvim_buf_is_valid(ib)) then return end
  local draft = I().input_text()
  if draft ~= "" and draft ~= q.text then
    return notify("The input box has a message in it - send or clear it first.", vim.log.levels.WARN)
  end
  if st.queue_editing and st.queue_editing ~= q then st.queue_editing.editing = nil end
  q.editing, st.queue_editing = true, q
  vim.api.nvim_buf_set_lines(ib, 0, -1, false, vim.split(q.text, "\n", { plain = true }))
  render()
  I().focus_input()
end

-- <CR> on !101 / #3001 in the conversation - or on a queued message: send
-- it now (the agent free), or once this answer is done (held after <C-c>).
open_ref = function()
  local n, q, st = queued_here()
  if n then
    if q.editing then return notify("It's in the input box - send it from there.") end
    if st.running then
      q.held = nil
      render()
      return notify("It goes when this answer is done.")
    end
    return RUN().send_queued(st, n)
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local ref = require("azure-cli.chat.refs").at(line, col)
  if not ref then return notify("Put the cursor on a !PR or #work-item reference.") end
  require("azure-cli.chat.refs").open(ref)
end

-- ga on one of the agent's steps (a tool call line) or a line of its
-- answer: ask it why, quoting that line and the message it answered.
ask_why = function()
  local st = STATE()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local idx, role = I().entry_at()[row], I().role_at()[row]
  local e = idx and st.entries[idx]
  if not (e and e.role == "agent") then return notify("Put the cursor on one of the agent's steps or answers.") end
  local quote = vim.trim(vim.api.nvim_get_current_line())
  if quote == "" then return notify("Put the cursor on a line with something on it.") end
  local asked
  for i = idx - 1, 1, -1 do
    if st.entries[i].role == "you" then asked = st.entries[i].text break end
  end
  local kind = (role == "tool_read" or role == "tool_write" or role == "tool_err" or role == "agent_log") and "step" or "line"
  if st.running then return notify("The agent is still answering - ask once it's done.", vim.log.levels.WARN) end
  require("azure-cli.editor").open({
    title = "Ask " .. agent_label() .. " why",
    anchor = { win = vim.api.nvim_get_current_win(), row = row }, context_lines = { quote },
    on_submit = function(q)
      send(CORE.why_message(quote, kind, asked, q), { display = q .. "  (about: " .. (#quote > 60 and (quote:sub(1, 57) .. "...")
        or quote) .. ")" })
    end,
  })
end

-- gr on an answer: open the comment editor prefilled with it, as a reply
-- to the thread its question was about (or a new PR comment), queued as a
-- batch-review draft on submit.
use_as_reply = function()
  local st = STATE()
  local idx = I().entry_at()[vim.api.nvim_win_get_cursor(0)[1]]
  local e = idx and st.entries[idx]
  if not (e and e.role == "agent" and (e.text or "") ~= "") then
    return notify("Put the cursor on one of the agent's answers.")
  end
  local view
  for i = idx - 1, 1, -1 do
    if st.entries[i].role == "you" then view = st.entries[i].view break end
  end
  local pr = view and view.pr
  if not pr then return notify("That answer wasn't about a pull request - nothing to reply on.", vim.log.levels.WARN) end
  local thread = view.thread
  local TOOLS = require("azure-cli.chat.tools")
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = thread and ("Reply \u{00B7} thread " .. tostring(thread.id)) or ("PR comment \u{00B7} !" .. tostring(pr.id)),
    initial = e.text, anchor = "center",
    on_submit = function(text)
      local item = thread and { kind = "reply", thread_id = thread.id, text = text }
        or { kind = "thread", args = { "--pr-comment", text }, bucket = "general", text = text, label = "PR comment" }
      TOOLS.queue_draft(pr.id, item)
      local KEYS = require("azure-cli.keys")
      notify("Queued as a draft on PR !" .. pr.id .. " (" .. KEYS.name("list", "batch_queue") .. " in the reviewer lists it, "
        .. KEYS.name("list", "batch_submit") .. " sends it).")
    end,
  })
end

show_help = function()
  local KEYS = require("azure-cli.keys")
  local screen_chat = KEYS.name("dashboard", "chat_input")  -- the chat key on a screen (each has one)
  local screen_sel = KEYS.name("dashboard", "chat_selection")  -- and on a selection
  local lines = KEYS.help_lines("chat", "Chat keys", {
    "Talk",
    { "send", "send the message (in the input box)" }, { "send_insert", "send while typing" },
    { "newline", "a new line while typing" },
    { "focus_input", "type a message (in the conversation)" },
    { "prev_message", "the previous message you sent" }, { "next_message", "the next one" },
    { "prompts", "run a saved prompt (/name in the input box does the same)" },
    { "cancel", "stop the agent (what you queued is held until you send it)" },
    "Queued (sent while the agent answers)",
    { "queue_drop", "cancel the queued message under the cursor" },
    { "queue_edit", "edit it in the input box; sending puts it back in its place" },
    "Answers",
    { "open_ref", "open the !PR / #work item under the cursor (on a queued message: send it)" },
    { "use_as_reply", "draft the answer under the cursor as a reply (queued for "
      .. KEYS.name("list", "batch_submit") .. ")" },
    { "why", "ask the agent why it did the step (or wrote the line) under the cursor" },
    { "expand", "unfold a long answer or a list of tool calls (again: fold it)" },
    { "audit", "what the agent changed - u undoes one" },
    { "changes", "the agent's code change, file by file (like the reviewer: "
      .. KEYS.name("diff", "next_hunk") .. " / " .. KEYS.name("diff", "prev_hunk") .. ", "
      .. KEYS.name("diff", "open_file") .. ", " .. KEYS.name("diff", "quit") .. ")" },
    { "agents", "every plan's agent: what each is doing (the Agents screen)" },
    "Conversation",
    { "new_chat", "start a new conversation" }, { "history", "open an earlier conversation" },
    { "agent", "choose the agent" }, { "model", "choose the model" },
    "Panel",
    { "back", "back to the screen next to the chat" }, { "hide", "hide the chat (" .. screen_chat .. " shows it again)" },
    { "resize_less", "make the chat smaller" }, { "resize_more", "make the chat bigger" },
    { "help", "this help" },
  }, { notes = {
    "The agent sees what you're looking at - the PR, work item, file, line, comment thread or selection "
      .. "(" .. screen_sel .. " in visual mode) under the cursor - and the !PRs and #work items you name. Type ! or # for completion.",
  } })
  require("azure-cli.ui").open_float(lines, { min_width = 60 })
end

pick_model = function()
  local name, agent = CHAT().current_agent()
  local list = CORE.models(agent)
  if #list == 0 then
    return notify("No models to choose from - list them in the agent's `models` and put {model} in its cmd.",
      vim.log.levels.WARN)
  end
  -- An ACP agent gets the model through session/set_config_option.
  local uses = agent.acp == true
  for _, part in ipairs(type(agent.cmd) == "table" and agent.cmd or { agent.cmd or "" }) do
    if tostring(part):find("{model}", 1, true) then uses = true end
  end
  local cur = CHAT().current_model(agent)
  require("azure-cli.prompt").select({ prompt = "Model for " .. (agent.label or name), items = list,
    current = function(m) return m.value == cur end }, function(choice)
    if not choice then return end
    -- This conversation's only: the main chat's, or the agent's in the
    -- plan you're looking at. The next message uses it (an ACP agent
    -- switches in its session; another starts again on it).
    local st = STATE()
    st.model, st.model_agent = choice.value, name
    CHAT().set_winbars()
    notify((st.plan_key and ("Model for " .. (st.label or st.plan_key) .. "'s agent: ") or "Chat model: ") .. choice.label
      .. (uses and "" or " - but the agent's cmd has no {model}, so it can't pass it on."))
  end)
end
M.pick_model = pick_model

-- gM: switch agents. The other agent can't resume this one's session, so
-- the next message replays the conversation to it.
pick_agent = function()
  local agents = CHAT().agents()
  local names = vim.tbl_keys(agents)
  table.sort(names)
  if #names < 2 then
    return notify("Only one agent is configured - add more under setup({ chat = { agents = { ... } } }).")
  end
  local cur = CHAT().current_agent()
  require("azure-cli.prompt").select({ prompt = "Agent for the chat", items = names,
    format = function(n) return agents[n].label or n end, current = cur }, function(choice)
    if not choice or choice == cur then return end
    local st = STATE()
    stop_persistent(st)
    st.agent_name = choice
    st.session_id = nil
    st.model, st.model_agent = nil, nil
    CHAT().set_winbars()
    notify("Chat agent: " .. (agents[choice].label or choice) .. " - it gets the conversation so far with your next message.")
  end)
end

-- gp: run a saved prompt, about whatever is on screen.
pick_prompt = function()
  local prompts = CORE.prompts(config().prompts)
  local names = vim.tbl_keys(prompts)
  table.sort(names)
  if #names == 0 then return notify("No saved prompts.") end
  require("azure-cli.prompt").select({ prompt = "Saved prompt", items = names,
    format = function(n)
      local t = prompts[n]:gsub("%s+", " ")
      return "/" .. n .. "  " .. (#t > 70 and (t:sub(1, 67) .. "...") or t)
    end }, function(choice)
    if choice then send("/" .. choice) end
  end)
end

-- gh: back to an earlier conversation.
pick_history = function()
  local STORE = require("azure-cli.chat.store")
  save()
  local list = STORE.list()
  if #list == 0 then return notify("No saved conversations yet.") end
  local st = STATE()
  require("azure-cli.prompt").select({ prompt = "Conversation", items = list, search = true,
    format = function(c)
      return os.date("%m-%d %H:%M", c.updated) .. "  " .. c.title .. "  (" .. c.turns .. " turns"
        .. (c.agent and (", " .. c.agent) or "") .. ")"
    end,
    current = function(c) return c.id == st.conv_id end }, function(choice)
    if not choice or choice.id == st.conv_id then return end
    if st.running then cancel() end
    stop_persistent(st)
    drop_queue(st)
    local rec = STORE.load(choice.id)
    if not rec then return notify("That conversation couldn't be read.", vim.log.levels.WARN) end
    I().load_conversation(rec)
    pcall(vim.fn.writefile, { rec.id }, STORE.root() .. "/current")
    render()
  end)
end

-- gH: the audit log - every change the agent made, newest first; u on one
-- undoes it (when it can be).
show_audit = function()
  local STORE = require("azure-cli.chat.store")
  local items = STORE.audit()
  if #items == 0 then return notify("The agent hasn't changed anything yet.") end
  local order = {}
  for i = #items, 1, -1 do order[#order + 1] = i end
  local function lines()
    local out = {}
    for _, i in ipairs(order) do
      local it = items[i]
      out[#out + 1] = os.date("%m-%d %H:%M", it.at or 0) .. "  " .. it.tool .. "  " .. (it.summary or "")
        .. (it.undone and "  [undone]" or (it.undo and "" or "  [can't undo]"))
    end
    return out
  end
  local win, buf = require("azure-cli.ui").open_float(lines(), { big = true, title = "What the agent changed",
    footer = "u undo" })
  if not win then return end
  vim.keymap.set("n", "u", function()
    local i = order[vim.api.nvim_win_get_cursor(win)[1]]
    local it = i and items[i]
    if not it then return end
    if it.undone then return notify("Already undone.") end
    require("azure-cli.chat.tools").undo(it, function(ok, msg)
      notify(msg or (ok and "Undone." or "Couldn't undo it."), ok and vim.log.levels.INFO or vim.log.levels.WARN)
      if ok then
        STORE.audit_mark_undone(i)
        it.undone = os.time()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines())
          vim.bo[buf].modifiable = false
        end
      end
    end)
  end, { buffer = buf, silent = true, nowait = true })
end

M.history_step, M.open_ref, M.ask_why, M.use_as_reply, M.show_help = history_step, open_ref, ask_why,
  use_as_reply, show_help
M.pick_agent, M.pick_prompt, M.pick_history, M.show_audit = pick_agent, pick_prompt, pick_history, show_audit

return M
