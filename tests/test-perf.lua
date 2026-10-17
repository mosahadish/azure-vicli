-- test-perf.lua: unit tests for perf.lua's pure helpers (M.screen_of,
-- M.fold_path, M.summarise, M.lines) - the :AzureCli perf summary of
-- azure-cli.py's perf log (#91).
--
-- Usage: luajit test-perf.lua <perf.lua path>

dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local path = arg[1]
assert(path, "usage: luajit test-perf.lua <perf.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok, extra)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. (ok and "" or ("  (" .. tostring(extra) .. ")")))
  if not ok then fails = fails + 1 end
end

-- --- M.screen_of -------------------------------------------------------------

check("screen: --list is the PR dashboard", M.screen_of("--list", "") == "PR dashboard")
check("screen: --threads is a PR review", M.screen_of("--threads", "") == "PR review")
check("screen: --wi-list is the work-items board", M.screen_of("--wi-list", "") == "Work-items board")
check("screen: --wi-list with board github is the Issues board", M.screen_of("--wi-list", "github") == "Issues board")
check("screen: anything else is Other", M.screen_of("--vote", "") == "Other")

-- --- M.fold_path -------------------------------------------------------------

do
  local p = M.fold_path("/org/proj/_apis/git/repositories/0f1e2d3c-aaaa-bbbb-cccc-0123456789ab/pullRequests/42/threads?api-version")
  check("fold_path: numbers and GUIDs fold, the query names stay",
    p == "/org/proj/_apis/git/repositories/{id}/pullRequests/{n}/threads?api-version", p)
  check("fold_path: a plain path is unchanged", M.fold_path("/graphql") == "/graphql", M.fold_path("/graphql"))
end

-- --- M.summarise -------------------------------------------------------------

local function req(cmd, ms, p, method)
  return { kind = "req", cmd = cmd, method = method or "GET", host = "dev.azure.com", path = p or "/o/_apis/x",
    status = 200, bytes = 10, ms = ms, conn = "new" }
end

local entries = {
  req("--list", 120, "/o/_apis/connectionData"),
  req("--list", 300, "/o/p/_apis/git/pullrequests/1/threads"),
  req("--list", 80, "/o/p/_apis/git/pullrequests/2/threads"),
  { kind = "total", cmd = "--list", board = "", requests = 3, req_ms = 500, wall_ms = 400 },
  req("--list", 110, "/o/_apis/connectionData"),
  { kind = "total", cmd = "--list", board = "", requests = 1, req_ms = 110, wall_ms = 150 },
  req("--threads", 50),
  { kind = "total", cmd = "--threads", board = "", requests = 1, req_ms = 50, wall_ms = 60 },
  req("--wi-list", 900, "/graphql", "POST"),
  { kind = "total", cmd = "--wi-list", board = "github", requests = 1, req_ms = 900, wall_ms = 950 },
  { kind = "total", cmd = "--print-pat", board = "", requests = 0, req_ms = 0, wall_ms = 1 },
  "not a table",
}

do
  local s = M.summarise(entries, { slowest = 3 })
  local names = {}
  for _, sc in ipairs(s.screens) do names[#names + 1] = sc.name end
  check("summarise: screens in order, a total with no requests left out",
    table.concat(names, ",") == "PR dashboard,PR review,Issues board", table.concat(names, ","))

  local list = s.screens[1].cmds[1]
  check("summarise: --list's calls", list.cmd == "--list" and list.calls == 2, list.calls)
  check("summarise: requests per tick avg / max / last",
    list.requests.avg == 2 and list.requests.max == 3 and list.requests.last == 1,
    list.requests.avg .. "/" .. list.requests.max .. "/" .. list.requests.last)
  check("summarise: wall ms per tick avg / max / last",
    list.wall_ms.avg == 275 and list.wall_ms.max == 400 and list.wall_ms.last == 150,
    list.wall_ms.avg .. "/" .. list.wall_ms.max .. "/" .. list.wall_ms.last)

  check("summarise: slowest N, slowest first",
    #s.slowest == 3 and s.slowest[1].ms == 900 and s.slowest[2].ms == 300 and s.slowest[3].ms == 120,
    #s.slowest)

  local top = s.paths[1]
  check("summarise: endpoints by count, ids folded - the repeated one first",
    top.key == "GET dev.azure.com/o/_apis/connectionData" and top.count == 2 and top.avg_ms == 115, top.key)
  local threads
  for _, p in ipairs(s.paths) do
    if p.key == "GET dev.azure.com/o/p/_apis/git/pullrequests/{n}/threads" then threads = p end
  end
  check("summarise: two PRs' /threads count as one endpoint", threads and threads.count == 2)
end

-- --- M.lines -----------------------------------------------------------------

do
  local lines = M.lines(M.summarise(entries))
  local text = table.concat(lines, "\n")
  check("lines: a section per screen", text:find("PR dashboard", 1, true) and text:find("Issues board", 1, true))
  check("lines: the --list row", text:find("--list", 1, true) and text:find("2 calls", 1, true), text)
  check("lines: the slowest and the endpoint sections",
    text:find("Slowest requests", 1, true) and text:find("Requests by endpoint", 1, true))

  local empty = M.lines(M.summarise({}))
  check("lines: an empty log says how to fill it", #empty == 1 and empty[1]:find("AZVICLI_DEBUG=1", 1, true), empty[1])
end

if fails > 0 then
  print(fails .. " test(s) failed")
  os.exit(1)
end
print("all perf tests passed")
