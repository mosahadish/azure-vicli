-- lua/azure-cli/prs.lua: pure helpers over a PR record (one line of
-- `azure-cli.py --list`'s NDJSON, as the dashboard caches it): the short
-- author/reviewer label, my current vote, and the optimistic vote update
-- both the dashboard's gv and the reviewer's gv apply to the shared cached
-- record, so the Overview page and the winbar badges reflect a vote the
-- moment it's cast rather than on the next poll. No vim calls, so
-- tests/test-prs.lua runs it under plain luajit.
local M = {}

-- Short label: surname from "Surname, Given", else the last word.
function M.surname(name)
  name = name or ""
  local s = name:match("^([^,]+),")
  if s then return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
  return name:match("(%S+)%s*$") or name
end

-- My reviewer entry on `pr` (matched by display name), or nil.
function M.my_reviewer(pr)
  local me = pr.myName or ""
  if me == "" then return nil end
  for _, r in ipairs(pr.reviewers or {}) do
    if r.name == me then return r end
  end
  return nil
end

-- My current vote as the VOTE_OPTIONS key string ("10", "5", "-5", "-10"),
-- or nil when I haven't voted / am not a reviewer.
function M.my_vote_key(pr)
  local r = M.my_reviewer(pr)
  local v = r and tonumber(r.vote)
  if v and v ~= 0 then return tostring(v) end
  return nil
end

-- Glyph for a vote value, as the dashboard's reviewer summary draws it.
function M.vote_glyph(v)
  v = tonumber(v) or 0
  if v == 10 or v == 5 then return "\u{2713}" end
  if v == -10 then return "\u{2717}" end
  if v == -5 then return "~" end
  return "\u{00B7}"
end

-- Records `vote` (a number) as mine on `pr` and recomputes the derived
-- voteRatio / reviewerSummary the way azure-cli.py builds them. Returns an
-- undo function that restores the previous values (for a failed call).
function M.apply_my_vote(pr, vote)
  local snap = { voteRatio = pr.voteRatio, reviewerSummary = pr.reviewerSummary, reviewers = {} }
  for i, r in ipairs(pr.reviewers or {}) do
    snap.reviewers[i] = { name = r.name, id = r.id, vote = r.vote }
  end
  pr.reviewers = pr.reviewers or {}
  local mine = M.my_reviewer(pr)
  if not mine then
    mine = { name = pr.myName or "", id = pr.myId or "", vote = 0 }
    table.insert(pr.reviewers, mine)
  end
  mine.vote = vote
  local signed, parts = 0, {}
  for _, r in ipairs(pr.reviewers) do
    local v = tonumber(r.vote) or 0
    if v == 10 or v == 5 then signed = signed + 1 end
    parts[#parts + 1] = M.vote_glyph(v) .. M.surname(r.name)
  end
  pr.voteRatio = signed .. " / " .. #pr.reviewers
  pr.reviewerSummary = table.concat(parts, " ")
  return function()
    pr.voteRatio, pr.reviewerSummary, pr.reviewers = snap.voteRatio, snap.reviewerSummary, snap.reviewers
  end
end

return M
