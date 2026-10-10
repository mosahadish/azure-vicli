-- lua/azure-cli/chat/plan_view.lua: the plan's tab (chat/plan.lua's open,
-- refresh, current, open_views, describe, describe_view): the section list
-- on the left with the keys that matter now, the plan as rendered markdown
-- with the questions and requested changes under its lines, the chat
-- alongside. Saving a plan's file by hand makes it a revision by you.
--
-- plan.lua loads it on its own load and reaches into it through M.changed
-- (save + redraw), M.plan_win and M.show; it reaches plan.lua lazily
-- (PLAN()), since plan.lua requires it while still loading.
local M = {}

local function PLAN() return require("azure-cli.chat.plan") end
local function UI() return require("azure-cli.ui") end
local function KEYS() return require("azure-cli.keys") end
local function THREADS() return require("azure-cli.chat.threads") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function last_rev(rec) return rec.revisions[#rec.revisions] end

-- One view per plan - its own tab - so several plans can be open at once.
-- `view` is the one being worked on: every key, autocmd and callback
-- points it at its own plan's view first (use_buf / with_view), and the
-- functions below read it.
local view = nil  -- { tab, list_win, plan_win, list_buf, plan_buf, key, rec, sections, rows, width }
local views = {}  -- plan key -> its view
local by_buf = {} -- buffer -> the view it belongs to
local goto_code, unanswered  -- forward
local list_ns = vim.api.nvim_create_namespace("azure_cli_plan_list")

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end
local function valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end

local function key_of(surface, action) return KEYS().first(surface, action) end

local LIST_HELP = {
  "Navigate",
  { "open", "go to the section" },
  "Decide",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", "ask for changes (you say what)" },
  { "open_file", "edit the plan by hand (saving it makes that the version the agent gets)" },
  "See",
  { "run_log", "the run log: revisions, questions, approvals, tests, the agent's tool calls" },
  { "refresh", "reload it" },
  { "chat", "go to the chat" },
  "Window",
  { "resize_less", "shrink the section list" }, { "resize_more", "grow the section list" },
  { "quit", "close" }, { "help", "this help" },
}
local PLAN_HELP = {
  "Navigate",
  { "next_thread", "next question" }, { "prev_thread", "previous question" },
  { "goto_code", "the code this line became (a linked step, or a Files entry's file)" },
  { "back", "back to the section list" },
  "Ask the agent",
  { "ask", "ask the agent about this line (in visual mode: these lines) - the answer shows under it" },
  { "request", "queue a change on this line (in visual mode: these lines) - gR sends them together" },
  { "answer", "answer the open question under the cursor - sent along when you approve" },
  { "expand_thread", "show all of the answer under this line / fold it again" },
  { "view_thread", "the question and answer in a popup" },
  { "delete_thread", "forget the question or change under this line" },
  "Decide",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", "ask for changes: what you write, plus the ones queued on lines (gc)" },
  { "open_file", "edit the plan by hand" },
  "See",
  { "since", "mark what this revision changed against the one before (on by default; toggles)" },
  { "run_log", "the run log: revisions, questions, approvals, tests, the agent's tool calls" },
  { "refresh", "reload it" },
  { "chat", "go to the chat (in visual mode: send the selected lines)" },
  "Window",
  { "quit", "close" }, { "help", "this help" },
}

local function help(tbl)
  UI().open_float(KEYS().help_lines("plan", "Plan keys", tbl, { notes = {
    "The agent waits for you: it can't start changing code (start_fix / start_story) until you approve the plan.",
  } }), { title = "Keys", min_width = 60 })
end

local function alive(v)
  return v and v.tab and vim.api.nvim_tabpage_is_valid(v.tab) and valid_win(v.list_win) and valid_win(v.plan_win)
end

local function use_buf(buf) if by_buf[buf] then view = by_buf[buf] end end

-- Runs fn with `view` = v, then puts back the view that was current.
local function with_view(v, fn)
  local keep = view
  view = v
  local ok, err = pcall(fn)
  view = keep
  if not ok then error(err, 0) end
end

local function view_of_tab(tab)
  for _, v in pairs(views) do if v.tab == tab and alive(v) then return v end end
  return nil
end

-- KEYS().bind for the plan surface, on a buffer of one plan's view: the
-- key works on that view.
local function bind(buf, action, fn, opts)
  KEYS().bind(buf, "plan", action, function(...)
    use_buf(buf)
    return fn(...)
  end, opts)
end

local function close()
  if view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(view.tab))
  end
end

local function resize(delta)
  if not (view and valid_win(view.list_win)) then return end
  view.width = math.max(20, vim.api.nvim_win_get_width(view.list_win) + delta)
  pcall(vim.api.nvim_win_set_width, view.list_win, view.width)
end

local link_ns = vim.api.nvim_create_namespace("azure_cli_plan_links")

-- "→ auth.py:13" at the end of each plan line a step of the change carries
-- out (show_fix's `steps`).
local function draw_links()
  if not (view and valid_buf(view.plan_buf)) then return end
  vim.api.nvim_buf_clear_namespace(view.plan_buf, link_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local by_line = {}
  for _, k in ipairs(view.rec.links or {}) do
    local l = PLAN().resolve_line(lines, k.plan_line, k.plan_anchor)
    if l then
      by_line[l] = by_line[l] or {}
      table.insert(by_line[l], vim.fn.fnamemodify(k.file or "?", ":t") .. ":" .. tostring(k.line))
    end
  end
  for l, where in pairs(by_line) do
    pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, link_ns, l - 1, 0, {
      virt_text = { { "  \u{2192} " .. table.concat(where, ", "), "AzureCliMuted" } }, virt_text_pos = "eol" })
  end
end

local since_ns = vim.api.nvim_create_namespace("azure_cli_plan_since")

-- What this revision changed against the one before it, or nil (the first
-- revision, or gi turned it off): revision_changes' { changed, removed }.
local function since()
  local revs = view.rec.revisions
  if view.since_off or #revs < 2 then return nil end
  local old = vim.split(revs[#revs - 1].markdown or "", "\n", { plain = true })
  local new = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local diff = (vim.text and vim.text.diff) or vim.diff
  local ok, hunks = pcall(diff, table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n",
    { result_type = "indices" })
  return PLAN().revision_changes(old, new, ok and hunks or {})
end

-- The bar beside each line this revision changed, and the lines it took
-- out (struck through, where they were).
local function draw_since()
  if not (view and valid_buf(view.plan_buf)) then return end
  vim.api.nvim_buf_clear_namespace(view.plan_buf, since_ns, 0, -1)
  local ch = since()
  view.changes = ch
  if not ch then return end
  local n = vim.api.nvim_buf_line_count(view.plan_buf)
  for l in pairs(ch.changed) do
    pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, since_ns, l - 1, 0,
      { sign_text = "\u{258E}", sign_hl_group = "AzureCliPlanChanged", priority = 5 })
  end
  for at, gone in pairs(ch.removed) do
    local vl = {}
    for _, g in ipairs(gone) do vl[#vl + 1] = { { "\u{2212} " .. g, "AzureCliPlanRemoved" } } end
    if at <= n then
      pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, since_ns, at - 1, 0, { virt_lines = vl, virt_lines_above = true })
    else
      pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, since_ns, n - 1, 0, { virt_lines = vl })
    end
  end
end

local function draw_threads()
  if not (view and valid_buf(view.plan_buf)) then return end
  THREADS().draw(view.plan_buf, view.plan_win, view.rec.threads, function(th) return th.line end)
  draw_links()
end

local function set_winbars()
  if not view then return end
  local rec = view.rec
  local short = { draft = "draft", approved = "approved", changes_requested = "changes asked", done = "done" }
  local tags = { "[" .. (short[rec.status] or "draft") .. "]" }
  local nq, nr = THREADS().counts(rec.threads)
  if nq > 0 then tags[#tags + 1] = "[?" .. nq .. "]" end
  if nr > 0 then tags[#tags + 1] = "[\u{270E}" .. nr .. " queued]" end
  if last_rev(rec) and last_rev(rec).by == "you" then tags[#tags + 1] = "[edited by you]" end
  if rec.allow_push and rec.status == "approved" then tags[#tags + 1] = "[may push]" end
  local open_q = unanswered()
  if open_q > 0 and rec.status ~= "approved" and rec.status ~= "done" then
    tags[#tags + 1] = "[" .. open_q .. " to answer]"
  end
  if view.changes then tags[#tags + 1] = "[\u{00B1} since rev " .. (#rec.revisions - 1) .. "]" end
  if valid_win(view.plan_win) then
    pcall(UI().wo, view.plan_win, "winbar", UI().winbar({ "Plan " .. PLAN().target_label(rec.target),
      #rec.revisions > 1 and ("rev " .. #rec.revisions) or nil }, tags))
  end
  if valid_win(view.list_win) then
    pcall(UI().wo, view.list_win, "winbar", UI().winbar({ "Sections" }, {}))
  end
end

-- Whether section `s` has lines this revision changed or took out.
local function section_changed(s)
  local ch = view.changes
  if not ch then return false end
  local stop = math.huge
  for _, o in ipairs(view.sections) do
    if o.line > s.line and o.level <= s.level then stop = o.line break end
  end
  for l in pairs(ch.changed) do if l >= s.line and l < stop then return true end end
  for l in pairs(ch.removed) do if l > s.line and l <= stop then return true end end
  return false
end

-- The section list: the plan's title and status, its sections (with how
-- many questions each has, and the Files count), then the keys that matter.
local function render_list()
  if not (view and valid_buf(view.list_buf)) then return end
  local rec = view.rec
  local width = valid_win(view.list_win) and vim.api.nvim_win_get_width(view.list_win) or 30
  local lines, hls, rows = {}, {}, {}
  local function add(text, hl, from)
    lines[#lines + 1] = text
    if hl then hls[#hls + 1] = { #lines - 1, from or 0, hl } end
  end
  add(" " .. UI().fit(PLAN().target_label(rec.target) .. "  " .. (rec.title or ""), width - 2), "AzureCliSection")
  local st, st_hl = PLAN().status_label(rec)
  if rec.allow_push and rec.status == "approved" then st = st .. " \u{00B7} may push" end
  add(" " .. st .. (#rec.revisions > 1 and ("  \u{00B7} revision " .. #rec.revisions) or ""), st_hl)
  add("")
  local per, per_req = {}, {}
  for _, th in ipairs(rec.threads) do
    local s = PLAN().section_at(view.sections, th.line)
    local into = th.kind == "request" and per_req or per
    if s and not (th.kind == "request" and th.status == "sent") then into[s.line] = (into[s.line] or 0) + 1 end
  end
  for _, s in ipairs(view.sections) do
    if s.level >= 2 then
      local badge = ""
      if per[s.line] then badge = "?" .. per[s.line] end
      if per_req[s.line] then badge = (badge ~= "" and (badge .. " ") or "") .. "\u{270E}" .. per_req[s.line] end
      if section_changed(s) then badge = (badge ~= "" and (badge .. " ") or "") .. "\u{00B1}" end
      if s.items > 0 and s.title:lower():find("file", 1, true) then badge = (badge ~= "" and (badge .. " ") or "") .. s.items end
      local indent = string.rep("  ", math.max(0, s.level - 2))
      local name = UI().fit(indent .. s.title, math.max(8, width - 4 - vim.fn.strdisplaywidth(badge)))
      add("   " .. name .. badge, nil)
      if badge ~= "" then hls[#hls + 1] = { #lines - 1, #lines[#lines] - #badge, "AzureCliAccent" } end
      rows[#lines] = s
    end
  end
  add("")
  local hints = {}
  local decided = rec.status == "approved" or rec.status == "done"
  if not decided then
    hints[#hints + 1] = { "plan", "approve", "approve" }
    hints[#hints + 1] = { "plan", "revise", "ask for changes" }
  end
  hints[#hints + 1] = { "plan", "ask", "ask about a line" }
  if not decided then hints[#hints + 1] = { "plan", "request", "ask a change on a line" } end
  if unanswered() > 0 then hints[#hints + 1] = { "plan", "answer", "answer an open question" } end
  if decided then
    hints[#hints + 1] = { "plan", "goto_code", "the code a step became" }
    hints[#hints + 1] = { "plan", "run_log", "what happened so far" }
  else
    hints[#hints + 1] = { "plan", "open_file", "edit it yourself" }
  end
  hints[#hints + 1] = { "plan", "help", "all keys" }
  local hl_, hhls = KEYS().hint_lines(hints)
  local at = #lines
  for _, l in ipairs(hl_) do lines[#lines + 1] = l end
  for _, h in ipairs(hhls) do hls[#hls + 1] = { at + h[1], h[2], h[4], h[3] } end
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, lines)
  vim.bo[view.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.list_buf, list_ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, view.list_buf, list_ns, h[1], h[2],
      { end_col = h[4] or #lines[h[1] + 1], hl_group = h[3] })
  end
  view.rows = rows
end

local function render_plan()
  if not (view and valid_buf(view.plan_buf)) then return end
  local lines = PLAN().lines(view.rec)
  view.sections = PLAN().sections(lines)
  vim.bo[view.plan_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.plan_buf, 0, -1, false, lines)
  vim.bo[view.plan_buf].modifiable = false
  draw_threads()
end

local function render()
  render_plan()
  draw_since()
  render_list()
  set_winbars()
end

-- Saves the plan and redraws the viewer if it shows it.
local function changed(rec)
  PLAN().save(rec)
  local v = views[rec.key]
  if alive(v) then
    with_view(v, function()
      view.rec = rec
      render_list()
      set_winbars()
      draw_threads()
    end)
  end
end

local function send(text, display)
  local CHAT = require("azure-cli.chat")
  if CHAT.busy() then
    notify("The agent is still answering - tell it once it's done (it can read the plan with get_plan).",
      vim.log.levels.WARN)
    return false
  end
  return CHAT.send(text, { view_win = valid_win(view and view.plan_win) and view.plan_win or nil, display = display })
    ~= nil
end

-- gA: approve - and, if you say so, let the change be pushed without
-- asking once the plan's tests pass on it (PLAN().push_check).
local function approve()
  local rec = view and view.rec
  if not rec then return end
  if rec.status == "approved" then return notify("Already approved.") end
  if rec.status == "done" then return notify("This plan was implemented already.") end
  PLAN().ask_approval({ rec.key }, function(allow_push) PLAN().approve(rec.key, allow_push) end)
end

-- gR: ask for changes - what you write here, plus every change queued on
-- a line with gc.
local function revise()
  local rec = view and view.rec
  if not rec then return end
  local queued = {}
  for _, th in ipairs(rec.threads) do
    if th.kind == "request" and th.status ~= "sent" then queued[#queued + 1] = th end
  end
  require("azure-cli.editor").open({
    title = "What should change in the plan?" .. (#queued > 0 and (" (+" .. #queued .. " on its lines)") or ""),
    initial = #queued > 0 and "See my comments on its lines." or "", anchor = "center",
    on_submit = function(text)
      view = views[rec.key] or view
      if send(PLAN().revise_message(rec, text, queued, PLAN().lines(rec)), "Changes to the plan: " .. text
          .. (#queued > 0 and (" (+" .. #queued .. " on its lines)") or "")) then
        rec.status = "changes_requested"
        for _, th in ipairs(queued) do th.status = "sent" end
        for _, th in ipairs(rec.threads) do if th.kind == "answer" then th.status = "sent" end end
        PLAN().add_event(rec, "changes", "You asked for changes: " .. text
          .. (#queued > 0 and (" (+" .. #queued .. " on its lines)") or ""))
        changed(rec)
      end
    end,
  })
end

-- gc: queue a change on this line (or these lines) for gR.
local function request(from, to)
  local rec = view.rec
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, from - 1, to, false)
  local sec = PLAN().section_at(view.sections, from)
  require("azure-cli.editor").open({
    title = "Change \u{00B7} plan:" .. (from == to and from or (from .. "-" .. to)) .. " (queued for gR)",
    initial = "", anchor = { win = view.plan_win, row = to }, context_lines = lines,
    on_submit = function(text)
      table.insert(rec.threads, { id = tostring(os.time()) .. "-" .. math.random(1000, 9999), kind = "request",
        line = to, anchor = vim.trim(lines[#lines] or ""), section = sec and sec.title, question = text,
        status = "queued", at = os.time() })
      changed(rec)
      local _, r = THREADS().counts(rec.threads)
      notify(r .. " change" .. (r == 1 and "" or "s") .. " queued - " .. (key_of("plan", "revise") or "gR")
        .. " sends " .. (r == 1 and "it" or "them") .. ".")
    end,
  })
end

-- gr on one of the plan's open questions: your answer, shown under it and
-- sent along when you approve (or ask for changes).
local function answer_here()
  local rec = view.rec
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local is_q = false
  for _, q in ipairs(PLAN().open_questions(lines)) do if q.line == row then is_q = true end end
  if not is_q then return notify("Put the cursor on one of the plan's open questions (its Open questions section).") end
  local existing
  for _, th in ipairs(rec.threads) do if th.kind == "answer" and th.line == row then existing = th end end
  require("azure-cli.editor").open({
    title = "Your answer \u{00B7} plan:" .. row, initial = existing and existing.question or "",
    anchor = { win = view.plan_win, row = row }, context_lines = { lines[row] },
    on_submit = function(text)
      if existing then
        existing.question, existing.status, existing.at = text, "queued", os.time()
      else
        table.insert(rec.threads, { id = tostring(os.time()) .. "-" .. math.random(1000, 9999), kind = "answer",
          line = row, anchor = vim.trim(lines[row] or ""), question = text, status = "queued", at = os.time() })
      end
      changed(rec)
    end,
  })
end

-- How many of the plan's open questions you haven't answered.
unanswered = function()
  local answered = {}
  for _, th in ipairs(view.rec.threads) do if th.kind == "answer" then answered[th.line] = true end end
  local n = 0
  local lines = valid_buf(view.plan_buf) and vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false) or {}
  for _, q in ipairs(PLAN().open_questions(lines)) do if not answered[q.line] then n = n + 1 end end
  return n
end

-- dd: forget the question or change request under the cursor.
local function delete_here()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local _, i = THREADS().at_line(view.rec.threads, row)
  if not i then return notify("Nothing under this line.") end
  table.remove(view.rec.threads, i)
  changed(view.rec)
end

local function open_file()
  if not view then return end
  local path = PLAN().path(view.key)
  local row = valid_win(view.plan_win) and vim.api.nvim_win_get_cursor(view.plan_win)[1] or 1
  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
end

-- Saving the plan's file by hand: that's a revision by you, which needs
-- approving again.
vim.api.nvim_create_autocmd("BufWritePost", {
  group = vim.api.nvim_create_augroup("AzureCliPlanFile", { clear = true }),
  pattern = "*.md",
  callback = function(ev)
    local file = vim.fn.fnamemodify(ev.match, ":p"):gsub("\\", "/")
    local root = vim.fn.fnamemodify(PLAN().root(), ":p"):gsub("\\", "/")
    if file:sub(1, #root) ~= root then return end
    local key = vim.fn.fnamemodify(file, ":t:r")
    local rec = PLAN().load(key)
    if not rec then return end
    local text = table.concat(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false), "\n")
    local rev = last_rev(rec)
    if rev and rev.markdown == text then return end
    local was = rec.status
    PLAN().add_revision(rec, text, "you")
    PLAN().save(rec)
    if alive(views[key]) then
      with_view(views[key], function()
        view.rec = rec
        render()
      end)
    end
    notify("Plan saved as your version" .. ((was == "approved") and " - approve it again (" .. (key_of("plan", "approve") or "gA") .. ") for the agent to use it." or "."))
  end,
})

local function thread_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return THREADS().at_line(view.rec.threads, row)
end

local function jump_thread(dir)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, th in ipairs(view.rec.threads) do
    if (dir > 0 and th.line > row and (not best or th.line < best))
        or (dir < 0 and th.line < row and (not best or th.line > best)) then
      best = th.line
    end
  end
  if not best then return notify(dir > 0 and "No further questions." or "No earlier questions.") end
  vim.api.nvim_win_set_cursor(0, { best, 0 })
end

local function ask(from, to)
  local rec = view.rec
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, from - 1, to, false)
  local quote = table.concat(lines, "\n")
  local sec = PLAN().section_at(view.sections, from)
  local where = (sec and ("section \"" .. sec.title .. "\", ") or "") .. (from == to and ("line " .. from)
    or ("lines " .. from .. "-" .. to))
  THREADS().ask({
    win = view.plan_win, row = to, line = to, anchor = vim.trim(lines[#lines] or ""), section = sec and sec.title,
    ctx = { what = "your plan for " .. PLAN().target_label(rec.target) .. " (\"" .. (rec.title or "") .. "\")", where = where },
    quote = quote,
    label = "plan:" .. (from == to and from or (from .. "-" .. to)),
    threads = rec.threads,
    changed = function() changed(rec) end,
  })
end

-- gd on a plan line: the code it became - a step of the change linked to
-- this line (show_fix's `steps`), or the file a Files entry names.
goto_code = function()
  local rec = view.rec
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local links = PLAN().links_on_plan_line(rec.links, lines, row)
  local function go(path, line)
    require("azure-cli.chat.tools_fix").open_at(rec.target, path, line, function(err)
      if err then notify(err, vim.log.levels.WARN) end
    end)
  end
  if #links == 1 then return go(links[1].file, links[1].line) end
  if #links > 1 then
    return require("azure-cli.prompt").select({ prompt = "Which part of the change", items = links,
      format = function(k) return k.file .. ":" .. tostring(k.line) .. (k.note and ("  " .. k.note) or "") end },
      function(k) if k then go(k.file, k.line) end end)
  end
  local file = PLAN().file_at_line(lines, row)
  if file then return go(file, nil) end
  notify("Nothing in the change is linked to this line (a Files entry opens its file).")
end

local function bind_common(buf)
  bind(buf, "approve", approve, { desc = "approve the plan" })
  bind(buf, "revise", revise, { desc = "ask for changes to the plan" })
  bind(buf, "open_file", open_file, { desc = "edit the plan by hand" })
  bind(buf, "refresh", function() M.refresh() end, { desc = "reload the plan" })
  bind(buf, "chat", function() require("azure-cli.chat").toggle() end, { desc = "go to the chat" })
  bind(buf, "chat", function() require("azure-cli.chat").capture_selection() end,
    { desc = "send the selected lines to the chat", mode = "x" })
  bind(buf, "resize_less", function() resize(-5) end, { desc = "shrink the section list" })
  bind(buf, "resize_more", function() resize(5) end, { desc = "grow the section list" })
  bind(buf, "quit", close, { desc = "close" })
  bind(buf, "run_log", function() PLAN().open_run_log(view.key) end, { desc = "everything that happened, as one page" })
end

local function goto_section(s, focus)
  if not (s and valid_win(view.plan_win)) then return end
  pcall(vim.api.nvim_win_set_cursor, view.plan_win, { s.line, 0 })
  vim.api.nvim_win_call(view.plan_win, function() vim.cmd("normal! zt") end)
  if focus then vim.api.nvim_set_current_win(view.plan_win) end
end

local function setup_list(buf)
  bind(buf, "open", function()
    goto_section(view.rows[vim.api.nvim_win_get_cursor(0)[1]], true)
  end, { desc = "go to the section" })
  bind(buf, "help", function() help(LIST_HELP) end, { desc = "keys" })
  bind_common(buf)
  -- Moving through the sections scrolls the plan to each one.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      use_buf(buf)
      local s = view and view.rows and view.rows[vim.api.nvim_win_get_cursor(0)[1]]
      if s then goto_section(s, false) end
    end,
  })
end

local function setup_plan(buf)
  bind(buf, "ask", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    ask(r, r)
  end, { desc = "ask the agent about this line" })
  bind(buf, "ask", function()
    local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    ask(a, b)
  end, { desc = "ask the agent about these lines", mode = "x" })
  bind(buf, "expand_thread", function()
    local th = thread_at_cursor()
    if not th then return notify("No question on this line (" .. (key_of("plan", "ask") or "ga") .. " asks one).") end
    THREADS().toggle(th)
    draw_threads()
  end, { desc = "show all of the answer / fold it" })
  bind(buf, "view_thread", function() THREADS().show(thread_at_cursor()) end, { desc = "the question and answer" })
  bind(buf, "request", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    request(r, r)
  end, { desc = "queue a change on this line" })
  bind(buf, "request", function()
    local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    request(a, b)
  end, { desc = "queue a change on these lines", mode = "x" })
  bind(buf, "delete_thread", delete_here, { desc = "forget the question / change under this line" })
  bind(buf, "answer", answer_here, { desc = "answer this open question" })
  bind(buf, "since", function()
    view.since_off = not view.since_off
    render()
    notify(view.since_off and "Not marking what changed." or (view.changes and "Marking what changed since revision "
      .. (#view.rec.revisions - 1) .. ".") or "This is the first revision.")
  end, { desc = "mark what this revision changed (toggle)" })
  bind(buf, "next_thread", function() jump_thread(1) end, { desc = "next question" })
  bind(buf, "prev_thread", function() jump_thread(-1) end, { desc = "previous question" })
  bind(buf, "back", function()
    if valid_win(view.list_win) then vim.api.nvim_set_current_win(view.list_win) end
  end, { desc = "back to the section list" })
  bind(buf, "goto_code", function() goto_code() end, { desc = "the code this line became" })
  bind(buf, "help", function() help(PLAN_HELP) end, { desc = "keys" })
  bind_common(buf)
end

-- Opens (or brings to the front, reloaded) the plan `key`, at plan line
-- `line` when given.
function M.open(key, line)
  local rec = PLAN().load(key)
  if not rec then return nil, "no plan " .. tostring(key) end
  UI().theme()
  if alive(views[key]) then
    view = views[key]
    view.rec = rec
    vim.api.nvim_set_current_tabpage(view.tab)
  else
    local width = view and view.width or 32
    view = { key = key, rec = rec, width = width, sections = {}, rows = {} }
    views[key] = view
    vim.cmd("tabnew")
    view.tab = vim.api.nvim_get_current_tabpage()
    view.list_win = vim.api.nvim_get_current_win()
    view.list_buf = vim.api.nvim_get_current_buf()
    by_buf[view.list_buf] = view
    vim.bo[view.list_buf].buftype = "nofile"
    vim.bo[view.list_buf].bufhidden = "wipe"
    vim.bo[view.list_buf].filetype = "azurecli-plan"
    pcall(vim.api.nvim_buf_set_name, view.list_buf, "azure-cli://plan/" .. key .. "/sections")
    setup_list(view.list_buf)
    vim.cmd("belowright vsplit")
    view.plan_win = vim.api.nvim_get_current_win()
    view.plan_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[view.plan_buf].buftype = "nofile"
    vim.bo[view.plan_buf].bufhidden = "wipe"
    vim.bo[view.plan_buf].filetype = "markdown"
    vim.b[view.plan_buf].azure_cli_view = "azurecli-plan"
    vim.b[view.plan_buf].azure_cli_title = "Plan"
    by_buf[view.plan_buf] = view
    pcall(vim.api.nvim_buf_set_name, view.plan_buf, "azure-cli://plan/" .. key)
    vim.api.nvim_win_set_buf(view.plan_win, view.plan_buf)
    pcall(vim.treesitter.start, view.plan_buf, "markdown")
    setup_plan(view.plan_buf)
    UI().plain_window(view.list_win, { cursorline = true })
    UI().plain_window(view.plan_win, {})
    UI().wo(view.plan_win, "wrap", true)
    UI().wo(view.plan_win, "linebreak", true)
    UI().wo(view.plan_win, "breakindent", true)
    UI().wo(view.plan_win, "conceallevel", 2)
    UI().wo(view.plan_win, "concealcursor", "")
    UI().wo(view.plan_win, "signcolumn", "yes:2")
    pcall(vim.api.nvim_win_set_width, view.list_win, width)
    local v = view
    vim.api.nvim_create_autocmd("WinResized", {
      buffer = view.list_buf,
      callback = function()
        vim.schedule(function() if alive(v) then with_view(v, function() render_list() draw_threads() end) end end)
      end,
    })
    -- The tab went: forget its view.
    for _, b in ipairs({ view.list_buf, view.plan_buf }) do
      vim.api.nvim_create_autocmd("BufWipeout", { buffer = b, once = true, callback = function()
        by_buf[b] = nil
        if views[key] == v then views[key] = nil end
      end })
    end
  end
  vim.t[view.tab].azure_cli_title = "Plan " .. PLAN().target_label(rec.target)
  vim.t[view.tab].azure_cli_plan_key = key
  pcall(function() require("azure-cli.chat").sync_active() end)
  render()
  -- The plan gets the focus - again after the chat panel has followed into
  -- this tab (it opens on a scheduled callback).
  local function focus()
    if view and valid_win(view.plan_win) then vim.api.nvim_set_current_win(view.plan_win) end
  end
  if line then
    pcall(vim.api.nvim_win_set_cursor, view.plan_win, { line, 0 })
    vim.api.nvim_win_call(view.plan_win, function() vim.cmd("normal! zz") end)
  end
  focus()
  vim.schedule(function() vim.schedule(focus) end)
  return view.tab
end

function M.refresh()
  if not view then return end
  local rec = PLAN().load(view.key)
  if not rec then return end
  view.rec = rec
  render()
end

-- The plan view in the current tab, else the last one used (tests): {
-- tab, list_win, plan_win, list_buf, plan_buf, key, rec }.
function M.current() return view_of_tab(vim.api.nvim_get_current_tabpage()) or view end

-- Every open plan's view, by key.
function M.open_views()
  local out = {}
  for k, v in pairs(views) do if alive(v) then out[k] = v end end
  return out
end

-- The chat's description of the plan window.
function M.describe(win)
  local v = by_buf[vim.api.nvim_win_get_buf(win)] or view_of_tab(vim.api.nvim_win_get_tabpage(win))
  if not v then return nil end
  local snap
  with_view(v, function() snap = M.describe_view(win) end)
  return snap
end

function M.describe_view(win)
  local rec = view.rec
  local snap = { screen = "plan", plan = { key = rec.key, title = rec.title, status = rec.status,
    revision = #rec.revisions, file = PLAN().path(rec.key) } }
  if rec.target.work_item_id then
    snap.work_item = { id = rec.target.work_item_id }
  else
    snap.pr = require("azure-cli.chat.tools").pr_record(rec.target.pr_id) or { id = rec.target.pr_id }
  end
  snap.note = "Looking at your plan for " .. PLAN().target_label(rec.target) .. " \"" .. tostring(rec.title) .. "\" ("
    .. (PLAN().status_label(rec)):gsub("^%S+ ", "") .. ", revision " .. #rec.revisions .. ", file " .. snap.plan.file .. ")"
  if win == view.plan_win and valid_win(win) then
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local sec = PLAN().section_at(view.sections, row)
    snap.plan_line, snap.plan_section = row, sec and sec.title
    snap.plan_text = vim.api.nvim_buf_get_lines(view.plan_buf, row - 1, row, false)[1]
  end
  return snap
end

require("azure-cli.chat.view").register("azurecli-plan", function(win) return M.describe(win) end)

-- Saves `rec` and redraws its tab if it's open (plan.lua's changes).
M.changed = changed

-- The plan window of plan `key`'s tab, or nil when it isn't open.
function M.plan_win(key)
  local v = views[key]
  return (alive(v) and valid_win(v.plan_win)) and v.plan_win or nil
end

-- Shows `rec` (a new revision) in its tab, if that's open.
function M.show(key, rec)
  if alive(views[key]) then with_view(views[key], function() view.rec = rec; render() end) end
end

return M
