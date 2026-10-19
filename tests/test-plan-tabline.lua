-- test-plan-tabline.lua: the tab line's "N plans wait for you" is drawn
-- again whenever the plans index changes (#117) - a discard, an approval,
-- a new plan - without a chat render or a tab switch, and once for a
-- burst of saves.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-plan-tabline.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

require("azure-cli.config").setup({ chat = { agent = { label = "fake", cmd = { "true" } }, max_agents = 1 } })
local CHAT = require("azure-cli.chat")
local PLAN = require("azure-cli.chat.plan")
local PD = require("azure-cli.chat.plan_discard")
local UI = require("azure-cli.ui")
require("azure-cli.shell").notify = function() end
CHAT.send = function() return {} end  -- approving tells no real agent

-- Counts the tab line redraws.
local redraws = 0
local real_cmd = vim.cmd
vim.cmd = setmetatable({}, {
  __call = function(_, c, ...)
    if c == "redrawtabline" then redraws = redraws + 1 end
    return real_cmd(c, ...)
  end,
  __index = real_cmd,
})
-- What happened to the tab line after the scheduled redraw ran.
local function settle()
  redraws = 0
  return function()
    vim.wait(1000, function() return redraws > 0 end, 10)
    vim.wait(50)  -- a second one, if any, would show by now
    return redraws
  end
end

local md = "# T\n\n## Goal\nx\n\n## Approach\nx\n\n## Files\n- `a`\n\n## Risks\nx\n\n## Test plan\nx\n\n## Open questions\nNone"
local function make_plan(id)
  local key = "wi-" .. id
  PLAN.save({ key = key, target = { work_item_id = id }, title = "Plan " .. id, status = "draft",
    revisions = { { markdown = md, by = "agent", at = os.time() } }, threads = {}, created = os.time() })
  vim.fn.writefile(vim.split(md, "\n"), PLAN.path(key))
  return key
end
local function says(n) return UI.tabline():find(n .. " plans wait for you", 1, true) ~= nil end

for id = 11701, 11704 do make_plan(id) end
vim.wait(100)
check("4 plans wait", says(4), UI.tabline())

-- Discard (dd / gD's move_files): one redraw, the count drops.
do
  local after = settle()
  assert(PD.move_files("wi-11701"))
  check("discard: one redraw", after() == 1, redraws)
  check("discard: 3 plans wait", says(3), UI.tabline())
end

-- A burst of saves in one go: one redraw.
do
  local after = settle()
  local rec = PLAN.load("wi-11702")
  for _ = 1, 5 do PLAN.save(rec) end
  check("debounce: five saves, one redraw", after() == 1, redraws)
end

-- Approve: one redraw, the count drops.
do
  local after = settle()
  check("approve: approved", PLAN.approve("wi-11702") == true)
  check("approve: one redraw", after() == 1, redraws)
  check("approve: 2 plans wait", says(2), UI.tabline())
end

-- A new plan through submit_plan: one redraw, the count goes up.
do
  local submit
  for _, t in ipairs(PLAN.tools()) do if t.name == "submit_plan" then submit = t end end
  local after = settle()
  local result
  submit.run({ work_item_id = 11705, title = "New", markdown = md },
    { background = function() return true end }, function(r, err) result = r or err end)
  check("submit: shown", type(result) == "table", vim.inspect(result))
  check("submit: one redraw", after() == 1, redraws)
  check("submit: 3 plans wait", says(3), UI.tabline())
end

print(fails == 0 and "all plan-tabline tests passed" or (fails .. " plan-tabline test(s) failed"))
real_cmd(fails == 0 and "qa!" or "cq!")
