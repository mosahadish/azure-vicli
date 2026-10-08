-- test-review-since.lua: unit tests for review/since.lua's pure
-- helpers - the ones that never touch vim/ctx, so they run directly under
-- plain luajit: M.normalize_iso (timestamp normalisation, including a
-- numeric UTC-offset fold across a day/month/year boundary), M.last_review_point
-- (picking my latest comment - including a system/vote one - out of a
-- synthetic thread list), M.pick_base (picking the iteration to diff from
-- out of a synthetic iterations list, including "no comments"/"all
-- iterations newer than my last review"), and the variant/range string
-- composition (M.variant/M.diff_variant/M.range).
--
-- Usage: luajit test-review-since.lua <review/since.lua path>

local path = arg[1]
assert(path, "usage: luajit test-review-since.lua <review/since.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- M.normalize_iso ---------------------------------------------------------

check("normalize_iso: already-Z pads fraction to 7 digits",
  M.normalize_iso("2024-01-15T10:30:00Z") == "2024-01-15T10:30:00.0000000Z")

check("normalize_iso: existing fraction padded",
  M.normalize_iso("2024-01-15T10:30:00.5Z") == "2024-01-15T10:30:00.5000000Z")

check("normalize_iso: over-long fraction truncated to 7 digits",
  M.normalize_iso("2024-01-15T10:30:00.1234567890Z") == "2024-01-15T10:30:00.1234567Z")

check("normalize_iso: positive offset folds hours back into UTC",
  M.normalize_iso("2024-01-15T10:30:00+02:00") == "2024-01-15T08:30:00.0000000Z")

check("normalize_iso: negative offset folds hours forward into UTC",
  M.normalize_iso("2024-01-15T10:30:00-05:00") == "2024-01-15T15:30:00.0000000Z")

check("normalize_iso: offset conversion rolls back across a day/month/year boundary",
  M.normalize_iso("2024-01-01T00:30:00+02:00") == "2023-12-31T22:30:00.0000000Z")

check("normalize_iso: unparseable input returns nil",
  M.normalize_iso("not a timestamp") == nil)

check("normalize_iso: non-string input returns nil",
  M.normalize_iso(nil) == nil)

do
  -- Two timestamps that represent the same instant via different original
  -- forms (Z with a fraction vs. an equivalent numeric offset) normalise to
  -- the same canonical string, and a later Z timestamp always compares
  -- greater once normalised - this is what M.pick_base's <=/> comparisons
  -- below actually rely on.
  local a = M.normalize_iso("2024-01-15T10:30:00Z")
  local b = M.normalize_iso("2024-01-15T10:30:00.5Z")
  check("normalize_iso: a whole second sorts before a fraction past it", a < b)

  local c = M.normalize_iso("2024-01-15T12:30:00+02:00")  -- == 10:30:00Z
  check("normalize_iso: an equivalent offset normalises identically", a == c)
end

-- --- M.last_review_point -----------------------------------------------------

do
  -- A thread with only someone else's comment, and a thread with one of
  -- mine (a later, plain comment) plus a vote (a system comment, still
  -- authored by me, dated earlier here so the plain comment wins).
  local threads = {
    { comments = {
        { author = { id = "other" }, publishedDate = "2024-01-05T00:00:00Z", commentType = "text" },
      } },
    { comments = {
        { author = { id = "me" }, publishedDate = "2024-01-03T00:00:00Z", commentType = "system" },
        { author = { id = "me" }, publishedDate = "2024-01-04T00:00:00Z", commentType = "text" },
      } },
  }
  check("last_review_point: latest of my own comments (across threads)",
    M.last_review_point(threads, "me") == "2024-01-04T00:00:00Z")
end

do
  -- A vote is the ONLY comment I have on this PR - a system comment still
  -- counts, since parse_threads' usual "drop system comments" rule doesn't
  -- apply here (see the module's header comment on why).
  local threads = {
    { comments = { { author = { id = "me" }, publishedDate = "2024-02-01T00:00:00Z", commentType = "system" } } },
  }
  check("last_review_point: a vote (system comment) alone still counts",
    M.last_review_point(threads, "me") == "2024-02-01T00:00:00Z")
end

check("last_review_point: no comments at all returns nil",
  M.last_review_point({}, "me") == nil)

check("last_review_point: only other people's comments returns nil",
  M.last_review_point({ { comments = { { author = { id = "other" }, publishedDate = "2024-01-01T00:00:00Z" } } } }, "me") == nil)

check("last_review_point: nil my_id returns nil",
  M.last_review_point({ { comments = { { author = { id = "me" }, publishedDate = "2024-01-01T00:00:00Z" } } } }, nil) == nil)

-- --- M.pick_base --------------------------------------------------------------

local ITERATIONS = {
  { id = 1, createdDate = "2024-01-01T00:00:00Z", sourceRefCommit = { commitId = "sha1" } },
  { id = 2, createdDate = "2024-01-02T00:00:00Z", sourceRefCommit = { commitId = "sha2" } },
  { id = 3, createdDate = "2024-01-10T00:00:00Z", sourceRefCommit = { commitId = "sha3" } },
}

do
  local base, new_count = M.pick_base(ITERATIONS, "2024-01-03T00:00:00Z")
  check("pick_base: picks the latest iteration at or before the review point",
    base and base.sourceRefCommit.commitId == "sha2")
  check("pick_base: counts iterations after the chosen base", new_count == 1)
end

do
  -- Exactly-equal timestamps: an iteration created AT my review point counts
  -- as "at or before" and is picked as the base (0 new iterations).
  local base, new_count = M.pick_base(ITERATIONS, "2024-01-02T00:00:00Z")
  check("pick_base: an iteration created exactly at the review point is the base",
    base and base.sourceRefCommit.commitId == "sha2")
  check("pick_base: no new iterations when the base is the latest one at the point", new_count == 1)
end

do
  -- Every iteration is after my last review - nothing to diff from, so the
  -- mode should decline (nil base) - the caller falls back to the normal
  -- full-PR view rather than turning the mode on.
  local base, new_count = M.pick_base(ITERATIONS, "2023-12-01T00:00:00Z")
  check("pick_base: all iterations newer than the review point -> no base", base == nil)
  check("pick_base: all iterations newer -> every one counted as new", new_count == #ITERATIONS)
end

do
  local base, new_count = M.pick_base({}, "2024-01-01T00:00:00Z")
  check("pick_base: no iterations at all -> no base", base == nil)
  check("pick_base: no iterations at all -> zero count", new_count == 0)
end

do
  local base, new_count = M.pick_base(ITERATIONS, nil)
  check("pick_base: nil review point -> no base", base == nil)
  check("pick_base: nil review point -> counts every iteration", new_count == #ITERATIONS)
end

-- --- variant / range composition ----------------------------------------------

check("variant: since:<short-sha>", M.variant("abc1234") == "since:abc1234")

check("diff_variant: no since-state falls back to the plain ignore_ws boolean",
  M.diff_variant(nil, true) == true)
check("diff_variant: no since-state, no ignore_ws",
  M.diff_variant(nil, false) == false)

do
  local state = { variant = "since:abc1234" }
  check("diff_variant: since-state alone (no ignore-whitespace suffix)",
    M.diff_variant(state, false) == "since:abc1234")
  check("diff_variant: since-state combined with ignore-whitespace",
    M.diff_variant(state, true) == "since:abc1234:iws")
end

check("range: two-dot base..origin/source",
  M.range("abc1234fullsha", "feature-x") == "abc1234fullsha..origin/feature-x")

print(fails == 0 and "test-review-since: all cases pass" or ("test-review-since: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
