-- lua/azure-cli/prs.lua: pure helpers over a PR record (one line of
-- `azure-cli.py --list`'s NDJSON, as the dashboard caches it): the short
-- author/reviewer label, my current vote, and the optimistic vote update
-- both the dashboard's gv and the reviewer's gv apply to the shared cached
-- record, so the Overview page and the winbar badges reflect a vote the
-- moment it's cast rather than on the next poll. No vim calls, so
-- tests/test-prs.lua runs it under plain luajit.
local M = {}
local HOSTS = require("azure-cli.hosts")

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

-- My current vote as its option key (Azure: "10", "5", "-5", "-10"), or
-- nil when I haven't voted / am not a reviewer.
function M.my_vote_key(pr)
  local r = M.my_reviewer(pr)
  local o = r and r.vote ~= nil and HOSTS.vote(pr, r.vote)
  if o and not o.reset then return o.key end
  return nil
end

-- Glyph for a vote value on `pr`'s host, as the dashboard's reviewer
-- summary draws it.
function M.vote_glyph(v, pr)
  return HOSTS.vote_glyph(pr, v)
end

-- Seconds to add to an os.time() result to correct for os.time() having
-- read its calendar table as LOCAL time. Measured at `epoch` itself rather
-- than once at load, so it stays right on both sides of a DST change.
local function utc_offset(epoch)
  local t = os.date("!*t", epoch)
  t.isdst = nil  -- let mktime decide DST for that date, don't force standard time
  return os.difftime(epoch, os.time(t))
end

-- A "o"-format ISO timestamp (yyyy-MM-ddTHH:mm:ss..., always UTC - see
-- iso_format() in azure-cli.py) as a real epoch, for sorting and age
-- checks. 0 when it doesn't parse, so a record missing the field sorts
-- last rather than erroring.
--
-- The UTC correction matters: os.time() interprets its table as local
-- time, so feeding it UTC fields returns an epoch shifted by the machine's
-- offset. Sorting never noticed (every value shifted alike), but the
-- dashboard compares the result against a real os.time() to decide whether
-- a PR is "aged", and that comparison was off by the offset.
function M.iso_epoch(iso)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return 0 end
  local guess = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
  return guess + utc_offset(guess)
end

-- Recomputes `pr`'s voteRatio / reviewerSummary from its reviewers, the
-- way azure-cli.py builds them - after a vote, or a reviewer added (gR).
function M.recompute(pr)
  local signed, parts = 0, {}
  for _, r in ipairs(pr.reviewers or {}) do
    local o = HOSTS.vote(pr, r.vote)
    if o and o.signed then signed = signed + 1 end
    parts[#parts + 1] = M.vote_glyph(r.vote, pr) .. M.surname(r.name)
  end
  pr.voteRatio = signed .. " / " .. #(pr.reviewers or {})
  pr.reviewerSummary = table.concat(parts, " ")
end

-- Records `vote` (an option key) as mine on `pr` and recomputes the derived
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
  M.recompute(pr)
  return function()
    pr.voteRatio, pr.reviewerSummary, pr.reviewers = snap.voteRatio, snap.reviewerSummary, snap.reviewers
  end
end

-- PRs completed from this session: `done` maps id (string) -> the os.time()
-- it was completed at (STATE.PR_COMPLETED). ADO completes a PR
-- asynchronously - for a few seconds after the PATCH (longer on a busy
-- on-prem server) the PR still lists as active while the merge runs, so the
-- refresh gm triggers put the row straight back on the dashboard.
-- drop_completed filters such ids out of a fresh --list until the server
-- stops returning them (which also forgets them), or COMPLETED_GRACE
-- seconds pass - a merge that failed server-side leaves the PR active, and
-- it should reappear rather than stay hidden for the session.
M.COMPLETED_GRACE = 300

function M.mark_completed(done, id, now)
  done[tostring(id)] = now
  return function() done[tostring(id)] = nil end
end

function M.drop_completed(done, list, now)
  local listed, kept = {}, {}
  for _, p in ipairs(list) do
    local id = tostring(HOSTS.key(p))
    local at = done[id]
    if at then listed[id] = true end
    if not (at and now - at < M.COMPLETED_GRACE) then kept[#kept + 1] = p end
  end
  for id, at in pairs(done) do
    if not listed[id] or now - at >= M.COMPLETED_GRACE then done[id] = nil end
  end
  return kept
end

-- The accounts a --list that still exited 0 couldn't list, in order and
-- once each: azure-cli.py prints "azure-cli --list failed for <account>:
-- <message>" on stderr for every one (#95), keeping the others' records.
M.LIST_PARTIAL_PREFIX = "azure-cli --list failed for "

function M.failed_accounts(lines)
  local names, seen = {}, {}
  for _, line in ipairs(lines or {}) do
    if line:sub(1, #M.LIST_PARTIAL_PREFIX) == M.LIST_PARTIAL_PREFIX then
      local name = line:sub(#M.LIST_PARTIAL_PREFIX + 1):match("^(.-): ")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  return names
end

-- Whether a --list that failed for `names` should warn, given `prev` (the
-- key it last returned; "" at first): only when the set of failed accounts
-- changed, so an account that keeps failing doesn't warn on every poll. A
-- clean list resets the key, so failing again after a recovery warns again.
-- Returns (warn, key).
function M.failed_accounts_changed(prev, names)
  local sorted = {}
  for i, n in ipairs(names or {}) do sorted[i] = n end
  table.sort(sorted)
  local key = table.concat(sorted, "\n")
  return key ~= "" and key ~= (prev or ""), key
end

return M
