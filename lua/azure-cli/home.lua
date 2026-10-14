-- lua/azure-cli/home.lua: the home screens - Pull requests, Work items,
-- Issues, Agents - each in a tab of its own, so P / W / I / A (and the tab
-- line) switch between them instead of swapping one screen for another.
-- Issues (a GitHub account's project, workitems/board.lua) is there only
-- when a GitHub account has an issues: block - an Azure-only setup has
-- three. The standalone launcher opens them all at startup and keeps them
-- the first tabs, in that order; in your own Neovim they're opened as
-- you go to them and stay where they are.
--
--   M.go(name)    goes to "prs" / "workitems" / "issues" / "agents", opening it if needed
--   M.open_all()  opens the ones not open yet, then comes back here; from
--                 then on every new tab (a PR, a plan) goes after them,
--                 and closing one goes back to the tab it was opened from
--   M.order()     moves the open ones to the front, in order, each followed
--                 by its inner tabs (innertabs.lua) (standalone)
--   M.tab(name)   the tab of an open home screen, or nil
local M = {}

M.SCREENS = {
  { name = "prs", ft = "azurecli-dashboard", open = function() require("azure-cli.dashboard").open() end },
  { name = "workitems", ft = "azurecli-workitems",
    open = function() require("azure-cli.workitems.dashboard").open() end },
  -- Only once --boards says a GitHub account has issues: (`when`).
  { name = "issues", ft = "azurecli-issues",
    open = function() require("azure-cli.workitems.dashboard").open("github") end,
    when = function() return require("azure-cli.workitems.board").has_issues() == true end },
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

function M.tab(name)
  local s = screen(name)
  return s and (tab_of(s.ft))
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
    local INNER = require("azure-cli.innertabs")
    for _, s in ipairs(M.SCREENS) do
      local t = tab_of(s.ft)
      if t then
        vim.api.nvim_set_current_tabpage(t)
        vim.cmd("tabmove " .. pos)
        pos = pos + 1
        -- Its inner tabs right after it, so gt and a tab line of your own
        -- keep them together.
        for _, m in ipairs(INNER.members(t)) do
          vim.api.nvim_set_current_tabpage(m.tab)
          vim.cmd("tabmove " .. pos)
          pos = pos + 1
        end
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
  if s.when and not s.when() then
    require("azure-cli.shell").notify("No GitHub account has an issues: block - add issues: { project: <number "
      .. "or title> } to one (gO) to get the Issues tab.", vim.log.levels.WARN)
    return
  end
  if not s.own_tab then vim.cmd("tabnew") end
  s.open()
  M.order()
end

function M.open_all()
  local tab, win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  for _, s in ipairs(M.SCREENS) do
    if not tab_of(s.ft) and (not s.when or s.when()) then
      if not s.own_tab then vim.cmd("tabnew") end
      s.open()
    end
  end
  M.order()
  if vim.api.nvim_tabpage_is_valid(tab) then vim.api.nvim_set_current_tabpage(tab) end
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  -- Issues opens once --boards answers that there are some (a moment
  -- after start-up), in its place after Work items.
  require("azure-cli.workitems.board").enabled(function()
    local s = screen("issues")
    if tab_of(s.ft) then return end
    local here, hwin = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
    vim.cmd("tabnew")
    s.open()
    M.order()
    if vim.api.nvim_tabpage_is_valid(here) then vim.api.nvim_set_current_tabpage(here) end
    if vim.api.nvim_win_is_valid(hwin) then vim.api.nvim_set_current_win(hwin) end
  end)
  -- A tab opened next to one of them (a PR from the dashboard) would
  -- otherwise land in between: put them back in front once it's built.
  local group = vim.api.nvim_create_augroup("AzureCliHomeTabs", { clear = true })
  -- Which tab each new one was opened from (tab handle -> tab handle), so
  -- closing it (q in a PR) goes back there rather than to its neighbour.
  local opened_from, leaving, fresh = {}, nil, false
  vim.api.nvim_create_autocmd("TabLeave", { group = group,
    callback = function() leaving = vim.api.nvim_get_current_tabpage() end })
  vim.api.nvim_create_autocmd("TabNew", { group = group, callback = function()
    fresh = true
    vim.schedule(M.order)
  end })
  vim.api.nvim_create_autocmd("TabEnter", { group = group, callback = function()
    if fresh and leaving then opened_from[vim.api.nvim_get_current_tabpage()] = leaving end
    fresh = false
  end })
  vim.api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
    local back
    local INNER = require("azure-cli.innertabs")
    for tab, from in pairs(opened_from) do
      if not vim.api.nvim_tabpage_is_valid(tab) then
        opened_from[tab] = nil
        -- An inner tab: innertabs.lua goes back to the one before it.
        if vim.api.nvim_tabpage_is_valid(from) and not INNER.owns(tab) then back = from end
      end
    end
    if back then vim.schedule(function()
      if vim.api.nvim_tabpage_is_valid(back) then vim.api.nvim_set_current_tabpage(back) end
    end) end
  end })
end

return M
