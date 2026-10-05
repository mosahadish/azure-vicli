-- lua/azure-cli/chat/core.lua: the chat's pure helpers - no Neovim API
-- here, so tests/test-chat.lua can pin them down (it still runs in a real
-- nvim for vim.json/vim.split, which a few of them take as injected
-- arguments anyway).
--
--   compose        the text one message sends the agent
--   stream_*       reading the agent's stdout as it arrives: Claude Code's
--                  --output-format stream-json events, its single json
--                  envelope, or plain text, line by line
--   parse_answer   the same over a finished run's whole output
--   can_resume     whether a message continues the agent's session
--   expand         {placeholder} templates
--   render         the transcript's lines and what each one is
--   prompts        saved prompts ("/triage ...")
--   find_refs      #123 / !123 / PR 123 references in a text
local M = {}

M.PREAMBLE = [[You are the assistant inside azure-vicli, a Neovim plugin for Azure DevOps pull requests and work items. The user talks to you from a chat panel next to the screen they're on. Each message starts with "Current view", describing what they are looking at; "this PR", "this comment", "this work item" and "this code" mean what it names.

Use the azure-vicli tools to look things up and to act. Drafted replies and comments are queued for the user to review, never posted directly. To change code for a review comment: call start_fix, edit files only inside the directory it returns, then show_fix to let the user see the change, and commit_and_push_fix once they agree; then draft a reply saying what you changed. To implement a work item (a story, bug or task): read it with get_work_item, call start_story (it makes the branch and a worktree; ask which repository and base branch when they aren't clear), edit files only inside the directory it returns, then show_fix and commit_and_push_fix with work_item_id, and offer create_pull_request linking the work item. Never edit files anywhere else. Use open_in_ui only when the user asks to be shown something, and annotate_code to leave notes on lines of a diff.

Refer to pull requests as !<id> and work items as #<id>, so the user can open them from the chat. Answer briefly, in markdown.]]

-- Default saved prompts (setup({chat = {prompts = {...}}}) adds, replaces,
-- or removes one with `name = false`). "/name rest" in the input box sends
-- the prompt followed by `rest`.
M.DEFAULT_PROMPTS = {
  triage = "Triage this pull request's open comment threads: for each, say whether the reviewer is right "
    .. "(fix / push back / question / already done), why, and draft a short reply with draft_reply.",
  review = "Review this pull request's change for correctness bugs, missing tests and risky spots. "
    .. "Leave notes on the lines that matter with annotate_code, and summarise here.",
  explain = "Explain what this code or comment is about, and what the change does around it.",
  build = "Why did this pull request's build fail? Read the build log and point at the cause.",
  standup = "Write my standup: what moved since yesterday on my pull requests and work items, "
    .. "what's waiting on me, and anything blocked or failing.",
}

-- The text one message sends: the preamble (first message, or every
-- replayed one), the earlier conversation (replay only), the current view,
-- what the message references, and the message. Pure.
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
  if opts.refs and opts.refs ~= "" then parts[#parts + 1] = "## Referenced in the message\n" .. opts.refs end
  parts[#parts + 1] = "## Message\n" .. message
  return table.concat(parts, "\n\n")
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

-- ---------------------------------------------------------------------------
-- Reading the agent's output.

-- A fresh stream reader. `strip` is a list of Lua patterns: plain-text lines
-- matching any are dropped (e.g. a CLI's own tool-call log).
function M.stream_new(strip)
  return { pending = "", texts = {}, plain = {}, final = nil, session = nil, tools = {}, strip = strip or {} }
end

local function stripped(st, line)
  for _, pat in ipairs(st.strip) do
    local ok, hit = pcall(string.find, line, pat)
    if ok and hit then return true end
  end
  return false
end

-- A short label for one of the agent's own tool calls (stream-json
-- tool_use), e.g. "Read src/a.py". Our own azure-vicli tools are logged by
-- the bridge already, so they're skipped here.
local function tool_label(item)
  local name = tostring(item.name or "?")
  if name:find("azure%-vicli") then return nil end
  local input = type(item.input) == "table" and item.input or {}
  local detail = input.file_path or input.path or input.pattern or input.command or input.url or input.query
  if type(detail) == "string" then
    detail = detail:gsub("%s+", " ")
    if #detail > 60 then detail = detail:sub(1, 57) .. "..." end
    return name .. " " .. detail
  end
  return name
end

local function stream_line(st, line, decode)
  line = line:gsub("\r$", "")
  if line:sub(1, 1) == "{" then
    local ok, ev = pcall(decode, line)
    if ok and type(ev) == "table" then
      if type(ev.session_id) == "string" and ev.session_id ~= "" then st.session = ev.session_id end
      if ev.type == "assistant" and type(ev.message) == "table" then
        local chunk = {}
        for _, c in ipairs(type(ev.message.content) == "table" and ev.message.content or {}) do
          if type(c) == "table" and c.type == "text" and type(c.text) == "string" then
            chunk[#chunk + 1] = c.text
          elseif type(c) == "table" and c.type == "tool_use" then
            local label = tool_label(c)
            if label then st.tools[#st.tools + 1] = label end
          end
        end
        if #chunk > 0 then st.texts[#st.texts + 1] = table.concat(chunk, "") end
        return
      end
      if type(ev.result) == "string" then
        st.final = ev.result
        st.is_error = ev.is_error == true
        return
      end
      if ev.type then return end  -- system/user/other stream events
    end
  end
  if not stripped(st, line) then st.plain[#st.plain + 1] = line end
end

-- Feeds jobstart's on_stdout `data` (a list whose first element continues
-- the previous chunk's last line, and whose last element is a partial
-- line). Returns true when something visible changed.
function M.stream_feed(st, data, decode)
  if not data or #data == 0 then return false end
  local before = #st.texts + #st.plain + #st.tools + (st.final and 1 or 0)
  st.pending = st.pending .. data[1]
  for i = 2, #data do
    stream_line(st, st.pending, decode)
    st.pending = data[i]
  end
  return #st.texts + #st.plain + #st.tools + (st.final and 1 or 0) ~= before
end

-- Flushes the last partial line (call when the job exits).
function M.stream_finish(st, decode)
  if st.pending ~= "" then stream_line(st, st.pending, decode) end
  st.pending = ""
end

-- What to show right now: the final answer once there is one, else the
-- assistant text so far, else the plain text so far.
function M.stream_text(st)
  if st.final then return trim(st.final) end
  if #st.texts > 0 then return trim(table.concat(st.texts, "\n\n")) end
  -- Plain output: drop leading/trailing blank lines only.
  local lines = {}
  for _, l in ipairs(st.plain) do lines[#lines + 1] = l end
  while #lines > 0 and lines[1]:match("^%s*$") do table.remove(lines, 1) end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  return table.concat(lines, "\n")
end

-- A finished run's whole output, read the same way. Returns text,
-- session_id. `pattern` (chat.agent.session_pattern) finds a session id in
-- plain output.
function M.parse_answer(out, err, decode, pattern, strip)
  local st = M.stream_new(strip)
  local lines = {}
  for l in ((out or "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  -- A multi-line json envelope (pretty-printed) is one document.
  local whole = trim(out)
  if whole:sub(1, 1) == "{" then
    local ok, d = pcall(decode, whole)
    if ok and type(d) == "table" then lines = { (whole:gsub("\n", " ")) } end
  end
  for _, l in ipairs(lines) do stream_line(st, l, decode) end
  local text = M.stream_text(st)
  if st.final and st.is_error and text == "" then text = "(the agent reported an error)" end
  local session = st.session
  if not session and type(pattern) == "string" and pattern ~= "" then
    session = M.find_session(pattern, out, err)
  end
  return text, session, st.tools
end

function M.find_session(pattern, ...)
  for _, s in ipairs({ ... }) do
    local ok, id = pcall(string.match, s or "", pattern)
    if ok and type(id) == "string" and id ~= "" then return id end
  end
  return nil
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

function M.expand(template, vars, quote)
  if type(template) ~= "string" then return template end
  return (template:gsub("{([%w_]+)}", function(name)
    local v = vars[name]
    if v == nil then return nil end
    v = tostring(v)
    return quote and quote(v) or v
  end))
end

-- An agent's models as { label, value } pairs: a string is both.
function M.models(agent)
  local out = {}
  for _, m in ipairs((agent and agent.models) or {}) do
    if type(m) == "string" then out[#out + 1] = { label = m, value = m }
    elseif type(m) == "table" and m.value then out[#out + 1] = { label = m.label or m.value, value = m.value } end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Saved prompts.

-- The prompts in effect: the defaults, then the user's (a string replaces
-- or adds one, false removes one). Pure.
function M.prompts(user)
  local out = {}
  for k, v in pairs(M.DEFAULT_PROMPTS) do out[k] = v end
  for k, v in pairs(user or {}) do
    if v == false then out[k] = nil else out[k] = v end
  end
  return out
end

-- "/name rest" -> the prompt (plus rest), name; anything else -> text, nil.
function M.expand_prompt(text, prompts)
  local name, rest = text:match("^/([%w_%-]+)%s*(.-)%s*$")
  if name and prompts[name] then
    return prompts[name] .. (rest ~= "" and ("\n\n" .. rest) or ""), name
  end
  return text, nil
end

-- ---------------------------------------------------------------------------
-- References.

-- Every #123 / !123 / "PR 123" / "PR #123" in `text`, in order, without
-- repeats: { kind = "pr"|"any", id, s, e } (byte span, 1-based). "!" and
-- "PR" mean a pull request; a bare "#" is either - a PR in the list or
-- else a work item (resolved later). Pure.
function M.find_refs(text)
  local out, seen = {}, {}
  local function add(kind, id, s, e)
    out[#out + 1] = { kind = kind, id = tonumber(id), s = s, e = e }
    seen[s] = true
  end
  local i = 1
  while true do
    local s, e, id = text:find("[Pp][Rr]%s*#?(%d+)", i)
    if not s then break end
    if s == 1 or not text:sub(s - 1, s - 1):match("[%w_]") then add("pr", id, s, e) end
    i = e + 1
  end
  for s, sigil, id, e in text:gmatch("()([#!])(%d+)()") do
    local covered = false
    for _, r in ipairs(out) do if s >= r.s and s <= r.e then covered = true end end
    local prev = s > 1 and text:sub(s - 1, s - 1) or ""
    if not covered and not prev:match("[%w_&]") then add(sigil == "!" and "pr" or "any", id, s, e - 1) end
  end
  table.sort(out, function(a, b) return a.s < b.s end)
  local uniq, keys = {}, {}
  for _, r in ipairs(out) do
    local key = r.kind .. r.id
    if not keys[key] then keys[key] = true; uniq[#uniq + 1] = r end
  end
  return uniq, out
end

-- ---------------------------------------------------------------------------
-- The transcript.

-- Lines plus what each line is, for colouring: a "You" / "<agent>"
-- heading per turn (the name, then a dimmer " · on PR #101" / " ·
-- working… 4s"), your text, the agent's tool calls as they happen, then
-- its markdown answer. Returns lines, roles (line -> one of you_head, you,
-- agent_head, agent, tool_read, tool_write, tool_err, note, intro; nil for
-- the gap between turns), name_end (heading line -> byte where its dim
-- part starts) and entry_at (line -> index into entries). Pure.
function M.render(entries, now, agent_label)
  local lines, roles, name_end, entry_at = {}, {}, {}, {}
  local cur
  local function add(l, role) lines[#lines + 1] = l; roles[#lines] = role; entry_at[#lines] = cur end
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
      .. "this comment?\", \"create a branch from develop for this work item\".\nType below; <CR> sends. "
      .. "/triage, /review, /build, /standup run saved prompts (gp lists them).", "intro")
    return lines, roles, name_end, entry_at
  end
  for i, e in ipairs(entries) do
    cur = nil
    if i > 1 then add("", nil) end
    cur = i
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
      head(e.label or agent_label or "Agent", table.concat(bits, "  \u{00B7}  "), "agent_head")
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
  return lines, roles, name_end, entry_at
end

-- A conversation's title for the history list: its first message, cut.
function M.title(entries)
  for _, e in ipairs(entries or {}) do
    if e.role == "you" then
      local t = (e.text or ""):gsub("%s+", " ")
      if #t > 60 then t = t:sub(1, 57) .. "..." end
      return t
    end
  end
  return "(empty)"
end

return M
