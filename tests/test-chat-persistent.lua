-- test-chat-persistent.lua: agent.persistent (chat/init.lua) actually
-- keeps one process alive across messages instead of starting a fresh one
-- each time, and the ordinary one-shot/followup path still works the same
-- now that both share their turn-finishing code.
--
-- tests/fake-persistent-agent.py stands in for a CLI that supports Claude
-- Code's `-p --input-format stream-json --output-format stream-json`: it
-- answers on stdin/stdout without exiting between turns, and reports its
-- own pid and a turn counter so this can tell a reused process (same pid,
-- turn 1 then turn 2) from a respawned one, and a --marker-file records
-- every pid a process of this test run ever had so "only one was ever
-- started" doesn't rely on pids never repeating. tests/fake-oneshot-agent.py
-- stands in for a plain `-p`/`--resume` CLI for the other path.
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
  label = "Fake Persistent", persistent = true, timeout_seconds = 20,
  cmd = { py, fake, "--marker-file", marker },
  stdin = '{"type":"user","message":{"role":"user","content":[{"type":"text","text":{message_json}}]}}',
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

-- The ordinary one-shot path (no `persistent`): a fresh process per
-- message, `followup` picking up the session id - unaffected by sharing
-- turn-finishing code with the persistent path above.
do
  local oneshot = plugin_root .. "/tests/fake-oneshot-agent.py"
  require("azure-cli").setup({ chat = { agent = {
    label = "Fake One-shot", timeout_seconds = 20,
    cmd = { py, oneshot }, stdin = "{message}",
    followup = { cmd = { py, oneshot, "--resume", "{session_id}" }, stdin = "{message}" },
  } } })
  CHAT.new_chat(true)

  local o1, oerr1 = send_and_wait("first")
  check("one-shot: first message answers", o1 ~= nil and o1.status == "done", oerr1)
  check("one-shot: first message isn't resumed", o1 ~= nil and o1.text == "resumed: False, asked: first", o1 and o1.text)
  check("one-shot: no persistent job for a non-persistent agent", STATE.chat.persistent_job == nil)

  local o2, oerr2 = send_and_wait("second")
  check("one-shot: second message answers", o2 ~= nil and o2.status == "done", oerr2)
  check("one-shot: second message resumes the session via followup",
    o2 ~= nil and o2.text == "resumed: True, asked: second", o2 and o2.text)
end

if fails > 0 then
  print(fails .. " chat-persistent test(s) FAILED")
  vim.cmd("cquit 1")
else
  print("all chat-persistent tests passed")
end
