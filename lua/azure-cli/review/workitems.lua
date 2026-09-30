-- lua/azure-cli/review/workitems.lua: gW/gl/gL in the reviewer (file list,
-- diff and overview) - the work items linked to the PR under review, and
-- linking/unlinking one, through pr_workitems.lua like the PR dashboard. The
-- reviewer's process env already names the PR (see dashboard.lua's
-- set_pr_env), so no env is passed. The popup opens mid-screen here.
local M = {}

-- This PR's record: the PR list's (it has org/project/repo), else built
-- from what the reviewer was opened with.
local function pr_record(ctx)
  local rec = ctx.current_pr_record()
  if rec then return rec end
  return { id = ctx.ID, org = ctx.ORG, project = ctx.PROJECT, repo = vim.env.AZVICLI_REPO or "" }
end

local function setup(ctx)
  local PW = function() return require("azure-cli.pr_workitems") end
  for _, kind in ipairs({ "list", "diff", "overview" }) do
    ctx.add_key(kind, "open_workitem", function() PW().choose(pr_record(ctx), nil, true) end,
      "the work items linked to this PR (<CR> open, gs state, gl link, gL unlink)")
    ctx.add_key(kind, "link_workitem", function() PW().link_item(pr_record(ctx)) end,
      "link a work item to this PR")
    ctx.add_key(kind, "unlink_workitem", function() PW().unlink_item(pr_record(ctx), nil) end,
      "unlink a work item from this PR")
  end
  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
