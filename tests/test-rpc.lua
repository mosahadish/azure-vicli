-- test-rpc.lua: drives rpc.lua's M.run/M.status with a shimmed `vim`
-- (fn.jobstart/fn.chansend/fn.timer_start/fn.timer_stop/fn.jobpid recording
-- everything they're called with, api.nvim_create_autocmd recording the
-- callback instead of registering a real one, schedule() queuing callbacks
-- for the test to drain by hand instead of nvim's event loop, and a minimal
-- json.encode/decode good enough for the plain {id, argv, env}/{id, code,
-- stdout, stderr} shapes the wire protocol uses) so the daemon-routing,
-- line-reassembly and lifecycle/fallback logic can be checked without a
-- real nvim or a real azure-cli.py --serve process.
--
-- Usage: luajit test-rpc.lua <rpc.lua path>
--
-- Checks: provider argv is routed to the daemon with the right JSON (argv
-- tail + env), non-provider argv (e.g. git) falls straight through to
-- jobstart, chunked/partial stdout is reassembled into complete lines and
-- dispatched to the right pending request by id even when two responses
-- land in the same chunk or arrive out of order, the buffered on_stdout/
-- on_stderr line shape (trailing "" / no trailing "" / a single "" for
-- empty output) matches real jobstart, a daemon exit fails every pending
-- request and the next M.run call retries starting it exactly once before
-- falling back for the cooldown window, a per-request timeout fails the
-- request and drops a late response that arrives after it, and
-- AZVICLI_NO_DAEMON=1 always falls back to plain jobstart.

assert(arg[1], "usage: luajit test-rpc.lua <rpc.lua>")

-- ---------------------------------------------------------------------------
-- Minimal JSON codec - just enough for {id, argv, env} (strings/numbers/
-- arrays/objects of strings) and {id, code, stdout, stderr} shapes.
-- ---------------------------------------------------------------------------

local function json_encode(v)
  local t = type(v)
  if t == "string" then
    local s = v:gsub('[%z\1-\31\\"]', function(c)
      if c == "\\" then return "\\\\" end
      if c == '"' then return '\\"' end
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
  elseif t == "number" then
    return tostring(v)
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    local n = #v
    if n > 0 then
      local parts = {}
      for i = 1, n do parts[i] = json_encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function json_decode(s)
  local i = 1
  local n = #s
  local parse_value

  local function skip_ws()
    while i <= n and s:sub(i, i):match("%s") do i = i + 1 end
  end

  local function parse_string()
    i = i + 1
    local out = {}
    while i <= n do
      local c = s:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(out)
      elseif c == "\\" then
        local nc = s:sub(i + 1, i + 1)
        if nc == "n" then out[#out + 1] = "\n"
        elseif nc == "t" then out[#out + 1] = "\t"
        elseif nc == "r" then out[#out + 1] = "\r"
        else out[#out + 1] = nc end
        i = i + 2
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    error("unterminated JSON string")
  end

  local function parse_number()
    local start = i
    while i <= n and s:sub(i, i):match("[%d%.%-%+eE]") do i = i + 1 end
    return tonumber(s:sub(start, i - 1))
  end

  local function parse_array()
    i = i + 1
    local arr = {}
    skip_ws()
    if s:sub(i, i) == "]" then i = i + 1; return arr end
    while true do
      skip_ws()
      arr[#arr + 1] = parse_value()
      skip_ws()
      local c = s:sub(i, i)
      if c == "," then i = i + 1
      elseif c == "]" then i = i + 1; break
      else error("bad JSON array at " .. i) end
    end
    return arr
  end

  local function parse_object()
    i = i + 1
    local obj = {}
    skip_ws()
    if s:sub(i, i) == "}" then i = i + 1; return obj end
    while true do
      skip_ws()
      local key = parse_string()
      skip_ws()
      assert(s:sub(i, i) == ":", "expected ':' in JSON object")
      i = i + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = s:sub(i, i)
      if c == "," then i = i + 1
      elseif c == "}" then i = i + 1; break
      else error("bad JSON object at " .. i) end
    end
    return obj
  end

  parse_value = function()
    skip_ws()
    local c = s:sub(i, i)
    if c == '"' then return parse_string() end
    if c == "{" then return parse_object() end
    if c == "[" then return parse_array() end
    if c == "t" then i = i + 4; return true end
    if c == "f" then i = i + 5; return false end
    if c == "n" then i = i + 4; return nil end
    return parse_number()
  end

  skip_ws()
  return parse_value()
end

-- ---------------------------------------------------------------------------
-- vim shim.
-- ---------------------------------------------------------------------------

local jobs = {}        -- job id -> { cmd, opts }, every vim.fn.jobstart call
local sent = {}         -- job id -> { data, data, ... }, every vim.fn.chansend payload
local timers = {}       -- timer id -> { ms, cb, stopped }
local scheduled = {}    -- queued vim.schedule callbacks, drained by hand
local autocmds = {}     -- event -> { opts, ... }
local next_job_id = 1
local next_timer_id = 1

local function reset_shim()
  jobs, sent, timers, scheduled, autocmds = {}, {}, {}, {}, {}
  next_job_id, next_timer_id = 1, 1
  -- rpc.lua's shared daemon state lives in lua/azure-cli/state.lua now
  -- (require()d, resolved through LUA_PATH - see tests/run.sh) instead of a
  -- bare global of its own; require() caches by module name, so this reaches
  -- the very same table rpc.lua itself reads/writes.
  require("azure-cli.state").rpc = nil
end

local function drain_scheduled()
  local pending = scheduled
  scheduled = {}
  for _, fn in ipairs(pending) do fn() end
end

local function vim_split(s, sep, _opts)
  local out = {}
  local start = 1
  while true do
    local found = s:find(sep, start, true)
    if not found then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, found - 1)
    start = found + #sep
  end
  return out
end

vim = {
  env = {},
  split = vim_split,
  schedule = function(fn) scheduled[#scheduled + 1] = fn end,
  json = { encode = json_encode, decode = json_decode },
  -- Real nvim's vim.empty_dict() forces a table to encode as JSON "{}"
  -- instead of vim.json.encode's ambiguous-empty-table default of "[]" -
  -- this shim's own json_encode already treats every empty table as "{}",
  -- so a plain table is a faithful enough stand-in here.
  empty_dict = function() return {} end,
  fn = {
    -- The module forwards every AZVICLI_* variable of the editor's live
    -- environment with each daemon request (the daemon never sees vim.env
    -- changes made after it was spawned); the shim serves vim.env as that.
    environ = function() return vim.env end,
    jobstart = function(cmd, opts)
      local id = next_job_id
      next_job_id = next_job_id + 1
      jobs[id] = { cmd = cmd, opts = opts or {} }
      return id
    end,
    chansend = function(job_id, data)
      assert(jobs[job_id], "chansend to an unknown job id")
      sent[job_id] = sent[job_id] or {}
      sent[job_id][#sent[job_id] + 1] = data
      return #data
    end,
    jobstop = function(job_id)
      if jobs[job_id] then jobs[job_id].stopped = true end
      return 1
    end,
    jobpid = function(job_id)
      assert(jobs[job_id], "jobpid of an unknown job id")
      return 4242
    end,
    timer_start = function(ms, cb)
      local id = next_timer_id
      next_timer_id = next_timer_id + 1
      timers[id] = { ms = ms, cb = cb, stopped = false }
      return id
    end,
    timer_stop = function(id)
      if timers[id] then timers[id].stopped = true end
    end,
  },
  api = {
    nvim_create_autocmd = function(event, opts)
      autocmds[event] = autocmds[event] or {}
      autocmds[event][#autocmds[event] + 1] = opts
    end,
  },
}

local M = dofile(arg[1])
local PROVIDER_ARGV = { "python3", "/x/azure-cli.py" }
local function provider_call(...)
  local a = { PROVIDER_ARGV[1], PROVIDER_ARGV[2] }
  for _, v in ipairs({ ... }) do a[#a + 1] = v end
  return a
end

-- 1. Provider argv is routed to the daemon with the right JSON request.
reset_shim()
do
  local out_calls, err_calls, exit_calls = {}, {}, {}
  local argv = provider_call("--threads")
  local opts = {
    env = { AZVICLI_ORG = "https://dev.azure.com/org", AZVICLI_PR = "5" },
    on_stdout = function(_, lines) out_calls[#out_calls + 1] = lines end,
    on_stderr = function(_, lines) err_calls[#err_calls + 1] = lines end,
    on_exit = function(_, code) exit_calls[#exit_calls + 1] = code end,
  }
  M.run(argv, opts)
  assert(#jobs == 1, "the first provider call should start the daemon")
  assert(jobs[1].cmd[1] == "python3" and jobs[1].cmd[2] == "/x/azure-cli.py" and jobs[1].cmd[3] == "--serve",
    "daemon should be started as <python> <provider> --serve")
  assert(jobs[1].opts.stdin == "pipe", "daemon job should have a writable stdin pipe")

  assert(sent[1] and #sent[1] == 1, "expected exactly one chansend to the daemon")
  local req = json_decode(sent[1][1])
  assert(req.id == 1, "first request should be id 1")
  assert(#req.argv == 1 and req.argv[1] == "--threads", "argv sent should be the provider tail, not python/azure-cli.py")
  assert(req.env.AZVICLI_ORG == "https://dev.azure.com/org", "env should carry the caller's AZVICLI_* overrides")
  assert(req.env.AZVICLI_PR == "5")

  -- Simulate the daemon's response line arriving whole.
  local resp = json_encode({ id = 1, code = 0, stdout = "a\nb\n", stderr = "" })
  jobs[1].opts.on_stdout(1, { resp, "" })
  drain_scheduled()
  assert(#out_calls == 1 and #out_calls[1] == 3 and out_calls[1][1] == "a" and out_calls[1][2] == "b"
    and out_calls[1][3] == "", "on_stdout should get the buffered lines plus a trailing \"\"")
  assert(#err_calls == 1 and #err_calls[1] == 1 and err_calls[1][1] == "", "empty stderr should still deliver a single \"\"")
  assert(#exit_calls == 1 and exit_calls[1] == 0, "on_exit should carry the response's code")
end

-- 2. Non-provider argv (git, browser-open, ...) falls straight through to jobstart.
reset_shim()
do
  M.run({ "git", "-C", "/repo", "status" }, { stdout_buffered = true })
  assert(#jobs == 1 and jobs[1].cmd[1] == "git", "a git argv must bypass the daemon entirely")
  assert(next(sent) == nil, "a git call must never go through chansend")
end

-- 3. Chunked/partial stdout is reassembled, and two responses landing in the
--    same chunk (in reverse completion order) are both matched by id.
reset_shim()
do
  local got = { [1] = {}, [2] = {} }
  local function opts_for(n)
    return { on_stdout = function(_, lines) got[n].stdout = lines end,
             on_stderr = function(_, lines) got[n].stderr = lines end,
             on_exit = function(_, code) got[n].code = code end }
  end
  M.run(provider_call("--wi-list"), opts_for(1))   -- id 1
  M.run(provider_call("--wi-detail", "9"), opts_for(2))  -- id 2, same (already-running) daemon
  assert(#jobs == 1, "a second provider call must reuse the already-running daemon, not start another")
  assert(sent[1] and #sent[1] == 2, "both requests should have been sent to the same daemon job")

  local resp1 = json_encode({ id = 1, code = 0, stdout = "one\n", stderr = "" })
  local resp2 = json_encode({ id = 2, code = 0, stdout = "two\n", stderr = "" })
  local combined = resp2 .. "\n" .. resp1 .. "\n"  -- id 2's response completes FIRST, out of request order
  -- Split the raw bytes at an arbitrary mid-object offset (not on a "\n"),
  -- the way a real partial socket/pipe read would, and feed each half
  -- through on_stdout the way jobstart delivers it: split-on-"\n" per chunk.
  local cut = #resp2 - 5
  local chunk_a, chunk_b = combined:sub(1, cut), combined:sub(cut + 1)
  jobs[1].opts.on_stdout(1, vim_split(chunk_a, "\n"))
  assert(got[2].code == nil and got[1].code == nil, "no complete line yet - nothing should have dispatched")
  jobs[1].opts.on_stdout(1, vim_split(chunk_b, "\n"))
  drain_scheduled()
  assert(got[2].code == 0 and got[2].stdout[1] == "two", "id 2's response should be delivered to request 2")
  assert(got[1].code == 0 and got[1].stdout[1] == "one", "id 1's response should still be delivered to request 1, despite arriving second")
end

-- 4. Buffered on_stdout/on_stderr line shapes: trailing "" newline, no
--    trailing "" (output didn't end in a newline), and a lone "" for empty output.
reset_shim()
do
  local out
  M.run(provider_call("--ping"), { on_stdout = function(_, lines) out = lines end })
  jobs[1].opts.on_stdout(1, { json_encode({ id = 1, code = 0, stdout = "pong", stderr = "" }), "" })
  drain_scheduled()
  assert(#out == 1 and out[1] == "pong", "stdout with no trailing newline should have no trailing \"\"")

  reset_shim()
  M.run(provider_call("--ping"), { on_stdout = function(_, lines) out = lines end })
  jobs[1].opts.on_stdout(1, { json_encode({ id = 1, code = 0, stdout = "", stderr = "" }), "" })
  drain_scheduled()
  assert(#out == 1 and out[1] == "", "empty stdout should be a single \"\" element")
end

-- 5. A daemon exit fails every pending request, and the next M.run call
--    restarts it exactly once before falling back for the cooldown window.
reset_shim()
do
  local exits = {}
  local argv = provider_call("--threads")
  M.run(argv, { on_exit = function(_, code) exits[#exits + 1] = code end })
  assert(#jobs == 1)
  jobs[1].opts.on_exit(1, 7)  -- the daemon process died
  drain_scheduled()
  assert(#exits == 1 and exits[1] == -1, "a request still pending when the daemon dies must fail with -1")

  M.run(argv, {})
  assert(#jobs == 2, "the next call after a daemon death should retry starting it once")

  jobs[2].opts.on_exit(2, 9)  -- the retry also died
  local before = #jobs
  M.run(argv, {})
  assert(#jobs == before + 1, "a second consecutive death should fall back to a plain jobstart, not a third daemon start")
  assert(jobs[#jobs].cmd[3] == "--threads", "the fallback call should run the plain provider argv, not --serve")
end

-- 6. Per-request timeout: fails the request, and a late response that
--    arrives after the timeout is dropped instead of double-delivering.
reset_shim()
do
  local exits, errs = {}, {}
  local argv = provider_call("--threads")
  M.run(argv, {
    on_exit = function(_, code) exits[#exits + 1] = code end,
    on_stderr = function(_, lines) errs[#errs + 1] = lines end,
  })
  assert(#timers == 1, "M.run should start a per-request timeout timer")
  assert(timers[1].ms == 120000, "default timeout should be 120000ms")

  timers[1].cb()  -- fire the timeout
  drain_scheduled()
  assert(#exits == 1 and exits[1] == -1, "a timed-out request must fail with -1")
  assert(#errs == 1 and errs[1][1]:find("timed out", 1, true), "a timed-out request must explain why on stderr")

  -- The daemon's response arrives anyway, after the timeout already fired.
  jobs[1].opts.on_stdout(1, { json_encode({ id = 1, code = 0, stdout = "late\n", stderr = "" }), "" })
  drain_scheduled()
  assert(#exits == 1, "a late response after the timeout must be dropped, not delivered a second time")

  -- opts.rpc_timeout_ms overrides the default.
  reset_shim()
  M.run(argv, { rpc_timeout_ms = 5000 })
  assert(timers[1].ms == 5000, "rpc_timeout_ms should override the default per-request timeout")
end

-- 7. AZVICLI_NO_DAEMON=1 always falls back to plain jobstart.
reset_shim()
do
  vim.env.AZVICLI_NO_DAEMON = "1"
  local argv = provider_call("--threads")
  M.run(argv, {})
  assert(#jobs == 1 and jobs[1].cmd[1] == "python3" and jobs[1].cmd[3] == "--threads",
    "AZVICLI_NO_DAEMON=1 must run the plain provider argv directly")
  assert(next(sent) == nil, "AZVICLI_NO_DAEMON=1 must never talk to a daemon")
  vim.env.AZVICLI_NO_DAEMON = nil
end

-- 8. M.status(): stopped/fallback before any call, running (with a pid)
--    once the daemon has been started.
reset_shim()
do
  local st0 = M.status()
  assert(st0.running == false and st0.fallback == true, "status before any call should report not running")
  M.run(provider_call("--threads"), {})
  local st1 = M.status()
  assert(st1.running == true and st1.pid == 4242, "status after a successful start should report running + pid")
end

-- 9. The daemon is stopped on VimLeavePre, registered exactly once even
--    across multiple M.run calls.
reset_shim()
do
  M.run(provider_call("--threads"), {})
  M.run(provider_call("--iterations"), {})
  assert(autocmds.VimLeavePre and #autocmds.VimLeavePre == 1, "VimLeavePre should be registered exactly once")
  autocmds.VimLeavePre[1].callback()
  assert(jobs[1].stopped == true, "VimLeavePre should jobstop the running daemon")
end

-- 10. A jobstart that can't spawn at all (no python on PATH) still
--     reports through on_stderr/on_exit on the next tick, so no caller is
--     ever left waiting on a job that never started.
reset_shim()
do
  local real_jobstart = vim.fn.jobstart
  vim.fn.jobstart = function() return -1 end
  vim.env.AZVICLI_NO_DAEMON = "1"
  local errs, exits = {}, {}
  local ret = M.run(provider_call("--threads"), {
    on_stderr = function(_, d) for _, l in ipairs(d) do if l ~= "" then errs[#errs + 1] = l end end end,
    on_exit = function(_, code) exits[#exits + 1] = code end,
  })
  assert(ret == -1, "a failed spawn returns -1 like jobstart does")
  assert(#exits == 0, "the failure is delivered on the next tick, not synchronously")
  drain_scheduled()
  assert(#exits == 1 and exits[1] ~= 0, "on_exit fires with a non-zero code for a failed spawn")
  assert(#errs == 1 and errs[1]:find("could not start 'python3'", 1, true), "on_stderr names what didn't start: " .. tostring(errs[1]))
  vim.fn.jobstart = real_jobstart
  vim.env.AZVICLI_NO_DAEMON = nil
end

print("test-rpc.lua: OK")

-- The editor's current AZVICLI_* environment rides along with every
-- request, with explicit opts.env winning; unrelated variables don't.
do
  reset_shim()
  vim.env.AZVICLI_ORG = "https://dev.azure.com/from-vim-env"
  vim.env.AZVICLI_PR = "77"
  vim.env.HOME = "/nope"
  M.run({ "python3", "/x/azure-cli.py", "--threads" }, { env = { AZVICLI_PR = "78" } })
  local job
  for id, j in pairs(jobs) do
    if j.cmd[3] == "--serve" then job = id end
  end
  assert(job and sent[job] and #sent[job] > 0, "a request was sent to the daemon")
  local req = json_decode(sent[job][#sent[job]])
  assert(req.env.AZVICLI_ORG == "https://dev.azure.com/from-vim-env", "vim.env AZVICLI_* forwarded")
  assert(req.env.AZVICLI_PR == "78", "explicit opts.env wins over vim.env")
  assert(req.env.HOME == nil, "non-AZVICLI_ variables are not forwarded")
  vim.env.AZVICLI_ORG = nil
  vim.env.AZVICLI_PR = nil
  vim.env.HOME = nil
  print("ok: live AZVICLI_* env forwarded per request")
end
