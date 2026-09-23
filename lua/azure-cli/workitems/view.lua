-- lua/azure-cli/workitems/view.lua: read-only work-item detail view (opened
-- from workitems/dashboard.lua).
--
-- Reads AZVICLI_WI_ID from the environment, fetches the item + its parent and
-- children + flattened description via the headless provider (azure-cli.py
-- --wi-detail), and renders them into a scratch buffer. Parent/child lines
-- are navigable with <CR>.
--
-- Keys
--   <CR>   on a parent/child line: open that work item here
--   gs     change the state of this work item
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
-- Fallback org/project for gl (link a PR) when the PR isn't in the dashboard's
-- cached PR list: only the AZVICLI_WI_COLLECTION/AZVICLI_WI_PROJECT overrides -
-- no hard-coded org here either.
local COLLECTION = env.AZVICLI_WI_COLLECTION or ""
local PROJECT = env.AZVICLI_WI_PROJECT or ""

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
  Iteration = true, Tags = true, URL = true, PRs = true,
}
local ns = vim.api.nvim_create_namespace("azure_cli_workitem")

local row_link = {}  -- buffer line (1-based) -> work item id (parent/child rows)

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
    local pr_ids = {}
    for _, p in ipairs(prs) do pr_ids[#pr_ids + 1] = "!" .. tostring(p.id) end
    lines[#lines + 1] = "PRs:" .. string.rep(" ", 11 - 4) .. table.concat(pr_ids, ", ")
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
-- Workflow metadata caches shared with workitems/dashboard.lua (keyed by "type\0state"),
-- so the state/reason pickers are instant when the dashboard already warmed them.
STATE.WI_TRANS_CACHE = STATE.WI_TRANS_CACHE or {}
STATE.WI_REASON_CACHE = STATE.WI_REASON_CACHE or {}
local META_TTL = 600
local prev_reg_id = nil
local CACHE_TTL = 30

-- Fetch a cached metadata list (transitions/reasons) for a (type, state),
-- invoking cb(list) when ready; instant on a fresh cache hit, coalesced when
-- concurrent. cb is optional (prefetch = no cb).
local meta_inflight = {}
local function fetch_meta(cache, subcmd, wtype, state, cb)
  local key = wtype .. "\0" .. state
  local c = cache[key]
  if c and (os.time() - c.ts) < META_TTL then
    if cb then cb(c.list) end
    return
  end
  local ikey = subcmd .. "\0" .. key
  if meta_inflight[ikey] then
    if cb then table.insert(meta_inflight[ikey], cb) end
    return
  end
  meta_inflight[ikey] = cb and { cb } or {}
  local out = {}
  RPC.run(provider_argv("--wi-state", subcmd, wtype, state), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      local list = vim.tbl_filter(function(s) return s ~= "" end, out)
      if code == 0 then cache[key] = { list = list, ts = os.time() } end
      local cbs = meta_inflight[ikey]
      meta_inflight[ikey] = nil
      for _, f in ipairs(cbs or {}) do pcall(f, list) end
    end,
  })
end

local function fetch_transitions(wtype, cur, cb)
  fetch_meta(STATE.WI_TRANS_CACHE, "transitions", wtype, cur, cb)
end

local function fetch_reasons(wtype, new, cb)
  fetch_meta(STATE.WI_REASON_CACHE, "reasons", wtype, new, cb)
end

local function meta_cached(cache, wtype, state)
  local c = cache[wtype .. "\0" .. state]
  return c and (os.time() - c.ts) < META_TTL
end

-- Warm the state/reason caches for the current item so 'gs' is instant here too.
local function prefetch_state_meta()
  local wtype, state = current_item.type or "", current_item.state or ""
  if wtype == "" or state == "" then return end
  fetch_transitions(wtype, state, function(targets)
    for _, t in ipairs(targets or {}) do fetch_reasons(wtype, t) end
  end)
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

local function open_linked()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local id = row_link[line]
  if id then load(id) end
end

-- Commit a new state (and optional reason) for this work item, then refresh
-- this view and the dashboard.
local function apply_state(new, reason)
  if ID == "" then return end
  local suffix = (reason and reason ~= "") and (" (" .. reason .. ")") or ""
  notify("Setting #" .. ID .. " \u{2192} " .. new .. suffix .. " \u{2026}")
  local cmd = provider_argv("--wi-state", "set", ID, new)
  if reason and reason ~= "" then cmd[#cmd + 1] = reason end
  local err = {}
  RPC.run(cmd, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("#" .. ID .. " is now " .. new .. suffix .. ".")
        STATE.WI_DETAIL_CACHE[ID] = nil
        load(ID, true)
        if STATE.WI_STATE_CHANGED then STATE.WI_STATE_CHANGED(ID, new) end
      else
        local msg = SHELL.job_error("work item #" .. ID, code, err)
        notify("Set #" .. ID .. " failed: " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
end

-- Prompt for the reason to record with a transition into `new`, then call
-- cb(reason). Offers the reasons actually accepted for that state, plus a
-- default (let ADO pick) and a free-text option. cb("") means "use default".
local function pick_reason(new, cb)
  local wtype = current_item.type or ""
  if not meta_cached(STATE.WI_REASON_CACHE, wtype, new) then
    notify("Fetching reasons \u{2026}")
  end
  fetch_reasons(wtype, new, function(reasons)
    vim.schedule(function()
      if #reasons <= 1 then
        cb("")
        return
      end
      local items = {}
      for _, r in ipairs(reasons) do items[#items + 1] = { label = r, reason = r } end
      items[#items + 1] = { label = "(default reason)", reason = "" }
      items[#items + 1] = { label = "(other\u{2026} type a reason)", other = true }
      PROMPT.select({ prompt = "Reason for #" .. ID .. " \u{2192} " .. new, items = items }, function(choice)
        if not choice then return end
        if choice.other then
          PROMPT.input({ prompt = "Reason:", allow_empty = true }, function(r)
            if r ~= nil then cb(r) end
          end)
          return
        end
        cb(choice.reason)
      end)
    end)
  end)
end

-- Change the state of this work item, offering only states reachable from its
-- current state (per the ADO workflow transitions), then a reason.
local function set_state()
  if ID == "" then return end
  local wtype, cur = current_item.type or "", current_item.state or ""
  if not meta_cached(STATE.WI_TRANS_CACHE, wtype, cur) then
    notify("Fetching states for #" .. ID .. " \u{2026}")
  end
  fetch_transitions(wtype, cur, function(states)
    if #states == 0 then
      notify("No transitions for #" .. ID .. ".", vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      PROMPT.select({ prompt = "Set #" .. ID .. " (" .. cur .. " \u{2192})", items = states }, function(new)
        if not new then return end
        pick_reason(new, function(reason) apply_state(new, reason) end)
      end)
    end)
  end)
end

-- Commit a single-field --wi-edit "set" for this work item, then refresh
-- this view (the way apply_state does) and, when given, reconcile the
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
  ask(function(pr_id)
  if pr_id == nil then return end
  if not pr_id:match("^%d+$") then
    notify("PR id must be numeric.", vim.log.levels.WARN)
    return
  end
  local org, project, repo
  local cache = STATE.PR_LIST_CACHE and STATE.PR_LIST_CACHE.prs
  if cache then
    for _, pr in ipairs(cache) do
      if tostring(pr.id) == pr_id then
        org, project, repo = pr.org, pr.project, pr.repo
        break
      end
    end
  end
  local function go()
  notify("Linking PR !" .. pr_id .. " to #" .. ID .. " \u{2026}")
  local err = {}
  RPC.run(provider_argv("--wi-edit", "link-pr", ID, org, project, repo, pr_id), {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("Linked PR !" .. pr_id .. " to #" .. ID .. ".")
        STATE.WI_DETAIL_CACHE[ID] = nil
        load(ID, true)
      else
        local msg = SHELL.job_error("work item #" .. ID, code, err)
        notify("Link PR !" .. pr_id .. " failed: " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
  end
  if repo then
    go()
    return
  end
  PROMPT.input({ prompt = "Repository name:" }, function(name)
    if name == nil then return end
    repo = name
    org = org or COLLECTION
    project = project or PROJECT
    go()
  end)
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
  PROMPT.select({ prompt = "Unlink PR from #" .. ID, items = prs,
    format = function(p) return "!" .. tostring(p.id) .. (p.title and p.title ~= "" and ("  " .. p.title) or "") end },
    function(p)
  if not p then return end
  local pr_id = tostring(p.id)
  notify("Unlinking PR !" .. pr_id .. " from #" .. ID .. " \u{2026}")
  local err = {}
  RPC.run(provider_argv("--wi-edit", "unlink-pr", ID, pr_id), {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("Unlinked PR !" .. pr_id .. " from #" .. ID .. ".")
        STATE.WI_DETAIL_CACHE[ID] = nil
        load(ID, true)
      else
        local msg = SHELL.job_error("work item #" .. ID, code, err)
        notify("Unlink PR !" .. pr_id .. " failed: " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
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
  { "open", "on a parent/child line: open that work item here" },
  "This item",
  { "state", "change the state of this work item" },
  { "assign", "assign this work item" },
  { "priority", "set this work item's priority" },
  { "edit_title", "edit this work item's title" },
  { "move_sprint", "move this work item to another sprint" },
  { "comment", "add a discussion comment" },
  { "link_pr", "link a pull request" },
  { "unlink_pr", "unlink a pull request" },
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
KEYS.bind(buf, "workitem_view", "browser", open_browser, { desc = "open this work item in the browser" })
KEYS.bind(buf, "workitem_view", "copy_link", yank_link, { desc = "copy this work item's link" })
KEYS.bind(buf, "workitem_view", "refresh", function() if ID ~= "" then load(ID, true) end end, { desc = "refresh" })
KEYS.bind(buf, "workitem_view", "back", leave, { desc = "close and return to the dashboard" })
KEYS.bind(buf, "workitem_view", "quit", leave, { desc = "close and return to the dashboard" })
KEYS.bind(buf, "workitem_view", "help", show_help, { desc = "this help" })

if ID == "" then
  set_lines({ "No work item id (AZVICLI_WI_ID) set." })
else
  load(ID)
end

end  -- M.open()

return M
