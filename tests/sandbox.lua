-- tests/sandbox.lua - keeps a test away from the real Neovim directories
-- and from the environment it was started in, however it was started
-- (nvim -l, nvim -c luafile, plain luajit, CI or tests/run.sh).
--
-- Every tests/*.lua loads it as its first statement (tests/run.sh's
-- "sandbox guard" check fails on one that doesn't):
--
--   dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
--
-- Unless the test already runs in a sandbox (AZVICLI_TEST_SANDBOX is set
-- and XDG_DATA/STATE/CACHE/CONFIG_HOME and HOME are all under it), this runs
-- the same command line again with fresh XDG directories and an empty HOME
-- in a temp dir (so nothing reads the real ~/.claude/skills, ~/.gitconfig
-- and the like) and without VIM, VIMRUNTIME, NVIM, MYVIMRC, NVIM_LOG_FILE or any
-- AZVICLI_CHAT_*, passes its output through, removes the temp dir and exits
-- with its exit code. (nvim exports NVIM_LOG_FILE to its children: kept,
-- the sandboxed nvim would log to the parent's file, in the real state
-- dir, instead of under its own XDG_STATE_HOME.) Doing
-- it in-process is not enough: nvim picks its runtime and shada at startup,
-- and several modules work out their stdpath("data") files when required.
--
-- Scripts loaded into an nvim a harness already set up with a fake
-- workspace (test-boards.lua, demo-smoke.lua, shot-*.lua: tests/demo.sh
-- and tests/run.sh export AZVICLI_TEST_SANDBOX=<workspace>) can't start
-- again - their config is in that workspace - so they pass
-- { attach = true }: then a test outside a sandbox stops instead. Those
-- check only the XDG dirs, not HOME: their harness owns the environment,
-- and the interactive tests/demo.sh keeps the real HOME so a real agent
-- opened from the demo's chat keeps its login (run.sh's harnesses and
-- demo.sh --headless give them an empty one).
--
-- POSIX only (sh -c, mktemp -d, sh quoting), like tests/run.sh, so there's
-- no USERPROFILE to set: the tests don't run on Windows.
local XDG = { "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME" }

local function sandboxed(attach)
  local root = os.getenv("AZVICLI_TEST_SANDBOX")
  if not root or root == "" then return false end
  local vars = { unpack(XDG) }
  if not attach then vars[#vars + 1] = "HOME" end
  for _, v in ipairs(vars) do
    local dir = os.getenv(v)
    if not dir or dir:sub(1, #root + 1) ~= root .. "/" then return false end
  end
  return true
end

local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- The command line this process was started with.
local function argv()
  local out = {}
  if type(vim) == "table" and vim.v and vim.api then
    out[1] = vim.v.progpath
    for i = 2, #vim.v.argv do out[#out + 1] = vim.v.argv[i] end
  else
    local first = 0
    while arg[first - 1] do first = first - 1 end
    for i = first, #arg do out[#out + 1] = arg[i] end
  end
  return out
end

-- os.execute's result: (true|nil, "exit"|"signal", n) in Lua 5.2 style,
-- a raw wait status in LuaJIT's default 5.1 style.
local function exit_code(a, how, n)
  if type(a) == "number" then return a > 255 and math.floor(a / 256) or a end
  if how == "signal" then return 128 + (n or 0) end
  return n or (a and 0 or 1)
end

return function(opts)
  if sandboxed(opts and opts.attach) then
    if type(vim) == "table" and vim.fn and vim.fn.environ then
      for k in pairs(vim.fn.environ()) do
        if k:match("^AZVICLI_CHAT_") then vim.env[k] = nil end
      end
    end
    return
  end
  if opts and opts.attach then
    io.stderr:write("tests/sandbox.lua: refusing to run outside a sandbox (XDG dirs not under AZVICLI_TEST_SANDBOX)"
      .. " - start this through tests/run.sh or tests/demo.sh\n")
    os.exit(1)
  end
  local p = io.popen('mktemp -d "${TMPDIR:-/tmp}/azvicli-test.XXXXXX"')
  local dir = p and p:read("*l")
  if p then p:close() end
  if not dir or dir == "" then
    io.stderr:write("tests/sandbox.lua: mktemp -d failed\n")
    os.exit(1)
  end
  local cmd = {}
  for _, a in ipairs(argv()) do cmd[#cmd + 1] = quote(a) end
  local d = quote(dir)
  local script = table.concat({
    "unset VIM VIMRUNTIME NVIM MYVIMRC NVIM_LOG_FILE",
    [[for v in $(env | sed -n 's/^\(AZVICLI_CHAT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done]],
    "mkdir -p " .. d .. "/data " .. d .. "/state " .. d .. "/cache " .. d .. "/config " .. d .. "/home",
    "export AZVICLI_TEST_SANDBOX=" .. d .. " XDG_DATA_HOME=" .. d .. "/data XDG_STATE_HOME=" .. d .. "/state"
      .. " XDG_CACHE_HOME=" .. d .. "/cache XDG_CONFIG_HOME=" .. d .. "/config HOME=" .. d .. "/home",
    table.concat(cmd, " "),
    "s=$?",
    "rm -rf " .. d,
    "exit $s",
  }, "\n")
  io.stdout:flush()
  os.exit(exit_code(os.execute("sh -c " .. quote(script))))
end
