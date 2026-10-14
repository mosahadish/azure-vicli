-- test-poll.lua: poll.lua (#93) - the network polls slow down while Neovim
-- is unfocused or idle and refresh once on return - on a clock the test
-- turns by hand (POLL._clock) and ticks it fires by hand (POLL._fire).
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-poll.lua
--       the scheduler on its own, and the phone dashboard's feed (web.lua)
--       pushing at its full rate while you're away
--   POLL_SURFACES=1, on a tests/fake-provider.py workspace (tests/run.sh
--   wires it up like test-boards.lua)
--       the real polls: the PR dashboard, the work-items and Issues boards,
--       a review and the chat's watched PRs each register with poll.lua,
--       slow while you're away and come back on return
--
-- Prints "all poll tests passed" / exits non-zero (POLL-TEST-OK /
-- POLL-TEST-FAIL in POLL_SURFACES mode).
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local surfaces = vim.env.POLL_SURFACES == "1"
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local POLL = require("azure-cli.poll")
local T = 1000
POLL._clock = function() return T end
-- What wake() scheduled has run.
local function settle() vim.wait(100, function() return false end, 10) end

-- Fires `name` `n` times while away, the clock moved on by each interval;
-- the intervals it re-armed with.
local function away_intervals(name, n)
  local out = {}
  for _ = 1, n do
    T = T + (POLL.info(name).interval or 0)
    POLL._fire(name)
    out[#out + 1] = POLL.info(name).interval
  end
  return out
end

-- Focus lost: each poll's intervals grow to the cap; focus gained after
-- base: each ticks once, at once, and is back at its base.
local function lost_and_regained(names, label)
  POLL._focus(false)
  for name, base in pairs(names) do
    local got = away_intervals(name, 5)
    local want = {}
    for k = 1, 5 do want[k] = POLL.next_interval(base, 300, k) end
    check(label .. ": focus lost slows " .. name .. " (" .. table.concat(want, ",") .. ")",
      vim.deep_equal(got, want), table.concat(got, ","))
  end
  T = T + 301
  POLL._focus(true)
  settle()
  for name, base in pairs(names) do
    local i = POLL.info(name)
    check(label .. ": focus gained refreshes " .. name .. " at once, back to " .. base .. "s",
      i and i.last == T and i.interval == base and i.away_ticks == 0, vim.inspect(i))
  end
end

if surfaces then
  local function fail(why)
    print("POLL-TEST-FAIL: " .. why)
    vim.cmd("qa!")
  end
  vim.o.columns = 140
  require("azure-cli.home").open_all()
  local want = { "pr-dashboard", "wi-board:azure", "wi-board:github" }
  local function has(name) return POLL.info(name) ~= nil end
  if not vim.wait(15000, function()
    for _, n in ipairs(want) do if not has(n) then return false end end
    return true
  end, 50) then
    return fail("the home tabs registered " .. table.concat(POLL.names(), ", ") .. "; expected " .. table.concat(want, ", "))
  end
  -- A review opens from the dashboard's list.
  vim.wait(15000, function()
    local c = require("azure-cli.state").PR_LIST_CACHE
    return c ~= nil and c.prs ~= nil and #c.prs > 0
  end, 50)
  require("azure-cli").open_review(101)
  local review
  if not vim.wait(15000, function()
    for _, n in ipairs(POLL.names()) do if n:find("^review:") then review = n end end
    return review ~= nil
  end, 50) then
    return fail("a review registered no poll: " .. table.concat(POLL.names(), ", "))
  end
  local W = require("azure-cli.chat.watch")
  W._reset()
  local store = require("azure-cli.chat.store").root()
  vim.fn.mkdir(store, "p")
  vim.fn.writefile({ vim.json.encode({ ["500"] = { id = 500, title = "watched", seen = {} } }) }, store .. "/watched.json")
  W.start()
  if not has("chat-watch") then return fail("chat/watch.lua's start registered no poll") end

  -- On the fake clock from here; every poll starts from a tick now.
  T = T + 1000
  POLL._input()
  settle()
  for _, n in ipairs(POLL.names()) do POLL._fire(n) end
  local names = { ["pr-dashboard"] = 30, ["wi-board:azure"] = 30, ["wi-board:github"] = 30, [review] = 30,
    ["chat-watch"] = 120 }
  lost_and_regained(names, "surfaces")
  -- Idle (no focus events at all): the same.
  T = T + 301
  for name, base in pairs(names) do
    POLL._fire(name)
    check("surfaces: idle slows " .. name, POLL.info(name).interval == base * 2, POLL.info(name).interval)
  end
  T = T + 301
  POLL._input()
  settle()
  for name, base in pairs(names) do
    local i = POLL.info(name)
    check("surfaces: the first key refreshes " .. name .. " once and restores " .. base .. "s",
      i.last == T and i.interval == base, vim.inspect(i))
  end
  if fails > 0 then return fail(fails .. " check(s) failed") end
  print("POLL-TEST-OK")
  return vim.cmd("qa!")
end

-- --- the interval rule --------------------------------------------------------
check("next_interval: base while here", POLL.next_interval(30, 300, 0) == 30)
check("next_interval: doubles while away",
  POLL.next_interval(30, 300, 1) == 60 and POLL.next_interval(30, 300, 2) == 120 and POLL.next_interval(30, 300, 3) == 240)
check("next_interval: capped", POLL.next_interval(30, 300, 4) == 300 and POLL.next_interval(30, 300, 40) == 300)
check("next_interval: a cap below base is base", POLL.next_interval(120, 60, 3) == 120)
local never_faster = true
for _, base in ipairs({ 1, 30, 120, 600 }) do
  for _, max in ipairs({ 1, 30, 300, 3600 }) do
    for k = 0, 20 do
      if POLL.next_interval(base, max, k) < base then never_faster = false end
    end
  end
end
check("next_interval: never faster than base", never_faster)

-- --- the four polls, by hand --------------------------------------------------
local BASES = { ["pr-dashboard"] = 30, ["review:1"] = 30, ["wi-board:azure"] = 30, ["chat-watch"] = 120 }
local ticks = {}
local function register()
  POLL._reset()
  for name, base in pairs(BASES) do
    ticks[name] = 0
    POLL.every(name, { base = function() return base end, tick = function() ticks[name] = ticks[name] + 1 end })
  end
end
local function ticked()
  local n = 0
  for _, c in pairs(ticks) do n = n + c end
  return n
end

register()
check("every: each starts at its base", POLL.info("pr-dashboard").interval == 30 and POLL.info("chat-watch").interval == 120)
lost_and_regained(BASES, "by hand")
local before = ticked()
check("focus gained: each ticked exactly once", before == 4 * 5 + 4, before)
POLL._focus(true)
POLL._input()
vim.api.nvim_exec_autocmds("FocusGained", {})
settle()
check("focus gained twice, then a key: no more ticks", ticked() == before, ticked() - before)
T = T + 30
POLL._fire("pr-dashboard")
check("focused: the rate stays at base", POLL.info("pr-dashboard").interval == 30)

-- Not overdue on return: no tick, moved to last tick + base.
register()
T = T + 10
POLL._focus(false)
T = T + 5
POLL._focus(true)
settle()
check("a quick alt-tab: no tick", ticked() == 0, ticked())
check("a quick alt-tab: still due at last tick + base",
  POLL.info("pr-dashboard").due == POLL.info("pr-dashboard").last + 30, vim.inspect(POLL.info("pr-dashboard")))
-- Slowed, then back before base: re-armed to last + base, not left slow.
POLL._focus(false)
T = T + 30
POLL._fire("pr-dashboard")
check("slowed while unfocused", POLL.info("pr-dashboard").interval == 60)
local last = POLL.info("pr-dashboard").last
T = T + 10
POLL._focus(true)
settle()
check("back before base: no tick, due at last + base (not left slow)",
  POLL.info("pr-dashboard").last == last and POLL.info("pr-dashboard").due == last + 30
  and POLL.info("pr-dashboard").away_ticks == 0, vim.inspect(POLL.info("pr-dashboard")))

-- The real autocmds.
register()
vim.api.nvim_exec_autocmds("FocusLost", {})
check("FocusLost: away", POLL.away())
T = T + 31
vim.api.nvim_exec_autocmds("FocusGained", {})
settle()
check("FocusGained: back, and each overdue poll ticked once",
  not POLL.away() and ticks["pr-dashboard"] == 1 and ticks["chat-watch"] == 0, vim.inspect(ticks))

-- Idle, with no focus events at all.
register()
T = T + 299
check("idle: not before idle_after", not POLL.away())
T = T + 1
check("idle: after idle_after", POLL.away())
for name, base in pairs(BASES) do
  local got = away_intervals(name, 3)
  check("idle slows " .. name, got[1] == base * 2 and got[3] == POLL.next_interval(base, 300, 3), table.concat(got, ","))
end
T = T + 301
local n0 = ticked()
-- A real key, through vim.on_key.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
settle()
check("the first key after idle: not away any more", not POLL.away())
check("the first key after idle: each poll refreshed once", ticked() == n0 + 4, ticked() - n0)
for name, base in pairs(BASES) do
  check("the first key after idle restores " .. name .. " to " .. base .. "s", POLL.info(name).interval == base)
end

-- FocusLost and never FocusGained (a terminal that loses it): a key brings
-- it back.
register()
POLL._focus(false)
T = T + 30
POLL._fire("pr-dashboard")
check("lost FocusGained: slow", POLL.info("pr-dashboard").interval == 60)
T = T + 31
POLL._input()
settle()
check("lost FocusGained: a key counts as focus", not POLL.away() and POLL.info("pr-dashboard").interval == 30)

-- tick() returning false stops it; registering a name again replaces it.
POLL._reset()
local h = POLL.every("x", { base = 30, tick = function() return false end })
POLL._fire("x")
check("tick returning false stops the poll", POLL.info("x") == nil and h.stopped)
local h1 = POLL.every("y", { base = 30, tick = function() end })
local h2 = POLL.every("y", { base = 30, tick = function() end })
check("the same name again stops the old one", h1.stopped and not h2.stopped and POLL.info("y") ~= nil)
POLL.stop(h2)
check("stop(handle)", POLL.info("y") == nil)
POLL.stop(nil)
POLL._reset()

-- --- the phone dashboard's feed keeps its pace while you're away ----------------
do
  local n = 0
  package.loaded["azure-cli.chat.agents_view"] = {
    rows = function() n = n + 1; return { { label = "#" .. n, title = "t", state = "working" } } end,
    arrange = function(rows) return rows, 0 end, FINISHED_DAYS = 7,
  }
  package.loaded["azure-cli.chat.agents"] = { queued = function() return {} end, working = function() return 1 end,
    max = function() return 2 end }
  package.loaded["azure-cli.chat"] = { conversations = function() return {} end, restore_plans = function() end }
  package.loaded["azure-cli.chat.plan"] = { load = function() end }
  package.loaded["azure-cli.chat.core"] = { context_label = function() return "" end,
    money = function(x) return tostring(x) end, requests_label = function() return "" end }
  require("azure-cli.config").setup({ dashboard_web = { enabled = true } })
  local sent = 0
  local real_jobstart, real_chansend, real_float = vim.fn.jobstart, vim.fn.chansend, require("azure-cli.ui").open_float
  vim.fn.jobstart = function(_, opts)
    vim.schedule(function() opts.on_stdout(7, { '{"port": 8797, "token": "t"}', "" }) end)
    return 7
  end
  vim.fn.chansend = function() sent = sent + 1 end
  require("azure-cli.ui").open_float = function() end
  local WEB = require("azure-cli.web")
  WEB.EVERY = 50
  POLL._focus(false)
  T = T + 3600
  check("web feed: set up as away (unfocused and idle)", POLL.away())
  WEB.start()
  vim.wait(1000, function() return sent >= 6 end, 10)
  check("web feed: pushes at its full rate while you're away", sent >= 6, sent)
  WEB.stop(true)
  vim.fn.jobstart, vim.fn.chansend, require("azure-cli.ui").open_float = real_jobstart, real_chansend, real_float
  check("web feed: not one of poll.lua's polls", #POLL.names() == 0, table.concat(POLL.names(), ","))
end

if fails > 0 then
  print(fails .. " poll test(s) failed")
  os.exit(1)
end
print("all poll tests passed")
