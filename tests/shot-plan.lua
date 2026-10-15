-- tests/shot-plan.lua: the scene for docs/images/chat-plan.png (tests/screenshots.py
-- runs it with :luafile in the standalone demo). A plan for #3001 through
-- submit_plan itself, two questions under its lines (one answered, one still
-- being asked) and a short conversation in the chat panel - written here, not
-- by an agent, so the picture is the same every run.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")({ attach = true })
local PLAN = require("azure-cli.chat.plan")
local TOOLS = require("azure-cli.chat.tools")
local md = table.concat({
  "# Throttle repeated failed logins", "",
  "## Goal", "Lock an account for 15 minutes after 5 failed logins in a row, and tell the caller why.", "",
  "## Approach", "Count failures per user in `throttle.py` and check the lock in `login()` before hashing.",
  "Keep `login()` returning a bool; add `login_result()` with a reason code for new callers.", "",
  "## Files",
  "- `src/throttle.py` - failure counter, lock window, `is_locked()`",
  "- `src/auth.py` - check the lock first, record failures",
  "- `tests/test_throttle.py` - lock, unlock after the window, reset on success", "",
  "## Risks", "In-memory counters reset on restart - acceptable for now, noted in the docstring.", "",
  "## Test plan", "Unit tests for the counter and the window; try 6 bad logins by hand.", "",
  "## Open questions", "Should admins be exempt from the lock?",
}, "\n")
TOOLS.by_name.submit_plan.run({ work_item_id = 3001, title = "Throttle failed logins", markdown = md }, {}, function() end)
local rec = PLAN.load("wi-3001")
rec.threads = {
  { id = "t1", line = 7, anchor = "Count failures per user in `throttle.py` and check the lock in `login()` before hashing.",
    question = "Why check the lock before hashing?", status = "answered", agent = "Copilot", at = os.time(),
    answer = "Hashing is the expensive part (sha256 per attempt). Checking the lock first means a locked account costs "
      .. "nothing to reject, and an attacker can't use a locked account to burn CPU. It also keeps the timing the same "
      .. "for locked and unknown users." },
  { id = "t2", line = 8, anchor = "Keep `login()` returning a bool; add `login_result()` with a reason code for new callers.",
    question = "Why not change login() itself?", status = "asking", agent = "Copilot", at = os.time() },
}
PLAN.save(rec)
-- submit_plan doesn't open it (#120): Enter on its Agents row does.
PLAN.open("wi-3001")
local st = require("azure-cli.state")
local CHAT = require("azure-cli.chat")
CHAT.agents = function() return { copilot = { label = "Copilot" } } end
st.chat.entries = {
  { role = "you", text = "/plan", where = "on #3001" },
  { role = "agent", status = "done", label = "Copilot", started = os.time() - 40, tools = {
      "\u{00B7} get_work_item (id=3001)", "\u{00B7} Read src/auth.py", "\u{270E} submit_plan (title=Throttle failed logins, work_item_id=3001)" },
    text = "I wrote a plan for #3001 - it's open next to the chat. It locks an account after **5 failed logins** for 15 minutes.\n\nOne open question: should admins be exempt?" },
  { role = "you", text = "Why check the lock before hashing?  (plan:7)", where = "on #3001 \u{00B7} plan:7" },
  { role = "agent", status = "done", label = "Copilot", started = os.time() - 10, tools = {},
    text = "Hashing is the expensive part (sha256 per attempt). Checking the lock first means a locked account costs nothing to reject." },
}
CHAT.show(false)
vim.defer_fn(function()
  local v = PLAN.current()
  vim.api.nvim_set_current_win(v.plan_win)
  vim.api.nvim_win_set_cursor(v.plan_win, { 7, 0 })
end, 400)
-- Clear the :luafile line this was run with (it names a local path).
vim.defer_fn(function() vim.cmd("echo \"\"") end, 700)
