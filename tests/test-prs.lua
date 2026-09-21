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

print(fails == 0 and "test-prs: all cases pass" or ("test-prs: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
