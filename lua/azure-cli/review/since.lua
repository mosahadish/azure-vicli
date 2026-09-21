-- lua/azure-cli/review/since.lua: "changes since my last review" (gi) - a
-- reviewer-feature module built on pr-review.lua's EXT extension mechanism
-- (see the comment at EXT's declaration there, and README's "Extending the
-- reviewer", for why this lives in its own require()'d module instead of new
-- code in pr-review.lua itself: that file is at LuaJIT's 200-local ceiling
-- for its main chunk).
--
-- Wired in by pr-review.lua's closing `do...end` block as
-- EXT.since_mod = require(this file)(ctx) - deliberately NOT `EXT.since`,
-- even though every other module follows that `EXT.<name>` convention:
-- `EXT.since` is the STATE this module drives (nil when the mode is off,
-- else `{ range, variant, short, base, new_iterations, at }` - see
-- toggle_since below), read directly (not through ctx) by every place in
-- pr-review.lua that already reads RANGE/ignore_ws - build_diff_async,
-- load_files, prefetch_all_diffs, decorate_comments, the three winbar
-- builders, build_overview and EXT.rebuild_view itself - because those all
-- live in pr-review.lua's own chunk, where EXT is a plain upvalue. This
-- module runs as a separate chunk (dofile), so it never touches EXT.since
-- directly; it goes through ctx.since()/ctx.set_since() instead, which
-- pr-review.lua's ctx construction wires straight to the EXT.since field.
--
-- Like review/range.lua/review/comments.lua/
-- review/commits.lua/review/batch.lua, this file's `return` is
-- a table with a __call metamethod: `require(path)` alone leaves the pure
-- helpers below reachable without a real `ctx` (what
-- tests/test-review-since.lua does), and `require(path)(ctx)` additionally
-- wires everything into the reviewer.
--
-- What "my last review point" means: the latest publishedDate of any
-- comment I authored on this PR, INCLUDING system comments - a vote (gv)
-- produces a system-type thread whose one comment is authored by the voter,
-- so casting a vote counts as "reviewing" even without leaving a line
-- comment. pr-review.lua's own parse_threads drops system comments (they're
-- not real review feedback to render inline), so this module re-fetches the
-- raw --threads JSON itself via run_script below rather than reading
-- ctx.threads()'s already-filtered tables.
--
-- How the base commit is picked: fetch this PR's iterations (--iterations;
-- each push/force-push is one, with an id, a createdDate and a
-- sourceRefCommit.commitId) and take the latest one created at or before my
-- last review point - that iteration's source commit is where I left off.
-- Iterations created after it are "new" (new_iterations). If every
-- iteration is at or after my last review point (I've never actually seen
-- any of this PR's pushes), there's nothing meaningful to diff against - the
-- normal full-PR view already shows exactly that, so the mode declines to
-- turn on and says so. The chosen base commit is then verified to actually
-- exist in this local clone (git cat-file -e) - a force-push that rewrote
-- history, or a shallow fetch, can leave it unreachable - falling back to
-- the normal view with a notification rather than handing git a range it
-- can't resolve.
--
-- Once a base is chosen, EXT.since.range is the two-dot
-- "<base>..origin/<source>" (everything reachable from the source branch
-- tip but not from the base commit) - unlike RANGE itself (three-dot,
-- merge-base diff), this is a plain range: base is a specific commit on the
-- PR's own history, not a branch to diff against. EXT.since.variant
-- ("since:<short-sha>") names the cache.lua files/diffs bucket that
-- range's results are cached under (see cache.lua's M.diffs/M.files),
-- kept warm alongside the PR's normal (and ignore-whitespace) buckets rather
-- than replacing them.
--
-- decorate_comments (pr-review.lua) skips "L"-side (left/target-branch)
-- threads while the mode is on: an "L" thread's line number is relative to
-- the target branch's copy of the file, which has nothing to do with the
-- base commit this mode diffs from, so mapping it onto the since-range's
-- diff would be meaningless (and, at the wrong line, actively misleading).
-- "R"-side (right/source-branch) threads are unaffected: the source branch
-- tip is still exactly what the since-range diffs against.
--
-- Keys (list/diff/overview - see ctx.add_key's kinds): gi toggles the mode.

local M = {}

-- ---------------------------------------------------------------------------
-- Pure helpers - no vim/ctx, so tests/test-review-since.lua exercises them
-- directly under plain luajit, the same way the other review/*.lua
-- modules' pure helpers are tested.

-- Gregorian civil-date <-> days-since-1970-01-01 conversions (Howard
-- Hinnant's well-known days_from_civil/civil_from_days algorithms - see
-- http://howardhinnant.github.io/date_algorithms.html), used by
-- M.normalize_iso below to fold a numeric UTC offset into the date/time by
-- hand: this module stays dependency-free (no os.date/os.time, which read
-- the local system clock/timezone rather than doing pure arithmetic on the
-- string), so a "-05:00"-style offset crossing a day/month/year boundary
-- still normalises correctly.
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era
  if y >= 0 then era = math.floor(y / 400) else era = math.floor((y - 399) / 400) end
  local yoe = y - era * 400
  local shifted = m + (m > 2 and -3 or 9)
  local doy = math.floor((153 * shifted + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end
local function civil_from_days(z)
  z = z + 719468
  local era
  if z >= 0 then era = math.floor(z / 146097) else era = math.floor((z - 146096) / 146097) end
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  if m <= 2 then y = y + 1 end
  return y, m, d
end

-- Normalises an ISO-8601 timestamp ("2024-01-15T10:30:00.123Z" or with a
-- numeric "+HH:MM"/"-HH:MM" offset instead of "Z") to a fixed-width, UTC,
-- "Z"-suffixed canonical form with exactly 7 fractional digits - so two
-- normalised timestamps compare correctly with a plain string "<"/">"/"<="
-- regardless of the input's original precision or offset. Returns nil for
-- anything that doesn't parse.
function M.normalize_iso(ts)
  if type(ts) ~= "string" then return nil end
  local y, mo, d, h, mi, s, frac, tz =
    ts:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(%.?%d*)([Z%+%-].*)$")
  if not y then return nil end
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)

  local offset_min = 0
  if tz ~= "Z" then
    local sign, oh, om = tz:match("^([%+%-])(%d%d):?(%d%d)$")
    if not sign then return nil end
    offset_min = (tonumber(oh) * 60 + tonumber(om)) * (sign == "-" and -1 or 1)
  end

  if offset_min ~= 0 then
    -- UTC = local - offset. Fold any minute/day/month/year carry through
    -- the civil-date conversions above rather than adjusting h/mi in place.
    local total_min = days_from_civil(y, mo, d) * 1440 + h * 60 + mi - offset_min
    local day = math.floor(total_min / 1440)
    local min_of_day = total_min - day * 1440
    h = math.floor(min_of_day / 60)
    mi = min_of_day - h * 60
    y, mo, d = civil_from_days(day)
  end

  local frac_digits = frac:gsub("^%.", "")
  if #frac_digits < 7 then frac_digits = frac_digits .. string.rep("0", 7 - #frac_digits) end
  frac_digits = frac_digits:sub(1, 7)

  return string.format("%04d-%02d-%02dT%02d:%02d:%02d.%sZ", y, mo, d, h, mi, s, frac_digits)
end

-- The latest (raw, un-normalised) publishedDate of any comment authored by
-- `my_id` across every thread in `threads` (the decoded --threads JSON's
-- "value" array, or equivalent) - every comment, including system ones (a
-- vote), unlike pr-review.lua's own parse_threads which drops system
-- comments entirely. Returns nil when I have no comments on this PR at all.
function M.last_review_point(threads, my_id)
  if not my_id then return nil end
  local latest, latest_norm
  for _, t in ipairs(threads or {}) do
    for _, c in ipairs(t.comments or {}) do
      local author = c.author
      if author and author.id == my_id and type(c.publishedDate) == "string" then
        local norm = M.normalize_iso(c.publishedDate)
        if norm and (not latest_norm or norm > latest_norm) then
          latest, latest_norm = c.publishedDate, norm
        end
      end
    end
  end
  return latest
end

-- Picks the iteration to diff from: the latest one (by createdDate) created
-- at or before `review_point` (a raw ISO timestamp, e.g. from
-- M.last_review_point). Returns the chosen iteration table (with at least
-- .sourceRefCommit.commitId) plus how many iterations were created after it
-- ("new_iterations"); returns nil (plus the total iteration count) when
-- every iteration is after review_point - meaning there's no earlier point
-- to diff from, i.e. the whole PR is "new" - or when review_point itself is
-- nil/unparseable.
function M.pick_base(iterations, review_point)
  iterations = iterations or {}
  local rp = M.normalize_iso(review_point)
  if not rp then return nil, #iterations end
  local best, best_norm
  for _, it in ipairs(iterations) do
    local norm = M.normalize_iso(it.createdDate)
    if norm and norm <= rp and (not best_norm or norm > best_norm) then
      best, best_norm = it, norm
    end
  end
  if not best then return nil, #iterations end
  local new_count = 0
  for _, it in ipairs(iterations) do
    local norm = M.normalize_iso(it.createdDate)
    if norm and norm > best_norm then new_count = new_count + 1 end
  end
  return best, new_count
end

-- The cache.lua files/diffs bucket suffix for a since-range based on
-- `base_commit`'s short sha - see cache.lua's M.diffs/M.files.
function M.variant(short_sha)
  return "since:" .. short_sha
end

-- The plain (no ignore-whitespace) diffs/files variant combined with the gw
-- ignore-whitespace flag - the same composition pr-review.lua's
-- EXT.rebuild_view inlines wherever it needs the live CACHE.diffs bucket for
-- the current mode (since or not, ignore-whitespace or not). Exposed here,
-- pure and tested, purely as documentation of that composition - pr-review.lua
-- doesn't call it directly (a nested chunk boundary would make that an extra
-- ctx round trip for a one-line expression); it stays a tiny inline
-- expression there instead (see README's "Extending the reviewer").
function M.diff_variant(state, ignore_ws)
  if not state then return ignore_ws end
  return state.variant .. (ignore_ws and ":iws" or "")
end

-- The two-dot git range a since-mode state diffs: everything reachable from
-- the source branch tip that isn't reachable from `base_commit`.
function M.range(base_commit, source)
  return base_commit .. "..origin/" .. source
end

-- ---------------------------------------------------------------------------
-- ctx wiring.

local function setup(ctx)
  -- Runs `ctx.provider(args)` (the python data provider's argv - see
  -- pr-review.lua's EXT.provider) in the background, calling cb(ok,
  -- body_or_err): stdout joined with "\n" on success (ok=true), a failure
  -- detail (stderr, or "exit N") otherwise - the same job shape
  -- pr-review.lua's own refresh_threads runs `EXT.provider({"--threads"})`
  -- with, generalised for the --iterations subcommand this module also needs
  -- and for the raw (unfiltered-by-parse_threads) --threads fetch
  -- M.last_review_point needs.
  local function run_script(args, cb)
    local cmd = ctx.provider(args)
    local out, err = {}, {}
    ctx.rpc.run(cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
      on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
      on_exit = function(_, code)
        if code ~= 0 then
          local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
          cb(false, "exit " .. code .. (msg ~= "" and (": " .. msg) or ""))
          return
        end
        cb(true, table.concat(out, "\n"))
      end,
    })
  end

  -- Decodes a --threads/--iterations JSON payload's "value" array (or the
  -- payload itself, if it wasn't wrapped that way) - the same tolerant shape
  -- pr-review.lua's own parse_threads reads.
  local function decode_list(json)
    if not json or json:gsub("%s", "") == "" then return {} end
    local ok, decoded = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
    if not ok or type(decoded) ~= "table" then return {} end
    local list = decoded.value or decoded
    if type(list) ~= "table" then return {} end
    return list
  end

  -- Verifies `sha` is a commit this clone actually has - a force-push that
  -- rewrote history, or a shallow fetch, can leave an old iteration's base
  -- unreachable - calling cb(true) or cb(false).
  local function commit_exists(sha, cb)
    vim.fn.jobstart(ctx.git_args("cat-file", "-e", sha .. "^{commit}"), {
      on_exit = function(_, code) cb(code == 0) end,
    })
  end

  -- Finds the base commit "my last review" should diff from - shared by gi
  -- (toggle_since, below) and review/followup.lua's "follow up on my
  -- comments" (gu), which needs exactly the same base (it diffs each
  -- thread's file against it to see whether anything landed nearby since).
  -- Runs the same --threads/--iterations requests and local
  -- `git cat-file -e` check toggle_since always ran inline: on success calls
  -- `cb(base_sha, new_iterations, review_point)` (review_point is the raw
  -- ISO timestamp M.last_review_point resolved, handed back so a caller like
  -- followup.lua can show it without re-fetching); on any of the ways this
  -- can come up empty, calls `cb(nil, reason, level)` instead - `reason` a
  -- complete, capitalised, already-punctuated sentence ready to hand
  -- straight to ctx.notify, `level` the vim.log.levels value to notify it at
  -- (nil for the "nothing to diff, but not an error" case, matching
  -- ctx.notify's own default-to-INFO when no level is given).
  function M.fetch_base(cb)
    local my_id = ctx.my_id()
    if not my_id then
      cb(nil, "Your identity hasn't resolved yet; try again in a moment.", vim.log.levels.WARN)
      return
    end

    run_script({ "--threads" }, function(ok, body)
      if not ok then
        cb(nil, "Could not load your review history (" .. body .. ").", vim.log.levels.ERROR)
        return
      end
      local review_point = M.last_review_point(decode_list(body), my_id)
      if not review_point then
        cb(nil, "You haven't commented on this PR yet, so there's no \"last review\" to compare since.",
          vim.log.levels.WARN)
        return
      end

      run_script({ "--iterations" }, function(ok2, body2)
        if not ok2 then
          cb(nil, "Could not load this PR's iterations (" .. body2 .. ").", vim.log.levels.ERROR)
          return
        end
        local base_it, new_count = M.pick_base(decode_list(body2), review_point)
        if not base_it then
          cb(nil, "Everything in this PR is new since your last review.")
          return
        end
        local sha = base_it.sourceRefCommit and base_it.sourceRefCommit.commitId
        if not sha or sha == "" then
          cb(nil, "Couldn't resolve a base commit for your last review.", vim.log.levels.ERROR)
          return
        end
        commit_exists(sha, function(exists)
          if not exists then
            cb(nil, "Base commit " .. sha:sub(1, 7)
              .. " isn't available locally (force-push or shallow fetch).", vim.log.levels.WARN)
            return
          end
          cb(sha, new_count, review_point)
        end)
      end)
    end)
  end

  -- Guards against a second gi press racing an in-flight lookup.
  local finding = false

  -- gi: turn the mode on (compute the base, async) or off (clear it),
  -- either way rebuilding the file list/diffs/decorations for it - see
  -- EXT.rebuild_view (pr-review.lua) via ctx.rebuild_view.
  local function toggle_since()
    if ctx.since() then
      ctx.set_since(nil)
      ctx.notify("Changes since last review: off.")
      ctx.rebuild_view(true)
      return
    end
    if finding then
      ctx.notify("Still finding your last review\u{2026}", vim.log.levels.WARN)
      return
    end

    finding = true
    ctx.notify("Finding your last review\u{2026}")
    M.fetch_base(function(base_sha, a, b)
      finding = false
      if not base_sha then
        -- Failure shape: cb(nil, reason, level) - see M.fetch_base's own
        -- comment. reason is already a complete, ready-to-show sentence
        -- (gi simply doesn't turn on; the current view - full diff or
        -- whatever was already showing - is left exactly as it was).
        ctx.notify(a, b)
        return
      end
      -- Success shape: cb(base_sha, new_iterations, review_point).
      local new_count, review_point = a, b
      local short = base_sha:sub(1, 7)
      ctx.set_since({
        range = M.range(base_sha, ctx.SOURCE),
        variant = M.variant(short),
        short = short,
        base = base_sha,
        new_iterations = new_count,
        at = review_point,
      })
      ctx.notify("Showing changes since your last review: " .. new_count
        .. " new iteration" .. (new_count == 1 and "" or "s") .. ".")
      ctx.rebuild_view(true)
    end)
  end

  for _, kind in ipairs({ "list", "diff", "overview" }) do
    ctx.add_key(kind, "since", toggle_since,
      "toggle changes-since-my-last-review (hides comments on the old target-side lines)")
  end

  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
