-- lua/azure-cli/chat/waiting.lua: ]w / [w on every screen - the next
-- (previous) thing that waits for you, without going through the Agents
-- screen: a waiting plan's unanswered open questions, one by one, then its
-- approval; a change show_fix made ready that you haven't opened. In the
-- Agents screen's order (its rows and arrange), wrapping around.
--
--   M.stops(arranged, questions)  where ]w stops (pure)
--   M.step(stops, here, dir)      the stop after / before `here` (pure)
--   M.go(dir)
local M = {}

local function notify(msg) require("azure-cli.shell").notify(msg) end

local RANK = { question = 1, approve = 2, review = 3 }

-- `arranged` (agents_view's M.arrange: rows, with headers between) as a
-- list of stops { key, kind, line, row }: for a plan that waits for you
-- (and whose agent isn't working on it), each open question you haven't
-- answered, by line, then its approval (kind "approve", no line); for a
-- change waiting for your review, kind "review". `questions(row)` gives
-- the row's plan's question_status (plan_text.lua), or nil. Pure.
function M.stops(arranged, questions)
  local out = {}
  for _, r in ipairs(arranged) do
    if r.key and not r.header then
      if r.waiting and not (r.conv and r.conv.running) then
        local qs = {}
        for _, q in ipairs(questions(r) or {}) do if not q.answer then qs[#qs + 1] = q end end
        table.sort(qs, function(a, b) return a.line < b.line end)
        for _, q in ipairs(qs) do out[#out + 1] = { key = r.key, kind = "question", line = q.line, row = r } end
        out[#out + 1] = { key = r.key, kind = "approve", row = r }
      end
      if r.review then out[#out + 1] = { key = r.key, kind = "review", row = r } end
    end
  end
  return out
end

-- The stop after (dir 1) or before (dir -1) `here` - { key, kind, line }:
-- in a plan, kind "question" with the cursor's line (or "approve" on its
-- approval stop); in its change, "review" - wrapping around; the first
-- (last) stop when `here` is nil or nothing of it waits. nil: no stops. Pure.
function M.step(stops, here, dir)
  if #stops == 0 then return nil end
  local block = {}
  for i, s in ipairs(stops) do block[s.key] = block[s.key] or i end
  local at = here and block[here.key] and { block[here.key], RANK[here.kind] or 1, here.line or 0 }
  if not at then return dir < 0 and stops[#stops] or stops[1] end
  -- Ordered by plan (as listed), then questions / approval / change, then line.
  local function pos(s) return { block[s.key], RANK[s.kind], s.line or 0 } end
  local function less(a, b)
    for i = 1, 3 do if a[i] ~= b[i] then return a[i] < b[i] end end
    return false
  end
  if dir > 0 then
    for _, s in ipairs(stops) do if less(at, pos(s)) then return s end end
    return stops[1]
  end
  for i = #stops, 1, -1 do if less(pos(stops[i]), at) then return stops[i] end end
  return stops[#stops]
end

-- The approval stop ]w last went to: { key, line } - the cursor that was
-- left there, so the next ]w knows it's past the plan's questions.
local last = nil

-- Where you are: the plan of this tab (its plan window's line; a file of
-- its Changes section counts as its change), or the change viewer's.
local function here()
  local key = vim.t.azure_cli_plan_key
  if not key then return nil end
  local PV = require("azure-cli.chat.plan_view")
  local v = PV.open_views()[key]
  if not (v and v.tab == vim.api.nvim_get_current_tabpage()) then return { key = key, kind = "review" } end
  if require("azure-cli.chat.plan_changes").showing(v) then return { key = key, kind = "review" } end
  local line = vim.api.nvim_win_get_cursor(v.plan_win)[1]
  if last and last.key == key and last.line == line then return { key = key, kind = "approve" } end
  return { key = key, kind = "question", line = line }
end

-- ]w (dir 1) / [w (dir -1): goes there - a question: its plan at that
-- line; an approval: its plan, as it was; a change: the change viewer, as
-- gd on its Agents row.
function M.go(dir)
  local AV = require("azure-cli.chat.agents_view")
  local CHAT = require("azure-cli.chat")
  local PLAN = require("azure-cli.chat.plan")
  pcall(CHAT.restore_plans)
  local now = os.time()
  local rows = AV.rows(CHAT.conversations(), {}, PLAN.load, now)
  local stops = M.stops(AV.arrange(rows, now, false), function(r)
    local rec = PLAN.load(r.key)
    return rec and PLAN.question_status(PLAN.lines(rec), rec.threads)
  end)
  local s = M.step(stops, here(), dir)
  last = nil
  if not s then return notify("Nothing waits for you.") end
  if s.kind == "review" then
    return require("azure-cli.chat.tools_fix").open_at(s.row.target, "", nil, function(err)
      if err and not err:find("isn't part of the change", 1, true) then notify(err) end
    end)
  end
  local tab, err = PLAN.open(s.key, s.line)
  if not tab then return notify(err) end
  if s.kind == "approve" then
    local win = require("azure-cli.chat.plan_view").plan_win(s.key)
    if win then last = { key = s.key, line = vim.api.nvim_win_get_cursor(win)[1] } end
  end
end

-- Binds ]w / [w on `buf` for `surface` (every azure-vicli screen).
function M.bind(buf, surface)
  local KEYS = require("azure-cli.keys")
  KEYS.bind(buf, surface, "next_waiting", function() M.go(1) end, { desc = "the next thing waiting for you" })
  KEYS.bind(buf, surface, "prev_waiting", function() M.go(-1) end, { desc = "the previous thing waiting for you" })
end

return M
