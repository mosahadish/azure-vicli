-- lua/azure-cli/chat/bridge.lua: the local TCP endpoint `azure-cli.py --mcp`
-- relays the chat agent's tool calls to.
--
-- The agent (Claude Code, the Copilot CLI, ...) starts `azure-cli.py --mcp`
-- from the MCP config chat/init.lua writes; that process knows nothing
-- itself and forwards every tools/list and tools/call here, one JSON line
-- per connection: {"token", "method": "list"|"call", "name", "arguments"}
-- in, {"tools"} / {"text", "error"} out. Listening on 127.0.0.1 with a
-- random port and a random token (both handed to the agent's environment
-- through that config), so only processes started from this Neovim can
-- call in. Handlers run on the main loop and may answer later (a tool
-- waiting on a provider job, or on the user approving a write).
local M = {}

local uv = vim.uv or vim.loop

-- M.handler(req, reply) is set by chat/init.lua: req is the decoded request
-- (token already checked), reply(tbl) sends the answer and closes.
M.handler = nil
-- One handler per extra agent (a plan's own agent, chat/init.lua's
-- conversations): a request whose "agent" names one goes there instead.
M.handlers = {}

-- Routes requests carrying agent id `id` to `fn`; nil removes it.
function M.route(id, fn) M.handlers[id] = fn end

local server, port, token
local clients = {}  -- open connections, closed by M.stop

local function random_token()
  local parts = {}
  math.randomseed(os.time() + math.floor((uv.hrtime() or 0) % 100000))
  for _ = 1, 4 do parts[#parts + 1] = string.format("%08x", math.random(0, 0x7fffffff)) end
  return table.concat(parts)
end

-- A new random agent id.
function M.new_id() return random_token():sub(1, 16) end

-- Starts listening (once per session) and returns "127.0.0.1:<port>",
-- token - or nil plus why.
function M.ensure()
  if server then return "127.0.0.1:" .. port, token end
  local s = uv.new_tcp()
  local okc, bound, err = pcall(s.bind, s, "127.0.0.1", 0)
  if not okc or not bound then
    err = okc and err or bound
    pcall(function() s:close() end)
    return nil, "could not open the chat bridge: " .. tostring(err)
  end
  token = random_token()
  local listened, lerr = s:listen(16, function(e)
    if e then return end
    local client = uv.new_tcp()
    s:accept(client)
    clients[client] = true
    local buf = ""
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        clients[client] = nil
        pcall(function() client:close() end)
        return
      end
      buf = buf .. chunk
      local nl = buf:find("\n", 1, true)
      if not nl then return end
      local line = buf:sub(1, nl - 1)
      client:read_stop()
      local answered = false
      local function reply(tbl)
        if answered then return end
        answered = true
        local okj, text = pcall(vim.json.encode, tbl)
        if not okj then text = vim.json.encode({ text = "internal error encoding the answer", error = true }) end
        client:write(text .. "\n", function()
          clients[client] = nil
          pcall(function() client:close() end)
        end)
      end
      vim.schedule(function()
        local okd, req = pcall(vim.json.decode, line)
        if not okd or type(req) ~= "table" then return reply({ text = "malformed request", error = true }) end
        if req.token ~= token then return reply({ text = "bad token", error = true }) end
        local handler = (req.agent and req.agent ~= "") and M.handlers[req.agent] or M.handler
        if not handler then
          return reply({ text = (req.agent and req.agent ~= "") and "that agent's conversation is gone"
            or "the chat isn't running", error = true })
        end
        local okh, herr = pcall(handler, req, reply)
        if not okh then reply({ text = "azure-vicli error: " .. tostring(herr), error = true }) end
      end)
    end)
  end)
  if not listened then
    pcall(function() s:close() end)
    return nil, "could not listen for the chat bridge: " .. tostring(lerr)
  end
  server = s
  port = s:getsockname().port
  return "127.0.0.1:" .. port, token
end

-- Closes the listener and every connection still open - a relay waiting
-- on an answer (a question you never got to) then sees the connection end
-- and exits, instead of keeping Neovim from quitting: it shares the
-- agent's stderr, which Neovim waits on.
function M.stop()
  for c in pairs(clients) do pcall(function() c:close() end) end
  clients = {}
  if server then pcall(function() server:close() end) end
  server, port, token = nil, nil, nil
end

return M
