-- tests/test-boards.lua - headless nvim, on a tests/fake-provider.py
-- workspace (tests/run.sh wires it up like demo.sh): I, the Issues tab,
-- exists only when --boards says a GitHub account has issues:.
--
--   BOARDS_EXPECT=azure   the workspace's config trimmed to its Azure
--                         account: no I in any key map, help or palette,
--                         and open_all() opens three home tabs
--   BOARDS_EXPECT=issues  the demo config as is: I is bound on the PR
--                         dashboard, W and Agents, open_all() opens four
--                         tabs, and I goes to the Issues tab
--
-- Prints BOARDS-TEST-OK, or BOARDS-TEST-FAIL: <why>.
-- Run by `nvim --headless -u <ws>/init.lua -c "luafile tests/test-boards.lua"`.

local expect = vim.env.BOARDS_EXPECT or "issues"
local issues = expect == "issues"

local function fail(why)
  print("BOARDS-TEST-FAIL: " .. why)
  vim.cmd("qa!")
end

-- Azure only: the demo config without its GitHub account (the fake's
-- --boards reads the config like azure-cli.py's boards()).
if not issues then
  local path = vim.env.XDG_CONFIG_HOME .. "/azure-cli.yml"
  local kept = {}
  for _, l in ipairs(vim.fn.readfile(path)) do
    if l:find("^%s*%- host: github") then break end
    kept[#kept + 1] = l
  end
  vim.fn.writefile(kept, path)
end

local HOME = require("azure-cli.home")
local BOARD = require("azure-cli.workitems.board")
vim.o.columns = 140
HOME.open_all()
if not vim.wait(10000, function() return BOARD.has_issues() ~= nil end, 50) then
  return fail("--boards never answered")
end
if BOARD.has_issues() ~= issues then
  return fail("--boards said issues = " .. tostring(BOARD.has_issues()) .. ", expected " .. tostring(issues))
end
-- What --boards unlocks is bound on the next tick.
vim.wait(300, function() return false end, 50)

local function buf_of(ft)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == ft then return b end
  end
end
local function home_tabs()
  local n = 0
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype
      if ft == "azurecli-dashboard" or ft == "azurecli-workitems" or ft == "azurecli-issues" or ft == "azurecli-agents" then
        n = n + 1
        break
      end
    end
  end
  return n
end
local want_tabs = issues and 4 or 3
if not vim.wait(10000, function() return home_tabs() == want_tabs end, 50) then
  return fail("open_all() opened " .. home_tabs() .. " home tabs, expected " .. want_tabs)
end

-- Each home screen: I bound or not, and in ? and the g. palette or not.
local function float_text()
  local parts = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      parts[#parts + 1] = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
    end
  end
  return table.concat(parts, "\n")
end
local function close_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
  end
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
for _, ft in ipairs({ "azurecli-dashboard", "azurecli-workitems", "azurecli-agents" }) do
  local b = buf_of(ft)
  if not b then return fail("no " .. ft .. " buffer") end
  vim.cmd("tab sbuffer " .. b)
  local bound = vim.fn.maparg("I", "n", false, true)
  bound = type(bound) == "table" and bound.buffer == 1
  if bound ~= issues then return fail(ft .. ": I bound = " .. tostring(bound) .. ", expected " .. tostring(issues)) end
  feed("?")
  local help = float_text()
  close_floats()
  if help == "" then return fail(ft .. ": ? showed no help") end
  if (help:find("issues", 1, true) ~= nil) ~= issues then
    return fail(ft .. ": the help " .. (issues and "doesn't list" or "lists") .. " I\n" .. help)
  end
  local labels = {}
  local real_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    for _, it in ipairs(items) do labels[#labels + 1] = opts.format_item and opts.format_item(it) or tostring(it) end
    cb(nil)
  end
  feed("g.")
  vim.ui.select = real_select
  local palette = table.concat(labels, "\n")
  if palette == "" then return fail(ft .. ": g. offered nothing") end
  if (palette:find("(I)", 1, true) ~= nil) ~= issues then
    return fail(ft .. ": the palette " .. (issues and "doesn't offer" or "offers") .. " I\n" .. palette)
  end
end

-- I goes to the Issues tab (and W back from it).
if issues then
  vim.cmd("tab sbuffer " .. buf_of("azurecli-workitems"))
  feed("I")
  if not vim.wait(5000, function() return vim.bo.filetype == "azurecli-issues" end, 50) then
    return fail("I didn't go to the Issues tab (ft " .. vim.bo.filetype .. ")")
  end
  feed("W")
  if not vim.wait(5000, function() return vim.bo.filetype == "azurecli-workitems" end, 50) then
    return fail("W from the Issues tab didn't go back (ft " .. vim.bo.filetype .. ")")
  end
end

print("BOARDS-TEST-OK")
vim.cmd("qa!")
