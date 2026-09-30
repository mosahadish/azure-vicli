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

return M
