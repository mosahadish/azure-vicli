-- test-chat-persistent.lua: the chat (chat/init.lua) keeps one agent
-- process alive across messages instead of starting a fresh one each
-- time; gm starts a new one (with the conversation replayed), and a CLI
-- that exits after one answer is reported as one that can't stay running.
--
-- tests/fake-persistent-agent.py stands in for a CLI that supports Claude
-- Code's `-p --input-format stream-json --output-format stream-json`: it
-- answers on stdin/stdout without exiting between turns, and reports its
-- own pid and a turn counter so this can tell a reused process (same pid,
-- turn 1 then turn 2) from a respawned one, and a --marker-file records
-- every pid a process of this test run ever had so "only one was ever
-- started" doesn't rely on pids never repeating. tests/fake-oneshot-agent.py
-- stands in for a plain `-p` CLI that answers once and exits.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-persistent.lua
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local plugin_root = vim.fn.getcwd()
local fake = plugin_root .. "/tests/fake-persistent-agent.py"
local marker = vim.fn.tempname()
local py = vim.fn.executable("python3") == 1 and "python3" or "python"

require("azure-cli").setup({ chat = { agent = {
  label = "Fake Persistent", timeout_seconds = 20, models = { "fast", "smart" },
  cmd = { py, fake, "--marker-file", marker },
} } })

local CHAT = require("azure-cli.chat")
local STATE = require("azure-cli.state")
local win = vim.api.nvim_get_current_win()

local function send_and_wait(text)
  local done
  CHAT.send(text, { view_win = win, on_done = function() done = true end })
  local st = STATE.chat
  local entry = st.entries[#st.entries]
  local ok = vim.wait(20000, function() return done end, 20)
  if not ok then return nil, "no answer to " .. vim.inspect(text) .. ": " .. vim.inspect(entry) end
  return entry
end

local e1, err1 = send_and_wait("one")
check("turn 1 answers", e1 ~= nil and e1.status == "done", err1)
local pid1 = e1 and e1.text:match("pid (%d+)")
check("turn 1 reports a pid", pid1 ~= nil, e1 and e1.text)

local pj = STATE.chat.persistent_job
check("a persistent job is tracked after the first message", pj ~= nil and pj.job ~= nil)
check("that job is still running", pj ~= nil and vim.fn.jobwait({ pj.job }, 0)[1] == -1)

local e2, err2 = send_and_wait("two")
check("turn 2 answers", e2 ~= nil and e2.status == "done", err2)
local pid2 = e2 and e2.text:match("pid (%d+)")
check("turn 2 is turn 2, not a fresh conversation", e2 ~= nil and e2.text:match("^turn 2,") ~= nil, e2 and e2.text)
check("turn 2 ran on the same process as turn 1", pid1 ~= nil and pid1 == pid2, { pid1 = pid1, pid2 = pid2 })
check("still the same job object", pj == STATE.chat.persistent_job)
-- Each answer's cost is the growth of its process's running total.
check("cost: turn 1 costs what the process reported", e1 and math.abs((e1.cost or -1) - 0.01) < 1e-9 and e1.tokens == 15,
  e1 and vim.inspect({ e1.cost, e1.tokens }))
check("cost: turn 2 only its own share, not the running total", e2 and math.abs((e2.cost or -1) - 0.01) < 1e-9,
  e2 and e2.cost)
check("cost: the conversation's", math.abs((require("azure-cli.chat.core").cost_of(STATE.chat.entries) or 0) - 0.02) < 1e-9)

local pids = {}
for line in io.lines(marker) do pids[line] = true end
local count = 0
for _ in pairs(pids) do count = count + 1 end
check("only one process was ever started for both messages", count == 1, pids)

CHAT.new_chat(true)
vim.wait(2000, function() return vim.fn.jobwait({ pj.job }, 0)[1] ~= -1 end, 20)
check("a new chat stops the persistent process", vim.fn.jobwait({ pj.job }, 0)[1] ~= -1)
check("and forgets it", STATE.chat.persistent_job == nil)

os.remove(marker)

-- gm: the running process was started with the old model, so the next
-- message starts a new one, which gets the conversation replayed.
do
  CHAT.new_chat(true)
  local g1 = send_and_wait("before gm")
  local before = STATE.chat.persistent_job
  local real_select = require("azure-cli.prompt").select
  require("azure-cli.prompt").select = function(o, cb) for _, it in ipairs(o.items) do if it.value == "smart" then return cb(it) end end end
  CHAT.pick_model()
  require("azure-cli.prompt").select = real_select
  local g2, gerr = send_and_wait("after gm")
  check("gm: answers", g2 ~= nil and g2.status == "done", gerr)
  check("gm: a new process, its turn 1", g2 ~= nil and g2.text:match("^turn 1,") ~= nil, g2 and g2.text)
  check("gm: the conversation is replayed to it", g2 ~= nil and g2.mode == "replay", g2 and g2.mode)
  check("gm: the old process is stopped", g1 ~= nil and before ~= nil and vim.fn.jobwait({ before.job }, 1000)[1] ~= -1)
  CHAT.new_chat(true)
end

-- Two conversations at once: a plan's own (CHAT.conversation) and the
-- main one, each with its own process, answering into its own entries -
-- and the plan's isn't the conversation restored after a restart.
do
  CHAT.new_chat(true)
  local plan = CHAT.conversation("wi-7", { label = "#7", target = { work_item_id = 7 } })
  check("conversation: one per plan key", CHAT.conversation("wi-7") == plan)
  check("conversation: shares the panel's state", plan.wins == STATE.chat.wins and plan.sent == STATE.chat.sent)
  local done_plan, done_main
  local ep = CHAT.send("plan slowly", { conv = plan, view_win = win, on_done = function() done_plan = true end })
  local em = CHAT.send("main meanwhile", { view_win = win, on_done = function() done_main = true end })
  check("conversation: both started at once", ep ~= nil and em ~= nil)
  local ok = vim.wait(20000, function() return done_plan and done_main end, 20)
  check("conversation: both answered", ok)
  check("conversation: each answer in its own conversation",
    #plan.entries == 2 and plan.entries[2].text:find("plan slowly", 1, true)
      and STATE.chat.entries[#STATE.chat.entries].text:find("main meanwhile", 1, true)
      and not STATE.chat.entries[#STATE.chat.entries].text:find("plan slowly", 1, true), vim.inspect(plan.entries))
  check("conversation: the plan's agent got its id", plan.entries[2].text:find("[agent " .. plan.agent_id .. "]", 1, true) ~= nil,
    plan.entries[2].text)
  check("conversation: the main agent got none", not STATE.chat.entries[#STATE.chat.entries].text:find("[agent", 1, true))
  local p1 = plan.entries[2].text:match("pid (%d+)")
  local p2 = STATE.chat.entries[#STATE.chat.entries].text:match("pid (%d+)")
  check("conversation: two processes", p1 and p2 and p1 ~= p2, { p1, p2 })
  local cur = require("azure-cli.chat.store").load_current()
  check("conversation: the main one stays current", cur and cur.id == STATE.chat.conv_id, cur and cur.id)
  check("conversation: the panel still shows the main one", not STATE.chat.active)
  -- After a restart: the plan's conversation comes back (its plan must
  -- exist), its process doesn't - the next message replays it.
  local PLAN = require("azure-cli.chat.plan")
  PLAN.save({ key = "wi-7", target = { work_item_id = 7 }, title = "Seven", status = "draft",
    revisions = { { markdown = "# x" } }, threads = {} })
  local saved_id = plan.conv_id
  for _, c in ipairs(CHAT.conversations()) do
    if c.persistent_job then pcall(vim.fn.jobstop, c.persistent_job.job) end
  end
  STATE.chat.convs, STATE.chat.plans_restored = {}, nil
  CHAT.restore_plans()
  local back = CHAT.find_conversation("wi-7")
  check("restore: the plan's conversation is back", back and back.conv_id == saved_id and #back.entries == 2
    and back.entries[2].text:find("plan slowly", 1, true) and back.label == "#7" and back.title == "Seven",
    back and vim.inspect({ back.conv_id, #back.entries }))
  local done_again
  local again = CHAT.send("and again", { conv = back, view_win = win, on_done = function() done_again = true end })
  vim.wait(20000, function() return done_again end, 20)
  check("restore: its next message starts the agent and replays the conversation",
    again and again.mode == "replay" and again.status == "done", again and again.mode)
  plan = back
  for _, c in ipairs(CHAT.conversations()) do
    if c.persistent_job then pcall(vim.fn.jobstop, c.persistent_job.job) end
  end
  STATE.chat.convs = {}
  CHAT.new_chat(true)
end

-- Issue #29: what you send from the input box while the agent answers is
-- queued, shown as queued, and sent in order once the answer is done -
-- each a turn of its own; dd cancels one, cc edits one in place, and after
-- <C-c> the queue waits for you. The same in a plan's own conversation.
do
  CHAT.new_chat(true)
  CHAT.show(false)
  local st = STATE.chat
  local ib = CHAT._.input_buf()
  local ACT = require("azure-cli.chat.actions")
  local function input() return table.concat(vim.api.nvim_buf_get_lines(ib, 0, -1, false), "\n") end
  local function type_and_send(text, conv)
    vim.api.nvim_buf_set_lines(ib, 0, -1, false, vim.split(text, "\n"))
    return CHAT.send(nil, { view_win = win, conv = conv })
  end
  local function you_sent(text, conv)
    for _, e in ipairs((conv or st).entries) do if e.role == "you" and e.text == text then return true end end
    return false
  end
  local function answer_to(text, conv)
    local es = (conv or st).entries
    for i, e in ipairs(es) do
      if e.role == "you" and e.text == text and es[i + 1] and es[i + 1].status ~= "running" then return es[i + 1] end
    end
  end
  local function idle(conv)
    conv = conv or st
    return vim.wait(20000, function()
      local last = conv.entries[#conv.entries]
      return not conv.running and #(conv.queue or {}) == 0 and last and last.status ~= "running"
    end, 20)
  end
  local function log_lines()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= ib and vim.api.nvim_buf_is_valid(b) and vim.b[b].azure_cli_chat then
        return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"), b
      end
    end
    return ""
  end
  -- The cursor on the n-th queued message, in the conversation's window.
  local function on_queued(n)
    local _, lb = log_lines()
    local lw = lb and vim.fn.bufwinid(lb)
    if not lw or lw == -1 then return false end
    vim.api.nvim_set_current_win(lw)
    for row, at in pairs(CHAT._.entry_at()) do
      if at == "q" .. n then vim.api.nvim_win_set_cursor(lw, { row, 0 }) return true end
    end
    return false
  end

  check("queue: the input box is there", ib ~= nil and vim.api.nvim_buf_is_valid(ib))
  CHAT.send("one slowly", { view_win = win })
  check("queue: the agent is answering", CHAT.busy())
  local r = type_and_send("two")
  check("queue: sending meanwhile starts no turn", r == nil and not you_sent("two"))
  check("queue: it's queued", #(st.queue or {}) == 1 and st.queue[1].text == "two", vim.inspect(st.queue))
  check("queue: the input box is cleared", input() == "", input())
  check("queue: the conversation shows it queued", log_lines():find("queued (1 of 1)", 1, true) ~= nil, log_lines())
  check("queue: it keeps what you were looking at", type(st.queue[1].snap) == "table")
  check("queue: <Up> brings it back", st.sent[#st.sent] == "two")
  check("queue: answered once the turn ends", idle())
  local a2 = answer_to("two")
  check("queue: sent as the next turn", a2 ~= nil and a2.text:match("^turn 2,") ~= nil and a2.text:find("two", 1, true) ~= nil,
    a2 and a2.text)
  check("queue: no longer shown as queued", not log_lines():find("queued (", 1, true))

  -- Two queued: in order, each its own turn.
  CHAT.send("three slowly", { view_win = win })
  type_and_send("a")
  type_and_send("b")
  check("queue: two queued", #(st.queue or {}) == 2 and log_lines():find("queued (2 of 2)", 1, true) ~= nil)
  check("queue: both answered", idle())
  local aa, ab = answer_to("a"), answer_to("b")
  check("queue: in order, a turn each", aa and ab and aa.text:match("^turn 4,") and ab.text:match("^turn 5,"),
    vim.inspect({ aa and aa.text, ab and ab.text }))

  -- dd: cancelled, never sent.
  CHAT.send("four slowly", { view_win = win })
  type_and_send("drop me")
  check("queue: dd - the cursor on it", on_queued(1))
  ACT.queue_drop()
  check("queue: dd takes it out of the queue", #(st.queue or {}) == 0)
  check("queue: dd - the turn still ends", idle())
  vim.wait(300)
  check("queue: dd - it was never sent", not you_sent("drop me"))
  local nxt = send_and_wait("after drop")
  check("queue: dd - the agent never got it", nxt ~= nil and nxt.text:match("^turn 7,") ~= nil, nxt and nxt.text)

  -- cc: back in the input box, changed, and sent in its place.
  CHAT.send("five slowly", { view_win = win })
  type_and_send("x")
  type_and_send("after x")
  check("queue: cc - the cursor on it", on_queued(1))
  ACT.queue_edit()
  vim.cmd("stopinsert")
  check("queue: cc puts it in the input box", input() == "x" and st.queue[1].editing == true, input())
  type_and_send("y")
  check("queue: cc - sent again, it's back in its place, changed",
    #st.queue == 2 and st.queue[1].text == "y" and not st.queue[1].editing and st.queue[2].text == "after x",
    vim.inspect(st.queue))
  check("queue: cc - both answered", idle())
  local ay, ax = answer_to("y"), answer_to("after x")
  check("queue: cc - the change went, in order", ay and ax and not you_sent("x") and ay.text:match("^turn 9,")
    and ax.text:match("^turn 10,"), vim.inspect({ ay and ay.text, ax and ax.text }))

  -- <C-c>: what's queued is held until you send it (<CR> on it).
  CHAT.send("six slowly", { view_win = win })
  type_and_send("held one")
  CHAT.cancel_conversation(st)
  vim.wait(5000, function() return not CHAT.busy() end, 20)
  vim.wait(500)
  check("queue: after <C-c> it's held, not sent", #(st.queue or {}) == 1 and st.queue[1].held and not you_sent("held one"),
    vim.inspect(st.queue))
  check("queue: held says so", log_lines():find("held - ", 1, true) ~= nil)
  check("queue: <CR> on it - the cursor", on_queued(1))
  ACT.open_ref()
  check("queue: <CR> on a held one sends it", idle() and answer_to("held one") ~= nil and answer_to("held one").status == "done")

  -- A plan's own conversation: its own queue, drained into it.
  local plan = CHAT.conversation("wi-29", { label = "#29", target = { work_item_id = 29 } })
  CHAT.send("plan slowly", { conv = plan, view_win = win })
  type_and_send("plan two", plan)
  check("queue: a plan's agent's conversation queues in its own", #(plan.queue or {}) == 1 and #(st.queue or {}) == 0)
  check("queue: and drains there", idle(plan) and answer_to("plan two", plan) ~= nil and not you_sent("plan two"))
  for _, c in ipairs(CHAT.conversations()) do
    if c.persistent_job then pcall(vim.fn.jobstop, c.persistent_job.job) end
  end
  STATE.chat.convs = {}

  -- A new chat drops what's queued.
  CHAT.send("seven slowly", { view_win = win })
  type_and_send("gone")
  CHAT.new_chat(true)
  check("queue: a new chat drops it", st.queue == nil)
  vim.wait(5000, function() return not CHAT.busy() end, 20)
  CHAT.hide()
  CHAT.new_chat(true)
end

-- A plain one-shot CLI (answers one message, exits) can't stay running:
-- the message fails with an explanation instead of hanging.
do
  require("azure-cli").setup({ chat = { agent = {
    label = "Fake One-shot", timeout_seconds = 20,
    cmd = { py, plugin_root .. "/tests/fake-oneshot-agent.py" }, stdin = "{message}",
  } } })
  CHAT.new_chat(true)
  local o1, oerr = send_and_wait("first")
  check("one-shot: the message finishes", o1 ~= nil, oerr)
  check("one-shot: reported as a CLI that can't stay running",
    o1 ~= nil and (o1.status == "done" or o1.status == "failed (the agent exited)"), o1 and o1.status)
  vim.wait(3000, function() return STATE.chat.persistent_job == nil end, 20)
  check("one-shot: no process left behind once it exits", STATE.chat.persistent_job == nil)
  CHAT.new_chat(true)
end

if fails > 0 then
  print(fails .. " chat-persistent test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-persistent tests passed")
end
