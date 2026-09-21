-- tests/demo-smoke.lua - the headless half of tests/demo.sh (--headless):
-- with the fake provider wired up by demo.sh, open the dashboard, wait for
-- the fake PRs to render (through the --serve daemon and the warm-all
-- prefetch), open PR 101 in the reviewer via the same path <CR> takes,
-- wait for its file list, and print both buffers plus a DEMO-SMOKE-OK
-- marker. Any timeout prints DEMO-SMOKE-FAIL with what was on screen.
-- Run by `nvim --headless -u <ws>/init.lua -c "luafile tests/demo-smoke.lua"`.

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function find_buf(ft)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == ft then return b end
  end
  return nil
end

local function fail(why, buf)
  print("DEMO-SMOKE-FAIL: " .. why)
  if buf then print(text(buf)) end
  vim.cmd("qa!")
end

vim.cmd("AzureCli dashboard")
local dash = find_buf("azurecli-dashboard")
if not dash then return fail("no dashboard buffer") end

local ok = vim.wait(15000, function()
  local t = text(dash)
  return t:find("#101", 1, true) ~= nil and t:find("#201", 1, true) ~= nil
end, 100)
if not ok then return fail("the dashboard never listed the fake PRs #101 and #201", dash) end
print("== dashboard ==")
print(text(dash))

require("azure-cli").open_review(101)
local files
ok = vim.wait(20000, function()
  files = find_buf("azurecli-files")
  if not files then return false end
  local t = text(files)
  return t:find("auth.py", 1, true) ~= nil and t:find("throttle.py", 1, true) ~= nil
end, 100)
if not ok then return fail("the reviewer never listed PR #101's files", files) end
print("== reviewer file list (PR #101) ==")
print(text(files))
print("DEMO-SMOKE-OK")
vim.cmd("qa!")
