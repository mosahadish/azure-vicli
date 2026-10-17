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
--
-- `host` ("github", from workitems/board.lua) names a GitHub issue's PRs
-- the GitHub way, repo#12, and finds them among the PR list's GitHub
-- records; absent means Azure, as before.
local M = {}

-- How a linked PR is named: "!101" on Azure, "repo#12" on GitHub.
function M.label(pr, host)
  return require("azure-cli.hosts").ref({ host = host, id = pr.id, repo = pr.repo })
end

-- The dashboard row's marker: "" / "!101" / "!101 +2".
function M.marker(prs, host)
  if not prs or #prs == 0 then return "" end
  local s = M.label(prs[1], host)
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
function M.lines(pr, host)
  local head = string.format("  %-7s %-10s %s", M.label(pr, host), M.status(pr), pr.title or "")
  head = head:gsub("%s+$", "")
  if not pr.repo or pr.repo == "" then return { head } end
  local where = "           " .. pr.repo .. "  " .. (pr.source or "") .. " \u{2192} " .. (pr.target or "")
  if pr.author and pr.author ~= "" then where = where .. "  \u{00B7}  " .. pr.author end
  return { head, where }
end

-- The PR dashboard's record for `id`, when its list has one. On GitHub
-- (`pr` the linked PR, with its repo) only a GitHub record of that repo.
function M.listed(id, pr, host)
  local cache = require("azure-cli.state").PR_LIST_CACHE
  for _, p in ipairs((cache and cache.prs) or {}) do
    if tostring(p.id) == tostring(id) then
      if host ~= "github" then
        if p.host ~= "github" then return p end
      elseif p.host == "github" and (not pr or not pr.repo or p.repo == pr.repo) then
        return p
      end
    end
  end
  return nil
end

-- Open `pr` ({id, url?}) linked to work item `item_id`: in the reviewer
-- when the PR list has it, else in the browser - fetching the item's
-- detail first when `pr` has no url yet (the dashboard's ids-only records).
-- `B` is the item's board (workitems/board.lua); absent means Azure.
function M.open(pr, item_id, B)
  local notify = require("azure-cli.shell").notify
  local host = B and B.host
  local rec = M.listed(pr.id, pr, host)
  if rec then
    require("azure-cli").open_review(rec.key or pr.id)
    return
  end
  local name = M.label(pr, host)
  if pr.url and pr.url ~= "" then
    notify(name .. " isn't in your PR list; opening it in the browser.")
    require("azure-cli.shell").open_url(pr.url)
    return
  end
  if pr.fetched or not item_id then
    notify("Can't open " .. name .. ": it isn't in your PR list and its link couldn't be read.",
      vim.log.levels.WARN)
    return
  end
  require("azure-cli.workitems.detail").for_board(B).fetch(item_id, function(data)
    vim.schedule(function()
      for _, p in ipairs((data and data.item and data.item.pullRequests) or {}) do
        if tostring(p.id) == tostring(pr.id) and (not pr.repo or not p.repo or p.repo == pr.repo) then
          p.fetched = true
          return M.open(p, item_id, B)
        end
      end
      M.open({ id = pr.id, repo = pr.repo, fetched = true }, item_id, B)
    end)
  end)
end

-- gR: open one of `prs` (linked to work item `item_id`) - straight away
-- when there's one, from a picker when there are more.
-- `item_id`: what the item's board's provider calls take (B.ref); `shown`:
-- how to name the item ("7"), when that differs.
function M.choose(prs, item_id, B, shown)
  local notify = require("azure-cli.shell").notify
  local host = B and B.host
  shown = shown or tostring(item_id)
  prs = prs or {}
  if #prs == 0 then
    notify("No pull requests linked to #" .. shown .. ".")
    return
  end
  if #prs == 1 then return M.open(prs[1], item_id, B) end
  local items = {}
  for _, p in ipairs(prs) do
    local rec = M.listed(p.id, p, host)
    local title = p.title or (rec and rec.title) or ""
    local status = M.status(p)
    items[#items + 1] = {
      label = M.label(p, host) .. (status ~= "" and ("  [" .. status .. "]") or "") .. "  " .. title,
      pr = p,
    }
  end
  require("azure-cli.prompt").select({ prompt = "Open a PR linked to #" .. shown, items = items },
    function(choice)
      if choice then M.open(choice.pr, item_id, B) end
    end)
end

-- ---------------------------------------------------------------------------
-- Linking and unlinking (gl/gL here, and gl/gL on the PR side)
-- ---------------------------------------------------------------------------

local function same(a, b) return tostring(a) == tostring(b) end

-- Whether record `rec` is item `item_id`: its id, or on GitHub its
-- owner~repo~n key (`item_id` may be either).
local function is_item(rec, item_id)
  if not rec then return false end
  item_id = tostring(item_id)
  if item_id:find("~", 1, true) then return rec.key == item_id end
  return same(rec.id, item_id)
end

-- Whether cache key `k` (a board's ref: the id, or owner~repo~n) is item
-- `item_id`.
local function is_ref(k, item_id)
  k, item_id = tostring(k), tostring(item_id)
  if k == item_id then return true end
  if item_id:find("~", 1, true) then return k == item_id:match("(%d+)$") end
  return k:match("~(%d+)$") == item_id
end

-- Everything that shows a link between work item `item_id` and PR `pr_id`
-- picks up that it was just made (`linked`) or removed: the work-items
-- dashboard's cached records (list and tree - their "!101" marker), the PR
-- dashboard's cached work items for that PR (its "#3001" badge and gW), and
-- an open detail tab for the item; both dashboards redraw. `item` is the
-- work item's record when the caller has it, for the PR side's entry. `B`
-- is the item's board (absent: Azure's); on GitHub `pr_repo` names the
-- PR's repository for the row's "repo#12" marker.
function M.link_changed(item_id, pr_id, linked, item, B, pr_repo)
  local STATE = require("azure-cli.state")
  local S = (B and B.state) or STATE
  local function patch(rec)
    if not is_item(rec, item_id) then return end
    local list = {}
    for _, p in ipairs(rec.pullRequests or {}) do
      if not same(p.id, pr_id) then list[#list + 1] = p end
    end
    if linked then list[#list + 1] = { id = tonumber(pr_id) or pr_id, repo = pr_repo } end
    rec.pullRequests = list
  end
  for _, c in pairs(S.WI_SPRINT_ITEMS or {}) do
    for _, r in ipairs(c.items or {}) do patch(r) end
  end
  for _, by_id in pairs(S.WI_TREE_KIDS or {}) do
    for _, r in pairs(by_id) do patch(r) end
  end
  -- A GitHub PR's issues are cached under its owner~repo~n key: drop that
  -- (and its read is redone) rather than guess which repository's #n.
  if B and B.host == "github" then
    for k in pairs(STATE.PR_WORKITEMS or {}) do
      if k:match("~(%d+)$") == tostring(pr_id) and (not pr_repo or k:find("~" .. pr_repo .. "~", 1, true)) then
        STATE.PR_WORKITEMS[k] = nil
      end
    end
  end
  local c = not (B and B.host == "github") and STATE.PR_WORKITEMS and STATE.PR_WORKITEMS[tostring(pr_id)]
  if c then
    local list = {}
    for _, w in ipairs(c.list or {}) do
      if not is_item(w, item_id) then list[#list + 1] = w end
    end
    if linked then
      item = item or {}
      list[#list + 1] = { id = tonumber(item_id) or item_id, type = item.type, state = item.state,
        title = item.title, assignedTo = item.assignedTo }
    end
    c.list = list
  end
  -- The detail cache and an open view are keyed by the board's ref: the id,
  -- or on GitHub the key - drop/reload every one that is this item.
  for k in pairs(S.WI_DETAIL_CACHE or {}) do
    if is_ref(k, item_id) then S.WI_DETAIL_CACHE[k] = nil end
  end
  if S.WI_ITEM_CHANGED then S.WI_ITEM_CHANGED(item_id, {}) end
  for k, reload in pairs(S.WI_VIEW_RELOAD or {}) do
    if is_ref(k, item_id) then vim.schedule(reload) end
  end
  if STATE.PR_DASHBOARD_RENDER then vim.schedule(STATE.PR_DASHBOARD_RENDER) end
end

-- The provider call for board B (absent: Azure's): RPC.run with B's env.
local function run(B, args, opts)
  if B then return B.run(args, opts) end
  return require("azure-cli.rpc").run(vim.list_extend(require("azure-cli.config").provider_argv(), args), opts)
end

-- Link PR `pr_id` to work item `item_id` (`item`: its record, optional).
-- `where` = { org, project, repo } when the caller knows the PR's home (the
-- PR side does); otherwise it comes from the PR dashboard's list, or the
-- repository is asked for and the work-item account's collection/project
-- (AZVICLI_WI_COLLECTION/AZVICLI_WI_PROJECT) fill the rest. On GitHub's
-- board `B` it adds "Closes #n" to the PR's description (github_issues.py).
function M.link(item_id, pr_id, item, where, B)
  local SHELL = require("azure-cli.shell")
  local notify = SHELL.notify
  local host = B and B.host
  item_id, pr_id = tostring(item_id), tostring(pr_id)
  if not pr_id:match("^%d+$") then
    notify("PR id must be numeric.", vim.log.levels.WARN)
    return
  end
  local org, project, repo
  if where then
    org, project, repo = where.org, where.project, where.repo
  else
    local rec = M.listed(pr_id, nil, host)
    if rec then org, project, repo = rec.org, rec.project, rec.repo end
  end
  local shown = "#" .. (item_id:match("~(%d+)$") or item_id)
  local function go()
    local pr_name = M.label({ id = pr_id, repo = repo }, host)
    notify("Linking PR " .. pr_name .. " to " .. shown .. " \u{2026}")
    local out, err = {}, {}
    run(B, { "--wi-edit", "link-pr", item_id, org or "", project or "", repo or "", pr_id }, {
      detach = true,  -- finish the ADO write even if the user quits before it returns
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
      on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
      on_exit = function(_, code)
        if code == 0 then
          local ok, res = pcall(vim.json.decode, table.concat(out, ""))
          local note = ok and type(res) == "table" and res.note or nil
          notify("Linked PR " .. pr_name .. " to " .. shown .. "." .. (note and (" " .. note .. ".") or ""),
            note and vim.log.levels.WARN or nil)
          M.link_changed(item_id, pr_id, true, item, B, repo)
        else
          notify("Link PR " .. pr_name .. " failed: " .. SHELL.job_error("work item " .. shown, code, err),
            vim.log.levels.ERROR)
        end
      end,
    })
  end
  if repo and repo ~= "" then return go() end
  require("azure-cli.prompt").input({ prompt = "Repository name:" }, function(name)
    if name == nil then return end
    repo = name
    if host == "github" then
      local acct = require("azure-cli.workitems.board").issues_account()
      org = (org and org ~= "") and org or (acct.apiUrl or "")
      project = (project and project ~= "") and project or (acct.owner or "")
    else
      org = (org and org ~= "") and org or (vim.env.AZVICLI_WI_COLLECTION or "")
      project = (project and project ~= "") and project or (vim.env.AZVICLI_WI_PROJECT or "")
    end
    go()
  end)
end

-- Unlink PR `pr_id` from work item `item_id`. On GitHub's board `B`,
-- `pr_repo` (owner/repo) is where the PR lives when that isn't the
-- issue's own repository.
function M.unlink(item_id, pr_id, item, B, pr_repo)
  local SHELL = require("azure-cli.shell")
  local notify = SHELL.notify
  item_id, pr_id = tostring(item_id), tostring(pr_id)
  local shown = "#" .. (item_id:match("~(%d+)$") or item_id)
  local pr_name = M.label({ id = pr_id, repo = pr_repo }, B and B.host)
  notify("Unlinking PR " .. pr_name .. " from " .. shown .. " \u{2026}")
  local err = {}
  local args = { "--wi-edit", "unlink-pr", item_id, pr_id }
  if B and B.host == "github" and pr_repo and pr_repo ~= "" then args[#args + 1] = pr_repo end
  run(B, args, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify("Unlinked PR " .. pr_name .. " from " .. shown .. ".")
        M.link_changed(item_id, pr_id, false, item, B)
      else
        notify("Unlink PR " .. pr_name .. " failed: " .. SHELL.job_error("work item " .. shown, code, err),
          vim.log.levels.ERROR)
      end
    end,
  })
end

return M
