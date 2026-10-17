-- test-key-hints.lua: the g-key float (keyhints.lua) with real input - g
-- and a pause put it up, the next key closes it and does what it always
-- did; typed fast there's no float at all; which-key / mini.clue (under
-- "auto") or ui.key_hints = false leave g alone. Needs the main loop:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-key-hints.lua"
-- prints KEY-HINTS-OK, or KEY-HINTS-FAIL and why.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local function finish(ok, why)
  io.stdout:write((ok and "KEY-HINTS-OK" or ("KEY-HINTS-FAIL: " .. why)) .. "\n")
  vim.cmd(ok and "qa!" or "cq!")
end

vim.o.timeoutlen = 100
require("azure-cli").setup({})
local KEYS = require("azure-cli.keys")
local KH = require("azure-cli.keyhints")

-- The pure parts first.
if not (KH.wanted("auto", false) and not KH.wanted("auto", true) and KH.wanted(true, true) and not KH.wanted(false, false)
    and KH.wanted(nil, false)) then
  return finish(false, "wanted() reads ui.key_hints wrong")
end
local entries = {}
for i = 1, 6 do entries[i] = { key = "g" .. i, desc = "action number " .. i, write = i == 2 } end
local lines = KH.lines(entries, 30, 5)
if not (lines[1] == "  g1  action number 1" and lines[2] == "\u{2191} g2  action number 2"
    and lines[4]:find("3 more", 1, true) and lines[#lines] == "\u{2191} changes Azure DevOps") then
  return finish(false, "lines(): " .. vim.inspect(lines))
end
lines = KH.lines({ { key = "gx", desc = string.rep("long ", 20), write = false } }, 20, 10)
if vim.fn.strdisplaywidth(lines[1]) > 20 or not lines[1]:find("\u{2026}$") then
  return finish(false, "lines() doesn't cut a long description: " .. lines[1])
end

local ran = {}
local function screen()
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(string.rep("x\n", 20), "\n"))
  vim.cmd("normal! G")
  local buf = vim.api.nvim_get_current_buf()
  KEYS.bind(buf, "dashboard", "vote", function() ran[#ran + 1] = "vote" end, { desc = "vote" })
  KEYS.bind(buf, "dashboard", "plan_agents", function() ran[#ran + 1] = "plan" end, { desc = "an agent plans it" })
  return buf
end
local function g_mapped(buf)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do if m.lhs == "g" then return true end end
  return false
end

-- which-key there, "auto": g stays its own; true: ours anyway; false: never.
package.loaded["which-key"] = {}
if g_mapped(screen()) then return finish(false, "g was mapped with which-key installed (auto)") end
require("azure-cli").setup({ ui = { key_hints = true } })
if not g_mapped(screen()) then return finish(false, "ui.key_hints = true didn't map g") end
package.loaded["which-key"] = nil
require("azure-cli").setup({ ui = { key_hints = false } })
if g_mapped(screen()) then return finish(false, "ui.key_hints = false mapped g") end
require("azure-cli").setup({})

-- The change viewer marks nothing as changing Azure DevOps.
local local_buf = screen()
vim.b[local_buf].azure_cli_keys_local = true
if next(KEYS.writes_on(local_buf)) then return finish(false, "a local buffer's keys were marked as writes") end

local buf = screen()
if not KEYS.writes_on(buf).gv then return finish(false, "gv (vote) isn't marked as a write") end
local function float_open()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then return true end
  end
  return false
end

local steps = {
  -- g, a pause: the float lists the screen's g keys, vote marked.
  function()
    vim.api.nvim_input("g")
    return 400, function()
      if not float_open() then return "no float after g and a pause" end
      local text
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
        end
      end
      if not (text:find("\u{2191} gv  vote", 1, true) and text:find("gP  an agent plans it", 1, true)) then
        return "the float doesn't list the keys: " .. text
      end
    end
  end,
  -- v: the float goes, vote runs, g is ours again.
  function()
    vim.api.nvim_input("v")
    return 300, function()
      if float_open() then return "the float stayed after the next key" end
      if ran[#ran] ~= "vote" then return "gv after the pause didn't vote: " .. vim.inspect(ran) end
      if not g_mapped(buf) then return "g wasn't mapped again" end
    end
  end,
  -- gg typed at once: Vim's own gg, no float.
  function()
    vim.api.nvim_input("gg")
    return 300, function()
      if vim.fn.line(".") ~= 1 then return "gg didn't go to the top: line " .. vim.fn.line(".") end
      if float_open() then return "a float after a fast gg" end
    end
  end,
  -- A count and a pause: 5g, pause, g lands on line 5.
  function()
    vim.api.nvim_input("G5g")
    return 400, function()
      if not float_open() then return "no float after 5g and a pause" end
      vim.api.nvim_input("g")
    end
  end,
  function()
    return 300, function()
      if vim.fn.line(".") ~= 5 then return "5g<pause>g didn't go to line 5: " .. vim.fn.line(".") end
    end
  end,
  -- A pause, then <Esc>: nothing happens, the float goes.
  function()
    local before = #ran
    vim.api.nvim_input("g")
    vim.defer_fn(function() vim.api.nvim_input("<Esc>") end, 300)
    return 600, function()
      if float_open() or #ran ~= before or not g_mapped(buf) then return "<Esc> after the pause didn't just cancel" end
    end
  end,
}

-- KH.rows (#123): a screen whose first and last lines aren't rows - a
-- header, a gap, a hint line. gg / G land on its first / last row, a
-- count on that row, typed fast or after g and a pause.
local rows_buf
local ROWS = { [3] = true, [4] = true, [6] = true, [7] = true }  -- 1-2 header, 5 gap, 8-9 hints
local function on(want, what)
  return function()
    local l = vim.fn.line(".")
    if l ~= want then return what .. " went to line " .. l .. ", not " .. want end
  end
end
local function typed(keys, want)
  return function()
    vim.api.nvim_input(keys)
    return 300, on(want, keys)
  end
end
vim.list_extend(steps, {
  function()
    rows_buf = screen()
    vim.api.nvim_buf_set_lines(rows_buf, 0, -1, false, { "header", "", "a", "b", "", "c", "d", "", "g? keys" })
    KH.rows(rows_buf, function() return ROWS end, "agents")
    vim.cmd("normal! 4G")
    vim.api.nvim_input("G")
    return 300, on(7, "G")
  end,
  typed("gg", 3),
  typed("3G", 6),
  typed("2gg", 4),
  typed("99G", 7),
  -- g, a pause: the float lists gg too; then g lands on the first row.
  function()
    vim.api.nvim_input("g")
    return 400, function()
      if not float_open() then return "no float after g and a pause on a rows screen" end
      local text = ""
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
        end
      end
      if not text:find("gg  first row", 1, true) then return "the float doesn't list gg: " .. text end
      vim.api.nvim_input("g")
    end
  end,
  function() return 300, on(3, "g<pause>g") end,
  -- 3g, a pause, g: the count goes through the replay.
  function()
    vim.api.nvim_input("3g")
    vim.defer_fn(function() vim.api.nvim_input("g") end, 300)
    return 600, on(6, "3g<pause>g")
  end,
  -- Another g key still does what it did.
  function()
    local before = #ran
    vim.api.nvim_input("gv")
    return 300, function()
      if #ran ~= before + 1 or ran[#ran] ~= "vote" then return "gv on a rows screen didn't vote" end
      if not g_mapped(rows_buf) then return "g wasn't mapped again on the rows screen" end
    end
  end,
  -- #128: first_row / last_row are in the palette (g.) like the other keys.
  function()
    local PROMPT = require("azure-cli.prompt")
    local real, seen = PROMPT.select, {}
    PROMPT.select = function(o) for _, a in ipairs(o.items) do seen[a.surface .. "." .. a.action] = true end end
    KEYS.palette(rows_buf)
    PROMPT.select = real
    return 0, function()
      if not (seen["agents.first_row"] and seen["agents.last_row"]) then
        return "the palette doesn't list first_row / last_row: " .. vim.inspect(vim.tbl_keys(seen))
      end
    end
  end,
  -- Rebound in setup(): the new keys go to the first / last row, gg is Vim's own again.
  function()
    require("azure-cli").setup({ keys = { agents = { first_row = "[[", last_row = "]]" } } })
    rows_buf = screen()
    vim.api.nvim_buf_set_lines(rows_buf, 0, -1, false, { "header", "", "a", "b", "", "c", "d", "", "g? keys" })
    KH.rows(rows_buf, function() return ROWS end, "agents")
    vim.cmd("normal! 4G")
    vim.api.nvim_input("]]")
    return 300, on(7, "a rebound last_row")
  end,
  typed("[[", 3),
  typed("2]]", 4),
  typed("gg", 1),
  -- Unbound (false): no mapping at all, G is Vim's own.
  function()
    require("azure-cli").setup({ keys = { agents = { first_row = false, last_row = false } } })
    rows_buf = screen()
    vim.api.nvim_buf_set_lines(rows_buf, 0, -1, false, { "header", "", "a", "b", "", "c", "d", "", "g? keys" })
    KH.rows(rows_buf, function() return ROWS end, "agents")
    require("azure-cli").setup({})
    vim.cmd("normal! 4G")
    vim.api.nvim_input("G")
    return 300, on(9, "an unbound last_row's G")
  end,
})

local i = 0
local function run()
  i = i + 1
  if not steps[i] then return finish(true) end
  local wait, check = steps[i]()
  vim.defer_fn(function()
    local err = check()
    if err then return finish(false, "step " .. i .. ": " .. err) end
    run()
  end, wait)
end
vim.defer_fn(run, 200)
