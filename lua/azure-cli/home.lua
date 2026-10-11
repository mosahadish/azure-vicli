-- lua/azure-cli/home.lua: the three home screens - Pull requests, Work
-- items, Agents - each in a tab of its own, so P / W / A (and the tab
-- line) switch between them instead of swapping one screen for another.
-- The standalone launcher opens all three at startup and keeps them the
-- first three tabs, in that order; in your own Neovim they're opened as
-- you go to them and stay where they are.
--
--   M.go(name)    goes to "prs" / "workitems" / "agents", opening it if needed
--   M.open_all()  opens the ones not open yet, then comes back here; from
--                 then on every new tab (a PR, a plan) goes after them
--   M.order()     moves the open ones to the front, in order (standalone)
local M = {}

M.SCREENS = {
  { name = "prs", ft = "azurecli-dashboard", open = function() require("azure-cli.dashboard").open() end },
  { name = "workitems", ft = "azurecli-workitems",
    open = function() require("azure-cli.workitems.dashboard").open() end },
  -- Opens a tab of its own (or goes to its tab).
  { name = "agents", ft = "azurecli-agents", own_tab = true,
    open = function() require("azure-cli.chat.agents_view").open() end },
}

local function screen(name)
  for i, s in ipairs(M.SCREENS) do if s.name == name then return s, i end end
end

local function tab_of(ft)
  return require("azure-cli.ui").find_tab(function(b) return vim.bo[b].filetype == ft end)
end

-- Without the tab and buffer autocmds that moving around would fire (the
-- chat panel follows you into every tab you enter).
local function quietly(fn)
  local ei = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok, err = pcall(fn)
  vim.o.eventignore = ei
  if not ok then error(err) end
end

function M.order()
  if not require("azure-cli").is_standalone() then return end
  local tab, win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  quietly(function()
    local pos = 0
    for _, s in ipairs(M.SCREENS) do
      local t = tab_of(s.ft)
      if t then
        vim.api.nvim_set_current_tabpage(t)
        vim.cmd("tabmove " .. pos)
        pos = pos + 1
      end
    end
    vim.api.nvim_set_current_tabpage(tab)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  end)
  vim.cmd("redrawtabline")
end

function M.go(name)
  local s = screen(name)
  if not s then return end
  local tab, win = tab_of(s.ft)
  if tab then
    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_set_current_win(win)
    return
  end
  if not s.own_tab then vim.cmd("tabnew") end
  s.open()
  M.order()
end

function M.open_all()
  local tab, win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  for _, s in ipairs(M.SCREENS) do
    if not tab_of(s.ft) then
      if not s.own_tab then vim.cmd("tabnew") end
      s.open()
    end
  end
  M.order()
  if vim.api.nvim_tabpage_is_valid(tab) then vim.api.nvim_set_current_tabpage(tab) end
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  -- A tab opened next to one of them (a PR from the dashboard) would
  -- otherwise land in between: put them back in front once it's built.
  vim.api.nvim_create_autocmd("TabNew", {
    group = vim.api.nvim_create_augroup("AzureCliHomeTabs", { clear = true }),
    callback = function() vim.schedule(M.order) end,
  })
end

return M
