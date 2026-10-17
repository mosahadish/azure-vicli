-- lua/azure-cli/chat/refs.lua: pull requests and work items named in the
-- chat - "!101", "#3001", "PR 101".
--
--   resolve      a reference -> the PR record from the dashboard's list, or
--                a work item (from the work-items list when it's loaded)
--   describe     a few lines about every item a message names, sent with
--                it so the agent needn't look each one up
--   at           the reference under a cursor column in a line
--   open         <CR> in the conversation: a PR opens in the reviewer, a
--                work item in its detail view
--   complete     the input box's completion after "!" or "#"
local M = {}

local function STATE() return require("azure-cli.state") end

local function pr_by_id(id)
  for _, p in ipairs((STATE().PR_LIST_CACHE or {}).prs or {}) do
    if tostring(p.id) == tostring(id) then return p end
  end
  return nil
end

local function wi_by_id(id)
  for _, it in ipairs((STATE().WI_LIST_CACHE or {}).items or {}) do
    if type(it) == "table" and tostring(it.id) == tostring(id) then return it end
  end
  return nil
end

-- Every issue the Issues board (I) has listed this session, once each.
local function issues()
  local out, seen = {}, {}
  local S = STATE().ISSUES
  for _, c in pairs((S and S.WI_SPRINT_ITEMS) or {}) do
    for _, it in ipairs(c.items or {}) do
      local k = type(it) == "table" and it.id and (it.key or tostring(it.id))
      if k and not seen[k] then
        seen[k] = true
        out[#out + 1] = it
      end
    end
  end
  return out
end

local function issue_by_id(id)
  for _, it in ipairs(issues()) do
    if tostring(it.id) == tostring(id) then return it end
  end
  return nil
end

-- Whether a "#n" no list knows is more likely an issue: the config has the
-- Issues board and no Azure one.
local function issues_only()
  local b = STATE().BOARDS
  return b ~= nil and not b.workItems and require("azure-cli.workitems.board").has_issues() == true
end

-- { kind = "pr", id, pr } or { kind = "wi", id, item, board } for a
-- find_refs entry. A bare "#" is a PR when one with that id is in the list,
-- else a work item - an Azure one when its list has it, else an issue from
-- the Issues board's (board = "github").
function M.resolve(ref)
  local pr = pr_by_id(ref.id)
  if ref.kind == "pr" or pr then return { kind = "pr", id = ref.id, pr = pr } end
  local item = wi_by_id(ref.id)
  if item then return { kind = "wi", id = ref.id, item = item } end
  local issue = issue_by_id(ref.id)
  if issue or issues_only() then return { kind = "wi", id = ref.id, item = issue, board = "github" } end
  return { kind = "wi", id = ref.id }
end

function M.describe(text)
  local CORE = require("azure-cli.chat.core")
  local out = {}
  for _, ref in ipairs(CORE.find_refs(text or "")) do
    local r = M.resolve(ref)
    if r.kind == "pr" and r.pr then
      local p = r.pr
      out[#out + 1] = "- PR !" .. p.id .. " \"" .. (p.title or "") .. "\" in " .. (p.repo or "?") .. " ("
        .. (p.source or "?") .. " -> " .. (p.target or "?") .. "), by " .. (p.author or "?")
    elseif r.kind == "pr" then
      out[#out + 1] = "- PR !" .. r.id .. " (not in the user's PR list)"
    elseif r.item and r.board == "github" then
      local w = r.item
      out[#out + 1] = "- issue #" .. w.id .. (w.repo and (" in " .. w.repo) or "") .. " \"" .. (w.title or "") .. "\" ["
        .. (w.state or "?") .. "]" .. ((w.assignedTo and w.assignedTo ~= "") and (", " .. w.assignedTo) or "")
        .. " (GitHub - the board tools take board = \"github\")"
    elseif r.item then
      local w = r.item
      out[#out + 1] = "- work item #" .. w.id .. " " .. (w.type or "") .. " \"" .. (w.title or "") .. "\" ["
        .. (w.state or "?") .. "]" .. ((w.assignedTo and w.assignedTo ~= "") and (", " .. w.assignedTo) or "")
    elseif r.board == "github" then
      local acct = require("azure-cli.workitems.board").issues_account()
      out[#out + 1] = "- #" .. r.id .. " (an issue in project " .. tostring(acct.project or "?")
        .. ", probably - get_work_item with board = \"github\" reads it)"
    else
      out[#out + 1] = "- #" .. r.id .. " (a work item, probably - get_work_item reads it)"
    end
  end
  return table.concat(out, "\n")
end

-- The reference covering byte `col` (0-based) of `line`, or nil.
function M.at(line, col)
  local _, all = require("azure-cli.chat.core").find_refs(line or "")
  for _, r in ipairs(all) do
    if col + 1 >= r.s and col + 1 <= r.e then return r end
  end
  return nil
end

function M.open(ref)
  local r = M.resolve(ref)
  if r.kind == "pr" then
    if not r.pr then
      require("azure-cli.shell").notify("PR !" .. r.id .. " isn't in your PR list.", vim.log.levels.WARN)
      return
    end
    require("azure-cli").open_review(r.id)
  elseif r.board == "github" then
    require("azure-cli.pr_workitems").open_item(r.id, require("azure-cli.workitems.board").get("github"),
      r.item and r.item.key or nil)
  else
    require("azure-cli.pr_workitems").open_item(r.id)
  end
end

-- Completion items for what's typed after `sigil` ("!" or "#"): PRs from
-- the dashboard's list ("!" and "#"), work items from the work-items list
-- and issues from the Issues board ("#" only), filtered by the digits
-- typed so far.
function M.complete(sigil, typed)
  local items = {}
  for _, p in ipairs((STATE().PR_LIST_CACHE or {}).prs or {}) do
    if tostring(p.id):find("^" .. typed) then
      items[#items + 1] = { word = sigil .. p.id, menu = "PR  " .. (p.title or ""):sub(1, 50) }
    end
  end
  if sigil == "#" then
    for _, w in ipairs((STATE().WI_LIST_CACHE or {}).items or {}) do
      if type(w) == "table" and w.id and tostring(w.id):find("^" .. typed) then
        items[#items + 1] = { word = "#" .. w.id, menu = (w.type or "item") .. "  " .. (w.title or ""):sub(1, 50) }
      end
    end
    for _, w in ipairs(issues()) do
      if tostring(w.id):find("^" .. typed) then
        items[#items + 1] = { word = "#" .. w.id, menu = "issue  " .. (w.title or ""):sub(1, 50) }
      end
    end
  end
  return items
end

return M
