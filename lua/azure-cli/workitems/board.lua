-- lua/azure-cli/workitems/board.lua: which board the work-items screens
-- show - Azure DevOps work items (W) or a GitHub account's issues in its
-- Projects v2 project (I, github_issues.py) - and everything that differs
-- between the two, so workitems/{dashboard,view,detail,state_dialog}.lua
-- stay one set of screens:
--
--   M.get("azure" | "github") -> board {
--     host, ft, item_ft,  -- the screens' filetypes (home.lua finds tabs by them)
--     state,              -- where the screens keep their caches and hooks
--                         -- (WI_DETAIL_CACHE, WI_SPRINT_ITEMS, WI_ITEM_CHANGED, ...):
--                         -- STATE itself on Azure, so every existing reader
--                         -- keeps working; a table of its own on GitHub
--     run(args, opts),    -- RPC.run of the provider with `args`, and on GitHub
--                         -- AZVICLI_WI_HOST=github in that call's env only
--     ref(item),          -- what a provider call or a cache takes for an item:
--                         -- the id on Azure, the owner~repo~n key on GitHub
--     words, caps,        -- the screens' wording, and what this board can do
--   }
--   M.enabled(cb)   cb(true) once --boards says a GitHub account has issues:
--                   (asked once, kept in STATE.BOARDS); never called otherwise
--   M.has_issues()  the answer so far: true / false / nil (not known yet)
local M = {}

local STATE = require("azure-cli.state")

local WORDS = {
  azure = {
    item = "work item", items = "work items", Items = "Work items", Item = "Work item",
    sprint = "sprint", sprints = "sprints", quarter = "quarter", discussion = "Discussion", area = "Area",
    screen = "work items dashboard", config_hint = "gO edits work_items.assignee/types",
    service = "Azure DevOps",
  },
  github = {
    item = "issue", items = "issues", Items = "Issues", Item = "Issue",
    sprint = "iteration", sprints = "iterations", quarter = "project", discussion = "Comments", area = "Repository",
    screen = "issues dashboard", config_hint = "gO edits issues: (project, repo, scope)",
    service = "GitHub",
  },
}

-- What a board can do: linking PRs (gl/gL - on GitHub a "Closes #n" line
-- in the PR's description), the chat (gq) and planning agents (gP). Both
-- boards can since GITHUB_PLAN.md phase 6 stage 3; a key a board can't do
-- isn't bound there at all. Editing the description (gE, and a body with
-- n) is GitHub's only: an issue body is Markdown, but Azure's comes back
-- from --wi-detail as flattened HTML that a write would lose formatting to.
local CAPS = {
  azure = { links = true, chat = true, plan_agents = true, description = false },
  github = { links = true, chat = true, plan_agents = true, description = true },
}

local boards = {}

local function fresh_state()
  return {
    WI_SPRINT_ITEMS = {}, WI_DETAIL_CACHE = {}, WI_TRANS_CACHE = {}, WI_REASON_CACHE = {},
    WI_STATES_CACHE = {}, WI_TREE_KIDS = {}, WI_VIEW_RELOAD = {},
  }
end

function M.get(host)
  host = host == "github" and "github" or "azure"
  if boards[host] then return boards[host] end
  local B = { host = host, words = WORDS[host], caps = CAPS[host] }
  if host == "azure" then
    B.ft, B.item_ft, B.state, B.env = "azurecli-workitems", "azurecli-workitem", STATE, nil
    B.ref = function(it) return tostring(type(it) == "table" and it.id or it) end
  else
    STATE.ISSUES = STATE.ISSUES or fresh_state()
    B.ft, B.item_ft, B.state, B.env = "azurecli-issues", "azurecli-issue", STATE.ISSUES, { AZVICLI_WI_HOST = "github" }
    B.ref = function(it)
      if type(it) ~= "table" then return tostring(it) end
      return (it.key and it.key ~= "") and it.key or tostring(it.id)
    end
  end
  -- The sprint word for one tab: GitHub's milestone fallback says so.
  B.sprint_word = function(sp)
    if host == "github" and sp and type(sp.path) == "string" and sp.path:find("^milestone/") then
      return "milestone"
    end
    return B.words.sprint
  end
  -- `args`: the provider's flags ({"--wi-list", "sprints"}); opts as RPC.run's.
  -- The host switch rides in this call's own env, never in vim.env: rpc.lua
  -- forwards every global AZVICLI_* with every request, so a global one
  -- would reach W's calls too.
  B.run = function(args, opts)
    opts = opts or {}
    if B.env then opts.env = vim.tbl_extend("force", opts.env or {}, B.env) end
    return require("azure-cli.rpc").run(vim.list_extend(require("azure-cli.config").provider_argv(), args), opts)
  end
  boards[host] = B
  return B
end

-- A copy of the module in file `source` (detail.lua, state_dialog.lua) for
-- board B: the file run again, its M._board set to B, so every cache and
-- call in that copy is B's while its code stays written once. One per
-- board; the Azure board uses the module require() returns.
local copies = {}
function M.module_for(source, B)
  local key = source .. "\0" .. B.host
  if not copies[key] then
    local mod = dofile(source)
    if type(mod) ~= "table" then error("board.module_for: " .. source .. " returned no module") end
    mod._board = B
    copies[key] = mod
  end
  return copies[key]
end

-- --boards: {"workItems": bool, "issues": [{"owner", "project"}]}, from the
-- config alone. Asked once; callbacks queue until it answers.
local waiting = {}
local asked = false

function M.has_issues()
  local b = STATE.BOARDS
  if not b then return nil end
  return type(b.issues) == "table" and #b.issues > 0
end

function M.enabled(cb)
  local has = M.has_issues()
  if has ~= nil then
    if has then cb(true) end
    return
  end
  waiting[#waiting + 1] = cb
  if asked then return end
  asked = true
  local out = {}
  require("azure-cli.rpc").run(require("azure-cli.config").provider_argv("--boards"), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      local ok, data = pcall(vim.json.decode, table.concat(out, ""))
      STATE.BOARDS = (code == 0 and ok and type(data) == "table") and data or { issues = {} }
      local cbs = waiting
      waiting = {}
      if M.has_issues() then
        vim.schedule(function()
          for _, f in ipairs(cbs) do pcall(f, true) end
        end)
      end
    end,
  })
end

-- The GitHub account the Issues board is (--boards' first issues entry:
-- owner, project, scope, apiUrl), or {} before --boards answers / without.
function M.issues_account()
  local b = STATE.BOARDS
  return (b and type(b.issues) == "table" and b.issues[1]) or {}
end

-- Whether a sprint lists everyone's items (issues: scope: all) rather than
-- mine - only the empty-list message reads it.
function M.everyones(B)
  if B.host ~= "github" then return false end
  return M.issues_account().scope == "all"
end

-- For tests: forget the --boards answer (and ask again next time).
function M._reset()
  STATE.BOARDS, waiting, asked = nil, {}, false
end

return M
