-- test-shell.lua: lua/azure-cli/shell.lua's open_url without vim.ui.open
-- (Neovim 0.9, #51): it starts xdg-open / open itself, detached.
-- Usage: luajit test-shell.lua <shell.lua path>
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local path = arg[1]
assert(path, "usage: luajit test-shell.lua <shell.lua path>")

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

local jobs, has, exe, job_id = {}, {}, {}, 7
_G.vim = {
  ui = {},
  fn = {
    has = function(f) return has[f] and 1 or 0 end,
    executable = function(x) return exe[x] and 1 or 0 end,
    jobstart = function(argv, opts) jobs[#jobs + 1] = { argv = argv, opts = opts } return job_id end,
  },
}
local S = dofile(path)

exe["xdg-open"] = true
local ok, why = S.open_url("https://example.com/pr/1")
check("0.9, linux: xdg-open starts", ok == true and #jobs == 1, why)
check("0.9, linux: argv is xdg-open <url>", jobs[1] and jobs[1].argv[1] == "xdg-open"
  and jobs[1].argv[2] == "https://example.com/pr/1")
check("0.9, linux: detached", jobs[1] and jobs[1].opts.detach == true)

jobs, has.mac, exe.open = {}, true, true
ok = S.open_url("https://example.com/pr/2")
check("0.9, macOS: open starts", ok == true and jobs[1] and jobs[1].argv[1] == "open")

jobs, has.mac = {}, nil
exe["xdg-open"] = nil
ok, why = S.open_url("https://example.com/pr/3")
check("0.9, no xdg-open: false with a reason", ok == false and tostring(why):find("xdg-open", 1, true) ~= nil and #jobs == 0, why)

exe["xdg-open"], job_id = true, 0
ok, why = S.open_url("https://example.com/pr/4")
check("0.9, jobstart fails: false with a reason", ok == false and why ~= nil, why)

jobs, job_id = {}, 7
local opened
vim.ui.open = function(u) opened = u return {} end
ok = S.open_url("https://example.com/pr/5")
check("0.10+: vim.ui.open is used, nothing spawned", ok == true and opened == "https://example.com/pr/5" and #jobs == 0)

check("no URL", S.open_url("") == false)

if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("all ok")
