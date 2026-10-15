-- test-plan-discard.lua: dd on the Agents screen discards a row's plan
-- (#98, chat/plan_discard.lua), gD in its plan view too (#103, closing
-- its tab) - asks first and Cancel leaves everything;
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

-- dd on plan `key`'s row: waits until it has said something - after a
-- Discard, the toast once its worktrees' git jobs are done (#119).
local function press(key)
  asked, said = nil, {}
  PD.ask({ key = key })
  vim.wait(10000, function() return #said > 0 or (asked and not answer) end, 10)
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
  check("confirm: the question lists the worktree, looked at after you answer",
    asked and table.concat(asked.lines, "\n"):find("After you answer:\n  - its worktree repo-wi9801 - removed if clean, kept if it has changes", 1, true),
    vim.inspect(asked and asked.lines))
  check("confirm: the toast says the clean worktree was removed", said[1] and said[1]:find("Removed its worktree " .. wt, 1, true),
    vim.inspect(said))
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
  check("uncommitted: kept, the plan discarded", vim.fn.isdirectory(wt) == 1 and vim.fn.readfile(wt .. "/a.txt")[1] == "two"
    and not exists(key) and #discarded(key) == 3, vim.inspect(said))
  check("uncommitted: the toast says it was kept, and why", said[1]
    and said[1]:find("Kept its worktree " .. wt .. " (1 uncommitted file)", 1, true), vim.inspect(said))

  key = make_plan(9803)
  wt = make_worktree(9803)
  vim.fn.writefile({ "three" }, wt .. "/a.txt")
  sh({ "git", "-C", wt, "commit", "-q", "-am", "three" })
  press(key)
  check("unpushed: the toast says it was kept, and why", said[1]
    and said[1]:find("Kept its worktree " .. wt .. " (1 unpushed commit)", 1, true), vim.inspect(said))
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
    worktrees = { { dir = "/w" } } })
  local text = table.concat(lines, "\n")
  check("confirm_lines: goes / stays / after you answer", lines[1] == "Goes:" and text:find("plans/wi-1.json, .md", 1, true)
    and text:find("Stays:\n  - #1 itself, and its branch on the server\n\nAfter you answer:\n"
      .. "  - its worktree w - removed if clean, kept if it has changes\n    /w", 1, true), text)
  lines = PD.confirm_lines({ key = "wi-1", label = "#1", turns = 1, conversations = {}, queued = true, worktrees = {} })
  text = table.concat(lines, "\n")
  check("confirm_lines: no worktree - no after-you-answer part", not text:find("After you answer", 1, true)
    and text:find("its conversation (1 turn)", 1, true) and not text:find("the plan (", 1, true), text)
end

-- The question's layout (#103, wi-19's): every item indented alike, also
-- once the popup wraps it, and a long worktree path in one piece, ~ for
-- your home, on its own line under its item.
do
  local long = vim.env.HOME .. "/.cache/nvim/azure-cli/fix-worktrees/azure-vicli-wi19-with-a-rather-long-name"
  local lines = PD.confirm_lines({ key = "wi-github-mosahadish~azure-vicli~19", label = "#19 in mosahadish/azure-vicli",
    plan = {}, turns = 12, conversations = { "a", "b" }, queued = false,
    worktrees = { { dir = long }, { dir = long .. "-2" } } })
  local bad = {}
  for _, l in ipairs(lines) do
    if l ~= "" and l ~= "Goes:" and l ~= "Stays:" and l ~= "After you answer:"
      and not (l:match("^  %- %S") or l:match("^    %S")) then
      bad[#bad + 1] = l
    end
  end
  check("layout: items are '  - ', their path lines '    '", #bad == 0, vim.inspect(lines))
  local path = vim.fn.fnamemodify(long, ":~")
  check("layout: the path is ~/..., on a line of its own", path:sub(1, 2) == "~/"
    and vim.tbl_contains(lines, "    " .. path), vim.inspect(lines))
  -- Through the popup, narrower than the items: wrapped lines keep their
  -- item's indent, and the path is never split.
  local UI = require("azure-cli.ui")
  local shown = UI.choose_lines(lines, { "Discard", "Cancel" }, 2, 60)
  local whole, shallow, item = false, {}, nil
  for _, l in ipairs(shown) do
    if l == " Goes:" or l == " Stays:" or l == " After you answer:" or l == "" then item = nil
    elseif l:match("^   %- ") then item = true
    elseif item and not l:match("^     %S") then shallow[#shallow + 1] = l end
    if l:find(path, 1, true) then whole = true end
    if l:match("^%s*Discard") then break end
  end
  check("layout: wrapped lines hang under their item's text", #shallow == 0, vim.inspect(shown))
  check("layout: the path is in one piece in the popup", whole, vim.inspect(shown))
end

-- gD in a plan view (#103): the same question as dd on Agents; Cancel
-- leaves it all, refused while its agent works, Discard moves the files
-- and closes the plan's tab.
do
  local key = make_plan(9806)
  local c = make_conv(key, 9806)
  local function feed(k) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false) end
  local function gd()
    local v = PLAN.current()
    vim.api.nvim_set_current_win(v.plan_win)
    asked, said = nil, {}
    feed(require("azure-cli.keys").first("plan", "discard"))
    vim.wait(10000, function() return #said > 0 or (asked and not answer) end, 10)
  end
  check("gD: the plan's discard key", require("azure-cli.keys").first("plan", "discard") == "gD")
  PLAN.open(key)
  local tab = PLAN.current() and PLAN.current().tab
  answer = false
  gd()
  check("gD cancel: it asked, saying what goes", asked and asked.title:find("#9806", 1, true)
    and table.concat(asked.lines, "\n"):find("its conversation (2 turns", 1, true), vim.inspect(asked))
  check("gD cancel: the files, the conversation and the tab stay", exists(key) and #discarded(key) == 0
    and CHAT.find_conversation(key) == c and vim.api.nvim_tabpage_is_valid(tab) and PLAN.open_views()[key] ~= nil)

  c.running = true
  answer = true
  gd()
  check("gD working: refused, <C-c> named, not asked", asked == nil and said[1]
    and said[1]:find("<C-c>", 1, true), vim.inspect(said))
  check("gD working: everything stays", exists(key) and CHAT.find_conversation(key) == c
    and vim.api.nvim_tabpage_is_valid(tab))
  c.running = false

  gd()
  vim.wait(1000, function() return not vim.api.nvim_tabpage_is_valid(tab) end, 10)
  check("gD discard: files moved, conversation gone", not exists(key) and #discarded(key) == 3
    and CHAT.find_conversation(key) == nil, vim.inspect({ said, discarded(key) }))
  check("gD discard: the plan's tab is closed", not vim.api.nvim_tabpage_is_valid(tab)
    and PLAN.open_views()[key] == nil, vim.inspect(said))
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

-- #114: issue plans keyed by the issue's key. Two GitHub #7s in different
-- repos and an Azure #7 are three plans, rows and worktrees; dd on one
-- leaves the others.
local function inspect(key)
  local info
  PD.inspect(key, function(i) info = i end)
  vim.wait(10000, function() return info ~= nil end, 10)
  return info
end
do
  local a, b, az = { work_item_id = 7, item_key = "o~a~7" }, { work_item_id = 7, item_key = "o~b~7" }, { work_item_id = 7 }
  local function plan_for(target, title)
    local key = PLAN.key(target)
    PLAN.save({ key = key, target = target, title = title, status = "draft",
      revisions = { { text = md, by = "agent", at = os.time() } }, threads = {}, created = os.time() })
    vim.fn.writefile(vim.split(md, "\n"), PLAN.path(key))
    local c = CHAT.conversation(key, { target = target, label = PLAN.target_label(target) })
    c.entries = { { role = "you", text = "/plan" }, { role = "agent", text = "planned" } }
    return key
  end
  local ka, kb, kz = plan_for(a, "A"), plan_for(b, "B"), plan_for(az, "Azure")
  check("#114 keys: two GitHub #7s and an Azure #7 are three plans", ka == "wi-github-o~a~7" and kb == "wi-github-o~b~7"
    and kz == "wi-7" and PLAN.load(ka).title == "A" and PLAN.load(kb).title == "B" and PLAN.load(kz).title == "Azure",
    vim.inspect({ ka, kb, kz }))
  local ra, rb, rz = row_of(ka), row_of(kb), row_of(kz)
  check("#114 Agents rows: one each, labelled by repo", ra and rb and rz and ra.label == "a#7" and rb.label == "b#7"
    and rz.label == "#7", vim.inspect({ ra and ra.label, rb and rb.label, rz and rz.label }))
  check("#114 Agents rows: Enter's plan is the row's own", PLAN.load(ra.key).title == "A" and PLAN.load(rb.key).title == "B"
    and PLAN.load(rz.key).title == "Azure")
  local function wt_for(target)
    local wt = FIX.story_path("repo", target)
    sh({ "git", "-C", clone, "worktree", "add", "-q", "--detach", wt, "origin/main" })
    vim.fn.writefile({ "feature/7", "main" }, wt .. ".branch")
    return wt
  end
  local wa, wb, wz = wt_for(a), wt_for(b), wt_for(az)
  check("#114 worktrees: named after the key, Azure's as before", wa == FIX.root() .. "/wi-github-o~a~7"
    and wb == FIX.root() .. "/wi-github-o~b~7" and wz == FIX.root() .. "/repo-wi7", vim.inspect({ wa, wb, wz }))
  local ia, ib, iz = inspect(ka), inspect(kb), inspect(kz)
  check("#114 dd: each plan finds its own worktree only", #ia.worktrees == 1 and ia.worktrees[1].dir == wa
    and #ib.worktrees == 1 and ib.worktrees[1].dir == wb and #iz.worktrees == 1 and iz.worktrees[1].dir == wz,
    vim.inspect({ ia.worktrees, ib.worktrees, iz.worktrees }))
  vim.fn.writefile({ "mine" }, wa .. "/a.txt")
  answer = true
  press(ka)
  check("#114 dd: a#7's plan goes, its changed worktree stays", not exists(ka) and #discarded(ka) == 2
    and vim.fn.isdirectory(wa) == 1 and row_of(ka) == nil, vim.inspect(said))
  check("#114 dd: b#7 and Azure #7 are untouched", exists(kb) and exists(kz) and row_of(kb) ~= nil and row_of(kz) ~= nil
    and vim.fn.isdirectory(wb) == 1 and vim.fn.isdirectory(wz) == 1)
end

-- #114: gP on two GitHub issues #17 from different repos, and an Azure
-- #17: three agents, not one.
do
  local busy = CHAT.conversation("wi-9890", { target = { work_item_id = 9890 }, label = "#9890" })
  busy.running = true  -- the one slot is taken: they queue
  AG.start_for_items({ { id = 17, key = "o~a~17", title = "A" }, { id = 17, key = "o~b~17", title = "B" } }, nil, "github")
  AG.start_for_items({ { id = 17, title = "Azure" } })
  local keys = vim.tbl_map(function(q) return q.key .. "=" .. q.label end, AG.queued())
  check("#114 gP: two GitHub #17s and an Azure #17 are three agents", table.concat(keys, ",")
    == "wi-github-o~a~17=a#17,wi-github-o~b~17=b#17,wi-17=#17", table.concat(keys, ","))
  check("#114 gP: each with its own target", AG.queued()[1].target.item_key == "o~a~17"
    and AG.queued()[2].target.item_key == "o~b~17" and AG.queued()[3].target.item_key == nil)
  busy.running = false
  CHAT.drop_conversation("wi-9890")
  AG.reset()
end

-- #114: an old plan - a copy of a real wi-88.json, from before issues had
-- keys of their own - with its <repo>-wi88 worktree and its conversation
-- (which recorded the issue it was started for) still loads, belongs to
-- that issue only, shows on the Agents screen, and dd works on it. Nothing
-- under plans/ is written by looking it up, however often.
do
  local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
  vim.fn.writefile(vim.fn.readfile(here .. "/fixtures/plan-wi88.json"), PLAN.root() .. "/wi-88.json")
  STORE.save({ id = "20261014-000000-0088", created = os.time(), plan = "wi-88", entries = {
    { role = "you", text = "/plan GitHub issue #88", view = { work_item = { id = 88, board = "github", key = "o~a~88" } } },
    { role = "agent", text = "planned" } } })
  PLAN.reset_recorded()
  local old = make_worktree(88)
  vim.fn.writefile({ "unfinished" }, old .. "/a.txt")
  local function listing()
    local l = vim.fn.glob(PLAN.root() .. "/**", false, true)
    table.sort(l)
    return table.concat(l, "\n")
  end
  local before = listing()
  local mine, other
  for _ = 1, 2 do
    mine = PLAN.resolve_item({ work_item_id = 88, item_key = "o~a~88" })
    other = PLAN.resolve_item({ work_item_id = 88, item_key = "o~b~88" })
  end
  check("#114 old plan: its issue resolves to wi-88", PLAN.key(mine) == "wi-88"
    and PLAN.load(PLAN.key(mine)).title == "Inner tabs, stage 3: plans inside Agents", vim.inspect(mine))
  check("#114 old plan: the same number in another repo doesn't take it", PLAN.key(other) == "wi-github-o~b~88",
    vim.inspect(other))
  check("#114 old plan: its old worktree is still its story", FIX.find_story(mine) == old
    and PLAN.for_worktree(old) and PLAN.for_worktree(old).key == "wi-88")
  check("#114 old plan: looking it up twice wrote nothing under plans/", listing() == before)
  -- Without the conversation: its one <repo>-wi88 worktree says which repo.
  local saved = STORE.root() .. "/conversations/20261014-000000-0088.json"
  vim.fn.rename(saved, saved .. ".away")
  PLAN.reset_recorded()
  STATE.BOARDS = { workItems = false, issues = { { owner = "o", project = "1" } } }
  check("#114 old plan, no conversation: the worktree's repo decides",
    PLAN.legacy_is_for({ work_item_id = 88, item_key = "o~repo~88" })
    and not PLAN.legacy_is_for({ work_item_id = 88, item_key = "o~a~88" }))
  STATE.BOARDS = { workItems = true, issues = { { owner = "o", project = "1" } } }
  check("#114 old plan, no evidence and an Azure board: no issue takes it",
    not PLAN.legacy_is_for({ work_item_id = 88, item_key = "o~repo~88" }))
  STATE.BOARDS = nil
  vim.fn.rename(saved .. ".away", saved)
  PLAN.reset_recorded()

  -- The Agents screen: restored with its conversation, under its old key.
  STATE.chat.plans_restored = nil
  CHAT.restore_plans()
  local r = row_of("wi-88")
  check("#114 old plan: its Agents row, label #88, Enter's plan is it", r and r.label == "#88"
    and PLAN.load(r.key).title == "Inner tabs, stage 3: plans inside Agents", vim.inspect(r and r.label))
  -- An Azure #88 doesn't start an agent on it.
  said = {}
  AG.start_for_items({ { id = 88, title = "Azure 88" } })
  check("#114 old plan: an Azure #88 doesn't share it", #AG.queued() == 0 and CHAT.find_conversation("wi-88").running ~= true
    and table.concat(said, "\n"):find("GitHub issue's plan", 1, true), vim.inspect(said))
  answer = true
  press("wi-88")
  check("#114 old plan: dd moves it to plans/discarded/, keeps its changed worktree", not exists("wi-88")
    and #discarded("wi-88") == 2 and vim.fn.isdirectory(old) == 1 and vim.fn.readfile(old .. "/a.txt")[1] == "unfinished",
    vim.inspect({ said, discarded("wi-88") }))
end

-- #119: the question comes at once, with no git; Cancel runs none; after
-- Discard the plan is gone before any git job answers; all worktrees are
-- checked in parallel, a clean one removed, a changed one and one git
-- failed on kept, one toast naming them; none removed twice. git stubbed:
-- every call counted, its answer held until release().
do
  local TOOLS = require("azure-cli.chat.tools")
  local real_git = TOOLS.git
  local calls, held = {}, {}
  TOOLS.git = function(argv, cb)
    calls[#calls + 1] = argv
    held[#held + 1] = { argv = argv, cb = cb }
  end
  local function count(word)
    local n = 0
    for _, a in ipairs(calls) do if vim.tbl_contains(a, word) then n = n + 1 end end
    return n
  end
  local removes = function()
    local out = {}
    for _, a in ipairs(calls) do if a[4] == "worktree" and a[5] == "remove" then out[#out + 1] = a[6] end end
    return out
  end
  -- What git would say: a worktree named *dirty* has a changed file, git
  -- fails on one named *broken*; everything else is clean and pushed.
  local function reply(argv)
    local dir = argv[3]
    if vim.tbl_contains(argv, "status") then
      if dir:find("broken", 1, true) then return false, "", "fatal: boom" end
      return true, dir:find("dirty", 1, true) and " M a.txt" or "", ""
    elseif vim.tbl_contains(argv, "rev-list") then return true, "0", ""
    elseif vim.tbl_contains(argv, "rev-parse") then return true, "/x/.git", ""
    end
    return true, "", ""
  end
  local function release()
    while #held > 0 do
      local h = table.remove(held, 1)
      h.cb(reply(h.argv))
    end
  end
  local function fake_worktree(name, id)
    local d = FIX.story_path(name, id)
    vim.fn.mkdir(d, "p")
    vim.fn.writefile({ "gitdir: /x/.git/worktrees/" .. name }, d .. "/.git")
    return d
  end
  local at_question
  meanwhile = function() at_question = #calls end

  local id = 11901
  local key = make_plan(id)
  make_conv(key, id)
  local clean, dirty, broken = fake_worktree("clean", id), fake_worktree("dirty", id), fake_worktree("broken", id)

  -- Cancel.
  calls, held, asked, said, at_question, answer = {}, {}, nil, {}, nil, false
  PD.ask({ key = key })
  local q = asked and table.concat(asked.lines, "\n") or ""
  check("#119 question: shown with no git run first", asked ~= nil and at_question == 0, vim.inspect(calls))
  check("#119 question: each worktree, removed if clean, kept if it has changes", q:find("After you answer:", 1, true)
    and q:find("its worktree clean-wi11901 - removed if clean, kept if it has changes", 1, true)
    and q:find("its worktree dirty-wi11901 -", 1, true) and q:find("its worktree broken-wi11901 -", 1, true), q)
  check("#119 cancel: no git at all, everything stays", #calls == 0 and exists(key) and row_of(key) ~= nil, vim.inspect(calls))

  -- Discard.
  local finished = false
  calls, held, asked, said, at_question, answer = {}, {}, nil, {}, nil, true
  PD.ask({ key = key }, function() finished = true end)
  check("#119 discard: the question still came with no git", asked ~= nil and at_question == 0, vim.inspect(calls))
  check("#119 discard: the plan is gone before any git job answers", finished and #held > 0 and not exists(key)
    and #discarded(key) == 3 and CHAT.find_conversation(key) == nil and row_of(key) == nil and #said == 0,
    vim.inspect({ finished, #held, said }))
  check("#119 discard: all worktrees checked in parallel", count("status") == 3 and #held == 3 and #removes() == 0,
    vim.inspect(calls))
  release()
  check("#119 discard: only the clean worktree is removed", #removes() == 1 and removes()[1] == clean, vim.inspect(removes()))
  check("#119 discard: one toast, removed and kept, and why", #said == 1
    and said[1]:find("Removed its worktree " .. clean, 1, true)
    and said[1]:find("its worktree " .. dirty .. " (1 uncommitted file)", 1, true)
    and said[1]:find("its worktree " .. broken .. " (git couldn't tell what's in it)", 1, true), vim.inspect(said))

  -- Discarding again while the first discard's jobs run: never twice.
  id = 11902
  key = make_plan(id)
  local again = fake_worktree("again", id)
  calls, held, said = {}, {}, {}
  PD.ask({ key = key })
  check("#119 twice: the first discard is checking it", count("status") == 1 and #said == 0, vim.inspect(calls))
  make_plan(id)  -- a new plan under the same key, discarded while the first's jobs run
  PD.ask({ key = key })
  check("#119 twice: the second leaves it to the first", count("status") == 1 and #said == 1
    and said[1]:find("its worktree " .. again .. " (an earlier discard is still checking it)", 1, true), vim.inspect(said))
  release()
  check("#119 twice: removed once", #removes() == 1 and removes()[1] == again and #said == 2
    and said[2]:find("Removed its worktree " .. again, 1, true), vim.inspect({ removes(), said }))

  -- gD goes through the same flow: no git before the question or on
  -- Cancel; the tab closes before any git job answers.
  id = 11903
  key = make_plan(id)
  make_conv(key, id)
  local gdwt = fake_worktree("gd", id)
  PLAN.open(key)
  local tab = PLAN.current().tab
  local function gd()
    vim.api.nvim_set_current_win(PLAN.current().plan_win)
    calls, held, asked, said, at_question = {}, {}, nil, {}, nil
    vim.api.nvim_feedkeys(require("azure-cli.keys").first("plan", "discard"), "x", false)
  end
  answer = false
  gd()
  check("#119 gD cancel: asked with no git, none after", asked ~= nil and at_question == 0 and #calls == 0
    and vim.api.nvim_tabpage_is_valid(tab) and exists(key), vim.inspect(calls))
  answer = true
  gd()
  check("#119 gD discard: asked with no git, the tab closed before git answers", asked ~= nil and at_question == 0
    and not vim.api.nvim_tabpage_is_valid(tab) and not exists(key) and #held == 1 and #said == 0, vim.inspect(calls))
  release()
  check("#119 gD discard: the clean worktree removed, one toast", #removes() == 1 and removes()[1] == gdwt and #said == 1
    and said[1]:find("Removed its worktree " .. gdwt, 1, true), vim.inspect(said))

  meanwhile = nil
  TOOLS.git = real_git
end

print(fails == 0 and "all plan-discard tests passed" or (fails .. " plan-discard test(s) failed"))
vim.cmd(fails == 0 and "qa!" or "cq!")
