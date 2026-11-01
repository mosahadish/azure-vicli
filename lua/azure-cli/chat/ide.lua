-- lua/azure-cli/chat/ide.lua: an agent's worktree in your own IDE (gI on the
-- Agents screen and in a plan) - chat.ide, a command as a list or a shell
-- string, with {dir} for the worktree:
--
--   ide = { "code", "-n", "{dir}" }      -- VS Code, a new window
--   ide = "devenv.exe {dir}"             -- Visual Studio, opening the folder
--
-- Without {dir}, the worktree goes at the end. On Windows the string form
-- runs through the shell, which finds code.cmd and friends.
local M = {}

local function notify(msg) require("azure-cli.shell").notify(msg) end

-- The command that opens folder `dir` with `spec` (chat.ide): a list with
-- {dir} filled in, or a shell string with it quoted. Pure.
function M.command(spec, dir)
  local CORE = require("azure-cli.chat.core")
  if type(spec) == "table" then
    local cmd, has = {}, false
    for i, a in ipairs(spec) do
      if a:find("{dir}", 1, true) then has = true end
      cmd[i] = CORE.expand(a, { dir = dir })
    end
    if not has then cmd[#cmd + 1] = dir end
    return cmd
  end
  if not spec:find("{dir}", 1, true) then return spec .. " " .. vim.fn.shellescape(dir) end
  return CORE.expand(spec, { dir = dir }, vim.fn.shellescape)
end

-- Opens worktree `dir` (nil: the agent has none yet) in chat.ide, on its
-- own: it stays open when Neovim quits.
function M.open(dir)
  if not dir or dir == "" then return notify("No worktree for that agent yet.") end
  local spec = (require("azure-cli.config").get().chat or {}).ide
  if not spec then return notify("No IDE set: chat.ide (docs/chat.md).") end
  if vim.fn.isdirectory(dir) == 0 then return notify(dir .. " isn't there any more.") end
  local cmd = M.command(spec, dir)
  local ok, job = pcall(vim.fn.jobstart, cmd, { detach = true, cwd = dir })
  if not ok or job <= 0 then
    local name = type(cmd) == "table" and cmd[1] or cmd:match("^%S+")
    return notify("Couldn't start " .. tostring(name) .. ".")
  end
end

return M
