-- lua/azure-cli/chat/plan_view.lua: the plan's tab (chat/plan.lua's open,
-- refresh, current, open_views, describe, describe_view): the section list
-- on the left with the keys that matter now, the plan as rendered markdown
-- with the questions and requested changes under its lines, the chat
-- alongside. Saving a plan's file by hand makes it a revision by you.
-- Once the agent has changed files, the list's Changes section shows its
-- diff, file by file, in the plan pane (chat/plan_changes.lua). gh opens
-- an older revision in the plan pane, read-only (view.old = its number):
-- the questions it had, no keys that write, gh again (or anything that
-- reloads the plan) back to the current one; gi there goes back to the
-- current one marking what changed since it (view.since_base).
--
-- plan.lua loads it on its own load and reaches into it through M.changed
-- (save + redraw), M.plan_win and M.show; it reaches plan.lua lazily
-- (PLAN()), since plan.lua requires it while still loading.
local M = {}

local function PLAN() return require("azure-cli.chat.plan") end
local function UI() return require("azure-cli.ui") end
local function KEYS() return require("azure-cli.keys") end
local function THREADS() return require("azure-cli.chat.threads") end
-- The Changes section (the agent's diff): its own module, see its top.
local function PC() return require("azure-cli.chat.plan_changes") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function last_rev(rec) return rec.revisions[#rec.revisions] end

-- One view per plan - its own tab - so several plans can be open at once.
-- `view` is the one being worked on: every key, autocmd and callback
-- points it at its own plan's view first (use_buf / with_view), and the
-- functions below read it.
local view = nil  -- { tab, list_win, plan_win, list_buf, plan_buf, key, rec, sections, rows, width, old }
local views = {}  -- plan key -> its view
local by_buf = {} -- buffer -> the view it belongs to
local goto_code, unanswered, unsent  -- forward
local list_ns = vim.api.nvim_create_namespace("azure_cli_plan_list")

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end
local function valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end

local function key_of(surface, action) return KEYS().first(surface, action) end

local LIST_HELP = {
  "Navigate",
  { "open", "go to the section - a file under Changes: its diff in the plan pane" },
  { "next_thread", "move the plan to the next open question or thread, in line order (answered ones too)" },
  { "prev_thread", "move the plan to the previous open question or thread" },
  "Decide",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", "ask for changes or send your answers (you say what; your unsent answers go along)" },
  { "open_file", "edit the plan by hand (saving it makes that the version the agent gets)" },
  { "discard", "discard this plan, its worktree and local branch - asks first (as dd on Agents)" },
  "See",
  { "open_pr", "its pull request in the reviewer (the one its agent opened, or the one it fixes)" },
  { "since", "a bar beside the lines this revision changed against the one before (on by default; toggles) - "
    .. "on an older revision: the current one, marked against that one" },
  { "revisions", "open an older revision, read-only (on one: back to the current one)" },
  { "run_log", "the run log: revisions, questions, approvals, tests, the agent's tool calls" },
  { "refresh", "reload it" },
  { "chat_input", "type in the chat (opens the panel; a draft stays)" },
  "Window",
  { "resize_less", "shrink the section list" }, { "resize_more", "grow the section list" },
  { "quit", "close" }, { "help", "this help" },
}
local PLAN_HELP = {
  "Navigate",
  { "next_thread", "next open question or thread, in line order (answered ones too)" },
  { "prev_thread", "previous open question or thread" },
  { "goto_code", "the code this line became (a linked step, or a Files entry's file)" },
  { "back", "back to the section list" },
  "Ask the agent",
  { "ask", "ask the agent about this line (in visual mode: these lines) - the answer shows under it" },
  { "request", function()
    return "queue a change on this line (in visual mode: these lines) - " .. KEYS().name("plan", "revise")
      .. " sends them together"
  end },
  { "answer", function()
    return "answer the open question under the cursor - " .. KEYS().name("plan", "revise")
      .. " sends your answers (approving does too)"
  end },
  { "expand_thread", "show all of the answer under this line / fold it again" },
  { "view_thread", "the question and answer in a popup" },
  { "delete_thread", "drop the queued change under this line (asks first), or forget the question - a sent change stays" },
  { "edit_request", "edit the queued change under this line" },
  "Decide",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", function()
    return "ask for changes or send your answers: what you write, plus the changes queued on lines ("
      .. KEYS().name("plan", "request") .. ") and your unsent answers"
  end },
  { "open_file", "edit the plan by hand" },
  { "discard", "discard this plan, its worktree and local branch - asks first (as dd on Agents)" },
  "See",
  { "open_pr", "its pull request in the reviewer (the one its agent opened, or the one it fixes)" },
  { "since", "a bar beside the lines this revision changed against the one before (on by default; toggles) - "
    .. "on an older revision: the current one, marked against that one" },
  { "revisions", "open an older revision, read-only (on one: back to the current one)" },
  { "run_log", "the run log: revisions, questions, approvals, tests, the agent's tool calls" },
  { "refresh", "reload it" },
  { "chat_input", "type in the chat (opens the panel; a draft stays)" },
  { "chat_selection", "in visual mode: send the selected lines to the chat" },
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

-- The keys that write, or work on the current text's threads and lines:
-- on an older revision (gh) they only say it's read-only.
local CURRENT_ONLY = {
  ask = true, request = true, answer = true, delete_thread = true, edit_request = true, expand_thread = true,
  view_thread = true, approve = true, revise = true, open_file = true, goto_code = true,
}

-- KEYS().bind for the plan surface, on a buffer of one plan's view: the
-- key works on that view.
local function bind(buf, action, fn, opts)
  KEYS().bind(buf, "plan", action, function(...)
    use_buf(buf)
    if view and view.old and CURRENT_ONLY[action] then
      return notify("Revision " .. view.old .. " is read-only - " .. (key_of("plan", "revisions") or "gh")
        .. " back to the current one.")
    end
    return fn(...)
  end, opts)
end

-- The older revision shown instead of the current one (gh), or nil.
local function old_rev()
  return view and view.old and PLAN().revision(view.rec, view.old) or nil
end

local function close()
  if view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
    -- An inner tab of Agents: back to the one before it (innertabs.lua).
    if vim.api.nvim_get_current_tabpage() == view.tab then pcall(require("azure-cli.innertabs").closing) end
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
  if view.old then return end  -- the steps carry out the current text
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

-- What this revision changed against the one before it - or the one gi
-- picked on an older revision (view.since_base), while it's kept - (its
-- number in view.changes_since), or nil (the first revision, gi turned it
-- off, an older one shown): revision_changes' { changed, removed }.
local function since()
  local revs = view.rec.revisions
  view.changes_since = nil
  if view.since_off or view.old or #revs < 2 then return nil end
  local base = PLAN().revision(view.rec, view.since_base)
  if not base or base == revs[#revs] then base, view.since_base = revs[#revs - 1], nil end
  view.changes_since = base.n or (#revs - 1)
  local old = vim.split(base.markdown or "", "\n", { plain = true })
  local new = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local diff = (vim.text and vim.text.diff) or vim.diff
  local ok, hunks = pcall(diff, table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n",
    { result_type = "indices" })
  return PLAN().revision_changes(old, new, ok and hunks or {})
end

-- The bar beside each line this revision changed - only that: the text it
-- took out isn't shown (#90; gh opens the revision before).
local function draw_since()
  if not (view and valid_buf(view.plan_buf)) then return end
  vim.api.nvim_buf_clear_namespace(view.plan_buf, since_ns, 0, -1)
  local ch = since()
  view.changes = ch
  if not ch then return end
  for l in pairs(ch.changed) do
    pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, since_ns, l - 1, 0,
      { sign_text = "\u{258E}", sign_hl_group = "AzureCliPlanChanged", priority = 5 })
  end
end

-- The questions and requests under their lines - on an older revision,
-- the ones it had when the next replaced it.
local function draw_threads()
  if not (view and valid_buf(view.plan_buf)) then return end
  local threads = view.old and ((old_rev() or {}).threads or {}) or view.rec.threads
  THREADS().draw(view.plan_buf, view.plan_win, threads, function(th) return th.line end,
    { send = KEYS().name("plan", "revise"), drop = key_of("plan", "delete_thread"), edit = key_of("plan", "edit_request") })
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
  local not_sent = unsent()
  if not_sent > 0 and rec.status ~= "approved" and rec.status ~= "done" then
    tags[#tags + 1] = "[" .. not_sent .. " answer" .. (not_sent == 1 and "" or "s") .. " unsent]"
  end
  if view.changes then tags[#tags + 1] = "[\u{00B1} since rev " .. tostring(view.changes_since) .. "]" end
  local count = PLAN().rev_count(rec)
  if PC().showing(view) then
    PC().winbar(view)  -- a file of the Changes section is in the plan pane
  elseif view.old and valid_win(view.plan_win) then
    -- An older revision (gh): which one, and the way back.
    pcall(UI().wo, view.plan_win, "winbar", UI().winbar({ "Plan " .. PLAN().target_label(rec.target),
      "rev " .. view.old .. " of " .. count, "read-only" },
      { "[" .. (key_of("plan", "revisions") or "gh") .. " back to the current one]",
        "[" .. (key_of("plan", "since") or "gi") .. " the current one against it]" }))
  elseif valid_win(view.plan_win) then
    pcall(UI().wo, view.plan_win, "winbar", UI().winbar({ "Plan " .. PLAN().target_label(rec.target),
      count > 1 and ("rev " .. count) or nil }, tags))
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
  local count = PLAN().rev_count(rec)
  add(" " .. st .. (count > 1 and ("  \u{00B7} revision " .. count) or ""), st_hl)
  if view.old then
    add(" " .. UI().fit("revision " .. view.old .. " of " .. count .. " \u{00B7} read-only \u{00B7} "
      .. KEYS().name("plan", "revisions") .. " back", width - 2), "AzureCliAccent")
  end
  local decided = rec.status == "approved" or rec.status == "done"
  -- Answers you gave that the agent hasn't seen yet, and the key that sends them.
  local not_sent = unsent()
  if not_sent > 0 and not decided then
    local what = not_sent .. " answer" .. (not_sent == 1 and "" or "s") .. " unsent - "
    local how = KEYS().name("plan", "revise") .. " sends " .. (not_sent == 1 and "it" or "them")
    -- On two lines when the list is too narrow for one.
    if vim.fn.strdisplaywidth(what .. how) <= width - 2 then
      add(" " .. what .. how, "AzureCliAccent")
    else
      add(" " .. UI().fit(vim.trim(what), width - 2), "AzureCliAccent")
      add("   " .. UI().fit(how, width - 4), "AzureCliAccent")
    end
  end
  add("")
  local per, per_req = {}, {}
  -- An older revision's sections: no badges, the threads are the current one's.
  for _, th in ipairs(view.old and {} or rec.threads) do
    local s = PLAN().section_at(view.sections, th.line)
    -- Your answers aren't questions: the header's [?N] skips them too.
    local into = th.kind == "request" and per_req or th.kind ~= "answer" and per or nil
    if s and into and not (th.kind == "request" and th.status == "sent") then into[s.line] = (into[s.line] or 0) + 1 end
  end
  local open_q = unanswered()
  for _, s in ipairs(view.sections) do
    if s.level >= 2 then
      local badge = ""
      if per[s.line] then badge = "?" .. per[s.line] end
      if per_req[s.line] then badge = (badge ~= "" and (badge .. " ") or "") .. "\u{270E}" .. per_req[s.line] end
      if section_changed(s) then badge = (badge ~= "" and (badge .. " ") or "") .. "\u{00B1}" end
      if s.items > 0 and s.title:lower():find("file", 1, true) then badge = (badge ~= "" and (badge .. " ") or "") .. s.items end
      if open_q > 0 and not decided and not view.old and s.level == 2 and s.title:lower():find("question", 1, true) then
        badge = (badge ~= "" and (badge .. " ") or "") .. open_q .. " to answer"
      end
      local indent = string.rep("  ", math.max(0, s.level - 2))
      local name = UI().fit(indent .. s.title, math.max(8, width - 4 - vim.fn.strdisplaywidth(badge)))
      add("   " .. name .. badge, nil)
      if badge ~= "" then hls[#hls + 1] = { #lines - 1, #lines[#lines] - #badge, "AzureCliAccent" } end
      rows[#lines] = s
    end
  end
  -- The agent's change, when there is one (chat/plan_changes.lua).
  local cl, chls, crows = PC().list_rows(view.key, width)
  if #cl > 0 then
    add("")
    local from = #lines
    for i, l in ipairs(cl) do
      lines[#lines + 1] = l
      rows[#lines] = crows[i]
    end
    for _, h in ipairs(chls) do hls[#hls + 1] = { from + h[1], h[2], h[4], h[3] } end
  end
  add("")
  local hints = {}
  if view.old then
    -- An older revision: only the way back (the other keys need the current one).
    hints[#hints + 1] = { "plan", "revisions", "back to the current revision" }
    hints[#hints + 1] = { "plan", "since", "the current one, marking what changed since this" }
    hints[#hints + 1] = { "plan", "run_log", "what happened so far" }
  else
    if not decided then
      hints[#hints + 1] = { "plan", "approve", "approve" }
      hints[#hints + 1] = { "plan", "revise", not_sent > 0 and "send your answers / ask for changes" or "ask for changes" }
    end
    hints[#hints + 1] = { "plan", "ask", "ask about a line" }
    if not decided then hints[#hints + 1] = { "plan", "request", "ask a change on a line" } end
    if select(2, THREADS().counts(rec.threads)) > 0 then
      hints[#hints + 1] = { "plan", "delete_thread", "drop a queued change" }
    end
    if open_q > 0 then hints[#hints + 1] = { "plan", "answer", "answer an open question" } end
    if decided then
      hints[#hints + 1] = { "plan", "goto_code", "the code a step became" }
      hints[#hints + 1] = { "plan", "run_log", "what happened so far" }
    else
      hints[#hints + 1] = { "plan", "open_file", "edit it yourself" }
      hints[#hints + 1] = { "plan", "discard", "discard the plan" }
    end
    if count > 1 then hints[#hints + 1] = { "plan", "revisions", "open an older revision" } end
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
  -- An older revision (gh) gone - pruned meanwhile: the current one.
  local old = old_rev()
  if not old then view.old = nil end
  local lines = old and vim.split(old.markdown or "", "\n", { plain = true }) or PLAN().lines(view.rec)
  view.sections = PLAN().sections(lines)
  vim.bo[view.plan_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.plan_buf, 0, -1, false, lines)
  vim.bo[view.plan_buf].modifiable = false
  draw_threads()
end

-- The plan pane's options for the plan's text (a diff of the Changes
-- section sets its own).
local function plan_window(win)
  UI().plain_window(win, {})
  UI().wo(win, "wrap", true)
  UI().wo(win, "linebreak", true)
  UI().wo(win, "breakindent", true)
  UI().wo(win, "conceallevel", 2)
  UI().wo(win, "concealcursor", "")
  UI().wo(win, "signcolumn", "yes:2")
  pcall(UI().wo, win, "statuscolumn", "")
  pcall(UI().wo, win, "foldmethod", "manual")
end

-- The plan's text back in the plan pane, when a diff was there.
local function back_to_plan()
  if view and PC().back(view) then
    plan_window(view.plan_win)
    set_winbars()
    draw_threads()
  end
end

-- Reads the agent's change for the Changes section (async); redraws the
-- list - and the diff in the plan pane, if one is there - when it changed.
local function load_changes()
  local v = view
  PC().load(v.key, v.rec, function()
    if not alive(v) then return end
    with_view(v, function()
      local shown = PC().showing(view)
      if shown and not PC().show(view, shown, false) then back_to_plan() end
      render_list()
      set_winbars()
    end)
  end)
end

local function render()
  render_plan()
  draw_since()
  render_list()
  set_winbars()
  load_changes()
end

-- From an older revision (gh) back to the current one: true when it was
-- on one.
local function to_current()
  if not (view and view.old) then return false end
  view.old = nil
  render()
  return true
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

-- Sends `text` to the agent that wrote the plan: its own conversation when
-- it has one (a board agent), as approving does, else the panel's.
local function send(text, display)
  local CHAT = require("azure-cli.chat")
  local conv = view and CHAT.find_conversation(view.key)
  if (conv and conv.running) or (not conv and CHAT.busy()) then
    notify("The agent is still answering - tell it once it's done (it can read the plan with get_plan).",
      vim.log.levels.WARN)
    return false
  end
  return CHAT.send(text, { conv = conv, view_win = valid_win(view and view.plan_win) and view.plan_win or nil,
    display = display }) ~= nil
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
-- a line with gc and your answers to the open questions. With only
-- answers waiting it opens ready to send just those.
local function revise()
  local rec = view and view.rec
  if not rec then return end
  local queued = {}
  for _, th in ipairs(rec.threads) do
    if th.kind == "request" and th.status ~= "sent" then queued[#queued + 1] = th end
  end
  local answers = unsent()
  local extra = {}
  if #queued > 0 then extra[#extra + 1] = "+" .. #queued .. " on its lines" end
  if answers > 0 then extra[#extra + 1] = "+" .. answers .. " answer" .. (answers == 1 and "" or "s") end
  local suffix = #extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or ""
  local initial = ""
  if #queued > 0 and answers > 0 then
    initial = "See my comments on its lines and my answers to your questions."
  elseif #queued > 0 then
    initial = "See my comments on its lines."
  elseif answers > 0 then
    initial = "See my answers to your questions."
  end
  require("azure-cli.editor").open({
    title = "What should change in the plan?" .. suffix, initial = initial, anchor = "center",
    on_submit = function(text)
      view = views[rec.key] or view
      if send(PLAN().revise_message(rec, text, queued, PLAN().lines(rec)), "Changes to the plan: " .. text .. suffix) then
        rec.status = "changes_requested"
        for _, th in ipairs(queued) do th.status = "sent" end
        for _, th in ipairs(rec.threads) do if th.kind == "answer" then th.status = "sent" end end
        PLAN().add_event(rec, "changes", "You asked for changes: " .. text .. suffix)
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
    title = "Change \u{00B7} plan:" .. (from == to and from or (from .. "-" .. to)) .. " (queued for " .. KEYS().name("plan", "revise") .. ")",
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
-- sent by gR (on its own, or with a change request) or with the approval.
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

-- The current revision's lines: the plan pane's, unless it shows an older one.
local function current_lines()
  if view.old then return PLAN().lines(view.rec) end
  return valid_buf(view.plan_buf) and vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false) or {}
end

-- How many of the plan's open questions you haven't answered.
unanswered = function()
  return PLAN().unanswered(current_lines(), view.rec.threads)
end

-- How many of your answers haven't gone to the agent yet.
unsent = function()
  return PLAN().unsent_answers(current_lines(), view.rec.threads)
end

local function already_sent()
  notify("That change was sent to the agent already - it stays as history.")
end

-- Back to plan view `v`'s plan window once a popup it opened is answered,
-- so the keys that follow go to the plan, not the chat's input.
local function refocus(v)
  if alive(v) and vim.api.nvim_get_current_tabpage() == v.tab then
    pcall(vim.api.nvim_set_current_win, v.plan_win)
  end
end

-- dd: drop the change queued under the cursor (after asking), or forget
-- the question there. A change already sent stays, as history.
local function delete_here()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local th, i, what = THREADS().pick_at_line(view.rec.threads, row)
  if not th then return notify("Nothing under this line.") end
  if what == "sent" then return already_sent() end
  if what == "thread" then
    table.remove(view.rec.threads, i)
    return changed(view.rec)
  end
  local v, rec = view, view.rec
  require("azure-cli.prompt").confirm({ title = "Drop this queued change?",
    prompt = "It won't be sent to the agent.", details = th.question }, function(yes)
    refocus(v)
    if not yes then return end
    for j, t in ipairs(rec.threads) do
      if t == th then table.remove(rec.threads, j) break end
    end
    changed(rec)
    local _, r = THREADS().counts(rec.threads)
    notify("Dropped" .. (r > 0 and (" - " .. r .. " change" .. (r == 1 and "" or "s") .. " still queued.") or "."))
  end)
end

-- cc: edit the change queued under the cursor.
local function edit_here()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local th, _, what = THREADS().pick_at_line(view.rec.threads, row)
  if what == "sent" then return already_sent() end
  if what ~= "queued" then
    return notify("No queued change on this line (" .. (key_of("plan", "request") or "gc") .. " queues one).")
  end
  local rec = view.rec
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, row - 1, row, false)
  require("azure-cli.editor").open({
    title = "Change \u{00B7} plan:" .. row .. " (queued for " .. KEYS().name("plan", "revise") .. ")",
    initial = th.question or "", anchor = { win = view.plan_win, row = row }, context_lines = lines,
    on_submit = function(text)
      th.question, th.at = text, os.time()
      changed(rec)
    end,
  })
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
        view.rec, view.old = rec, nil
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

-- ]t / [t: the next / previous of the plan's open questions (answered or
-- not) and threads, in line order. Moves the plan window's cursor, so from
-- the section list too - which keeps its own cursor (moving it would send
-- the plan back to the section). From an older revision: the current one's.
local function jump_thread(dir)
  if not valid_win(view.plan_win) then return end
  back_to_plan()
  to_current()
  local row = vim.api.nvim_win_get_cursor(view.plan_win)[1]
  local stops = PLAN().jump_stops(vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false), view.rec.threads)
  local best
  for _, l in ipairs(stops) do
    if dir > 0 and l > row then best = l break end
    if dir < 0 and l < row then best = l end
  end
  if not best then
    return notify(dir > 0 and "No further questions or threads." or "No earlier questions or threads.")
  end
  vim.api.nvim_win_set_cursor(view.plan_win, { best, 0 })
  vim.api.nvim_win_call(view.plan_win, function() vim.cmd("normal! zz") end)
end

-- gh: an older revision of the plan in the plan pane, read-only - picked
-- from the ones kept, newest first, with who wrote it and when; on an
-- older one, back to the current one.
local function revisions()
  if to_current() then
    return notify("Back to the current revision (" .. PLAN().rev_count(view.rec) .. ").")
  end
  local rec = view.rec
  if #rec.revisions < 2 then return notify("This is the only revision of the plan.") end
  local cur, approved = PLAN().rev_count(rec), PLAN().last_approved(rec)
  local items = {}
  for i = #rec.revisions, 1, -1 do items[#items + 1] = rec.revisions[i] end
  local v = view
  require("azure-cli.prompt").select({ prompt = "Open which revision (read-only)", items = items,
    format = function(r)
      local tags = {}
      if r.n == cur then tags[#tags + 1] = "current" end
      if r.n == approved then tags[#tags + 1] = "approved" end
      return "rev " .. tostring(r.n) .. (#tags > 0 and (" (" .. table.concat(tags, ", ") .. ")") or "")
        .. " \u{00B7} " .. (r.by == "you" and "by you" or "by the agent")
        .. (r.at and (" \u{00B7} " .. os.date("%m-%d %H:%M", r.at)) or "")
    end }, function(r)
      if not (r and alive(v)) then return end
      with_view(v, function()
        back_to_plan()
        view.old = r.n ~= cur and r.n or nil
        render()
        if view.old then pcall(vim.api.nvim_win_set_cursor, view.plan_win, { 1, 0 }) end
      end)
      refocus(v)
    end)
end

-- gi: the marks of what this revision changed, on or off - on an older
-- revision, back to the current one marked against that one.
local function since_key()
  if view.old then
    view.since_base, view.since_off, view.old = view.old, false, nil
  else
    view.since_off, view.since_base = not view.since_off, nil
  end
  render()
  notify(view.since_off and "Not marking what changed." or (view.changes and "Marking what changed since revision "
    .. tostring(view.changes_since) .. ".") or "This is the first revision.")
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

-- PR `key` (hosts.lua's; `id` its number) in the reviewer - gp in a plan
-- and on an Agents row. Looked up on the server when the dashboard doesn't
-- list it (a completed one).
function M.open_pr(key, id)
  local TOOLS = require("azure-cli.chat.tools")
  local function go(found) require("azure-cli.dashboard").open_pr_by_record(found) end
  local known = TOOLS.pr_record(key)
  if known then return go(known) end
  if not id then return notify("PR " .. tostring(key) .. " isn't on the dashboard.") end
  TOOLS.fetch_pr(id, function(found, err)
    vim.schedule(function()
      if found then go(found) else notify(err or ("PR !" .. tostring(id) .. " wasn't found."), vim.log.levels.WARN) end
    end)
  end)
end

-- gp: the PR the plan's agent opened, or the one a PR fix's plan fixes
-- (gp there comes back).
local function open_pr()
  local rec = view and PLAN().load(view.key)
  if not rec then return end
  local t, pr = rec.target or {}, type(rec.pr) == "table" and rec.pr or {}
  local key = pr.key or t.pr_key or pr.id or t.pr_id
  if not key then
    return notify("This plan has no pull request yet - its agent opens one once the plan is carried out.")
  end
  M.open_pr(key, pr.id or t.pr_id)
end

local function bind_common(buf)
  bind(buf, "approve", approve, { desc = "approve the plan" })
  bind(buf, "revise", revise, { desc = "ask for changes / send your answers" })
  bind(buf, "open_file", open_file, { desc = "edit the plan by hand" })
  bind(buf, "refresh", function() M.refresh() end, { desc = "reload the plan" })
  bind(buf, "chat_input", function() require("azure-cli.chat").show(true) end,
    { desc = "type in the chat (opens the panel; a draft stays)" })
  bind(buf, "chat_selection", function() require("azure-cli.chat").capture_selection() end,
    { desc = "send the selected lines to the chat", mode = "x" })
  bind(buf, "resize_less", function() resize(-5) end, { desc = "shrink the section list" })
  bind(buf, "resize_more", function() resize(5) end, { desc = "grow the section list" })
  bind(buf, "quit", close, { desc = "close" })
  bind(buf, "run_log", function() PLAN().open_run_log(view.key) end, { desc = "everything that happened, as one page" })
  -- gD: Agents' dd from here (#103) - asks first, then closes this tab.
  bind(buf, "discard", function() require("azure-cli.chat.plan_discard").ask({ key = view.key }) end,
    { desc = "discard this plan (asks first)" })
  bind(buf, "open_pr", open_pr, { desc = "its pull request, in the reviewer" })
end

local function goto_section(s, focus)
  if not (s and s.line and valid_win(view.plan_win)) then return end
  back_to_plan()
  pcall(vim.api.nvim_win_set_cursor, view.plan_win, { s.line, 0 })
  vim.api.nvim_win_call(view.plan_win, function() vim.cmd("normal! zt") end)
  if focus then vim.api.nvim_set_current_win(view.plan_win) end
end

-- A row of the section list: a section scrolls the plan to it, a file of
-- the Changes section shows its diff in the plan pane (the Changes row
-- itself its first file, on Enter).
local function goto_row(r, focus)
  if r and r.changes and focus then
    local st = PC().state(view.key)
    r = st and { file = st.files[1].path }
  end
  if r and r.file then
    to_current()  -- the change carries out the current revision
    if PC().show(view, r.file, focus) then set_winbars() end
  elseif r and r.line then
    goto_section(r, focus)
  end
end

local function setup_list(buf)
  bind(buf, "open", function()
    goto_row(view.rows[vim.api.nvim_win_get_cursor(0)[1]], true)
  end, { desc = "go to the section (a changed file: its diff)" })
  bind(buf, "next_thread", function() jump_thread(1) end, { desc = "move the plan to the next open question or thread" })
  bind(buf, "prev_thread", function() jump_thread(-1) end, { desc = "move the plan to the previous open question or thread" })
  bind(buf, "revisions", revisions, { desc = "open an older revision, read-only / back to the current one" })
  bind(buf, "since", since_key, { desc = "mark what this revision changed (toggle)" })
  bind(buf, "help", function() help(LIST_HELP) end, { desc = "keys" })
  bind_common(buf)
  -- Moving through the sections scrolls the plan to each one.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      use_buf(buf)
      local s = view and view.rows and view.rows[vim.api.nvim_win_get_cursor(0)[1]]
      if s then goto_row(s, false) end
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
  bind(buf, "view_thread", function() THREADS().show(thread_at_cursor(),
    { send = KEYS().name("plan", "revise"), ask = KEYS().name("plan", "ask") }) end, { desc = "the question and answer" })
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
  bind(buf, "delete_thread", delete_here, { desc = "drop the queued change (asks first) / forget the question here" })
  bind(buf, "edit_request", edit_here, { desc = "edit the queued change under this line" })
  bind(buf, "answer", answer_here, { desc = "answer this open question" })
  bind(buf, "since", since_key, { desc = "mark what this revision changed (toggle)" })
  bind(buf, "next_thread", function() jump_thread(1) end, { desc = "next open question or thread" })
  bind(buf, "prev_thread", function() jump_thread(-1) end, { desc = "previous open question or thread" })
  bind(buf, "back", function()
    if valid_win(view.list_win) then vim.api.nvim_set_current_win(view.list_win) end
  end, { desc = "back to the section list" })
  bind(buf, "goto_code", function() goto_code() end, { desc = "the code this line became" })
  bind(buf, "revisions", revisions, { desc = "open an older revision, read-only / back to the current one" })
  bind(buf, "help", function() help(PLAN_HELP) end, { desc = "keys" })
  bind_common(buf)
end

-- What the Changes section needs from the plan view (plan_changes.lua's
-- M.hooks): the plan's keys on a diff buffer (it binds the diff's own on
-- top), sending to the plan's agent, redrawing the list.
PC().hooks = {
  bind = function(v, buf)
    by_buf[buf] = v
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() by_buf[buf] = nil end })
    bind(buf, "back", function()
      if valid_win(view.list_win) then vim.api.nvim_set_current_win(view.list_win) end
    end, { desc = "back to the section list" })
    bind(buf, "help", function() help(PLAN_HELP) end, { desc = "keys" })
    bind_common(buf)
  end,
  send = function(v, text, display)
    local ok = false
    with_view(v, function() ok = send(text, display) end)
    return ok
  end,
  redraw = function(v)
    if alive(v) then with_view(v, function() render_list() set_winbars() end) end
  end,
}

-- What the plan's inner tab shows in the Agents strip (innertabs.lua).
local function strip_title(rec)
  return vim.trim(PLAN().target_label(rec.target) .. " " .. tostring(rec.title or ""))
end

-- Builds plan `key`'s two panes in the current (new) tab, for view `v`.
local function build(v, key)
  v.tab = vim.api.nvim_get_current_tabpage()
  v.list_win = vim.api.nvim_get_current_win()
  v.list_buf = vim.api.nvim_get_current_buf()
  by_buf[v.list_buf] = v
  vim.bo[v.list_buf].buftype = "nofile"
  vim.bo[v.list_buf].bufhidden = "wipe"
  vim.bo[v.list_buf].filetype = "azurecli-plan"
  pcall(vim.api.nvim_buf_set_name, v.list_buf, "azure-cli://plan/" .. key .. "/sections")
  setup_list(v.list_buf)
  vim.cmd("belowright vsplit")
  v.plan_win = vim.api.nvim_get_current_win()
  v.plan_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[v.plan_buf].buftype = "nofile"
  vim.bo[v.plan_buf].bufhidden = "wipe"
  vim.bo[v.plan_buf].filetype = "markdown"
  vim.b[v.plan_buf].azure_cli_view = "azurecli-plan"
  vim.b[v.plan_buf].azure_cli_title = "Plan"
  by_buf[v.plan_buf] = v
  pcall(vim.api.nvim_buf_set_name, v.plan_buf, "azure-cli://plan/" .. key)
  vim.api.nvim_win_set_buf(v.plan_win, v.plan_buf)
  pcall(vim.treesitter.start, v.plan_buf, "markdown")
  setup_plan(v.plan_buf)
  UI().plain_window(v.list_win, { cursorline = true })
  plan_window(v.plan_win)
  pcall(vim.api.nvim_win_set_width, v.list_win, v.width)
  vim.api.nvim_create_autocmd("WinResized", {
    buffer = v.list_buf,
    callback = function()
      vim.schedule(function() if alive(v) then with_view(v, function() render_list() draw_threads() end) end end)
    end,
  })
  -- The tab went: forget its view.
  for _, b in ipairs({ v.list_buf, v.plan_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = b, once = true, callback = function()
      by_buf[b] = nil
      if views[key] == v then views[key] = nil end
      -- The Changes section's diff buffers (and the plan's text, kept
      -- loaded while a diff was in its window).
      if b == v.list_buf then PC().forget(key, v) end
    end })
  end
end

-- Opens plan `key` as an inner tab of Agents (innertabs.lua; a tab of its
-- own when Agents isn't open), at plan line `line` when given. Already
-- open: goes to its tab as it was (cursor, section, Changes file, older
-- revision) - reloaded only for `line` (gp) or a newer revision.
function M.open(key, line)
  local rec = PLAN().load(key)
  if not rec then return nil, "no plan " .. tostring(key) end
  UI().theme()
  local INNER = require("azure-cli.innertabs")
  local had = views[key]
  if alive(had) and not line and PLAN().rev_count(rec) == PLAN().rev_count(had.rec) then
    view = had
    vim.api.nvim_set_current_tabpage(view.tab)
    vim.cmd("redrawtabline")
    pcall(function() require("azure-cli.chat").sync_active() end)
    return view.tab
  end
  if alive(had) then
    view = had
    view.rec, view.old = rec, nil
    vim.api.nvim_set_current_tabpage(view.tab)
    INNER.retitle(view.tab, nil, strip_title(rec))
  else
    -- Its tab with a pane closed by hand: closed, so the strip doesn't
    -- send this back to it.
    if had and had.tab and vim.api.nvim_tabpage_is_valid(had.tab) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(had.tab))
    end
    local v = { key = key, rec = rec, width = view and view.width or 32, sections = {}, rows = {} }
    views[key] = v
    INNER.open("agents", INNER.plan_key(key), strip_title(rec), function() build(v, key) end)
    if not v.tab then
      views[key] = nil
      return nil, "couldn't open the plan " .. tostring(key)
    end
    view = v
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
  view.rec, view.old = rec, nil
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
    revision = PLAN().rev_count(rec), viewing_revision = view.old, file = PLAN().path(rec.key) } }
  if rec.target.work_item_id then
    snap.work_item = { id = rec.target.work_item_id, board = rec.target.item_key and "github" or nil,
      key = rec.target.item_key }
  else
    snap.pr = require("azure-cli.chat.tools").pr_record(rec.target.pr_key or rec.target.pr_id) or { id = rec.target.pr_id }
  end
  snap.note = "Looking at your plan for " .. PLAN().target_label(rec.target) .. " \"" .. tostring(rec.title) .. "\" ("
    .. (PLAN().status_label(rec)):gsub("^%S+ ", "") .. ", revision " .. snap.plan.revision .. ", file " .. snap.plan.file .. ")"
  if view.old then
    snap.note = snap.note .. " - reading its older revision " .. view.old .. " (read-only; the plan is revision "
      .. snap.plan.revision .. ")"
  end
  local diff = win == view.plan_win and PC().describe(view, win)
  if diff then
    -- A file of the Changes section: the line of the change under the cursor.
    snap.file, snap.line, snap.side, snap.code_line, snap.worktree = diff.file, diff.line, diff.side, diff.code_line,
      diff.worktree
    snap.note = snap.note .. " - its Changes section, your change to " .. diff.file
      .. (diff.line and (" line " .. diff.line) or "")
  elseif win == view.plan_win and valid_win(win) then
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
  if alive(views[key]) then
    with_view(views[key], function() view.rec, view.old = rec, nil; render() end)
    require("azure-cli.innertabs").retitle(views[key].tab, nil, strip_title(rec))
  end
end

return M
