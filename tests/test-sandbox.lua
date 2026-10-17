-- test-sandbox.lua: tests/sandbox.lua's own probe. Started straight from a
-- polluted environment (XDG dirs at a sentinel "real" directory, a bogus
-- VIMRUNTIME, VIM/NVIM/MYVIMRC and AZVICLI_CHAT_* set), it checks it ended
-- up in a fresh sandbox instead, then writes a chat file the way the plugin
-- does - tests/run.sh then checks the sentinel directory stayed empty.
-- Runs under both plain luajit and a headless nvim:
--
--   luajit tests/test-sandbox.lua <sentinel dir>
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-sandbox.lua <sentinel dir>
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end
local function under(path, root) return path ~= nil and root ~= nil and path:sub(1, #root + 1) == root .. "/" end

local real = arg[1]
local root = os.getenv("AZVICLI_TEST_SANDBOX")
check("AZVICLI_TEST_SANDBOX is set", root and root ~= "")
for _, v in ipairs({ "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME" }) do
  check(v .. " is in the sandbox", under(os.getenv(v), root), os.getenv(v))
  if real then check(v .. " is not the real one", not under(os.getenv(v) .. "/", real), os.getenv(v)) end
end
check("HOME is in the sandbox", under(os.getenv("HOME"), root), os.getenv("HOME"))
if real then check("HOME is not the real one", not under(os.getenv("HOME") .. "/", real), os.getenv("HOME")) end

local env = {}
local p = io.popen("env")
for line in p:lines() do
  local k, v = line:match("^([%w_]+)=(.*)")
  if k then env[k] = v end
end
p:close()
local chat = {}
for k in pairs(env) do if k:match("^AZVICLI_CHAT_") then chat[#chat + 1] = k end end
check("no AZVICLI_CHAT_* reaches what the test starts", #chat == 0, table.concat(chat, " "))
check("no MYVIMRC", env.MYVIMRC == nil, env.MYVIMRC)
-- nvim sets NVIM_LOG_FILE for itself (under the sandbox's state dir); the
-- parent's must not get through.
check("NVIM_LOG_FILE is unset or in the sandbox", env.NVIM_LOG_FILE == nil
  or (under(env.NVIM_LOG_FILE, root) and not (real and under(env.NVIM_LOG_FILE, real))), env.NVIM_LOG_FILE)

local data
if type(vim) == "table" and vim.fn then
  -- nvim sets VIM and VIMRUNTIME for itself; they must be its own, not the parent's.
  check("VIMRUNTIME is this nvim's own", vim.env.VIMRUNTIME and not under(vim.env.VIMRUNTIME .. "/", real)
    and vim.fn.isdirectory(vim.env.VIMRUNTIME .. "/syntax") == 1, vim.env.VIMRUNTIME)
  check("no NVIM", vim.env.NVIM == nil, vim.env.NVIM)
  check("stdpath('data') is in the sandbox", under(vim.fn.stdpath("data"), root), vim.fn.stdpath("data"))
  data = require("azure-cli.chat.store").root()
  vim.fn.mkdir(data, "p")
else
  for _, v in ipairs({ "VIM", "VIMRUNTIME", "NVIM" }) do check("no " .. v, env[v] == nil, env[v]) end
  data = os.getenv("XDG_DATA_HOME") .. "/azure-cli-chat"
  os.execute("mkdir -p '" .. data .. "'")
end
check("the chat dir is in the sandbox", under(data, root), data)
local f = io.open(data .. "/sandbox-probe.json", "w")
check("can write a chat file", f ~= nil)
if f then f:write("{}\n"); f:close() end

if fails > 0 then
  print(fails .. " sandbox test(s) failed")
  os.exit(1)
end
print("all sandbox tests passed")
