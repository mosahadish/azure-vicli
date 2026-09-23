-- test-prs.lua: lua/azure-cli/prs.lua's pure PR-record helpers.
-- Usage: luajit test-prs.lua <prs.lua path>
local path = arg[1]
assert(path, "usage: luajit test-prs.lua <prs.lua path>")
local P = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

check("surname: 'Surname, Given'", P.surname("Doe, Jane") == "Doe")
check("surname: last word", P.surname("Jane Doe") == "Doe")
check("surname: nil", P.surname(nil) == "")

local pr = { myName = "Mosa Hadish", myId = "me", reviewers = {
  { name = "Doe, Jane", id = "1", vote = 10 }, { name = "Mosa Hadish", id = "me", vote = 0 } },
  voteRatio = "1 / 2", reviewerSummary = "\u{2713}Doe \u{00B7}Hadish" }
check("my_vote_key: none yet", P.my_vote_key(pr) == nil)

local undo = P.apply_my_vote(pr, 5)
check("apply: my vote recorded", P.my_reviewer(pr).vote == 5)
check("apply: key", P.my_vote_key(pr) == "5")
check("apply: ratio", pr.voteRatio == "2 / 2", pr.voteRatio)
check("apply: summary", pr.reviewerSummary == "\u{2713}Doe \u{2713}Hadish", pr.reviewerSummary)
undo()
check("undo: vote back", P.my_reviewer(pr).vote == 0)
check("undo: ratio back", pr.voteRatio == "1 / 2")
check("undo: summary back", pr.reviewerSummary == "\u{2713}Doe \u{00B7}Hadish")

local pr2 = { myName = "New Person", reviewers = {} }
P.apply_my_vote(pr2, -10)
check("apply: adds me when absent", #pr2.reviewers == 1 and pr2.reviewerSummary == "\u{2717}Person")
check("apply: reject key", P.my_vote_key(pr2) == "-10")

-- iso_epoch: the provider's stamps are UTC, and os.time() reads its table
-- as local time, so this has to correct for the machine's offset. These
-- expectations are absolute epochs, so they only hold if it does - the
-- previous version was off by the offset (and by an hour more or less
-- across a DST boundary, which is why both a summer and a winter stamp are
-- pinned here).
check("iso_epoch: UTC summer stamp", P.iso_epoch("2026-09-23T12:00:00.0000000Z") == 1790164800,
  P.iso_epoch("2026-09-23T12:00:00.0000000Z"))
check("iso_epoch: UTC winter stamp", P.iso_epoch("2026-01-15T12:00:00.0000000Z") == 1768478400,
  P.iso_epoch("2026-01-15T12:00:00.0000000Z"))
check("iso_epoch: epoch itself", P.iso_epoch("1970-01-01T00:00:00Z") == 0, P.iso_epoch("1970-01-01T00:00:00Z"))
check("iso_epoch: unparseable is 0", P.iso_epoch("not a date") == 0)
check("iso_epoch: nil is 0", P.iso_epoch(nil) == 0)
-- Ordering is what the dashboard's section sort relies on.
check("iso_epoch: orders", P.iso_epoch("2026-09-23T12:00:01Z") > P.iso_epoch("2026-09-23T12:00:00Z"))

print(fails == 0 and "test-prs: all cases pass" or ("test-prs: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
