-- lua/azure-cli/cache.lua: per-PR content caches and the background
-- prefetch pipeline that fills them, shared by the dashboard and the
-- reviewer, which run in the same nvim. require()'d by both - require()
-- caches the module, and the caches themselves live in
-- lua/azure-cli/state.lua, so they survive each surface's re-open().
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
--   threads  the raw comment-thread JSON (the data provider's --threads),
--            keyed by
--            id only and stamped with the thread count it was fetched at so
--            the list feed's count can tell when it's out of date
-- The dashboard fills these while the cursor rests on a PR and, after each
-- list load, for every open PR whose branches it has warmed; the reviewer
-- reads them on open and falls back to fetching on its own for any miss.
local M = {}
local STATE = require("azure-cli.state")
local RPC = require("azure-cli.rpc")

local PR_DIFF_CACHE    = STATE.PR_DIFF_CACHE     -- key -> { [path] = {lines, map} }; key..":iws" holds the --ignore-all-space variant
local PR_FILES_CACHE   = STATE.PR_FILES_CACHE    -- key -> { paths }
local PR_COMMITS_CACHE = STATE.PR_COMMITS_CACHE  -- key -> { lines }
local PR_CACHE_ORDER   = STATE.PR_CACHE_ORDER    -- keys, oldest first
local PR_THREADS_CACHE = STATE.PR_THREADS_CACHE  -- id -> { json, ts, totalThreads }
-- key -> { suffix, ... }: extra string-variant suffixes (e.g. ":since:<sha>"
-- or ":since:<sha>:iws", from the "changes since my last review" mode - see
-- M.diffs/M.files below) registered for that PR version, on top of the
-- always-present plain/":iws" pair - so touch()'s eviction below can drop
-- them alongside everything else once that PR version ages out.
local PR_DIFF_CACHE_EXTRA = STATE.PR_DIFF_CACHE_EXTRA

M.MAX_PRS = 24        -- PRs whose files/commits/diffs are held at once
M.THREADS_TTL = 120   -- seconds before a cached thread list is refetched on hover

function M.key(id, updated_iso)
  return tostring(id) .. ":" .. tostring(updated_iso or "")
end

-- Register a key (creating its diff buckets, plain and ignore-whitespace) and
-- evict the oldest PRs' entries across all three per-key caches once over
-- MAX_PRS. Eviction counts PR versions, not diff variants: both buckets for
-- a key are created and evicted together, so toggling gw never changes how
-- many PRs the cache holds. Any extra string-variant buckets registered for
-- this key (see variant_suffix below) are evicted alongside it too.
local function touch(key)
  if PR_DIFF_CACHE[key] then return end
  PR_DIFF_CACHE[key] = {}
  PR_DIFF_CACHE[key .. ":iws"] = {}
  table.insert(PR_CACHE_ORDER, key)
  while #PR_CACHE_ORDER > M.MAX_PRS do
    local evict = table.remove(PR_CACHE_ORDER, 1)
    PR_DIFF_CACHE[evict] = nil
    PR_DIFF_CACHE[evict .. ":iws"] = nil
    PR_FILES_CACHE[evict] = nil
    PR_COMMITS_CACHE[evict] = nil
    for _, suffix in ipairs(PR_DIFF_CACHE_EXTRA[evict] or {}) do
      PR_DIFF_CACHE[evict .. suffix] = nil
      PR_FILES_CACHE[evict .. suffix] = nil
    end
    PR_DIFF_CACHE_EXTRA[evict] = nil
  end
end

-- Resolves a M.diffs/M.files/M.set_files `variant` argument to the ":"-
-- prefixed suffix appended to `key` for that bucket, registering it (once)
-- in PR_DIFF_CACHE_EXTRA so touch()'s eviction above cleans it up alongside
-- the rest of that PR version - "" for the plain bucket. `true` is the
-- original ignore-whitespace toggle (gw), kept as a boolean for every
-- existing caller; a non-empty string is any other named variant - today
-- just the "since:<sha>"/"since:<sha>:iws" buckets review/since.lua's
-- "changes since my last review" mode (gi) keeps warm side by side with the
-- normal ones.
local function variant_suffix(key, variant)
  if variant == true then return ":iws" end
  if type(variant) == "string" and variant ~= "" then
    local suffix = ":" .. variant
    local extra = PR_DIFF_CACHE_EXTRA[key]
    if not extra then extra = {}; PR_DIFF_CACHE_EXTRA[key] = extra end
    local seen = false
    for _, s in ipairs(extra) do if s == suffix then seen = true break end end
    if not seen then extra[#extra + 1] = suffix end
    return suffix
  end
  return ""
end

-- variant selects which diff bucket to read/create: nil/false for the plain
-- one, true for the --ignore-all-space one (key..":iws", the gw toggle), or
-- any other string for its own named bucket (key..":"..variant) - kept warm
-- alongside the rest instead of replacing them, and evicted together with
-- this PR version (see variant_suffix above).
function M.diffs(key, variant)
  touch(key)
  local suffix = variant_suffix(key, variant)
  if suffix == "" then return PR_DIFF_CACHE[key] end
  PR_DIFF_CACHE[key .. suffix] = PR_DIFF_CACHE[key .. suffix] or {}
  return PR_DIFF_CACHE[key .. suffix]
end
-- variant: nil for the PR's normal file list, or a string (see M.diffs) for
-- a named variant's own list - e.g. the files actually changed in a
-- "changes since my last review" sub-range, which differs from the PR's
-- full file list. Unlike M.diffs, there's no separate ignore-whitespace
-- dimension here (the set of changed files doesn't depend on -w).
function M.files(key, variant)
  if type(variant) == "string" and variant ~= "" then
    return PR_FILES_CACHE[key .. ":" .. variant]
  end
  return PR_FILES_CACHE[key]
end
function M.commits(key) return PR_COMMITS_CACHE[key] end
function M.threads(id) return PR_THREADS_CACHE[tostring(id)] end
function M.set_files(key, list, variant)
  touch(key)
  if type(variant) == "string" and variant ~= "" then
    PR_FILES_CACHE[key .. variant_suffix(key, variant)] = list
  else
    PR_FILES_CACHE[key] = list
  end
end
function M.set_commits(key, list) touch(key); PR_COMMITS_CACHE[key] = list end
function M.set_threads(id, json, total)
  PR_THREADS_CACHE[tostring(id)] = { json = json, ts = os.time(), totalThreads = total }
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
        or l:match("^copy ") or l:match("^Binary files ") or l:match("^\\") then
      -- Git metadata: drop it entirely. "Binary files ... differ" too: an
      -- image's section is nothing but metadata, so it falls through to
      -- the "(no textual diff for this file)" placeholder below instead of
      -- rendering as a bogus context line.
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

-- Tokenizes a line into words and non-word runs: [%w_]+, whitespace runs,
-- and single punctuation characters. Concatenating the tokens reproduces
-- the line exactly, so byte offsets can be recovered by summing token
-- lengths - that's what word_pair_marks below does.
local function tokenize(s)
  local toks = {}
  local i, n = 1, #s
  while i <= n do
    local ws = s:match("^%s+", i)
    if ws then
      toks[#toks + 1] = ws
      i = i + #ws
    else
      local w = s:match("^[%w_]+", i)
      if w then
        toks[#toks + 1] = w
        i = i + #w
      else
        toks[#toks + 1] = s:sub(i, i)
        i = i + 1
      end
    end
  end
  return toks
end

-- Compares a deleted/added line pair token-by-token: the longest common
-- prefix and suffix (in token units, so a partial word never gets split)
-- bracket the middle that actually changed. Returns the {s, e} byte range
-- of that middle for each side (0-based, exclusive end, ready for an
-- extmark's col/end_col), or nil for a side with nothing left to mark.
-- When neither a prefix nor a suffix is shared the whole line differs, so
-- both are nil - the line-level highlight already says it all.
local function word_pair_marks(a, b)
  local ta, tb = tokenize(a), tokenize(b)
  local common = math.min(#ta, #tb)
  local p = 0
  while p < common and ta[p + 1] == tb[p + 1] do p = p + 1 end
  local s = 0
  while s < (common - p) and ta[#ta - s] == tb[#tb - s] do s = s + 1 end
  if p == 0 and s == 0 then return nil, nil end
  local function range(toks)
    local total, sbytes, ebytes = 0, 0, 0
    for i, t in ipairs(toks) do
      total = total + #t
      if i <= p then sbytes = sbytes + #t end
      if i > #toks - s then ebytes = ebytes + #t end
    end
    return sbytes, total - ebytes
  end
  local as_, ae = range(ta)
  local bs_, be = range(tb)
  local am = as_ < ae and { s = as_, e = ae } or nil
  local bm = bs_ < be and { s = bs_, e = be } or nil
  return am, bm
end

-- Word-level highlights for "modified" blocks: a run of deleted lines
-- immediately followed by a run of added lines. Pairs the i-th deleted line
-- with the i-th added line of such a block (an unequal count leaves the
-- longer run's extra lines with only the plain line-level highlight - see
-- decorate_diff/decorate_revision in pr-review.lua) and, per pair, finds
-- the byte range that actually changed via word_pair_marks. Skips a pair if
-- either line is over 1000 bytes (tokenizing and comparing long generated
-- lines line-by-line isn't worth the cost, and the line highlight is enough
-- there anyway). Pure and side-effect free so it's testable without nvim.
--
-- Returns a list of { line = <1-based index into lines/map>, s = <0-based
-- byte column>, e = <exclusive byte column>, kind = "add"|"del" }.
function M.word_diff(lines, map)
  local marks = {}
  local i, n = 1, #map
  while i <= n do
    if map[i].kind ~= "del" then
      i = i + 1
    else
      local del_start = i
      while i <= n and map[i].kind == "del" do i = i + 1 end
      local del_end = i - 1
      if i <= n and map[i].kind == "add" then
        local add_start = i
        while i <= n and map[i].kind == "add" do i = i + 1 end
        local add_end = i - 1
        local pair_n = math.min(del_end - del_start + 1, add_end - add_start + 1)
        for k = 0, pair_n - 1 do
          local dl, al = del_start + k, add_start + k
          local dtext, atext = lines[dl], lines[al]
          if #dtext <= 1000 and #atext <= 1000 then
            local dm, am = word_pair_marks(dtext, atext)
            if dm then marks[#marks + 1] = { line = dl, s = dm.s, e = dm.e, kind = "del" } end
            if am then marks[#marks + 1] = { line = al, s = am.s, e = am.e, kind = "add" } end
          end
        end
      end
    end
  end
  return marks
end

-- Splits a multi-file `git diff` into { [path] = raw lines }, one entry per
-- "diff --git" section. The path prefers the "+++ b/<path>" line (the
-- new/b-side - what --name-only reports for every non-deletion, including a
-- rename: "--- a/<old>" always comes first in a section, so a rename with
-- content changes has both lines and must not let the earlier "---" one
-- win), falling back to "--- a/<path>" only when there's no "+++ b/..." at
-- all - a pure deletion (whose "+++" side is "/dev/null"). A binary file's
-- section has neither line (just "Binary files ... differ"), so the last
-- resort is the b-side of the "diff --git a/<path> b/<path>" header itself
-- - otherwise an image in a PR would never get a diffs entry at all and
-- its file-list row would show "(?)" forever.
function M.split_diff(raw)
  local out, cur, path, del_path, hdr_path = {}, nil, nil, nil, nil
  local function flush()
    local p = path or del_path or hdr_path
    if cur and p then out[p] = cur end
  end
  for _, l in ipairs(raw) do
    if l:match("^diff %-%-git ") then
      flush()
      cur, path, del_path = {}, nil, nil
      hdr_path = l:match("^diff %-%-git a/.- b/(.*)$")
    end
    if cur then
      cur[#cur + 1] = l
      if not path then
        local p = l:match("^%+%+%+ b/(.*)$")
        if p then path = p end
      end
      if not del_path then
        local d = l:match("^%-%-%- a/(.*)$")
        if d then del_path = d end
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

-- lua/azure-cli/rpc.lua, required at the top of this file (only the threads
-- fetch below ever needs it - the far more common caller here is M.git's
-- own "git" argv, which never goes through the daemon). require() caches
-- the module, so this still shares the one daemon rpc.lua itself keeps in
-- lua/azure-cli/state.lua.

-- Run a command in the background, calling cb(code, stdout_lines) on the
-- main loop once it exits (always asynchronously, even when it fails to
-- start, so callers' bookkeeping never sees a re-entrant callback). `cmd`
-- is either a git argv (M.git above - always run directly) or the data
-- provider's argv (spec.cmd + a subcommand, below - routed through the
-- shared daemon client when it's a provider call, same as every other
-- caller of the provider in this codebase).
local function run(cmd, env, cb)
  local out = {}
  local runner = (cmd[1] == "git") and vim.fn.jobstart or RPC.run
  local ok = pcall(runner, cmd, {
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
--         cmd, env, ignore_ws, range, variant }  - cmd (the data-provider argv
--         prefix, e.g. { python, azure-cli.py } - see EXT.provider/PROVIDER_CMD)
--         and env drive the threads fetch and may be omitted to skip it (the
--         reviewer does its own). ignore_ws selects the --ignore-all-space
--         diff variant (cached separately under key..":iws", see M.diffs);
--         files/commits/threads are unaffected, so the dashboard's normal
--         (non-ignore_ws) prefetch and a toggled reviewer's can run for the
--         same PR at once. range overrides the usual
--         origin/<target>...origin/<source> range (three-dot, merge-base
--         diff) - review/since.lua's "changes since my last review"
--         mode (gi) passes its own two-dot "<base>..origin/<source>" range
--         instead. variant names the files/diffs bucket that range's result
--         is cached under (see M.diffs/M.files) instead of the plain one -
--         required whenever `range` is given, since a plain-keyed bucket
--         must always hold the PR's real (three-dot) range. A variant'd
--         prefetch only fills files + diffs; commits/threads are PR-wide,
--         not range-scoped, and are left to the plain prefetch.
local inflight = {}  -- key (variant-suffixed, see below) -> { callbacks }
function M.prefetch(spec, cb)
  local key = M.key(spec.id, spec.updatedIso)
  local variant_key = key .. (spec.variant and (":" .. spec.variant) or "") .. (spec.ignore_ws and ":iws" or "")
  if inflight[variant_key] then
    if cb then table.insert(inflight[variant_key], cb) end
    return
  end
  inflight[variant_key] = { cb }
  local range = spec.range or ("origin/" .. spec.target .. "...origin/" .. spec.source)
  local diff_args = { "diff", "--unified=100000" }
  if spec.ignore_ws then diff_args[#diff_args + 1] = "--ignore-all-space" end
  diff_args[#diff_args + 1] = range
  local diff_variant = spec.variant and (spec.ignore_ws and (spec.variant .. ":iws") or spec.variant) or spec.ignore_ws
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
    local bucket = M.diffs(key, diff_variant)
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
  local files = M.files(key, spec.variant)
  if files then
    after_files(files)
  else
    run(M.git(spec.repo, { "diff", "--name-only", range }), nil, function(code, out)
      if code ~= 0 then done_one() return end
      local list = vim.tbl_filter(function(f) return f ~= "" end, out)
      M.set_files(key, list, spec.variant)
      after_files(list)
    end)
  end

  if not spec.variant then
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
    if stale and spec.cmd then
      start()
      local threads_args = vim.list_extend({}, spec.cmd)
      threads_args[#threads_args + 1] = "--threads"
      run(threads_args, spec.env, function(code, out)
        if code == 0 then
          M.set_threads(spec.id, table.concat(out, "\n"), spec.totalThreads)
        end
        done_one()
      end)
    end
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
  local bucket = PR_DIFF_CACHE[key] or {}
  for _, f in ipairs(files) do
    if not bucket[f] then return false end
  end
  return M.commits(key) ~= nil
end

return M
