-- lua/azure-cli/chat/plan.lua: the agent's plan - what it means to change,
-- and why - shown to the user before any code changes, like a PR in the
-- reviewer: a tab with the plan's sections on the left and the plan itself
-- (rendered markdown, from a template) on the right, the chat alongside.
--
-- The agent writes it with submit_plan (one plan per work item or PR; a
-- new call is a new revision of the same plan). The user reads it, asks
-- about any line with ga - "why did you choose this here?" - and gets the
-- answer under that line (chat/threads.lua), then approves it (gA) or asks
-- for changes (gR). gf opens the plan's file to edit it by hand; saving it
-- makes that the version the agent gets.
--
-- The gate: start_fix and start_story (chat/tools_fix.lua) refuse until the
-- plan for their PR / work item is approved (setup({ chat = { plan_first =
-- true | false | "stories" } }), default true). Pushing the change
-- (commit_and_push_fix) marks the plan done, so the next change needs a
-- plan of its own.
--
-- Kept under stdpath("data")/azure-cli-chat/plans/: <key>.md (the plan's
-- text, the file gf edits) and <key>.json (its title, status, revisions
-- and questions), key = "wi-<id>" or "pr-<id>".
--
--   pure:   key, target_label, sections, section_at, missing, gate_check,
--           approval_message, revise_message, status_label
--   Neovim: load, save, open, refresh, describe, gate, mark_done, tools
local M = {}

M.TEMPLATE = [[# <Title>

## Goal
What this change achieves, in a sentence or two.

## Approach
How you'll do it, and why this way - the alternatives you considered and why not them.

## Files
- `path/to/file` - what changes there, and why

## Risks
What could break, and how the change avoids or contains it.

## Test plan
How it gets checked: the tests you'll add or run, what to try by hand.

## Open questions
Anything the user should decide before you start (or "None").]]

local function STORE() return require("azure-cli.chat.store") end
local function UI() return require("azure-cli.ui") end
local function KEYS() return require("azure-cli.keys") end
local function THREADS() return require("azure-cli.chat.threads") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function config() return require("azure-cli.config").get().chat or {} end

function M.template() return config().plan_template or M.TEMPLATE end

-- ---------------------------------------------------------------------------
-- Pure helpers.

-- "wi-3001" for { work_item_id = 3001 }, "pr-101" for { pr_id = 101 }, nil
-- for neither.
function M.key(target)
  if type(target) ~= "table" then return nil end
  if target.work_item_id then return "wi-" .. tostring(target.work_item_id) end
  if target.pr_id then return "pr-" .. tostring(target.pr_id) end
  return nil
end

function M.target_label(target)
  if target.work_item_id then return "#" .. tostring(target.work_item_id) end
  return "PR !" .. tostring(target.pr_id)
end

-- The markdown headings of `lines`: { { title, level, line, items } },
-- items = the list entries under it (the Files section's count). Lines in
-- ``` fences don't count. Pure.
function M.sections(lines)
  local out, fenced = {}, false
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    if not fenced then
      local hashes, title = l:match("^(#+)%s+(.-)%s*$")
      if hashes and title ~= "" then
        out[#out + 1] = { title = title, level = #hashes, line = i, items = 0 }
      elseif #out > 0 and l:match("^%s*[-*+]%s+%S") then
        out[#out].items = out[#out].items + 1
      end
    end
  end
  return out
end

-- The section line `line` is in (the last heading at or above it). Pure.
function M.section_at(sections, line)
  local cur
  for _, s in ipairs(sections) do
    if s.line <= line then cur = s else break end
  end
  return cur
end

-- The template's "## " headings `markdown` doesn't have. Pure.
function M.missing(markdown, template)
  local have = {}
  for _, s in ipairs(M.sections(vim.split(markdown or "", "\n", { plain = true }))) do have[s.title:lower()] = true end
  local out = {}
  for _, s in ipairs(M.sections(vim.split(template or "", "\n", { plain = true }))) do
    if s.level == 2 and not have[s.title:lower()] then out[#out + 1] = s.title end
  end
  return out
end

-- Whether a change may start for `target`, given its plan record `rec`
-- (nil: none yet) and the plan_first setting `mode`: ok, why. Pure.
function M.gate_check(rec, mode, target)
  if mode == nil then mode = true end
  if mode == false or (mode == "stories" and not target.work_item_id) then return true end
  if rec and rec.status == "approved" then return true end
  local label = M.target_label(target)
  if not rec then
    return false, "No plan for " .. label .. " yet. Write one with submit_plan first (following its template), then "
      .. "stop and wait: the user reads it, may ask about it, and approves it before you change any code."
  end
  if rec.status == "changes_requested" then
    return false, "The user asked for changes to the plan for " .. label .. ". Revise it with submit_plan and wait "
      .. "for their approval."
  end
  if rec.status == "done" then
    return false, "The plan for " .. label .. " was implemented and pushed already. For more changes, write a new "
      .. "plan with submit_plan and wait for the user to approve it."
  end
  return false, "The plan for " .. label .. " isn't approved yet. Wait for the user - they'll tell you when it is "
    .. "(or what to change)."
end

local STATUS = {
  draft = { "\u{25CF} Waiting for your review", "AzureCliStatusDraft" },
  approved = { "\u{2713} Approved", "AzureCliStatusOk" },
  changes_requested = { "\u{21BA} Changes asked for", "AzureCliStatusBad" },
  done = { "\u{2713} Implemented", "AzureCliStatusDone" },
}
-- The status line in the section list: text, highlight group. Pure.
function M.status_label(rec)
  local s = STATUS[rec.status] or STATUS.draft
  return s[1], s[2]
end

local function last_rev(rec) return rec.revisions[#rec.revisions] end

-- What approving sends the agent. Pure.
function M.approval_message(rec)
  local label = M.target_label(rec.target)
  local rev = last_rev(rec)
  local text = "I approve the plan for " .. label .. " (revision " .. #rec.revisions .. "). Go ahead and make the "
    .. "change as planned, then show_fix it to me."
  if rev and rev.by == "you" then
    text = text .. "\n\nI edited the plan before approving - follow this version:\n\n" .. rev.markdown
  end
  return text
end

-- What asking for changes sends the agent. Pure.
function M.revise_message(rec, feedback)
  return "Please revise the plan for " .. M.target_label(rec.target) .. ": " .. feedback
    .. "\n\nSubmit the new version with submit_plan, then wait for me again."
end

-- ---------------------------------------------------------------------------
-- Storage.

function M.root() return STORE().root() .. "/plans" end
function M.path(key) return M.root() .. "/" .. key .. ".md" end

function M.load(key)
  if not key then return nil end
  local ok, lines = pcall(vim.fn.readfile, M.root() .. "/" .. key .. ".json")
  if not ok or #lines == 0 then return nil end
  local okd, rec = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not okd or type(rec) ~= "table" then return nil end
  rec.revisions = rec.revisions or {}
  rec.threads = rec.threads or {}
  return rec
end

function M.save(rec)
  vim.fn.mkdir(M.root(), "p")
  vim.fn.writefile({ vim.json.encode(rec) }, M.root() .. "/" .. rec.key .. ".json")
end

-- The plan's text as it is on disk now (the user may have edited it).
local function current_lines(rec)
  local ok, lines = pcall(vim.fn.readfile, M.path(rec.key))
  if ok and #lines > 0 then return lines end
  local rev = last_rev(rec)
  return vim.split(rev and rev.markdown or "", "\n", { plain = true })
end

-- A new revision `markdown` by `by` ("agent" / "you"): the file rewritten
-- (when the agent wrote it), the questions moved to their lines, the status
-- back to waiting for the user.
local function add_revision(rec, markdown, by)
  rec.revisions[#rec.revisions + 1] = { at = os.time(), by = by, markdown = markdown }
  local lines = vim.split(markdown, "\n", { plain = true })
  if by == "agent" then
    vim.fn.mkdir(M.root(), "p")
    vim.fn.writefile(lines, M.path(rec.key))
  end
  THREADS().reanchor(rec.threads, lines)
  rec.status = "draft"
  rec.approved_rev = nil
end

-- ---------------------------------------------------------------------------
-- The viewer.

local view = nil  -- { tab, list_win, plan_win, list_buf, plan_buf, key, rec, sections, rows, width }
local list_ns = vim.api.nvim_create_namespace("azure_cli_plan_list")

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end
local function valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end

local function key_of(surface, action)
  local k = KEYS().resolve(surface, action)
  if type(k) == "table" then k = k[1] end
  return k
end

local LIST_HELP = {
  "Sections",
  { "open", "go to the section" },
  "The plan",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", "ask for changes (you say what)" },
  { "open_file", "edit the plan by hand (saving it makes that the version the agent gets)" },
  { "refresh", "reload it" },
  { "chat", "go to the chat" },
  { "resize_less", "shrink the section list" }, { "resize_more", "grow the section list" },
  { "quit", "close" }, { "help", "this help" },
}
local PLAN_HELP = {
  "Ask",
  { "ask", "ask the agent about this line (in visual mode: these lines) - the answer shows under it" },
  { "expand_thread", "show all of the answer under this line / fold it again" },
  { "view_thread", "the question and answer in a popup" },
  { "next_thread", "next question" }, { "prev_thread", "previous question" },
  "The plan",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", "ask for changes (you say what)" },
  { "open_file", "edit the plan by hand" },
  { "back", "back to the section list" },
  { "refresh", "reload it" },
  { "chat", "go to the chat (in visual mode: send the selected lines)" },
  { "quit", "close" }, { "help", "this help" },
}

local function help(tbl)
  UI().open_float(KEYS().help_lines("plan", "Plan keys", tbl, { notes = {
    "The agent waits for you: it can't start changing code (start_fix / start_story) until you approve the plan.",
  } }), { title = "Keys", min_width = 60 })
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

local function draw_threads()
  if not (view and valid_buf(view.plan_buf)) then return end
  THREADS().draw(view.plan_buf, view.plan_win, view.rec.threads, function(th) return th.line end)
end

local function set_winbars()
  if not view then return end
  local rec = view.rec
  local short = { draft = "draft", approved = "approved", changes_requested = "changes asked", done = "done" }
  local tags = { "[" .. (short[rec.status] or "draft") .. "]" }
  if #rec.threads > 0 then tags[#tags + 1] = "[?" .. #rec.threads .. "]" end
  if last_rev(rec) and last_rev(rec).by == "you" then tags[#tags + 1] = "[edited by you]" end
  if valid_win(view.plan_win) then
    pcall(UI().wo, view.plan_win, "winbar", UI().winbar({ "Plan " .. M.target_label(rec.target),
      #rec.revisions > 1 and ("rev " .. #rec.revisions) or nil }, tags))
  end
  if valid_win(view.list_win) then
    pcall(UI().wo, view.list_win, "winbar", UI().winbar({ "Sections" }, {}))
  end
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
  add(" " .. UI().fit(M.target_label(rec.target) .. "  " .. (rec.title or ""), width - 2), "AzureCliSection")
  local st, st_hl = M.status_label(rec)
  add(" " .. st .. (#rec.revisions > 1 and ("  \u{00B7} revision " .. #rec.revisions) or ""), st_hl)
  add("")
  local per = {}
  for _, th in ipairs(rec.threads) do
    local s = M.section_at(view.sections, th.line)
    if s then per[s.line] = (per[s.line] or 0) + 1 end
  end
  for _, s in ipairs(view.sections) do
    if s.level >= 2 then
      local badge = ""
      if per[s.line] then badge = "?" .. per[s.line] end
      if s.items > 0 and s.title:lower():find("file", 1, true) then badge = (badge ~= "" and (badge .. " ") or "") .. s.items end
      local indent = string.rep("  ", math.max(0, s.level - 2))
      local name = UI().fit(indent .. s.title, math.max(8, width - 4 - #badge))
      add("   " .. name .. badge, nil)
      if badge ~= "" then hls[#hls + 1] = { #lines - 1, #lines[#lines] - #badge, "AzureCliAccent" } end
      rows[#lines] = s
    end
  end
  add("")
  local hints = {}
  if rec.status ~= "approved" and rec.status ~= "done" then
    hints[#hints + 1] = { key_of("plan", "approve"), "approve" }
    hints[#hints + 1] = { key_of("plan", "revise"), "ask for changes" }
  end
  hints[#hints + 1] = { key_of("plan", "ask"), "ask about a line" }
  hints[#hints + 1] = { key_of("plan", "open_file"), "edit it yourself" }
  hints[#hints + 1] = { key_of("plan", "help"), "all keys" }
  for _, h in ipairs(hints) do
    if h[1] then
      add(" " .. h[1] .. "  " .. h[2], "AzureCliMuted")
      hls[#hls + 1] = { #lines - 1, 1, "AzureCliKeyHint", 1 + #h[1] }
    end
  end
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
  local lines = current_lines(view.rec)
  view.sections = M.sections(lines)
  vim.bo[view.plan_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.plan_buf, 0, -1, false, lines)
  vim.bo[view.plan_buf].modifiable = false
  draw_threads()
end

local function render()
  render_plan()
  render_list()
  set_winbars()
end

-- Saves the plan and redraws the viewer if it shows it.
local function changed(rec)
  M.save(rec)
  if view and view.key == rec.key then
    view.rec = rec
    render_list()
    set_winbars()
    draw_threads()
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

local function approve()
  local rec = view and view.rec
  if not rec then return end
  if rec.status == "approved" then return notify("Already approved.") end
  if rec.status == "done" then return notify("This plan was implemented already.") end
  rec.status = "approved"
  rec.approved_rev = #rec.revisions
  rec.approved_at = os.time()
  changed(rec)
  send(M.approval_message(rec), "Approved the plan for " .. M.target_label(rec.target) .. ".")
  notify("Plan approved - the agent can change the code now.")
end

local function revise()
  local rec = view and view.rec
  if not rec then return end
  require("azure-cli.editor").open({
    title = "What should change in the plan?", initial = "", anchor = "center",
    on_submit = function(text)
      rec.status = "changes_requested"
      changed(rec)
      send(M.revise_message(rec, text), "Changes to the plan: " .. text)
    end,
  })
end

local function open_file()
  if not view then return end
  local path = M.path(view.key)
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
    local root = vim.fn.fnamemodify(M.root(), ":p"):gsub("\\", "/")
    if file:sub(1, #root) ~= root then return end
    local key = vim.fn.fnamemodify(file, ":t:r")
    local rec = M.load(key)
    if not rec then return end
    local text = table.concat(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false), "\n")
    local rev = last_rev(rec)
    if rev and rev.markdown == text then return end
    local was = rec.status
    add_revision(rec, text, "you")
    M.save(rec)
    if view and view.key == key then
      view.rec = rec
      render()
    end
    notify("Plan saved as your version" .. ((was == "approved") and " - approve it again (gA) for the agent to use it." or "."))
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
  local sec = M.section_at(view.sections, from)
  local where = (sec and ("section \"" .. sec.title .. "\", ") or "") .. (from == to and ("line " .. from)
    or ("lines " .. from .. "-" .. to))
  THREADS().ask({
    win = view.plan_win, row = to, line = to, anchor = vim.trim(lines[#lines] or ""), section = sec and sec.title,
    ctx = { what = "your plan for " .. M.target_label(rec.target) .. " (\"" .. (rec.title or "") .. "\")", where = where },
    quote = quote,
    label = "plan:" .. (from == to and from or (from .. "-" .. to)),
    threads = rec.threads,
    changed = function() changed(rec) end,
  })
end

local function bind_common(buf)
  local K = KEYS()
  K.bind(buf, "plan", "approve", approve, { desc = "approve the plan" })
  K.bind(buf, "plan", "revise", revise, { desc = "ask for changes to the plan" })
  K.bind(buf, "plan", "open_file", open_file, { desc = "edit the plan by hand" })
  K.bind(buf, "plan", "refresh", function() M.refresh() end, { desc = "reload the plan" })
  K.bind(buf, "plan", "chat", function() require("azure-cli.chat").toggle() end, { desc = "go to the chat" })
  K.bind(buf, "plan", "chat", function() require("azure-cli.chat").capture_selection() end,
    { desc = "send the selected lines to the chat", mode = "x" })
  K.bind(buf, "plan", "resize_less", function() resize(-5) end, { desc = "shrink the section list" })
  K.bind(buf, "plan", "resize_more", function() resize(5) end, { desc = "grow the section list" })
  K.bind(buf, "plan", "quit", close, { desc = "close" })
end

local function goto_section(s, focus)
  if not (s and valid_win(view.plan_win)) then return end
  pcall(vim.api.nvim_win_set_cursor, view.plan_win, { s.line, 0 })
  vim.api.nvim_win_call(view.plan_win, function() vim.cmd("normal! zt") end)
  if focus then vim.api.nvim_set_current_win(view.plan_win) end
end

local function setup_list(buf)
  local K = KEYS()
  K.bind(buf, "plan", "open", function()
    goto_section(view.rows[vim.api.nvim_win_get_cursor(0)[1]], true)
  end, { desc = "go to the section" })
  K.bind(buf, "plan", "help", function() help(LIST_HELP) end, { desc = "keys" })
  bind_common(buf)
  -- Moving through the sections scrolls the plan to each one.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local s = view and view.rows and view.rows[vim.api.nvim_win_get_cursor(0)[1]]
      if s then goto_section(s, false) end
    end,
  })
end

local function setup_plan(buf)
  local K = KEYS()
  K.bind(buf, "plan", "ask", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    ask(r, r)
  end, { desc = "ask the agent about this line" })
  K.bind(buf, "plan", "ask", function()
    local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    ask(a, b)
  end, { desc = "ask the agent about these lines", mode = "x" })
  K.bind(buf, "plan", "expand_thread", function()
    local th = thread_at_cursor()
    if not th then return notify("No question on this line (" .. (key_of("plan", "ask") or "ga") .. " asks one).") end
    THREADS().toggle(th)
    draw_threads()
  end, { desc = "show all of the answer / fold it" })
  K.bind(buf, "plan", "view_thread", function() THREADS().show(thread_at_cursor()) end, { desc = "the question and answer" })
  K.bind(buf, "plan", "next_thread", function() jump_thread(1) end, { desc = "next question" })
  K.bind(buf, "plan", "prev_thread", function() jump_thread(-1) end, { desc = "previous question" })
  K.bind(buf, "plan", "back", function()
    if valid_win(view.list_win) then vim.api.nvim_set_current_win(view.list_win) end
  end, { desc = "back to the section list" })
  K.bind(buf, "plan", "help", function() help(PLAN_HELP) end, { desc = "keys" })
  bind_common(buf)
end

-- Opens (or brings to the front, reloaded) the plan `key`.
function M.open(key)
  local rec = M.load(key)
  if not rec then return nil, "no plan " .. tostring(key) end
  UI().theme()
  if view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab) and valid_win(view.list_win)
      and valid_win(view.plan_win) then
    view.key, view.rec = key, rec
    vim.api.nvim_set_current_tabpage(view.tab)
  else
    local width = view and view.width or 32
    view = { key = key, rec = rec, width = width, sections = {}, rows = {} }
    vim.cmd("tabnew")
    view.tab = vim.api.nvim_get_current_tabpage()
    view.list_win = vim.api.nvim_get_current_win()
    view.list_buf = vim.api.nvim_get_current_buf()
    vim.bo[view.list_buf].buftype = "nofile"
    vim.bo[view.list_buf].bufhidden = "wipe"
    vim.bo[view.list_buf].filetype = "azurecli-plan"
    pcall(vim.api.nvim_buf_set_name, view.list_buf, "azure-cli://plan")
    setup_list(view.list_buf)
    vim.cmd("belowright vsplit")
    view.plan_win = vim.api.nvim_get_current_win()
    view.plan_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[view.plan_buf].buftype = "nofile"
    vim.bo[view.plan_buf].bufhidden = "wipe"
    vim.bo[view.plan_buf].filetype = "markdown"
    vim.b[view.plan_buf].azure_cli_view = "azurecli-plan"
    vim.b[view.plan_buf].azure_cli_title = "Plan"
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
    UI().wo(view.plan_win, "signcolumn", "yes:1")
    pcall(vim.api.nvim_win_set_width, view.list_win, width)
    vim.api.nvim_create_autocmd("WinResized", {
      buffer = view.list_buf,
      callback = function() vim.schedule(function() if view then render_list() draw_threads() end end) end,
    })
  end
  vim.t[view.tab].azure_cli_title = "Plan " .. M.target_label(rec.target)
  render()
  -- The plan gets the focus - again after the chat panel has followed into
  -- this tab (it opens on a scheduled callback).
  local function focus()
    if view and valid_win(view.plan_win) then vim.api.nvim_set_current_win(view.plan_win) end
  end
  focus()
  vim.schedule(function() vim.schedule(focus) end)
  return view.tab
end

function M.refresh()
  if not view then return end
  local rec = M.load(view.key)
  if not rec then return end
  view.rec = rec
  render()
end

-- The open viewer (tests): { tab, list_win, plan_win, list_buf, plan_buf, key, rec }.
function M.current() return view end

-- The chat's description of the plan window.
function M.describe(win)
  if not view then return nil end
  local rec = view.rec
  local snap = { screen = "plan", plan = { key = rec.key, title = rec.title, status = rec.status,
    revision = #rec.revisions, file = M.path(rec.key) } }
  if rec.target.work_item_id then
    snap.work_item = { id = rec.target.work_item_id }
  else
    snap.pr = require("azure-cli.chat.tools").pr_record(rec.target.pr_id) or { id = rec.target.pr_id }
  end
  snap.note = "Looking at your plan for " .. M.target_label(rec.target) .. " \"" .. tostring(rec.title) .. "\" ("
    .. (M.status_label(rec)):gsub("^%S+ ", "") .. ", revision " .. #rec.revisions .. ", file " .. snap.plan.file .. ")"
  if win == view.plan_win and valid_win(win) then
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local sec = M.section_at(view.sections, row)
    snap.plan_line, snap.plan_section = row, sec and sec.title
    snap.plan_text = vim.api.nvim_buf_get_lines(view.plan_buf, row - 1, row, false)[1]
  end
  return snap
end

require("azure-cli.chat.view").register("azurecli-plan", function(win) return M.describe(win) end)

-- ---------------------------------------------------------------------------
-- The gate (chat/tools_fix.lua).

function M.gate(target)
  return M.gate_check(M.load(M.key(target)), config().plan_first, target)
end

-- commit_and_push_fix pushed the change: its plan is done.
function M.mark_done(target)
  local rec = M.load(M.key(target))
  if rec and rec.status == "approved" then
    rec.status = "done"
    rec.done_at = os.time()
    changed(rec)
  end
end

-- ---------------------------------------------------------------------------
-- Tools (chat/tools.lua).

function M.tools(T)
  local target_props = {
    work_item_id = { type = "integer", description = "the work item the plan is for (implementing a story/bug/task)" },
    pr_id = { type = "integer", description = "the pull request the plan is for (fixing a review comment)" },
  }
  local function target_of(args)
    if args.work_item_id then return { work_item_id = args.work_item_id } end
    if args.pr_id then return { pr_id = args.pr_id } end
    return nil
  end
  return {
    {
      name = "submit_plan",
      description = "Shows the user your plan for a change - before you change any code (start_fix / start_story "
        .. "refuse until the user approves it). Give work_item_id or pr_id, a short title, and the plan in markdown "
        .. "following this template (keep its ## headings; say why for each choice, the user can ask about any line):\n\n"
        .. M.template() .. "\n\nCalling it again for the same work item / PR replaces the plan with a new revision "
        .. "(it then needs approving again). After calling it, STOP and wait: the user will approve it or ask for "
        .. "changes in the chat.",
      schema = { type = "object", properties = {
        work_item_id = target_props.work_item_id, pr_id = target_props.pr_id,
        title = { type = "string", description = "a few words" },
        markdown = { type = "string", description = "the plan, in markdown, following the template" },
      }, required = { "title", "markdown" } },
      risk = "write",
      run = function(args, _, done)
        local target = target_of(args)
        if not target then return done(nil, "give work_item_id or pr_id") end
        if type(args.markdown) ~= "string" or vim.trim(args.markdown) == "" then return done(nil, "the plan is empty") end
        local key = M.key(target)
        local rec = M.load(key) or { key = key, target = target, revisions = {}, threads = {}, created = os.time() }
        if rec.status == "done" then rec.threads = {} end
        rec.title = args.title
        add_revision(rec, args.markdown, "agent")
        M.save(rec)
        M.open(key)
        done({
          shown = true, revision = #rec.revisions, file = M.path(key),
          missing_sections = M.missing(args.markdown, M.template()),
          next = "Stop here and wait for the user: they read the plan, may ask about lines of it, then approve it "
            .. "(you'll get a message) or ask for changes. Don't call start_fix / start_story before it's approved.",
        })
      end,
    },
    {
      name = "get_plan",
      description = "Reads your plan for a work item or PR as it is now - the user may have edited it - with its "
        .. "status (draft, approved, changes_requested, done) and the questions the user asked about its lines.",
      schema = { type = "object", properties = target_props },
      risk = "read",
      run = function(args, _, done)
        local target = target_of(args)
        if not target then return done(nil, "give work_item_id or pr_id") end
        local rec = M.load(M.key(target))
        if not rec then return done(nil, "no plan for " .. M.target_label(target) .. " - write one with submit_plan") end
        local qs = {}
        for _, th in ipairs(rec.threads) do
          qs[#qs + 1] = { line = th.line, about = th.anchor, question = th.question, answer = th.answer }
        end
        local rev = last_rev(rec)
        done({ title = rec.title, status = rec.status, revision = #rec.revisions,
          edited_by_user = rev and rev.by == "you" or false,
          markdown = table.concat(current_lines(rec), "\n"), questions = qs })
      end,
    },
  }
end

return M
