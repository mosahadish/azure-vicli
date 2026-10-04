-- lua/azure-cli/chat/init.lua: the chat panel - an agent (Claude Code, the
-- Copilot CLI, ...) you talk to from inside azure-vicli, which sees what you
-- see and can act on it.
--
-- The panel is a split next to whatever azure-vicli screen you're on: the
-- conversation on top, a small input box below. `gq` (any screen) shows or
-- hides it; once shown it follows you into every azure-vicli tab (PR
-- dashboard, reviewer, work items) until hidden again. setup({ chat = {
-- position, size, ... } }) places it.
--
-- Sending a message runs the configured agent headless (chat.agent: a
-- command template, like an agent action's) with the message on stdin,
-- prefixed by a description of what you're looking at (chat/view.lua).
-- Later messages resume the agent's own session when chat.agent.followup
-- says how ({session_id} from Claude Code's JSON output, or
-- session_pattern), and otherwise replay the conversation so far.
--
-- The agent gets an MCP server ({mcp_config}: `azure-cli.py --mcp`) whose
-- tools (chat/tools.lua) read the PR list, threads, diffs and work items
-- and act - link, create a branch, draft replies into the batch-review
-- queue directly; vote and change a work item's state only after you say
-- yes. Tool calls show in the conversation as they happen.
local M = {}

local function STATE()
  local S = require("azure-cli.state")
  S.chat = S.chat or {
    entries = {},        -- { role = "you"|"agent"|"note", text, lines, tools = {}, status, view }
    session_id = nil,
    visible = false,
    wins = {},           -- tabpage -> { log = win, input = win }
    main_win = {},       -- tabpage -> the last non-chat window
    running = nil,       -- { job, entry, started }
  }
  return S.chat
end

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function config() return require("azure-cli.config").get().chat or {} end

M.PREAMBLE = [[You are the assistant inside azure-vicli, a Neovim plugin for Azure DevOps pull requests and work items. The user talks to you from a chat panel next to the screen they're on. Each message starts with "Current view", describing what they are looking at; "this PR", "this comment" and "this work item" mean what it names.

Use the azure-vicli tools to look things up (current_view, list_pull_requests, get_pull_request, get_pr_threads, get_pr_diff, list_work_items, get_work_item) and to act (link_pr_to_work_item, create_branch, draft_reply, draft_comment, vote, set_work_item_state). Drafts are queued for the user to review, never posted. Answer briefly, in markdown.]]

-- ---------------------------------------------------------------------------
-- Pure helpers.

-- The text sent to the agent for one message: the preamble (first message
-- only, or every replayed one), the earlier conversation (replay only),
-- the current view and the message. Pure.
function M.compose(message, view_text, opts)
  opts = opts or {}
  local parts = {}
  if opts.first or opts.history then parts[#parts + 1] = M.PREAMBLE end
  if opts.history and #opts.history > 0 then
    parts[#parts + 1] = "## The conversation so far"
    for _, e in ipairs(opts.history) do
      if e.role == "you" then
        parts[#parts + 1] = "User: " .. e.text
      elseif e.role == "agent" and e.text and e.text ~= "" then
        parts[#parts + 1] = "You: " .. e.text
      end
    end
  end
  parts[#parts + 1] = "## Current view\n" .. (view_text or "(unknown)")
  parts[#parts + 1] = "## Message\n" .. message
  return table.concat(parts, "\n\n")
end

-- The agent's answer out of its stdout: Claude Code's --output-format json
-- envelope ({ "result", "session_id" }) unwrapped, else the text as-is;
-- `pattern` (chat.agent.session_pattern) finds a session id in plain
-- output. Returns text, session_id. `decode` is vim.json.decode at runtime.
function M.parse_answer(out, err, decode, pattern)
  local text = (out or ""):gsub("\r\n", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  local session
  if text:sub(1, 1) == "{" then
    local ok, d = pcall(decode, text)
    if ok and type(d) == "table" and type(d.result) == "string" then
      text = d.result:gsub("^%s+", ""):gsub("%s+$", "")
      session = type(d.session_id) == "string" and d.session_id or nil
      if d.is_error == true and text == "" then text = "(the agent reported an error)" end
    end
  end
  if not session and type(pattern) == "string" and pattern ~= "" then
    for _, s in ipairs({ out or "", err or "" }) do
      local ok, id = pcall(string.match, s, pattern)
      if ok and type(id) == "string" and id ~= "" then session = id break end
    end
  end
  return text, session
end

-- Whether a message can resume the agent's session: a followup is set and
-- either doesn't need {session_id} or there is one.
function M.can_resume(agent, session)
  local f = agent and agent.followup
  if not f then return false end
  local needs = false
  for _, part in ipairs(type(f.cmd) == "table" and f.cmd or { f.cmd }) do
    if tostring(part):find("{session_id}", 1, true) then needs = true end
  end
  if (f.stdin or ""):find("{session_id}", 1, true) then needs = true end
  return not needs or (session ~= nil and session ~= "")
end

local function expand(template, vars, quote)
  if type(template) ~= "string" then return template end
  return (template:gsub("{([%w_]+)}", function(name)
    local v = vars[name]
    if v == nil then return nil end
    v = tostring(v)
    return quote and quote(v) or v
  end))
end
M.expand = expand

-- The transcript as lines, plus what each line is, for colouring: a
-- "You" / "<agent>" heading per turn (the name, then a dimmer " · on PR
-- #101" / " · working… 4s"), your text, the agent's tool calls as they
-- happen, then its markdown answer. Returns lines, roles (line -> one of
-- you_head, you, agent_head, agent, tool_read, tool_write, tool_err,
-- note, intro; nil for the gap between turns) and name_end (heading line
-- -> byte where its dim part starts). Pure (`now` injected).
function M.render(entries, now, agent_label)
  local lines, roles, name_end = {}, {}, {}
  local function add(l, role) lines[#lines + 1] = l; roles[#lines] = role end
  local function add_text(t, role) for l in ((t or "") .. "\n"):gmatch("(.-)\n") do add(l, role) end end
  local function head(name, extra, role)
    add(name .. (extra ~= "" and ("  \u{00B7}  " .. extra) or ""), role)
    name_end[#lines] = #name
  end
  if #entries == 0 then
    add("Chat", "agent_head")
    name_end[1] = 4
    add("", "intro")
    add_text("Ask about what you're looking at - \"triage this PR's comments\", \"what do you think about "
      .. "this comment?\", \"create a branch from develop for this work item\".\nType below; <CR> sends.", "intro")
    return lines, roles, name_end
  end
  for i, e in ipairs(entries) do
    if i > 1 then add("", nil) end
    if e.role == "you" then
      head("You", e.where or "", "you_head")
      add_text(e.text, "you")
    elseif e.role == "agent" then
      local bits = {}
      if e.status == "running" then
        bits[#bits + 1] = "working\u{2026} " .. math.max(0, (now or 0) - (e.started or now or 0)) .. "s"
      elseif e.status and e.status ~= "done" then
        bits[#bits + 1] = e.status
      end
      if e.mode == "replay" then bits[#bits + 1] = "replayed" end
      head(agent_label or "Agent", table.concat(bits, "  \u{00B7}  "), "agent_head")
      for _, t in ipairs(e.tools or {}) do
        local role = t:find("^\u{2717}") and "tool_err" or (t:find("^\u{270E}") and "tool_write" or "tool_read")
        add("  " .. t, role)
      end
      if #(e.tools or {}) > 0 and (e.text or "") ~= "" then add("", "agent") end
      if e.text and e.text ~= "" then add_text(e.text, "agent") end
    else
      add_text(e.text or "", "note")
    end
  end
  return lines, roles, name_end
end

-- Highlight groups the chat uses, all links (so a colorscheme can restyle
-- them): the bar down each turn and its heading per speaker, tool calls by
-- kind.
local HL = {
  AzureCliChatYou = "Function", AzureCliChatAgent = "String", AzureCliChatMeta = "Comment",
  AzureCliChatToolRead = "Comment", AzureCliChatToolWrite = "DiagnosticWarn", AzureCliChatToolErr = "DiagnosticError",
  AzureCliChatNote = "DiagnosticInfo", AzureCliChatYouText = "Normal",
}
local BAR = {
  you_head = "AzureCliChatYou", you = "AzureCliChatYou",
  agent_head = "AzureCliChatAgent", agent = "AzureCliChatAgent",
  tool_read = "AzureCliChatAgent", tool_write = "AzureCliChatAgent", tool_err = "AzureCliChatAgent",
  note = "AzureCliChatNote", intro = "AzureCliChatAgent",
}
local LINE_HL = {
  tool_read = "AzureCliChatToolRead", tool_write = "AzureCliChatToolWrite", tool_err = "AzureCliChatToolErr",
  note = "AzureCliChatNote", intro = "AzureCliChatMeta", you = "AzureCliChatYouText",
}

-- ---------------------------------------------------------------------------
-- Buffers and windows.

local log_buf, input_buf
local ns = vim.api.nvim_create_namespace("azure_cli_chat")

local function is_chat_buf(b) return b == log_buf or b == input_buf end

local function agent_label()
  local a = config().agent
  return (a and a.label) or "Agent"
end

-- chat.agent.models as { label, value } pairs: a string is both.
function M.models(agent)
  local out = {}
  for _, m in ipairs((agent and agent.models) or {}) do
    if type(m) == "string" then out[#out + 1] = { label = m, value = m }
    elseif type(m) == "table" and m.value then out[#out + 1] = { label = m.label or m.value, value = m.value } end
  end
  return out
end

-- The model in use: the one picked with gm this session, else
-- chat.agent.model, else the first of chat.agent.models, else nil (the
-- agent's own default).
function M.current_model(agent)
  local picked = STATE().model
  if picked then return picked end
  if agent and agent.model then return agent.model end
  local list = M.models(agent)
  return list[1] and list[1].value or nil
end

local function render()
  if not (log_buf and vim.api.nvim_buf_is_valid(log_buf)) then return end
  local st = STATE()
  local lines, roles, name_end = M.render(st.entries, os.time(), agent_label())
  vim.bo[log_buf].modifiable = true
  vim.api.nvim_buf_set_lines(log_buf, 0, -1, false, lines)
  vim.bo[log_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(log_buf, ns, 0, -1)
  for i = 1, #lines do
    local role = roles[i]
    if role then
      -- A coloured bar down the left of each turn, in its speaker's colour.
      pcall(vim.api.nvim_buf_set_extmark, log_buf, ns, i - 1, 0, {
        sign_text = "\u{258E}", sign_hl_group = BAR[role] or "AzureCliChatAgent", priority = 10,
      })
      if role == "you_head" or role == "agent_head" then
        local cut = name_end[i] or #lines[i]
        pcall(vim.api.nvim_buf_set_extmark, log_buf, ns, i - 1, 0, {
          end_col = cut, hl_group = role == "you_head" and "AzureCliChatYou" or "AzureCliChatAgent", priority = 200,
        })
        if cut < #lines[i] then
          pcall(vim.api.nvim_buf_set_extmark, log_buf, ns, i - 1, cut, {
            end_col = #lines[i], hl_group = "AzureCliChatMeta", priority = 200,
          })
        end
        pcall(vim.api.nvim_buf_set_extmark, log_buf, ns, i - 1, 0, { line_hl_group = "CursorLine", priority = 5 })
      elseif LINE_HL[role] then
        pcall(vim.api.nvim_buf_set_extmark, log_buf, ns, i - 1, 0, {
          end_col = #lines[i], hl_group = LINE_HL[role], priority = 200,
        })
      end
    end
  end
  -- Keep every chat window scrolled to the end.
  for _, w in pairs(st.wins) do
    if w.log and vim.api.nvim_win_is_valid(w.log) and vim.api.nvim_get_current_win() ~= w.log then
      pcall(vim.api.nvim_win_set_cursor, w.log, { #lines, 0 })
    end
  end
  M.set_winbars()
end
M.render_now = render

function M.set_winbars()
  local st = STATE()
  local tags = {}
  local model = M.current_model(config().agent)
  if model then tags[#tags + 1] = "[" .. model .. "]" end
  if st.running then tags[#tags + 1] = "[working\u{2026}]" end
  if st.session_id then tags[#tags + 1] = "[session]" end
  local UI = require("azure-cli.ui")
  for _, w in pairs(st.wins) do
    if w.log and vim.api.nvim_win_is_valid(w.log) then
      pcall(UI.wo, w.log, "winbar", UI.winbar({ "Chat", agent_label() }, tags))
    end
    if w.input and vim.api.nvim_win_is_valid(w.input) then
      local KEYS = require("azure-cli.keys")
      local send = KEYS.resolve("chat", "send")
      if type(send) == "table" then send = send[1] end
      pcall(UI.wo, w.input, "winbar", "%#Comment# " .. (send and (send .. " sends") or "") .. "  \u{00B7}  ? keys")
    end
  end
end

-- The window the user was last in, in the current tab (never the panel).
function M.main_win()
  local st = STATE()
  local tab = vim.api.nvim_get_current_tabpage()
  local w = st.main_win[tab]
  -- Never the panel itself: a split briefly shows the buffer it was split
  -- from, so a WinEnter on it can have recorded a window that became the
  -- chat's a moment later.
  if w and vim.api.nvim_win_is_valid(w) and not is_chat_buf(vim.api.nvim_win_get_buf(w)) then return w end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if not is_chat_buf(vim.api.nvim_win_get_buf(win)) and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return vim.api.nvim_get_current_win()
end

local send, cancel, new_chat, show_help, pick_model  -- forward

local function ensure_bufs()
  if log_buf and vim.api.nvim_buf_is_valid(log_buf) and input_buf and vim.api.nvim_buf_is_valid(input_buf) then return end
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
  require("azure-cli.ui").link_hl(HL)
  -- The agent answers in markdown: render it (headings, **bold**, `code`,
  -- lists) with Neovim's bundled markdown parser when there is one, falling
  -- back to the regex syntax the filetype already gives.
  pcall(vim.treesitter.start, log_buf, "markdown")
  vim.b[input_buf].azure_cli_chat = true
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
    KEYS.bind(b, "chat", "help", function() show_help() end, { desc = "chat keys" })
    KEYS.bind(b, "chat", "model", function() pick_model() end, { desc = "choose the model" })
    KEYS.bind(b, "chat", "back", function()
      local w = M.main_win()
      if w and vim.api.nvim_win_is_valid(w) then vim.api.nvim_set_current_win(w) end
    end, { desc = "back to the screen next to the chat" })
  end
  KEYS.bind(log_buf, "chat", "focus_input", focus_input, { desc = "type a message" })
  KEYS.bind(input_buf, "chat", "send", function() send() end, { desc = "send the message" })
  KEYS.bind(input_buf, "chat", "send_insert", function() vim.cmd("stopinsert") send() end,
    { desc = "send the message", mode = "i" })
  render()
end

-- The tabs the panel belongs in: azure-vicli's own screens.
local PLUGIN_FT = {
  ["azurecli-dashboard"] = true, ["azurecli-files"] = true, ["azurecli-workitems"] = true, ["azurecli-workitem"] = true,
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

-- Opens the panel in the current tab (no-op when it's there already).
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
  local size = cfg.size or (vertical and 0.35 or 0.3)
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
  -- are hidden (except on the cursor line, so the text can still be read
  -- and yanked as written).
  UI.wo(log, "signcolumn", "yes:1")
  UI.wo(log, "conceallevel", 2)
  UI.wo(log, "concealcursor", "")
  UI.wo(input, "winfixheight", true)
  st.wins[tab] = { log = log, input = input }
  -- The splits above fired WinEnter while still showing the screen's
  -- buffer, so the "last window" tracking recorded the new panel windows:
  -- what the chat describes is the window gq was pressed in.
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

-- gq: shows the panel, focused and ready to type, or hides it when it's
-- showing.
function M.toggle()
  local st = STATE()
  if st.visible and panel_open_in(vim.api.nvim_get_current_tabpage()) then return M.hide() end
  M.show(true)
end

-- Follow the user into every azure-vicli tab while visible, and remember
-- the last non-chat window per tab (what "current view" describes).
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
          -- Closed by hand (:q, <C-w>c) while its tab lives on: that's
          -- hiding it, or it would come straight back on the next
          -- BufWinEnter. A whole tab closing (leaving the reviewer) isn't.
          if vim.api.nvim_tabpage_is_valid(tab) then STATE().visible = false end
        end)
        STATE().wins[tab] = nil
      end
    end
  end,
})

-- ---------------------------------------------------------------------------
-- Talking to the agent.

local function tool_env(entry)
  return {
    main_win = function() return entry.view_win and vim.api.nvim_win_is_valid(entry.view_win) and entry.view_win or M.main_win() end,
    log = function(line)
      entry.tools = entry.tools or {}
      table.insert(entry.tools, line)
      render()
    end,
    confirm = function(question, cb)
      notify(question .. " (answer in the prompt)")
      require("azure-cli.prompt").confirm({ prompt = question .. " Allow?", yes = "Allow", no = "Deny" }, cb)
    end,
  }
end

-- The MCP config handed to the agent: one stdio server, `azure-cli.py
-- --mcp`, with the bridge's address and token in its environment.
local function write_mcp_config(addr, token)
  local CONFIG = require("azure-cli.config")
  local argv = CONFIG.provider_cmd()
  local path = vim.fn.stdpath("cache") .. "/azure-cli/chat-mcp.json"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local env = { AZVICLI_CHAT_BRIDGE = addr, AZVICLI_CHAT_TOKEN = token }
  for _, k in ipairs({ "AZVICLI_CONFIG", "AZVICLI_ACCOUNTS_JSON", "AZVICLI_FAKE_WS" }) do
    if vim.env[k] and vim.env[k] ~= "" then env[k] = vim.env[k] end
  end
  local cfg = { mcpServers = { ["azure-vicli"] = {
    command = argv[1], args = vim.list_extend(vim.list_slice(argv, 2), { "--mcp" }), env = env,
  } } }
  vim.fn.writefile({ vim.json.encode(cfg) }, path)
  return path
end

-- Where the agent runs: the clone of the PR in view (so a repository's own
-- agent instructions and skills apply), else Neovim's cache directory.
local function agent_cwd(snap)
  local pr = snap and snap.pr
  if type(pr) == "table" then
    local rec
    for _, p in ipairs((require("azure-cli.state").PR_LIST_CACHE or {}).prs or {}) do
      if tostring(p.id) == tostring(pr.id) then rec = p break end
    end
    local clone = require("azure-cli.chat.tools").clone_path(rec or pr)
    if clone ~= "" and vim.fn.isdirectory(clone) == 1 then return clone end
  end
  local dir = vim.fn.stdpath("cache") .. "/azure-cli"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function where_label(snap)
  local bits = {}
  if type(snap.pr) == "table" then bits[#bits + 1] = "PR #" .. tostring(snap.pr.id) end
  if type(snap.work_item) == "table" then bits[#bits + 1] = "#" .. tostring(snap.work_item.id) end
  if snap.file then bits[#bits + 1] = vim.fn.fnamemodify(snap.file, ":t") .. (snap.line and (":" .. snap.line) or "") end
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

send = function(text)
  local st = STATE()
  if not text then
    if not (input_buf and vim.api.nvim_buf_is_valid(input_buf)) then return end
    text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))
  end
  if text == "" then return end
  if st.running then
    notify("The agent is still answering - wait, or stop it (<C-c>).", vim.log.levels.WARN)
    return
  end
  local agent = config().agent
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
  if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
  end

  local VIEW = require("azure-cli.chat.view")
  local view_win = M.main_win()
  local snap = VIEW.snapshot(view_win)
  local history = {}
  for _, e in ipairs(st.entries) do if e.role ~= "note" then history[#history + 1] = e end end
  local first = #history == 0
  local resume = not first and M.can_resume(agent, st.session_id)
  table.insert(st.entries, { role = "you", text = text, where = where_label(snap) })
  local entry = { role = "agent", status = "running", started = os.time(), tools = {}, view_win = view_win,
    mode = (not first and not resume) and "replay" or nil }
  table.insert(st.entries, entry)
  BRIDGE.handler = bridge_handler(function() return entry end)
  render()

  local message = M.compose(text, VIEW.text(snap), { first = first, history = (not first and not resume) and history or nil })
  local vars = {
    message = message, text = text, session_id = st.session_id or "", model = M.current_model(agent) or "",
    mcp_config = write_mcp_config(addr, token), view = VIEW.text(snap),
  }
  local spec = resume and agent.followup or agent
  local cmd
  if type(spec.cmd) == "table" then
    cmd = {}
    for i, a in ipairs(spec.cmd) do cmd[i] = expand(a, vars) end
    local exe = vim.fn.exepath(cmd[1])
    if exe == "" then
      entry.status, entry.text = "failed", "`" .. cmd[1] .. "` isn't on PATH."
      return render()
    end
    cmd[1] = exe
  else
    cmd = expand(spec.cmd, vars, vim.fn.shellescape)
  end
  local env = { AZVICLI_CHAT_BRIDGE = addr, AZVICLI_CHAT_TOKEN = token }
  for k, v in pairs(agent.env or {}) do env[k] = expand(tostring(v), vars) end
  for k, v in pairs(spec.env or {}) do env[k] = expand(tostring(v), vars) end
  local out, err = {}, {}
  local ok, job = pcall(vim.fn.jobstart, cmd, {
    cwd = agent_cwd(snap), env = env, stdout_buffered = true, stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if st.running and st.running.timer then pcall(vim.fn.timer_stop, st.running.timer) end
        local cancelled = st.running and st.running.cancelled
        st.running = nil
        local answer, session = M.parse_answer(table.concat(out, "\n"), table.concat(err, "\n"), vim.json.decode,
          agent.session_pattern)
        if session then st.session_id = session end
        entry.text = answer
        if cancelled then
          entry.status = "stopped"
        elseif code ~= 0 then
          entry.status = "failed (exit " .. code .. ")"
          local tail = vim.tbl_filter(function(l) return l ~= "" end, err)
          if #tail > 0 then
            entry.text = (entry.text ~= "" and (entry.text .. "\n\n") or "") .. "```\n"
              .. table.concat(vim.list_slice(tail, math.max(1, #tail - 15)), "\n") .. "\n```"
          end
        else
          entry.status = "done"
          if entry.text == "" then entry.text = "_(no answer)_" end
        end
        render()
        local visible = false
        for _, w in pairs(st.wins) do if w.log and vim.api.nvim_win_is_valid(w.log) then visible = true end end
        if not visible then notify(agent_label() .. " answered in the chat (gq shows it).") end
      end)
    end,
  })
  if not ok or job <= 0 then
    entry.status, entry.text = "failed", "could not start the agent: " .. tostring(job)
    return render()
  end
  pcall(vim.fn.chansend, job, expand(spec.stdin or "{message}", vars))
  pcall(vim.fn.chanclose, job, "stdin")
  st.running = { job = job, entry = entry }
  -- Tick the "working… Ns" heading while it runs.
  st.running.timer = vim.fn.timer_start(1000, function()
    if st.running then render() end
  end, { ["repeat"] = -1 })
  local timeout = tonumber(agent.timeout_seconds) or 900
  vim.defer_fn(function()
    if st.running and st.running.job == job then
      st.running.cancelled = true
      entry.tools = entry.tools or {}
      table.insert(entry.tools, "\u{2717} timed out after " .. timeout .. "s")
      pcall(vim.fn.jobstop, job)
    end
  end, timeout * 1000)
end
M.send = send

cancel = function()
  local st = STATE()
  if not st.running then return notify("The agent isn't running.") end
  st.running.cancelled = true
  pcall(vim.fn.jobstop, st.running.job)
end

new_chat = function()
  local st = STATE()
  if st.running then cancel() end
  st.entries, st.session_id = {}, nil
  render()
  notify("New conversation.")
end

show_help = function()
  local KEYS = require("azure-cli.keys")
  local lines = KEYS.help_lines("chat", "Chat keys", {
    "Talk",
    { "send", "send the message (in the input box)" }, { "send_insert", "send while typing" },
    { "focus_input", "type a message (in the conversation)" },
    { "cancel", "stop the agent" }, { "new_chat", "start a new conversation" },
    { "model", "choose the model (from chat.agent.models)" },
    "Panel",
    { "back", "back to the screen next to the chat" }, { "hide", "hide the chat (gq shows it again)" },
    { "help", "this help" },
  }, { notes = {
    "The agent sees what you're looking at - the PR, work item, file, line or comment thread under the cursor - "
      .. "and can link, create branches and draft replies directly; votes and state changes ask you first.",
  } })
  require("azure-cli.ui").open_float(lines, { min_width = 60 })
end

-- gm: pick the model for the next messages, from chat.agent.models. It
-- reaches the agent through {model} in its command, so it applies to the
-- next message, resumed sessions included.
pick_model = function()
  local agent = config().agent
  local list = M.models(agent)
  if #list == 0 then
    return notify("No models to choose from - list them in setup({ chat = { agent = { models = { ... } } } }) "
      .. "and put {model} in its cmd.", vim.log.levels.WARN)
  end
  local uses = false
  for _, spec in ipairs({ agent, agent.followup or {} }) do
    for _, part in ipairs(type(spec.cmd) == "table" and spec.cmd or { spec.cmd or "" }) do
      if tostring(part):find("{model}", 1, true) then uses = true end
    end
  end
  local cur = M.current_model(agent)
  require("azure-cli.prompt").select({ prompt = "Model for the chat", items = list,
    current = function(m) return m.value == cur end }, function(choice)
    if not choice then return end
    STATE().model = choice.value
    M.set_winbars()
    notify("Chat model: " .. choice.label .. (uses and "" or " - but the agent's cmd has no {model}, so it can't pass it on."))
  end)
end

-- Binds the show/hide key on a screen's buffer (every azure-vicli screen
-- calls this for its own surface).
function M.bind_toggle(buf, surface)
  require("azure-cli.keys").bind(buf, surface, "chat", function() M.toggle() end,
    { desc = "show/hide the chat panel" })
end

return M
