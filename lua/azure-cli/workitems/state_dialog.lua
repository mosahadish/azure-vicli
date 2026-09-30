-- lua/azure-cli/workitems/state_dialog.lua: gs's "set state" popup, shared
-- by the work-items dashboard and the detail view - pick the new state and
-- a reason in one float, and optionally carry the change down to the
-- item's children.
--
-- Children usually have another type (Tasks under a Story) whose workflow
-- names its states differently, so each child is mapped by M.child_target:
-- the same state when that child can move to it, else the state it can
-- move to in the same category (Proposed/InProgress/Resolved/Completed/
-- Removed, from `--wi-state states <type>`). Every child's mapping is shown
-- in the popup before anything is sent, and "also set children" starts
-- unchecked.
--
-- Also home to the workflow-metadata fetches (transitions, reasons,
-- states) both screens used to carry their own copies of, so a pre-warm
-- from either coalesces with a gs from the other.
--
-- The pure half (M.child_target, M.default_on, M.reason_options, M.lines
-- and the toggles) runs under plain luajit for tests/test-state-dialog.lua;
-- everything touching vim or the provider is resolved inside functions.
local M = {}

M.META_TTL = 600    -- workflow metadata rarely changes
M.DETAIL_TTL = 30   -- same freshness the detail prefetch uses

M.DEFAULT_REASON = "(default reason)"
M.OTHER_REASON = "(other\u{2026} type a reason)"

-- Where a child in state `cur` should go when its parent moves to `target`
-- (whose category, on the parent's type, is `target_cat` - nil/"" when the
-- server reports none). `reachable` is the child's transitions from `cur`,
-- `cats` its type's state -> category map. Returns the state, or nil and
-- why not (shown in the popup).
function M.child_target(cur, target, target_cat, reachable, cats)
  cats = cats or {}
  if cur == target then return nil, "already " .. cur end
  local has_cat = target_cat and target_cat ~= ""
  if has_cat and cats[cur] == target_cat then return nil, "already " .. cur end
  for _, s in ipairs(reachable or {}) do
    if s == target then return target end
  end
  if has_cat then
    for _, s in ipairs(reachable or {}) do
      if cats[s] == target_cat then return s end
    end
  end
  return nil, "no matching state"
end

-- Workflow order of the categories, for "would this move a child back".
local CAT_RANK = { Proposed = 1, InProgress = 2, Resolved = 3, Completed = 4 }

-- Whether a child with a target starts checked (it can always be checked
-- by hand): not when it was removed, and not when the move takes it back
-- a step - closing a story closes its open tasks, but moving the story to
-- Active doesn't quietly reopen the finished ones. `cur_cat`/`target_cat`
-- are nil when the server reports no categories.
function M.default_on(target, cur_cat, target_cat)
  if target == nil or cur_cat == "Removed" then return false end
  local from, to = CAT_RANK[cur_cat or ""], CAT_RANK[target_cat or ""]
  return not (from and to and from > to)
end

-- The reason choices for a transition, given the reasons ADO has seen for
-- it: nothing to choose between (0 or 1) is just ADO's default; otherwise
-- those reasons, then the default, then free text - the order gs's old
-- picker offered them in.
function M.reason_options(reasons)
  local opts = {}
  if #reasons > 1 then
    for _, r in ipairs(reasons) do opts[#opts + 1] = { label = r, reason = r } end
  end
  opts[#opts + 1] = { label = M.DEFAULT_REASON, reason = "" }
  if #reasons > 1 then opts[#opts + 1] = { label = M.OTHER_REASON, other = true } end
  return opts
end

-- `s` cut to `n` characters (UTF-8 aware), with an ellipsis when cut.
local function cut(s, n)
  s = s or ""
  local out, count = {}, 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    count = count + 1
    if count > n then return table.concat(out) .. "\u{2026}" end
    out[#out + 1] = ch
  end
  return s
end

local function cycler(list, i)
  if not list or #list == 0 then return "loading\u{2026}" end
  local s = "\u{2039} " .. list[i].label .. " \u{203A}"
  if #list > 1 then s = s .. "   (" .. i .. "/" .. #list .. ")" end
  return s
end

-- How many children would be set if "also set children" were on.
function M.selected(st)
  local n = 0
  for _, k in ipairs(st.kids or {}) do
    if k.on and k.target then n = n + 1 end
  end
  return n
end

-- The popup's lines for `spec` = { id, type, state, title } and the dialog
-- state `st` = { states = {{label}}, si, ropts = nil|{{label,...}}, ri,
-- all, kids = nil|{{id, type, state, title, target, why, on, pending}} },
-- plus rows[line] = { kind = "state"|"reason"|"all"|"child", i } saying
-- what <Space> on that line does.
function M.lines(spec, st)
  local lines, rows = {}, {}
  local function add(l, row)
    lines[#lines + 1] = l
    rows[#lines] = row
  end
  add("Set #" .. tostring(spec.id) .. "  " .. (spec.type or "") .. " \u{00B7} " .. (spec.state or ""))
  if spec.title and spec.title ~= "" then add("  " .. cut(spec.title, 60)) end
  add("")
  add("State:   " .. cycler(st.states, st.si), { kind = "state" })
  add("Reason:  " .. cycler(st.ropts, st.ri), { kind = "reason" })
  add("")
  local kids = st.kids
  if kids == nil then
    add("Children: loading\u{2026}")
  elseif #kids == 0 then
    add("No children")
  else
    add((st.all and "[x]" or "[ ]") .. " Also set children (" .. M.selected(st) .. " of " .. #kids .. ")",
      { kind = "all" })
    for i, k in ipairs(kids) do
      local head = "    " .. ((st.all and k.on and k.target) and "[x]" or "[ ]")
        .. " #" .. tostring(k.id) .. " " .. (k.type or "") .. "  " .. (k.state or "")
      local tail
      if k.pending then
        tail = " \u{2026}"
      elseif k.target then
        tail = " \u{2192} " .. k.target
      else
        tail = "  (" .. (k.why or "no matching state") .. ")"
      end
      add(head .. tail .. "  " .. cut(k.title, 40), { kind = "child", i = i })
    end
  end
  add("")
  add("<Space>/l, h: cycle or toggle   <CR>: apply   q: close")
  return lines, rows
end

-- "Also set children": turning it on with nothing selected brings the
-- defaults back, so it never turns on to an empty set.
function M.toggle_all(st)
  if not st.kids or #st.kids == 0 then return false end
  st.all = not st.all
  if st.all and M.selected(st) == 0 then
    for _, k in ipairs(st.kids) do k.on = M.default_on(k.target, k.cur_cat, k.target_cat) end
  end
  return true
end

-- One child's box. While "also set children" is off, checking a child
-- means "just this one": the master turns on with only that child picked.
-- Unchecking the last one turns the master back off.
function M.toggle_kid(st, i)
  local k = st.kids and st.kids[i]
  if not k or not k.target then return false end
  if not st.all then
    for _, o in ipairs(st.kids) do o.on = false end
    st.all, k.on = true, true
  else
    k.on = not k.on
    if M.selected(st) == 0 then st.all = false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Provider calls (vim only below this line)
-- ---------------------------------------------------------------------------

local inflight = {}

-- Fetch a cached metadata list for (subcmd, wtype, state) - --wi-state
-- transitions/reasons/states - and call cb(list) when ready: instant on a
-- fresh cache hit, coalesced when a fetch for the same key is already
-- running. cb is optional (a pre-warm passes none).
local function fetch_meta(cache, subcmd, wtype, state, cb)
  local key = wtype .. "\0" .. (state or "")
  local c = cache[key]
  if c and (os.time() - c.ts) < M.META_TTL then
    if cb then cb(c.list) end
    return
  end
  local ikey = subcmd .. "\0" .. key
  if inflight[ikey] then
    if cb then table.insert(inflight[ikey], cb) end
    return
  end
  inflight[ikey] = cb and { cb } or {}
  local argv = require("azure-cli.config").provider_argv("--wi-state", subcmd, wtype)
  if state then argv[#argv + 1] = state end
  local out = {}
  require("azure-cli.rpc").run(argv, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      local list = vim.tbl_filter(function(s) return s ~= "" end, out)
      if code == 0 then cache[key] = { list = list, ts = os.time() } end
      local cbs = inflight[ikey]
      inflight[ikey] = nil
      for _, f in ipairs(cbs or {}) do pcall(f, list) end
    end,
  })
end

function M.fetch_transitions(wtype, cur, cb)
  fetch_meta(require("azure-cli.state").WI_TRANS_CACHE, "transitions", wtype, cur, cb)
end

function M.fetch_reasons(wtype, new, cb)
  fetch_meta(require("azure-cli.state").WI_REASON_CACHE, "reasons", wtype, new, cb)
end

-- cb(map) of state name -> category for `wtype`; empty when the server
-- reports no categories (children then match on the name alone).
function M.fetch_categories(wtype, cb)
  fetch_meta(require("azure-cli.state").WI_STATES_CACHE, "states", wtype, nil, function(list)
    local cats = {}
    for _, line in ipairs(list) do
      local name, cat = line:match("^(.-)\t(.*)$")
      if name then cats[name] = cat end
    end
    cb(cats)
  end)
end

function M.transitions_cached(wtype, state)
  local c = require("azure-cli.state").WI_TRANS_CACHE[wtype .. "\0" .. state]
  return c and (os.time() - c.ts) < M.META_TTL
end

-- Warm the caches gs needs for an item in (wtype, state) so it opens at
-- once: its transitions, the reasons for each of them, and its categories.
function M.prewarm(wtype, state)
  if wtype == "" or state == "" then return end
  M.fetch_transitions(wtype, state, function(targets)
    for _, t in ipairs(targets or {}) do M.fetch_reasons(wtype, t) end
  end)
  M.fetch_categories(wtype, function() end)
end

-- cb(data) with an item's --wi-detail JSON (nil on failure), from the
-- detail cache the dashboard's prefetch and the view share when fresh.
local function fetch_detail(id, cb)
  local STATE = require("azure-cli.state")
  local c = STATE.WI_DETAIL_CACHE[id]
  local function decode(body)
    local ok, data = pcall(vim.json.decode, body)
    return ok and type(data) == "table" and data or nil
  end
  if c and (os.time() - c.ts) < M.DETAIL_TTL then
    local data = decode(c.body)
    if data then return cb(data) end
  end
  local out = {}
  require("azure-cli.rpc").run(require("azure-cli.config").provider_argv("--wi-detail", id), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then return cb(nil) end
      local body = table.concat(out, "\n")
      STATE.WI_DETAIL_CACHE[id] = { body = body, ts = os.time() }
      cb(decode(body))
    end,
  })
end

-- Whatever shows `id` picks up its new state: the dashboard's record and
-- any open detail tab (which also drops the stale detail cache entry).
local function refresh(id)
  local STATE = require("azure-cli.state")
  STATE.WI_DETAIL_CACHE[id] = nil
  local reload = STATE.WI_VIEW_RELOAD and STATE.WI_VIEW_RELOAD[id]
  if reload then vim.schedule(reload) end
end

-- One --wi-state set; cb(ok, err_msg).
local function set_one(id, new, reason, cb)
  local SHELL = require("azure-cli.shell")
  local cmd = require("azure-cli.config").provider_argv("--wi-state", "set", id, new)
  if reason and reason ~= "" then cmd[#cmd + 1] = reason end
  local err = {}
  require("azure-cli.rpc").run(cmd, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        local STATE = require("azure-cli.state")
        if STATE.WI_STATE_CHANGED then STATE.WI_STATE_CHANGED(id, new) end
        refresh(id)
        cb(true)
      else
        cb(false, SHELL.job_error("work item #" .. id, code, err))
      end
    end,
  })
end

-- Set `id` to `new` (with `reason`, "" = ADO's default), then - only once
-- that succeeded - each of `kids` ({id, target}) to its own target with its
-- type's default reason. A child that fails is reported on its own; the
-- parent's change stands.
function M.apply(id, new, reason, kids)
  local notify = require("azure-cli.shell").notify
  local suffix = (reason and reason ~= "") and (" (" .. reason .. ")") or ""
  notify("Setting #" .. id .. " \u{2192} " .. new .. suffix .. " \u{2026}")
  set_one(id, new, reason, function(ok, msg)
    if not ok then
      notify("Set #" .. id .. " failed: " .. msg, vim.log.levels.ERROR)
      return
    end
    notify("#" .. id .. " is now " .. new .. suffix .. ".")
    if #kids == 0 then return end
    local left, done, failed = #kids, 0, {}
    notify("Setting " .. #kids .. " child" .. (#kids == 1 and "" or "ren") .. " of #" .. id .. " \u{2026}")
    for _, k in ipairs(kids) do
      local kid_id = tostring(k.id)
      set_one(kid_id, k.target, "", function(kok, kmsg)
        if kok then
          done = done + 1
        else
          failed[#failed + 1] = kid_id
          notify("Set #" .. kid_id .. " \u{2192} " .. k.target .. " failed: " .. kmsg, vim.log.levels.ERROR)
        end
        left = left - 1
        if left > 0 then return end
        -- The parent's detail lists its children's states: reload it too.
        refresh(id)
        if #failed == 0 then
          notify("Set " .. done .. " child" .. (done == 1 and "" or "ren") .. " of #" .. id .. ".")
        else
          notify("Set " .. done .. " of " .. #kids .. " children of #" .. id .. "; #"
            .. table.concat(failed, ", #") .. " failed.", vim.log.levels.WARN)
        end
      end)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- The popup
-- ---------------------------------------------------------------------------

-- Open gs's popup for `item` = { id, type, state, title }. Fetches the
-- item's transitions first (nothing to show without them), then fills the
-- reason and the children in as they arrive.
function M.open(item)
  local notify = require("azure-cli.shell").notify
  local spec = {
    id = tostring(item.id or ""), type = item.type or "", state = item.state or "", title = item.title or "",
  }
  if spec.id == "" then return end
  if not M.transitions_cached(spec.type, spec.state) then
    notify("Fetching states for #" .. spec.id .. " \u{2026}")
  end
  M.fetch_transitions(spec.type, spec.state, function(states)
    vim.schedule(function()
      if #states == 0 then
        notify("No transitions for #" .. spec.id .. ".", vim.log.levels.WARN)
        return
      end
      M._popup(spec, states)
    end)
  end)
end

function M._popup(spec, states)
  local notify = require("azure-cli.shell").notify
  local st = { si = 1, ri = 1, all = false, states = {} }
  for _, s in ipairs(states) do st.states[#st.states + 1] = { label = s } end
  local parent_cats   -- nil until fetched
  local kid_trans, kid_cats = {}, {}   -- per child id / per child type
  local rows = {}
  local closed = false

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  local win

  local function geometry(lines)
    local width = 20
    for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
    width = math.min(width, math.max(20, vim.o.columns - 6))
    local height = 0
    for _, l in ipairs(lines) do
      height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
    height = math.min(height, math.max(3, vim.o.lines - 4))
    return {
      relative = "editor", width = width, height = height,
      row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    }
  end

  local function draw()
    if closed then return end
    local lines
    lines, rows = M.lines(spec, st)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_config(win, geometry(lines)) end
  end

  -- Work every child's target out again (after a state change, or when
  -- a child's transitions/categories arrive).
  local function remap()
    if not st.kids then return end
    local target = st.states[st.si].label
    local tcat = parent_cats and parent_cats[target]
    for _, k in ipairs(st.kids) do
      local trans, cats = kid_trans[k.id], kid_cats[k.type or ""]
      k.pending = not (parent_cats and trans and cats)
      if k.pending then
        k.target, k.why, k.on = nil, nil, false
      else
        k.cur_cat = cats[k.state or ""]
        k.target, k.why = M.child_target(k.state or "", target, tcat, trans, cats)
        k.target_cat = k.target and cats[k.target]
        k.on = M.default_on(k.target, k.cur_cat, k.target_cat)
      end
    end
    if M.selected(st) == 0 then st.all = false end
  end

  local function load_reasons()
    local want = st.states[st.si].label
    st.ropts, st.ri = nil, 1
    M.fetch_reasons(spec.type, want, function(reasons)
      vim.schedule(function()
        if closed or st.states[st.si].label ~= want then return end
        st.ropts = M.reason_options(reasons)
        draw()
      end)
    end)
  end

  local function redraw_later()
    vim.schedule(function()
      remap()
      draw()
    end)
  end

  draw()
  local cfg = geometry(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  cfg.style, cfg.border = "minimal", "rounded"
  win = vim.api.nvim_open_win(buf, true, cfg)
  local UI = require("azure-cli.ui")
  UI.wo(win, "wrap", true)
  UI.wo(win, "linebreak", true)
  UI.wo(win, "cursorline", true)
  for l, r in pairs(rows) do
    if r.kind == "state" then pcall(vim.api.nvim_win_set_cursor, win, { l, 0 }) end
  end

  load_reasons()
  M.fetch_categories(spec.type, function(cats)
    parent_cats = cats
    redraw_later()
  end)
  fetch_detail(spec.id, function(data)
    vim.schedule(function()
      if closed then return end
      st.kids = {}
      for _, c in ipairs((data and data.children) or {}) do
        local k = { id = tostring(c.id), type = c.type or "", state = c.state or "", title = c.title or "" }
        st.kids[#st.kids + 1] = k
        M.fetch_transitions(k.type, k.state, function(list)
          kid_trans[k.id] = list
          redraw_later()
        end)
        if not kid_cats[k.type] then
          M.fetch_categories(k.type, function(cats)
            kid_cats[k.type] = cats
            redraw_later()
          end)
        end
      end
      if not data then notify("Couldn't load #" .. spec.id .. "'s children.", vim.log.levels.WARN) end
      remap()
      draw()
    end)
  end)

  local function close()
    closed = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  -- Leaving the float (a mouse click elsewhere, <C-w>w) cancels it; a
  -- window can't be closed from inside its own WinLeave, hence the schedule.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf, once = true, callback = function() vim.schedule(close) end,
  })

  local function cycle(step)
    local r = rows[vim.api.nvim_win_get_cursor(win)[1]]
    if not r then return end
    if r.kind == "state" then
      if #st.states < 2 then return end
      st.si = (st.si - 1 + step) % #st.states + 1
      load_reasons()
      remap()
    elseif r.kind == "reason" then
      if not st.ropts or #st.ropts < 2 then return end
      st.ri = (st.ri - 1 + step) % #st.ropts + 1
    elseif r.kind == "all" then
      if not M.toggle_all(st) then return end
    elseif r.kind == "child" then
      if not M.toggle_kid(st, r.i) then return end
    else
      return
    end
    draw()
  end

  local function confirm()
    local new = st.states[st.si].label
    local kids = {}
    if st.all then
      for _, k in ipairs(st.kids or {}) do
        if k.on and k.target then kids[#kids + 1] = { id = k.id, target = k.target } end
      end
    end
    local opt = st.ropts and st.ropts[st.ri]
    close()
    if opt and opt.other then
      require("azure-cli.prompt").input({ prompt = "Reason:", allow_empty = true }, function(r)
        if r ~= nil then M.apply(spec.id, new, r, kids) end
      end)
      return
    end
    M.apply(spec.id, new, opt and opt.reason or "", kids)
  end

  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<Space>", function() cycle(1) end, kopts)
  vim.keymap.set("n", "l", function() cycle(1) end, kopts)
  vim.keymap.set("n", "h", function() cycle(-1) end, kopts)
  vim.keymap.set("n", "<CR>", confirm, kopts)
  vim.keymap.set("n", "q", close, kopts)
  vim.keymap.set("n", "<Esc>", close, kopts)
end

return M
