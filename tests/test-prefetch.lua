-- test-prefetch.lua: drives cache.lua's prefetch pipeline with a
-- shimmed vim.fn.jobstart (runs the command synchronously via io.popen, then
-- defers the callbacks to a queue drained by the test, mirroring nvim's main
-- loop) against a scratch git repo and a stub provider script (spec.cmd -
-- the { bash, stub-script } argv prefix - stands in for the real
-- { python, azure-cli.py } EXT.provider/PROVIDER_CMD builds).
--
-- Usage: luajit test-prefetch.lua <cache.lua path> <scratch repo dir> <stub script path>
--
-- Checks: caching of files/commits/diffs/threads, coalescing concurrent
-- calls onto one run, no refetch of threads while fresh, refetch on thread
-- count change, the failure path (bad range) still completes without
-- caching anything, and eviction once over MAX_PRS keys.

local queue = {}
vim = {
  env = {},  -- cache.lua's run() routes non-git cmds through rpc.lua,
             -- whose M.run reads vim.env.AZVICLI_NO_DAEMON before anything else
  list_extend = function(a, b) for _, v in ipairs(b) do a[#a+1] = v end return a end,
  tbl_filter = function(f, t) local o = {} for _, v in ipairs(t) do if f(v) then o[#o+1] = v end end return o end,
  schedule = function(f) queue[#queue+1] = f end,
  fn = {
    fnamemodify = function(path, mods)
      if mods == ":p:h" then return (path:match("^(.*)[/\\][^/\\]*$") or ".") end
      return path
    end,
    jobstart = function(cmd, opts)
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
-- cache.lua's caches now live in lua/azure-cli/state.lua (require()d,
-- resolved through LUA_PATH - see tests/run.sh) instead of bare `_G.*`
-- globals; same module instance M itself just required, since require()
-- caches by module name.
local STATE = require("azure-cli.state")
local repo = arg[2]
local script = arg[3]
assert(repo and script, "usage: luajit test-prefetch.lua <cache.lua> <scratch repo dir> <stub script>")

local spec = { id = 42, updatedIso = "t1", source = "src", target = "tgt", repo = repo, totalThreads = 3,
               cmd = { "bash", script }, env = { X = "1" } }
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
-- ignore_ws = true builds the ":iws" bucket (M.diffs(key, true)) instead of
-- the plain one, from a `git diff --ignore-all-space` run. ws.txt (see
-- build_scratch_repo: tgt has "same content\n", src only adds trailing
-- whitespace) has a real, non-empty diff under the plain variant but none
-- under ignore-all-space, so it should collapse to parse_diff's "no textual
-- diff" placeholder there while the plain bucket still shows the change.
local ws_done = false
M.prefetch({ id = 42, updatedIso = "t1", source = "src", target = "tgt", repo = repo, ignore_ws = true },
  function() ws_done = true end)
drain()
assert(ws_done, "ignore_ws prefetch completed")
local iws_bucket = M.diffs(key, true)
assert(iws_bucket["ws.txt"], "iws bucket filled for ws.txt")
assert(iws_bucket["ws.txt"].lines[1] == "(no textual diff for this file)",
  "whitespace-only file collapses to the placeholder under ignore_ws, got: "
    .. tostring(iws_bucket["ws.txt"] and iws_bucket["ws.txt"].lines[1]))
local plain_bucket = M.diffs(key, false)
assert(plain_bucket["ws.txt"] and plain_bucket["ws.txt"].lines[1] ~= "(no textual diff for this file)",
  "plain bucket still shows ws.txt's real (whitespace) diff")

-- A named string variant (what review/since.lua's "changes since my
-- last review" mode uses: e.g. "since:<short-sha>") keeps its own files AND
-- diffs bucket, warm side by side with the plain/iws ones instead of
-- replacing them - and a spec.range override (a since-range's own two-dot
-- range) is diffed instead of the usual origin/<target>...origin/<source>.
-- Reuses the same tgt/src branches, just as a plain two-dot range, so this
-- should produce the exact same file list/diffs as the normal prefetch above.
local since_done = false
M.prefetch({ id = 42, updatedIso = "t1", source = "src", target = "tgt", repo = repo,
             range = "refs/remotes/origin/tgt..refs/remotes/origin/src", variant = "since:test" },
  function() since_done = true end)
drain()
assert(since_done, "since-variant prefetch completed")
local since_files = M.files(key, "since:test")
assert(since_files and #since_files == #files, "since-variant files bucket filled, same file count")
local since_bucket = M.diffs(key, "since:test")
assert(since_bucket["f.txt"] and #since_bucket["f.txt"].lines > 0, "since-variant diffs bucket filled")
-- The plain/iws buckets from earlier in this test are untouched by the
-- since-variant prefetch (different bucket entirely).
assert(M.diffs(key, false)["f.txt"], "plain bucket still intact after a since-variant prefetch")
-- Combining ignore_ws with a since-variant composes to "<variant>:iws",
-- its own bucket again - reuses the same ws.txt "collapses to the
-- placeholder" behaviour checked above, just under the since-range.
local since_iws_done = false
M.prefetch({ id = 42, updatedIso = "t1", source = "src", target = "tgt", repo = repo,
             range = "refs/remotes/origin/tgt..refs/remotes/origin/src", variant = "since:test", ignore_ws = true },
  function() since_iws_done = true end)
drain()
assert(since_iws_done, "since-variant + ignore_ws prefetch completed")
local since_iws_bucket = STATE.PR_DIFF_CACHE[key .. ":since:test:iws"]
assert(since_iws_bucket and since_iws_bucket["ws.txt"]
  and since_iws_bucket["ws.txt"].lines[1] == "(no textual diff for this file)",
  "since-variant + ignore_ws composes to its own \"<variant>:iws\" bucket")

-- Eviction keeps at most MAX_PRS keys, and cleans up a key's extra
-- string-variant buckets (files + diffs, every suffix registered above)
-- alongside its plain/iws ones once that PR version ages out.
for i = 1, M.MAX_PRS + 5 do M.diffs(M.key(1000 + i, "v")) end
assert(#STATE.PR_CACHE_ORDER == M.MAX_PRS and not STATE.PR_DIFF_CACHE[key], "evicted oldest")
assert(not STATE.PR_DIFF_CACHE[key .. ":since:test"] and not STATE.PR_DIFF_CACHE[key .. ":since:test:iws"],
  "evicted the since-variant diffs buckets too")
assert(not STATE.PR_FILES_CACHE[key .. ":since:test"], "evicted the since-variant files bucket too")
assert(not STATE.PR_DIFF_CACHE_EXTRA[key], "evicted key's extra-variant registry too")

print("prefetch pipeline ok: " .. #files .. " files")
