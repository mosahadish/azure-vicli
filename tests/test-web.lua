-- test-web.lua: unit tests for web.lua's pure helpers (M.snapshot, M.url) -
-- the phone dashboard's page JSON built from the Agents screen's rows (#97).
--
-- Usage: luajit test-web.lua <web.lua path>   (LUA_PATH finding chat/core.lua)

dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local path = arg[1]
assert(path, "usage: luajit test-web.lua <web.lua path>")
local M = dofile(path)
local CORE = require("azure-cli.chat.core")

local fails = 0
local function check(name, ok, extra)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. (ok and "" or ("  (" .. tostring(extra) .. ")")))
  if not ok then fails = fails + 1 end
end

-- Rows as agents_view.rows makes them, with everything a row carries -
-- including what the page must never show.
local waiting = {
  key = "wi-3002", label = "#3002", title = "--name takes the flag", state = "\u{25CF} plan waits for you",
  hl = "AzureCliStatusDraft", detail = "", ago = "3m", group = 1, at = 100, waiting = true,
  target = { work_item_id = 3002, repo = "widgets", worktree = "/home/me/.cache/nvim/azure-cli/fix-worktrees/w" },
  conv = { plan_key = "wi-3002", entries = { { text = "SECRET PLAN TEXT" } } },
  pr_id = 118, cost = 0.42, context = { used = 27, size = 100 },
}
local working = {
  key = "wi-3001", label = "#3001", title = "Throttle logins", state = " working", hl = "AzureCliAccent",
  detail = "\u{270E} start_story", ago = "12s", group = 2, at = 200, requests = 3,
  conv = { plan_key = "wi-3001", entries = {} },
}
local finished = { key = "wi-2990", label = "#2990", title = "Old", state = "\u{2713} merged (PR !99)", group = 4,
  ago = "9d", cost = 1, at = 1 }
local arranged = { { header = "Needs you (1)" }, waiting, { header = "Working (1)" }, working }
local rows = { waiting, working, finished }

local snap = M.snapshot(arranged, rows, { working = 1, queued = 2, max = 3, hidden = 1, finished_days = 7 }, CORE)

check("headers stay where arrange put them: Needs you first",
  snap.items[1].header == "Needs you (1)" and snap.items[3].header == "Working (1)" and #snap.items == 4)
local r = snap.items[2]
check("a row: label, title, state, group, age", r.label == "#3002" and r.title == "--name takes the flag"
  and r.state == "\u{25CF} plan waits for you" and r.group == 1 and r.ago == "3m")
check("a row: its cost as the screen shows it", r.cost == "$0.42", r.cost)
check("a row: context then the tool line, as the screen shows it", r.detail == "ctx 27%", r.detail)
check("a working row: no spinner frame, its premium requests, its tool line",
  snap.items[4].state == "working" and snap.items[4].cost == "3 req" and snap.items[4].detail == "\u{270E} start_story",
  snap.items[4].state .. "|" .. snap.items[4].cost .. "|" .. snap.items[4].detail)
check("totals: as the winbar, over the hidden ones too",
  snap.totals == "1 working \u{00B7} 2 queued \u{00B7} max 3 \u{00B7} $1.42 so far \u{00B7} 3 premium requests so far",
  snap.totals)
check("hidden and finished_days carried", snap.hidden == 1 and snap.finished_days == 7)

-- Nothing beyond those fields, anywhere in the snapshot.
local ALLOWED = { label = true, title = true, state = true, group = true, ago = true, cost = true, detail = true }
local extra = {}
for _, it in ipairs(snap.items) do
  for k in pairs(it) do
    if not (it.header and k == "header") and not ALLOWED[k] then extra[#extra + 1] = k end
  end
end
for k in pairs(snap) do
  if not ({ items = true, totals = true, hidden = true, finished_days = true })[k] then extra[#extra + 1] = k end
end
check("only the shown fields: no key, target, conv, pr_id", #extra == 0, table.concat(extra, ","))

local function walk(v, seen)
  if type(v) == "string" then seen[#seen + 1] = v
  elseif type(v) == "table" then for _, x in pairs(v) do walk(x, seen) end end
  return seen
end
local leaked = {}
for _, s in ipairs(walk(snap, {})) do
  if s:find("SECRET PLAN TEXT", 1, true) or s:find("fix-worktrees", 1, true) or s:find("wi-300", 1, true) then
    leaked[#leaked + 1] = s
  end
end
check("no plan text, paths or plan keys", #leaked == 0, table.concat(leaked, ","))

local empty = M.snapshot({}, {}, { working = 0, max = 3 }, CORE)
check("no rows: no items, the totals still", #empty.items == 0 and empty.totals == "0 working \u{00B7} max 3",
  empty.totals)

check("url: an IPv4 bind", M.url("100.64.0.5", 8797, "abc") == "http://100.64.0.5:8797/?token=abc")
check("url: an IPv6 bind is bracketed", M.url("fd7a::1", 8797, "abc") == "http://[fd7a::1]:8797/?token=abc")
check("url: an already bracketed one isn't doubled", M.url("[::1]", 1, "t") == "http://[::1]:1/?token=t")

print(fails == 0 and "test-web: all cases pass" or ("test-web: " .. fails .. " failed"))
if fails > 0 then os.exit(1) end
