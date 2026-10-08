-- lua/azure-cli/chat/acp.lua: a minimal Agent Client Protocol (ACP) client
-- - JSON-RPC 2.0 over a subprocess's stdin/stdout, one JSON object per
-- line (https://agentclientprotocol.com). chat/init.lua's send_acp uses
-- this to keep one `copilot --acp` process warm for a whole conversation
-- instead of starting a fresh one each message (agent.acp = true).
--
-- Verified against a real `copilot --acp`: newline-delimited (no
-- Content-Length framing like LSP), `initialize` -> `session/new` ->
-- repeated `session/prompt` with `session/update` notifications streamed
-- in between, and `session/request_permission` as a request the agent
-- sends us mid-turn.
local M = {}

-- Starts `cmd` and returns a connection, or nil, err. `opts`: cwd, env.
-- `callbacks`:
--   on_notification(method, params)         - a one-way message
--   on_request(method, params, id)          - must eventually conn.respond(id, ...)
--   on_stderr(lines)
--   on_exit(code)
-- The connection:
--   conn.request(method, params, cb)   cb(result, err) - err is a string
--   conn.notify(method, params)
--   conn.respond(id, result, err)
--   conn.close()
--   conn.job
function M.connect(cmd, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local conn = { pending = {}, next_id = 0, buf = "" }

  local function handle_line(line)
    if line == "" then return end
    local ok, msg = pcall(vim.json.decode, line)
    if not ok or type(msg) ~= "table" then return end
    if msg.method and msg.id ~= nil then
      if callbacks.on_request then callbacks.on_request(msg.method, msg.params or {}, msg.id) end
    elseif msg.method then
      if callbacks.on_notification then callbacks.on_notification(msg.method, msg.params or {}) end
    elseif msg.id ~= nil then
      local cb = conn.pending[msg.id]
      conn.pending[msg.id] = nil
      if cb then
        if msg.error then cb(nil, type(msg.error) == "table" and (msg.error.message or vim.json.encode(msg.error)) or tostring(msg.error))
        else cb(msg.result or vim.empty_dict(), nil) end
      end
    end
  end

  local ok, job = pcall(vim.fn.jobstart, cmd, {
    cwd = opts.cwd, env = opts.env, stderr_buffered = false,
    on_stdout = function(_, d)
      if not d then return end
      conn.buf = conn.buf .. d[1]
      for i = 2, #d do
        handle_line(conn.buf)
        conn.buf = d[i]
      end
    end,
    on_stderr = function(_, d) if d and callbacks.on_stderr then callbacks.on_stderr(d) end end,
    on_exit = function(_, code)
      local pending = conn.pending
      conn.pending = {}
      for _, cb in pairs(pending) do pcall(cb, nil, "the agent process exited") end
      if callbacks.on_exit then callbacks.on_exit(code) end
    end,
  })
  if not ok or job <= 0 then return nil, "could not start the agent: " .. tostring(job) end
  conn.job = job

  function conn.request(method, params, cb)
    conn.next_id = conn.next_id + 1
    local id = conn.next_id
    conn.pending[id] = cb
    pcall(vim.fn.chansend, job, vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params }) .. "\n")
    return id
  end

  function conn.notify(method, params)
    pcall(vim.fn.chansend, job, vim.json.encode({ jsonrpc = "2.0", method = method, params = params }) .. "\n")
  end

  function conn.respond(id, result, err)
    local msg = { jsonrpc = "2.0", id = id }
    if err then msg.error = { code = -32000, message = tostring(err) } else msg.result = result or vim.empty_dict() end
    pcall(vim.fn.chansend, job, vim.json.encode(msg) .. "\n")
  end

  function conn.close()
    pcall(vim.fn.jobstop, job)
  end

  return conn
end

return M
