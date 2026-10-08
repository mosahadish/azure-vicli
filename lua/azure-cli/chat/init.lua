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
-- The chosen agent (chat.agent, or one of chat.agents - ga switches) runs
-- headless and stays running for the whole conversation: either a CLI
-- reading one stream-json request per message on stdin (Claude Code's
-- --input-format stream-json), its events read as they arrive by
-- chat/core.lua's stream reader, or (agent.acp) an Agent Client Protocol
-- session (chat/acp.lua). Each message carries a description of what's
-- under the cursor (chat/view.lua) and of the PRs/work items it names
-- (chat/refs.lua); a process started mid-conversation (ga, gh, gm) gets
-- the conversation so far replayed to it. Conversations are saved
-- (chat/store.lua): the last one comes back after a restart, gh opens an
-- older one.
--
-- The agent's tools (chat/tools*.lua) reach Neovim through `azure-cli.py
-- --mcp` and chat/bridge.lua; their calls show in the conversation as they
-- happen, every change lands in an audit log (gL, u undoes), and the ones
-- that ask pop up a prompt (with the diff/text they'd send, when there is
-- one).
local M = {}

local CORE = require("azure-cli.chat.core")
for _, k in ipairs({ "PREAMBLE", "compose", "parse_answer", "expand", "render", "models" }) do
  M[k] = CORE[k]
end

local function STATE()
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
    models = {},         -- agent name -> model picked with gm
    agent_name = nil,    -- picked with ga
    sent = {},           -- what was sent, for <Up>/<Down> in the input box
    selection = nil,     -- { win, buf, from, to, text } from gq in visual mode
    restored = false,
  }
  return S.chat
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

-- The agent in use: name, spec - the one picked with ga, else
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

-- The model in use for `agent`: the one picked with gm (per agent) this
-- session, else agent.model, else the first of agent.models, else nil.
function M.current_model(agent)
  for name, a in pairs(M.agents()) do
    if a == agent and STATE().models[name] then return STATE().models[name] end
  end
  if agent and agent.model then return agent.model end
  local list = CORE.models(agent)
  return list[1] and list[1].value or nil
end

-- ---------------------------------------------------------------------------
-- Conversation persistence.

local function save()
  local st = STATE()
  if #st.entries == 0 then return end
  st.conv_id = st.conv_id or require("azure-cli.chat.store").new_id()
  st.created = st.created or os.time()
  pcall(require("azure-cli.chat.store").save, { id = st.conv_id, created = st.created, entries = st.entries,
    session_id = st.session_id, agent = (M.current_agent()), model = M.current_model(select(2, M.current_agent())) })
end

local function load_conversation(rec)
  local st = STATE()
  st.entries = rec.entries or {}
  st.session_id = rec.session_id
  st.conv_id = rec.id
  st.created = rec.created
  if rec.agent and M.agents()[rec.agent] then st.agent_name = rec.agent end
end

local function restore_once()
  local st = STATE()
  if st.restored then return end
  st.restored = true
  if #st.entries > 0 then return end
  local rec = require("azure-cli.chat.store").load_current()
  if rec then load_conversation(rec) end
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
  note = "AzureCliChatNote", intro = "AzureCliChatAgent",
}
local LINE_HL = {
  -- Your messages in your colour, the agent's own step log dimmed, so its
  -- answer stands out from both.
  you = "AzureCliChatYouText", agent_log = "AzureCliChatToolRead",
  tool_read = "AzureCliChatToolRead", tool_write = "AzureCliChatToolWrite", tool_err = "AzureCliChatToolErr",
  note = "AzureCliChatNote", intro = "AzureCliChatMeta",
}

local log_buf, input_buf
local ns = vim.api.nvim_create_namespace("azure_cli_chat")
local entry_at = {}

local function is_chat_buf(b) return b ~= nil and (b == log_buf or b == input_buf) end
M.is_chat_buf = is_chat_buf

local function render()
  if not (log_buf and vim.api.nvim_buf_is_valid(log_buf)) then return end
  local st = STATE()
  local lines, roles, name_end, at = CORE.render(st.entries, os.time(), agent_label())
  entry_at = at
  vim.bo[log_buf].modifiable = true
  vim.api.nvim_buf_set_lines(log_buf, 0, -1, false, lines)
  vim.bo[log_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(log_buf, ns, 0, -1)
  local function mark(row, col, opts) pcall(vim.api.nvim_buf_set_extmark, log_buf, ns, row, col, opts) end
  for i = 1, #lines do
    local role = roles[i]
    if role then
      mark(i - 1, 0, { sign_text = "\u{258E}", sign_hl_group = BAR[role] or "AzureCliChatAgent", priority = 10 })
      if role == "you_head" or role == "agent_head" then
        local cut = name_end[i] or #lines[i]
        mark(i - 1, 0, { end_col = cut, hl_group = role == "you_head" and "AzureCliChatYou" or "AzureCliChatAgent", priority = 200 })
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
local function spinner()
  local run = STATE().running
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

function M.set_winbars()
  local st = STATE()
  local tags = {}
  local _, agent = M.current_agent()
  local model = M.current_model(agent)
  if model then tags[#tags + 1] = "[" .. model .. "]" end
  if st.running then tags[#tags + 1] = "[" .. spinner() .. " working]" end
  if st.session_id then tags[#tags + 1] = "[session]" end
  if st.selection then tags[#tags + 1] = "[selection: " .. (st.selection.to - st.selection.from + 1) .. " lines]" end
  local UI = require("azure-cli.ui")
  for _, w in pairs(st.wins) do
    if w.log and vim.api.nvim_win_is_valid(w.log) then
      pcall(UI.wo, w.log, "winbar", UI.winbar({ "Chat", agent_label() }, tags))
    end
    if w.input and vim.api.nvim_win_is_valid(w.input) then
      local KEYS = require("azure-cli.keys")
      local send = KEYS.resolve("chat", "send")
      if type(send) == "table" then send = send[1] end
      pcall(UI.wo, w.input, "winbar", "%#Comment# " .. (send and (send .. " sends") or "")
        .. "  \u{00B7}  /prompt  \u{00B7}  !PR #item  \u{00B7}  ? keys")
    end
  end
  pcall(vim.cmd, "redrawstatus!")  -- for M.status() in a statusline
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
  use_as_reply, open_ref, history_step  -- forward

local function input_text()
  if not (input_buf and vim.api.nvim_buf_is_valid(input_buf)) then return "" end
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))
end

local function ensure_bufs()
  if log_buf and vim.api.nvim_buf_is_valid(log_buf) and input_buf and vim.api.nvim_buf_is_valid(input_buf) then return end
  restore_once()
  local KEYS = require("azure-cli.keys")
  log_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[log_buf].buftype = "nofile"
  vim.bo[log_buf].filetype = "markdown"
  vim.bo[log_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, log_buf, "azure-cli://chat")
  input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, input_buf, "azure-cli://chat-input")
  vim.b[log_buf].azure_cli_chat = true
  vim.b[input_buf].azure_cli_chat = true
  require("azure-cli.ui").link_hl(HL)
  vim.api.nvim_set_hl(0, "AzureCliChatName", { default = true, bold = true })
  -- The agent answers in markdown: render it with Neovim's bundled parser.
  pcall(vim.treesitter.start, log_buf, "markdown")

  local function focus_input()
    local w = (STATE().wins[vim.api.nvim_get_current_tabpage()] or {}).input
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_set_current_win(w)
      vim.cmd("startinsert!")
    end
  end
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
  KEYS.bind(log_buf, "chat", "open_ref", function() open_ref() end, { desc = "open the PR/work item under the cursor" })
  KEYS.bind(log_buf, "chat", "use_as_reply", function() use_as_reply() end, { desc = "draft this answer as a reply" })
  KEYS.bind(input_buf, "chat", "send", function() send() end, { desc = "send the message" })
  KEYS.bind(input_buf, "chat", "send_insert", function() vim.cmd("stopinsert") send() end,
    { desc = "send the message", mode = "i" })
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
  render()
end

-- The tabs the panel belongs in: azure-vicli's own screens.
local PLUGIN_FT = {
  ["azurecli-dashboard"] = true, ["azurecli-files"] = true, ["azurecli-workitems"] = true, ["azurecli-workitem"] = true,
  ["azurecli-changes"] = true,
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

function M.hide()
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
vim.api.nvim_create_autocmd({ "TabEnter", "BufWinEnter" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      local st = STATE()
      local tab = vim.api.nvim_get_current_tabpage()
      if st.visible and not panel_open_in(tab) and plugin_tab(tab) then open_here(false) end
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
local function confirm(question, cb, details)
  local win
  if details and #details > 0 then
    win = require("azure-cli.ui").open_float(details, { big = true, title = "Details", focus = false })
    local buf = win and vim.api.nvim_win_get_buf(win)
    if buf and (details[1] or ""):match("^diff ") then vim.bo[buf].filetype = "diff" end
  end
  notify(question .. " (answer in the prompt)")
  require("azure-cli.prompt").confirm({ prompt = question .. " Allow?", yes = "Allow", no = "Deny" }, function(yes)
    if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    cb(yes)
  end)
end
M.confirm = confirm

local function tool_env(entry)
  return {
    main_win = function() return entry.view_win and vim.api.nvim_win_is_valid(entry.view_win) and entry.view_win or M.main_win() end,
    -- What the user was looking at when they sent the message (selection
    -- included) - current_view answers with it.
    view = function() return entry.snap end,
    log = function(line)
      entry.tools = entry.tools or {}
      table.insert(entry.tools, line)
      render_soon()
    end,
    confirm = confirm,
  }
end

-- The MCP server definition every agent gets: one stdio server,
-- `azure-cli.py --mcp`, with the bridge's address and token in its
-- environment. write_mcp_config (most agents: a file, `env` as an
-- object) and acp_mcp_server (session/new's `mcpServers`: inline, `env`
-- as a list and a `name` field required there) both build on this.
local function mcp_server_def(addr, token)
  local CONFIG = require("azure-cli.config")
  local argv = CONFIG.provider_cmd()
  local env = { AZVICLI_CHAT_BRIDGE = addr, AZVICLI_CHAT_TOKEN = token }
  for _, k in ipairs({ "AZVICLI_CONFIG", "AZVICLI_ACCOUNTS_JSON", "AZVICLI_FAKE_WS" }) do
    if vim.env[k] and vim.env[k] ~= "" then env[k] = vim.env[k] end
  end
  return { command = argv[1], args = vim.list_extend(vim.list_slice(argv, 2), { "--mcp" }), env = env }
end

local function acp_mcp_server(addr, token)
  local def = mcp_server_def(addr, token)
  local env = {}
  for k, v in pairs(def.env) do table.insert(env, { name = k, value = v }) end
  return { name = "azure-vicli", command = def.command, args = def.args, env = env }
end

local function write_mcp_config(addr, token)
  local path = vim.fn.stdpath("cache") .. "/azure-cli/chat-mcp.json"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local cfg = { mcpServers = { ["azure-vicli"] = mcp_server_def(addr, token) } }
  vim.fn.writefile({ vim.json.encode(cfg) }, path)
  return path
end

-- Where the agent runs: the clone of the PR in view (so a repository's own
-- agent instructions and skills apply), else Neovim's cache directory.
local function agent_cwd(snap)
  local pr = snap and snap.pr
  if type(pr) == "table" then
    local TOOLS = require("azure-cli.chat.tools")
    local clone = TOOLS.clone_path(TOOLS.pr_record(pr.id) or pr)
    if clone ~= "" and vim.fn.isdirectory(clone) == 1 then return clone end
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
  if #bits > 0 then return "on " .. table.concat(bits, " \u{00B7} ") end
  if snap.screen and snap.screen ~= "other" and snap.screen ~= "unknown" then return "on the " .. snap.screen end
  return nil
end

local function bridge_handler(entry_ref)
  return function(req, reply)
    local TOOLS = require("azure-cli.chat.tools")
    if req.method == "list" then return reply({ tools = TOOLS.describe() }) end
    if req.method == "call" then
      local entry = entry_ref() or { tools = {} }
      return TOOLS.call(req.name, req.arguments, tool_env(entry), function(text, is_err)
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
-- stopped whenever the conversation it belongs to goes away from under it (ga, gh,
-- a new chat) or Neovim exits. An ACP connection's `.finish` (set by
-- send_acp's `running`) finalizes whatever message is still in flight -
-- stopping the process on its own would otherwise leave that entry's
-- status "running" forever, with `st.running` never cleared.
local function stop_persistent(st)
  local pj = st.persistent_job
  st.persistent_job = nil
  if not pj then return end
  if pj.finish then pcall(pj.finish, "stopped") end
  if pj.job then pcall(vim.fn.jobstop, pj.job) end
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
  M.set_winbars()
  st.running.timer = vim.fn.timer_start(120, function()
    local run = st.running
    if not run then return end
    run.tick = run.tick + 1
    if run.tick % 8 == 0 then render() else M.set_winbars() end
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
    save()
    if not panel_visible() then notify(agent_label() .. " answered in the chat (gq shows it).") end
    if opts.on_done then pcall(opts.on_done, entry) end
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
    confirm((tool.title or "The agent") .. " wants to " .. (tool.kind or "act"), function(yes)
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
        local model = M.current_model(agent)
        if model then
          pcall(conn.request, "session/set_config_option",
            { sessionId = pj.acp_session_id, configId = "model", value = model }, function() end)
        end
        send_prompt(pj)
      end)
    end)
  end)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function() stop_persistent(STATE()) end,
})

-- Sends `text` (default: the input box). opts.view_win overrides which
-- window "current view" describes; opts.quiet doesn't clear the input box.
send = function(text, opts)
  opts = opts or {}
  local st = STATE()
  restore_once()
  local from_input = text == nil
  if from_input then text = input_text() end
  if text == "" then return end
  if st.running then
    notify("The agent is still answering - wait, or stop it (<C-c>).", vim.log.levels.WARN)
    return
  end
  local agent_name, agent = M.current_agent()
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
  if from_input and input_buf and vim.api.nvim_buf_is_valid(input_buf) then
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
  end
  table.insert(st.sent, text)
  while #st.sent > 100 do table.remove(st.sent, 1) end
  st.sent_pos = nil

  local shown_text = text
  local expanded = CORE.expand_prompt(text, CORE.prompts(config().prompts))

  local VIEW = require("azure-cli.chat.view")
  local view_win = opts.view_win or M.main_win()
  local sel = st.selection
  if sel and not (vim.api.nvim_win_is_valid(sel.win) and sel.win == view_win) then sel = nil end
  st.selection = nil
  local snap = VIEW.snapshot(view_win, sel)
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
  BRIDGE.handler = bridge_handler(function() return entry end)
  render()

  local message = CORE.compose(expanded, view_text, {
    first = first, history = replay and history or nil,
    refs = require("azure-cli.chat.refs").describe(expanded),
  })
  local vars = {
    message = message, message_json = vim.json.encode(message), text = expanded,
    model = M.current_model(agent) or "",
    mcp_config = write_mcp_config(addr, token),
    mcp_server = agent.acp and acp_mcp_server(addr, token) or nil,
    view = view_text,
    fix_root = require("azure-cli.chat.tools_fix").root(),
  }
  vim.fn.mkdir(vars.fix_root, "p")

  if agent.acp then return send_acp(st, agent, agent_name, entry, message, snap, vars, reuse, opts) end

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
    save()
    if not panel_visible() then notify(agent_label() .. " answered in the chat (gq shows it).") end
    if opts.on_done then pcall(opts.on_done, entry) end
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
    local env = { AZVICLI_CHAT_BRIDGE = addr, AZVICLI_CHAT_TOKEN = token }
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

  st.running = { job = job, turn = turn }
  start_spinner(st)
  local timeout = tonumber(agent.timeout_seconds) or 900
  vim.defer_fn(function()
    if st.running and st.running.turn == turn then
      turn.cancelled = true
      table.insert(entry.tools, "\u{2717} timed out after " .. timeout .. "s")
      pcall(vim.fn.jobstop, job)
    end
  end, timeout * 1000)
end
M.send = send

cancel = function()
  local st = STATE()
  if not st.running then return notify("The agent isn't running.") end
  if st.running.acp then return st.running.cancel() end
  if st.running.turn then st.running.turn.cancelled = true end
  pcall(vim.fn.jobstop, st.running.job)
end

-- A fresh conversation (the current one stays in the history - gh).
new_chat = function(quiet)
  local st = STATE()
  if st.running then cancel() end
  stop_persistent(st)
  save()
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
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  local w = (st.wins[vim.api.nvim_get_current_tabpage()] or {}).input
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_set_cursor, w, { vim.api.nvim_buf_line_count(input_buf), #vim.api.nvim_buf_get_lines(input_buf, -2, -1, false)[1] })
  end
end

-- <CR> on !101 / #3001 in the conversation.
open_ref = function()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local ref = require("azure-cli.chat.refs").at(line, col)
  if not ref then return notify("Put the cursor on a !PR or #work-item reference.") end
  require("azure-cli.chat.refs").open(ref)
end

-- gr on an answer: open the comment editor prefilled with it, as a reply
-- to the thread its question was about (or a new PR comment), queued as a
-- batch-review draft on submit.
use_as_reply = function()
  local st = STATE()
  local idx = entry_at[vim.api.nvim_win_get_cursor(0)[1]]
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
      notify("Queued as a draft on PR !" .. pr.id .. " (gQ in the reviewer lists it, gS sends it).")
    end,
  })
end

show_help = function()
  local KEYS = require("azure-cli.keys")
  local lines = KEYS.help_lines("chat", "Chat keys", {
    "Talk",
    { "send", "send the message (in the input box)" }, { "send_insert", "send while typing" },
    { "focus_input", "type a message (in the conversation)" },
    { "prev_message", "the previous message you sent" }, { "next_message", "the next one" },
    { "prompts", "run a saved prompt (/name in the input box does the same)" },
    { "cancel", "stop the agent" },
    "Answers",
    { "open_ref", "open the !PR / #work item under the cursor" },
    { "use_as_reply", "draft the answer under the cursor as a reply (queued for gS)" },
    { "audit", "what the agent changed - u undoes one" },
    { "changes", "the agent's code change, file by file (like the reviewer: ]c / [c, gf, q)" },
    "Conversation",
    { "new_chat", "start a new conversation" }, { "history", "open an earlier conversation" },
    { "agent", "choose the agent" }, { "model", "choose the model" },
    "Panel",
    { "back", "back to the screen next to the chat" }, { "hide", "hide the chat (gq shows it again)" },
    { "toggle", "hide the chat - the same key on a screen takes you back to it" },
    { "resize_less", "make the chat smaller" }, { "resize_more", "make the chat bigger" },
    { "help", "this help" },
  }, { notes = {
    "The agent sees what you're looking at - the PR, work item, file, line, comment thread or selection "
      .. "(gq in visual mode) under the cursor - and the !PRs and #work items you name. Type ! or # for completion.",
  } })
  require("azure-cli.ui").open_float(lines, { min_width = 60 })
end

pick_model = function()
  local name, agent = M.current_agent()
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
  local cur = M.current_model(agent)
  require("azure-cli.prompt").select({ prompt = "Model for " .. (agent.label or name), items = list,
    current = function(m) return m.value == cur end }, function(choice)
    if not choice then return end
    local st = STATE()
    st.models[name] = choice.value
    -- The running process was started with the old model: the next
    -- message starts one with this model (the conversation replayed).
    if st.persistent_job then st.persistent_job.stale = true end
    M.set_winbars()
    notify("Chat model: " .. choice.label .. (uses and "" or " - but the agent's cmd has no {model}, so it can't pass it on."))
  end)
end
M.pick_model = pick_model

-- ga: switch agents. The other agent can't resume this one's session, so
-- the next message replays the conversation to it.
pick_agent = function()
  local agents = M.agents()
  local names = vim.tbl_keys(agents)
  table.sort(names)
  if #names < 2 then
    return notify("Only one agent is configured - add more under setup({ chat = { agents = { ... } } }).")
  end
  local cur = M.current_agent()
  require("azure-cli.prompt").select({ prompt = "Agent for the chat", items = names,
    format = function(n) return agents[n].label or n end, current = cur }, function(choice)
    if not choice or choice == cur then return end
    local st = STATE()
    stop_persistent(st)
    st.agent_name = choice
    st.session_id = nil
    M.set_winbars()
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
  require("azure-cli.prompt").select({ prompt = "Conversation", items = list,
    format = function(c)
      return os.date("%m-%d %H:%M", c.updated) .. "  " .. c.title .. "  (" .. c.turns .. " turns"
        .. (c.agent and (", " .. c.agent) or "") .. ")"
    end,
    current = function(c) return c.id == st.conv_id end }, function(choice)
    if not choice or choice.id == st.conv_id then return end
    if st.running then cancel() end
    stop_persistent(st)
    local rec = STORE.load(choice.id)
    if not rec then return notify("That conversation couldn't be read.", vim.log.levels.WARN) end
    load_conversation(rec)
    pcall(vim.fn.writefile, { rec.id }, STORE.root() .. "/current")
    render()
  end)
end

-- gL: the audit log - every change the agent made, newest first; u on one
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

-- Binds the chat key on a screen's buffer (every azure-vicli screen calls
-- this for its own surface): normal mode goes to the chat, visual mode
-- sends the selection along with the next message.
function M.bind_toggle(buf, surface)
  local KEYS = require("azure-cli.keys")
  KEYS.bind(buf, surface, "chat", function() M.toggle() end, { desc = "go to the chat panel (opening it if needed)" })
  KEYS.bind(buf, surface, "chat", function() M.capture_selection() end,
    { desc = "ask the chat about the selected lines", mode = "x" })
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
    notify("Your daily summary is ready in the chat (gq).")
  end })
end

return M
