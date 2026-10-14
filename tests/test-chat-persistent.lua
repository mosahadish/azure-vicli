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
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
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

-- #86: a plan no agent's conversation has (the main chat wrote it) gets an
-- idle one on restore - the Agents screen lists it, and approving it goes
-- to that agent, told the plan is its now. A finished one is left alone.
do
  local PLAN = require("azure-cli.chat.plan")
  PLAN.save({ key = "wi-8601", target = { work_item_id = 8601 }, title = "Orphan", status = "draft",
    revisions = { { by = "agent", markdown = "# Orphan" } }, threads = {} })
  PLAN.save({ key = "wi-8602", target = { work_item_id = 8602 }, title = "Finished", status = "done",
    revisions = { { by = "agent", markdown = "# Done" } }, threads = {} })
  STATE.chat.convs, STATE.chat.plans_restored = {}, nil
  CHAT.restore_plans()
  local c = CHAT.find_conversation("wi-8601")
  check("#86 restore: an orphan plan gets a conversation of its own, with a note",
    c and #c.entries == 1 and c.entries[1].role == "note" and c.entries[1].text:find("discard_plan", 1, true)
      and c.label == "#8601" and c.title == "Orphan", c and vim.inspect(c.entries))
  check("#86 restore: a finished one is left alone", CHAT.find_conversation("wi-8602") == nil)
  local rows = require("azure-cli.chat.agents_view").rows(CHAT.conversations(), {}, PLAN.load, os.time())
  local row
  for _, r in ipairs(rows) do if r.key == "wi-8601" then row = r end end
  check("#86 the Agents screen lists it as waiting for you", row and row.waiting and row.state:find("plan waits for you", 1, true),
    vim.inspect(row and row.state))
  local orig_send, sent = CHAT.send, nil
  CHAT.send = function(text, o) sent = { text = text, conv = o.conv } return {} end
  PLAN.approve("wi-8601")
  CHAT.send = orig_send
  check("#86 approving it goes to its own agent, told the plan is its now",
    sent and sent.conv == c and sent.text:find("it's yours now - read it with get_plan (work_item_id 8601)", 1, true)
      and sent.text:find("I approve the plan for #8601", 1, true), sent and sent.text)
  for _, k in ipairs({ "wi-8601", "wi-8602" }) do
    vim.fn.delete(PLAN.root() .. "/" .. k .. ".json")
    vim.fn.delete(PLAN.root() .. "/" .. k .. ".md")
  end
  STATE.chat.convs = {}
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

  -- Issue #60: the main chat's message_agent to that agent mid-turn
  -- queues in its queue, says so, and leaves the input box alone; the
  -- messages go in order once the turn ends. Idle, it still sends at once.
  local TOOLS = require("azure-cli.chat.tools")
  local function message(text)
    local res, err
    TOOLS.by_name.message_agent.run({ work_item_id = 29, message = text }, {}, function(r, e) res, err = r, e end)
    vim.wait(2000, function() return res ~= nil or err ~= nil end, 10)
    return res, err
  end
  CHAT.send("plan again slowly", { conv = plan, view_win = win })
  vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "half typed" })
  local q1, e1 = message("first tip")
  local q2 = message("second tip")
  check("message_agent: mid-turn it's queued, and says so", q1 and q1:find("Queued for #29's agent (1 of 1)", 1, true)
    and q1:find("delivered when that turn ends", 1, true), q1 or e1)
  check("message_agent: the second behind it", q2 and q2:find("(2 of 2)", 1, true), q2)
  check("message_agent: in that agent's queue", #(plan.queue or {}) == 2
    and plan.queue[1].display == "From the main chat: first tip" and plan.queue[2].display == "From the main chat: second tip",
    vim.inspect(plan.queue))
  check("message_agent: the input box is left alone", input() == "half typed", input())
  check("message_agent: list_agents counts them", (function()
    local listed
    TOOLS.by_name.list_agents.run({}, {}, function(r) listed = r end)
    for _, row in ipairs(type(listed) == "table" and listed or {}) do
      if row.queued_messages == 2 then return true end
    end
  end)())
  check("message_agent: both delivered once the turn ends", idle(plan))
  local first_at, second_at
  for i, e in ipairs(plan.entries) do
    if e.role == "you" and e.text == "From the main chat: first tip" then first_at = i end
    if e.role == "you" and e.text == "From the main chat: second tip" then second_at = i end
  end
  check("message_agent: in order, each answered", first_at and second_at and first_at < second_at
    and plan.entries[first_at + 1].status == "done" and plan.entries[second_at + 1].status == "done",
    vim.inspect({ first_at, second_at }))
  local sent = message("third tip")
  check("message_agent: idle, it's sent at once", sent and sent:find("Sent to #29's agent", 1, true), sent)
  idle(plan)
  vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "" })
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

-- Issue #27: the timeout is an idle one (no output for N seconds) plus a
-- separate cap on the whole turn, and the chat says which one fired.
do
  local function timeouts(idle, cap)
    require("azure-cli").setup({ chat = { agent = {
      label = "Fake Persistent", idle_timeout_seconds = idle, max_turn_seconds = cap,
      cmd = { py, fake },
    } } })
    CHAT.new_chat(true)
  end
  local function said(e, s)
    for _, l in ipairs(e and e.tools or {}) do if l:find(s, 1, true) then return true end end
    return false
  end

  timeouts(1, 30)
  local q, qerr = send_and_wait("go quiet")
  check("timeout: the idle one fires when the agent goes quiet", q ~= nil and q.status == "timed out (idle 1s)",
    qerr or (q and q.status))
  check("timeout: it says which, after how long, and the setting",
    said(q, "timed out: no output from the agent for 1s") and said(q, "idle_timeout_seconds = 1"), q and vim.inspect(q.tools))
  check("timeout: it took about the idle time, not the agent's 6s", q and os.time() - q.started <= 4,
    q and (os.time() - q.started))
  check("timeout: what it said so far stays", q and q.text:find("Thinking...", 1, true) ~= nil, q and q.text)
  check("timeout: the agent isn't running any more", not CHAT.busy())
  local nx, nxerr = send_and_wait("after the timeout")
  check("timeout: the next message still gets answered", nx ~= nil and nx.status == "done", nxerr or (nx and nx.status))
  -- Issue #65: the turn was interrupted, not the process killed.
  check("timeout: by the same process, its turn 2 - not a replay",
    nx ~= nil and nx.text:match("^turn 2,") ~= nil and nx.mode ~= "replay", nx and (nx.text .. " " .. tostring(nx.mode)))

  -- Output every 0.3s for 3s: three times the idle timeout - the old wall
  -- clock of that length would have stopped it.
  local s, serr = send_and_wait("stream steadily")
  check("timeout: steady output past the old wall-clock limit doesn't time out", s ~= nil and s.status == "done",
    serr or (s and (s.status .. " " .. vim.inspect(s.tools))))
  check("timeout: its answer arrived", s and s.text:find(": stream steadily", 1, true) ~= nil, s and s.text)

  timeouts(30, 1)
  local c, cerr = send_and_wait("stream steadily")
  check("timeout: the cap fires however steady the output", c ~= nil and c.status == "timed out (cap 1s)",
    cerr or (c and c.status))
  check("timeout: the cap names itself", said(c, "the turn ran 1s, the cap (max_turn_seconds = 1)")
    and not said(c, "idle_timeout_seconds"), c and vim.inspect(c.tools))
  check("timeout: and not the agent's last chunk", c and not c.text:find("chunk 9", 1, true), c and c.text)

  -- The Agents screen says it too, ahead of an approved plan's "approved".
  local AV = require("azure-cli.chat.agents_view")
  local rows = AV.rows({ { plan_key = "wi-27", entries = STATE.chat.entries } }, {},
    function() return { status = "approved", title = "T" } end, os.time())
  check("timeout: the Agents screen shows which one fired", rows[1] and rows[1].state == "\u{2717} timed out (cap 1s)",
    rows[1] and rows[1].state)
  CHAT.new_chat(true)
end

-- Issue #65: a timed-out or stopped Claude Code turn is interrupted with a
-- stream-json control_request, so the process - its session, its worktree
-- - takes the next message. An agent that ignores the interrupt is killed
-- after interrupt_grace_seconds, and the chat says so.
do
  local mk, clog = vim.fn.tempname(), vim.fn.tempname()
  local function agent(idle, cap, grace)
    require("azure-cli").setup({ chat = { agent = {
      label = "Fake Persistent", idle_timeout_seconds = idle, max_turn_seconds = cap,
      interrupt_grace_seconds = grace or 1,
      cmd = { py, fake, "--marker-file", mk, "--control-log", clog },
    } } })
    CHAT.new_chat(true)
    os.remove(mk)
    os.remove(clog)
  end
  local function lines_of(path)
    local t = {}
    if vim.fn.filereadable(path) == 1 then for l in io.lines(path) do t[#t + 1] = l end end
    return t
  end
  local function said_at(e, s)
    for i, l in ipairs(e and e.tools or {}) do if l:find(s, 1, true) then return i end end
  end
  local function pid_of(e) return e and e.text:match("pid (%d+)") end
  local KEPT = "interrupted - the session stays, your next message continues it"
  local KILLED = "so it was killed - your next message starts it again and replays the conversation"

  -- Idle timeout, interrupt honoured.
  agent(1, 30)
  local h = send_and_wait("hello")
  local pid0 = pid_of(h)
  local t0 = os.time()
  local q, qerr = send_and_wait("go quiet")
  check("interrupt: the idle timeout still says so", q ~= nil and q.status == "timed out (idle 1s)", qerr or (q and q.status))
  check("interrupt: #27's line first, then that the session stays",
    (said_at(q, "no output from the agent for 1s") or 99) < (said_at(q, KEPT) or 0), q and vim.inspect(q.tools))
  check("interrupt: no kill", not said_at(q, "killed"), q and vim.inspect(q.tools))
  check("interrupt: the agent got one control_request, an interrupt",
    vim.deep_equal(lines_of(clog), { "interrupt" }), vim.inspect(lines_of(clog)))
  check("interrupt: it ended on the agent's result, not the 6s it would have taken", os.time() - t0 <= 4, os.time() - t0)
  check("interrupt: what it said so far stays", q and q.text:find("Thinking...", 1, true) ~= nil, q and q.text)
  local n, nerr = send_and_wait("next")
  check("interrupt: the next message is the same process's next turn",
    n ~= nil and n.status == "done" and n.text:match("^turn 3,") ~= nil and pid_of(n) == pid0 and n.mode ~= "replay",
    nerr or (n and (n.text .. " " .. tostring(n.mode))))
  check("interrupt: only one process ever started", #lines_of(mk) == 1, vim.inspect(lines_of(mk)))

  -- Idle timeout, interrupt ignored: killed after the grace period.
  t0 = os.time()
  local d, derr = send_and_wait("go quiet and ignore interrupts")
  check("ignored: killed, and the status says so", d ~= nil and d.status == "timed out (idle 1s, killed)",
    derr or (d and d.status))
  check("ignored: #27's line, then why it was killed",
    (said_at(d, "no output from the agent for 1s") or 99)
      < (said_at(d, "the agent didn't stop within 1s of the interrupt, " .. KILLED) or 0), d and vim.inspect(d.tools))
  check("ignored: not said to be kept", not said_at(d, KEPT), d and vim.inspect(d.tools))
  check("ignored: within idle + grace, not the agent's 6s", os.time() - t0 <= 5, os.time() - t0)
  local r, rerr = send_and_wait("after the kill")
  check("ignored: the next message starts a new process and replays",
    r ~= nil and r.status == "done" and r.mode == "replay" and r.text:match("^turn 1,") ~= nil and pid_of(r) ~= pid0,
    rerr or (r and (r.text .. " " .. tostring(r.mode))))

  -- The hard cap, honoured, then ignored.
  agent(30, 1)
  h = send_and_wait("hello")
  pid0 = pid_of(h)
  local c, cerr = send_and_wait("stream steadily")
  check("cap: still the cap's status", c ~= nil and c.status == "timed out (cap 1s)", cerr or (c and c.status))
  check("cap: the cap's line, then that the session stays",
    (said_at(c, "the turn ran 1s, the cap (max_turn_seconds = 1)") or 99) < (said_at(c, KEPT) or 0),
    c and vim.inspect(c.tools))
  check("cap: it stopped streaming", c and not c.text:find("chunk 9", 1, true), c and c.text)
  n, nerr = send_and_wait("next")
  check("cap: the next message is the same process's next turn",
    n ~= nil and n.text:match("^turn 3,") ~= nil and pid_of(n) == pid0, nerr or (n and n.text))
  local ck, ckerr = send_and_wait("stream steadily and ignore interrupts")
  check("cap: ignored, killed", ck ~= nil and ck.status == "timed out (cap 1s, killed)", ckerr or (ck and ck.status))
  check("cap: says why", said_at(ck, "didn't stop within 1s of the interrupt") ~= nil, ck and vim.inspect(ck.tools))

  -- <C-c> (the chat's, and the Agents screen's): interrupted, the session
  -- kept; a second one while it's interrupting kills at once.
  agent(30, 30, 10)
  h = send_and_wait("hello")
  pid0 = pid_of(h)
  local function start(text)
    CHAT.send(text, { view_win = win })
    local e = STATE.chat.entries[#STATE.chat.entries]
    vim.wait(5000, function() return e.text:find("Thinking...", 1, true) ~= nil end, 20)
    return e
  end
  local function settle(e) vim.wait(5000, function() return e.status ~= "running" end, 20) return e end
  local s = start("go quiet")
  require("azure-cli.chat.run").cancel()  -- the chat's <C-c>
  settle(s)
  check("<C-c>: stopped", s.status == "stopped", s.status)
  check("<C-c>: the session stays", said_at(s, KEPT) ~= nil, vim.inspect(s.tools))
  n, nerr = send_and_wait("next")
  check("<C-c>: the next message is the same process's",
    n ~= nil and n.text:match("^turn 3,") ~= nil and pid_of(n) == pid0, nerr or (n and n.text))
  s = start("go quiet")
  CHAT.cancel_conversation(STATE.chat)
  settle(s)
  check("Agents <C-c>: interrupted too", s.status == "stopped" and said_at(s, KEPT) ~= nil, s.status)
  t0 = os.time()
  s = start("go quiet and ignore interrupts")
  require("azure-cli.chat.run").cancel()  -- the chat's <C-c>
  require("azure-cli.chat.run").cancel()  -- the chat's <C-c>
  settle(s)
  check("<C-c> twice: killed at once, not after the 10s grace", s.status == "stopped (killed)" and os.time() - t0 <= 4,
    s.status .. " after " .. (os.time() - t0))
  check("<C-c> twice: says so", said_at(s, "stopped again while interrupting, " .. KILLED) ~= nil, vim.inspect(s.tools))

  -- Sent while a turn is being interrupted: it waits, then goes to the
  -- same process.
  agent(1, 30)
  h = send_and_wait("hello")
  pid0 = pid_of(h)
  CHAT.show(false)
  local ib = CHAT._.input_buf()
  CHAT.send("go quiet", { view_win = win })
  local quiet = STATE.chat.entries[#STATE.chat.entries]
  vim.wait(5000, function() return said_at(quiet, "interrupting the turn") ~= nil end, 20)
  vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "queued one" })
  CHAT.send(nil, { view_win = win })
  check("queued: it waits while the turn is interrupted", #(STATE.chat.queue or {}) == 1, vim.inspect(STATE.chat.queue))
  vim.wait(10000, function()
    local last = STATE.chat.entries[#STATE.chat.entries]
    return not STATE.chat.running and #(STATE.chat.queue or {}) == 0 and last.role == "agent" and last.status ~= "running"
  end, 20)
  local last = STATE.chat.entries[#STATE.chat.entries]
  check("queued: then goes to the same process", last.text:find(": queued one", 1, true) ~= nil and pid_of(last) == pid0,
    last.text)
  CHAT.new_chat(true)
  os.remove(mk)
  os.remove(clog)
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
