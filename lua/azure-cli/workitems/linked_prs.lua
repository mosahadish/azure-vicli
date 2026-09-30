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

-- Byte range (1-based, inclusive) of the marker `mark` in `line`: its last
-- occurrence, since the marker column comes after the title and a title can
-- contain the same "!123" text itself. nil when absent.
function M.marker_range(line, mark)
  if not mark or mark == "" then return nil end
  local s, e, from = nil, nil, 1
  while true do
    local a, b = line:find(mark, from, true)
    if not a then return s, e end
    s, e, from = a, b, a + 1
  end
end

-- Highlight group for a row's marker, from its first PR's record in the
-- PR dashboard's list (`rec`, nil when that list doesn't have it): draft,
-- active, or AzureCliWiPr (dim) for a PR the list doesn't know - completed,
-- abandoned, or one you're not on.
function M.marker_group(rec)
  if not rec then return "AzureCliWiPr" end
  return rec.isDraft and "AzureCliWiPrDraft" or "AzureCliWiPrActive"
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
function M.listed(id)
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
  if M.listed(pr.id) then
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
    local rec = M.listed(p.id)
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

-- ---------------------------------------------------------------------------
-- Linking and unlinking (gl/gL here, and gl/gL on the PR side)
-- ---------------------------------------------------------------------------

local function same(a, b) return tostring(a) == tostring(b) end

-- Everything that shows a link between work item `item_id` and PR `pr_id`
-- picks up that it was just made (`linked`) or removed: the work-items
-- dashboard's cached records (list and tree - their "!101" marker), the PR
-- dashboard's cached work items for that PR (its "#3001" badge and gW), and
-- an open detail tab for the item; both dashboards redraw. `item` is the
-- work item's record when the caller has it, for the PR side's entry.
function M.link_changed(item_id, pr_id, linked, item)
  local STATE = require("azure-cli.state")
  local function patch(rec)
    if not rec or not same(rec.id, item_id) then return end
    local list = {}
    for _, p in ipairs(rec.pullRequests or {}) do
      if not same(p.id, pr_id) then list[#list + 1] = p end
    end
    if linked then list[#list + 1] = { id = tonumber(pr_id) or pr_id } end
    rec.pullRequests = list
  end
  for _, c in pairs(STATE.WI_SPRINT_ITEMS or {}) do
    for _, r in ipairs(c.items or {}) do patch(r) end
  end
  for _, by_id in pairs(STATE.WI_TREE_KIDS or {}) do
    for _, r in pairs(by_id) do patch(r) end
  end
  local c = STATE.PR_WORKITEMS and STATE.PR_WORKITEMS[tostring(pr_id)]
  if c then
    local list = {}
    for _, w in ipairs(c.list or {}) do
      if not same(w.id, item_id) then list[#list + 1] = w end
    end
    if linked then
      item = item or {}
      list[#list + 1] = { id = tonumber(item_id) or item_id, type = item.type, state = item.state,
        title = item.title, assignedTo = item.assignedTo }
    end
    c.list = list
  end
  STATE.WI_DETAIL_CACHE[tostring(item_id)] = nil
  if STATE.WI_ITEM_CHANGED then STATE.WI_ITEM_CHANGED(item_id, {}) end
  local reload = STATE.WI_VIEW_RELOAD and STATE.WI_VIEW_RELOAD[tostring(item_id)]
  if reload then vim.schedule(reload) end
  if STATE.PR_DASHBOARD_RENDER then vim.schedule(STATE.PR_DASHBOARD_RENDER) end
end

-- Link PR `pr_id` to work item `item_id` (`item`: its record, optional).
-- `where` = { org, project, repo } when the caller knows the PR's home (the
-- PR side does); otherwise it comes from the PR dashboard's list, or the
-- repository is asked for and the work-item account's collection/project
-- (AZVICLI_WI_COLLECTION/AZVICLI_WI_PROJECT) fill the rest.
function M.link(item_id, pr_id, item, where)
  local SHELL = require("azure-cli.shell")
  local notify = SHELL.notify
  item_id, pr_id = tostring(item_id), tostring(pr_id)
  if not pr_id:match("^%d+$") then
    notify("PR id must be numeric.", vim.log.levels.WARN)
    return
  end
  local org, project, repo
  if where then
    org, project, repo = where.org, where.project, where.repo
  else
    local rec = M.listed(pr_id)
    if rec then org, project, repo = rec.org, rec.project, rec.repo end
  end
  local function go()
    notify("Linking PR !" .. pr_id .. " to #" .. item_id .. " \u{2026}")
    local err = {}
    require("azure-cli.rpc").run(require("azure-cli.config").provider_argv(
      "--wi-edit", "link-pr", item_id, org or "", project or "", repo or "", pr_id), {
      detach = true,  -- finish the ADO write even if the user quits before it returns
      stdout_buffered = true,
      stderr_buffered = true,
      on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
      on_exit = function(_, code)
        if code == 0 then
          notify("Linked PR !" .. pr_id .. " to #" .. item_id .. ".")
          M.link_changed(item_id, pr_id, true, item)
        else
          notify("Link PR !" .. pr_id .. " failed: " .. SHELL.job_error("work item #" .. item_id, code, err),
            vim.log.levels.ERROR)
        end
      end,
    })
  end
  if repo and repo ~= "" then return go() end
  require("azure-cli.prompt").input({ prompt = "Repository name:" }, function(name)
    if name == nil then return end
    repo = name
    org = (org and org ~= "") and org or (vim.env.AZVICLI_WI_COLLECTION or "")
    project = (project and project ~= "") and project or (vim.env.AZVICLI_WI_PROJECT or "")
    go()
  end)
end

-- Unlink PR `pr_id` from work item `item_id`.
function M.unlink(item_id, pr_id, item)
  local SHELL = require("azure-cli.shell")
  local notify = SHELL.notify
  item_id, pr_id = tostring(item_id), tostring(pr_id)
  notify("Unlinking PR !" .. pr_id .. " from #" .. item_id .. " \u{2026}")
  local err = {}
  require("azure-cli.rpc").run(require("azure-cli.config").provider_argv("--wi-edit", "unlink-pr", item_id, pr_id), {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("Unlinked PR !" .. pr_id .. " from #" .. item_id .. ".")
        M.link_changed(item_id, pr_id, false, item)
      else
        notify("Unlink PR !" .. pr_id .. " failed: " .. SHELL.job_error("work item #" .. item_id, code, err),
          vim.log.levels.ERROR)
      end
    end,
  })
end

return M
