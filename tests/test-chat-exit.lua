-- test-chat-exit.lua: quitting Neovim while agents work (and more wait in
-- the queue) exits straight away. It used to hang: stopping a working agent
-- finished its answer, which started the next queued agent mid-exit - a
-- new process Neovim then waited for.
--
--   timeout 30 nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-chat-exit.lua"
-- prints CHAT-EXIT-STARTED once an agent works, then quits; the caller
-- checks it didn't take the whole timeout.
local root = vim.fn.getcwd()
local py = vim.fn.executable("python3") == 1 and "python3" or "python"
require("azure-cli").setup({ chat = { max_agents = 1, agent = { label = "Fake", timeout_seconds = 60,
  cmd = { py, root .. "/tests/fake-persistent-agent.py" } } } })
local AGENTS = require("azure-cli.chat.agents")
AGENTS.plan_prompt = function() return "answer slowly" end
AGENTS.start_for_items({ { id = 1, title = "one" }, { id = 2, title = "two" } })
vim.defer_fn(function()
  if AGENTS.working() == 1 and #AGENTS.queued() == 1 then io.stdout:write("CHAT-EXIT-STARTED\n") end
  vim.cmd("qa!")
end, 300)
