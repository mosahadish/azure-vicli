-- lua/azure-cli/workitems/view.lua: read-only work-item detail view (opened
-- from workitems/dashboard.lua).
--
-- Opened on an item's ref (else AZVICLI_WI_ID), fetches the item + its parent and
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
--   ge     edit this work item: every field that can change, in one popup
--          (workitems/edit.lua) - title, state, assignee, priority, sprint,
--          parent, tags, hours where its type has them
--   gE     write or edit its description (GitHub issues only)
--   gi     move this work item to another sprint
--   gU     move this work item under another parent, or off its own (a picker)
--   gc    add a discussion comment
--   gl     link a pull request
--   gL     unlink a pull request
--   o      open this work item in the browser
--   r      refresh
--   <BS>/q close and return to the dashboard
--   ?      show this help
--
-- M.open(board, ref, opts) (re)builds this view - called by workitems/dashboard.lua's
-- <CR> with its board (workitems/board.lua) and the item's ref (the id on
-- Azure, owner~repo~n for a GitHub issue). With neither, it's an Azure work
-- item read from AZVICLI_WI_ID, as pr_workitems.lua's gW opens it.
-- opts.edit opens ge's form once the item has loaded (the dashboard's ge).
local PROMPT = require("azure-cli.prompt")
local KEYS = require("azure-cli.keys")
local STATES = require("azure-cli.workitems.states")
local LINKED_PRS = require("azure-cli.workitems.linked_prs")
local UI = require("azure-cli.ui")
-- Shared housekeeping helpers - see shell.lua.
local SHELL = require("azure-cli.shell")

local M = {}

function M.open(board, ref, opts)

local env    = vim.env
-- The board this item is on: its caches and hooks (S), provider calls
-- (B.run) and words.
local B = board or require("azure-cli.workitems.board").get("azure")
local S = B.state
local WORDS = B.words
local STATE_DIALOG = require("azure-cli.workitems.state_dialog").for_board(B)
local ID     = ref and tostring(ref) or env.AZVICLI_WI_ID or ""
-- How to name the item: "#7" for a GitHub ref owner~repo~7, else the id.
local current_item = {}
local function shown()
  if current_item.id then return tostring(current_item.id) end
  return ID:match("~(%d+)$") or ID
end
-- A parent or child of this item, as this board's provider takes it: on
-- GitHub, the same repository's issue (sub-issues live beside their parent).
local function ref_for(id)
  local o, r = ID:match("^(.-)~(.-)~%d+$")
  if B.host == "github" and o then return o .. "~" .. r .. "~" .. tostring(id) end
  return tostring(id)
end
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
-- This view's tab: an inner tab of Work items / Issues (innertabs.lua),
-- whose strip label follows the item shown here.
local tab = vim.api.nvim_get_current_tabpage()
local INNER = require("azure-cli.innertabs")
-- The window showing this view: renders land after a load, maybe while
-- you're in another tab.
local function view_win()
  for _, w in ipairs(vim.api.nvim_tabpage_is_valid(tab) and vim.api.nvim_tabpage_list_wins(tab) or {}) do
    if vim.api.nvim_win_get_buf(w) == buf then return w end
  end
end
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = B.item_ft
-- What this view's ↑ keys change, for the key hints (keyhints.lua).
vim.b[buf].azure_cli_service = WORDS.service
-- A winbar from the start, so the inner-tab strip shows while it loads.
if ID ~= "" then pcall(UI.wo, 0, "winbar", UI.winbar({ "#" .. (ID:match("~(%d+)$") or ID) }, {})) end
-- A GitHub issue's body is Markdown, shown as written.
if B.host == "github" then vim.bo[buf].syntax = "markdown" end

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
-- S.WI_SPRINTS_CACHE before a detail tab can be opened (see
-- move_sprint_item below), and falls back to states.lua's own
-- hard-coded table when that hasn't happened yet or the field is absent.
local wi_built = STATES.build(S.WI_SPRINTS_CACHE and S.WI_SPRINTS_CACHE.states)
local KNOWN_LABEL = {
  Parent = true, Children = true, Assigned = true, Priority = true,
  Created = true, Changed = true, Reason = true, Area = true,
  Iteration = true, Tags = true, URL = true, Repository = true, Hours = true,
}
local ns = vim.api.nvim_create_namespace("azure_cli_workitem")
-- A linked PR's status word, coloured like the work-item states it echoes.
local PR_STATUS_HL = {
  active = "AzureCliWiActive", draft = "AzureCliWiNew",
  completed = "AzureCliWiClosed", abandoned = "AzureCliWiRemoved",
}

-- Created/Changed: a provider's UTC ISO timestamp ("2026-10-13T20:06:19Z",
-- Azure's with fractions) as local time, "13 Oct 2026 22:06" - the
-- dashboard's date style. Anything else is shown as it came.
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function fmt_when(iso)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return iso or "" end
  local as_local = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
  -- os.time() read those fields as local time; shift by the zone's offset.
  local now = os.time()
  local t = as_local + os.difftime(now, os.time(os.date("!*t", now)))
  local dt = os.date("*t", t)
  return string.format("%d %s %d %02d:%02d", dt.day, MONTHS[dt.month], dt.year, dt.hour, dt.min)
end

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
  -- The hours its type has (a Task's, usually); "" is one not set.
  if type(it.hours) == "table" and next(it.hours) then
    local parts = {}
    for _, h in ipairs(require("azure-cli.workitems.edit").HOURS) do
      if it.hours[h.key] ~= nil then
        local t = require("azure-cli.workitems.edit").hours_text(it.hours[h.key])
        parts[#parts + 1] = h.label:match("^%a+"):lower() .. " " .. (t == "" and "\u{2014}" or (t .. " h"))
      end
    end
    lines[#lines + 1] = "Hours:     " .. table.concat(parts, "  \u{00B7}  ")
  end
  lines[#lines + 1] = "Created:   " .. (it.createdBy or "") .. "  " .. fmt_when(it.createdDate)
  lines[#lines + 1] = "Changed:   " .. fmt_when(it.changedDate)
  if it.reason and it.reason ~= "" then lines[#lines + 1] = "Reason:    " .. it.reason end
  -- "Repository:" is as wide as the column: still one space after it.
  local area = WORDS.area .. ":"
  lines[#lines + 1] = area .. string.rep(" ", math.max(1, 11 - #area)) .. (it.areaPath or "")
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
      for _, l in ipairs(LINKED_PRS.lines(p, B.host)) do
        lines[#lines + 1] = l
        row_pr[#lines] = p
      end
    end
  end

  add_block(lines, "Description", it.description, true)
  add_block(lines, "Acceptance Criteria", it.acceptanceCriteria)
  add_block(lines, "Repro Steps", it.reproSteps)

  local comments = data.comments or {}
  local disc_title = WORDS.discussion .. " (" .. #comments .. ")"
  lines[#lines + 1] = ""
  lines[#lines + 1] = disc_title
  lines[#lines + 1] = string.rep("─", #disc_title)
  if data.commentsUnsupported then
    lines[#lines + 1] = "  (comments not available on this server)"
  elseif #comments == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, c in ipairs(comments) do
      lines[#lines + 1] = (c.author or "") .. "  " .. fmt_when(c.date) .. comment_tag(c)
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
        -- "!101" on Azure, "repo#12" on GitHub (linked_prs.lua's M.label).
        local name = B.host == "github" and "^  [%w%._-]*#%d+" or "^  !%d+"
        local ps, pe = line:find(name)
        if ps then add("AzureCliWiId", lnum, 2, pe) end
        local ss, se, st = line:find(name .. "%s+(%a+)")
        if ss then add(PR_STATUS_HL[st] or "AzureCliWiOther", lnum, se - #st, se) end
      end
    end
  end

  pcall(function()
    local w = view_win()
    if w then UI.wo(w, "winbar", UI.winbar({ "#" .. tostring(it.id or "?"), it.type or "", it.state or "" }, {})) end
    vim.b[buf].azure_cli_title = "#" .. tostring(it.id or "?")
  end)
  INNER.retitle(tab, nil, "#" .. tostring(it.id or "?") .. " " .. tostring(it.title or ""))
  -- Neovim's own tab line (plugin mode) names a tab after its buffer, and an
  -- unnamed one is "[Scratch]". (Taken when the same issue is open twice.)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_set_name, buf, WORDS.Item .. " #" .. tostring(it.id or "?"))
  end
end

local current_url = ""
local current_data = {}
-- ge's form while it's open (workitems/edit.lua), and whether to open it
-- once the item has loaded.
local edit_form = nil
local pending_edit = opts and opts.edit or false
local open_edit

-- Detail cache shared with workitems/dashboard.lua's prefetch (same nvim session).
S.WI_DETAIL_CACHE = S.WI_DETAIL_CACHE or {}
-- Registry so the dashboard can trigger a live reload of an open detail tab
-- (keyed by the item's ref) after it commits a state change.
S.WI_VIEW_RELOAD = S.WI_VIEW_RELOAD or {}
local prev_reg_id = nil
local CACHE_TTL = 30

-- Warm the workflow caches for the current item so 'gs' is instant here too.
local function prefetch_state_meta()
  STATE_DIALOG.prewarm(current_item.type or "", current_item.state or "")
end

local function apply(body)
  -- luanil: a null (an issue's parent or priority) is nil, not a truthy vim.NIL.
  local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    set_lines({ "Could not parse " .. WORDS.item .. " JSON.", body })
    return false
  end
  current_url = (data.item or {}).url or ""
  current_item = data.item or {}
  current_data = data
  render(data)
  prefetch_state_meta()
  if pending_edit then
    pending_edit = false
    vim.schedule(open_edit)
  elseif edit_form and edit_form.valid() then
    edit_form.refresh(current_item, data.parent)
  end
  return true
end

-- Load the work item. Uses a fresh prefetched cache entry when available (so the
-- tab opens instantly); force=true (the r key) always refetches live.
-- quiet=true keeps the view as it is (no "Loading…") until the answer
-- replaces it, and a failure leaves it there - a re-read after a comment.
local function load(id, force, quiet)
  if tostring(id) ~= ID then
    current_item = {}
    -- Another item here now (<CR> on a parent/child): the strip follows.
    INNER.retitle(tab, INNER.item_key(B.host, id), "#" .. (tostring(id):match("~(%d+)$") or tostring(id)))
  end
  ID = tostring(id)
  -- Register a live-reload hook for this id so a state change committed from the
  -- dashboard refreshes this tab; drop the previous id's hook when navigating.
  S.WI_VIEW_EDIT = S.WI_VIEW_EDIT or {}
  if prev_reg_id and prev_reg_id ~= ID then
    S.WI_VIEW_RELOAD[prev_reg_id] = nil
    S.WI_VIEW_EDIT[prev_reg_id] = nil
  end
  prev_reg_id = ID
  S.WI_VIEW_RELOAD[ID] = function()
    if vim.api.nvim_buf_is_valid(buf) then load(ID, true) end
  end
  -- ge on the dashboard while this item is already open here.
  S.WI_VIEW_EDIT[ID] = function() open_edit() end
  if not force then
    local c = S.WI_DETAIL_CACHE[ID]
    if c and (os.time() - c.ts) < CACHE_TTL and apply(c.body) then
      return
    end
  end
  if not quiet then set_lines({ "Loading " .. WORDS.item .. " #" .. shown() .. " …" }) end
  local out, err = {}, {}
  B.run({ "--wi-detail", ID }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code ~= 0 and quiet then return end
      if code ~= 0 then
        set_lines({ "Failed to load " .. WORDS.item .. " #" .. shown() .. ":",
          SHELL.job_error(WORDS.item .. " #" .. shown(), code, err) })
        return
      end
      local body = table.concat(out, "\n")
      S.WI_DETAIL_CACHE[ID] = { body = body, ts = os.time() }
      apply(body)
    end,
  })
end

-- <CR>: a parent/child line opens that item here; a Pull Requests line
-- opens that PR (in the reviewer, or the browser - see linked_prs.lua).
local function open_linked()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local id = row_link[line]
  -- Open in another inner tab already: go there rather than show it twice.
  if id and INNER.goto_key(INNER.item_key(B.host, ref_for(id))) then return end
  if id then return load(ref_for(id)) end
  local pr = row_pr[line]
  if pr then LINKED_PRS.open(pr, ID, B) end
end

-- gR: open a linked PR - the one under the cursor, else pick one.
local function open_linked_pr()
  if ID == "" then return end
  local pr = row_pr[vim.api.nvim_win_get_cursor(0)[1]]
  if pr then return LINKED_PRS.open(pr, ID, B) end
  LINKED_PRS.choose(current_item.pullRequests, ID, B, shown())
end

-- gs: the state popup (workitems/state_dialog.lua, shared with the
-- dashboard). Its write reloads this tab through S.WI_VIEW_RELOAD.
local function set_state()
  if ID == "" then return end
  -- The popup sends B.ref(item): the id on Azure, the key on GitHub.
  local it = vim.tbl_extend("force", {}, current_item, B.host == "github" and { key = ID } or { id = ID })
  STATE_DIALOG.open(it)
end

-- Commit a single-field --wi-edit "set" for this work item, then refresh
-- this view (the way gs's write does) and, when given, reconcile the
-- dashboard's cached record via dash_patch (best-effort: no-op if the
-- dashboard globals were never installed in this session).
local function apply_field(arg_name, value, describe, dash_patch)
  if ID == "" then return end
  local name = "#" .. shown()
  notify(describe .. " " .. name .. " \u{2026}")
  local err = {}
  B.run({ "--wi-edit", "set", ID, arg_name, tostring(value) }, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify(describe .. " " .. name .. ": done.")
        S.WI_DETAIL_CACHE[ID] = nil
        load(ID, true)
        if dash_patch then dash_patch() end
      else
        local msg = SHELL.job_error(WORDS.item .. " " .. name, code, err)
        notify(describe .. " " .. name .. " failed: " .. msg, vim.log.levels.ERROR)
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
      if S.WI_ITEM_CHANGED then S.WI_ITEM_CHANGED(ID, { assignedTo = new }) end
    end)
  end
  if S.WI_PICK_ASSIGNEE then
    S.WI_PICK_ASSIGNEE(current_item.assignedTo or "", commit)
    return
  end
  PROMPT.input({ prompt = "Assign #" .. shown() .. " to (empty = me):", default = current_item.assignedTo or "",
    allow_empty = true }, function(new)
    if new ~= nil then commit(new) end
  end)
end

local PRIORITIES = { 1, 2, 3, 4 }

-- Set the priority of this work item (1-4).
local function set_priority()
  if ID == "" then return end
  PROMPT.select({ prompt = "Priority for #" .. shown(), items = PRIORITIES,
    format = function(p) return "P" .. p end,
    current = function(p) return tostring(p) == tostring(current_item.priority) end }, function(new)
    if not new then return end
    apply_field("priority", new, "Setting priority on", function()
      if S.WI_ITEM_CHANGED then S.WI_ITEM_CHANGED(ID, { priority = new }) end
    end)
  end)
end

-- ge: the edit form (workitems/edit.lua) over this view - every field that
-- can change; its saves come back here (a reload, and the dashboard's
-- records patched). Before the item has loaded, it opens once it has.
function open_edit()
  if ID == "" then return end
  if not current_item.id then
    pending_edit = true
    return
  end
  if edit_form and edit_form.valid() then return edit_form.focus() end
  local item_ref = ID
  edit_form = require("azure-cli.workitems.edit").open({
    board = B, id = ID, shown = shown(), item = current_item, parent = current_data.parent,
    sprints = S.WI_SPRINTS_CACHE and S.WI_SPRINTS_CACHE.list or {},
    pick_assignee = S.WI_PICK_ASSIGNEE,
    state = function() set_state() end,
    parent_pick = function()
      local p = current_data and current_data.parent
      require("azure-cli.workitems.parent").choose(B, { id = current_item.id or shown(), key = ID,
        parentId = p and p.id or nil })
    end,
    saved = function(done)
      local fields = {}
      for _, c in ipairs(done) do
        if c.key == "iteration" then
          if S.WI_ITEM_MOVED then S.WI_ITEM_MOVED(item_ref, c.from, c.value) end
        elseif c.key == "title" or c.key == "assignedTo" or c.key == "tags" then
          fields[c.key] = c.value
        elseif c.key == "priority" then
          fields.priority = tonumber(c.value)
        end
      end
      if next(fields) and S.WI_ITEM_CHANGED then S.WI_ITEM_CHANGED(item_ref, fields) end
      S.WI_DETAIL_CACHE[item_ref] = nil
      if vim.api.nvim_buf_is_valid(buf) and ID == item_ref then load(ID, true, true) end
    end,
  })
end

-- Write or edit this item's description in the comment editor, prefilled
-- with the current one. An empty save clears it; q, or saving it unchanged,
-- writes nothing. Only where B.caps.description: Azure's comes back as
-- flattened HTML, so writing that text back would lose its formatting.
local function edit_description()
  if ID == "" then return end
  local old = vim.trim(current_item.description or "")
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("description", { id = shown() }),
    anchor = "center",
    initial = old,
    allow_empty = true,
    draft_key = EDITOR.draft_key(ID, "description", ""),
    on_submit = function(text)
      if text == old then
        notify("Description unchanged.")
        return
      end
      apply_field("description", text, "Updating the description of")
    end,
  })
end

-- Move this work item to another sprint of the quarter, offered from the
-- dashboard's cached sprint list (workitems/dashboard.lua always populates it before a
-- detail tab can be opened). Re-renders this view on success rather than
-- patching in place - unlike workitems/dashboard.lua's own 'gi' there's no row for this
-- item to optimistically drop here.
local function move_sprint_item()
  if ID == "" then return end
  local list = (S.WI_SPRINTS_CACHE and S.WI_SPRINTS_CACHE.list) or {}
  local word = B.sprint_word(list[1])
  if #list == 0 then
    notify(word:gsub("^%l", string.upper) .. " list not loaded - open this item from the dashboard first.",
      vim.log.levels.WARN)
    return
  end
  -- Azure's detail names the sprint by path; GitHub's by its title.
  local from_path = current_item.iterationPath or ""
  for _, sp in ipairs(list) do
    if B.host == "github" and sp.name == from_path then from_path = sp.path; break end
  end
  local targets = {}
  for _, sp in ipairs(list) do
    if sp.path ~= from_path then targets[#targets + 1] = sp end
  end
  if #targets == 0 then
    notify("No other " .. word .. " to move to.", vim.log.levels.WARN)
    return
  end
  PROMPT.select({ prompt = "Move #" .. shown() .. " to " .. word, items = targets,
    format = function(sp) return sp.label or sp.name or sp.path end }, function(target)
    if not target then return end
    apply_field("iteration", target.path, "Moving", function()
      if S.WI_ITEM_MOVED then S.WI_ITEM_MOVED(ID, from_path, target.path) end
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
    -- Dated now; the real author and date come back with the reload below.
    local entry = { author = (ASSIGNEE ~= "" and ASSIGNEE or "Me"), date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      text = text, pending = true }
    table.insert(current_data.comments, entry)
    render(current_data)
    local err = {}
    local name = "#" .. shown()
    B.run({ "--wi-edit", "comment", ID, text }, {
      detach = true,  -- finish the ADO write even if the user quits before it returns
      stdout_buffered = true,
      stderr_buffered = true,
      on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
      on_exit = function(_, code)
        if code == 0 then
          entry.pending = nil
          notify("Comment added to " .. name .. ".")
          -- Read it back from the server, with its real author and date.
          S.WI_DETAIL_CACHE[ID] = nil
          if vim.api.nvim_buf_is_valid(buf) then
            render(current_data)
            load(ID, true, true)
            return
          end
        else
          for i, c in ipairs(current_data.comments) do
            if c == entry then table.remove(current_data.comments, i); break end
          end
          notify("Comment on " .. name .. " failed: " .. SHELL.job_error(WORDS.item .. " " .. name, code, err),
            vim.log.levels.ERROR)
        end
        render(current_data)
      end,
    })
  end
  local EDITOR = require("azure-cli.editor")
  EDITOR.open({
    title = EDITOR.format_title("workitem", { id = shown() }),
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
    if S.WI_PICK_PR then
      S.WI_PICK_PR("Link a pull request to #" .. shown(), cb)
      return
    end
    PROMPT.input({ prompt = "Link PR id to #" .. shown() .. ":" }, function(t)
      if t ~= nil then cb((t:gsub("^!", ""))) end
    end)
  end
  -- linked_prs.lua links it and updates every screen showing the link
  -- (this tab reloads through STATE.WI_VIEW_RELOAD).
  ask(function(pr_id, rec)
    if pr_id ~= nil then
      LINKED_PRS.link(ID, pr_id, current_item, rec and { org = rec.org, project = rec.project, repo = rec.repo } or nil,
        B.host == "github" and B or nil)
    end
  end)
end

-- Unlink a pull request from this work item, picked from the ones currently
-- linked (a menu by PR id).
local function unlink_pr()
  if ID == "" then return end
  local prs = current_item.pullRequests or {}
  if #prs == 0 then
    notify("No linked pull requests on #" .. shown() .. ".", vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, p in ipairs(prs) do
    items[#items + 1] = { label = LINKED_PRS.label(p, B.host) .. (p.title and p.title ~= "" and ("  " .. p.title) or ""), pr = p }
  end
  UI.pick_popup({ title = "Unlink a PR from #" .. shown(), items = items, action = "unlink" }, function(choice)
    LINKED_PRS.unlink(ID, choice.pr.id, current_item, B.host == "github" and B or nil, choice.pr.repo)
  end)
end

local function open_browser()
  local ok, why = SHELL.open_url(current_url)
  if not ok and current_url ~= "" then
    notify("Can't open #" .. shown() .. ": " .. why, vim.log.levels.WARN)
  end
end

-- Copy this work item's web link to the system clipboard.
local function yank_link()
  if not SHELL.yank_url(current_url) then return end
  notify("Copied link to #" .. shown() .. ": " .. current_url)
end

-- Show this view's keys in a float.
-- Ordered { action, desc } pairs for the `?` popup - real key(s) resolved
-- through KEYS every time (see keys.lua's M.line), never hard-coded.
local ITEM, SPRINT = WORDS.item, WORDS.sprint
local WORKITEM_VIEW_HELP = {
  "Navigate",
  { "open", "on a parent/child line: open that " .. ITEM .. " here; on a PR: open the PR" },
  "This " .. ITEM,
  { "state", "change this " .. ITEM .. "'s state (a popup; can set its children too)" },
  { "assign", "assign this " .. ITEM },
  { "priority", "set this " .. ITEM .. "'s priority" },
  { "edit_title", "edit this " .. ITEM .. ": every field in one popup (title, state, hours\u{2026})" },
  { "description", "write or edit this " .. ITEM .. "'s description" },
  { "move_sprint", "move this " .. ITEM .. " to another " .. SPRINT },
  { "set_parent", "move this " .. ITEM .. " under another parent, or off its own (a picker)" },
  { "comment", B.host == "github" and "add a comment" or "add a discussion comment" },
  { "link_pr", "link a pull request" },
  { "unlink_pr", "unlink a pull request" },
  { "open_pr", "open a linked pull request (reviewer, or browser if it isn't in your PR list)" },
  { "browser", "open this " .. ITEM .. " in the browser" },
  { "copy_link", "copy this " .. ITEM .. "'s link" },
  "Session",
  { "refresh", "refresh" },
  { "back", "close and return to the dashboard" },
  { "help", "this help" },
}
local function show_help()
  -- gl/gL only where the board can link PRs (B.caps.links), gE where it can
  -- edit descriptions (B.caps.description): not bound, not listed.
  local help = vim.tbl_filter(function(a)
    if type(a) == "string" then return true end
    if a[1] == "description" then return B.caps.description end
    return B.caps.links or (a[1] ~= "link_pr" and a[1] ~= "unlink_pr")
  end, WORKITEM_VIEW_HELP)
  local title = B.host == "github" and "Issue detail keys" or "Work-item detail keys"
  UI.open_float(KEYS.help_lines("workitem_view", title, help,
    { fixed = { "  j / k       move" }, service = WORDS.service }))
end

local function leave()
  if S.WI_VIEW_RELOAD then S.WI_VIEW_RELOAD[ID] = nil end
  if S.WI_VIEW_EDIT then S.WI_VIEW_EDIT[ID] = nil end
  if #vim.api.nvim_list_tabpages() > 1 then
    -- An inner tab: back to the one before it (innertabs.lua).
    pcall(INNER.closing)
    pcall(vim.cmd, "tabclose")
    -- Change-aware dashboard refresh: only redraws if the list actually changed.
    if S.WI_REFRESH then vim.schedule(S.WI_REFRESH) end
  else
    vim.cmd("qa!")
  end
end

KEYS.bind(buf, "workitem_view", "open", open_linked, { desc = "open that " .. ITEM .. " here" })
KEYS.bind(buf, "workitem_view", "state", set_state, { desc = "change the state of this " .. ITEM })
KEYS.bind(buf, "workitem_view", "assign", assign_item, { desc = "assign this " .. ITEM })
KEYS.bind(buf, "workitem_view", "priority", set_priority, { desc = "set this " .. ITEM .. "'s priority" })
KEYS.bind(buf, "workitem_view", "edit_title", open_edit, { desc = "edit this " .. ITEM .. " (every field)" })
if B.caps.description then
  KEYS.bind(buf, "workitem_view", "description", edit_description,
    { desc = "write or edit this " .. ITEM .. "'s description" })
end
KEYS.bind(buf, "workitem_view", "move_sprint", move_sprint_item, { desc = "move this " .. ITEM .. " to another " .. SPRINT })
-- gU: workitems/parent.lua, shared with the dashboard; its move reloads
-- this view through S.WI_VIEW_RELOAD.
KEYS.bind(buf, "workitem_view", "set_parent", function()
  if ID == "" then return end
  local parent = current_data and current_data.parent
  require("azure-cli.workitems.parent").choose(B, { id = current_item.id or shown(), key = ID,
    parentId = parent and parent.id or nil })
end, { desc = "move this " .. ITEM .. " under another parent" })
KEYS.bind(buf, "workitem_view", "comment", add_comment,
  { desc = B.host == "github" and "add a comment" or "add a discussion comment" })
if B.caps.links then
  KEYS.bind(buf, "workitem_view", "link_pr", link_pr, { desc = "link a pull request" })
  KEYS.bind(buf, "workitem_view", "unlink_pr", unlink_pr, { desc = "unlink a pull request" })
end
KEYS.bind(buf, "workitem_view", "open_pr", open_linked_pr, { desc = "open a linked pull request" })
KEYS.bind(buf, "workitem_view", "browser", open_browser, { desc = "open this " .. ITEM .. " in the browser" })
KEYS.bind(buf, "workitem_view", "copy_link", yank_link, { desc = "copy this " .. ITEM .. "'s link" })
KEYS.bind(buf, "workitem_view", "refresh", function() if ID ~= "" then load(ID, true) end end, { desc = "refresh" })
KEYS.bind(buf, "workitem_view", "back", leave, { desc = "close and return to the dashboard" })
KEYS.bind(buf, "workitem_view", "quit", leave, { desc = "close and return to the dashboard" })
KEYS.bind(buf, "workitem_view", "help", show_help, { desc = "this help" })
-- The chat (B.caps.chat): on GitHub its board tools then take board =
-- "github", which the snapshot names.
if B.caps.chat then
-- i: the chat panel's input box, told which work item this view shows.
require("azure-cli.chat").bind_toggle(buf, "workitem_view")
-- One describer per filetype, but several of these views open at once
-- (inner tabs): it asks the one in the window being described.
S.WI_VIEW_SNAP = S.WI_VIEW_SNAP or {}
require("azure-cli.chat.view").register(B.item_ft, function(win)
  local ok, b = pcall(vim.api.nvim_win_get_buf, win or 0)
  local f = ok and S.WI_VIEW_SNAP[b]
  if f then return f() end
end)
vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true,
  callback = function() S.WI_VIEW_SNAP[buf] = nil end })
S.WI_VIEW_SNAP[buf] = function()
  local snap = { screen = B.host == "github" and "issue detail view" or "work item detail view",
    work_item = { id = tonumber(ID) or ID } }
  local c = S.WI_DETAIL_CACHE[ID]
  local ok, d = pcall(vim.json.decode, c and c.body or "")
  local item = ok and type(d) == "table" and (d.item or d) or nil
  if type(item) == "table" then
    snap.work_item.type, snap.work_item.title, snap.work_item.state = item.type, item.title, item.state
  end
  if B.host == "github" then
    snap.board = "github"
    local n = ID:match("~(%d+)$")
    if n then snap.work_item.id = tonumber(n) end
    snap.work_item.board = "github"
    snap.work_item.repo = (type(item) == "table" and item.repo) or ID:match("^[^~]+~([^~]+)~") or nil
    snap.work_item.key = (type(item) == "table" and item.key) or (n and ID) or nil
  end
  return snap
end
end

if ID == "" then
  set_lines({ "No " .. ITEM .. " id (AZVICLI_WI_ID) set." })
else
  load(ID)
end

end  -- M.open()

return M
