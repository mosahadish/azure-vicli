-- lua/azure-cli/chat/watchdog.lua: when a chat turn has gone on too long
-- (chat/run.lua). Two limits, both from the agent's config:
--
--   idle - no sign of life from the agent for this long (idle_timeout_seconds,
--          or the old timeout_seconds): every chunk it streams, every tool
--          call and permission request starts it again, and it doesn't run
--          while one of azure-vicli's tools is working (`busy`) or a popup
--          waits for you (`asking`).
--   cap  - the whole turn, however busy (max_turn_seconds), less the time a
--          popup waited for you.
--
-- The clock is the caller's (seconds, fractions fine), so it's all pure.
local M = {}

M.IDLE, M.CAP = 600, 7200

-- The limits `agent` sets: { idle, cap } in seconds.
function M.limits(agent)
  agent = type(agent) == "table" and agent or {}
  return { idle = tonumber(agent.idle_timeout_seconds) or tonumber(agent.timeout_seconds) or M.IDLE,
    cap = tonumber(agent.max_turn_seconds) or M.CAP }
end

function M.new(limits, now)
  return { idle = limits.idle, cap = limits.cap, started = now, last = now, busy = 0, asking = 0,
    asked_total = 0, asked_since = nil }
end

-- The agent did something.
function M.activity(w, now) if now > w.last then w.last = now end end

-- One of azure-vicli's tools starts (+1) or ends (-1).
function M.busy(w, delta, now)
  w.busy = math.max(0, w.busy + delta)
  M.activity(w, now)
end

-- A popup starts waiting for you (+1), or you answered it (-1).
function M.asking(w, delta, now)
  if delta > 0 then
    if w.asking == 0 then w.asked_since = now end
    w.asking = w.asking + 1
  elseif w.asking > 0 then
    w.asking = w.asking - 1
    if w.asking == 0 and w.asked_since then
      w.asked_total = w.asked_total + (now - w.asked_since)
      w.asked_since = nil
    end
  end
  M.activity(w, now)
end

-- nil while the turn may go on; else which limit it hit and after how
-- long: { kind = "idle" | "cap", after = seconds }.
function M.check(w, now)
  local waited = w.asked_total + (w.asked_since and (now - w.asked_since) or 0)
  local ran = now - w.started - waited
  if ran >= w.cap then return { kind = "cap", after = ran } end
  if w.busy == 0 and w.asking == 0 and now - w.last >= w.idle then return { kind = "idle", after = now - w.last } end
  return nil
end

-- 45s, 10m, 2h, 90s.
function M.span(s)
  s = math.floor(s + 0.5)
  if s >= 3600 and s % 3600 == 0 then return (s / 3600) .. "h" end
  if s >= 60 and s % 60 == 0 then return (s / 60) .. "m" end
  return s .. "s"
end

-- The entry's status once `fired` stopped it: "timed out (idle 10m)", or
-- "timed out (idle 10m, killed)" when the agent ignored the interrupt and
-- its process had to go (chat/run.lua).
function M.status(fired, w, killed)
  return "timed out (" .. fired.kind .. " " .. M.span(fired.kind == "cap" and w.cap or w.idle)
    .. (killed and ", killed" or "") .. ")"
end

-- The line under the answer saying which limit fired, and after how long
-- (the limit: checked once a second, `after` can be a second past it).
function M.line(fired, w)
  if fired.kind == "cap" then
    return "\u{2717} timed out: the turn ran " .. M.span(w.cap) .. ", the cap (max_turn_seconds = " .. w.cap .. ")"
  end
  return "\u{2717} timed out: no output from the agent for " .. M.span(w.idle)
    .. " (idle_timeout_seconds = " .. w.idle .. ")"
end

return M
