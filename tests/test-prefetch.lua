-- test-prefetch.lua: drives prdash-cache.lua's prefetch pipeline with a
-- shimmed vim.fn.jobstart (runs the command synchronously via io.popen, then
-- defers the callbacks to a queue drained by the test, mirroring nvim's main
-- loop) against a scratch git repo and a stub review script.
--
-- Usage: luajit test-prefetch.lua <prdash-cache.lua path> <scratch repo dir> <stub script path>
--
-- Checks: caching of files/commits/diffs/threads, coalescing concurrent
-- calls onto one run, no refetch of threads while fresh, refetch on thread
-- count change, the failure path (bad range) still completes without
-- caching anything, and eviction once over MAX_PRS keys.

local queue = {}
vim = {
  list_extend = function(a, b) for _, v in ipairs(b) do a[#a+1] = v end return a end,
  tbl_filter = function(f, t) local o = {} for _, v in ipairs(t) do if f(v) then o[#o+1] = v end end return o end,
  schedule = function(f) queue[#queue+1] = f end,
  fn = { jobstart = function(cmd, opts)
    local parts = {}
    for _, c in ipairs(cmd) do parts[#parts+1] = "'" .. c:gsub("'", "'\\''") .. "'" end
    local p = io.popen(table.concat(parts, " ") .. " 2>/dev/null; echo \"__rc=$?\"")
    local out = {}
    for l in p:lines() do out[#out+1] = l end
    p:close()
    local rc = tonumber(out[#out]:match("__rc=(%d+)")); out[#out] = nil
    out[#out+1] = ""
    opts.on_stdout(0, out); opts.on_exit(0, rc)
    return 1
  end },
}
local function drain() while #queue > 0 do local f = table.remove(queue, 1); f() end end

local M = dofile(arg[1])
local repo = arg[2]
local script = arg[3]
assert(repo and script, "usage: luajit test-prefetch.lua <prdash-cache.lua> <scratch repo dir> <stub script>")

local spec = { id = 42, updatedIso = "t1", source = "src", target = "tgt", repo = repo, totalThreads = 3,
               bash = "bash", script = script, env = { X = "1" } }
local done = 0
M.prefetch(spec, function() done = done + 1 end)
M.prefetch(spec, function() done = done + 1 end)  -- coalesces onto the same run
drain()
local key = M.key(42, "t1")
local files = M.files(key)
assert(files and #files > 0, "files cached")
assert(M.is_complete(key), "complete")
assert(M.commits(key) and #M.commits(key) > 0, "commits cached")
assert(M.threads(42) and M.threads(42).json:match("threads%-ok") and M.threads(42).totalThreads == 3, "threads cached")
assert(done == 2, "both callbacks ran, got " .. done)
-- Second call is a no-op for git/commits, and threads are fresh -> only the callback fires.
local before = M.threads(42).ts
M.prefetch(spec, function() done = done + 1 end); drain()
assert(done == 3 and M.threads(42).ts == before, "no refetch when fresh")
-- Count change -> threads refetched.
spec.totalThreads = 4
M.prefetch(spec); drain()
assert(M.threads(42).totalThreads == 4, "refetched on count change")
-- Failing fetch (bad range) leaves nothing cached and still completes.
local bad = { id = 7, updatedIso = "x", source = "nope", target = "tgt", repo = repo }
local fin = false
M.prefetch(bad, function() fin = true end); drain()
assert(fin and not M.files(M.key(7, "x")), "bad range completes without caching")
-- Eviction keeps at most MAX_PRS keys.
for i = 1, M.MAX_PRS + 5 do M.diffs(M.key(1000 + i, "v")) end
assert(#_G.PR_CACHE_ORDER == M.MAX_PRS and not _G.PR_DIFF_CACHE[key], "evicted oldest")
print("prefetch pipeline ok: " .. #files .. " files")
