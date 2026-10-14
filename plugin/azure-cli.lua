-- plugin/azure-cli.lua: defines the :AzureCli user command. Loaded
-- automatically by any plugin manager that puts this repo on 'rtp' (lazy.nvim,
-- packer, vim-plug, ...) - no side effects beyond defining the command, so
-- loading this file never itself starts a job, opens a buffer, or requires
-- setup() to have run first (every surface applies config.lua's defaults
-- until setup() says otherwise).
if vim.g.loaded_azure_cli then
  return
end
vim.g.loaded_azure_cli = true

local SUBCOMMANDS = { "dashboard", "review", "workitems", "issues", "chat", "agents", "doctor", "toasts", "status", "log",
  "perf", "web", "options", "help" }
local WEB_ACTIONS = { "start", "stop", "status" }

local function show_help()
  local lines = {
    "AzureCli commands",
    "",
    "  :AzureCli dashboard   open the pull-request dashboard",
    "  :AzureCli review <id> open the reviewer for pull request <id>",
    "  :AzureCli workitems   open the work-items dashboard",
    "  :AzureCli issues      open the issues dashboard (a GitHub account's issues: project)",
    "  :AzureCli chat        show/hide the chat panel (gq on any azure-cli screen)",
    "  :AzureCli agents      every plan's agent: what each is doing",
    "  :AzureCli doctor      check the setup: Neovim, python, config, sign-in per organization",
    "  :AzureCli toasts      toggle desktop notifications for this session",
    "  :AzureCli status      show the provider daemon's status",
    "  :AzureCli log         show this session's error log",
    "  :AzureCli perf        request timings logged with AZVICLI_DEBUG=1: per screen, slowest, per endpoint",
    "  :AzureCli web start|stop|status  the phone dashboard: a read-only web page of the Agents screen",
    "  :AzureCli options    every option at its default: azure-cli.lua (standalone), or a list to copy into setup()",
    "  :AzureCli help        this message",
  }
  vim.notify(table.concat(lines, "\n"))
end

local function dispatch(opts)
  local args = opts.fargs
  local sub = args[1] or "dashboard"
  if vim.fn.has("nvim-0.9") == 0 then
    vim.notify("azure-cli needs Neovim 0.9 or newer (this is " .. tostring(vim.version and vim.version().major or "?")
      .. "." .. tostring(vim.version and vim.version().minor or "?") .. ").", vim.log.levels.ERROR)
    return
  end
  local azure_cli = require("azure-cli")

  if sub == "doctor" then
    require("azure-cli.health").open()
  elseif sub == "dashboard" then
    azure_cli.open_dashboard()
  elseif sub == "review" then
    local id = args[2]
    if not id then
      vim.notify("azure-cli: :AzureCli review needs a pull request id", vim.log.levels.ERROR)
      return
    end
    azure_cli.open_review(id)
  elseif sub == "workitems" then
    azure_cli.open_workitems()
  elseif sub == "issues" then
    azure_cli.open_issues()
  elseif sub == "chat" then
    require("azure-cli.chat").toggle()
  elseif sub == "agents" then
    require("azure-cli.chat.agents_view").open()
  elseif sub == "toasts" then
    azure_cli.toggle_toasts()
  elseif sub == "status" then
    azure_cli.status()
  elseif sub == "log" then
    require("azure-cli.log").open()
  elseif sub == "perf" then
    require("azure-cli.perf").open()
  elseif sub == "web" then
    require("azure-cli.web").command(args[2])
  elseif sub == "options" then
    require("azure-cli.shell").open_options_file()
  elseif sub == "help" then
    show_help()
  else
    vim.notify("azure-cli: unknown subcommand '" .. sub .. "' (see :AzureCli help)", vim.log.levels.ERROR)
  end
end

vim.api.nvim_create_user_command("AzureCli", dispatch, {
  nargs = "*",
  desc = "Azure DevOps dashboard (dashboard | review <id> | workitems | chat | agents | doctor | toasts | status | log | perf | web | options | help)",
  complete = function(arg_lead, cmd_line, _)
    if cmd_line:match("^%s*%S+%s+web%s+%S*$") then
      return vim.tbl_filter(function(s) return s:find(arg_lead, 1, true) == 1 end, WEB_ACTIONS)
    end
    local parts = vim.split(vim.trim(cmd_line), "%s+")
    -- parts[1] is "AzureCli" itself; completing the subcommand while only
    -- one argument has been typed so far (plus whatever's still being typed).
    if #parts <= 2 then
      return vim.tbl_filter(function(s) return s:find(arg_lead, 1, true) == 1 end, SUBCOMMANDS)
    end
    return {}
  end,
})
