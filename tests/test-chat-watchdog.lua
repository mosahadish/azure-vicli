-- test-chat-watchdog.lua: a chat turn's idle timeout and hard cap
-- (chat/watchdog.lua, issue #27), on a clock the test turns by hand.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-watchdog.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local WD = require("azure-cli.chat.watchdog")

-- Limits from the config: the defaults, the old name, the new one winning.
local l = WD.limits({})
check("limits: defaults are 600s idle, 7200s cap", l.idle == 600 and l.cap == 7200, vim.inspect(l))
check("limits: the old timeout_seconds is the idle timeout", WD.limits({ timeout_seconds = 900 }).idle == 900
  and WD.limits({ timeout_seconds = 900 }).cap == 7200)
check("limits: idle_timeout_seconds wins over timeout_seconds",
  WD.limits({ timeout_seconds = 900, idle_timeout_seconds = 300 }).idle == 300)
check("limits: max_turn_seconds", WD.limits({ max_turn_seconds = 60 }).cap == 60)

-- Idle fires with no output.
local w = WD.new({ idle = 10, cap = 1000 }, 0)
check("idle: not before its time", WD.check(w, 9.9) == nil)
local f = WD.check(w, 10)
check("idle: fires after 10s with no output", f and f.kind == "idle" and f.after == 10, vim.inspect(f))

-- Steady output, well past the old wall-clock limit: never times out.
w = WD.new({ idle = 10, cap = 1000 }, 0)
local fired
for t = 5, 100, 5 do
  WD.activity(w, t)
  fired = fired or WD.check(w, t + 4.9)
end
check("idle: output every 5s for 100s never fires a 10s idle timeout", fired == nil, vim.inspect(fired))
check("idle: it fires once the output stops", (WD.check(w, 110) or {}).kind == "idle")

-- One of azure-vicli's tools working, a popup waiting: idle doesn't run.
w = WD.new({ idle = 10, cap = 1000 }, 0)
WD.busy(w, 1, 1)
check("busy: a long tool call doesn't count as idle", WD.check(w, 500) == nil)
WD.busy(w, -1, 500)
check("busy: idle counts from when it ended", WD.check(w, 509) == nil and (WD.check(w, 510) or {}).kind == "idle")
w = WD.new({ idle = 10, cap = 1000 }, 0)
WD.asking(w, 1, 2)
check("asking: a popup waiting for you doesn't count as idle", WD.check(w, 300) == nil)
WD.asking(w, -1, 300)
check("asking: idle counts from your answer", WD.check(w, 309) == nil and (WD.check(w, 310) or {}).kind == "idle")
WD.busy(w, -1, 311)
check("busy: never below zero", w.busy == 0)

-- The cap: fires however steady the output.
w = WD.new({ idle = 10, cap = 60 }, 0)
for t = 1, 59 do WD.activity(w, t) end
check("cap: not before its time", WD.check(w, 59.9) == nil)
f = WD.check(w, 60)
check("cap: fires at 60s despite steady output", f and f.kind == "cap" and f.after == 60, vim.inspect(f))
check("cap: even while a tool works", (function()
  local w2 = WD.new({ idle = 10, cap = 60 }, 0)
  WD.busy(w2, 1, 1)
  return (WD.check(w2, 61) or {}).kind == "cap"
end)())

-- Time a popup waited for you is taken off the cap (idle long here, so
-- only the cap is in play).
w = WD.new({ idle = 1000, cap = 60 }, 0)
WD.asking(w, 1, 30)
check("cap: a popup open for an hour doesn't trip it", WD.check(w, 3630) == nil)
WD.asking(w, -1, 3630)
check("cap: counts on after the answer", WD.check(w, 3659) == nil and (WD.check(w, 3660) or {}).kind == "cap")
w = WD.new({ idle = 1000, cap = 60 }, 0)
WD.asking(w, 1, 10)
WD.asking(w, 1, 20)
WD.asking(w, -1, 30)
check("cap: two popups at once count once", WD.check(w, 75) == nil)
WD.asking(w, -1, 40)
check("cap: and both answered, it counts again", WD.check(w, 89) == nil and (WD.check(w, 90) or {}).kind == "cap")

-- What it says: which one fired, after how long.
local wi = { idle = 600, cap = 7200 }
check("status: idle", WD.status({ kind = "idle", after = 600.4 }, wi) == "timed out (idle 10m)",
  WD.status({ kind = "idle", after = 600.4 }, wi))
check("status: cap", WD.status({ kind = "cap", after = 7200 }, wi) == "timed out (cap 2h)")
local li = WD.line({ kind = "idle", after = 600.4 }, wi)
check("line: idle names the time and the setting",
  li:find("no output from the agent for 10m", 1, true) and li:find("idle_timeout_seconds = 600", 1, true), li)
local lc = WD.line({ kind = "cap", after = 7200 }, wi)
check("line: cap names the time and the setting",
  lc:find("the turn ran 2h", 1, true) and lc:find("max_turn_seconds = 7200", 1, true), lc)
check("span", WD.span(45) == "45s" and WD.span(90) == "90s" and WD.span(120) == "2m" and WD.span(1) == "1s",
  vim.inspect({ WD.span(45), WD.span(90), WD.span(120), WD.span(1) }))

if fails > 0 then
  print(fails .. " chat-watchdog test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-watchdog tests passed")
end
