-- lua/azure-cli/pr_workitems.lua: the work items linked to a pull request -
-- the "#3001" badge on a PR dashboard row and gW (PR dashboard and
-- reviewer), which opens one in the work-item detail view. The way back
-- from a PR to its items, next to the work-items side's gR
-- (workitems/linked_prs.lua).
--
-- One --work-items provider call per PR, cached in STATE.PR_WORKITEMS by
-- PR id for a few minutes (linking an item doesn't touch the PR's own
-- updated time, so that alone can't tell a stale entry).
--
-- The pure half (M.label, M.describe) runs under plain luajit for
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

-- The cached list for `pr_id` when fresh, else nil.
function M.cached(pr_id)
  local c = require("azure-cli.state").PR_WORKITEMS[tostring(pr_id)]
  if c and (os.time() - c.ts) < M.TTL then return c.list end
  return nil
end

-- cb(list) with PR `pr_id`'s linked work items ({id, type, state, title,
-- assignedTo}), or cb(nil, err). `env` is the PR's AZVICLI_* env (the
-- dashboard's pr_env), or nil where the process env already names the PR
-- (the reviewer). `force` skips the cache.
function M.fetch(pr_id, env, cb, force)
  if not force then
    local list = M.cached(pr_id)
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
      require("azure-cli.state").PR_WORKITEMS[tostring(pr_id)] = { list = list, ts = os.time() }
      cb(list)
    end,
  })
end

-- Open work item `id` in the detail view, in a new tab.
function M.open_item(id)
  vim.env.AZVICLI_WI_ID = tostring(id)
  vim.cmd("tabnew")
  require("azure-cli.workitems.view").open()
end

-- gW: fetch PR `pr_id`'s linked items and open one - straight away when
-- there's one, from a picker when there are more.
function M.choose(pr_id, env)
  local notify = require("azure-cli.shell").notify
  M.fetch(pr_id, env, function(list, err)
    vim.schedule(function()
      if not list then
        notify("Couldn't read PR #" .. tostring(pr_id) .. "'s work items: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      if #list == 0 then
        notify("No work items linked to PR #" .. tostring(pr_id) .. ".")
        return
      end
      if #list == 1 then return M.open_item(list[1].id) end
      local items = {}
      for _, w in ipairs(list) do items[#items + 1] = { label = M.describe(w), id = w.id } end
      require("azure-cli.prompt").select({ prompt = "Open a work item linked to PR #" .. tostring(pr_id), items = items },
        function(choice)
          if choice then M.open_item(choice.id) end
        end)
    end)
  end)
end

return M
