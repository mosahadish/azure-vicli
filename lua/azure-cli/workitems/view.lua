-- lua/azure-cli/workitems/view.lua: read-only work-item detail view (opened
-- from workitems/dashboard.lua).
--
-- Reads AZVICLI_WI_ID from the environment, fetches the item + its parent and
-- children + flattened description via the headless provider (azure-cli.py
-- --wi-detail), and renders them into a scratch buffer. Parent/child lines
-- are navigable with <CR>.
--
-- Keys
--   <CR>   on a parent/child line: open that work item here; on a PR: open it
--   gR     open a linked pull request (in the reviewer, else the browser)
--   gs     change this item's state (a popup; can set its children too)
--   ga     assign this work item
--   gp     set this work item's priority
--   ge     edit this work item's title
--   gi     move this work item to another sprint
--   gc     add a discussion comment
--   gl     link a pull request
--   gL     unlink a pull request
--   o      open this work item in the browser
--   r      refresh
--   <BS>/q close and return to the dashboard
--   ?      show this help
--
-- M.open() (re)builds this view - called by workitems/dashboard.lua's <CR>.
local CONFIG = require("azure-cli.config")
local STATE = require("azure-cli.state")
local RPC = require("azure-cli.rpc")
local PROMPT = require("azure-cli.prompt")
local KEYS = require("azure-cli.keys")
local STATES = require("azure-cli.workitems.states")
local STATE_DIALOG = require("azure-cli.workitems.state_dialog")
local LINKED_PRS = require("azure-cli.workitems.linked_prs")
local UI = require("azure-cli.ui")
-- Shared housekeeping helpers - see shell.lua.
local SHELL = require("azure-cli.shell")

local M = {}

function M.open()

local env    = vim.env
-- Data-provider argv (python azure-cli.py) every work-item fetch/action in
-- this view runs, replacing wi-detail.sh/wi-state.sh/wi-edit.sh entirely.
-- The builder lives in config.lua next to provider_cmd() now; this file and
-- workitems/dashboard.lua had the same copy.
local provider_argv = CONFIG.provider_argv
local ID     = env.AZVICLI_WI_ID or ""
-- AZVICLI_WI_ASSIGNEE override only - no personal default here any more. ga
-- (assign_item below) sends an empty submission through as-is, and azure-cli.py
-- resolves that to the real "me" itself (work_items: assignee: from config, or
-- the signed-in user - see WorkItemActions.assignee/_wi_set_field); this local is
-- only the optimistic-comment author label below (add_comment), which falls back
-- to the generic "Me" when no override is set, since it's never sent to the server.
local ASSIGNEE = env.AZVICLI_WI_ASSIGNEE or ""
-- gl's fallback org/project for a PR the PR list doesn't know is
-- workitems/linked_prs.lua's M.link now.

local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = "azurecli-workitem"

-- Colours (termguicolors is on); idempotent so re-opening a tab is harmless.
-- Same AzureCliWiHeader/Id/... groups workitems/dashboard.lua defines (its
-- own call already ran by the time this view opens, but this file can also
-- open standalone-ish within a fresh tab, so it defines them again itself,
-- exactly as before) - see UI.link_hl for why these link to standard
-- groups with `default = true`.
UI.link_hl({
  AzureCliWiHeader      = "Title",
  AzureCliWiId          = "Identifier",
  AzureCliWiActive      = "String",
  AzureCliWiNew         = "Special",
  AzureCliWiImplemented = "WarningMsg",
  AzureCliWiResolved    = "Directory",
  AzureCliWiClosed      = "Comment",
  AzureCliWiRemoved     = "ErrorMsg",
  AzureCliWiViewTitle   = "Title",
  AzureCliWiViewLabel   = "Special",
  AzureCliWiOther       = "Comment",
})

-- Built from the sprint list's "states" field (work_items.states:,
-- see states.lua) - workitems/dashboard.lua always populates
-- STATE.WI_SPRINTS_CACHE before a detail tab can be opened (see
-- move_sprint_item below), and falls back to states.lua's own
-- hard-coded table when that hasn't happened yet or the field is absent.
local wi_built = STATES.build(STATE.WI_SPRINTS_CACHE and STATE.WI_SPRINTS_CACHE.states)
local KNOWN_LABEL = {
  Parent = true, Children = true, Assigned = true, Priority = true,
  Created = true, Changed = true, Reason = true, Area = true,
  Iteration = true, Tags = true, URL = true,
}
local ns = vim.api.nvim_create_namespace("azure_cli_workitem")
-- A linked PR's status word, coloured like the work-item states it echoes.
local PR_STATUS_HL = {
  active = "AzureCliWiActive", draft = "AzureCliWiNew",
  completed = "AzureCliWiClosed", abandoned = "AzureCliWiRemoved",
}

local row_link = {}  -- buffer line (1-based) -> work item id (parent/child rows)
local row_pr = {}    -- buffer line (1-based) -> linked PR (Pull Requests rows)

local notify = SHELL.notify

local function set_lines(lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- `always` renders the block with "(none)" when there's no text, so an
-- empty Description reads as empty rather than as a failed load.
local function add_block(lines, title, text, always)
  if (not text or text == "") and not always then return end
  lines[#lines + 1] = ""
  lines[#lines + 1] = title
  lines[#lines + 1] = string.rep("─", #title)
  if not text or text == "" then
    lines[#lines + 1] = "  (none)"
    return
  end
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = l
  end
end

-- "(sending…)" tag for a comment still awaiting its POST to confirm, the
-- same convention pr-review.lua uses for its own optimistic writes.
local function comment_tag(c)
  return (c and c.pending) and "  (sending\u{2026})" or ""
end

local function render(data)
  local it = data.item or {}
  local lines = {}
  row_link = {}
  row_pr = {}

  lines[#lines + 1] = string.format("#%s  %s  [%s]",
    tostring(it.id or "?"), it.type or "", it.state or "")
  lines[#lines + 1] = it.title or ""
  lines[#lines + 1] = ""

  if data.parent then
    local p = data.parent
    lines[#lines + 1] = string.format("Parent:  #%s  %s  [%s]  %s",
      tostring(p.id), p.type or "", p.state or "", p.title or "")
    row_link[#lines] = p.id
  else
    lines[#lines + 1] = "Parent:  (none)"
  end

  lines[#lines + 1] = ""
  local kids = data.children or {}
  lines[#lines + 1] = "Children (" .. #kids .. "):"
  if #kids == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, c in ipairs(kids) do
      lines[#lines + 1] = string.format("  #%s  %s  [%s]  %s",
        tostring(c.id), c.type or "", c.state or "", c.title or "")
      row_link[#lines] = c.id
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Details"
  lines[#lines + 1] = "───────"
  lines[#lines + 1] = "Assigned:  " .. (it.assignedTo or "")
  if type(it.priority) == "number" then lines[#lines + 1] = "Priority:  P" .. it.priority end
  lines[#lines + 1] = "Created:   " .. (it.createdBy or "") .. "  " .. (it.createdDate or "")
  lines[#lines + 1] = "Changed:   " .. (it.changedDate or "")
  if it.reason and it.reason ~= "" then lines[#lines + 1] = "Reason:    " .. it.reason end
  lines[#lines + 1] = "Area:      " .. (it.areaPath or "")
  lines[#lines + 1] = "Iteration: " .. (it.iterationPath or "")
  if it.tags and it.tags ~= "" then lines[#lines + 1] = "Tags:      " .. it.tags end
  lines[#lines + 1] = "URL:       " .. (it.url or "")
  local prs = it.pullRequests or {}
  if #prs > 0 then
    local pr_title = "Pull Requests (" .. #prs .. ")"
    lines[#lines + 1] = ""
    lines[#lines + 1] = pr_title
    lines[#lines + 1] = string.rep("─", #pr_title)
    for _, p in ipairs(prs) do
      for _, l in ipairs(LINKED_PRS.lines(p)) do
        lines[#lines + 1] = l
        row_pr[#lines] = p
      end
    end
  end

  add_block(lines, "Description", it.description, true)
  add_block(lines, "Acceptance Criteria", it.acceptanceCriteria)
  add_block(lines, "Repro Steps", it.reproSteps)

  local comments = data.comments or {}
  local disc_title = "Discussion (" .. #comments .. ")"
  lines[#lines + 1] = ""
  lines[#lines + 1] = disc_title
  lines[#lines + 1] = string.rep("─", #disc_title)
  if data.commentsUnsupported then
    lines[#lines + 1] = "  (comments not available on this server)"
  elseif #comments == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, c in ipairs(comments) do
      lines[#lines + 1] = (c.author or "") .. "  " .. (c.date or "") .. comment_tag(c)
      for _, cl in ipairs(vim.split(c.text or "", "\n", { plain = true })) do
        lines[#lines + 1] = "  " .. cl
      end
      lines[#lines + 1] = ""
    end
  end

  set_lines(lines)

  -- Colour: section titles/underlines, the item title, field labels, and the
  -- #id / [state] tokens on the header and parent/child rows.
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local function add(grp, lnum, cs, ce)
    vim.api.nvim_buf_add_highlight(buf, ns, grp, lnum, cs, ce)
  end
  -- A rule line is one made entirely of box-drawing dashes. ('─' is 3 bytes, so
  -- a naive "^─+$" Lua pattern wouldn't match more than one.)
  local function is_rule(l) return l ~= "" and l:gsub("─", "") == "" end
  for i, line in ipairs(lines) do
    local lnum = i - 1
    if is_rule(line) then
      add("AzureCliWiHeader", lnum, 0, -1)
    else
      if lines[i + 1] and is_rule(lines[i + 1]) then
        add("AzureCliWiHeader", lnum, 0, -1)
      end
      if i == 2 then add("AzureCliWiViewTitle", lnum, 0, -1) end
      local w = line:match("^(%a+)")
      if w and KNOWN_LABEL[w] then
        local le = select(2, line:find("^[%a][%w %(%)]-:"))
        if le then add("AzureCliWiViewLabel", lnum, 0, le) end
      end
      local s, e = line:find("#%d+")
      if s then add("AzureCliWiId", lnum, s - 1, e) end
      local bs, be, state = line:find("%[(.-)%]")
      if bs and wi_built.hl[state] then add(wi_built.hl[state], lnum, bs - 1, be) end
      if row_pr[i] then
        local ps, pe = line:find("^  !%d+")
        if ps then add("AzureCliWiId", lnum, 2, pe) end
        local ss, se, st = line:find("^  !%d+%s+(%a+)")
        if ss then add(PR_STATUS_HL[st] or "AzureCliWiOther", lnum, se - #st, se) end
      end
    end
  end

  pcall(function()
    UI.wo(0, "winbar", UI.winbar({ "#" .. tostring(it.id or "?"), it.type or "", it.state or "" }, {}))
  end)
end

local current_url = ""
local current_item = {}
local current_data = {}

-- Detail cache shared with workitems/dashboard.lua's prefetch (same nvim session).
STATE.WI_DETAIL_CACHE = STATE.WI_DETAIL_CACHE or {}
-- Registry so the dashboard can trigger a live reload of an open detail tab
-- (keyed by work item id) after it commits a state change.
STATE.WI_VIEW_RELOAD = STATE.WI_VIEW_RELOAD or {}
local prev_reg_id = nil
local CACHE_TTL = 30

-- Warm the workflow caches for the current item so 'gs' is instant here too.
local function prefetch_state_meta()
  STATE_DIALOG.prewarm(current_item.type or "", current_item.state or "")
end

local function apply(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then
    set_lines({ "Could not parse work item JSON.", body })
    return false
  end
  current_url = (data.item or {}).url or ""
  current_item = data.item or {}
  current_data = data
  render(data)
  prefetch_state_meta()
  return true
end

-- Load the work item. Uses a fresh prefetched cache entry when available (so the
-- tab opens instantly); force=true (the r key) always refetches live.
local function load(id, force)
  ID = tostring(id)
  -- Register a live-reload hook for this id so a state change committed from the
  -- dashboard refreshes this tab; drop the previous id's hook when navigating.
  if prev_reg_id and prev_reg_id ~= ID then STATE.WI_VIEW_RELOAD[prev_reg_id] = nil end
  prev_reg_id = ID
  STATE.WI_VIEW_RELOAD[ID] = function()
    if vim.api.nvim_buf_is_valid(buf) then load(ID, true) end
  end
  if not force then
    local c = STATE.WI_DETAIL_CACHE[ID]
    if c and (os.time() - c.ts) < CACHE_TTL and apply(c.body) then
      return
    end
  end
  set_lines({ "Loading work item #" .. ID .. " …" })
  local out, err = {}, {}
  RPC.run(provider_argv("--wi-detail", ID), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then
        set_lines({ "Failed to load work item #" .. ID .. ":",
          SHELL.job_error("work item #" .. ID, code, err) })
        return
      end
      local body = table.concat(out, "\n")
      STATE.WI_DETAIL_CACHE[ID] = { body = body, ts = os.time() }
      apply(body)
    end,
  })
end

-- <CR>: a parent/child line opens that item here; a Pull Requests line
-- opens that PR (in the reviewer, or the browser - see linked_prs.lua).
local function open_linked()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local id = row_link[line]
  if id then return load(id) end
  local pr = row_pr[line]
  if pr then LINKED_PRS.open(pr, ID) end
end

-- gR: open a linked PR - the one under the cursor, else pick one.
local function open_linked_pr()
  if ID == "" then return end
  local pr = row_pr[vim.api.nvim_win_get_cursor(0)[1]]
  if pr then return LINKED_PRS.open(pr, ID) end
  LINKED_PRS.choose(current_item.pullRequests, ID)
end

-- gs: the state popup (workitems/state_dialog.lua, shared with the
-- dashboard). Its write reloads this tab through STATE.WI_VIEW_RELOAD.
local function set_state()
  if ID == "" then return end
  local it = vim.tbl_extend("force", {}, current_item, { id = ID })
  STATE_DIALOG.open(it)
end

-- Commit a single-field --wi-edit "set" for this work item, then refresh
-- this view (the way gs's write does) and, when given, reconcile the
-- dashboard's cached record via dash_patch (best-effort: no-op if the
-- dashboard globals were never installed in this session).
local function apply_field(arg_name, value, describe, dash_patch)
  if ID == "" then return end
  notify(describe .. " #" .. ID .. " \u{2026}")
  local err = {}
  RPC.run(provider_argv("--wi-edit", "set", ID, arg_name, tostring(value)), {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify(describe .. " #" .. ID .. ": done.")
        STATE.WI_DETAIL_CACHE[ID] = nil
        load(ID, true)
        if dash_patch then dash_patch() end
      else
        local msg = SHELL.job_error("work item #" .. ID, code, err)
        notify(describe .. " #" .. ID .. " failed: " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
end

-- Assign this work item. Prefilled with its current assignee; submitting
-- empty assigns it to me - azure-cli.py resolves that server-side
-- (WorkItemActions._wi_set_field), so the empty string is sent through as-is.
local function assign_item()
  if ID == "" then return end
  -- The dashboard's team-member picker when it's been installed this
  -- session (it always is: a detail view is opened from the dashboard),
  -- else the plain typed prompt.
  local function commit(new)
    apply_field("assignedTo", new, "Assigning", function()
      if STATE.WI_ITEM_CHANGED then STATE.WI_ITEM_CHANGED(ID, { assignedTo = new }) end
    end)
  end
  if STATE.WI_PICK_ASSIGNEE then
    STATE.WI_PICK_ASSIGNEE(current_item.assignedTo or "", commit)
    return
  end
  PROMPT.input({ prompt = "Assign #" .. ID .. " to (empty = me):", default = current_item.assignedTo or "",
    allow_empty = true }, function(new)
    if new ~= nil then commit(new) end
  end)
end

local PRIORITIES = { 1, 2, 3, 4 }

-- Set the priority of this work item (1-4).
local function set_priority()
  if ID == "" then return end
  PROMPT.select({ prompt = "Priority for #" .. ID, items = PRIORITIES,
    format = function(p) return "P" .. p end,
    current = function(p) return tostring(p) == tostring(current_item.priority) end }, function(new)
    if not new then return end
    apply_field("priority", new, "Setting priority on", function()
      if STATE.WI_ITEM_CHANGED then STATE.WI_ITEM_CHANGED(ID, { priority = new }) end
    end)
  end)
end

-- Edit the title of this work item, prefilled with the current one.
local function edit_title()
  if ID == "" then return end
  PROMPT.input({ prompt = "Title for #" .. ID .. ":", default = current_item.title or "" }, function(new)
    if new == nil then return end
    if new == current_item.title then
      notify("Title unchanged.")
      return
    end
    apply_field("title", new, "Renaming", function()
      if STATE.WI_ITEM_CHANGED then STATE.WI_ITEM_CHANGED(ID, { title = new }) end
    end)
  end)
end

-- Move this work item to another sprint of the quarter, offered from the
-- dashboard's cached sprint list (workitems/dashboard.lua always populates it before a
-- detail tab can be opened). Re-renders this view on success rather than
-- patching in place - unlike workitems/dashboard.lua's own 'gi' there's no row for this
-- item to optimistically drop here.
local function move_sprint_item()
  if ID == "" then return end
  local list = (STATE.WI_SPRINTS_CACHE and STATE.WI_SPRINTS_CACHE.list) or {}
  if #list == 0 then
    notify("Sprint list not loaded - open this item from the dashboard first.", vim.log.levels.WARN)
    return
  end
  local from_path = current_item.iterationPath or ""
  local targets = {}
  for _, sp in ipairs(list) do
    if sp.path ~= from_path then targets[#targets + 1] = sp end
  end
  if #targets == 0 then
    notify("No other sprint to move to.", vim.log.levels.WARN)
    return
  end
  PROMPT.select({ prompt = "Move #" .. ID .. " to sprint", items = targets,
    format = function(sp) return sp.label or sp.name or sp.path end }, function(target)
    if not target then return end
    apply_field("iteration", target.path, "Moving", function()
      if STATE.WI_ITEM_MOVED then STATE.WI_ITEM_MOVED(ID, from_path, target.path) end
    end)
  end)
end

-- Add a discussion comment to this work item. Shown at once, tagged
-- "(sending…)"; the tag drops on success, or the entry is removed and the
-- failure notified - the same optimistic pattern pr-review.lua uses for its
-- own comments (see comment_tag above), simplified: no retry prompt here.
local function add_comment()
  if ID == "" then return end
  local function post(text)
    current_data.comments = current_data.comments or {}
    local entry = { author = (ASSIGNEE ~= "" and ASSIGNEE or "Me"), date = "", text = text, pending = true }
    table.insert(current_data.comments, entry)
    render(current_data)
    local err = {}
    RPC.run(provider_argv("--wi-edit", "comment", ID, text), {
      detach = true,  -- finish the ADO write even if the user quits before it returns
      stdout_buffered = true,
      stderr_buffered = true,
      on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
      on_exit = function(_, code)
        if code == 0 then
          entry.pending = nil
          notify("Comment added to #" .. ID .. ".")
        else
          for i, c in ipairs(current_data.comments) do
            if c == entry then table.remove(current_data.comments, i); break end
          end
          notify("Comment on #" .. ID .. " failed: " .. SHELL.job_error("work item #" .. ID, code, err),
            vim.log.levels.ERROR)
        end
        render(current_data)
      end,
    })
  end
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("workitem", { id = ID }),
    anchor = "center",
    draft_key = EDITOR.draft_key(ID, "workitem", ""),
    on_submit = post,
  })
end

-- Link a pull request to this work item. Resolves the PR's org/project/repo
-- from the dashboard's cached PR list (STATE.PR_LIST_CACHE.prs, populated by
-- workitems/dashboard.lua's background prefetch) when its id is there; otherwise prompts
-- for the repository name and falls back to this account's own
-- collection/project.
local function link_pr()
  if ID == "" then return end
  local function ask(cb)
    if STATE.WI_PICK_PR then
      STATE.WI_PICK_PR("Link a pull request to #" .. ID, cb)
      return
    end
    PROMPT.input({ prompt = "Link PR id to #" .. ID .. ":" }, function(t)
      if t ~= nil then cb((t:gsub("^!", ""))) end
    end)
  end
  -- linked_prs.lua links it and updates every screen showing the link
  -- (this tab reloads through STATE.WI_VIEW_RELOAD).
  ask(function(pr_id)
    if pr_id ~= nil then LINKED_PRS.link(ID, pr_id, current_item) end
  end)
end

-- Unlink a pull request from this work item, picked from the ones currently
-- linked (a menu by PR id).
local function unlink_pr()
  if ID == "" then return end
  local prs = current_item.pullRequests or {}
  if #prs == 0 then
    notify("No linked pull requests on #" .. ID .. ".", vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, p in ipairs(prs) do
    items[#items + 1] = { label = "!" .. tostring(p.id) .. (p.title and p.title ~= "" and ("  " .. p.title) or ""), pr = p }
  end
  UI.pick_popup({ title = "Unlink a PR from #" .. ID, items = items, action = "unlink" }, function(choice)
    LINKED_PRS.unlink(ID, choice.pr.id, current_item)
  end)
end

local function open_browser()
  local ok, why = SHELL.open_url(current_url)
  if not ok and current_url ~= "" then
    notify("Can't open #" .. ID .. ": " .. why, vim.log.levels.WARN)
  end
end

-- Copy this work item's web link to the system clipboard.
local function yank_link()
  if not SHELL.yank_url(current_url) then return end
  notify("Copied link to #" .. tostring(ID) .. ": " .. current_url)
end

-- Show this view's keys in a float.
-- Ordered { action, desc } pairs for the `?` popup - real key(s) resolved
-- through KEYS every time (see keys.lua's M.line), never hard-coded.
local WORKITEM_VIEW_HELP = {
  "Navigate",
  { "open", "on a parent/child line: open that work item here; on a PR: open the PR" },
  "This item",
  { "state", "change this item's state (a popup; can set its children too)" },
  { "assign", "assign this work item" },
  { "priority", "set this work item's priority" },
  { "edit_title", "edit this work item's title" },
  { "move_sprint", "move this work item to another sprint" },
  { "comment", "add a discussion comment" },
  { "link_pr", "link a pull request" },
  { "unlink_pr", "unlink a pull request" },
  { "open_pr", "open a linked pull request (reviewer, or browser if it isn't in your PR list)" },
  { "browser", "open this work item in the browser" },
  { "copy_link", "copy this work item's link" },
  "Session",
  { "refresh", "refresh" },
  { "back", "close and return to the dashboard" },
  { "help", "this help" },
}
local function show_help()
  UI.open_float(KEYS.help_lines("workitem_view", "Work-item detail keys", WORKITEM_VIEW_HELP,
    { fixed = { "  j / k       move" } }))
end

local function leave()
  if STATE.WI_VIEW_RELOAD then STATE.WI_VIEW_RELOAD[ID] = nil end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
    -- Change-aware dashboard refresh: only redraws if the list actually changed.
    if STATE.WI_REFRESH then vim.schedule(STATE.WI_REFRESH) end
  else
    vim.cmd("qa!")
  end
end

KEYS.bind(buf, "workitem_view", "open", open_linked, { desc = "open that work item here" })
KEYS.bind(buf, "workitem_view", "state", set_state, { desc = "change the state of this work item" })
KEYS.bind(buf, "workitem_view", "assign", assign_item, { desc = "assign this work item" })
KEYS.bind(buf, "workitem_view", "priority", set_priority, { desc = "set this work item's priority" })
KEYS.bind(buf, "workitem_view", "edit_title", edit_title, { desc = "edit this work item's title" })
KEYS.bind(buf, "workitem_view", "move_sprint", move_sprint_item, { desc = "move this work item to another sprint" })
KEYS.bind(buf, "workitem_view", "comment", add_comment, { desc = "add a discussion comment" })
KEYS.bind(buf, "workitem_view", "link_pr", link_pr, { desc = "link a pull request" })
KEYS.bind(buf, "workitem_view", "unlink_pr", unlink_pr, { desc = "unlink a pull request" })
KEYS.bind(buf, "workitem_view", "open_pr", open_linked_pr, { desc = "open a linked pull request" })
KEYS.bind(buf, "workitem_view", "browser", open_browser, { desc = "open this work item in the browser" })
KEYS.bind(buf, "workitem_view", "copy_link", yank_link, { desc = "copy this work item's link" })
KEYS.bind(buf, "workitem_view", "refresh", function() if ID ~= "" then load(ID, true) end end, { desc = "refresh" })
KEYS.bind(buf, "workitem_view", "back", leave, { desc = "close and return to the dashboard" })
KEYS.bind(buf, "workitem_view", "quit", leave, { desc = "close and return to the dashboard" })
KEYS.bind(buf, "workitem_view", "help", show_help, { desc = "this help" })
-- gq: the chat panel, told which work item this view shows.
require("azure-cli.chat").bind_toggle(buf, "workitem_view")
require("azure-cli.chat.view").register("azurecli-workitem", function()
  local snap = { screen = "work item detail view", work_item = { id = tonumber(ID) or ID } }
  local c = STATE.WI_DETAIL_CACHE[ID]
  local ok, d = pcall(vim.json.decode, c and c.body or "")
  local item = ok and type(d) == "table" and (d.item or d) or nil
  if type(item) == "table" then
    snap.work_item.type, snap.work_item.title, snap.work_item.state = item.type, item.title, item.state
  end
  return snap
end)

if ID == "" then
  set_lines({ "No work item id (AZVICLI_WI_ID) set." })
else
  load(ID)
end

end  -- M.open()

return M
