-- lua/azure-cli/workitems/detail.lua: an item's --wi-detail JSON (item,
-- parent, children, linked PRs, comments) through the detail cache the
-- dashboard's prefetch and the detail view share, for the helpers that
-- need it without opening the view (gs's children, gR's PR links).
local M = {}

M.TTL = 30  -- same freshness the dashboard's prefetch uses

-- cb(data), or cb(nil) when the fetch or the JSON fails. Served from the
-- cache when fresh; a fetch refreshes the cache for the detail view too.
function M.fetch(id, cb)
  id = tostring(id)
  local STATE = require("azure-cli.state")
  local function decode(body)
    local ok, data = pcall(vim.json.decode, body)
    return ok and type(data) == "table" and data or nil
  end
  local c = STATE.WI_DETAIL_CACHE[id]
  if c and (os.time() - c.ts) < M.TTL then
    local data = decode(c.body)
    if data then return cb(data) end
  end
  local out = {}
  require("azure-cli.rpc").run(require("azure-cli.config").provider_argv("--wi-detail", id), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then return cb(nil) end
      local body = table.concat(out, "\n")
      STATE.WI_DETAIL_CACHE[id] = { body = body, ts = os.time() }
      cb(decode(body))
    end,
  })
end

-- NDJSON list records (skipping blank and _meta lines).
local function records(out)
  local list = {}
  for _, line in ipairs(out) do
    if line:gsub("%s", "") ~= "" then
      local ok, rec = pcall(vim.json.decode, line)
      if ok and type(rec) == "table" and not rec._meta then list[#list + 1] = rec end
    end
  end
  return list
end

local function list_call(selector, ids, cb)
  local out, err = {}, {}
  require("azure-cli.rpc").run(require("azure-cli.config").provider_argv("--wi-list", selector, table.concat(ids, ",")), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then return cb(nil, require("azure-cli.shell").job_error("work item tree", code, err)) end
      cb(records(out))
    end,
  })
end

-- cb(records) with everything under the items `ids` - children, their
-- children and so on - as list records carrying parentId (--wi-list tree,
-- one recursive query). If the server rejects that query (an older TFS),
-- falls back to `direct_ids`, the roots' own children, read by id; cb(nil,
-- err) when both fail. The roots themselves aren't included.
function M.descendants(ids, direct_ids, cb)
  ids = vim.tbl_map(tostring, ids)
  if #ids == 0 then return cb({}) end
  list_call("tree", ids, function(list, err)
    if list then return cb(list) end
    direct_ids = vim.tbl_map(tostring, direct_ids or {})
    if #direct_ids == 0 then return cb(nil, err) end
    list_call("ids", direct_ids, cb)
  end)
end

return M
