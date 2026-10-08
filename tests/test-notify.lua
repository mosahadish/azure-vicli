-- test-notify.lua: drives notify.lua's toast() with a shimmed `vim`
-- (fn.has/fn.executable/fn.jobstart recording the command, fn.timer_start
-- queuing its callback for the test to fire by hand instead of nvim's event
-- loop) so the coalescing/rate-limit behaviour can be checked without a
-- real nvim or a real OS notification backend.
--
-- Usage: luajit test-notify.lua <notify.lua path>
--
-- Checks: the Windows command line carries the escaped title/body and the
-- app id; embedded single quotes and XML metacharacters in the body are
-- escaped; the AZVICLI_TOASTS=0 opt-out suppresses the call entirely; two
-- toast() calls with the same title inside the rate-limit window collapse
-- into one call whose body says "(+1 more)".

local jobs = {}       -- recorded vim.fn.jobstart command tables, in order
local timers = {}     -- queued fn.timer_start callbacks (+ their ms), drained by hand
local stopped_timers = {}  -- timer ids fn.timer_stop was called on
local notifies = {}   -- recorded vim.notify(msg, level) calls, in order
local env = {}         -- vim.env shim, mutable by the test

-- M.flash's floating-window side (see notify.lua's own header comment on
-- it): a tiny fake of just the vim.api calls it makes, so the
-- queueing/eviction/dismiss-ordering logic can be driven without a real
-- nvim - nvim_open_win records enough (buf/config) to be inspected,
-- nvim_win_close/nvim_win_is_valid track open/closed per fake window id.
local win_seq = 0
local fake_wins = {}  -- winid -> { valid = bool, config = table }

vim = {
  env = env,
  log = { levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 } },
  o = { lines = 24, columns = 80 },
  notify = function(msg, level)
    notifies[#notifies + 1] = { msg = msg, level = level }
  end,
  deepcopy = function(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = vim.deepcopy(x) end
    return out
  end,
  split = function(s, sep)
    local out = {}
    for line in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = line end
    return out
  end,
  fn = {
    strdisplaywidth = function(s) return #tostring(s) end,
    has = function(what)
      if what == "win32" then return env._has_win32 and 1 or 0 end
      if what == "mac" then return env._has_mac and 1 or 0 end
      return 0
    end,
    executable = function(name)
      if env._executables and env._executables[name] then return 1 end
      return 0
    end,
    jobstart = function(cmd, opts)
      jobs[#jobs + 1] = { cmd = cmd, opts = opts }
      return #jobs
    end,
    timer_start = function(ms, cb)
      timers[#timers + 1] = { cb = cb, ms = ms }
      return #timers
    end,
    timer_stop = function(id)
      stopped_timers[id] = true
    end,
  },
  bo = setmetatable({}, { __index = function() return setmetatable({}, { __newindex = function() end }) end }),
  api = {
    nvim_create_buf = function() return 1 end,
    nvim_buf_set_lines = function() end,
    nvim_open_win = function(_, _enter, cfg)
      win_seq = win_seq + 1
      fake_wins[win_seq] = { valid = true, config = cfg }
      return win_seq
    end,
    nvim_win_close = function(win)
      local w = fake_wins[win]
      if w then w.valid = false end
    end,
    nvim_win_is_valid = function(win)
      local w = fake_wins[win]
      return w ~= nil and w.valid
    end,
    nvim_win_get_height = function(win)
      local w = fake_wins[win]
      return (w and w.config and w.config.height) or 1
    end,
    nvim_win_set_config = function(win, cfg)
      local w = fake_wins[win]
      if w then
        for k, v in pairs(cfg) do w.config[k] = v end
      end
    end,
  },
}

local function drain_timers()
  local pending = timers
  timers = {}
  for _, t in ipairs(pending) do t.cb() end
end

local function last_job_cmd_line()
  assert(#jobs > 0, "expected a jobstart call")
  local cmd = jobs[#jobs].cmd
  local parts = {}
  for _, c in ipairs(cmd) do parts[#parts + 1] = c end
  return table.concat(parts, " \1 ")  -- \1 so a substring check can't false-match across args
end

assert(arg[1], "usage: luajit test-notify.lua <notify.lua>")

-- Windows path: has("win32") true, powershell present.
env._has_win32 = true
env._executables = { powershell = true }

local M = dofile(arg[1])
-- notify.lua now keeps its opt-out flag in lua/azure-cli/state.lua (via
-- require, resolved through LUA_PATH - see tests/run.sh) instead of a bare
-- bare global of its own; same module instance M itself just required, since
-- require() caches by module name.
local STATE = require("azure-cli.state")

-- 1. Basic toast: command carries the escaped title/body and the app id.
jobs, timers = {}, {}
M.toast("PR #123", "New comment on your PR: it's <urgent> & broken")
assert(#jobs == 0, "toast must wait for the rate-limit timer, not fire immediately")
drain_timers()
assert(#jobs == 1, "expected exactly one jobstart call after the timer fires, got " .. #jobs)
local line = last_job_cmd_line()
assert(line:find("powershell", 1, true), "command should invoke powershell")
assert(line:find("PR #123", 1, true), "command should carry the (unescaped-in-args) title text 'PR #123'")
-- The body's embedded single quote must be doubled for the PS '...' literal,
-- and its < and & must be XML-escaped for the ToastText02 text node.
assert(line:find("it''s", 1, true), "embedded single quote must be doubled: " .. line)
assert(line:find("&lt;urgent&gt;", 1, true), "< and > must be XML-escaped: " .. line)
assert(line:find("&amp;", 1, true), "& must be XML-escaped: " .. line)
assert(line:find("{1AC14E77%-02E7%-4E5D%-B744%-2EB1AE5198B7}", 1), "command should carry the well-known AppUserModelId: " .. line)
assert(jobs[1].opts.detach == true, "toast job should be detached so it never blocks nvim")

-- 2. Opt-out via env var suppresses the call entirely.
jobs, timers = {}, {}
env.AZVICLI_TOASTS = "0"
M.toast("PR #999", "should not fire")
drain_timers()
assert(#jobs == 0, "AZVICLI_TOASTS=0 must suppress the toast")
env.AZVICLI_TOASTS = nil

-- 3. Opt-out via STATE.toasts == false, and M.toggle() flips it back.
jobs, timers = {}, {}
STATE.toasts = false
assert(M.enabled() == false, "M.enabled() should reflect STATE.toasts == false")
M.toast("PR #999", "should not fire either")
drain_timers()
assert(#jobs == 0, "STATE.toasts == false must suppress the toast")
local now = M.toggle()
assert(now == true, "M.toggle() should flip back to enabled")
assert(M.enabled() == true, "M.enabled() should now be true")

-- 4. Coalescing: two toast() calls with the same title inside the window
-- produce exactly one jobstart call, with "(+1 more)" appended.
jobs, timers = {}, {}
M.toast("PR #7", "first")
M.toast("PR #7", "second")
assert(#jobs == 0, "coalesced toasts must not fire before the timer")
drain_timers()
assert(#jobs == 1, "two toasts with the same title should collapse into one call, got " .. #jobs)
line = last_job_cmd_line()
assert(line:find("(+1 more)", 1, true), "the coalesced call should report the extra toast: " .. line)
assert(line:find("first", 1, true), "the coalesced call should keep the first toast's body: " .. line)

-- 5. A different title starts its own, independent window.
jobs, timers = {}, {}
M.toast("PR #1", "a")
M.toast("PR #2", "b")
drain_timers()
assert(#jobs == 2, "distinct titles must not coalesce, got " .. #jobs)

-- 6. Linux backend: notify-send used when present, nothing spawned when absent.
env._has_win32 = false
env._has_mac = false
env._executables = { ["notify-send"] = true }
jobs, timers = {}, {}
M.toast("PR #5", "linux body")
drain_timers()
assert(#jobs == 1, "notify-send should be invoked on Linux when present")
assert(jobs[1].cmd[1] == "notify-send", "Linux backend should call notify-send")

env._executables = {}
jobs, timers = {}, {}
M.toast("PR #6", "no backend available")
drain_timers()
assert(#jobs == 0, "a missing backend must be a silent no-op, not an error")

-- 7. M.flash: default "float" mode opens a non-focusable floating window
-- (nvim_open_win with focusable=false) and tracks it in STATE.flashes -
-- shared state, the same table notify.lua's own flash stack lives in, so
-- inspecting it here doesn't need anything notify.lua doesn't already
-- expose to every requirer of state.lua.
jobs, timers, notifies = {}, {}, {}
M.flash("Opening PR #1 in browser\u{2026}")
assert(#STATE.flashes == 1, "a float-mode flash should be tracked in STATE.flashes, got " .. #STATE.flashes)
assert(fake_wins[STATE.flashes[1].win].config.focusable == false, "a flash window must be non-focusable")
assert(#notifies == 0, "an INFO flash must not also go through vim.notify")

-- 8. MAX_FLASH eviction: a 5th push while 4 are already showing dismisses
-- the oldest right away instead of queueing/blocking.
STATE.flashes = {}
local first_msg_win
for i = 1, 5 do
  M.flash("message " .. i)
  if i == 1 then first_msg_win = STATE.flashes[1].win end
end
assert(#STATE.flashes == 4, "at most 4 flashes should be showing at once, got " .. #STATE.flashes)
assert(not fake_wins[first_msg_win].valid,
  "the oldest flash (message 1) should have been evicted once the 5th arrived")

-- 9. Dismiss ordering: two flashes started in order, each with the timer
-- delay its level implies (errors longer than info), both dismissed by
-- draining the timers in the order they were queued.
STATE.flashes = {}
timers = {}
M.flash("first (info)", vim.log.levels.INFO)
M.flash("second (error)", vim.log.levels.ERROR)
assert(#STATE.flashes == 2, "expected both flashes to be showing, got " .. #STATE.flashes)
assert(timers[1].ms == 3000, "an INFO flash should dismiss after 3s, got " .. tostring(timers[1].ms))
assert(timers[2].ms == 6000, "an ERROR flash should dismiss after 6s (longer), got " .. tostring(timers[2].ms))
local first_win, second_win = STATE.flashes[1].win, STATE.flashes[2].win
drain_timers()
assert(#STATE.flashes == 0, "both flashes should be gone after their timers fire, got " .. #STATE.flashes)
assert(not fake_wins[first_win].valid, "the first flash's window should have closed")
assert(not fake_wins[second_win].valid, "the second flash's window should have closed")

-- 10. An ERROR-level flash also goes through vim.notify(text, ERROR)
-- unconditionally, so :messages keeps it even after the float dismisses.
STATE.flashes = {}
notifies = {}
M.flash("provider call failed", vim.log.levels.ERROR)
assert(#notifies == 1, "an ERROR flash should also vim.notify, got " .. #notifies .. " calls")
assert(notifies[1].msg == "provider call failed" and notifies[1].level == vim.log.levels.ERROR,
  "the vim.notify call should carry the same text/level")

-- 11. setup({notifications = "notify"}) turns M.flash into a plain
-- vim.notify pass-through - no floating window at all.
local CONFIG = require("azure-cli.config")
CONFIG.setup({ notifications = "notify" })
STATE.flashes = {}
notifies = {}
M.flash("plain status", vim.log.levels.INFO)
assert(#STATE.flashes == 0, "notifications=\"notify\" must not open a float, got " .. #STATE.flashes)
assert(#notifies == 1 and notifies[1].msg == "plain status",
  "notifications=\"notify\" should route the message through vim.notify instead")
CONFIG.setup({ notifications = "float" })  -- leave the shared config module as found

print("notify ok: " .. #jobs .. " jobs in the last (empty-backend) check")
