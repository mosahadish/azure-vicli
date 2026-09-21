-- test-review-commits.lua: unit tests for review/commits.lua's pure
-- helpers - the ones that never touch vim/ctx, so they run directly under
-- plain luajit: M.parse_commit/M.commit_line_sha (an Overview commit row's
-- shape, and pulling a sha out of one), M.overview_commit_at (finding the
-- commit under the cursor within the Overview's own rendered lines, scoped
-- to its "Commits (who pushed):" block), M.parse_name_status (`git show
-- --name-status` output, including a rename/copy line), and M.is_root_commit
-- (`git rev-list --parents -n1 <sha>` output -> has a parent or not).
--
-- Usage: luajit test-review-commits.lua <review/commits.lua path>

local path = arg[1]
assert(path, "usage: luajit test-review-commits.lua <review/commits.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- parse_commit / commit_line_sha -----------------------------------------

do
  local c = M.parse_commit("a1b2c3d  2024-01-15  John Doe: Fix the thing")
  check("parse_commit sha", c and c.sha == "a1b2c3d")
  check("parse_commit date", c and c.date == "2024-01-15")
  check("parse_commit author", c and c.author == "John Doe")
  check("parse_commit subject", c and c.subject == "Fix the thing")
end

do
  -- A subject containing its own ": " shouldn't confuse the non-greedy
  -- author/subject split - the FIRST ": " is always the author/subject
  -- boundary, matching how `git log --format="%an: %s"` never repeats it
  -- before the subject.
  local c = M.parse_commit("deadbee  2024-02-01  Jane Roe: refactor: tidy up")
  check("parse_commit subject keeps its own colon", c and c.subject == "refactor: tidy up")
end

check("parse_commit rejects a non-commit line", M.parse_commit("just some text") == nil)
check("parse_commit rejects empty", M.parse_commit("") == nil)
check("parse_commit rejects nil", M.parse_commit(nil) == nil)

check("commit_line_sha matches a rendered Overview row",
  M.commit_line_sha("  a1b2c3d  2024-01-15  John Doe: Fix the thing") == "a1b2c3d")
check("commit_line_sha rejects without the 2-space prefix",
  M.commit_line_sha("a1b2c3d  2024-01-15  John Doe: Fix the thing") == nil)
check("commit_line_sha rejects a description line",
  M.commit_line_sha("  Fixes the flaky test by waiting for the job.") == nil)
check("commit_line_sha rejects a comment content line",
  M.commit_line_sha("\226\148\130   looks good to me") == nil)
check("commit_line_sha rejects nil", M.commit_line_sha(nil) == nil)

-- --- overview_commit_at -----------------------------------------------------

do
  -- Mirrors build_overview's own layout: title/meta/description, then the
  -- "Commits (who pushed):" block, then a blank line and the Comments block -
  -- a description line here deliberately starts with two spaces too, to
  -- prove the block-boundary scoping (not just the line's own shape) is
  -- what keeps it from being mistaken for a commit row.
  local lines = {
    "PR #42  Add widgets",
    "master -> feature/widgets",
    "Author: Jane Roe",
    "",
    "Description:",
    "  ab12345 is not a commit here, just descriptive text",
    "",
    "Commits (who pushed):",
    "  a1b2c3d  2024-01-15  John Doe: Fix the thing",
    "  e4f5678  2024-01-16  Jane Roe: Add the other thing",
    "",
    "Comments (0):",
    "  (none — press c to add one)",
  }
  check("commit at first commit row", M.overview_commit_at(lines, 9) == "a1b2c3d")
  check("commit at second commit row", M.overview_commit_at(lines, 10) == "e4f5678")
  check("nil on the header row", M.overview_commit_at(lines, 8) == nil)
  check("nil on the blank line after the block", M.overview_commit_at(lines, 11) == nil)
  check("nil on the description look-alike (outside the block)", M.overview_commit_at(lines, 6) == nil)
  check("nil past the end of the lines", M.overview_commit_at(lines, 99) == nil)
end

do
  local lines = { "loading placeholder", "Commits (who pushed):", "  (loading\u{2026})", "" }
  check("nil on the loading placeholder", M.overview_commit_at(lines, 3) == nil)
end

check("overview_commit_at with no Commits block returns nil",
  M.overview_commit_at({ "just", "some", "lines" }, 2) == nil)

-- --- parse_name_status -------------------------------------------------------

do
  local out = M.parse_name_status({
    "M\tREADME.md",
    "A\treview/commits.lua",
    "D\told-file.lua",
    "R100\told/path.lua\tnew/path.lua",
    "",
  })
  check("4 entries parsed (blank line skipped)", #out == 4)
  check("modify", out[1].status == "M" and out[1].path == "README.md")
  check("add", out[2].status == "A" and out[2].path == "review/commits.lua")
  check("delete", out[3].status == "D" and out[3].path == "old-file.lua")
  check("rename keeps destination path", out[4].status == "R" and out[4].path == "new/path.lua")
end

check("parse_name_status of nil is empty", #M.parse_name_status(nil) == 0)
check("parse_name_status of {} is empty", #M.parse_name_status({}) == 0)

-- --- is_root_commit -----------------------------------------------------------

check("root commit (own sha only)", M.is_root_commit("b5b99893670977a10c0737d9bc103bd0534a0362") == true)
check("normal commit (one parent)",
  M.is_root_commit("6e742eeab470bf44501606d4895a4bf1873eb0e5 ee7874ba2abf2c877ea1178a6e89e5ea957a9e93") == false)
check("merge commit (two parents)",
  M.is_root_commit("eee09440422aeecc8df277a64c97148c6e76be9c c8343637c06934d5a89af8bba61560698890d628 6e742eeab470bf44501606d4895a4bf1873eb0e5") == false)
check("empty/failed rev-list treated as root (falls back to `git show`)", M.is_root_commit("") == true)
check("nil treated as root", M.is_root_commit(nil) == true)

print(fails == 0 and "test-review-commits: all cases pass" or ("test-review-commits: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
