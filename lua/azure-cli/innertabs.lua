-- lua/azure-cli/innertabs.lua: what's opened from a home tab (home.lua's
-- Pull requests, Work items, Issues, Agents) stays inside it, as inner
-- tabs. Each inner tab is still a tabpage of its own - so it keeps its
-- windows, cursor, folds and everything else while you're elsewhere, and
-- the chat panel follows into it like any tab - but it's grouped under its
-- home: the tab line shows only the home (ui.lua's M.tabline), and the
-- winbar of the widest window shows the strip
--
--   Pull requests │ !101 Fix auth │ [!102 Cache] ┃ <the window's own winbar>
--
-- (ui.lua's M.wo puts M.bar() in front of every winbar). ]r / [r go to the
-- next / previous one, g1..g9 to the n-th (g1 the home list), and closing
-- one (q) goes to the one before it, the list when there's none. Opening
-- an item that's already open goes to its inner tab.
--
-- An item goes to its kind's home, wherever it's opened from: a PR to Pull
-- requests, an Azure work item to Work items, a GitHub issue to Issues.
-- When that home isn't open (plugin mode, only the work items open), it
-- opens as a tab of its own, as before. One opened from outside its home
-- (gW in a review, the chat) goes back there when it's closed.
--
--   M.open(name, key, title, open_fn)  opens an item in home `name`
--   M.item_key(host, ref), M.item_home(host)  a work item's key and home
--   M.retitle(tab, key, title)  what the inner tab `tab` shows changed
--   M.goto_key(key)    goes to the inner tab showing `key`; true if it did
--   M.home_of(tab)     the home tab `tab` belongs to (itself for a home)
--   M.is_member(tab)   an inner tab (not a home); M.owns(tab) also for one
--                      just closed (home.lua's own close handling skips it)
--   M.cycle(dir), M.pick(n)  switch; M.bar()  the strip, for a winbar
--   M.closing()        a screen's close key, right before its :tabclose
--
-- The pure helpers (M.wrap, M.close_target, M.strip_text, M.item_key,
-- M.item_home) take no vim.* and are tested under plain luajit by
-- tests/test-innertabs.lua.
local M = {}

-- The homes whose items open as inner tabs (home.lua's screen names).
M.ENABLED = { prs = true, workitems = true, issues = true }

-- A work item's key: "wi:azure:3001", "wi:github:owner~repo~7" - never a
-- PR's (hosts.lua's key). Pure.
function M.item_key(host, ref)
  return "wi:" .. (host == "github" and "github" or "azure") .. ":" .. tostring(ref)
end

-- The home a work item of board `host` opens in. Pure.
function M.item_home(host)
  return host == "github" and "issues" or "workitems"
end

-- The n-th entry `dir` steps from `cur`, wrapping around (1..n). Pure.
function M.wrap(cur, dir, n)
  if n < 1 then return nil end
  return ((cur - 1 + dir) % n) + 1
end

-- Where closing member `i` (1-based, of the members) goes: the member
-- before it, 0 for the home. Pure.
function M.close_target(i)
  return math.max(0, i - 1)
end

-- Display cells of a UTF-8 string, close enough for titles (one per
-- character). Pure.
local function cells(s)
  return #(s:gsub("[\128-\191]", ""))
end

-- `s` cut to `n` cells, an ellipsis marking the cut. Pure.
local function cut(s, n)
  if cells(s) <= n then return s end
  local out, w = {}, 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if w + 1 > n - 1 then break end
    out[#out + 1] = ch
    w = w + 1
  end
  return table.concat(out) .. "\u{2026}"
end

local SEP = " \u{2502} "

-- The strip for `labels` (the home first) with entry `cur` marked [..],
-- fitted to `width` cells: every label gets an equal share, at least 8
-- cells, the current one never less than its own. Returns the 'winbar'
-- text (highlight groups, "%" escaped) and the plain text. Pure.
function M.strip_text(labels, cur, width)
  local n = #labels
  if n == 0 then return "", "" end
  local room = math.max(20, width) - (n - 1) * cells(SEP) - 2
  local share = math.max(8, math.floor(room / n))
  local fmt, plain = {}, {}
  for i, l in ipairs(labels) do
    local t = cut(l, i == cur and math.max(share, math.min(cells(l), 30)) or share)
    if i == cur then t = "[" .. t .. "]" end
    plain[i] = t
    fmt[i] = (i == cur and "%#AzureCliWinbarTitle#" or "%#AzureCliWinbar#") .. t:gsub("%%", "%%%%")
  end
  return " " .. table.concat(fmt, "%#AzureCliWinbarSep#" .. SEP) .. "%#AzureCliWinbarSep# \u{2503}%#AzureCliWinbar#",
    table.concat(plain, SEP)
end

-- Everything below needs Neovim.
if not vim or not vim.api then return M end

-- home tab -> { name, members = { { tab, key, title, from } } } in opening
-- order; `from` is the tab it was opened from when that's outside its home.
local groups = {}
local closed = {}  -- member tabs closed since the last tick (M.owns)
-- The tab a screen's own close key is closing (M.closing, just before its
-- :tabclose): at TabClosed, go back to the one before it. No event says
-- this reliably - :tabclose moves to a neighbour first and closes the
-- windows from there - and a tab closed in the background (:tabonly from
-- the list) must not pull you anywhere.
local closing_here

local function valid(tab) return tab and vim.api.nvim_tabpage_is_valid(tab) end

-- Drops members (and groups) whose tabs are gone.
local function prune()
  for home, g in pairs(groups) do
    if not valid(home) then
      groups[home] = nil
    else
      for i = #g.members, 1, -1 do
        if not valid(g.members[i].tab) then
          closed[g.members[i].tab] = true  -- M.owns, for home.lua's own TabClosed
          table.remove(g.members, i)
        end
      end
    end
  end
end

local function member(tab)
  for home, g in pairs(groups) do
    for i, m in ipairs(g.members) do
      if m.tab == tab then return home, i, m end
    end
  end
end

function M.is_member(tab)
  local home = member(tab)
  return home ~= nil and valid(home)
end

function M.owns(tab)
  return closed[tab] or member(tab) ~= nil or (closing_here ~= nil and closing_here.tab == tab)
end

-- The home name of a home tab, by its list's filetype (home.lua's SCREENS).
local function home_name(tab)
  for _, s in ipairs(require("azure-cli.home").SCREENS) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local ok, buf = pcall(vim.api.nvim_win_get_buf, w)
      if ok and vim.bo[buf].filetype == s.ft then return s.name end
    end
  end
end

function M.home_of(tab)
  tab = (tab == nil or tab == 0) and vim.api.nvim_get_current_tabpage() or tab
  local home = member(tab)
  if home and valid(home) then return home end
  local name = home_name(tab)
  if name and M.ENABLED[name] then return tab end
end

-- home's entries: the home itself, then its members.
function M.members(home)
  prune()
  local out = {}
  for _, m in ipairs((groups[home] or {}).members or {}) do out[#out + 1] = m end
  return out
end

local function entries(home)
  local list = { home }
  for _, m in ipairs(M.members(home)) do list[#list + 1] = m.tab end
  return list
end

local function index_of(list, tab)
  for i, t in ipairs(list) do if t == tab then return i end end
end

local function go(tab)
  if not valid(tab) then return end
  vim.api.nvim_set_current_tabpage(tab)
  vim.cmd("redrawtabline")
end

function M.goto_key(key)
  prune()
  for _, g in pairs(groups) do
    for _, m in ipairs(g.members) do
      if m.key == key then
        go(m.tab)
        return true
      end
    end
  end
  return false
end

-- Moves the current tab to just after home's last member.
local function place(home)
  local list = entries(home)
  local after = list[#list - 1] or home  -- the current tab is the last
  if not valid(after) then return end
  local ei = vim.o.eventignore
  vim.o.eventignore = "all"
  pcall(vim.cmd, "tabmove " .. vim.api.nvim_tabpage_get_number(after))
  vim.o.eventignore = ei
end

local setup  -- the autocmds, set up by the first M.open (below)

function M.open(name, key, title, open_fn)
  setup()
  if M.goto_key(key) then return end
  local home
  local cur = vim.api.nvim_get_current_tabpage()
  if M.ENABLED[name] then
    if home_name(cur) == name then
      home = cur
    else
      local here = M.home_of(cur)
      if here and home_name(here) == name then
        home = here
      else
        home = require("azure-cli.home").tab(name)
      end
    end
  end
  vim.cmd("tabnew")
  if home then
    groups[home] = groups[home] or { name = name, members = {} }
    -- Opened from outside its home (gW in a review): closing goes back there.
    local from = (cur ~= home and M.home_of(cur) ~= home) and cur or nil
    table.insert(groups[home].members, { tab = vim.api.nvim_get_current_tabpage(), key = key, title = title, from = from })
    place(home)
  end
  open_fn()
  vim.cmd("redrawtabline")
end

-- Inner tab `tab` shows something else now (a work item's <CR> on its
-- parent), or the same under its real title: its key and strip label.
function M.retitle(tab, key, title)
  local _, _, m = member(tab)
  if not m then return end
  m.key = key or m.key
  m.title = title or m.title
  vim.cmd("redrawtabline")
end

-- The current tab's group: home, its entries, the current one's index.
local function here()
  local tab = vim.api.nvim_get_current_tabpage()
  local home = M.home_of(tab)
  if not home then return end
  local list = entries(home)
  return home, list, index_of(list, tab) or 1
end

local function busy()
  return require("azure-cli.ui").choosing()
end

-- Called by a screen's close key right before it closes the current tab
-- (the reviewer's q, a work item's q / <BS>): when that's an inner tab,
-- closing it goes to the one before it, the list when there's none - or
-- back to where it was opened from, when that's outside its home.
function M.closing()
  local tab = vim.api.nvim_get_current_tabpage()
  local home, i, m = member(tab)
  if not (home and valid(home)) then return end
  -- Worked out now, while the group is whole: by TabClosed something may
  -- already have dropped the closed tab from it.
  local t = M.close_target(i)
  local target = t == 0 and home or groups[home].members[t].tab
  if valid(m.from) then target = m.from end
  closing_here = { tab = tab, home = home, target = target }
  -- The close failed (the tab's still there): forget it.
  vim.schedule(function()
    if closing_here and closing_here.tab == tab and valid(tab) then closing_here = nil end
  end)
end

function M.cycle(dir)
  if busy() then return end
  local _, list, i = here()
  if not list then return end
  if #list < 2 then
    require("azure-cli.shell").notify("No inner tabs open here.")
    return
  end
  go(list[M.wrap(i, dir, #list)])
end

-- Entry n (1 = the home list); without n, a picker of them.
function M.pick(n)
  if busy() then return end
  local home, list = here()
  if not list then return end
  if n then
    if list[n] then go(list[n]) end
    return
  end
  local items = { { label = require("azure-cli.ui").tab_title(home), tab = home } }
  for _, m in ipairs(M.members(home)) do items[#items + 1] = { label = m.title, tab = m.tab } end
  require("azure-cli.ui").pick_popup({ items = items, title = "Inner tabs", action = "go", center = true },
    function(it) go(it.tab) end)
end

-- The window of `tab` the strip goes in: its widest normal window that
-- isn't the chat panel.
local function host(tab)
  local best, bw
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(w).relative == "" and not vim.b[vim.api.nvim_win_get_buf(w)].azure_cli_chat then
      local width = vim.api.nvim_win_get_width(w)
      if not bw or width > bw then best, bw = w, width end
    end
  end
  return best, bw
end

-- The strip for the window being drawn ('winbar' %{% %} evaluates with it
-- current), or "" - not a grouped tab's host window, or no members yet.
function M.bar()
  local ok, s = pcall(function()
    local win = vim.api.nvim_get_current_win()
    local tab = vim.api.nvim_win_get_tabpage(win)
    local home = M.home_of(tab)
    if not home or not groups[home] or #groups[home].members == 0 then return "" end
    local h, width = host(tab)
    if h ~= win then return "" end
    local labels, cur = { require("azure-cli.ui").tab_title(home) }, 1
    for _, m in ipairs(groups[home].members) do
      if valid(m.tab) then
        labels[#labels + 1] = m.title
        if m.tab == tab then cur = #labels end
      end
    end
    if #labels < 2 then return "" end
    return (M.strip_text(labels, cur, math.floor(width * 0.6)))
  end)
  return ok and s or ""
end

-- The tabs keys on `buf`, once, when it's ours (keys.lua bound it some) and
-- in an enabled home or one of its inner tabs.
local function bind(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].azure_cli_tabs or vim.b[buf].azure_cli_chat then return end
  local KEYS = require("azure-cli.keys")
  if not KEYS.has(buf) then return end
  if not M.home_of(0) then return end
  vim.b[buf].azure_cli_tabs = true
  KEYS.bind(buf, "tabs", "next", function() M.cycle(1) end, { desc = "next inner tab" })
  KEYS.bind(buf, "tabs", "prev", function() M.cycle(-1) end, { desc = "previous inner tab" })
  KEYS.bind(buf, "tabs", "pick", M.pick, { desc = "go to inner tab n (the first is the list)", each = true })
end

setup = function()
  if M._set then return end
  M._set = true
  local group = vim.api.nvim_create_augroup("AzureCliInnerTabs", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, { group = group, callback = function(ev)
    vim.schedule(function()
      bind(ev.buf)
      bind(vim.api.nvim_get_current_buf())
    end)
  end })
  -- At TabClosed the closed tab can still count as valid (it's freed
  -- after), so what closed is worked out a tick later.
  vim.api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
    vim.schedule(function()
      prune()
      -- Closed from inside it (q): back to the one before it, else the list.
      local c = closing_here
      if c and not valid(c.tab) then
        closing_here = nil
        local target = valid(c.target) and c.target or c.home
        if valid(target) then go(target) end
      end
      closed = {}
      vim.cmd("redrawtabline")
    end)
  end })
end

return M
