-- prdash-cache.lua: per-PR content caches and the background prefetch
-- pipeline that fills them, shared by the dashboard (azure-cli.lua) and the
-- reviewer (pr-review.lua), which run in the same nvim. Loaded with dofile()
-- by both, so the caches live in _G and survive each script's re-luafile.
--
-- Everything the reviewer needs to open a PR is cached here, keyed by the PR
-- id plus its last-activity timestamp (a new push therefore invalidates the
-- lot, and old PRs are evicted once more than MAX_PRS are held):
--   files    the changed paths           (git diff --name-only)
--   commits  the Overview's commit list  (git log)
--   diffs    every file's parsed diff    (ONE git diff over the whole range,
--                                         split per file, not one spawn per
--                                         file: under git-bash each spawn is
--                                         ~300ms, so a 20-file PR went from
--                                         twenty spawns to one; cached twice
--                                         per PR version, plain and with
--                                         --ignore-all-space (the reviewer's
--                                         gw toggle), under a ":iws"-suffixed
--                                         key so both are warm at once)
--   threads  the raw comment-thread JSON (review-pr.sh --threads), keyed by
--            id only and stamped with the thread count it was fetched at so
--            the list feed's count can tell when it's out of date
-- The dashboard fills these while the cursor rests on a PR and, after each
-- list load, for every open PR whose branches it has warmed; the reviewer
-- reads them on open and falls back to fetching on its own for any miss.
local M = {}

_G.PR_DIFF_CACHE    = _G.PR_DIFF_CACHE or {}     -- key -> { [path] = {lines, map} }; key..":iws" holds the --ignore-all-space variant
_G.PR_FILES_CACHE   = _G.PR_FILES_CACHE or {}    -- key -> { paths }
_G.PR_COMMITS_CACHE = _G.PR_COMMITS_CACHE or {}  -- key -> { lines }
_G.PR_CACHE_ORDER   = _G.PR_CACHE_ORDER or {}    -- keys, oldest first
_G.PR_THREADS_CACHE = _G.PR_THREADS_CACHE or {}  -- id -> { json, ts, totalThreads }

M.MAX_PRS = 24        -- PRs whose files/commits/diffs are held at once
M.THREADS_TTL = 120   -- seconds before a cached thread list is refetched on hover

function M.key(id, updated_iso)
  return tostring(id) .. ":" .. tostring(updated_iso or "")
end

-- Register a key (creating its diff buckets, plain and ignore-whitespace) and
-- evict the oldest PRs' entries across all three per-key caches once over
-- MAX_PRS. Eviction counts PR versions, not diff variants: both buckets for
-- a key are created and evicted together, so toggling gw never changes how
-- many PRs the cache holds.
local function touch(key)
  if _G.PR_DIFF_CACHE[key] then return end
  _G.PR_DIFF_CACHE[key] = {}
  _G.PR_DIFF_CACHE[key .. ":iws"] = {}
  table.insert(_G.PR_CACHE_ORDER, key)
  while #_G.PR_CACHE_ORDER > M.MAX_PRS do
    local evict = table.remove(_G.PR_CACHE_ORDER, 1)
    _G.PR_DIFF_CACHE[evict] = nil
    _G.PR_DIFF_CACHE[evict .. ":iws"] = nil
    _G.PR_FILES_CACHE[evict] = nil
    _G.PR_COMMITS_CACHE[evict] = nil
  end
end

-- ignore_ws selects the --ignore-all-space diff variant, cached separately
-- under key..":iws" (files/commits/threads have no whitespace dimension, so
-- they stay keyed by `key` alone - see M.files/M.commits/M.threads below).
function M.diffs(key, ignore_ws)
  touch(key)
  return _G.PR_DIFF_CACHE[ignore_ws and (key .. ":iws") or key]
end
function M.files(key) return _G.PR_FILES_CACHE[key] end
function M.commits(key) return _G.PR_COMMITS_CACHE[key] end
function M.threads(id) return _G.PR_THREADS_CACHE[tostring(id)] end
function M.set_files(key, list) touch(key); _G.PR_FILES_CACHE[key] = list end
function M.set_commits(key, list) touch(key); _G.PR_COMMITS_CACHE[key] = list end
function M.set_threads(id, json, total)
  _G.PR_THREADS_CACHE[tostring(id)] = { json = json, ts = os.time(), totalThreads = total }
end

-- Parses raw `git diff` output for ONE file into display lines plus a
-- per-line {side, lineno} map so a comment on any buffer line anchors to the
-- correct file/side. Line numbers are derived from the hunk headers
-- (@@ -a,b +c,d @@); header/metadata lines get a nil side (not commentable).
function M.parse_diff(raw)
  local lines = {}
  local map = {}
  local new, old = 0, 0
  for _, l in ipairs(raw) do
    local c = l:sub(1, 1)
    if l:match("^@@") then
      -- Hunk header: update line counters but don't display it.
      old = (tonumber(l:match("%-(%d+)")) or 1) - 1
      new = (tonumber(l:match("%+(%d+)")) or 1) - 1
    elseif l:match("^%+%+%+") or l:match("^%-%-%-") or l:match("^diff ")
        or l:match("^index ") or l:match("^new file") or l:match("^deleted file")
        or l:match("^old mode") or l:match("^new mode")
        or l:match("^rename ") or l:match("^similarity ")
        or l:match("^copy ") or l:match("^\\") then
      -- Git metadata: drop it entirely.
    elseif c == "+" then
      new = new + 1
      lines[#lines + 1] = l:sub(2)
      map[#map + 1] = { side = "R", lineno = new, kind = "add" }
    elseif c == "-" then
      old = old + 1
      lines[#lines + 1] = l:sub(2)
      map[#map + 1] = { side = "L", lineno = old, kind = "del" }
    else
      new = new + 1
      old = old + 1
      lines[#lines + 1] = l:sub(2)
      map[#map + 1] = { side = "R", lineno = new, kind = "ctx" }
    end
  end
  if #lines == 0 then
    lines = { "(no textual diff for this file)" }
    map = { {} }
  end
  return lines, map
end

-- Splits a multi-file `git diff` into { [path] = raw lines }, one entry per
-- "diff --git" section. The path comes from the "+++ b/<path>" line (or
-- "--- a/<path>" for a deletion), which is exactly what --name-only prints
-- for the same file, so the split keys match the file list.
function M.split_diff(raw)
  local out, cur, path = {}, nil, nil
  local function flush()
    if cur and path then out[path] = cur end
  end
  for _, l in ipairs(raw) do
    if l:match("^diff %-%-git ") then
      flush()
      cur, path = {}, nil
    end
    if cur then
      cur[#cur + 1] = l
      if not path then
        local p = l:match("^%+%+%+ b/(.*)$")
        if not p then
          local d = l:match("^%-%-%- a/(.*)$")
          if d and not l:match("^%-%-%- /dev/null") then path = d end
        else
          path = p
        end
      end
    end
  end
  flush()
  return out
end

-- git argv rooted at `repo` (a clone path; "" means the cwd).
function M.git(repo, args)
  local a = { "git" }
  if repo and repo ~= "" then
    a[#a + 1] = "-C"
    a[#a + 1] = repo
  end
  vim.list_extend(a, args)
  return a
end

-- Run a command in the background, calling cb(code, stdout_lines) on the
-- main loop once it exits (always asynchronously, even when it fails to
-- start, so callers' bookkeeping never sees a re-entrant callback).
local function run(cmd, env, cb)
  local out = {}
  local ok = pcall(vim.fn.jobstart, cmd, {
    env = env,
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code) vim.schedule(function() cb(code, out) end) end,
  })
  if not ok then vim.schedule(function() cb(-1, {}) end) end
end

-- Fill every cache for one PR, skipping whatever is already there, so this
-- is cheap to call repeatedly (hover, warm-all, open). Concurrent calls for
-- the same PR version coalesce onto one run. The local git work (files, then
-- the whole-range diff; commits alongside) and the threads fetch (network)
-- run side by side. cb() (optional) runs once everything has finished.
--
-- spec: { id, updatedIso, source, target, repo (clone path), totalThreads,
--         bash, script, env, ignore_ws }  - bash/script/env drive the threads
--         fetch and may be omitted to skip it (the reviewer does its own).
--         ignore_ws selects the --ignore-all-space diff variant (cached
--         separately under key..":iws", see M.diffs); files/commits/threads
--         are unaffected, so the dashboard's normal (non-ignore_ws) prefetch
--         and a toggled reviewer's can run for the same PR at once.
local inflight = {}  -- key (":iws"-suffixed when ignore_ws) -> { callbacks }
function M.prefetch(spec, cb)
  local key = M.key(spec.id, spec.updatedIso)
  local variant_key = spec.ignore_ws and (key .. ":iws") or key
  if inflight[variant_key] then
    if cb then table.insert(inflight[variant_key], cb) end
    return
  end
  inflight[variant_key] = { cb }
  local range = "origin/" .. spec.target .. "...origin/" .. spec.source
  local diff_args = { "diff", "--unified=100000" }
  if spec.ignore_ws then diff_args[#diff_args + 1] = "--ignore-all-space" end
  diff_args[#diff_args + 1] = range
  local pending = 0
  local function start() pending = pending + 1 end
  local function done_one()
    pending = pending - 1
    if pending > 0 then return end
    local cbs = inflight[variant_key] or {}
    inflight[variant_key] = nil
    for _, f in ipairs(cbs) do if f then f() end end
  end

  -- Files, then every missing file's diff from a single git run.
  start()
  local function after_files(files)
    local bucket = M.diffs(key, spec.ignore_ws)
    local missing = false
    for _, f in ipairs(files) do
      if not bucket[f] then missing = true break end
    end
    if not missing then done_one() return end
    run(M.git(spec.repo, diff_args), nil, function(code, out)
      if code == 0 then
        local per = M.split_diff(out)
        for _, f in ipairs(files) do
          if not bucket[f] then
            -- A file --name-only lists can still be absent from the combined
            -- diff's sections when ignore_ws is on and its only changes were
            -- whitespace: git omits such a file entirely rather than
            -- emitting an empty hunk for it. parse_diff({}) is exactly what
            -- a single-file build of that file would produce anyway (the
            -- "no textual diff" placeholder), so caching that here keeps it
            -- from being re-fetched on every open instead of ever settling.
            local lines, map = M.parse_diff(per[f] or {})
            bucket[f] = { lines = lines, map = map }
          end
        end
      end
      done_one()
    end)
  end
  local files = M.files(key)
  if files then
    after_files(files)
  else
    run(M.git(spec.repo, { "diff", "--name-only", range }), nil, function(code, out)
      if code ~= 0 then done_one() return end
      local list = vim.tbl_filter(function(f) return f ~= "" end, out)
      M.set_files(key, list)
      after_files(list)
    end)
  end

  if not M.commits(key) then
    start()
    run(M.git(spec.repo, { "log", "--format=%h  %ad  %an: %s", "--date=short",
        "origin/" .. spec.target .. "..origin/" .. spec.source }), nil, function(code, out)
      if code == 0 then
        M.set_commits(key, vim.tbl_filter(function(l) return l ~= "" end, out))
      end
      done_one()
    end)
  end

  local th = M.threads(spec.id)
  local stale = th == nil
    or (spec.totalThreads ~= nil and th.totalThreads ~= spec.totalThreads)
    or (os.time() - th.ts) > M.THREADS_TTL
  if stale and spec.bash and spec.script then
    start()
    run({ spec.bash, spec.script, "--threads" }, spec.env, function(code, out)
      if code == 0 then
        M.set_threads(spec.id, table.concat(out, "\n"), spec.totalThreads)
      end
      done_one()
    end)
  end
end

-- True while a prefetch for this PR version is in flight.
function M.is_syncing(key)
  return inflight[key] ~= nil
end

-- True once files and every file's diff are cached for this PR version.
function M.is_complete(key)
  local files = M.files(key)
  if not files then return false end
  local bucket = _G.PR_DIFF_CACHE[key] or {}
  for _, f in ipairs(files) do
    if not bucket[f] then return false end
  end
  return M.commits(key) ~= nil
end

return M
