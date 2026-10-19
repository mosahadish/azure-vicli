-- lua/azure-cli/perf.lua: :AzureCli perf - a summary of the provider's perf
-- log (#91). With AZVICLI_DEBUG on, azure-cli.py appends one JSON line per
-- HTTP request ("kind": "req") and one per command ("kind": "total") to
-- <AZVICLI_PREFETCH_DIR>/perf.log (see its "Perf log" section); this reads
-- that file (and the perf.log.1 it rotates to) and shows:
--   - per screen (PR dashboard, PR review, work-items / issues board), each
--     command's requests and wall time per call - a poll tick for --list,
--     --threads and --wi-list - as avg / max / last;
--   - the slowest requests;
--   - requests by method + host + path, ids folded to {n}, most frequent
--     first - where repeats (connectionData on every tick) show.
--
-- M.screen_of, M.fold_path, M.summarise and M.lines are pure (no vim
-- calls), so tests/test-perf.lua runs them under plain luajit; M.read and
-- M.open below them need Neovim.

local M = {}

local REVIEW_FLAGS = {
  ["--threads"] = true, ["--iterations"] = true, ["--get-pr"] = true, ["--work-items"] = true,
  ["--build-log"] = true, ["--test-results"] = true,
}

local SCREEN_ORDER = { "PR dashboard", "PR review", "Work-items board", "Issues board", "Other" }

-- Which screen a command's calls belong to: --list is the PR dashboard's
-- poll, --threads (and the reviewer's other reads) a PR review's, --wi-list
-- the board's - the Issues board when the call carried AZVICLI_WI_HOST=github.
function M.screen_of(cmd, board)
  if cmd == "--list" then return "PR dashboard" end
  if REVIEW_FLAGS[cmd] then return "PR review" end
  if cmd == "--wi-list" then return board == "github" and "Issues board" or "Work-items board" end
  return "Other"
end

-- A request path with its ids folded, so every PR's /threads counts as one
-- endpoint: numeric segments become {n}, GUIDs {id}.
function M.fold_path(path)
  path = tostring(path or "")
  local q = path:find("?", 1, true)
  local base, query = path, ""
  if q then base, query = path:sub(1, q - 1), path:sub(q) end
  local segs = {}
  for seg in base:gmatch("[^/]+") do
    if seg:match("^%d+$") then
      seg = "{n}"
    elseif seg:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
      seg = "{id}"
    end
    segs[#segs + 1] = seg
  end
  return "/" .. table.concat(segs, "/") .. query
end

local function stats(values)
  local sum, max = 0, 0
  for _, v in ipairs(values) do
    sum = sum + v
    if v > max then max = v end
  end
  return { avg = #values > 0 and sum / #values or 0, max = max, last = values[#values] or 0 }
end

-- entries: decoded perf.log lines, oldest first. Returns
--   { screens = { { name, cmds = { { cmd, calls, requests = {avg,max,last}, wall_ms = {...} } } } },
--     slowest = { req entries, slowest first (at most opts.slowest, default 15) },
--     paths = { { key, count, avg_ms } } most frequent first }
-- A total with no requests (--print-pat, --boards, ...) is left out.
function M.summarise(entries, opts)
  opts = opts or {}
  local by_screen, reqs, paths, path_order = {}, {}, {}, {}
  for _, e in ipairs(entries or {}) do
    if type(e) == "table" and e.kind == "total" and (tonumber(e.requests) or 0) > 0 then
      local name = M.screen_of(e.cmd, e.board)
      local screen = by_screen[name]
      if not screen then
        screen = { cmds = {}, order = {} }
        by_screen[name] = screen
      end
      local c = screen.cmds[e.cmd]
      if not c then
        c = { requests = {}, wall = {} }
        screen.cmds[e.cmd] = c
        screen.order[#screen.order + 1] = e.cmd
      end
      c.requests[#c.requests + 1] = tonumber(e.requests) or 0
      c.wall[#c.wall + 1] = tonumber(e.wall_ms) or 0
    elseif type(e) == "table" and e.kind == "req" then
      reqs[#reqs + 1] = e
      local key = tostring(e.method or "?") .. " " .. tostring(e.host or "") .. M.fold_path(e.path)
      local p = paths[key]
      if not p then
        p = { key = key, count = 0, ms = 0 }
        paths[key] = p
        path_order[#path_order + 1] = p
      end
      p.count = p.count + 1
      p.ms = p.ms + (tonumber(e.ms) or 0)
    end
  end

  local out = { screens = {}, slowest = {}, paths = {} }
  for _, name in ipairs(SCREEN_ORDER) do
    local screen = by_screen[name]
    if screen then
      local cmds = {}
      for _, cmd in ipairs(screen.order) do
        local c = screen.cmds[cmd]
        cmds[#cmds + 1] = { cmd = cmd, calls = #c.requests, requests = stats(c.requests), wall_ms = stats(c.wall) }
      end
      out.screens[#out.screens + 1] = { name = name, cmds = cmds }
    end
  end

  -- Stable for equal ms: newer first (table.sort isn't stable on its own).
  for i, e in ipairs(reqs) do e._i = i end
  table.sort(reqs, function(a, b)
    local am, bm = tonumber(a.ms) or 0, tonumber(b.ms) or 0
    if am ~= bm then return am > bm end
    return a._i > b._i
  end)
  for i = 1, math.min(opts.slowest or 15, #reqs) do
    out.slowest[i] = reqs[i]
  end

  for i, p in ipairs(path_order) do p._i = i end
  table.sort(path_order, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a._i < b._i
  end)
  for _, p in ipairs(path_order) do
    out.paths[#out.paths + 1] = { key = p.key, count = p.count, avg_ms = p.ms / p.count }
  end
  return out
end

local function n(x)
  return string.format("%.0f", tonumber(x) or 0)
end

-- The summary as the lines :AzureCli perf shows.
function M.lines(s)
  local lines = {}
  local function add(l) lines[#lines + 1] = l end
  if #s.screens == 0 and #s.slowest == 0 then
    add("(no requests logged - start Neovim with AZVICLI_DEBUG=1 and use the dashboards for a poll tick or two)")
    return lines
  end
  add("Requests and wall ms per call (avg / max / last)")
  for _, screen in ipairs(s.screens) do
    add("")
    add(screen.name)
    for _, c in ipairs(screen.cmds) do
      add(string.format("  %-14s %4d calls   requests %s / %s / %s   wall ms %s / %s / %s", c.cmd, c.calls,
        string.format("%.1f", c.requests.avg), n(c.requests.max), n(c.requests.last),
        n(c.wall_ms.avg), n(c.wall_ms.max), n(c.wall_ms.last)))
    end
  end
  add("")
  add("Slowest requests")
  for _, e in ipairs(s.slowest) do
    add(string.format("  %6s ms  %-6s %-4s %s%s  (%s, %s B, %s)", n(e.ms), tostring(e.method or "?"),
      tostring(e.status or "?"), tostring(e.host or ""), tostring(e.path or ""), tostring(e.cmd or "?"),
      tostring(e.bytes or 0), tostring(e.conn or "?")))
  end
  add("")
  add("Requests by endpoint (count, avg ms)")
  for _, p in ipairs(s.paths) do
    add(string.format("  %5d  %6s ms  %s", p.count, n(p.avg_ms), p.key))
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Reading the log + the :AzureCli perf view - Neovim from here on.

-- Where azure-cli.py writes it: AZVICLI_PREFETCH_DIR, which config.lua's
-- provider_cmd sets to stdpath("cache") .. "/azure-cli" when unset.
function M.log_path()
  local dir = vim.env.AZVICLI_PREFETCH_DIR
  if not dir or dir == "" then dir = vim.fn.stdpath("cache") .. "/azure-cli" end
  return dir .. "/perf.log"
end

-- Every entry in perf.log.1 then perf.log, oldest first; lines that don't
-- decode (a write cut short) are skipped.
function M.read(path)
  path = path or M.log_path()
  local entries = {}
  for _, f in ipairs({ path .. ".1", path }) do
    if vim.fn.filereadable(f) == 1 then
      for _, line in ipairs(vim.fn.readfile(f)) do
        local ok, e = pcall(vim.json.decode, line)
        if ok and type(e) == "table" then entries[#entries + 1] = e end
      end
    end
  end
  return entries
end

-- :AzureCli perf - a scratch split with the summary; "q" closes it, "r"
-- reads the log again.
function M.open()
  local path = M.log_path()
  local function render(buf)
    local lines = M.lines(M.summarise(M.read(path)))
    table.insert(lines, 1, path)
    table.insert(lines, 2, "")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  vim.cmd("botright split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "azurecli-perf"
  render(buf)
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "r", function() render(buf) end, { buffer = buf, silent = true, nowait = true })
end

return M
