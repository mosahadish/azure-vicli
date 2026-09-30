-- lua/azure-cli/workitems/linked_prs.lua: the pull requests linked to a
-- work item - the dashboard row's "!101" marker, the detail view's Pull
-- Requests block, and gR, which opens one.
--
-- List records carry only the linked ids ({id}); --wi-detail adds each
-- PR's title, status, repo, branches, author and web url. gR opens a PR
-- in the reviewer when the PR dashboard's list has it (the reviewer needs
-- that record), otherwise in the browser - a completed PR, or one you're
-- not on.
--
-- The pure half (M.marker, M.status, M.lines) runs under plain luajit for
-- tests/test-linked-prs.lua.
local M = {}

-- The dashboard row's marker: "" / "!101" / "!101 +2".
function M.marker(prs)
  if not prs or #prs == 0 then return "" end
  local s = "!" .. tostring(prs[1].id)
  if #prs > 1 then s = s .. " +" .. (#prs - 1) end
  return s
end

-- "draft" for an active draft, else ADO's status ("active", "completed",
-- "abandoned"); "" when the detail couldn't read the PR.
function M.status(pr)
  if pr.isDraft and pr.status == "active" then return "draft" end
  return pr.status or ""
end

-- The detail view's lines for one PR: id, status and title, then where
-- it goes and who opened it. Just the id when the PR couldn't be read.
function M.lines(pr)
  local head = string.format("  !%-6s %-10s %s", tostring(pr.id), M.status(pr), pr.title or "")
  head = head:gsub("%s+$", "")
  if not pr.repo or pr.repo == "" then return { head } end
  local where = "           " .. pr.repo .. "  " .. (pr.source or "") .. " \u{2192} " .. (pr.target or "")
  if pr.author and pr.author ~= "" then where = where .. "  \u{00B7}  " .. pr.author end
  return { head, where }
end

-- The PR dashboard's record for `id`, when its list has one.
local function listed(id)
  local cache = require("azure-cli.state").PR_LIST_CACHE
  for _, p in ipairs((cache and cache.prs) or {}) do
    if tostring(p.id) == tostring(id) then return p end
  end
  return nil
end

-- Open `pr` ({id, url?}) linked to work item `item_id`: in the reviewer
-- when the PR list has it, else in the browser - fetching the item's
-- detail first when `pr` has no url yet (the dashboard's ids-only records).
function M.open(pr, item_id)
  local notify = require("azure-cli.shell").notify
  if listed(pr.id) then
    require("azure-cli").open_review(pr.id)
    return
  end
  if pr.url and pr.url ~= "" then
    notify("!" .. pr.id .. " isn't in your PR list; opening it in the browser.")
    require("azure-cli.shell").open_url(pr.url)
    return
  end
  if pr.fetched or not item_id then
    notify("Can't open !" .. pr.id .. ": it isn't in your PR list and its link couldn't be read.",
      vim.log.levels.WARN)
    return
  end
  require("azure-cli.workitems.detail").fetch(item_id, function(data)
    vim.schedule(function()
      for _, p in ipairs((data and data.item and data.item.pullRequests) or {}) do
        if tostring(p.id) == tostring(pr.id) then
          p.fetched = true
          return M.open(p, item_id)
        end
      end
      M.open({ id = pr.id, fetched = true }, item_id)
    end)
  end)
end

-- gR: open one of `prs` (linked to work item `item_id`) - straight away
-- when there's one, from a picker when there are more.
function M.choose(prs, item_id)
  local notify = require("azure-cli.shell").notify
  prs = prs or {}
  if #prs == 0 then
    notify("No pull requests linked to #" .. tostring(item_id) .. ".")
    return
  end
  if #prs == 1 then return M.open(prs[1], item_id) end
  local items = {}
  for _, p in ipairs(prs) do
    local rec = listed(p.id)
    local title = p.title or (rec and rec.title) or ""
    local status = M.status(p)
    items[#items + 1] = {
      label = "!" .. p.id .. (status ~= "" and ("  [" .. status .. "]") or "") .. "  " .. title,
      pr = p,
    }
  end
  require("azure-cli.prompt").select({ prompt = "Open a PR linked to #" .. tostring(item_id), items = items },
    function(choice)
      if choice then M.open(choice.pr, item_id) end
    end)
end

return M
