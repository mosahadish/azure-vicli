-- test-notify.lua: drives prdash-notify.lua's toast() with a shimmed `vim`
-- (fn.has/fn.executable/fn.jobstart recording the command, fn.timer_start
-- queuing its callback for the test to fire by hand instead of nvim's event
-- loop) so the coalescing/rate-limit behaviour can be checked without a
-- real nvim or a real OS notification backend.
--
-- Usage: luajit test-notify.lua <prdash-notify.lua path>
--
-- Checks: the Windows command line carries the escaped title/body and the
-- app id; embedded single quotes and XML metacharacters in the body are
-- escaped; the PRDASH_TOASTS=0 opt-out suppresses the call entirely; two
-- toast() calls with the same title inside the rate-limit window collapse
-- into one call whose body says "(+1 more)".

local jobs = {}       -- recorded vim.fn.jobstart command tables, in order
local timers = {}     -- queued fn.timer_start callbacks, drained by hand
local env = {}         -- vim.env shim, mutable by the test

vim = {
  env = env,
  fn = {
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
    timer_start = function(_, cb)
      timers[#timers + 1] = cb
      return #timers
    end,
  },
}

local function drain_timers()
  local pending = timers
  timers = {}
  for _, cb in ipairs(pending) do cb() end
end

local function last_job_cmd_line()
  assert(#jobs > 0, "expected a jobstart call")
  local cmd = jobs[#jobs].cmd
  local parts = {}
  for _, c in ipairs(cmd) do parts[#parts + 1] = c end
  return table.concat(parts, " \1 ")  -- \1 so a substring check can't false-match across args
end

assert(arg[1], "usage: luajit test-notify.lua <prdash-notify.lua>")

-- Windows path: has("win32") true, powershell present.
env._has_win32 = true
env._executables = { powershell = true }

local M = dofile(arg[1])

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
env.PRDASH_TOASTS = "0"
M.toast("PR #999", "should not fire")
drain_timers()
assert(#jobs == 0, "PRDASH_TOASTS=0 must suppress the toast")
env.PRDASH_TOASTS = nil

-- 3. Opt-out via _G.PRDASH_TOASTS == false, and M.toggle() flips it back.
jobs, timers = {}, {}
_G.PRDASH_TOASTS = false
assert(M.enabled() == false, "M.enabled() should reflect _G.PRDASH_TOASTS == false")
M.toast("PR #999", "should not fire either")
drain_timers()
assert(#jobs == 0, "_G.PRDASH_TOASTS == false must suppress the toast")
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

print("prdash-notify ok: " .. #jobs .. " jobs in the last (empty-backend) check")
