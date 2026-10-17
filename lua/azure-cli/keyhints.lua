-- lua/azure-cli/keyhints.lua: press g on one of azure-vicli's screens and
-- pause, and a small float lists the g keys that screen has and what each
-- does (↑ before the ones that change Azure DevOps), until the next key -
-- which then does what it always did. On those buffers g is a key of its
-- own. Every screen also has longer g keys (gP, g., ...), so Neovim waits
-- 'timeoutlen' after a g before it settles on the plain one - that wait is
-- the pause: when this g runs with no key typed after it, you paused, and
-- the float goes up. (Nothing can be shown from outside: Neovim runs no
-- timers or scheduled callbacks while a mapping is still pending.) The key
-- you then type, or the one already waiting, is replayed with this g out
-- of the way, after the count and register: Vim's own g commands, your g
-- mappings (gcc, grn, ...) and the screen's (gP, gA, ...) all do what
-- they did. A screen with lines that aren't rows gives M.rows its rows,
-- so gg / G (its first_row / last_row keys) land on one.
--
-- ui.key_hints: "auto" (the default) - on unless which-key or mini.clue is
-- there, which show pending keys themselves (from the same descriptions
-- keys.lua gives every map); true - always; false - never.
local M = {}

local float = nil  -- { win, buf } while it shows

local function cfg() return require("azure-cli.config").get() end

-- which-key or mini.clue: loaded, set up, or in lazy.nvim's spec (it may
-- only load on its first key).
function M.other_plugin()
  if _G.package.loaded["which-key"] or _G.MiniClue then return true end
  local ok, lazy = pcall(require, "lazy.core.config")
  local plugins = ok and type(lazy) == "table" and lazy.plugins
  return type(plugins) == "table" and (plugins["which-key.nvim"] or plugins["mini.clue"]) and true or false
end

-- `setting` is ui.key_hints; `other` whether which-key / mini.clue is there.
-- Pure.
function M.wanted(setting, other)
  if setting == nil or setting == "auto" then return not other end
  return setting == true
end

function M.enabled()
  local setting = (cfg().ui or {}).key_hints
  if setting == false then return false end
  return M.wanted(setting, M.other_plugin())
end

-- The float's lines and highlights for `entries` ({ key, desc, write },
-- sorted), at most `max_w` cells wide and `max_h` lines tall: "↑ gA  desc",
-- keys in a column, a "…" line (and g. to see the rest) when they don't
-- all fit, the ↑ legend when one is marked. Pure.
function M.lines(entries, max_w, max_h, service)
  local kw = 0
  for _, e in ipairs(entries) do kw = math.max(kw, vim.fn.strdisplaywidth(e.key)) end
  local lines, hls, marked = {}, {}, false
  local room = math.max(1, max_h - 2)
  for i, e in ipairs(entries) do
    if i > room and #entries > room + 1 then
      lines[#lines + 1] = "  \u{2026} " .. (#entries - room) .. " more - g. lists them all"
      hls[#hls + 1] = { #lines - 1, 0, -1, "AzureCliMuted" }
      break
    end
    local mark = e.write and "\u{2191}" or " "
    marked = marked or e.write
    local head = mark .. " " .. e.key .. string.rep(" ", kw - vim.fn.strdisplaywidth(e.key) + 2)
    local text = head .. e.desc
    if vim.fn.strdisplaywidth(text) > max_w then
      text = vim.fn.strcharpart(text, 0, math.max(1, max_w - 1)) .. "\u{2026}"
    end
    lines[#lines + 1] = text
    hls[#hls + 1] = { #lines - 1, #mark + 1, #mark + 1 + #e.key, "AzureCliKeyHint" }
  end
  if marked then
    lines[#lines + 1] = "\u{2191} changes " .. (service or "Azure DevOps")
    hls[#hls + 1] = { #lines - 1, 0, -1, "AzureCliMuted" }
  end
  return lines, hls
end

-- This buffer's g keys (normal mode): { key, desc, write } by key.
function M.entries(buf)
  local writes = require("azure-cli.keys").writes_on(buf)
  local out, seen = {}, {}
  -- g1..g9 (innertabs.lua's tabs.pick) as one line, not nine.
  local pick = vim.b[buf].azure_cli_tabs and require("azure-cli.keys").resolve("tabs", "pick")
  pick = type(pick) == "table" and pick or (pick and { pick }) or {}
  for _, k in ipairs(pick) do seen[k] = true end
  if #pick > 1 and pick[1]:sub(1, 1) == "g" then
    out[#out + 1] = { key = pick[1] .. "-" .. pick[#pick], desc = "go to inner tab n (the first is the list)", write = false }
  end
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    local lhs = m.lhs or ""
    if lhs:sub(1, 1) == "g" and #lhs > 1 and not seen[lhs] then
      seen[lhs] = true
      out[#out + 1] = { key = lhs, desc = m.desc or "", write = writes[lhs] or false }
    end
  end
  table.sort(out, function(a, b)
    local la, lb = a.key:lower(), b.key:lower()
    if la ~= lb then return la < lb end
    return a.key > b.key  -- ga before gA
  end)
  return out
end

function M.close()
  if float then
    pcall(vim.api.nvim_win_close, float.win, true)
    float = nil
  end
end

local function show(buf)
  local entries = M.entries(buf)
  if #entries == 0 then return end
  local UI = require("azure-cli.ui")
  UI.theme()
  local max_w = math.max(20, math.min(70, vim.o.columns - 6))
  local max_h = math.max(3, vim.o.lines - vim.o.cmdheight - 6)
  -- vim.b.azure_cli_service: what a screen's ↑ keys change ("GitHub" on the Issues tab).
  local lines, hls = M.lines(entries, max_w, max_h, vim.b[buf].azure_cli_service)
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("azure_cli_key_hints")
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, fbuf, ns, h[1], h[2],
      { end_col = h[3] == -1 and #lines[h[1] + 1] or h[3], hl_group = h[4] })
  end
  -- Bottom right, above the command line, out of the way of the cursor.
  local cfgw = { relative = "editor", anchor = "SE", row = vim.o.lines - vim.o.cmdheight - 1, col = vim.o.columns - 1,
    width = width, height = #lines, style = "minimal", border = UI.border(), focusable = false, zindex = 250,
    title = " g\u{2026} ", title_pos = "left" }
  local ok, win = pcall(vim.api.nvim_open_win, fbuf, false, cfgw)
  if not ok then
    cfgw.title, cfgw.title_pos = nil, nil
    ok, win = pcall(vim.api.nvim_open_win, fbuf, false, cfgw)
  end
  if not ok then return end
  UI.float_hl(win)
  float = { win = win, buf = fbuf }
  vim.cmd("redraw")
end

-- The key after the g: nil for <Esc> / <C-c>. Puts the float up when it
-- isn't typed yet - Neovim's 'timeoutlen' wait has already passed then.
local function next_key(buf)
  if vim.fn.getchar(1) == 0 then pcall(show, buf) end
  local ok, c = pcall(vim.fn.getcharstr)
  M.close()
  if not ok or c == "\27" or c == "\3" then return nil end
  return c
end

local G_DESC = "g keys (pause to list them)"
local press

local function map_g(buf)
  vim.keymap.set("n", "g", function() press(buf) end, { buffer = buf, silent = true, desc = G_DESC })
end

-- g: wait for the next key (listing them on a pause), then replay it all
-- with g unmapped, as if it had been typed - and map g again once Neovim
-- has taken those keys in.
press = function(buf)
  local count, reg = vim.v.count, vim.v.register
  local c = next_key(buf)
  if not c then return end
  local keys = (count > 0 and tostring(count) or "") .. ((reg ~= "" and reg ~= '"') and ('"' .. reg) or "") .. "g" .. c
  pcall(vim.keymap.del, "n", "g", { buffer = buf })
  -- "i": ahead of anything typed after it (rX arriving at once: X follows gr).
  vim.api.nvim_feedkeys(keys, "mi", false)
  -- Scheduled work runs once the typeahead is used up (and a pending
  -- mapping like grn resolved), so g is ours again after, not during.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then map_g(buf) end
  end)
end

-- gg / G on a screen whose lines aren't all rows (group headers, a tab
-- bar, the padding round a centred box): the first / last row, and with a
-- count the count-th row, instead of a line the cursor can't use there.
-- `fn()` gives the screen's rows by line ({ [line] = row }). Bound as
-- `surface`'s first_row / last_row (config.lua: gg / G, rebindable),
-- whether or not the hints are on; g and a pause replays gg into this one
-- too, count and all.
function M.rows(buf, fn, surface)
  local function go(last)
    local list = {}
    for l in pairs(fn() or {}) do list[#list + 1] = l end
    if #list == 0 then return end
    table.sort(list)
    local n = vim.v.count
    local i = n > 0 and math.min(n, #list) or (last and #list or 1)
    vim.cmd("normal! m'")
    pcall(vim.api.nvim_win_set_cursor, 0, { list[i], vim.api.nvim_win_get_cursor(0)[2] })
  end
  local KEYS = require("azure-cli.keys")
  KEYS.bind(buf, surface, "first_row", function() go(false) end, { desc = "first row (a count: that row)" })
  KEYS.bind(buf, surface, "last_row", function() go(true) end, { desc = "last row (a count: that row)" })
end

-- Gives `buf` (one of ours - keys.lua calls this on its first key) the g
-- key, unless ui.key_hints says no, or which-key / mini.clue is there under
-- "auto" - then g is left to them.
function M.attach(buf)
  if not M.enabled() then return end
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == "g" and m.desc ~= G_DESC then return end  -- a g the screen binds itself
  end
  map_g(buf)
end

return M
