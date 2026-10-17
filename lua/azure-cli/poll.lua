-- lua/azure-cli/poll.lua: the one scheduler every network poll runs on
-- (#93) - the PR dashboard's list, a review's threads/new-push checks, the
-- work-items and Issues boards, and chat/watch.lua's watched PRs.
--
-- Each poll ticks every `base` seconds while you're here. While you're away
-- - Neovim unfocused (FocusLost), or no key for timing.idle_after seconds -
-- every tick doubles its interval, up to timing.max_poll_seconds (never
-- below `base`): slow, never stopped. On return - FocusGained, or the first
-- key while away - each poll that's overdue (its last tick `base` or more
-- ago) ticks once at once and goes back to `base`; one that isn't is moved
-- to last tick + base. So a quick alt-tab costs nothing, and FocusGained
-- followed by a key ticks once, not twice. Nothing ever ticks sooner than
-- `base` after its last tick.
--
-- Idle works without focus events (terminals that don't send them, tmux
-- without `focus-events on`): a key stamps the last input (vim.on_key), and
-- a key while "unfocused" counts as focus too, so a lost FocusGained can't
-- leave the polls slow.
--
-- Local redraws (the agent column, the Agents screen, the phone dashboard's
-- feed, spinners) don't go through here: they make no requests, and they're
-- what shows a running agent's progress while you're away.
--
--   M.every(name, { base = secs | fn -> secs, tick = fn })  a poll; replaces
--       the one already called `name`. tick() returning false stops it.
--       Returns its handle: handle.stop().
--   M.stop(handle)    stops a handle (or a plain timer id, or nil)
--   M.next_interval(base, cap, away_ticks)  pure: the interval rule above
--   M.away(now)       whether you're away
--   M.wake()          the return: what FocusGained / a key do
--   M.info(name)      { interval, away_ticks, last, due } (tests)
--   M._clock, M._fire(name), M._focus(bool), M._input()  tests
local M = {}

M.DEFAULT_IDLE_AFTER = 300
M.DEFAULT_MAX = 300

local pollers = {}  -- name -> { name, base, tick, timer, last, due, interval, away_ticks, stopped }
local focused = true
local last_input
local installed = false
local wake_pending = false

-- Seconds; tests replace it.
function M._clock() return (vim.uv or vim.loop).hrtime() / 1e9 end

local function timing()
  local ok, cfg = pcall(function() return require("azure-cli.config").get().timing end)
  return ok and type(cfg) == "table" and cfg or {}
end
local function idle_after() return tonumber(timing().idle_after) or M.DEFAULT_IDLE_AFTER end
local function cap() return tonumber(timing().max_poll_seconds) or M.DEFAULT_MAX end

local function base_of(p)
  local b = type(p.base) == "function" and p.base() or p.base
  return math.max(1, tonumber(b) or 30)
end

-- Base while here; while away base * 2^away_ticks, up to max(cap, base).
function M.next_interval(base, max, away_ticks)
  if not away_ticks or away_ticks <= 0 then return base end
  return math.min(base * 2 ^ away_ticks, math.max(max or base, base))
end

function M.away(now)
  now = now or M._clock()
  return not focused or (last_input ~= nil and now - last_input >= idle_after())
end

local fire  -- below

local function arm(p, secs)
  if p.timer then pcall(vim.fn.timer_stop, p.timer); p.timer = nil end
  if p.stopped then return end
  secs = math.max(0, secs)
  p.interval = secs
  p.due = M._clock() + secs
  p.timer = vim.fn.timer_start(math.max(1, math.floor(secs * 1000)), function()
    p.timer = nil
    fire(p)
  end)
end

fire = function(p)
  if p.stopped or vim.v.exiting ~= vim.NIL then return end
  local now = M._clock()
  p.away_ticks = M.away(now) and p.away_ticks + 1 or 0
  p.last = now
  local ok, res = pcall(p.tick)
  if ok and res == false then return p.stop() end
  arm(p, M.next_interval(base_of(p), cap(), p.away_ticks))
  if not ok then error(res, 0) end
end

-- The return: overdue polls tick now, the rest go back to last + base.
-- Scheduled (on_key can't run them), and once however many events ask.
function M.wake()
  if wake_pending then return end
  wake_pending = true
  vim.schedule(function()
    wake_pending = false
    local now = M._clock()
    local err
    for _, p in pairs(vim.tbl_values(pollers)) do
      local base = base_of(p)
      p.away_ticks = 0
      if now - p.last >= base then
        if p.timer then pcall(vim.fn.timer_stop, p.timer); p.timer = nil end
        local ok, e = pcall(fire, p)
        if not ok then err = err or e end
      elseif p.due and p.due > p.last + base then
        arm(p, p.last + base - now)
      end
    end
    if err then error(err, 0) end
  end)
end

local function on_focus(gained)
  if gained then
    local was_away = M.away()
    focused = true
    last_input = M._clock()
    if was_away then M.wake() end
  else
    focused = false
  end
end

local function on_input()
  local now = M._clock()
  local was_away = M.away(now)
  focused = true
  last_input = now
  if was_away then M.wake() end
end

local function install()
  if installed then return end
  installed = true
  last_input = M._clock()
  vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
    group = vim.api.nvim_create_augroup("AzureCliPoll", { clear = true }),
    callback = function(ev) on_focus(ev.event == "FocusGained") end,
  })
  vim.on_key(function() on_input() end, vim.api.nvim_create_namespace("azure-cli.poll"))
end

function M.every(name, opts)
  install()
  if pollers[name] then pollers[name].stop() end
  local p = { name = name, base = opts.base, tick = opts.tick, away_ticks = 0, last = M._clock() }
  function p.stop()
    p.stopped = true
    if p.timer then pcall(vim.fn.timer_stop, p.timer); p.timer = nil end
    if pollers[name] == p then pollers[name] = nil end
  end
  pollers[name] = p
  arm(p, base_of(p))
  return p
end

function M.stop(h)
  if type(h) == "table" and h.stop then h.stop()
  elseif type(h) == "number" then pcall(vim.fn.timer_stop, h) end
end

function M.info(name)
  local p = pollers[name]
  if not p then return nil end
  return { interval = p.interval, away_ticks = p.away_ticks, last = p.last, due = p.due }
end

function M.names()
  local out = vim.tbl_keys(pollers)
  table.sort(out)
  return out
end

-- Tests: tick `name` now, as its timer would.
function M._fire(name)
  local p = pollers[name]
  if not p then return end
  if p.timer then pcall(vim.fn.timer_stop, p.timer); p.timer = nil end
  fire(p)
end
function M._focus(gained) install(); on_focus(gained) end
function M._input() install(); on_input() end
function M._reset()
  for _, p in pairs(pollers) do p.stop() end
  focused, last_input, wake_pending = true, M._clock(), false
end

return M
