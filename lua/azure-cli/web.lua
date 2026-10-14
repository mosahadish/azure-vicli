-- lua/azure-cli/web.lua: the phone dashboard (#97) - a read-only web page of
-- the Agents screen, served by `azure-cli.py --web-dashboard` (its own
-- process: see the "Web dashboard" section there for the security rules)
-- and reached from a phone over the LAN or a VPN.
--
--   :AzureCli web start    starts it (only with dashboard_web.enabled) and
--                          shows its URL, token included, in a float
--   :AzureCli web status   the URL again, or that it isn't running
--   :AzureCli web stop     stops it; the next start makes a new token
--
-- While it runs, every M.EVERY ms the Agents screen's rows
-- (agents_view.rows/arrange, read only) go to the server's stdin as one
-- JSON line, only when they changed. M.snapshot picks the fields the page
-- shows, nothing more.
--
--   M.snapshot(arranged, rows, counts, fmt)  the page's JSON (pure)
--   M.url(bind, port, token)                 the URL to open (pure)
--   M.start() / M.stop() / M.status() / M.command(sub)
local M = {}

M.EVERY = 2000

local srv = nil  -- { job, url, timer, last, out, stopping }

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- `arranged` (agents_view.arrange: group headers and rows), `rows` (all of
-- them, the hidden finished ones too, for the totals) and `counts`
-- ({ working, queued, max, hidden, finished_days }) -> what the page shows:
-- { items = { {header} | {label, title, state, group, ago, cost, detail} },
--   totals, hidden, finished_days }. Only those fields: no keys, targets,
-- conversations, plan text or paths. `fmt` is chat/core.lua (money,
-- requests_label, context_label). Pure.
function M.snapshot(arranged, rows, counts, fmt)
  fmt = fmt or require("azure-cli.chat.core")
  counts = counts or {}
  local items = {}
  for _, r in ipairs(arranged or {}) do
    if r.header then
      items[#items + 1] = { header = r.header }
    else
      local ctx = fmt.context_label(r.context)
      local detail = r.detail or ""
      if ctx ~= "" then detail = ctx .. (detail ~= "" and (" \u{00B7} " .. detail) or "") end
      -- The screen's spinner frame (rows() is given none here) goes.
      local state = trim(r.state)
      items[#items + 1] = {
        label = tostring(r.label or ""), title = tostring(r.title or ""), state = state,
        group = r.group or 3, ago = tostring(r.ago or ""),
        cost = r.cost and fmt.money(r.cost) or fmt.requests_label(r.requests), detail = detail,
      }
    end
  end
  -- The totals line, as the Agents screen's winbar has it.
  local total, requests
  for _, r in ipairs(rows or {}) do
    if r.cost then total = (total or 0) + r.cost end
    if r.requests then requests = (requests or 0) + r.requests end
  end
  local parts = { (counts.working or 0) .. " working" }
  if (counts.queued or 0) > 0 then parts[#parts + 1] = counts.queued .. " queued" end
  if counts.max then parts[#parts + 1] = "max " .. counts.max end
  if total then parts[#parts + 1] = fmt.money(total) .. " so far" end
  if requests then
    parts[#parts + 1] = (fmt.requests_label(requests):gsub(" req$", " premium requests")) .. " so far"
  end
  return { items = items, totals = table.concat(parts, " \u{00B7} "), hidden = counts.hidden or 0,
    finished_days = counts.finished_days }
end

-- The URL the phone opens. Pure.
function M.url(bind, port, token)
  local host = trim(bind):gsub("^%[", ""):gsub("%]$", "")
  if host:find(":", 1, true) then host = "[" .. host .. "]" end
  return "http://" .. host .. ":" .. tostring(port) .. "/?token=" .. tostring(token)
end

local function snapshot_line()
  local AV = require("azure-cli.chat.agents_view")
  local AG = require("azure-cli.chat.agents")
  local now = os.time()
  local rows = AV.rows(require("azure-cli.chat").conversations(), AG.queued(), require("azure-cli.chat.plan").load,
    now, "")
  local arranged, hidden = AV.arrange(rows, now, false)
  return vim.json.encode(M.snapshot(arranged, rows, { working = AG.working(), queued = #AG.queued(), max = AG.max(),
    hidden = hidden, finished_days = AV.FINISHED_DAYS }))
end

local function push()
  if not (srv and srv.job and srv.url) then return end
  local ok, line = pcall(snapshot_line)
  if not ok or line == srv.last then return end
  srv.last = line
  pcall(vim.fn.chansend, srv.job, line .. "\n")
end

local LOOPBACK = { ["127.0.0.1"] = true, ["localhost"] = true, ["::1"] = true, ["[::1]"] = true }

local function show()
  if not (srv and srv.url) then return end
  local bind = require("azure-cli.config").get().dashboard_web.bind
  local lines = {
    "Phone dashboard - the Agents screen, read-only",
    "",
    "  " .. srv.url,
    "",
    "Open it on your phone (same network or a VPN such as Tailscale).",
    "Anyone with this URL can see the page until :AzureCli web stop;",
    "the next start makes a new URL.",
  }
  if LOOPBACK[trim(bind)] then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Listening on " .. trim(bind) .. " only: set dashboard_web.bind to this machine's"
    lines[#lines + 1] = "LAN or VPN address to reach it from a phone."
  end
  require("azure-cli.ui").open_float(lines, { title = "Phone dashboard", center = true })
end

function M.start()
  local cfg = require("azure-cli.config").get().dashboard_web or {}
  if not cfg.enabled then
    return notify("The phone dashboard is off: set dashboard_web = { enabled = true, bind = \"<this machine's LAN or "
      .. "VPN address>\" } in setup() (docs/chat.md).")
  end
  if srv then
    if srv.url then return show() end
    return notify("The phone dashboard is starting.")
  end
  pcall(require("azure-cli.chat").restore_plans)  -- the plans' agents from before a restart
  local s = { out = "" }
  srv = s
  local err_lines = {}
  local argv = require("azure-cli.config").provider_argv("--web-dashboard", "--bind", cfg.bind, "--port",
    tostring(cfg.port))
  local ok, job = pcall(vim.fn.jobstart, argv, {
    on_stdout = function(_, d)
      if s.url or not d then return end
      s.out = s.out .. table.concat(d, "\n")
      local first = s.out:match("^([^\n]*)\n")
      if not first then return end
      local okj, info = pcall(vim.json.decode, first)
      if okj and type(info) == "table" and info.port and info.token then
        s.url = M.url(cfg.bind, info.port, info.token)
        s.out = ""
        vim.schedule(function()
          if srv ~= s then return end
          push()
          show()
        end)
      end
    end,
    on_stderr = function(_, d) if d then vim.list_extend(err_lines, d) end end,
    on_exit = function(_, code)
      if s.timer then
        s.timer:stop()
        s.timer:close()
        s.timer = nil
      end
      if srv == s then srv = nil end
      if not s.stopping then
        local err = trim(table.concat(err_lines, " "))
        vim.schedule(function()
          notify("The phone dashboard stopped (exit " .. code .. ")" .. (err ~= "" and (": " .. err) or "."),
            vim.log.levels.WARN)
        end)
      end
    end,
  })
  if not ok or type(job) ~= "number" or job <= 0 then
    srv = nil
    return notify("Couldn't start the phone dashboard: " .. tostring(job), vim.log.levels.ERROR)
  end
  s.job = job
  s.timer = (vim.uv or vim.loop).new_timer()
  s.timer:start(M.EVERY, M.EVERY, vim.schedule_wrap(push))
  if not M._leave then
    M._leave = true
    vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() M.stop(true) end })
  end
end

function M.stop(quiet)
  if not srv then
    if not quiet then notify("The phone dashboard isn't running.") end
    return
  end
  local s = srv
  srv = nil
  s.stopping = true
  if s.timer then
    s.timer:stop()
    s.timer:close()
    s.timer = nil
  end
  -- Its stdin closing is what stops it.
  if s.job then pcall(vim.fn.chanclose, s.job, "stdin") end
  if not quiet then notify("The phone dashboard stopped.") end
end

function M.status()
  if srv and srv.url then return show() end
  if srv then return notify("The phone dashboard is starting.") end
  notify("The phone dashboard isn't running (:AzureCli web start).")
end

function M.running() return srv ~= nil and srv.url ~= nil end

-- :AzureCli web [start|stop|status]
function M.command(sub)
  sub = sub or "status"
  if sub == "start" then return M.start() end
  if sub == "stop" then return M.stop() end
  if sub == "status" then return M.status() end
  notify("azure-cli: :AzureCli web takes start, stop or status", vim.log.levels.ERROR)
end

return M
