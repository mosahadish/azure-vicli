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
