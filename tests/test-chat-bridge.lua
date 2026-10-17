-- test-chat-bridge.lua: chat/bridge.lua over a real socket - a request with
-- the token reaches the handler, a wrong token doesn't, and a request that
-- grows past MAX_REQUEST without a newline is dropped (the bridge stays up
-- for the next one).
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-bridge.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local uv = vim.uv or vim.loop
local B = require("azure-cli.chat.bridge")
local fails = 0
local function check(name, ok, detail)
  if ok then print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail and ("\n     " .. tostring(detail)) or ""))
  end
end

local seen = {}
B.handler = function(req, reply)
  seen[#seen + 1] = req.name
  reply({ text = "hi " .. tostring(req.name) })
end
local addr, token = B.ensure()
check("the bridge listens, with a 32-hex-digit token", addr and token and token:match("^%x+$") and #token == 32, token)
local port = tonumber(addr:match(":(%d+)$"))

-- Sends `data` on a new connection: what came back (nil when nothing did)
-- and whether the bridge closed the connection.
local function talk(data)
  local got, closed = nil, false
  local c = uv.new_tcp()
  c:connect("127.0.0.1", port, function(err)
    if err then closed = true return end
    c:read_start(function(rerr, chunk)
      if rerr or not chunk then closed = true; pcall(function() c:close() end) return end
      got = (got or "") .. chunk
    end)
    c:write(data)
  end)
  vim.wait(3000, function() return closed end, 10)
  pcall(function() if not c:is_closing() then c:close() end end)
  return got, closed
end

local got = talk(vim.json.encode({ token = token, method = "call", name = "one" }) .. "\n")
check("a request with the token is answered", got and got:find("hi one", 1, true), got)
got = talk(vim.json.encode({ token = "nope", method = "call", name = "two" }) .. "\n")
check("a wrong token is refused", got and got:find("bad token", 1, true) and #seen == 1, got)

B.MAX_REQUEST = 4096
local got_big, closed = talk(string.rep("x", 20000))
check("past MAX_REQUEST without a newline: dropped, unanswered", closed and got_big == nil, got_big)
got = talk(vim.json.encode({ token = token, method = "call", name = "three" }) .. "\n")
check("and the bridge still answers the next one", got and got:find("hi three", 1, true), got)
B.stop()

print(fails == 0 and "all bridge tests passed" or (fails .. " bridge test(s) failed"))
vim.cmd(fails == 0 and "qa!" or "cq!")
