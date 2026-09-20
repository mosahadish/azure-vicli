-- wi-dash: Neovim work-items dashboard.
--
-- Sibling of azure-cli.lua. Renders the user stories and bugs assigned to me in
-- the current sprint by shelling out to the headless provider wi-list.sh
-- (NDJSON), and opens a read-only detail view (wi-view.lua) on <CR>. Press W in
-- the PR dashboard to come here, and P here to go back to the PR dashboard.
--
-- Keys
--   j/k    move
--   <CR>   open the work item under the cursor (parent/children/description)
--   gs     change the state of the work item under the cursor
--   [ ]    jump to the previous / next sprint in the quarter (also <S-Tab>/<Tab>)
--   {n}gt  jump to sprint n (1-based, like vim's tab gt); gt with no count = next
--   click  click a tab in the tab bar to jump straight to that sprint
--   r      refresh
--   P      switch to the pull-request dashboard
--   q      quit
--   ?      show this help

vim.o.compatible = false
vim.o.number = false
vim.o.signcolumn = "no"
vim.o.hidden = true
vim.o.termguicolors = true
vim.o.laststatus = 2
vim.o.mouse = "a"

local function script_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(path, ":p:h")
end

local DIR    = script_dir()
local env    = vim.env
local LIST   = env.WIDASH_LIST or (DIR .. "/wi-list.sh")
local DETAIL = env.WIDASH_DETAIL or (DIR .. "/wi-detail.sh")
local STATE  = env.WIDASH_STATE or (DIR .. "/wi-state.sh")
local BASH   = env.PRDASH_BASH or "bash"
local WI_VIEW_LUA = (DIR .. "/wi-view.lua"):gsub("\\", "/")
local PR_DASH_LUA = (DIR .. "/azure-cli.lua"):gsub("\\", "/")
-- PR list provider (headless exe), warmed in the background so the first P swap is instant.
local PR_EXE = env.PRDASH_EXE or (DIR .. "/src/bin/Debug/net6.0/azure-cli.exe")

-- Detail cache shared with wi-view.lua (same nvim session): id -> {body, ts}.
-- Prefetching the item under the cursor lets the detail tab open instantly.
_G.WI_DETAIL_CACHE = _G.WI_DETAIL_CACHE or {}
local CACHE_TTL = 30  -- seconds a prefetched detail is considered fresh

-- Workflow metadata caches shared with wi-view.lua (same nvim session):
--   WI_TRANS_CACHE[type\0state]  -> { list = {targetStates}, ts }
--   WI_REASON_CACHE[type\0state] -> { list = {reasons}, ts }
-- These change rarely, so a long TTL is fine; pre-warming them makes the state
-- and reason pickers ('gs') appear instantly.
_G.WI_TRANS_CACHE = _G.WI_TRANS_CACHE or {}
_G.WI_REASON_CACHE = _G.WI_REASON_CACHE or {}
local META_TTL = 600

-- Per-sprint work-item cache keyed by iteration path, plus the quarter's sprint
-- list, both shared across dashboard swaps so re-entry and tab jumps are instant.
_G.WI_SPRINT_ITEMS = _G.WI_SPRINT_ITEMS or {}   -- path -> { items, ts }
-- _G.WI_SPRINTS_CACHE = { list, quarter, currentIndex, ts }
local LIST_TTL = 30
local SPRINTS_TTL = 300

-- Sections: one per work item type, in this order. Types not listed here fall
-- into a trailing "Other" bucket.
local SECTIONS = {
  { key = "User Story", title = "User Stories" },
  { key = "Bug",        title = "Bugs" },
}

-- Rank so the most actionable states sort to the top within a section:
-- Active, New, Implemented, Resolved, Closed.
local STATE_RANK = { Active = 1, ["In Progress"] = 1, New = 2, Implemented = 3,
                     Resolved = 4, Closed = 5, Removed = 6 }

-- Colours (termguicolors is on). Defined idempotently so the swap re-luafile is
-- harmless. State groups are reused by wi-view.lua's own setup.
local function define_hl()
  local hl = vim.api.nvim_set_hl
  hl(0, "WidashHeader",      { fg = "#89b4fa", bold = true })
  hl(0, "WidashId",          { fg = "#cba6f7" })
  hl(0, "WidashActive",      { fg = "#a6e3a1", bold = true })
  hl(0, "WidashNew",         { fg = "#89dceb" })
  hl(0, "WidashImplemented", { fg = "#f9e2af" })
  hl(0, "WidashResolved",    { fg = "#94e2d5" })
  hl(0, "WidashClosed",      { fg = "#6c7086" })
  hl(0, "WidashRemoved",     { fg = "#f38ba8" })
  hl(0, "WidashOther",       { fg = "#bac2de" })
  hl(0, "WidashDivider",     { fg = "#45475a" })
  hl(0, "WidashTabActive",   { fg = "#1e1e2e", bg = "#89b4fa", bold = true })
  hl(0, "WidashTabInactive", { fg = "#6c7086" })
  hl(0, "WidashDate",        { fg = "#7f849c", italic = true })
  hl(0, "WidashBorder",      { fg = "#585b70" })
end
define_hl()

-- Map a work item state to its highlight group.
local STATE_HL = {
  Active = "WidashActive", ["In Progress"] = "WidashActive",
  New = "WidashNew", Implemented = "WidashImplemented",
  Resolved = "WidashResolved", Closed = "WidashClosed",
  Removed = "WidashRemoved",
}

local ns = vim.api.nvim_create_namespace("widash")

local items = {}     -- all parsed work item records
local row_item = {}  -- buffer line (1-based) -> record (nil on header/blank)
local buf, win
local sprints = {}            -- quarter's sprints: {name,label,path,start,finish,timeframe,current}
local active_index = 1        -- 1-based index into sprints (the focused tab)
local quarter = ""            -- quarter node label, e.g. "BarLev-RnD\\2026\\Q3"
local prefetch_state_meta     -- forward decl: warms state/reason caches
local prefetch_neighbors      -- forward decl: warms adjacent sprints' items
local loading = false         -- true while a fetch for the active tab is in flight
local tabbar_hl = {}          -- byte ranges of the two tab segments, for highlighting
local date_row = nil          -- 1-based line of the sprint date line, for highlighting
local tab_row = 1             -- 1-based line of the tab bar itself, for click hit-testing
local content_col = 0         -- byte column where a normal row's real content starts (inside the box)

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

-- Resolve azure-cli.yml's path (matches Config.ConfigPath in the C# source):
-- %APPDATA%\azure-cli.yml on Windows, $XDG_CONFIG_HOME/azure-cli.yml (default
-- ~/.config) elsewhere - the same place .NET's ApplicationData resolves to.
local function config_path()
  if vim.fn.has("win32") == 1 then
    return (vim.env.APPDATA or vim.fn.expand("$APPDATA")) .. "\\azure-cli.yml"
  end
  local xdg = vim.env.XDG_CONFIG_HOME
  if not xdg or xdg == "" then xdg = vim.fn.expand("~/.config") end
  return xdg .. "/azure-cli.yml"
end

-- Open azure-cli.yml (accounts/PAT/clones_dir config) in a new tab for quick editing.
local function open_config_file()
  local path = config_path()
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "yaml"
  if vim.fn.filereadable(path) == 0 then
    notify("azure-cli.yml doesn't exist yet — save this buffer (:w) to create it at " .. path, vim.log.levels.WARN)
  end
end

local function fit(s, n)
  s = s or ""
  if vim.fn.strdisplaywidth(s) <= n then
    return s .. string.rep(" ", n - vim.fn.strdisplaywidth(s))
  end
  return s:sub(1, n - 1) .. "…"
end

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

  local by_type = {}
  local order = {}
  for _, sec in ipairs(SECTIONS) do
    by_type[sec.key] = {}
    order[#order + 1] = sec
  end
  local other = {}
  for _, it in ipairs(items) do
    if by_type[it.type] then
      table.insert(by_type[it.type], it)
    else
      table.insert(other, it)
    end
  end
  if #other > 0 then
    by_type["__other__"] = other
    order[#order + 1] = { key = "__other__", title = "Other" }
  end

  local function sort_items(list)
    table.sort(list, function(a, b)
      local ra = STATE_RANK[a.state] or 9
      local rb = STATE_RANK[b.state] or 9
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
    else
      lines[#lines + 1] = "No work items assigned to you in "
        .. ((sprints[active_index] and sprints[active_index].label) or "this sprint") .. "."
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
          seg.active and "WidashTabActive" or "WidashTabInactive", lnum, seg.s, seg.e)
      end
    elseif i == top_line_1based or i == bottom_line_1based then
      vim.api.nvim_buf_add_highlight(buf, ns, "WidashBorder", lnum, 0, -1)
    elseif i == date_row then
      vim.api.nvim_buf_add_highlight(buf, ns, "WidashDate", lnum, 0, -1)
    elseif line:match("──") then
      vim.api.nvim_buf_add_highlight(buf, ns, "WidashHeader", lnum, 0, -1)
    elseif line:match("┄") then
      vim.api.nvim_buf_add_highlight(buf, ns, "WidashDivider", lnum, 0, -1)
    else
      local s, e = line:find("#%d+")
      if s then vim.api.nvim_buf_add_highlight(buf, ns, "WidashId", lnum, s - 1, e) end
      local bs, be, state = line:find("%[(.-)%]")
      if bs then
        vim.api.nvim_buf_add_highlight(buf, ns, STATE_HL[state] or "WidashOther", lnum, bs - 1, be)
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
  local c = _G.WI_DETAIL_CACHE[id]
  if c and (os.time() - c.ts) < CACHE_TTL then return end
  if prefetching[id] then return end
  prefetching[id] = true
  local out = {}
  vim.fn.jobstart({ BASH, DETAIL, id }, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      prefetching[id] = nil
      if code == 0 then
        _G.WI_DETAIL_CACHE[id] = { body = table.concat(out, "\n"), ts = os.time() }
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
  local cache = _G.WI_SPRINT_ITEMS[path]
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
  vim.fn.jobstart({ BASH, LIST, "items", path }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      -- Guard against the user having jumped to another sprint mid-fetch.
      local still = sprints[active_index] and sprints[active_index].path == path
      if code ~= 0 then
        if still then
          loading = false
          local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false,
            { build_tabbar(), "", "Failed to load work items (exit " .. code .. "):", msg })
          vim.bo[buf].modifiable = false
        end
        return
      end
      local fresh = parse_items(out)
      _G.WI_SPRINT_ITEMS[path] = { items = fresh, ts = os.time() }
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

  local c = _G.WI_SPRINTS_CACHE
  if c and c.list and (os.time() - c.ts) < SPRINTS_TTL then
    sprints = c.list
    quarter = c.quarter or ""
    finalize(tonumber(c.currentIndex) or 0)
    return
  end
  local out = {}
  vim.fn.jobstart({ BASH, LIST, "sprints" }, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      local ci = 0
      if code == 0 then
        for _, line in ipairs(out) do
          if line:gsub("%s", "") ~= "" then
            local ok, d = pcall(vim.json.decode, line)
            if ok and type(d) == "table" and d._sprints then
              ci = apply_sprints(d)
              _G.WI_SPRINTS_CACHE = { list = sprints, quarter = quarter,
                                      currentIndex = ci, ts = os.time() }
              break
            end
          end
        end
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
  vim.env.WIDASH_ID = tostring(it.id)
  vim.cmd("tabnew")
  vim.cmd("luafile " .. vim.fn.fnameescape(WI_VIEW_LUA))
end

-- Reflect a committed state change immediately: patch the in-memory list and
-- caches, drop any stale detail cache, and re-render. Exposed globally so a
-- change made from the detail view (wi-view.lua) updates the dashboard too.
function _G.WI_STATE_CHANGED(id, new)
  id = tostring(id)
  local function patch(list)
    if not list then return end
    for _, it in ipairs(list) do
      if tostring(it.id) == id then it.state = new end
    end
  end
  patch(items)
  for _, c in pairs(_G.WI_SPRINT_ITEMS or {}) do patch(c.items) end
  if _G.WI_DETAIL_CACHE then _G.WI_DETAIL_CACHE[id] = nil end
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
  vim.fn.jobstart({ BASH, STATE, subcmd, wtype, state }, {
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
  fetch_meta(_G.WI_TRANS_CACHE, "transitions", wtype, cur, cb)
end

local function fetch_reasons(wtype, new, cb)
  fetch_meta(_G.WI_REASON_CACHE, "reasons", wtype, new, cb)
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
  local cmd = { BASH, STATE, "set", id, new }
  if reason and reason ~= "" then cmd[#cmd + 1] = reason end
  local err = {}
  vim.fn.jobstart(cmd, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("#" .. id .. " is now " .. new .. suffix .. ".")
        _G.WI_STATE_CHANGED(id, new)
        local reload = _G.WI_VIEW_RELOAD and _G.WI_VIEW_RELOAD[tostring(id)]
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
  if not meta_cached(_G.WI_REASON_CACHE, wtype, new) then
    notify("Fetching reasons \u{2026}")
  end
  fetch_reasons(wtype, new, function(reasons)
    vim.schedule(function()
      local choices = { "Reason for #" .. id .. " \u{2192} " .. new .. ":" }
      for i, r in ipairs(reasons) do choices[#choices + 1] = i .. ": " .. r end
      local default_i = #reasons + 1
      local other_i = #reasons + 2
      choices[#choices + 1] = default_i .. ": (default reason)"
      choices[#choices + 1] = other_i .. ": (other\u{2026} type a reason)"
      local idx = tonumber(vim.fn.inputlist(choices))
      if not idx or idx < 1 then
        notify("Cancelled.")
        return
      end
      if idx <= #reasons then
        cb(reasons[idx])
      elseif idx == default_i then
        cb("")
      elseif idx == other_i then
        local r = vim.fn.input("Reason: ")
        cb(r or "")
      else
        notify("Cancelled.")
      end
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
  if not meta_cached(_G.WI_TRANS_CACHE, wtype, cur) then
    notify("Fetching states for #" .. id .. " \u{2026}")
  end
  fetch_transitions(wtype, cur, function(states)
    if #states == 0 then
      notify("No transitions for #" .. id .. ".", vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      local choices = { "Set #" .. id .. " (" .. cur .. " \u{2192}):" }
      for i, s in ipairs(states) do choices[#choices + 1] = i .. ": " .. s end
      local idx = tonumber(vim.fn.inputlist(choices))
      if not idx or idx < 1 or idx > #states then
        notify("Cancelled.")
        return
      end
      local new = states[idx]
      pick_reason(id, wtype, new, function(reason) apply_state(id, new, reason) end)
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
      local c = _G.WI_SPRINT_ITEMS[sp.path]
      if not (c and (os.time() - c.ts) < LIST_TTL) then
        local out = {}
        vim.fn.jobstart({ BASH, LIST, "items", sp.path }, {
          stdout_buffered = true,
          on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
          on_exit = function(_, code)
            if code == 0 then
              _G.WI_SPRINT_ITEMS[sp.path] = { items = parse_items(out), ts = os.time() }
            end
          end,
        })
      end
    end
  end
end

-- Swap to the pull-request dashboard in this same window.
local function open_pr_dash()
  vim.cmd("luafile " .. vim.fn.fnameescape(PR_DASH_LUA))
end

-- Copy the web link of the work item under the cursor to the system clipboard.
local function yank_link()
  local it = current_item()
  if not it or not it.url or it.url == "" then return end
  vim.fn.setreg('"', it.url)
  pcall(vim.fn.setreg, "+", it.url)
  vim.notify("Copied link to #" .. tostring(it.id) .. ": " .. it.url)
end

-- Open the work item under the cursor in the default web browser.
local function open_browser()
  local it = current_item()
  if not it or not it.url or it.url == "" then return end
  local ok = pcall(vim.ui.open, it.url)
  if not ok then
    vim.fn.jobstart({ "cmd", "/c", "start", "", it.url }, { detach = true })
  end
  vim.notify("Opening #" .. tostring(it.id) .. " in browser…")
end

-- Open a scratch floating window at the cursor showing the given text lines
-- (same small helper as azure-cli.lua's open_float; kept local since the two
-- dashboards don't share a require'd module).
local function open_float(lines)
  if #lines == 0 then return end
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, 100)
  local height = math.min(#lines, 24)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].buftype = "nofile"
  vim.api.nvim_open_win(fbuf, true, {
    relative = "cursor", row = 1, col = 0,
    width = width, height = height,
    style = "minimal", border = "rounded",
  })
  local fopts = { buffer = fbuf, silent = true, nowait = true }
  vim.keymap.set("n", "q", "<Cmd>close<CR>", fopts)
  vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", fopts)
end

-- Show this dashboard's keys in a float.
local function show_help()
  open_float({
    "Work-items dashboard keys",
    "",
    "  j / k        move",
    "  <CR>         open the item: parent, children, description",
    "  gs           change the item's state, with the allowed transitions and reasons",
    "  [ / ]        previous / next sprint (also <S-Tab> / <Tab>)",
    "  {n}gt        jump to sprint n",
    "  click        click a tab in the tab bar to jump straight to that sprint",
    "  gy           copy the item's link",
    "  o            open in the browser",
    "  gO           open the config file",
    "  r            refresh",
    "  P            switch to the pull-request dashboard",
    "  q            quit",
    "  ?            this help",
  })
end

buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = "widash"
vim.api.nvim_set_current_buf(buf)
win = vim.api.nvim_get_current_win()
pcall(function()
  vim.wo[win].winbar = "work items   (<CR>: open  gs: set state  o: browser  gy: copy link  [ ]/{n}gt/click: sprint nav  gO: config  r: refresh  P: PR dashboard  q: quit  ?: help)"
end)

local opts = { buffer = buf, silent = true, nowait = true }
vim.keymap.set("n", "<CR>", open_item, opts)
vim.keymap.set("n", "gs", set_state, opts)
vim.keymap.set("n", "o", open_browser, opts)
vim.keymap.set("n", "r", function() load(false, true) end, opts)
vim.keymap.set("n", "]", function() goto_sprint(1) end, opts)
vim.keymap.set("n", "[", function() goto_sprint(-1) end, opts)
vim.keymap.set("n", "<Tab>", function() goto_sprint(1) end, opts)
vim.keymap.set("n", "<S-Tab>", function() goto_sprint(-1) end, opts)
vim.keymap.set("n", "gt", goto_sprint_count, opts)
vim.keymap.set("n", "<LeftMouse>", on_click, opts)
vim.keymap.set("n", "P", open_pr_dash, opts)
vim.keymap.set("n", "gy", yank_link, opts)
vim.keymap.set("n", "gO", open_config_file, opts)
vim.keymap.set("n", "?", show_help, opts)
vim.keymap.set("n", "q", "<Cmd>qa!<CR>", opts)

-- Prefetch the item under the cursor once movement settles (debounced), so the
-- detail tab opens from cache instantly.
local prefetch_timer
vim.api.nvim_create_autocmd("CursorMoved", {
  buffer = buf,
  callback = function()
    if prefetch_timer then vim.fn.timer_stop(prefetch_timer) end
    prefetch_timer = vim.fn.timer_start(400, function()
      local it = current_item()
      if it then prefetch(it.id) end
    end)
  end,
})

-- Re-centre the table when the terminal is resized. Uses a named augroup
-- (cleared each time this file is sourced) so W/P swaps don't stack duplicate
-- autocmds across re-luafile's of this script.
vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("WiDashResize", { clear = true }),
  callback = function()
    if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
      render()
    end
  end,
})

-- Let wi-view.lua trigger a change-aware refresh when a detail tab is closed;
-- load(true) only redraws if the list actually changed (no flicker otherwise).
_G.WI_DASH_REFRESH = function()
  if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
    load_sprints(function() load(true) end, false)
  end
end

-- Periodic auto-refresh (silent + change-aware). Stop any timer from a previous
-- swap into this dashboard so timers don't stack across W/P swaps.
if _G.WI_DASH_TIMER then pcall(vim.fn.timer_stop, _G.WI_DASH_TIMER) end
_G.WI_DASH_TIMER = vim.fn.timer_start(60000, function()
  if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
    load_sprints(function() load(true) end, false)
  end
end, { ["repeat"] = -1 })

-- Warm the PR list in the background at startup so the first swap to the PR
-- dashboard (P) is instant. No-op when already cached.
local function prefetch_prs()
  if _G.PR_LIST_CACHE and _G.PR_LIST_CACHE.prs then return end
  local out = {}
  vim.fn.jobstart({ PR_EXE, "--list" }, {
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
      _G.PR_LIST_CACHE = { prs = prs, ts = os.time() }
    end,
  })
end

load_sprints(function()
  load(false)
  if prefetch_neighbors then prefetch_neighbors() end
end, true)
prefetch_prs()
