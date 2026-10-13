-- lua/azure-cli/hosts.lua: what each code host can do, so the screens ask
-- here instead of hard-coding Azure DevOps' vocabulary. A PR record from
-- `azure-cli.py --list` carries `host` ("azure" when absent) and may carry
-- `caps`, overrides the provider knows per repo (which merge methods it
-- allows, say); M.caps(pr) is the host's table with those laid over it.
--
-- Also the PR's key - the one value every per-PR cache, queue and chat
-- conversation is keyed by. On Azure it's the PR id itself (ids are unique
-- in a project, and keeping the number keeps every key already saved
-- valid); other hosts send an opaque `key`, since their numbers are only
-- unique within one repository. No vim calls: tests run it under luajit.
local M = {}

local AZURE = {
  host = "azure",
  -- Votes in menu order. `key` is what `--vote` takes and what a reviewer
  -- entry's `vote` holds; `signed` counts towards the "n / m" ratio;
  -- `glyph` is the dashboard's reviewer-summary mark (`detail` the
  -- description float's, where approve-with-suggestions reads differently).
  votes = {
    { key = "10",  name = "approve", label = "Approve", signed = true, glyph = "\u{2713}" },
    { key = "5",   name = "approve_with_suggestions", label = "Approve with suggestions", signed = true,
      glyph = "\u{2713}", detail = "\u{2713}~" },
    { key = "-5",  name = "wait", label = "Wait for author", glyph = "~" },
    { key = "-10", name = "reject", label = "Reject", glyph = "\u{2717}", confirm = true },
    { key = "0",   name = "reset", label = "Reset (no vote)", reset = true },
  },
  -- Comment-thread statuses `s` can set, in menu order. Every host reports
  -- its threads in these words (a GitHub conversation is "active" or
  -- "fixed"), so M.is_open needs no host.
  thread_statuses = {
    { key = "active",   label = "Active" },
    { key = "fixed",    label = "Resolved (fixed)" },
    { key = "wontfix",  label = "Won't fix" },
    { key = "closed",   label = "Closed" },
    { key = "bydesign", label = "By design" },
    { key = "pending",  label = "Pending" },
  },
  merge_methods = {
    { key = "squash",        label = "Squash commit" },
    { key = "noFastForward", label = "Merge (no fast forward)" },
    { key = "rebase",        label = "Rebase and fast-forward" },
    { key = "rebaseMerge",   label = "Semi-linear merge" },
  },
  complete_work_items = true,
  auto_complete = true,
  -- "@<guid>": Azure DevOps only notifies for a mention by GUID.
  mention = function(id) return "@<" .. id .. ">" end,
  sigil = "!",
}

-- GitHub (github_host.py): votes keep Azure's numbers as the currency
-- between provider and screens - an approval is 10, changes requested -5
-- (a review GitHub waits on the author for), 0 none - so everything that
-- counts or sorts by vote works unchanged; only the choices differ.
local GITHUB = {
  host = "github",
  votes = {
    { key = "10", name = "approve", label = "Approve", signed = true, glyph = "\u{2713}" },
    -- `reason`: GitHub wants a few words with it - the menus ask, and the
    -- text goes to --vote after the key.
    { key = "-5", name = "request_changes", label = "Request changes", glyph = "\u{2717}", reason = true },
    { key = "0",  name = "reset", label = "Dismiss my review", reset = true },
  },
  -- A conversation is resolved or not; the provider reports them as
  -- "active" and "fixed".
  thread_statuses = {
    { key = "active", label = "Unresolved" },
    { key = "fixed",  label = "Resolved" },
  },
  -- The repository's own allowed set comes in the record's caps.
  merge_methods = {
    { key = "squash", label = "Squash and merge" },
    { key = "merge",  label = "Create a merge commit" },
    { key = "rebase", label = "Rebase and merge" },
  },
  complete_work_items = false,
  auto_complete = true,
  mention = function(login) return "@" .. login end,
  sigil = "#",
  -- "repo#12": a number alone is ambiguous across repositories.
  ref = function(pr) return (pr.repo and pr.repo ~= "" and pr.repo or "") .. "#" .. tostring(pr.id) end,
}

M.HOSTS = { azure = AZURE, github = GITHUB }

local function host_of(pr)
  local h = type(pr) == "table" and pr.host or nil
  return (h and M.HOSTS[h]) and h or "azure"
end

function M.host(pr) return host_of(pr) end

-- The PR's capabilities: its host's table with the record's own `caps`
-- (provider-supplied, per repo) laid over it.
function M.caps(pr)
  local base = M.HOSTS[host_of(pr)]
  local over = type(pr) == "table" and type(pr.caps) == "table" and pr.caps or nil
  if not over then return base end
  local c = {}
  for k, v in pairs(base) do c[k] = v end
  for k, v in pairs(over) do c[k] = v end
  return c
end

-- The key every per-PR table uses: the record's `key`, else its id.
function M.key(pr)
  if type(pr) ~= "table" then return pr end
  if pr.key ~= nil then return pr.key end
  return pr.id
end

-- How a PR is named in text: "!101" on Azure, "repo#12" on GitHub.
function M.ref(pr)
  local c = M.caps(pr)
  if c.ref and type(pr) == "table" then return c.ref(pr) end
  local id = type(pr) == "table" and pr.id or pr
  return (c.sigil or "!") .. tostring(id)
end

-- The vote option whose key is `v` (a number or string), or nil.
function M.vote(pr, v)
  local k = tostring(v)
  for _, o in ipairs(M.caps(pr).votes) do
    if o.key == k then return o end
  end
  return nil
end

-- A vote's mark: "✓", "~", "✗", or "·" for none. `detail` picks the
-- description float's variant.
function M.vote_glyph(pr, v, detail)
  local o = M.vote(pr, v)
  if not o or o.reset then return "\u{00B7}" end
  return (detail and o.detail) or o.glyph or "\u{00B7}"
end

-- Whether a thread status counts as unresolved: "active" or "pending", or
-- none yet (a thread we just made, before the server answers). Everything
-- else - fixed, wontFix, closed, byDesign - is settled. The one rule the
-- filters, tallies and the merge warning share.
function M.is_open(status)
  return status == nil or status == "active" or status == "pending"
end

-- The "@" completion entries for the comment editor: each reviewer with
-- the text a mention of them becomes when the comment is sent.
function M.mentions(pr)
  local out = {}
  local fmt = M.caps(pr).mention
  for _, r in ipairs(type(pr) == "table" and type(pr.reviewers) == "table" and pr.reviewers or {}) do
    if r.name and r.name ~= "" then
      out[#out + 1] = { name = r.name, id = r.id,
        token = (r.id and r.id ~= "" and fmt) and fmt(r.id) or nil }
    end
  end
  return out
end

return M
