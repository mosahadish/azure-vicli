-- tests/shot-agents.lua: the scene for docs/images/chat-agents.png - the
-- Agents screen with three plans' agents: one working on #3001, #3002's plan
-- waiting for review, #3012's approved. Written here (no agent runs while
-- screenshots are taken), so the picture is the same every run.
local CHAT = require("azure-cli.chat")
local TOOLS = require("azure-cli.chat.tools")
local PLAN = require("azure-cli.chat.plan")
local now = os.time()
local function plan(id, title)
  TOOLS.by_name.submit_plan.run({ work_item_id = id, title = title, markdown = "# " .. title
    .. "\n\n## Goal\nx\n\n## Approach\ny\n\n## Files\n- `src/auth.py` - z" }, { background = function() return true end },
    function() end)
end
plan(3002, "--name takes the flag as its value")
plan(3012, "Tests for the lockout window")
local rec = PLAN.load("wi-3012")
rec.status = "approved"
PLAN.save(rec)
CHAT.agents = function() return { claude = { label = "Claude" } } end
local c1 = CHAT.conversation("wi-3001", { label = "#3001", title = "Throttle repeated login failures",
  target = { work_item_id = 3001 } })
c1.entries = { { role = "you", text = "/plan #3001" }, { role = "agent", status = "running", started = now - 42,
  tools = { "\u{00B7} get_work_item (id=3001)", "\u{270E} start_story (from=main, name=feature/3001-throttle)" }, text = "" } }
c1.running = { entry = c1.entries[2] }
local c2 = CHAT.conversation("wi-3002", { label = "#3002", target = { work_item_id = 3002 } })
c2.entries = { { role = "you", text = "/plan #3002" }, { role = "agent", status = "done", started = now - 260, text = "Plan submitted." } }
local c3 = CHAT.conversation("wi-3012", { label = "#3012", target = { work_item_id = 3012 } })
c3.entries = { { role = "you", text = "/plan #3012" }, { role = "agent", status = "done", started = now - 900, text = "Approved." } }
CHAT.hide()
require("azure-cli.chat.agents_view").open()
-- Clear the :luafile line this was run with (it names a local path).
vim.defer_fn(function() vim.cmd("echo \"\"") end, 300)
