-- test-ide.lua: chat/ide.lua - opening an agent's worktree in your IDE
-- (chat.ide): the command it runs, and how it starts it. Needs vim.fn, so
-- it runs under a real headless Neovim:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-ide.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local IDE = require("azure-cli.chat.ide")

-- --- the command ---------------------------------------------------------------
do
  local cmd = IDE.command({ "code", "-n", "{dir}" }, "/w/repo-101")
  check("command: a list gets the folder", vim.deep_equal(cmd, { "code", "-n", "/w/repo-101" }), vim.inspect(cmd))
  cmd = IDE.command({ "code" }, "/w/repo-101")
  check("command: a list without {dir} ends with it", vim.deep_equal(cmd, { "code", "/w/repo-101" }), vim.inspect(cmd))
  cmd = IDE.command("devenv.exe {dir}", "/w/my repo")
  check("command: a shell string quotes it", cmd == "devenv.exe " .. vim.fn.shellescape("/w/my repo"), cmd)
  cmd = IDE.command("idea", "/w/x")
  check("command: a shell string without {dir} ends with it", cmd == "idea " .. vim.fn.shellescape("/w/x"), cmd)
end

-- --- opening -------------------------------------------------------------------
do
  local config = require("azure-cli.config")
  local notified = {}
  local NOTIFY = require("azure-cli.shell")
  local real_notify = NOTIFY.notify
  NOTIFY.notify = function(msg) notified[#notified + 1] = msg end
  local started
  local real_jobstart = vim.fn.jobstart
  vim.fn.jobstart = function(cmd, opts) started = { cmd = cmd, opts = opts } return 7 end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  config.setup({ chat = {} })
  IDE.open(dir)
  check("open: no ide set says so", started == nil and (notified[#notified] or ""):find("chat.ide", 1, true) ~= nil,
    notified[#notified])

  config.setup({ chat = { ide = { "code", "{dir}" } } })
  IDE.open(dir)
  check("open: starts it detached, in the folder", started and vim.deep_equal(started.cmd, { "code", dir })
    and started.opts.detach == true and started.opts.cwd == dir, vim.inspect(started))

  started = nil
  IDE.open(dir .. "/gone")
  check("open: a folder that isn't there", started == nil and (notified[#notified] or ""):find("isn't there", 1, true) ~= nil,
    notified[#notified])
  IDE.open(nil)
  check("open: no worktree yet", started == nil and (notified[#notified] or ""):find("No worktree", 1, true) ~= nil,
    notified[#notified])

  vim.fn.jobstart = function() return -1 end
  IDE.open(dir)
  check("open: says when it can't start it", (notified[#notified] or ""):find("Couldn't start code", 1, true) ~= nil,
    notified[#notified])

  -- A whole command in one list item: says why, and how to write it.
  config.setup({ chat = { ide = { "code -n {dir}" } } })
  vim.fn.jobstart = function() error("Vim:E475: Invalid value for argument cmd: 'code -n x' is not executable") end
  IDE.open(dir)
  local msg = notified[#notified] or ""
  check("open: the reason it couldn't start", msg:find("is not executable", 1, true) ~= nil, msg)
  check("open: a list item with spaces is one argument", msg:find('one list item per argument, or a string: "code -n {dir}"', 1, true) ~= nil, msg)

  -- The launcher starts, then fails.
  config.setup({ chat = { ide = { "code", "{dir}" } } })
  vim.fn.jobstart = function(cmd, opts) started = { cmd = cmd, opts = opts } return 9 end
  IDE.open(dir)
  started.opts.on_exit(9, 0)
  local quiet = #notified
  started.opts.on_exit(9, 2)
  vim.wait(200, function() return #notified > quiet end)
  check("open: a launcher that fails says so", #notified == quiet + 1 and notified[#notified]:find("code exited with 2", 1, true) ~= nil,
    notified[#notified])
  vim.fn.jobstart, NOTIFY.notify = real_jobstart, real_notify
end

-- --- keys ----------------------------------------------------------------------
do
  local KEYS = require("azure-cli.keys")
  check("keys: gI on the Agents screen", KEYS.resolve("agents", "open_ide") == "gI", vim.inspect(KEYS.resolve("agents", "open_ide")))
  check("keys: gI in the plan", KEYS.resolve("plan", "open_ide") == "gI")
  -- The Agents screen binds it, with the worktree of the agent under the cursor.
  pcall(require("azure-cli.chat.agents_view").open)
  local abuf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "azurecli-agents" then abuf = b end
  end
  local mapped = abuf and vim.api.nvim_buf_call(abuf, function() return vim.fn.maparg("gI", "n", false, true) end)
  check("keys: the Agents screen binds gI", type(mapped) == "table" and mapped.desc ~= nil
    and mapped.desc:find("IDE", 1, true) ~= nil, vim.inspect(mapped))
end

if fails > 0 then
  print(fails .. " ide test(s) failed")
  os.exit(1)
end
print("all ide tests passed")
