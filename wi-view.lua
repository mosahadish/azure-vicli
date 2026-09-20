-- wi-view: read-only work-item detail view (opened from wi-dash.lua).
--
-- Reads WIDASH_ID from the environment, fetches the item + its parent and
-- children + flattened description via wi-detail.sh, and renders them into a
-- scratch buffer. Parent/child lines are navigable with <CR>.
--
-- Keys
--   <CR>   on a parent/child line: open that work item here
--   gs     change the state of this work item
--   o      open this work item in the browser
--   r      refresh
--   <BS>/q close and return to the dashboard
--   ?      show this help

local function script_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(path, ":p:h")
end

local DIR    = script_dir()
local env    = vim.env
local DETAIL = env.WIDASH_DETAIL or (DIR .. "/wi-detail.sh")
local STATE  = env.WIDASH_STATE or (DIR .. "/wi-state.sh")
local BASH   = env.PRDASH_BASH or "bash"
local ID     = env.WIDASH_ID or ""

local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = "wiview"

-- Colours (termguicolors is on); idempotent so re-opening a tab is harmless.
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
  hl(0, "WiviewTitle",       { bold = true })
  hl(0, "WiviewLabel",       { fg = "#fab387" })
end
define_hl()

local STATE_HL = {
  Active = "WidashActive", ["In Progress"] = "WidashActive",
  New = "WidashNew", Implemented = "WidashImplemented",
  Resolved = "WidashResolved", Closed = "WidashClosed",
  Removed = "WidashRemoved",
}
local KNOWN_LABEL = {
  Parent = true, Children = true, Assigned = true, Priority = true,
  Created = true, Changed = true, Reason = true, Area = true,
  Iteration = true, Tags = true, URL = true,
}
local ns = vim.api.nvim_create_namespace("wiview")

local row_link = {}  -- buffer line (1-based) -> work item id (parent/child rows)

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

local function set_lines(lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function add_block(lines, title, text)
  if not text or text == "" then return end
  lines[#lines + 1] = ""
  lines[#lines + 1] = title
  lines[#lines + 1] = string.rep("─", #title)
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = l
  end
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

  add_block(lines, "Description", it.description)
  add_block(lines, "Acceptance Criteria", it.acceptanceCriteria)
  add_block(lines, "Repro Steps", it.reproSteps)

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
      add("WidashHeader", lnum, 0, -1)
    else
      if lines[i + 1] and is_rule(lines[i + 1]) then
        add("WidashHeader", lnum, 0, -1)
      end
      if i == 2 then add("WiviewTitle", lnum, 0, -1) end
      local w = line:match("^(%a+)")
      if w and KNOWN_LABEL[w] then
        local le = select(2, line:find("^[%a][%w %(%)]-:"))
        if le then add("WiviewLabel", lnum, 0, le) end
      end
      local s, e = line:find("#%d+")
      if s then add("WidashId", lnum, s - 1, e) end
      local bs, be, state = line:find("%[(.-)%]")
      if bs and STATE_HL[state] then add(STATE_HL[state], lnum, bs - 1, be) end
    end
  end

  pcall(function()
    vim.wo[0].winbar = "work item #" .. tostring(it.id or "?")
      .. "   (<CR>: open linked  gs: set state  o: browser  gy: copy link  r: refresh  <BS>/q: back  ?: help)"
  end)
end

local current_url = ""
local current_item = {}

-- Detail cache shared with wi-dash.lua's prefetch (same nvim session).
_G.WI_DETAIL_CACHE = _G.WI_DETAIL_CACHE or {}
-- Registry so the dashboard can trigger a live reload of an open detail tab
-- (keyed by work item id) after it commits a state change.
_G.WI_VIEW_RELOAD = _G.WI_VIEW_RELOAD or {}
-- Workflow metadata caches shared with wi-dash.lua (keyed by "type\0state"),
-- so the state/reason pickers are instant when the dashboard already warmed them.
_G.WI_TRANS_CACHE = _G.WI_TRANS_CACHE or {}
_G.WI_REASON_CACHE = _G.WI_REASON_CACHE or {}
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
  if prev_reg_id and prev_reg_id ~= ID then _G.WI_VIEW_RELOAD[prev_reg_id] = nil end
  prev_reg_id = ID
  _G.WI_VIEW_RELOAD[ID] = function()
    if vim.api.nvim_buf_is_valid(buf) then load(ID, true) end
  end
  if not force then
    local c = _G.WI_DETAIL_CACHE[ID]
    if c and (os.time() - c.ts) < CACHE_TTL and apply(c.body) then
      return
    end
  end
  set_lines({ "Loading work item #" .. ID .. " …" })
  local out, err = {}, {}
  vim.fn.jobstart({ BASH, DETAIL, ID }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
        set_lines({ "Failed to load work item #" .. ID .. " (exit " .. code .. "):", msg })
        return
      end
      local body = table.concat(out, "\n")
      _G.WI_DETAIL_CACHE[ID] = { body = body, ts = os.time() }
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
  local cmd = { BASH, STATE, "set", ID, new }
  if reason and reason ~= "" then cmd[#cmd + 1] = reason end
  local err = {}
  vim.fn.jobstart(cmd, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("#" .. ID .. " is now " .. new .. suffix .. ".")
        _G.WI_DETAIL_CACHE[ID] = nil
        load(ID, true)
        if _G.WI_STATE_CHANGED then _G.WI_STATE_CHANGED(ID, new) end
      else
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
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
  if not meta_cached(_G.WI_REASON_CACHE, wtype, new) then
    notify("Fetching reasons \u{2026}")
  end
  fetch_reasons(wtype, new, function(reasons)
    vim.schedule(function()
      local choices = { "Reason for #" .. ID .. " \u{2192} " .. new .. ":" }
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

-- Change the state of this work item, offering only states reachable from its
-- current state (per the ADO workflow transitions), then a reason.
local function set_state()
  if ID == "" then return end
  local wtype, cur = current_item.type or "", current_item.state or ""
  if not meta_cached(_G.WI_TRANS_CACHE, wtype, cur) then
    notify("Fetching states for #" .. ID .. " \u{2026}")
  end
  fetch_transitions(wtype, cur, function(states)
    if #states == 0 then
      notify("No transitions for #" .. ID .. ".", vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      local choices = { "Set #" .. ID .. " (" .. cur .. " \u{2192}):" }
      for i, s in ipairs(states) do choices[#choices + 1] = i .. ": " .. s end
      local idx = tonumber(vim.fn.inputlist(choices))
      if not idx or idx < 1 or idx > #states then
        notify("Cancelled.")
        return
      end
      local new = states[idx]
      pick_reason(new, function(reason) apply_state(new, reason) end)
    end)
  end)
end

local function open_browser()
  if current_url == "" then return end
  local ok = pcall(vim.ui.open, current_url)
  if not ok then
    vim.fn.jobstart({ "cmd", "/c", "start", "", current_url }, { detach = true })
  end
end

-- Copy this work item's web link to the system clipboard.
local function yank_link()
  if current_url == "" then return end
  vim.fn.setreg('"', current_url)
  pcall(vim.fn.setreg, "+", current_url)
  vim.notify("Copied link to #" .. tostring(ID) .. ": " .. current_url)
end

-- Open a scratch floating window at the cursor showing the given text lines
-- (same small helper as azure-cli.lua's and wi-dash.lua's open_float; kept
-- local since this file has no require'd module to share it from).
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

-- Show this view's keys in a float.
local function show_help()
  open_float({
    "Work-item detail keys",
    "",
    "  j / k        move",
    "  <CR>         on a parent/child line: open that work item here",
    "  gs           change the state of this work item",
    "  o            open this work item in the browser",
    "  gy           copy this work item's link",
    "  r            refresh",
    "  <BS> / q     close and return to the dashboard",
    "  ?            this help",
  })
end

local function leave()
  if _G.WI_VIEW_RELOAD then _G.WI_VIEW_RELOAD[ID] = nil end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
    -- Change-aware dashboard refresh: only redraws if the list actually changed.
    if _G.WI_DASH_REFRESH then vim.schedule(_G.WI_DASH_REFRESH) end
  else
    vim.cmd("qa!")
  end
end

local opts = { buffer = buf, silent = true, nowait = true }
vim.keymap.set("n", "<CR>", open_linked, opts)
vim.keymap.set("n", "gs", set_state, opts)
vim.keymap.set("n", "o", open_browser, opts)
vim.keymap.set("n", "gy", yank_link, opts)
vim.keymap.set("n", "r", function() if ID ~= "" then load(ID, true) end end, opts)
vim.keymap.set("n", "<BS>", leave, opts)
vim.keymap.set("n", "q", leave, opts)
vim.keymap.set("n", "?", show_help, opts)

if ID == "" then
  set_lines({ "No work item id (WIDASH_ID) set." })
else
  load(ID)
end
