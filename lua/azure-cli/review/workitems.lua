-- lua/azure-cli/review/workitems.lua: gW in the reviewer (file list, diff
-- and overview) - open a work item linked to the PR under review, through
-- pr_workitems.lua, the same helper the PR dashboard's gW uses. The
-- reviewer's process env already names the PR (see dashboard.lua's
-- set_pr_env), so no env is passed.
local M = {}

local function setup(ctx)
  for _, kind in ipairs({ "list", "diff", "overview" }) do
    ctx.add_key(kind, "open_workitem", function()
      require("azure-cli.pr_workitems").choose(ctx.ID, nil)
    end, "open a work item linked to this PR")
  end
  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
