-- lua/azure-cli/chat/agents_view.lua: the Agents screen - every plan's
-- agent at a glance, like a dashboard: what each is doing, what waits for
-- you, how long since it last did anything.
--
--   Agents                                      2 working · 1 queued · max 3
--
--   Needs you (1)
--    #3002  --name takes the flag as its value ● plan waits for you    3m
--
--   Working (2)
--    #3001  Throttle repeated login failures   ⠹ working  12s   ✎ start_story
--    #3012  Tests for the lockout window       ⌛ waiting for an agent
--
--   Finished (1)
--    #2990  Lock out after 5 failures          ✓ merged (PR !118)
--
-- Grouped by what needs you first (M.arrange), the most recent first in
-- each group; finished means its PR was merged or abandoned
-- (plan.pr_closed), and those over M.FINISHED_DAYS old hide until gF.
-- <CR> opens the row's plan, gd its change, gH its run log, gq its plan's
-- tab with that agent's conversation in the chat; <C-c> stops what it's
-- doing. Redrawn every second while it's showing.
--
--   M.rows(convs, queued, plan_of, now)  the rows (pure)
--   M.arrange(rows, now, all)            grouped and sorted (pure)
--   M.open()
local M = {}

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function CHAT() return require("azure-cli.chat") end

local SPIN = { "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" }

local function age(s)
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  return math.floor(s / 3600) .. "h"
end

-- One row per plan's agent (conversations with a plan key) and per
-- queued work item: { key, label, title, state, hl, detail, ago }.
-- `plan_of(key)` gives a plan's record (or nil). Each has its `group`
-- (M.GROUPS) and `at` (when it last did something). Pure.
function M.rows(convs, queued, plan_of, now, frame)
  local rows, seen = {}, {}
  for _, c in ipairs(convs) do
    if c.plan_key then
      seen[c.plan_key] = true
      local rec = plan_of(c.plan_key)
      local last = c.entries[#c.entries]
      local state, hl, group
      local detail = ""
      if c.running then
        group = 2
        state, hl = (frame or "*") .. " working", "AzureCliAccent"
        local tools = last and last.tools or {}
        detail = tools[#tools] or ""
      elseif rec and rec.pr_state == "completed" then
        state, hl = "\u{2713} merged (PR !" .. tostring(rec.pr and rec.pr.id or c.target and c.target.pr_id or "?") .. ")",
          "AzureCliStatusDone"
        group = 4
      elseif rec and rec.pr_state == "abandoned" then
        state, hl, group = "\u{2717} PR abandoned", "AzureCliMuted", 4
      elseif rec and rec.status == "draft" then
        state, hl, group = "\u{25CF} plan waits for you", "AzureCliStatusDraft", 1
      elseif rec and rec.status == "changes_requested" then
        state, hl, group = "\u{21BA} changes asked, not revised yet", "AzureCliStatusBad", 1
      elseif rec and rec.status == "approved" then
        state, hl, group = "\u{2713} approved", "AzureCliStatusOk", 3
      elseif rec and rec.status == "done" and type(rec.pr) == "table" then
        state, hl, group = "\u{2713} PR !" .. tostring(rec.pr.id) .. " open", "AzureCliStatusDone", 3
      elseif rec and rec.status == "done" then
        state, hl, group = "\u{2713} pushed", "AzureCliStatusDone", 3
      elseif last and last.status and last.status ~= "done" then
        state, hl, group = "\u{2717} " .. last.status, "AzureCliStatusBad", 1
      else
        state, hl, group = "idle", "AzureCliMuted", 3
      end
      local started = last and last.started or c.created or now
      rows[#rows + 1] = { key = c.plan_key, label = c.label or c.plan_key, title = (rec and rec.title) or c.title or "",
        state = state, hl = hl, detail = (detail:gsub("%s+", " ")), ago = age(math.max(0, now - (started or now))),
        target = c.target, conv = c, group = group, at = started or 0, closed_at = rec and rec.closed_at, cost = require("azure-cli.chat.core").cost_of(c.entries),
        requests = require("azure-cli.chat.core").requests_of(c.entries), context = last and last.context,
        waiting = rec and (rec.status == "draft" or rec.status == "changes_requested") or nil }
    end
  end
  for _, q in ipairs(queued) do
    if not seen[q.key] then
      rows[#rows + 1] = { key = q.key, label = q.label, title = q.title or "",
        state = "\u{231B} waiting for an agent", hl = "AzureCliMuted", detail = "", ago = "", target = q.target,
        group = 2, at = 0 }
    end
  end
  return rows
end

-- The screen's groups, in order: what needs you first.
M.GROUPS = { "Needs you", "Working", "In progress", "Finished" }
-- Finished agents older than this are hidden until gF shows them.
M.FINISHED_DAYS = 7

-- `rows` (M.rows) in their groups, the most recent first in each, with a
-- { header = "Needs you (2)" } before each group that has any. Finished
-- ones closed over M.FINISHED_DAYS ago are left out unless `all`; the
-- second result is how many were. Pure.
function M.arrange(rows, now, all)
  local kept, hidden = {}, 0
  for i, r in ipairs(rows) do
    if r.group == 4 and not all and r.closed_at and now - r.closed_at > M.FINISHED_DAYS * 86400 then
      hidden = hidden + 1
    else
      kept[#kept + 1] = { r = r, i = i }
    end
  end
  table.sort(kept, function(a, b)
    local ga, gb = a.r.group or 3, b.r.group or 3
    if ga ~= gb then return ga < gb end
    local ta, tb = a.r.closed_at or a.r.at or 0, b.r.closed_at or b.r.at or 0
    if ta ~= tb then return ta > tb end
    return a.i < b.i
  end)
  local counts = {}
  for _, k in ipairs(kept) do counts[k.r.group or 3] = (counts[k.r.group or 3] or 0) + 1 end
  local out, last = {}, nil
  for _, k in ipairs(kept) do
    local g = k.r.group or 3
    if g ~= last then
      out[#out + 1] = { header = M.GROUPS[g] .. " (" .. counts[g] .. ")" }
      last = g
    end
    out[#out + 1] = k.r
  end
  return out, hidden
end

-- Where the cursor goes when it lands on line `to` (from line `from`) of
-- a screen whose rows are `rows` (line -> row) and `last` lines long: `to`
-- if it's a row, else the next row on the way it was going, else `from`.
-- Pure.
function M.step_to_row(rows, from, to, last)
  if rows[to] then return to end
  local dir = to >= from and 1 or -1
  local l = to
  while l >= 1 and l <= last do
    if rows[l] then return l end
    l = l + dir
  end
  return rows[from] and from or to
end

local view = nil  -- { tab, win, buf, rows, timer, all, placed, line }
local ns = vim.api.nvim_create_namespace("azure_cli_agents")

local function render()
  if not (view and vim.api.nvim_buf_is_valid(view.buf)) then return end
  local UI = require("azure-cli.ui")
  local AG = require("azure-cli.chat.agents")
  local PLAN = require("azure-cli.chat.plan")
  local frame = SPIN[math.floor((vim.uv or vim.loop).now() / 120) % #SPIN + 1]
  local rows = M.rows(CHAT().conversations(), AG.queued(), PLAN.load, os.time(), frame)
  -- The rows move between groups as they go: the cursor follows its row.
  local was = vim.api.nvim_win_is_valid(view.win) and view.rows[vim.api.nvim_win_get_cursor(view.win)[1]]
  view.rows = {}
  local width = vim.api.nvim_win_is_valid(view.win) and UI.text_width(view.win) or 100
  local lines, hls = { "" }, {}
  if #rows == 0 then
    lines[#lines + 1] = "  No agents yet. On the work-items board, " .. require("azure-cli.keys").name("workitems", "plan_agents")
      .. " on a work item (or on selected rows)"
    lines[#lines + 1] = "  starts one per item, each writing its plan."
    hls[#hls + 1] = { 1, 0, -1, "AzureCliMuted" }
    hls[#hls + 1] = { 2, 0, -1, "AzureCliMuted" }
  end
  -- label 8, state 26, age 4, cost 7 and the gaps take 55 cells; the title gets
  -- what's left, keeping ~20 for the latest step.
  local title_w = math.max(16, math.min(44, width - 55 - 20))
  local CORE = require("azure-cli.chat.core")
  local total, requests
  local arranged, hidden = M.arrange(rows, os.time(), view.all)
  for _, r in ipairs(arranged) do
    if r.header then
      if #lines > 1 then lines[#lines + 1] = "" end
      lines[#lines + 1] = "  " .. r.header
      hls[#hls + 1] = { #lines - 1, 0, -1, "AzureCliSection" }
    else
      local label = UI.fit(r.label, 8)
      local title = UI.fit(r.title, title_w)
      local state = UI.fit(r.state, 26)
      -- What it has used: its cost when it reports one, else its premium
      -- requests; and how full its context is (ACP's usage_update).
      local cost = UI.fit(r.cost and CORE.money(r.cost) or CORE.requests_label(r.requests), 7)
      local ctx = CORE.context_label(r.context)
      local detail = ctx ~= "" and (ctx .. (r.detail ~= "" and (" \u{00B7} " .. r.detail) or "")) or r.detail
      local line = "  " .. label .. " " .. title .. "  " .. state .. "  " .. UI.fit(r.ago, 4) .. " " .. cost .. "  " .. detail
      lines[#lines + 1] = line
      view.rows[#lines] = r
      local s = #("  " .. label .. " " .. title .. "  ")
      hls[#hls + 1] = { #lines - 1, 2, 2 + #label, "AzureCliAccent" }
      hls[#hls + 1] = { #lines - 1, s, s + #state, r.hl }
      hls[#hls + 1] = { #lines - 1, s + #state + 2, -1, "AzureCliMuted" }
    end
  end
  for _, r in ipairs(rows) do  -- the hidden ones too
    if r.cost then total = (total or 0) + r.cost end
    if r.requests then requests = (requests or 0) + r.requests end
  end
  if hidden > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. hidden .. " finished more than " .. M.FINISHED_DAYS .. " days ago - "
      .. require("azure-cli.keys").name("agents", "show_finished") .. " shows them"
    hls[#hls + 1] = { #lines - 1, 0, -1, "AzureCliMuted" }
  end
  -- What's worth pressing now: approve only while a plan waits for you.
  if #rows > 0 then
    local waiting = 0
    for _, r in ipairs(rows) do if r.waiting then waiting = waiting + 1 end end
    local hints = { { "agents", "open", "its plan" } }
    if waiting > 0 then hints[#hints + 1] = { "agents", "approve", "approve (" .. waiting .. " waiting)" } end
    hints[#hints + 1] = { "agents", "changes", "its change" }
    hints[#hints + 1] = { "agents", "run_log", "what happened" }
    hints[#hints + 1] = { "agents", "help", "all keys" }
    local text, hhls = require("azure-cli.keys").hint_line(hints, "  ")
    lines[#lines + 1] = ""
    lines[#lines + 1] = text
    hls[#hls + 1] = { #lines - 1, 0, -1, "AzureCliMuted" }
    for _, h in ipairs(hhls) do hls[#hls + 1] = { #lines - 1, h[1], h[2], h[3] } end
  end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  if vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_buf(view.win) == view.buf then
    -- The first time, the first row; after that only a row the cursor
    -- was on is followed (headers and gaps are stepped over as you move).
    local cur = vim.api.nvim_win_get_cursor(view.win)[1]
    local want
    for l, r in pairs(view.rows) do
      if (was and r.key == was.key) or (not was and not view.placed and (not want or l < want)) then want = l end
    end
    if want then view.placed = true end
    if want and want ~= cur then
      view.line = want
      pcall(vim.api.nvim_win_set_cursor, view.win, { want, 0 })
    end
  end
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, view.buf, ns, h[1], h[2],
      { end_col = h[3] == -1 and #lines[h[1] + 1] or h[3], hl_group = h[4] })
  end
  local working, queued = AG.working(), #AG.queued()
  local parts = { working .. " working" }
  if queued > 0 then parts[#parts + 1] = queued .. " queued" end
  parts[#parts + 1] = "max " .. AG.max()
  if total then parts[#parts + 1] = CORE.money(total) .. " so far" end
  if requests then parts[#parts + 1] = CORE.requests_label(requests):gsub(" req$", " premium requests") .. " so far" end
  pcall(UI.wo, view.win, "winbar", UI.winbar({ "Agents", table.concat(parts, " \u{00B7} ") }, {}))
end

local function row_here()
  return view and view.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function open_plan(r)
  if not (r and require("azure-cli.chat.plan").load(r.key)) then
    return notify("No plan for " .. (r and r.label or "this row") .. " yet.")
  end
  require("azure-cli.chat.plan").open(r.key)
end

local HELP = {
  "This agent",
  { "open", "the row's plan" }, { "changes", "its change, file by file" }, { "run_log", "its run log" },
  { "chat", "its plan's tab, with that agent's conversation in the chat" },
  "Act",
  { "approve", "approve its plan (in visual mode: every selected row's), sent to its own agent" },
  { "cancel", "stop what that agent is doing" },
  "Window",
  { "pr_list", "the pull-request dashboard" }, { "workitems", "the work-items board" },
  { "show_finished", "show (or hide again) the agents finished over " .. M.FINISHED_DAYS .. " days ago" },
  { "refresh", "redraw" }, { "quit", "close" }, { "help", "this help" },
}

local function setup(buf)
  local K = require("azure-cli.keys")
  K.bind(buf, "agents", "open", function() open_plan(row_here()) end, { desc = "the row's plan" })
  K.bind(buf, "agents", "changes", function()
    local r = row_here()
    if not r then return end
    require("azure-cli.chat.tools_fix").open_at(r.target, "", nil, function(err)
      if err and not err:find("isn't part of the change", 1, true) then notify(err) end
    end)
  end, { desc = "its change" })
  K.bind(buf, "agents", "run_log", function()
    local r = row_here()
    if r then require("azure-cli.chat.plan").open_run_log(r.key) end
  end, { desc = "its run log" })
  K.bind(buf, "agents", "chat", function()
    local r = row_here()
    if not r then return end
    if require("azure-cli.chat.plan").load(r.key) then
      open_plan(r)
      vim.schedule(function() CHAT().show(true) end)
    else
      notify((r.label or "") .. " hasn't written its plan yet - its conversation shows in the plan's tab once it has.")
    end
  end, { desc = "its conversation" })
  K.bind(buf, "agents", "cancel", function()
    local r = row_here()
    if not (r and r.conv and r.conv.running) then return notify("That agent isn't doing anything.") end
    CHAT().cancel_conversation(r.conv)
  end, { desc = "stop it" })
  -- gA: approve the row's plan (in visual mode: every selected row's that
  -- waits for you) - one question for all, each goes to its own agent.
  local function approve_rows(rows)
    local PLAN = require("azure-cli.chat.plan")
    local keys, skipped = {}, {}
    for _, r in ipairs(rows) do
      local rec = PLAN.load(r.key)
      if rec and (rec.status == "draft" or rec.status == "changes_requested") then keys[#keys + 1] = r.key
      else skipped[#skipped + 1] = r.label end
    end
    if #keys == 0 then return notify("No plan there waits for your approval.") end
    PLAN.ask_approval(keys, function(allow_push)
      for _, k in ipairs(keys) do PLAN.approve(k, allow_push) end
      notify("Approved " .. #keys .. " plan" .. (#keys == 1 and "" or "s")
        .. (#skipped > 0 and (" (not " .. table.concat(skipped, ", ") .. ": nothing to approve)") or "") .. ".")
      render()
    end)
  end
  K.bind(buf, "agents", "approve", function()
    local r = row_here()
    if r then approve_rows({ r }) end
  end, { desc = "approve its plan" })
  K.bind(buf, "agents", "approve", function()
    local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local rows = {}
    for l = a, b do if view.rows[l] then rows[#rows + 1] = view.rows[l] end end
    approve_rows(rows)
  end, { desc = "approve the selected rows' plans", mode = "x" })
  K.bind(buf, "agents", "pr_list", function() require("azure-cli.home").go("prs") end,
    { desc = "the pull-request dashboard" })
  K.bind(buf, "agents", "workitems", function() require("azure-cli.home").go("workitems") end,
    { desc = "the work-items board" })
  K.bind(buf, "agents", "show_finished", function()
    view.all = not view.all
    render()
  end, { desc = "show the older finished agents" })
  K.bind(buf, "agents", "refresh", render, { desc = "redraw" })
  K.bind(buf, "agents", "quit", function()
    if view and vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(view.tab))
    end
  end, { desc = "close" })
  K.bind(buf, "agents", "help", function()
    require("azure-cli.ui").open_float(K.help_lines("agents", "Agents keys", HELP, {}), { title = "Keys" })
  end, { desc = "keys" })
end

-- Opens the screen (or goes to it).
function M.open()
  require("azure-cli.ui").theme()
  pcall(CHAT().restore_plans)  -- the plans' agents from before a restart
  if view and vim.api.nvim_tabpage_is_valid(view.tab) and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_set_current_tabpage(view.tab)
    vim.api.nvim_set_current_win(view.win)
    return render()
  end
  vim.cmd("tabnew")
  view = { tab = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(), rows = {} }
  vim.bo[view.buf].buftype = "nofile"
  vim.bo[view.buf].bufhidden = "wipe"
  vim.bo[view.buf].filetype = "azurecli-agents"
  vim.b[view.buf].azure_cli_title = "Agents"
  pcall(vim.api.nvim_buf_set_name, view.buf, "azure-cli://agents")
  require("azure-cli.ui").plain_window(view.win, { cursorline = true })
  setup(view.buf)
  -- j/k step over the group headers and the gaps between groups.
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = view.buf, callback = function()
    if not view then return end
    local to = vim.api.nvim_win_get_cursor(0)[1]
    local go = M.step_to_row(view.rows, view.line or to, to, vim.api.nvim_buf_line_count(view.buf))
    view.line = go
    if go ~= to then pcall(vim.api.nvim_win_set_cursor, 0, { go, 0 }) end
  end })
  local timer = (vim.uv or vim.loop).new_timer()
  view.timer = timer
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if view and vim.api.nvim_buf_is_valid(view.buf) and #vim.fn.win_findbuf(view.buf) > 0 then render() end
  end))
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = view.buf, once = true, callback = function()
    timer:stop()
    timer:close()
    view = nil
  end })
  render()
end

function M.current() return view end

require("azure-cli.chat.view").register("azurecli-agents", function(win)
  local r = view and view.rows[vim.api.nvim_win_get_cursor(win)[1]]
  local snap = { screen = "agents (every plan's agent: what each is doing)" }
  if r then
    snap.work_item = r.target and r.target.work_item_id and { id = r.target.work_item_id, title = r.title } or nil
    snap.note = "The cursor is on " .. r.label .. "'s agent: " .. r.state
  end
  return snap
end)

return M
