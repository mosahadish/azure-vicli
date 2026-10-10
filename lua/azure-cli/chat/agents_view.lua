-- lua/azure-cli/chat/agents_view.lua: the Agents screen - every plan's
-- agent at a glance, like a dashboard: what each is doing, what waits for
-- you, how long since it last did anything.
--
--   Agents                                      2 working · 1 queued · max 3
--
--    #3001  Throttle repeated login failures   ⠹ working  12s   ✎ start_story
--    #3002  --name takes the flag as its value ● plan waits for you    3m
--    #3012  Tests for the lockout window       ⌛ waiting for an agent
--
-- <CR> opens the row's plan, gd its change, gL its run log, gq its plan's
-- tab with that agent's conversation in the chat; <C-c> stops what it's
-- doing. Redrawn every second while it's showing.
--
--   M.rows(convs, queued, plan_of, now)  the rows (pure)
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
-- `plan_of(key)` gives a plan's record (or nil). Pure.
function M.rows(convs, queued, plan_of, now, frame)
  local rows, seen = {}, {}
  for _, c in ipairs(convs) do
    if c.plan_key then
      seen[c.plan_key] = true
      local rec = plan_of(c.plan_key)
      local last = c.entries[#c.entries]
      local state, hl
      local detail = ""
      if c.running then
        state, hl = (frame or "*") .. " working", "AzureCliAccent"
        local tools = last and last.tools or {}
        detail = tools[#tools] or ""
      elseif rec and rec.status == "draft" then
        state, hl = "\u{25CF} plan waits for you", "AzureCliStatusDraft"
      elseif rec and rec.status == "changes_requested" then
        state, hl = "\u{21BA} changes asked, not revised yet", "AzureCliStatusBad"
      elseif rec and rec.status == "approved" then
        state, hl = "\u{2713} approved", "AzureCliStatusOk"
      elseif rec and rec.status == "done" then
        state, hl = "\u{2713} pushed", "AzureCliStatusDone"
      elseif last and last.status and last.status ~= "done" then
        state, hl = "\u{2717} " .. last.status, "AzureCliStatusBad"
      else
        state, hl = "idle", "AzureCliMuted"
      end
      local started = last and last.started or c.created or now
      rows[#rows + 1] = { key = c.plan_key, label = c.label or c.plan_key, title = (rec and rec.title) or c.title or "",
        state = state, hl = hl, detail = (detail:gsub("%s+", " ")), ago = age(math.max(0, now - (started or now))),
        target = c.target, conv = c, cost = require("azure-cli.chat.core").cost_of(c.entries) }
    end
  end
  for _, q in ipairs(queued) do
    if not seen[q.key] then
      rows[#rows + 1] = { key = q.key, label = "#" .. tostring(q.item.id), title = q.item.title or "",
        state = "\u{231B} waiting for an agent", hl = "AzureCliMuted", detail = "", ago = "",
        target = { work_item_id = q.item.id } }
    end
  end
  return rows
end

local view = nil  -- { tab, win, buf, rows, timer }
local ns = vim.api.nvim_create_namespace("azure_cli_agents")

local function render()
  if not (view and vim.api.nvim_buf_is_valid(view.buf)) then return end
  local UI = require("azure-cli.ui")
  local AG = require("azure-cli.chat.agents")
  local PLAN = require("azure-cli.chat.plan")
  local frame = SPIN[math.floor((vim.uv or vim.loop).now() / 120) % #SPIN + 1]
  local rows = M.rows(CHAT().conversations(), AG.queued(), PLAN.load, os.time(), frame)
  view.rows = {}
  local width = vim.api.nvim_win_is_valid(view.win) and UI.text_width(view.win) or 100
  local lines, hls = { "" }, {}
  if #rows == 0 then
    lines[#lines + 1] = "  No agents yet. On the work-items board, gP on a work item (or on selected rows)"
    lines[#lines + 1] = "  starts one per item, each writing its plan."
    hls[#hls + 1] = { 1, 0, -1, "AzureCliMuted" }
    hls[#hls + 1] = { 2, 0, -1, "AzureCliMuted" }
  end
  -- label 8, state 26, age 4, cost 7 and the gaps take 55 cells; the title gets
  -- what's left, keeping ~20 for the latest step.
  local title_w = math.max(16, math.min(44, width - 55 - 20))
  local CORE = require("azure-cli.chat.core")
  local total
  for _, r in ipairs(rows) do
    local label = UI.fit(r.label, 8)
    local title = UI.fit(r.title, title_w)
    local state = UI.fit(r.state, 26)
    local cost = UI.fit(CORE.money(r.cost), 7)
    local line = "  " .. label .. " " .. title .. "  " .. state .. "  " .. UI.fit(r.ago, 4) .. " " .. cost .. "  " .. r.detail
    lines[#lines + 1] = line
    view.rows[#lines] = r
    local s = #("  " .. label .. " " .. title .. "  ")
    hls[#hls + 1] = { #lines - 1, 2, 2 + #label, "AzureCliAccent" }
    hls[#hls + 1] = { #lines - 1, s, s + #state, r.hl }
    hls[#hls + 1] = { #lines - 1, s + #state + 2, -1, "AzureCliMuted" }
    if r.cost then total = (total or 0) + r.cost end
  end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
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
  "Agents",
  { "open", "the row's plan" }, { "changes", "its change, file by file" }, { "run_log", "its run log" },
  { "chat", "its plan's tab, with that agent's conversation in the chat" },
  { "approve", "approve its plan (in visual mode: every selected row's), sent to its own agent" },
  { "cancel", "stop what that agent is doing" },
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
  pcall(vim.api.nvim_win_set_cursor, view.win, { 2, 0 })
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
