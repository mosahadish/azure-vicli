-- test-plan-discard.lua: dd on the Agents screen discards a row's plan
-- (#98, chat/plan_discard.lua) - asks first and Cancel leaves everything;
-- refused while its agent works (also when it starts while you answer);
-- a worktree with uncommitted or unpushed changes is kept, a clean one
-- removed; the plan's and its conversation's files move to
-- plans/discarded/; a plan the main chat wrote with no agent conversation
-- behind it (like wi-19) goes too; a queued one leaves the queue. Real git
-- worktrees in the sandbox, the yes/no popup stubbed.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-plan-discard.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

for k, v in pairs({ GIT_AUTHOR_NAME = "t", GIT_AUTHOR_EMAIL = "t@x", GIT_COMMITTER_NAME = "t",
  GIT_COMMITTER_EMAIL = "t@x", GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = "/dev/null" }) do
  vim.env[k] = v
end
local function sh(argv)
  local out = vim.fn.system(argv)
  assert(vim.v.shell_error == 0, table.concat(argv, " ") .. ": " .. out)
  return vim.trim(out)
end

require("azure-cli.config").setup({ chat = { agent = { label = "fake", cmd = { "true" } }, max_agents = 1 } })
local STATE = require("azure-cli.state")
local CHAT = require("azure-cli.chat")
local PLAN = require("azure-cli.chat.plan")
local AG = require("azure-cli.chat.agents")
local AV = require("azure-cli.chat.agents_view")
local FIX = require("azure-cli.chat.tools_fix")
local STORE = require("azure-cli.chat.store")
local PD = require("azure-cli.chat.plan_discard")

-- The popup answers `answer` (and runs `meanwhile` first); toasts kept.
local asked, answer, meanwhile, said = nil, false, nil, {}
require("azure-cli.ui").confirm = function(opts, cb)
  asked = opts
  if meanwhile then meanwhile() end
  cb(answer)
end
require("azure-cli.shell").notify = function(msg) said[#said + 1] = msg end

-- dd on plan `key`'s row: waits until it has said something.
local function press(key)
  asked, said = nil, {}
  local finished = false
  PD.ask({ key = key }, function() finished = true end)
  vim.wait(10000, function() return finished or #said > 0 or (asked and not answer) end, 10)
end

local md = "# T\n\n## Goal\nx\n\n## Approach\nx\n\n## Files\n- `a`\n\n## Risks\nx\n\n## Test plan\nx\n\n## Open questions\nNone"
local function make_plan(id)
  local key = "wi-" .. id
  PLAN.save({ key = key, target = { work_item_id = id }, title = "Plan " .. id, status = "draft",
    revisions = { { text = md, by = "agent", at = os.time() } }, threads = {}, created = os.time() })
  vim.fn.writefile(vim.split(md, "\n"), PLAN.path(key))
  return key
end
local function exists(key) return vim.fn.filereadable(PLAN.root() .. "/" .. key .. ".json") == 1
  or vim.fn.filereadable(PLAN.path(key)) == 1 end
local function discarded(key) return vim.fn.glob(PLAN.root() .. "/discarded/" .. key .. "-*", false, true) end
local function row_of(key)
  for _, r in ipairs(AV.rows(CHAT.conversations(), AG.queued(), PLAN.load, os.time())) do
    if r.key == key then return r end
  end
  return nil
end
-- A plan's agent conversation, saved like a real one.
local function make_conv(key, id)
  local c = CHAT.conversation(key, { target = { work_item_id = id }, label = "#" .. id })
  c.entries = { { role = "you", text = "/plan #" .. id }, { role = "agent", text = "planned" } }
  STORE.save({ id = c.conv_id, created = c.created, entries = c.entries, plan = key })
  return c
end

-- A clone of a scratch origin, for the worktrees.
local tmp = vim.fn.tempname()
local origin, clone = tmp .. "/origin.git", tmp .. "/clone"
sh({ "git", "init", "-q", "--bare", "-b", "main", origin })
sh({ "git", "clone", "-q", origin, clone })
vim.fn.writefile({ "one" }, clone .. "/a.txt")
sh({ "git", "-C", clone, "add", "-A" })
sh({ "git", "-C", clone, "commit", "-q", "-m", "one" })
sh({ "git", "-C", clone, "push", "-q", "origin", "HEAD:refs/heads/main" })
vim.fn.mkdir(FIX.root(), "p")
local function make_worktree(id)
  local wt = FIX.story_path("repo", id)
  sh({ "git", "-C", clone, "worktree", "add", "-q", "--detach", wt, "origin/main" })
  vim.fn.writefile({ "feature/" .. id, "main" }, wt .. ".branch")
  return wt
end

-- Cancel: everything stays.
do
  local key = make_plan(9801)
  local c = make_conv(key, 9801)
  answer = false
  press(key)
  check("cancel: it asked, saying what goes", asked and asked.title:find("#9801", 1, true)
    and table.concat(asked.lines, "\n"):find("its conversation (2 turns, 1 saved file moved too)", 1, true), vim.inspect(asked))
  check("cancel: the files, the conversation and the row stay", exists(key) and #discarded(key) == 0
    and CHAT.find_conversation(key) == c and row_of(key) ~= nil
    and vim.fn.filereadable(STORE.root() .. "/conversations/" .. c.conv_id .. ".json") == 1)
end

-- Refused while working: nothing asked, nothing moved.
do
  local key = "wi-9801"
  local c = CHAT.find_conversation(key)
  c.running = true
  answer = true
  press(key)
  check("working: refused, <C-c> named, not asked", asked == nil and said[1]
    and said[1]:find("working", 1, true) and said[1]:find("<C-c>", 1, true), vim.inspect(said))
  check("working: everything stays", exists(key) and CHAT.find_conversation(key) == c)
  c.running = false
  -- It starts working while the question waits: still refused.
  meanwhile = function() c.running = true end
  press(key)
  meanwhile = nil
  check("working: starting while you answer is refused too", asked ~= nil and said[1]
    and said[1]:find("<C-c>", 1, true) and exists(key) and CHAT.find_conversation(key) == c, vim.inspect(said))
  c.running = false
end

-- Confirm: the files move, the conversation and the row go; a clean
-- worktree is removed.
do
  local key = "wi-9801"
  local c = CHAT.find_conversation(key)
  local conv_file = STORE.root() .. "/conversations/" .. c.conv_id .. ".json"
  local wt = make_worktree(9801)
  check("confirm: waiting for review before", vim.tbl_contains(PLAN.waiting(), "#9801"), vim.inspect(PLAN.waiting()))
  answer = true
  press(key)
  local moved = discarded(key)
  table.sort(moved)
  check("confirm: the question lists the clean worktree as removed",
    asked and table.concat(asked.lines, "\n"):find("(nothing in it) - removed", 1, true), vim.inspect(asked and asked.lines))
  check("confirm: plan and conversation files moved to plans/discarded/", not exists(key) and #moved == 3
    and moved[1]:match("%.conversation%.json$") and vim.fn.filereadable(conv_file) == 0, vim.inspect(moved))
  check("confirm: the conversation and the row are gone", CHAT.find_conversation(key) == nil and row_of(key) == nil)
  check("confirm: the clean worktree is removed", vim.fn.isdirectory(wt) == 0 and vim.fn.filereadable(wt .. ".branch") == 0,
    vim.inspect(said))
  check("confirm: not waiting for review any more", not vim.tbl_contains(PLAN.waiting(), "#9801"), vim.inspect(PLAN.waiting()))
  check("confirm: the toast says where", said[1] and said[1]:find("plans/discarded", 1, true), vim.inspect(said))
end

-- A worktree with changes is kept (uncommitted; unpushed); the plan goes.
do
  local key = make_plan(9802)
  make_conv(key, 9802)
  local wt = make_worktree(9802)
  vim.fn.writefile({ "two" }, wt .. "/a.txt")
  answer = true
  press(key)
  local q = asked and table.concat(asked.lines, "\n") or ""
  check("uncommitted: the question says it's kept", q:find("1 uncommitted file: kept", 1, true), q)
  check("uncommitted: kept, the plan discarded", vim.fn.isdirectory(wt) == 1 and vim.fn.readfile(wt .. "/a.txt")[1] == "two"
    and not exists(key) and #discarded(key) == 3, vim.inspect(said))
  check("uncommitted: the toast says it was kept", said[1] and said[1]:find("Kept its worktree", 1, true), vim.inspect(said))

  key = make_plan(9803)
  wt = make_worktree(9803)
  vim.fn.writefile({ "three" }, wt .. "/a.txt")
  sh({ "git", "-C", wt, "commit", "-q", "-am", "three" })
  press(key)
  q = asked and table.concat(asked.lines, "\n") or ""
  check("unpushed: the question says it's kept", q:find("1 unpushed commit: kept", 1, true), q)
  check("unpushed: kept, the plan discarded", vim.fn.isdirectory(wt) == 1 and not exists(key), vim.inspect(said))
end

-- A plan the main chat wrote before #86, like wi-19: no agent
-- conversation, no saved conversation file, no worktree.
do
  local key = make_plan(9819)
  STATE.chat.convs[key], STATE.chat.plans_restored = nil, nil
  CHAT.restore_plans()
  local c = CHAT.find_conversation(key)
  check("orphan: restore_plans adopted it, a note only", c and #c.entries == 1 and c.entries[1].role == "note"
    and row_of(key) ~= nil and c.entries[1].text:find("dd on the Agents screen", 1, true), vim.inspect(c and c.entries))
  answer = true
  press(key)
  local q = asked and table.concat(asked.lines, "\n") or ""
  check("orphan: the question says there's no conversation", q:find("no conversation", 1, true), q)
  check("orphan: discarded - files moved, row and conversation gone", not exists(key) and #discarded(key) == 2
    and CHAT.find_conversation(key) == nil and row_of(key) == nil, vim.inspect({ said, discarded(key) }))
end

-- A queued one leaves the queue.
do
  local busy = CHAT.conversation("wi-9890", { target = { work_item_id = 9890 }, label = "#9890" })
  busy.running = true  -- the one slot is taken: what's started next waits
  AG.start_for_items({ { id = 9804, title = "Queued" } })
  check("queued: it waits", #AG.queued() == 1 and row_of("wi-9804") ~= nil, vim.inspect(AG.queued()))
  answer = true
  press("wi-9804")
  check("queued: it asked, naming its place in the queue",
    asked and table.concat(asked.lines, "\n"):find("its place in the queue", 1, true), vim.inspect(asked))
  check("queued: off the queue, the row gone", #AG.queued() == 0 and row_of("wi-9804") == nil, vim.inspect(said))
  busy.running = false
  CHAT.drop_conversation("wi-9890")
  AG.reset()
end

-- confirm_lines (pure): what goes, what stays.
do
  local lines = PD.confirm_lines({ key = "wi-1", label = "#1", plan = {}, turns = 0, conversations = {}, queued = false,
    worktrees = { { dir = "/w", dirty = 2, unpushed = 1, keep = true } } })
  local text = table.concat(lines, "\n")
  check("confirm_lines: goes / stays", lines[1] == "Goes:" and text:find("plans/wi-1.json, .md", 1, true)
    and text:find("Stays:\n  - #1 itself, and its branch on the server", 1, true)
    and text:find("/w - 2 uncommitted files, 1 unpushed commit: kept", 1, true), text)
  lines = PD.confirm_lines({ key = "wi-1", label = "#1", turns = 1, conversations = {}, queued = true,
    worktrees = { { dir = "/w", dirty = 0, unpushed = 0, unknown = true, keep = true } } })
  text = table.concat(lines, "\n")
  check("confirm_lines: git couldn't tell - kept", text:find("git couldn't tell what's in it: kept", 1, true)
    and text:find("its conversation (1 turn)", 1, true) and not text:find("the plan (", 1, true), text)
end

-- The main chat's discard_plan still moves an orphan's files, through
-- move_files (test-chat-plan.lua's #86 checks it still refuses an agent's).
do
  local key = make_plan(9805)
  local TOOLS = require("azure-cli.chat.tools")
  local main_env = CHAT._.tool_env({ tools = {} }, nil)
  local res, err, finished
  TOOLS.by_name["discard_plan"].run({ work_item_id = 9805 }, main_env, function(r, e) res, err, finished = r, e, true end)
  vim.wait(5000, function() return finished end, 10)
  check("discard_plan: an orphan's files still move", res and not exists(key) and #discarded(key) == 2, err)
end

print(fails == 0 and "all plan-discard tests passed" or (fails .. " plan-discard test(s) failed"))
vim.cmd(fails == 0 and "qa!" or "cq!")
