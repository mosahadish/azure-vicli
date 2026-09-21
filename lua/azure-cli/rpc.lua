-- lua/azure-cli/rpc.lua: shared RPC client for the python data provider's
-- --serve daemon (azure-cli.py --serve - see that file's own header comment
-- for the wire protocol this mirrors). require()'d by the dashboard,
-- reviewer, work-items dashboard/view and lua/azure-cli/cache.lua, the same
-- way as lua/azure-cli/cache.lua/notify.lua - require() caches the module,
-- so every requirer shares ONE daemon process and its pending-request table
-- (kept in lua/azure-cli/state.lua, like the content caches in cache.lua).
--
-- M.run(argv, opts) is a drop-in replacement for vim.fn.jobstart(argv, opts)
-- exactly as this codebase already calls it: opts.env (table), opts.detach
-- (ignored here - the daemon finishes the write either way, it isn't a
-- process this nvim owns the lifetime of), opts.stdout_buffered/
-- stderr_buffered (always treated as buffered - a daemon response only ever
-- arrives once, whole, never streamed), opts.on_stdout(_, lines)/
-- opts.on_stderr(_, lines)/opts.on_exit(_, code). When argv looks like a
-- call to the data provider (argv[2] ends in "azure-cli.py" - what
-- EXT.provider/PROVIDER_CMD/provider_argv all build) and the daemon is
-- usable, the request goes over the daemon's stdin instead of spawning a
-- fresh python process; anything else (git, "start"/"open" browser calls,
-- ...) falls straight through to a real vim.fn.jobstart, unchanged.
--
-- Lifecycle: the daemon (`<python> <azure-cli.py> --serve`, one persistent
-- process shared by every dashboard/reviewer/work-item view in this nvim
-- session) is started lazily by the first M.run call that needs it, using
-- that call's own argv[1]/argv[2] (python interpreter + provider path) -
-- whichever caller gets there first. If it dies (on_exit fires), every
-- request still waiting on it fails right away (on_exit(-1) plus a stderr
-- line); the NEXT M.run call gets one immediate restart attempt, and if
-- THAT also dies, every call falls back to plain jobstart for
-- FALLBACK_COOLDOWN_S seconds before a restart is tried again. Setting
-- AZVICLI_NO_DAEMON=1 in the environment disables the daemon entirely
-- (M.run always falls back to jobstart) - useful to debug a call without
-- the daemon in the loop. The daemon is stopped (jobstop) on VimLeavePre,
-- via an autocmd created once, so it never outlives the nvim session.
--
-- Wire protocol (one JSON object per line, both directions - see
-- azure-cli.py's serve()):
--   -> {"id": <int>, "argv": [...], "env": {...}}   (argv: everything after
--       the provider path/interpreter; env: the AZVICLI_*/AZVICLI_WI_* overrides
--       for this call only, e.g. AZVICLI_ORG/AZVICLI_PR/AZVICLI_PREFETCH -
--       merged over the daemon's own environment server-side)
--   <- {"id": <int>, "code": <int>, "stdout": "...", "stderr": "..."}
-- Responses can arrive out of order (independent requests run concurrently
-- server-side); M.run matches them back up to their caller by id, not order.

local M = {}
local STATE = require("azure-cli.state")

local DEFAULT_TIMEOUT_MS = 120000  -- per-request timeout: on expiry, on_exit(-1) + a stderr line
local FALLBACK_COOLDOWN_S = 30     -- how long a second consecutive daemon death is avoided before retrying

-- Shared state, in lua/azure-cli/state.lua so every requirer of this module
-- (dashboard, reviewer, work-item views) talks to the same daemon and
-- pending-request table - exactly the pattern cache.lua uses for its
-- content caches.
local function state()
  STATE.rpc = STATE.rpc or {
    job = nil,              -- vim.fn.jobstart job id of the running daemon, or nil
    pending = {},            -- request id -> { opts, timer, done }
    next_id = 1,
    buf = "",                -- partial stdout line waiting on more chunks (see feed_lines)
    fallback_until = 0,      -- os.time() epoch; M.run falls back to jobstart while now() < this
    restarted_once = false,  -- whether the daemon has already had its one immediate retry
    autocmd_set = false,
  }
  return STATE.rpc
end

-- True for argv shaped like { python, .../azure-cli.py, ... } - what
-- EXT.provider/PROVIDER_CMD/provider_argv build everywhere in this repo.
-- Anything else (git, a browser "start"/"open" call, ...) isn't ours to
-- route, so M.run falls through to a plain jobstart for it.
local function is_provider_argv(argv)
  return type(argv) == "table" and type(argv[2]) == "string" and argv[2]:match("azure%-cli%.py$") ~= nil
end

-- table.empty()/next() isn't in this test suite's allowed-globals list, so
-- "no keys at all" is a plain pairs() scan instead.
local function is_empty_table(t)
  for _ in pairs(t) do return false end
  return true
end

local function now() return os.time() end

local function in_fallback_window(st)
  return now() < st.fallback_until
end

-- jobstart's buffered on_stdout/on_stderr shape: the whole text split on
-- "\n", with a trailing "" element when the text ends in a newline (and a
-- single "" element for empty text) - see the callers below.
local function buffered_lines(text)
  return vim.split(text or "", "\n", { plain = true })
end

-- Delivers one finished response to the request that's still waiting on it
-- (scheduled, like every job callback nvim itself delivers on the main loop).
local function deliver(req, resp)
  local opts = req.opts
  vim.schedule(function()
    if opts.on_stdout then opts.on_stdout(0, buffered_lines(resp.stdout)) end
    if opts.on_stderr then opts.on_stderr(0, buffered_lines(resp.stderr)) end
    if opts.on_exit then opts.on_exit(0, resp.code or -1) end
  end)
end

-- Fails a still-pending request (daemon died, or its response timed out)
-- the same shape a real jobstart failure would: an on_exit(-1), plus one
-- line of explanation on stderr.
local function fail_request(req, message)
  local opts = req.opts
  vim.schedule(function()
    if opts.on_stderr then opts.on_stderr(0, { message, "" }) end
    if opts.on_exit then opts.on_exit(0, -1) end
  end)
end

local function settle(st, id, fn)
  local req = st.pending[id]
  if not req or req.done then return end
  req.done = true
  st.pending[id] = nil
  if req.timer then pcall(vim.fn.timer_stop, req.timer) end
  fn(req)
end

-- One complete response line off the daemon's stdout.
local function on_response_line(st, line)
  if line == "" then return end
  local ok, resp = pcall(vim.json.decode, line)
  if not ok or type(resp) ~= "table" or resp.id == nil then return end
  settle(st, resp.id, function(req) deliver(req, resp) end)
end

-- Reassembles daemon stdout chunks into complete lines: jobstart splits
-- output arbitrarily across on_stdout calls, so the first element of a new
-- chunk continues whatever the previous chunk's last element left pending
-- (st.buf), and the new chunk's own last element becomes the next pending
-- fragment (empty when the chunk ended exactly on a newline).
local function feed_lines(st, data)
  if not data or #data == 0 then return {} end
  local merged = { (st.buf or "") .. data[1] }
  for i = 2, #data do merged[#merged + 1] = data[i] end
  local lines = {}
  for i = 1, #merged - 1 do lines[#lines + 1] = merged[i] end
  st.buf = merged[#merged]
  return lines
end

-- Every request still waiting on a daemon that just died fails right away -
-- there is no response coming for any of them.
local function fail_all_pending(st, why)
  local pending = st.pending
  st.pending = {}
  for _, req in pairs(pending) do
    if req.timer then pcall(vim.fn.timer_stop, req.timer) end
    fail_request(req, why)
  end
end

local function handle_exit(st, code)
  fail_all_pending(st, "provider daemon exited (code " .. tostring(code) .. ")")
  st.job = nil
  st.buf = ""
  if st.restarted_once then
    -- Second death in a row without a clean run in between: stop retrying
    -- for a while so a persistently broken daemon doesn't respawn on every
    -- single provider call.
    st.fallback_until = now() + FALLBACK_COOLDOWN_S
    st.restarted_once = false
  else
    -- First death: the very next M.run gets one immediate restart attempt.
    st.restarted_once = true
  end
end

-- Starts the daemon using THIS call's own interpreter/provider path (argv[1]/
-- argv[2] - whichever caller gets here first supplies them; every call site
-- in this repo resolves the same AZVICLI_PY/AZVICLI_PROVIDER, so it never
-- matters which one actually wins the race).
local function start_daemon(st, argv)
  st.buf = ""
  -- pcall: jobstart raises (E475 "not executable") rather than returning
  -- -1 when argv[1] is a path that doesn't exist - a bad setup({python=})
  -- or no python at all - and that must fall through to spawn()'s own
  -- reporting, not error out of whichever dashboard action called M.run.
  local ok, job = pcall(vim.fn.jobstart, { argv[1], argv[2], "--serve" }, {
    stdin = "pipe",
    on_stdout = function(_, data)
      for _, line in ipairs(feed_lines(st, data)) do on_response_line(st, line) end
    end,
    on_stderr = function() end,  -- daemon-level diagnostics; nothing here depends on them
    on_exit = function(_, code) handle_exit(st, code) end,
  })
  if ok and type(job) == "number" and job > 0 then
    st.job = job
  else
    st.job = nil
    st.fallback_until = now() + FALLBACK_COOLDOWN_S
  end
end

-- Stops the daemon when nvim exits, so it never outlives the session -
-- created once (guarded by st.autocmd_set), the first time M.run needs it.
local function ensure_autocmd(st)
  if st.autocmd_set then return end
  st.autocmd_set = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if st.job then pcall(vim.fn.jobstop, st.job) end
    end,
  })
end

-- A plain jobstart that can't spawn at all (argv[1] not on PATH - the
-- usual case being no python - or not executable) returns 0/-1 and never
-- fires on_exit, which once left a dashboard on "Loading…" forever with
-- its in-flight flag stuck. This delivers that failure through the same
-- on_stderr/on_exit callbacks a real exit would, on the next tick, so
-- every caller's error path runs and the user is told what didn't start.
local function spawn(argv, opts)
  local ok, job = pcall(vim.fn.jobstart, argv, opts)
  if ok and type(job) == "number" and job > 0 then return job end
  vim.schedule(function()
    local what = tostring(argv[1] or "?")
    local msg = "could not start '" .. what .. "'"
    local not_exec = (not ok) and tostring(job):find("not executable", 1, true)
    if job == 0 or ((not ok) and not not_exec) then
      msg = msg .. " (invalid arguments" .. ((not ok) and (": " .. tostring(job)) or "") .. ")"
    else
      msg = msg .. " - is it installed and on PATH? (:AzureCli status shows the interpreter in use)"
    end
    if opts.on_stderr then opts.on_stderr(-1, { msg, "" }, "stderr") end
    if opts.on_exit then opts.on_exit(-1, 127, "exit") end
  end)
  return -1
end

local function send_request(st, argv, opts)
  local id = st.next_id
  st.next_id = id + 1
  local request_argv = {}
  for i = 3, #argv do request_argv[#request_argv + 1] = argv[i] end
  -- vim.json.encode can't tell an empty Lua table apart from an array or
  -- an object and defaults to "[]" - fine for request_argv (an empty argv
  -- really should be "[]"), wrong for env, which the daemon requires to be
  -- a JSON object even when there's nothing in it (see serve()'s own
  -- malformed-request check) - vim.empty_dict() forces the "{}" encoding.
  -- A one-shot jobstart inherits Neovim's environment at spawn time, and
  -- the reviewer relies on that: the dashboard sets AZVICLI_PR/ORG/... in
  -- vim.env when a PR is opened and the reviewer's --threads/--post calls
  -- pass no env of their own. The daemon was spawned earlier and never
  -- sees those later changes, so forward every current AZVICLI_* variable
  -- with each request (explicit opts.env still wins) - otherwise the
  -- daemon answers "AZVICLI_ORG not set" for every reviewer action.
  local payload_env = {}
  for name, value in pairs(vim.fn.environ()) do
    if name:sub(1, 8) == "AZVICLI_" then payload_env[name] = value end
  end
  for name, value in pairs(opts.env or {}) do payload_env[name] = value end
  if is_empty_table(payload_env) then payload_env = vim.empty_dict() end
  local payload = { id = id, argv = request_argv, env = payload_env }
  local ok = pcall(vim.fn.chansend, st.job, vim.json.encode(payload) .. "\n")
  if not ok then
    -- The channel died synchronously (e.g. between ensure/start and here) -
    -- this one call falls back rather than waiting on a response that will
    -- never come; on_exit above will have already started the cooldown/retry
    -- bookkeeping for the daemon itself.
    return spawn(argv, opts)
  end

  local req = { opts = opts, done = false }
  local timeout_ms = opts.rpc_timeout_ms or DEFAULT_TIMEOUT_MS
  req.timer = vim.fn.timer_start(timeout_ms, function()
    settle(st, id, function(r) fail_request(r, "provider request timed out") end)
  end)
  st.pending[id] = req
  return st.job
end

-- M.run(argv, opts): see this file's header comment for the full contract.
function M.run(argv, opts)
  opts = opts or {}
  local st = state()

  if vim.env.AZVICLI_NO_DAEMON == "1" then
    return spawn(argv, opts)
  end
  if not is_provider_argv(argv) then
    return spawn(argv, opts)
  end
  if in_fallback_window(st) then
    return spawn(argv, opts)
  end

  if not st.job then
    start_daemon(st, argv)
    if not st.job then
      return spawn(argv, opts)
    end
  end

  ensure_autocmd(st)
  return send_request(st, argv, opts)
end

-- M.status(): for the "?" help popup / a notify - see azure-cli.lua's ?.
function M.status()
  local st = state()
  local pid = nil
  if st.job then
    local ok, p = pcall(vim.fn.jobpid, st.job)
    if ok then pid = p end
  end
  local running = st.job ~= nil
  return {
    running = running,
    fallback = (not running) or in_fallback_window(st),
    pid = pid,
  }
end

return M
