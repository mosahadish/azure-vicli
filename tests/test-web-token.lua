-- test-web-token.lua: the phone dashboard's token across restarts (#105),
-- end to end - web.lua starting the real `azure-cli.py --web-dashboard` in
-- a sandboxed stdpath("state"): two starts give the same URL, the stored
-- file is 0600, rotate changes the URL (running) or deletes the file
-- (stopped), an unsafe file is replaced with a warning, and the token is on
-- neither the server's argv nor in a message or :AzureCli log.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-web-token.lua
--
-- Prints "all web-token tests passed" / exits non-zero.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

-- The Agents screen's data, empty: only the server is under test here.
package.loaded["azure-cli.chat.agents"] = { queued = function() return {} end, working = function() return 0 end,
  max = function() return 2 end }
package.loaded["azure-cli.chat"] = { conversations = function() return {} end, restore_plans = function() end }
package.loaded["azure-cli.chat.plan"] = { load = function() end }

local uv = vim.uv or vim.loop
local floats, notes, jobs = {}, {}, {}
require("azure-cli.ui").open_float = function(lines) floats[#floats + 1] = table.concat(lines, "\n") end
require("azure-cli.shell").notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
local real_jobstart = vim.fn.jobstart
vim.fn.jobstart = function(argv, opts)
  local id = real_jobstart(argv, opts)
  jobs[#jobs + 1] = { argv = argv, id = id, pid = vim.fn.jobpid(id) }
  return id
end

local CONFIG = require("azure-cli.config")
CONFIG.setup({ dashboard_web = { enabled = true, bind = "127.0.0.1", port = 0 } })
local WEB = require("azure-cli.web")
local path = WEB.token_path()
check("the token file is under the sandbox's state dir", path:find(vim.env.XDG_STATE_HOME, 1, true) == 1, path)

local function token_in(text) return text and text:match("%?token=([%w_%-]+)") end
local function last_float() return floats[#floats] end
local function read_file()
  local fh = io.open(path, "r")
  if not fh then return nil end
  local s = fh:read("*a")
  fh:close()
  return vim.trim(s)
end

-- Starts it and returns the token in the URL it shows.
local function start()
  local before = #floats
  WEB.start()
  vim.wait(10000, function() return #floats > before end, 20)
  return token_in(last_float())
end
local function stop()
  WEB.stop(true)
  vim.wait(200, function() return false end, 20)
end
local function note_with(text)
  for _, n in ipairs(notes) do
    if n.msg:find(text, 1, true) then return n end
  end
end

-- Restarts keep the URL.
local first = start()
check("start shows a URL with a token", first and #first == 43, last_float())
check("the float doesn't explain where the token lives", not (last_float() or ""):find("token is", 1, true), last_float())
stop()
local second = start()
check("a restart keeps the token (same URL)", second == first, tostring(first) .. " vs " .. tostring(second))
check("the file holds it", read_file() == first)
local st = uv.fs_stat(path)
check("the file is 0600", st and st.mode % 512 == tonumber("600", 8), st and string.format("%o", st.mode % 512))

-- Never on argv.
local job = jobs[#jobs]
check("argv has the token file", vim.tbl_contains(job.argv, "--token-file") and vim.tbl_contains(job.argv, path))
check("argv has no token", not table.concat(job.argv, " "):find(first, 1, true))
local fh = io.open("/proc/" .. tostring(job.pid) .. "/cmdline", "rb")
if fh then
  local cmdline = fh:read("*a")
  fh:close()
  check("the server's /proc cmdline has no token", not cmdline:find(first, 1, true))
end

-- Rotate while running: a new URL, saved, said, shown.
local shown = #floats
WEB.rotate()
vim.wait(5000, function() return #floats > shown end, 20)
local rotated = token_in(last_float())
check("rotate re-shows the float with a new URL", rotated and rotated ~= first, rotated)
check("rotate says the old link is dead", note_with("token rotated") ~= nil)
check("rotate saved the new token", read_file() == rotated)
stop()
check("a restart after rotate keeps the rotated URL", start() == rotated)
stop()

-- Rotate while stopped: the file goes, the next start makes a new URL.
WEB.rotate()
check("rotate while stopped deletes the stored token", uv.fs_lstat(path) == nil and note_with("deleted") ~= nil)
local fresh = start()
check("the next start makes a new URL", fresh and fresh ~= rotated)
stop()

-- A file others can read is replaced, with a warning.
uv.fs_chmod(path, tonumber("644", 8))
local replaced = start()
local warn = note_with("wasn't safe to use")
check("a 0644 file: a new token and a warning", replaced ~= fresh and warn and warn.level == vim.log.levels.WARN,
  warn and warn.msg)
check("... and it's 0600 again", uv.fs_stat(path).mode % 512 == tonumber("600", 8))
stop()

-- Status while stopped says whether a token is stored.
WEB.status()
check("status while stopped: the token is stored", notes[#notes].msg:find("stored in", 1, true) ~= nil,
  notes[#notes].msg)

-- persist_token = false: nothing read or written.
os.remove(path)
CONFIG.setup({ dashboard_web = { enabled = true, bind = "127.0.0.1", port = 0, persist_token = false } })
local mem = start()
check("persist_token = false: no token file", mem and uv.fs_lstat(path) == nil)
check("persist_token = false: no --token-file on argv", not vim.tbl_contains(jobs[#jobs].argv, "--token-file"))
stop()
check("persist_token = false: the next start makes a new URL", start() ~= mem)
stop()

-- The token in no message and no :AzureCli log entry.
local said = {}
for _, n in ipairs(notes) do said[#said + 1] = n.msg end
for _, e in ipairs(require("azure-cli.log").entries()) do said[#said + 1] = vim.inspect(e) end
said = table.concat(said, "\n")
local leaked = {}
for _, t in ipairs({ first, rotated, fresh, replaced, mem }) do
  if said:find(t, 1, true) then leaked[#leaked + 1] = t end
end
check("no token in a message or the log", #leaked == 0, table.concat(leaked, ","))

if fails > 0 then
  print(fails .. " web-token test(s) failed")
  os.exit(1)
end
print("all web-token tests passed")
