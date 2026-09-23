-- lua/azure-cli/workitems/dashboard.lua: Neovim work-items dashboard.
--
-- Sibling of dashboard.lua. Renders the user stories and bugs assigned to me
-- in the current sprint by running the python data provider
-- (azure-cli.py --wi-list, NDJSON), and opens a read-only detail view
-- (workitems/view.lua) on <CR>. Press W in the PR dashboard to come here,
-- and P here to go back to the PR dashboard.
--
-- Keys
--   j/k    move
--   <CR>   open the work item under the cursor (parent/children/description)
--   gs     change the state of the work item under the cursor
--   n      new work item: type, title, and parent (if the cursor is on one)
--   ga     assign the item under the cursor
--   gp     set the item's priority
--   ge     edit the item's title
--   gi     move the item to another sprint of the quarter
--   gl     link a pull request to the item under the cursor
--   [ ]    jump to the previous / next sprint in the quarter (also <S-Tab>/<Tab>)
--   {n}gt  jump to sprint n (1-based, like vim's tab gt); gt with no count = next
--   click  click a tab in the tab bar to jump straight to that sprint
--   r      refresh
--   P      switch to the pull-request dashboard
--   q      quit
--   ?      show this help
--
-- M.open() (re)builds this dashboard - called by lua/azure-cli/init.lua's
-- open_workitems() and, to swap back from the PR dashboard, by
-- dashboard.lua's "W" key and this file's own "P" key directly.
local CONFIG = require("azure-cli.config")
local STATE = require("azure-cli.state")
local RPC = require("azure-cli.rpc")
local KEYS = require("azure-cli.keys")
local STATES = require("azure-cli.workitems.states")
local UI = require("azure-cli.ui")
local PROMPT = require("azure-cli.prompt")
-- Shared housekeeping helpers - see shell.lua; the PR dashboard, the
-- reviewer and this file each used to carry private copies of these.
local SHELL = require("azure-cli.shell")

local M = {}

function M.open()

local env    = vim.env
-- Data-provider argv (python azure-cli.py) every work-item fetch/action in
-- this dashboard runs, replacing wi-list.sh/wi-detail.sh/wi-state.sh/
-- wi-edit.sh entirely. The builder lives in config.lua next to
-- provider_cmd() now; this file and workitems/view.lua had the same copy.
local provider_argv = CONFIG.provider_argv
-- AZVICLI_WI_COLLECTION/AZVICLI_WI_PROJECT overrides only: the fallback org/project
-- for gl (link a PR) when the PR isn't in the cached PR list and isn't configured
-- either - no hard-coded org here either. There's no local ASSIGNEE any more: ga
-- (assign_item below) sends an empty submission through as-is, and azure-cli.py
-- resolves that to the real "me" (work_items: assignee: from config, or the
-- signed-in user) itself - see WorkItemActions.assignee/_wi_set_field.
local COLLECTION = env.AZVICLI_WI_COLLECTION or ""
local PROJECT = env.AZVICLI_WI_PROJECT or ""

-- Detail cache shared with workitems/view.lua (same nvim session): id -> {body, ts}.
-- Prefetching the item under the cursor lets the detail tab open instantly.
local WI_DETAIL_CACHE = STATE.WI_DETAIL_CACHE
local CACHE_TTL = 30  -- seconds a prefetched detail is considered fresh

-- Workflow metadata caches shared with workitems/view.lua (same nvim session):
--   WI_TRANS_CACHE[type\0state]  -> { list = {targetStates}, ts }
--   WI_REASON_CACHE[type\0state] -> { list = {reasons}, ts }
-- These change rarely, so a long TTL is fine; pre-warming them makes the state
-- and reason pickers ('gs') appear instantly.
local WI_TRANS_CACHE = STATE.WI_TRANS_CACHE
local WI_REASON_CACHE = STATE.WI_REASON_CACHE
local META_TTL = 600

-- Per-sprint work-item cache keyed by iteration path, plus the quarter's sprint
-- list, both shared across dashboard swaps so re-entry and tab jumps are instant.
local WI_SPRINT_ITEMS = STATE.WI_SPRINT_ITEMS   -- path -> { items, ts }
-- STATE.WI_SPRINTS_CACHE = { list, quarter, currentIndex, ts }
local LIST_TTL = 30
local SPRINTS_TTL = 300

-- Sections: one per work item type, in this order. Types not listed here fall
-- into a trailing "Other" bucket.
-- Sections follow work_items.types: (carried on the --wi-list sprints
-- meta line, see wi_types below); this is only the fallback for a cache
-- from before that field existed.
local DEFAULT_TYPES = { "User Story", "Bug" }
local wi_types = nil
local function plural(t)
  if t:match("[^aeiou]y$") then return t:sub(1, -2) .. "ies" end
  if t:match("s$") then return t end
  return t .. "s"
end
local function sections()
  local out = {}
  for _, t in ipairs(wi_types or DEFAULT_TYPES) do out[#out + 1] = { key = t, title = plural(t) } end
  return out
end

-- Colours (termguicolors is on). Defined idempotently so re-opening this
-- dashboard is harmless. State groups are reused by workitems/view.lua's
-- own setup. Every group links to a standard highlight group with
-- `default = true` (UI.link_hl applies that for every group), so plugin
-- mode picks up the active colorscheme and standalone/init.lua's explicit
-- catppuccin-mocha palette (applied after this, non-default) still wins.
UI.link_hl({
  AzureCliWiHeader      = "Title",
  AzureCliWiId          = "Identifier",
  AzureCliWiActive      = "String",
  AzureCliWiNew         = "Special",
  AzureCliWiImplemented = "WarningMsg",
  AzureCliWiResolved    = "Directory",
  AzureCliWiClosed      = "Comment",
  AzureCliWiRemoved     = "ErrorMsg",
  AzureCliWiOther       = "Comment",
  AzureCliWiDivider     = "NonText",
  AzureCliWiTabActive   = "TabLineSel",
  AzureCliWiTabInactive = "TabLine",
  AzureCliWiDate        = "Comment",
  AzureCliWiBorder      = "FloatBorder",
})

local ns = vim.api.nvim_create_namespace("azure_cli_workitems")

local items = {}     -- all parsed work item records
local row_item = {}  -- buffer line (1-based) -> record (nil on header/blank)
local buf, win
local sprints = {}            -- quarter's sprints: {name,label,path,start,finish,timeframe,current}
local active_index = 1        -- 1-based index into sprints (the focused tab)
local quarter = ""            -- quarter node label, e.g. "MyProject\\2026\\Q3"
-- Rank/highlight tables for the active states list (work_items.states:,
-- see lua/azure-cli/workitems/states.lua) - rebuilt whenever apply_sprints
-- below sees a fresh "states" field, falls back to states.lua's own
-- hard-coded tables until then / when the field is never sent.
local wi_built = STATES.build(nil)
-- Case-insensitive text filter over id/title/state/assignee (empty = show
-- all); in STATE so it survives a P/W dashboard swap.
local wi_filter = STATE.wi_filter or ""
local function item_matches(it, q)
  if tostring(it.id or ""):find(q, 1, true) then return true end
  for _, field in ipairs({ "title", "state", "assignedTo", "type" }) do
    local v = it[field]
    if type(v) == "string" and v:lower():find(q, 1, true) then return true end
  end
  return false
end
local prefetch_state_meta     -- forward decl: warms state/reason caches
local prefetch_neighbors      -- forward decl: warms adjacent sprints' items
local loading = false         -- true while a fetch for the active tab is in flight
local tabbar_hl = {}          -- byte ranges of the two tab segments, for highlighting
local date_row = nil          -- 1-based line of the sprint date line, for highlighting
local tab_row = 1             -- 1-based line of the tab bar itself, for click hit-testing
local content_col = 0         -- byte column where a normal row's real content starts (inside the box)

local notify = SHELL.notify

-- gO: open azure-cli.yml in a new tab (or explain that setup({accounts=...})
-- is what's being read instead). Shared with the PR dashboard and the
-- reviewer, which each had this verbatim.
local open_config_file = SHELL.open_config_file

local fit = UI.fit

local TAB_SEP = "  "
local function tab_seg(name, is_active)
  if is_active then return "[" .. name .. "]" end
  return " " .. name .. " "
end

-- Build the tab-bar line for the quarter's sprints and record the byte range of
-- each visible segment for highlighting. When the tabs are wider than the window
-- a window of tabs around the active one is shown, with ‹/› overflow markers.
local function build_tabbar()
  tabbar_hl = {}
  if #sprints == 0 then return "(loading sprints…)" end
  local segs = {}
  for i, sp in ipairs(sprints) do
    segs[i] = tab_seg(sp.label or ("S" .. i), i == active_index)
  end
  local width = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win))
    or vim.o.columns or 80
  width = width - 6  -- leave room for the ‹ › overflow markers
  local lo, hi = active_index, active_index
  local used = #segs[active_index]
  local grow = true
  while grow do
    grow = false
    if hi < #segs and used + #TAB_SEP + #segs[hi + 1] <= width then
      hi = hi + 1; used = used + #TAB_SEP + #segs[hi]; grow = true
    end
    if lo > 1 and used + #TAB_SEP + #segs[lo - 1] <= width then
      lo = lo - 1; used = used + #TAB_SEP + #segs[lo]; grow = true
    end
  end
  local line = (lo > 1) and "‹ " or ""
  for i = lo, hi do
    local s = #line
    line = line .. segs[i]
    tabbar_hl[#tabbar_hl + 1] = { s = s, e = #line, idx = i, active = (i == active_index) }
    if i < hi then line = line .. TAB_SEP end
  end
  if hi < #segs then line = line .. " ›" end
  return line
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Parse the date part of an ISO timestamp (YYYY-MM-DD...) to an epoch at noon
-- (noon avoids DST edge cases in whole-day math).
local function parse_date(iso)
  if not iso or iso == "" then return nil end
  local y, m, d = iso:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

local function fmt_date(t)  -- e.g. "26 Aug 2026"
  local dt = os.date("*t", t)
  return string.format("%d %s %d", dt.day, MONTHS[dt.month], dt.year)
end

local function day_diff(a, b)  -- whole days from a to b
  return math.floor((b - a) / 86400 + 0.5)
end

-- "26 Aug 2026 – 8 Sep 2026  (ends in 1d)" for the focused sprint, or nil.
local function sprint_dateline()
  local sp = sprints[active_index]
  if not sp then return nil end
  local ts, tf = parse_date(sp.start), parse_date(sp.finish)
  if not ts or not tf then return nil end
  local now = os.time()
  local rel
  if now < ts then
    rel = "starts in " .. day_diff(now, ts) .. "d"
  elseif now <= tf then
    rel = "ends in " .. math.max(0, day_diff(now, tf)) .. "d"
  else
    rel = "ended " .. day_diff(tf, now) .. "d ago"
  end
  return fmt_date(ts) .. " – " .. fmt_date(tf) .. "  (" .. rel .. ")"
end

-- "Sep 1–14" (same month) or "Sep 28–Oct 2" (crossing a month) - the compact
-- date range set_wi_winbar below puts next to the sprint label; sprint_dateline
-- above is the fuller "26 Aug 2026 – 8 Sep 2026 (ends in 1d)" shown as its own
-- row in the table.
local function short_date(t)
  local dt = os.date("*t", t)
  return MONTHS[dt.month] .. " " .. dt.day
end
local function short_range(sp)
  local ts, tf = parse_date(sp.start), parse_date(sp.finish)
  if not ts or not tf then return nil end
  local dts, dtf = os.date("*t", ts), os.date("*t", tf)
  if dts.month == dtf.month and dts.year == dtf.year then
    return MONTHS[dts.month] .. " " .. dts.day .. "\u{2013}" .. dtf.day
  end
  return short_date(ts) .. "\u{2013}" .. short_date(tf)
end

-- Winbar: "Work items · Sprint 42 (Sep 1-14) · 7 items   ?: help" - see
-- lua/azure-cli/ui.lua's UI.winbar. No mode tags here (nothing on this
-- dashboard toggles a filter/mode the way the PR dashboard or reviewer do).
local function set_wi_winbar()
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local parts = { "Work items" }
  local sp = sprints[active_index]
  if sp then
    local label = sp.label or ("Sprint " .. active_index)
    local range = short_range(sp)
    parts[#parts + 1] = range and (label .. " (" .. range .. ")") or label
    parts[#parts + 1] = #items .. " items"
  end
  local cache = sp and WI_SPRINT_ITEMS[sp.path]
  if cache and cache.ts then
    local age = os.time() - cache.ts
    parts[#parts + 1] = "updated " .. (age < 60 and "just now" or (math.floor(age / 60) .. "m ago"))
  end
  local tags = {}
  if loading then tags[#tags + 1] = "[loading\u{2026}]" end
  if wi_filter ~= "" then tags[#tags + 1] = "[filter: " .. wi_filter .. "]" end
  pcall(function()
    UI.wo(win, "winbar", UI.winbar(parts, tags))
  end)
end

local function render()
  -- Remember which item the cursor is on (by id, not raw row number) before
  -- we rebuild everything below, since the box's vertical centring means row
  -- numbers shift whenever the window is resized or the row count changes.
  local prev_item_id
  if win and vim.api.nvim_win_is_valid(win) then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local prev_it = row_item[cur[1]]
      prev_item_id = prev_it and prev_it.id
    end
  end

  local lines = {}
  row_item = {}
  date_row = nil

  -- Tab bar: one tab per sprint in the quarter, with the focused sprint's dates below.
  lines[#lines + 1] = build_tabbar()
  local dl = sprint_dateline()
  if dl then
    lines[#lines + 1] = dl
    date_row = #lines
  end
  lines[#lines + 1] = ""

  set_wi_winbar()

  local by_type = {}
  local order = {}
  for _, sec in ipairs(sections()) do
    by_type[sec.key] = {}
    order[#order + 1] = sec
  end
  local other = {}
  local shown = 0
  local flc = wi_filter:lower()
  for _, it in ipairs(items) do
    if flc == "" or item_matches(it, flc) then
      shown = shown + 1
      if by_type[it.type] then
        table.insert(by_type[it.type], it)
      else
        table.insert(other, it)
      end
    end
  end
  if #other > 0 then
    by_type["__other__"] = other
    order[#order + 1] = { key = "__other__", title = "Other" }
  end

  local function sort_items(list)
    table.sort(list, function(a, b)
      local ra = wi_built.rank[a.state] or 9999
      local rb = wi_built.rank[b.state] or 9999
      if ra ~= rb then return ra < rb end
      return (a.id or 0) > (b.id or 0)
    end)
  end

  for _, sec in ipairs(order) do
    local list = by_type[sec.key]
    if list and #list > 0 then
      sort_items(list)
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = "── " .. sec.title .. " (" .. #list .. ") ──"
      local prev_state
      for _, it in ipairs(list) do
        if prev_state and it.state ~= prev_state then
          lines[#lines + 1] = "  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
        end
        prev_state = it.state
        local pri = type(it.priority) == "number" and ("P" .. it.priority) or "  "
        local row = string.format(
          "  #%-7s %-13s %s %-4s %s",
          tostring(it.id),
          "[" .. (it.state or "") .. "]",
          fit(it.title, 60),
          pri,
          it.changedHuman or ""
        )
        lines[#lines + 1] = row
        row_item[#lines] = it
      end
    end
  end

  if vim.tbl_isempty(row_item) then
    if loading then
      lines[#lines + 1] = "Loading work items…"
    elseif wi_filter ~= "" then
      lines[#lines + 1] = 'No work items match "' .. wi_filter .. '"  (/ then <Esc> clears the filter).'
    else
      lines[#lines + 1] = "No work items assigned to you in "
        .. ((sprints[active_index] and sprints[active_index].label) or "this sprint") .. "."
      lines[#lines + 1] = "  n creates one here \u{00B7} ] / [ other sprints \u{00B7} gO edits work_items.assignee/types"
    end
  end

  -- Wrap the table in a rounded border box and centre it in the window, both
  -- horizontally and vertically. row_item/date_row/tabbar_hl all reference
  -- positions in the pre-box `lines`, so they get shifted by the same offsets
  -- (regex-based highlights below run against the final, already-boxed text,
  -- so they don't need adjusting — border/tab rows are just special-cased by
  -- line number so they aren't mistaken for section headers).
  local content_width = 0
  for _, l in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  content_width = math.max(content_width, 1)
  local box_width = content_width + 4
  local win_width = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)) or vim.o.columns
  local win_height = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_height(win)) or vim.o.lines
  local pad_h = math.max(0, math.floor((win_width - box_width) / 2))
  local hprefix = string.rep(" ", pad_h)
  local col_offset = pad_h + #"│ "  -- hprefix + "│ " (│ is a 3-byte UTF-8 char, not 1)

  local boxed = {}
  boxed[#boxed + 1] = hprefix .. "╭" .. string.rep("─", box_width - 2) .. "╮"
  local tab_extra_pad = 0
  for i, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    if i == 1 then
      -- Centre the tab bar within the box instead of left-justifying it, so
      -- the active tab lines up visually with the rest of the (usually wider)
      -- table instead of sitting flush against the left border.
      tab_extra_pad = math.max(0, math.floor((content_width - w) / 2))
      boxed[#boxed + 1] = hprefix .. "│ " .. string.rep(" ", tab_extra_pad) .. l
        .. string.rep(" ", content_width - w - tab_extra_pad) .. " │"
    else
      boxed[#boxed + 1] = hprefix .. "│ " .. l .. string.rep(" ", content_width - w) .. " │"
    end
  end
  boxed[#boxed + 1] = hprefix .. "╰" .. string.rep("─", box_width - 2) .. "╯"

  local pad_v = math.max(0, math.floor((win_height - #boxed) / 2))
  local final = {}
  for _ = 1, pad_v do final[#final + 1] = "" end
  local top_line_1based = #final + 1
  for _, l in ipairs(boxed) do final[#final + 1] = l end
  local bottom_line_1based = #final
  local row_offset = pad_v + 1  -- add to an old 1-based `lines` index to get the new one

  local tab_line_1based = 1 + row_offset  -- the tab bar was always old line 1
  tab_row = tab_line_1based
  content_col = col_offset
  if date_row then date_row = date_row + row_offset end
  local shifted_row_item = {}
  for ln, it in pairs(row_item) do
    shifted_row_item[ln + row_offset] = it
  end
  row_item = shifted_row_item
  for _, seg in ipairs(tabbar_hl) do
    seg.s = seg.s + col_offset + tab_extra_pad
    seg.e = seg.e + col_offset + tab_extra_pad
  end

  lines = final

  -- Change-aware: skip the buffer write + re-highlight when nothing changed, so
  -- periodic/auto refresh never flickers or moves the cursor.
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Colour section headers, the #id, and the [state] token on each row.
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local lnum = i - 1
    if i == tab_line_1based then
      for _, seg in ipairs(tabbar_hl) do
        vim.api.nvim_buf_add_highlight(buf, ns,
          seg.active and "AzureCliWiTabActive" or "AzureCliWiTabInactive", lnum, seg.s, seg.e)
      end
    elseif i == top_line_1based or i == bottom_line_1based then
      vim.api.nvim_buf_add_highlight(buf, ns, "AzureCliWiBorder", lnum, 0, -1)
    elseif i == date_row then
      vim.api.nvim_buf_add_highlight(buf, ns, "AzureCliWiDate", lnum, 0, -1)
    elseif line:match("──") then
      vim.api.nvim_buf_add_highlight(buf, ns, "AzureCliWiHeader", lnum, 0, -1)
    elseif line:match("┄") then
      vim.api.nvim_buf_add_highlight(buf, ns, "AzureCliWiDivider", lnum, 0, -1)
    else
      local s, e = line:find("#%d+")
      if s then vim.api.nvim_buf_add_highlight(buf, ns, "AzureCliWiId", lnum, s - 1, e) end
      local bs, be, state = line:find("%[(.-)%]")
      if bs then
        vim.api.nvim_buf_add_highlight(buf, ns, wi_built.hl[state] or "AzureCliWiOther", lnum, bs - 1, be)
      end
    end
  end

  -- The box's vertical/horizontal centring means row numbers move around
  -- whenever the window is resized or the row count changes (blank-padding
  -- rows above/below shift everything). Re-find the same item (by id) the
  -- cursor was on before this render and land there again; fall back to the
  -- first item row, or the tab bar row if the list is empty.
  if win and vim.api.nvim_win_is_valid(win) then
    local target
    if prev_item_id then
      for ln, it in pairs(row_item) do
        if it.id == prev_item_id then target = ln; break end
      end
    end
    if not target then
      for ln in pairs(row_item) do
        if not target or ln < target then target = ln end
      end
    end
    -- The tab row is centred with its own extra left pad, unlike normal item
    -- rows, so its content-start column differs from col_offset.
    local col = target and col_offset or (col_offset + tab_extra_pad)
    pcall(vim.api.nvim_win_set_cursor, win, { target or tab_line_1based, col })
  end
end

local function current_item()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return row_item[line]
end

-- Fetch the item + parent + children in the background and cache it, so opening
-- the detail view is instant. No-op when a fresh entry already exists.
local prefetching = {}
local function prefetch(id)
  id = tostring(id or "")
  if id == "" then return end
  local c = WI_DETAIL_CACHE[id]
  if c and (os.time() - c.ts) < CACHE_TTL then return end
  if prefetching[id] then return end
  prefetching[id] = true
  local out = {}
  RPC.run(provider_argv("--wi-detail", id), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      prefetching[id] = nil
      if code == 0 then
        WI_DETAIL_CACHE[id] = { body = table.concat(out, "\n"), ts = os.time() }
      end
    end,
  })
end

-- Parse NDJSON work-item records (skipping any _meta line) into a list.
local function parse_items(out)
  local fresh = {}
  for _, line in ipairs(out) do
    if line:gsub("%s", "") ~= "" then
      local ok, rec = pcall(vim.json.decode, line)
      if ok and type(rec) == "table" and not rec._meta then
        fresh[#fresh + 1] = rec
      end
    end
  end
  return fresh
end

-- Load the focused sprint's work items (by iteration path). Renders the cached
-- list immediately when available, then refetches unless the cache is fresh.
local function load(silent, force)
  local sp = sprints[active_index]
  if not sp then return end
  local path = sp.path
  local cache = WI_SPRINT_ITEMS[path]
  if cache and cache.items then
    items = cache.items
    loading = false
    render()
    if prefetch_state_meta then prefetch_state_meta() end
  elseif not silent then
    loading = true
    items = {}
    render()
  end

  if cache and cache.items and not force and (os.time() - cache.ts) < LIST_TTL then
    return
  end

  local out, err = {}, {}
  RPC.run(provider_argv("--wi-list", "items", path), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      -- Guard against the user having jumped to another sprint mid-fetch.
      local still = sprints[active_index] and sprints[active_index].path == path
      if code ~= 0 then
        local LOG = require("azure-cli.log")
        local raw = LOG.join_output(out, err)
        LOG.record("work items", raw)
        if silent and cache and cache.items then
          notify("Refresh failed: " .. LOG.summary(raw, 60) .. "  (r to retry, :AzureCli log)", vim.log.levels.WARN)
          return
        end
        if still and vim.api.nvim_buf_is_valid(buf) then
          loading = false
          local lines = { build_tabbar(), "" }
          vim.list_extend(lines, LOG.failure_lines("Failed to load work items (exit " .. code .. "):", raw))
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          vim.bo[buf].modifiable = false
        end
        return
      end
      local fresh = parse_items(out)
      WI_SPRINT_ITEMS[path] = { items = fresh, ts = os.time() }
      if still then
        items = fresh
        loading = false
        render()
        if prefetch_state_meta then prefetch_state_meta() end
      end
    end,
  })
end

-- Fetch the quarter's sprint list, then cb(). focus_current=true lands on the
-- current sprint (used on open); otherwise the focused sprint is preserved by
-- path across the refresh.
local function apply_sprints(d)
  sprints = d.sprints or {}
  quarter = d.quarter or ""
  wi_built = STATES.build(d.states)
  if type(d.types) == "table" and #d.types > 0 then wi_types = d.types end
  return tonumber(d.currentIndex) or 0
end

local function load_sprints(cb, focus_current)
  local prev_path = sprints[active_index] and sprints[active_index].path
  local function finalize(ci)
    if focus_current and ci >= 1 and ci <= #sprints then
      active_index = ci
    elseif prev_path then
      for i, sp in ipairs(sprints) do
        if sp.path == prev_path then active_index = i; break end
      end
    end
    active_index = math.max(1, math.min(active_index, math.max(1, #sprints)))
    if cb then cb() end
  end

  local c = STATE.WI_SPRINTS_CACHE
  if c and c.list and (os.time() - c.ts) < SPRINTS_TTL then
    sprints = c.list
    quarter = c.quarter or ""
    wi_built = STATES.build(c.states)
    if type(c.types) == "table" and #c.types > 0 then wi_types = c.types end
    finalize(tonumber(c.currentIndex) or 0)
    return
  end
  local out, err = {}, {}
  RPC.run(provider_argv("--wi-list", "sprints"), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      local ci = 0
      if code == 0 then
        for _, line in ipairs(out) do
          if line:gsub("%s", "") ~= "" then
            local ok, d = pcall(vim.json.decode, line)
            if ok and type(d) == "table" and d._sprints then
              ci = apply_sprints(d)
              STATE.WI_SPRINTS_CACHE = { list = sprints, quarter = quarter,
                                      currentIndex = ci, states = d.states, types = d.types, ts = os.time() }
              break
            end
          end
        end
      elseif #sprints == 0 and vim.api.nvim_buf_is_valid(buf) then
        -- Nothing loaded yet (e.g. no work_items: block configured, see
        -- ensure_configured() in azure-cli.py) - show the provider's own
        -- diagnostic in the buffer instead of leaving "(loading sprints...)"
        -- up forever. A transient failure once sprints are already loaded
        -- (periodic refresh) is left alone so the working view does not blank.
        loading = false
        local LOG = require("azure-cli.log")
        local raw = LOG.join_output(out, err)
        LOG.record("work items", raw)
        -- "No account has a work_items: block" isn't a failure, it's the
        -- feature being off - say so instead of "exit 1".
        local title = raw:find("work_items:", 1, true)
          and "Work items aren't configured yet:"
          or ("Failed to load work items (exit " .. code .. "):")
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, LOG.failure_lines(title, raw))
        vim.bo[buf].modifiable = false
      end
      finalize(ci)
    end,
  })
end

-- Jump to sprint at `idx` (clamped) and load it; prewarm neighbours.
local function set_sprint(idx)
  if #sprints == 0 then return end
  idx = math.max(1, math.min(idx, #sprints))
  if idx == active_index then return end
  active_index = idx
  load(false)
  -- Land the cursor on the first work item of the newly focused sprint, if any.
  local first
  for l in pairs(row_item) do
    if not first or l < first then first = l end
  end
  if first then
    pcall(vim.api.nvim_win_set_cursor, win, { first, content_col })
  end
  if prefetch_neighbors then prefetch_neighbors() end
end

-- Move the focused sprint by delta (-1 previous, +1 next).
local function goto_sprint(delta)
  set_sprint(active_index + delta)
end

-- {count}gt jumps to sprint number {count} (1-based, like vim's tab gt);
-- gt with no count just moves to the next sprint.
local function goto_sprint_count()
  local n = vim.v.count
  if n > 0 then
    set_sprint(n)
  else
    goto_sprint(1)
  end
end

-- Handle a left-click: jump to the sprint whose tab was clicked, otherwise
-- fall through to the normal click behaviour (cursor placement).
local function on_click()
  local pos = vim.fn.getmousepos()
  if pos.winid == win and pos.line == tab_row then
    for _, seg in ipairs(tabbar_hl) do
      if pos.column - 1 >= seg.s and pos.column - 1 < seg.e then
        set_sprint(seg.idx)
        return
      end
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "n", false)
end

-- Open the work item under the cursor in the read-only detail view (new tab).
local function open_item()
  local it = current_item()
  if not it then return end
  vim.env.AZVICLI_WI_ID = tostring(it.id)
  vim.cmd("tabnew")
  require("azure-cli.workitems.view").open()
end

-- Merge `fields` into every cached record for `id` (the active list plus
-- every sprint's cache), drop its stale detail cache entry, and re-render.
-- Exposed globally so a change committed from the detail view (wi-view.lua) -
-- state, assignee, priority or title - updates the dashboard too.
function STATE.WI_ITEM_CHANGED(id, fields)
  id = tostring(id)
  local function patch(list)
    if not list then return end
    for _, it in ipairs(list) do
      if tostring(it.id) == id then
        for k, v in pairs(fields) do it[k] = v end
      end
    end
  end
  patch(items)
  for _, c in pairs(WI_SPRINT_ITEMS or {}) do patch(c.items) end
  if WI_DETAIL_CACHE then WI_DETAIL_CACHE[id] = nil end
  if vim.api.nvim_buf_is_valid(buf) then pcall(render) end
end

-- Backward-compatible alias for the one field the dashboard's own 'gs' uses.
function STATE.WI_STATE_CHANGED(id, new)
  STATE.WI_ITEM_CHANGED(id, { state = new })
end

-- Reflect a work item moving to a different sprint (wi-view.lua's 'gi'):
-- drop it from the active list and its old sprint's cache, and drop the
-- target sprint's cache so it refetches fresh (with correct ranking/state)
-- next time that tab is visited. Exposed globally for the same reason as
-- WI_ITEM_CHANGED above.
function STATE.WI_ITEM_MOVED(id, from_path, to_path)
  id = tostring(id)
  local function drop(list)
    if not list then return end
    for i, it in ipairs(list) do
      if tostring(it.id) == id then table.remove(list, i); return end
    end
  end
  drop(items)
  local cache = from_path and WI_SPRINT_ITEMS[from_path]
  if cache then drop(cache.items) end
  if to_path then WI_SPRINT_ITEMS[to_path] = nil end
  if WI_DETAIL_CACHE then WI_DETAIL_CACHE[id] = nil end
  if vim.api.nvim_buf_is_valid(buf) then pcall(render) end
end

-- Fetch a cached metadata list (transitions or reasons) for a (type, state),
-- invoking cb(list) when ready. Serves from cache instantly when fresh, and
-- coalesces concurrent requests for the same key so pre-warming and an on-
-- demand 'gs' never launch duplicate jobs. cb is optional (prefetch = no cb).
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
  fetch_meta(WI_TRANS_CACHE, "transitions", wtype, cur, cb)
end

local function fetch_reasons(wtype, new, cb)
  fetch_meta(WI_REASON_CACHE, "reasons", wtype, new, cb)
end

local function meta_cached(cache, wtype, state)
  local c = cache[wtype .. "\0" .. state]
  return c and (os.time() - c.ts) < META_TTL
end

-- Apply a new state (and optional reason) to a work item, then reflect it in
-- the dashboard and any open detail view for that item.
local function apply_state(id, new, reason)
  local suffix = (reason and reason ~= "") and (" (" .. reason .. ")") or ""
  notify("Setting #" .. id .. " \u{2192} " .. new .. suffix .. " \u{2026}")
  local cmd = provider_argv("--wi-state", "set", id, new)
  if reason and reason ~= "" then cmd[#cmd + 1] = reason end
  local err = {}
  RPC.run(cmd, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("#" .. id .. " is now " .. new .. suffix .. ".")
        STATE.WI_STATE_CHANGED(id, new)
        local reload = STATE.WI_VIEW_RELOAD and STATE.WI_VIEW_RELOAD[tostring(id)]
        if reload then vim.schedule(reload) end
      else
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
        notify("Set #" .. id .. " failed: " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
end

-- Prompt for the reason to record with a transition into `new`, then call
-- cb(reason). Offers the reasons actually accepted for that state, plus a
-- default (let ADO pick) and a free-text option. cb("") means "use default".
local function pick_reason(id, wtype, new, cb)
  if not meta_cached(WI_REASON_CACHE, wtype, new) then
    notify("Fetching reasons \u{2026}")
  end
  fetch_reasons(wtype, new, function(reasons)
    vim.schedule(function()
      -- Nothing to choose between: let ADO record its default reason
      -- rather than asking a question with one answer.
      if #reasons <= 1 then
        cb("")
        return
      end
      local items = {}
      for _, r in ipairs(reasons) do items[#items + 1] = { label = r, reason = r } end
      items[#items + 1] = { label = "(default reason)", reason = "" }
      items[#items + 1] = { label = "(other\u{2026} type a reason)", other = true }
      PROMPT.select({ prompt = "Reason for #" .. id .. " \u{2192} " .. new, items = items }, function(choice)
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

-- Change the state of the work item under the cursor. Offers only the states
-- reachable from its current state, per the ADO workflow transitions, then a
-- reason for the chosen transition.
local function set_state()
  local it = current_item()
  if not it then return end
  local id, wtype, cur = tostring(it.id), it.type or "", it.state or ""
  if not meta_cached(WI_TRANS_CACHE, wtype, cur) then
    notify("Fetching states for #" .. id .. " \u{2026}")
  end
  fetch_transitions(wtype, cur, function(states)
    if #states == 0 then
      notify("No transitions for #" .. id .. ".", vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      PROMPT.select({ prompt = "Set #" .. id .. " (" .. cur .. " \u{2192})", items = states }, function(new)
        if not new then return end
        pick_reason(id, wtype, new, function(reason) apply_state(id, new, reason) end)
      end)
    end)
  end)
end

-- Run a --wi-edit "set" call for a work item, optimistically. Mirrors
-- azure-cli.lua's run_action: apply(it) mutates the record right away and
-- returns an undo function; on failure that undo runs and the error is
-- shown, on success on_success(stdout_lines) runs (e.g. to drop stale detail
-- caches / poke an open detail tab). apply/on_success are both optional.
local function run_edit(it, cmd_args, describe, apply, on_success)
  notify(describe .. " #" .. it.id .. " \u{2026}")
  local undo = apply and apply(it)
  if undo then render() end
  local out, err = {}, {}
  local job_args = provider_argv("--wi-edit")
  vim.list_extend(job_args, cmd_args)
  RPC.run(job_args, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify(describe .. " #" .. it.id .. ": done.")
        if on_success then on_success(out) end
      else
        if undo then
          undo()
          render()
        end
        -- Full stderr (often a python traceback) to the session log, one
        -- line here - the same treatment the reviewer's writes have always
        -- had, and what this used to flatten into a single toast instead.
        local msg = SHELL.job_error("work item #" .. tostring(it.id), code, err)
        notify(describe .. " #" .. it.id .. " failed: " .. msg
          .. (undo and " - change reverted." or ""), vim.log.levels.ERROR)
      end
    end,
  })
end

-- Poke any open detail tab for `id` to reload, and drop its stale cache entry,
-- after a field committed here from the dashboard.
local function nudge_detail(id)
  id = tostring(id)
  if WI_DETAIL_CACHE then WI_DETAIL_CACHE[id] = nil end
  local reload = STATE.WI_VIEW_RELOAD and STATE.WI_VIEW_RELOAD[id]
  if reload then vim.schedule(reload) end
end

-- Assign the item under the cursor. Prefilled with its current assignee;
-- submitting empty assigns it to me - azure-cli.py resolves that server-side
-- (WorkItemActions._wi_set_field), so the empty string is sent through as-is.
-- The team's members ({name, email}) for the assignee picker, fetched once
-- per session (--wi-list members) and kept in STATE; cb(list) with an
-- empty list when the call fails, so the picker degrades to typing.
local function fetch_members(cb)
  if STATE.WI_MEMBERS then
    cb(STATE.WI_MEMBERS)
    return
  end
  local out = {}
  RPC.run(provider_argv("--wi-list", "members"), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      local members = {}
      if code == 0 then
        for _, line in ipairs(out) do
          if line:gsub("%s", "") ~= "" then
            local ok, rec = pcall(vim.json.decode, line)
            if ok and type(rec) == "table" and rec.name then members[#members + 1] = rec end
          end
        end
        table.sort(members, function(a, b) return a.name:lower() < b.name:lower() end)
        STATE.WI_MEMBERS = members
      end
      vim.schedule(function() cb(members) end)
    end,
  })
end

-- Runs the assignee picker for `current` (a display name or "") and
-- calls cb(new_name) - "" meaning "me". Shared with the detail view
-- through STATE.WI_PICK_ASSIGNEE. Team members are listed when the call
-- works; "(me)" and "(type a name…)" are always there.
local function pick_assignee(current, cb)
  fetch_members(function(members)
    local items = { { label = "(me)", value = "" } }
    for _, m in ipairs(members) do items[#items + 1] = { label = m.name, value = m.name } end
    items[#items + 1] = { label = "(type a name\u{2026})", typed = true }
    PROMPT.select({ prompt = "Assign to", items = items,
      current = function(x) return x.value ~= nil and x.value ~= "" and x.value == current end }, function(choice)
      if not choice then return end
      if choice.typed then
        PROMPT.input({ prompt = "Assign to (empty = me):", default = current or "", allow_empty = true }, function(new)
          if new ~= nil then cb(new) end
        end)
        return
      end
      cb(choice.value)
    end)
  end)
end
STATE.WI_PICK_ASSIGNEE = pick_assignee

local function assign_item()
  local it = current_item()
  if not it then return end
  pick_assignee(it.assignedTo or "", function(new)
    run_edit(it, { "set", tostring(it.id), "assignedTo", new }, "Assigning", function(rec)
      local prev = rec.assignedTo
      rec.assignedTo = new
      return function() rec.assignedTo = prev end
    end, function() nudge_detail(it.id) end)
  end)
end

local PRIORITIES = { 1, 2, 3, 4 }

-- Set the priority of the item under the cursor (1-4).
local function set_priority()
  local it = current_item()
  if not it then return end
  PROMPT.select({ prompt = "Priority for #" .. it.id, items = PRIORITIES,
    format = function(p) return "P" .. p end,
    current = function(p) return tostring(p) == tostring(it.priority) end }, function(new)
    if not new then return end
    run_edit(it, { "set", tostring(it.id), "priority", tostring(new) }, "Setting priority on", function(rec)
      local prev = rec.priority
      rec.priority = new
      return function() rec.priority = prev end
    end, function() nudge_detail(it.id) end)
  end)
end

-- Edit the title of the item under the cursor, prefilled with the current one.
local function edit_title()
  local it = current_item()
  if not it then return end
  PROMPT.input({ prompt = "Title for #" .. it.id .. ":", default = it.title or "" }, function(new)
    if new == nil then return end
    if new == it.title then
      notify("Title unchanged.")
      return
    end
    run_edit(it, { "set", tostring(it.id), "title", new }, "Renaming", function(rec)
      local prev = rec.title
      rec.title = new
      return function() rec.title = prev end
    end, function() nudge_detail(it.id) end)
  end)
end

-- Move the item under the cursor to another sprint of the quarter, offered
-- from the same cached sprint list the tab bar uses. Optimistic: the item
-- leaves the current tab's in-memory list and cache immediately; the target
-- sprint's cache is dropped rather than guessed at, so it refetches fresh
-- (with correct ranking/state) the next time that tab is visited.
local function move_sprint_item()
  local it = current_item()
  if not it then return end
  if #sprints == 0 then
    notify("Sprint list not loaded yet.", vim.log.levels.WARN)
    return
  end
  local from_path = sprints[active_index].path
  local targets = {}
  for _, sp in ipairs(sprints) do
    if sp.path ~= from_path then targets[#targets + 1] = sp end
  end
  if #targets == 0 then
    notify("No other sprint to move to.", vim.log.levels.WARN)
    return
  end
  PROMPT.select({ prompt = "Move #" .. it.id .. " to sprint", items = targets,
    format = function(sp) return sp.label or sp.name or sp.path end }, function(target)
  if not target then return end
  run_edit(it, { "set", tostring(it.id), "iteration", target.path }, "Moving", function(rec)
    local at
    for i, x in ipairs(items) do
      if x == rec then at = i; break end
    end
    if at then table.remove(items, at) end
    local cache = WI_SPRINT_ITEMS[from_path]
    local cache_at
    if cache and cache.items then
      for i, x in ipairs(cache.items) do
        if x == rec then cache_at = i; break end
      end
      if cache_at then table.remove(cache.items, cache_at) end
    end
    WI_SPRINT_ITEMS[target.path] = nil  -- force a fresh fetch next time it's opened
    return function()
      if at then table.insert(items, math.min(at, #items + 1), rec) end
      if cache and cache.items and cache_at then
        table.insert(cache.items, math.min(cache_at, #cache.items + 1), rec)
      end
    end
  end, function() nudge_detail(it.id) end)
  end)
end

-- Link a pull request to the item under the cursor. Resolves the PR's
-- org/project/repo from the cached PR list (STATE.PR_LIST_CACHE.prs, populated
-- by this file's own background prefetch) when its id is there; otherwise
-- prompts for the repository name and falls back to this account's own
-- collection/project. Same flow as wi-view.lua's own gl.
-- Offers the cached PR list (the dashboard's own, prefetched in the
-- background) as a picker before falling back to typing an id, then
-- calls cb(pr_id_string). Shared with the detail view via STATE.
local function pick_pr(prompt, cb)
  local cache = STATE.PR_LIST_CACHE and STATE.PR_LIST_CACHE.prs or {}
  local items = {}
  for _, pr in ipairs(cache) do
    items[#items + 1] = { label = "!" .. tostring(pr.id) .. "  " .. (pr.title or "") .. "  (" .. (pr.repo or "") .. ")", id = tostring(pr.id) }
  end
  local function typed()
    PROMPT.input({ prompt = prompt .. " (PR id):" }, function(t)
      if t ~= nil then cb((t:gsub("^!", ""))) end
    end)
  end
  if #items == 0 then
    typed()
    return
  end
  items[#items + 1] = { label = "(type a PR id\u{2026})", typed = true }
  PROMPT.select({ prompt = prompt, items = items }, function(choice)
    if not choice then return end
    if choice.typed then typed() else cb(choice.id) end
  end)
end
STATE.WI_PICK_PR = pick_pr

local function link_pr_item()
  local it = current_item()
  if not it then return end
  local id = tostring(it.id)
  pick_pr("Link a pull request to #" .. id, function(pr_id)
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
  notify("Linking PR !" .. pr_id .. " to #" .. id .. " \u{2026}")
  local err = {}
  RPC.run(provider_argv("--wi-edit", "link-pr", id, org, project, repo, pr_id), {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("Linked PR !" .. pr_id .. " to #" .. id .. ".")
        nudge_detail(id)
      else
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
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

-- Unlink a pull request from the item under the cursor (gL) - the item's
-- links come from its detail record, prefetched on hover or fetched now.
local function unlink_pr_item()
  local it = current_item()
  if not it then return end
  local id = tostring(it.id)
  local function with_detail(cb)
    local c = WI_DETAIL_CACHE[id]
    if c and c.body then
      local ok, data = pcall(vim.json.decode, c.body)
      if ok and type(data) == "table" then cb(data) return end
    end
    notify("Loading #" .. id .. " \u{2026}")
    local out = {}
    RPC.run(provider_argv("--wi-detail", id), {
      stdout_buffered = true,
      on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
      on_exit = function(_, code)
        local ok, data = pcall(vim.json.decode, table.concat(out, "\n"))
        if code ~= 0 or not ok or type(data) ~= "table" then
          notify("Could not load #" .. id .. ".", vim.log.levels.ERROR)
          return
        end
        vim.schedule(function() cb(data) end)
      end,
    })
  end
  with_detail(function(data)
    local prs = (data.item or {}).pullRequests or {}
    if #prs == 0 then
      notify("No linked pull requests on #" .. id .. ".", vim.log.levels.WARN)
      return
    end
    PROMPT.select({ prompt = "Unlink PR from #" .. id, items = prs,
      format = function(p) return "!" .. tostring(p.id) .. ((p.title and p.title ~= "") and ("  " .. p.title) or "") end },
      function(p)
      if not p then return end
      local pr_id = tostring(p.id)
      notify("Unlinking PR !" .. pr_id .. " from #" .. id .. " \u{2026}")
      local err = {}
      RPC.run(provider_argv("--wi-edit", "unlink-pr", id, pr_id), {
        detach = true, stdout_buffered = true, stderr_buffered = true,
        on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
        on_exit = function(_, code)
          if code == 0 then
            notify("Unlinked PR !" .. pr_id .. " from #" .. id .. ".")
            nudge_detail(id)
          else
            local LOG = require("azure-cli.log")
            local raw = table.concat(err, "\n")
            LOG.record("work item #" .. id, raw)
            notify("Unlink PR !" .. pr_id .. " failed: " .. LOG.summary(raw, 60) .. "  (:AzureCli log)", vim.log.levels.ERROR)
          end
        end,
      })
    end)
  end)
end

-- `/`: narrow the list as you type (id, title, state, assignee, type).
local function set_wi_filter()
  local function apply(text)
    wi_filter = vim.trim(text or "")
    STATE.wi_filter = wi_filter
    render()
  end
  UI.filter_prompt({
    win = win, prompt = "Filter work items (id, title, state, assignee)", default = wi_filter,
    on_change = apply, on_submit = apply,
    on_cancel = function() apply("") end,
  })
end

-- The types `n` offers: the configured work_items.types (see sections()).
local function new_types() return wi_types or DEFAULT_TYPES end

-- Create a new work item in the active sprint. Prompts for type, then title,
-- then (only when the cursor is on an item) whether to parent it under that
-- item. There is no id to insert optimistically until the server answers, so
-- this just notifies and reloads the active sprint's list on success.
local function new_item()
  local under = current_item()
  local sp = sprints[active_index]
  if not sp then
    notify("Sprint not loaded yet.", vim.log.levels.WARN)
    return
  end
  local function create(wtype, title, parent_id)
  notify("Creating " .. wtype .. " \u{2026}")
  local out, err = {}, {}
  RPC.run(provider_argv("--wi-edit", "create", wtype, title, parent_id, sp.path), {
    detach = true,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        local line = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), "")
        local ok, rec = pcall(vim.json.decode, line)
        notify("Created #" .. tostring(ok and type(rec) == "table" and rec.id or "?") .. ".")
        if sprints[active_index] and sprints[active_index].path == sp.path then
          load(false, true)
        end
      else
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
        notify("Create failed: " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
  end
  PROMPT.select({ prompt = "New work item type", items = new_types() }, function(wtype)
    if not wtype then return end
    PROMPT.input({ prompt = "Title:" }, function(title)
      if not title then return end
      if not under then
        create(wtype, title, "")
        return
      end
      PROMPT.select({ prompt = "Parent", items = {
        { label = "none", id = "" },
        { label = "child of #" .. under.id .. " " .. (under.title or ""), id = tostring(under.id) },
      } }, function(p)
        if not p then return end
        create(wtype, title, p.id)
      end)
    end)
  end)
end

-- Pre-warm the state/reason caches in the background so 'gs' is instant: for
-- each distinct (type, currentState) in the list, fetch its transitions, then
-- fetch the reasons for each reachable target state. All coalesced/cached.
prefetch_state_meta = function()
  local seen = {}
  for _, it in ipairs(items) do
    local wtype, state = it.type or "", it.state or ""
    if wtype ~= "" and state ~= "" then
      local k = wtype .. "\0" .. state
      if not seen[k] then
        seen[k] = true
        fetch_transitions(wtype, state, function(targets)
          for _, t in ipairs(targets or {}) do fetch_reasons(wtype, t) end
        end)
      end
    end
  end
end

-- Warm the adjacent sprints' item lists in the background so jumping to them
-- with [ / ] is instant. Skips sprints already cached fresh.
prefetch_neighbors = function()
  for _, i in ipairs({ active_index - 1, active_index + 1 }) do
    local sp = sprints[i]
    if sp then
      local c = WI_SPRINT_ITEMS[sp.path]
      if not (c and (os.time() - c.ts) < LIST_TTL) then
        local out = {}
        RPC.run(provider_argv("--wi-list", "items", sp.path), {
          stdout_buffered = true,
          on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
          on_exit = function(_, code)
            if code == 0 then
              WI_SPRINT_ITEMS[sp.path] = { items = parse_items(out), ts = os.time() }
            end
          end,
        })
      end
    end
  end
end

-- Swap to the pull-request dashboard in this same window.
local function open_pr_list()
  require("azure-cli.dashboard").open()
end

-- Copy the web link of the work item under the cursor to the system clipboard.
-- Both of these announce themselves through notify.lua's flash now, like
-- every other key on this dashboard - they were the last two call sites
-- still going straight to vim.notify, which bypasses the toast styling.
local function yank_link()
  local it = current_item()
  if not it or not SHELL.yank_url(it.url) then return end
  notify("Copied link to #" .. tostring(it.id) .. ": " .. it.url)
end

-- Open the work item under the cursor in the default web browser.
local function open_browser()
  local it = current_item()
  if not it then return end
  local ok, why = SHELL.open_url(it.url)
  if not ok then
    notify("Can't open #" .. tostring(it.id) .. ": " .. why, vim.log.levels.WARN)
    return
  end
  notify("Opening #" .. tostring(it.id) .. " in browser…")
end

-- Show this dashboard's keys in a float.
-- Ordered { action, desc } pairs for the `?` popup - real key(s) resolved
-- through KEYS every time (see keys.lua's M.line), never hard-coded.
local WORKITEMS_HELP = {
  "Navigate",
  { "open", "open the item: parent, children, description" },
  { "filter", "filter by id, title, state or assignee (Esc clears)" },
  { "prev_sprint", "previous sprint" },
  { "next_sprint", "next sprint" },
  { "goto_sprint_n", "jump to sprint n (prefix with a count)" },
  { "click", "click a tab in the tab bar to jump straight to that sprint" },
  "This item",
  { "state", "change the item's state, with the allowed transitions and reasons" },
  { "assign", "assign the item under the cursor" },
  { "priority", "set the item's priority" },
  { "edit_title", "edit the item's title" },
  { "move_sprint", "move the item to another sprint of the quarter" },
  { "link_pr", "link a pull request to the item under the cursor" },
  { "unlink_pr", "unlink a pull request from the item under the cursor" },
  { "copy_link", "copy the item's link" },
  { "browser", "open in the browser" },
  "Session",
  { "new", "new work item: type, title, and parent (if the cursor is on one)" },
  { "refresh", "refresh" },
  { "pr_list", "switch to the pull-request dashboard" },
  { "config", "open the config file" },
  { "quit", "quit" },
  { "help", "this help" },
}
local function show_help()
  local now = {}
  if wi_filter ~= "" then now[#now + 1] = "[filter: " .. wi_filter .. "]" end
  UI.open_float(KEYS.help_lines("workitems", "Work-items dashboard keys", WORKITEMS_HELP,
    { now = now, fixed = { "  j / k       move" } }))
end

buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = "azurecli-workitems"
vim.api.nvim_set_current_buf(buf)
win = vim.api.nvim_get_current_win()
UI.plain_window(win, { cursorline = true })
set_wi_winbar()

KEYS.bind(buf, "workitems", "open", open_item, { desc = "open the item: parent, children, description" })
KEYS.bind(buf, "workitems", "state", set_state, { desc = "change the item's state" })
KEYS.bind(buf, "workitems", "new", new_item, { desc = "new work item" })
KEYS.bind(buf, "workitems", "assign", assign_item, { desc = "assign the item under the cursor" })
KEYS.bind(buf, "workitems", "priority", set_priority, { desc = "set the item's priority" })
KEYS.bind(buf, "workitems", "edit_title", edit_title, { desc = "edit the item's title" })
KEYS.bind(buf, "workitems", "move_sprint", move_sprint_item, { desc = "move the item to another sprint" })
KEYS.bind(buf, "workitems", "link_pr", link_pr_item, { desc = "link a pull request to the item under the cursor" })
KEYS.bind(buf, "workitems", "unlink_pr", unlink_pr_item, { desc = "unlink a pull request from the item under the cursor" })
KEYS.bind(buf, "workitems", "filter", set_wi_filter, { desc = "filter by id, title, state or assignee" })
KEYS.bind(buf, "workitems", "browser", open_browser, { desc = "open in the browser" })
KEYS.bind(buf, "workitems", "refresh", function() load(false, true) end, { desc = "refresh" })
-- next_sprint/prev_sprint default to a two-key list ("]"/"<Tab>" and
-- "["/"<S-Tab>") - KEYS.bind binds every key in that list to the same fn.
KEYS.bind(buf, "workitems", "next_sprint", function() goto_sprint(1) end, { desc = "next sprint" })
KEYS.bind(buf, "workitems", "prev_sprint", function() goto_sprint(-1) end, { desc = "previous sprint" })
KEYS.bind(buf, "workitems", "goto_sprint_n", goto_sprint_count, { desc = "jump to sprint n" })
KEYS.bind(buf, "workitems", "click", on_click, { desc = "click a tab in the tab bar to jump to that sprint" })
KEYS.bind(buf, "workitems", "pr_list", open_pr_list, { desc = "switch to the pull-request dashboard" })
KEYS.bind(buf, "workitems", "copy_link", yank_link, { desc = "copy the item's link" })
KEYS.bind(buf, "workitems", "config", open_config_file, { desc = "open the config file" })
KEYS.bind(buf, "workitems", "help", show_help, { desc = "this help" })
-- Same standalone-vs-plugin-tab distinction as the PR dashboard's own quit
-- key (dashboard.lua) - this dashboard is reached from it by a same-tab
-- swap ("W"), not a new tab, so quitting from here means the same thing.
KEYS.bind(buf, "workitems", "quit", function()
  if STATE.WI_REFRESH_TIMER then pcall(vim.fn.timer_stop, STATE.WI_REFRESH_TIMER); STATE.WI_REFRESH_TIMER = nil end
  if require("azure-cli").is_standalone() then
    vim.cmd("qa!")
    return
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  else
    pcall(vim.cmd, "enew")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end, { desc = "quit" })

-- Prefetch the item under the cursor once movement settles (debounced), so the
-- detail tab opens from cache instantly.
local prefetch_timer
vim.api.nvim_create_autocmd("CursorMoved", {
  buffer = buf,
  callback = function()
    if prefetch_timer then vim.fn.timer_stop(prefetch_timer) end
    prefetch_timer = vim.fn.timer_start(CONFIG.get().timing.hover_ms, function()
      local it = current_item()
      if it then prefetch(it.id) end
    end)
  end,
})

-- Re-centre the table when the terminal is resized. Uses a named augroup
-- (cleared each time this file is sourced) so W/P swaps don't stack duplicate
-- autocmds across re-luafile's of this script.
vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("AzureCliWiResize", { clear = true }),
  callback = function()
    if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
      render()
    end
  end,
})

-- Let wi-view.lua trigger a change-aware refresh when a detail tab is closed;
-- load(true) only redraws if the list actually changed (no flicker otherwise).
STATE.WI_REFRESH = function()
  if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
    load_sprints(function() load(true) end, false)
  end
end

-- Periodic auto-refresh (silent + change-aware). Stop any timer from a previous
-- swap into this dashboard so timers don't stack across W/P swaps - see
-- config.lua's timing.poll_seconds for the interval (the same knob the PR
-- dashboard/reviewer polls use).
if STATE.WI_REFRESH_TIMER then pcall(vim.fn.timer_stop, STATE.WI_REFRESH_TIMER) end
STATE.WI_REFRESH_TIMER = vim.fn.timer_start(CONFIG.get().timing.poll_seconds * 1000, function()
  if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
    load_sprints(function() load(true) end, false)
  end
end, { ["repeat"] = -1 })

-- Warm the PR list in the background at startup so the first swap to the PR
-- dashboard (P) is instant. No-op when already cached.
local function prefetch_prs()
  if STATE.PR_LIST_CACHE and STATE.PR_LIST_CACHE.prs then return end
  local out = {}
  -- Same data PR_EXE --list would print, run through the provider argv
  -- directly so it's routed through the daemon like every other provider call.
  RPC.run(provider_argv("--list"), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then return end
      local prs = {}
      for _, line in ipairs(out) do
        if line:gsub("%s", "") ~= "" then
          local ok, rec = pcall(vim.json.decode, line)
          if ok and type(rec) == "table" then prs[#prs + 1] = rec end
        end
      end
      STATE.PR_LIST_CACHE = { prs = prs, ts = os.time() }
    end,
  })
end

load_sprints(function()
  load(false)
  if prefetch_neighbors then prefetch_neighbors() end
end, true)
prefetch_prs()

end  -- M.open()

return M
