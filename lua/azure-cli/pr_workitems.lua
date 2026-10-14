-- lua/azure-cli/pr_workitems.lua: the work items linked to a pull request -
-- the "#3001" badge on a PR dashboard row, gW (PR dashboard and
-- reviewer), a popup of them from which <CR> opens one in the work-item
-- detail view and gs changes its state, and gl/gL, which link and unlink
-- one from the PR side. The way back
-- from a PR to its items, next to the work-items side's gR
-- (workitems/linked_prs.lua).
--
-- One --work-items provider call per PR, cached in STATE.PR_WORKITEMS by
-- PR id for a few minutes (linking an item doesn't touch the PR's own
-- updated time, so that alone can't tell a stale entry).
--
-- The pure half (M.label, M.describe, M.popup_line) runs under plain luajit for
-- tests/test-pr-workitems.lua.
local M = {}

M.TTL = 300

-- A PR row's badge: "" / "#3001" / "#3001 +1".
function M.label(list)
  if not list or #list == 0 then return "" end
  local s = "#" .. tostring(list[1].id)
  if #list > 1 then s = s .. " +" .. (#list - 1) end
  return s
end

-- One picker line: "#3001  [Active]  User Story  Throttle repeated…".
function M.describe(w)
  local parts = { "#" .. tostring(w.id) }
  if w.state and w.state ~= "" then parts[#parts + 1] = "[" .. w.state .. "]" end
  if w.type and w.type ~= "" then parts[#parts + 1] = w.type end
  if w.title and w.title ~= "" then parts[#parts + 1] = w.title end
  return table.concat(parts, "  ")
end

-- What STATE.PR_WORKITEMS keys a PR's list by: its id on Azure, its
-- owner~repo~n key on GitHub (two repositories' #7 are two PRs). `pr` is a
-- PR record, or an id (Azure's).
function M.key(pr)
  if type(pr) ~= "table" then return tostring(pr) end
  return (pr.host == "github" and pr.key) or tostring(pr.id)
end

-- The cached list for `pr` (a record, or an Azure PR's id) when fresh,
-- else nil.
function M.cached(pr)
  local c = require("azure-cli.state").PR_WORKITEMS[M.key(pr)]
  if c and (os.time() - c.ts) < M.TTL then return c.list end
  return nil
end

-- cb(list) with PR `pr`'s (a record, or an Azure PR's id) linked work items
-- ({id, type, state, title, assignedTo}; a GitHub PR's issues add key,
-- repo and host), or cb(nil, err). `env` is the PR's AZVICLI_* env (the
-- dashboard's pr_env), or nil where the process env already names the PR
-- (the reviewer). `force` skips the cache.
function M.fetch(pr, env, cb, force)
  local pr_id = type(pr) == "table" and pr.id or pr
  if not force then
    local list = M.cached(pr)
    if list then return cb(list) end
  end
  local out, err = {}, {}
  require("azure-cli.rpc").run(require("azure-cli.config").provider_argv("--work-items"), {
    env = env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then
        return cb(nil, require("azure-cli.shell").job_error("PR #" .. tostring(pr_id) .. " work items", code, err))
      end
      local list = {}
      for _, line in ipairs(out) do
        if line:gsub("%s", "") ~= "" then
          local ok, rec = pcall(vim.json.decode, line)
          if ok and type(rec) == "table" and rec.id then list[#list + 1] = rec end
        end
      end
      require("azure-cli.state").PR_WORKITEMS[M.key(pr)] = { list = list, ts = os.time() }
      cb(list)
    end,
  })
end

-- Open work item `id` in the detail view: an inner tab of Work items, or
-- on GitHub's board `B` the issue view in Issues (innertabs.lua), on `ref`
-- (its owner~repo~n key) when given. Already open: goes to it. The view
-- puts the item's title in the strip once it's loaded.
function M.open_item(id, B, ref)
  local INNER = require("azure-cli.innertabs")
  local github = B and B.host == "github"
  local r = github and (ref or tostring(id)) or tostring(id)
  local host = github and "github" or "azure"
  INNER.open(INNER.item_home(host), INNER.item_key(host, r), "#" .. tostring(id), function()
    if github then
      require("azure-cli.workitems.view").open(B, r)
      return
    end
    vim.env.AZVICLI_WI_ID = r
    require("azure-cli.workitems.view").open()
  end)
end

-- The board a PR's linked items are on: a GitHub PR's are issues.
local function board_of(pr)
  return require("azure-cli.workitems.board").get(pr and pr.host == "github" and "github" or "azure")
end

-- Where a GitHub PR lives (owner/repo), for unlinking one of its issues.
local function pr_repo(pr)
  if not (pr and pr.host == "github") then return nil end
  return (pr.project or "") .. "/" .. (pr.repo or "")
end

-- The popup's line for one item: "#3001  [Active]  User Story  Throttle…  · Jordan Doe".
function M.popup_line(w)
  local s = "  " .. M.describe(w)
  if w.assignedTo and w.assignedTo ~= "" then s = s .. "  \u{00B7} " .. w.assignedTo end
  return s
end

-- Keep cached lists in step with a state change made anywhere (gs, here or
-- on the work-items side).
function M.patch_state(id, new)
  for _, c in pairs(require("azure-cli.state").PR_WORKITEMS) do
    for _, w in ipairs(c.list or {}) do
      if tostring(w.id) == tostring(id) then w.state = new end
    end
  end
end

-- Work items to offer when linking one to PR `pr_id`: every sprint the
-- work-items dashboard has cached, minus the ones already linked; cb(list).
-- When nothing is cached yet (that dashboard was never opened this
-- session), the current sprint's items are read first. On board B (a
-- GitHub PR's: the Issues board's).
local function candidates(pr, B, cb)
  local linked, seen, out = {}, {}, {}
  for _, w in ipairs(M.cached(pr) or {}) do linked[w.key or tostring(w.id)] = true end
  local function add(r)
    local id = B.ref(r)
    if not seen[id] and not linked[id] then
      seen[id] = true
      out[#out + 1] = r
    end
  end
  for _, c in pairs(B.state.WI_SPRINT_ITEMS or {}) do
    for _, r in ipairs(c.items or {}) do add(r) end
  end
  if #out > 0 then return cb(out) end
  local lines = {}
  B.run({ "--wi-list", "current" }, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(lines, d) end end,
    on_exit = function()
      for _, line in ipairs(lines) do
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" and rec.id and not rec._meta then add(rec) end
      end
      cb(out)
    end,
  })
end

-- gl (PR side): link a work item to `pr` ({id, org, project, repo}) - one of
-- my sprint's items from a popup, or any id typed in. `center` puts the
-- popup mid-screen (the reviewer) instead of at the cursor.
function M.link_item(pr, center)
  local notify = require("azure-cli.shell").notify
  local PROMPT = require("azure-cli.prompt")
  local B = board_of(pr)
  local item = B.words.item
  candidates(pr, B, function(list)
    vim.schedule(function()
      local items = {}
      for _, w in ipairs(list) do items[#items + 1] = { label = M.describe(w), w = w } end
      items[#items + 1] = { label = "(other\u{2026} type " .. (B.host == "github" and "an " or "a ") .. item .. " id)",
        other = true }
      require("azure-cli.ui").pick_popup({ title = "Link " .. (B.host == "github" and "an " or "a ") .. item
        .. " to PR #" .. tostring(pr.id), items = items, action = "link", center = center }, function(choice)
        local function go(w)
          require("azure-cli.workitems.linked_prs").link(B.ref(w), pr.id, w,
            { org = pr.org, project = pr.project, repo = pr.repo }, B.host == "github" and B or nil)
        end
        if not choice.other then return go(choice.w) end
        PROMPT.input({ prompt = B.words.Item .. " id:" }, function(t)
          if t == nil then return end
          t = t:gsub("^#", "")
          if not t:match("^%d+$") then
            notify(B.words.Item .. " id must be numeric.", vim.log.levels.WARN)
            return
          end
          go({ id = tonumber(t) })
        end)
      end)
    end)
  end)
end

-- gL (PR side): unlink one of `pr`'s linked work items, from a popup.
function M.unlink_item(pr, env, center)
  local notify = require("azure-cli.shell").notify
  M.fetch(pr, env, function(list)
    vim.schedule(function()
      if not list or #list == 0 then
        notify("No work items linked to PR #" .. tostring(pr.id) .. ".")
        return
      end
      local items = {}
      for _, w in ipairs(list) do items[#items + 1] = { label = M.describe(w), w = w } end
      local B = board_of(pr)
      require("azure-cli.ui").pick_popup({ title = "Unlink " .. (B.host == "github" and "an " or "a ") .. B.words.item
        .. " from PR #" .. tostring(pr.id), items = items, action = "unlink", center = center }, function(choice)
        require("azure-cli.workitems.linked_prs").unlink(B.ref(choice.w), pr.id, choice.w,
          B.host == "github" and B or nil, pr_repo(pr))
      end)
    end)
  end)
end

-- gW: a popup of `pr`'s ({id, org, project, repo}) linked work items -
-- state, type, title and assignee each - where <CR> opens one in the
-- detail view, gs changes its state, gl links another and gL unlinks the
-- one under the cursor. At the cursor by default; `center` puts it
-- mid-screen (the reviewer, whose cursor can be anywhere in a split).
function M.choose(pr, env, center)
  local notify = require("azure-cli.shell").notify
  local pr_id = pr.id
  if not M.cached(pr) then notify("Reading PR #" .. tostring(pr_id) .. "'s work items \u{2026}") end
  M.fetch(pr, env, function(list, err)
    vim.schedule(function()
      if not list then
        notify("Couldn't read PR #" .. tostring(pr_id) .. "'s work items: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      if #list == 0 then
        notify("No work items linked to PR #" .. tostring(pr_id) .. " - gl links one.")
        return
      end
      local lines, row = {}, {}
      for _, w in ipairs(list) do
        lines[#lines + 1] = M.popup_line(w)
        row[#lines] = w
      end
      local UI = require("azure-cli.ui")
      local win, buf = UI.open_float(lines, {
        title = "Work items linked to PR #" .. tostring(pr_id),
        footer = "<CR> open \u{00B7} gs state \u{00B7} gl link \u{00B7} gL unlink",
        min_width = 50,
        center = center,
      })
      if not win then return end
      UI.wo(win, "cursorline", true)
      UI.wo(win, "wrap", false)
      local ns = vim.api.nvim_create_namespace("azure_cli_pr_workitems")
      for i, l in ipairs(lines) do
        local s, e = l:find("#%d+")
        if s then vim.api.nvim_buf_add_highlight(buf, ns, "Identifier", i - 1, s - 1, e) end
        local bs, be = l:find("%[.-%]")
        if bs then vim.api.nvim_buf_add_highlight(buf, ns, "Special", i - 1, bs - 1, be) end
      end
      local function current()
        return row[vim.api.nvim_win_get_cursor(win)[1]]
      end
      local function close()
        if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      end
      local kopts = { buffer = buf, silent = true, nowait = true }
      -- A GitHub PR's items are issues: they open, and change state, on the
      -- Issues board.
      local B = board_of(pr)
      local github = B.host == "github" and B or nil
      vim.keymap.set("n", "<CR>", function()
        local w = current()
        if not w then return end
        close()
        M.open_item(w.id, github, w.key)
      end, kopts)
      vim.keymap.set("n", "gs", function()
        local w = current()
        if not w then return end
        close()
        local SD = require("azure-cli.workitems.state_dialog")
        if github then SD = SD.for_board(github) end
        SD.open(w)
      end, kopts)
      vim.keymap.set("n", "gl", function()
        close()
        M.link_item(pr, center)
      end, kopts)
      vim.keymap.set("n", "gL", function()
        local w = current()
        if not w then return end
        close()
        require("azure-cli.workitems.linked_prs").unlink(B.ref(w), pr_id, w, github, pr_repo(pr))
      end, kopts)
    end)
  end)
end

return M
