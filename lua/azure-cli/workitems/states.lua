-- lua/azure-cli/workitems/states.lua: pure helpers mapping a work-item
-- state name to its sort rank and highlight group.
--
-- Built from the ordered `states` list the provider's `--wi-list
-- current|next` _meta line and `--wi-list sprints` _sprints line carry
-- (work_items.states: in azure-cli.yml, see README's Configuration/Work
-- items sections) - or, when that field is missing entirely (an older
-- provider, or no work_items.states: configured), the exact hard-coded
-- rank/highlight tables workitems/dashboard.lua and workitems/view.lua used
-- before this module existed, so an install that never configures
-- work_items.states: renders exactly as it always has.
--
-- Shared by workitems/dashboard.lua (section sort order) and
-- workitems/view.lua ([state] token colour); unit-tested directly
-- (tests/test-states.lua) without nvim.
local M = {}

-- Legacy hard-coded tables (pre-work_items.states:) - M.build's fallback
-- when `states` is nil/empty. "In Progress" is a synonym some work-item
-- types (e.g. Task) use in place of Active, ranked/coloured identically.
local DEFAULT_RANK = {
  Active = 1, ["In Progress"] = 1, New = 2, Implemented = 3,
  Resolved = 4, Closed = 5, Removed = 6,
}
local DEFAULT_HL = {
  Active = "AzureCliWiActive", ["In Progress"] = "AzureCliWiActive",
  New = "AzureCliWiNew", Implemented = "AzureCliWiImplemented",
  Resolved = "AzureCliWiResolved", Closed = "AzureCliWiClosed",
  Removed = "AzureCliWiRemoved",
}

-- Builds { rank = {state -> 1-based rank}, hl = {state -> highlight group} }
-- from an ordered `states` list: position = rank (first = most actionable,
-- sorted to the top of a section), and highlight group by position - 1st ->
-- AzureCliWiNew, 2nd -> AzureCliWiActive, last -> AzureCliWiRemoved,
-- second-to-last -> AzureCliWiClosed, everything else (the 3rd state up to
-- the third-from-last) -> AzureCliWiImplemented. A state name appearing more
-- than once in the list keeps its first position. Falls back to the legacy
-- tables above when `states` is nil or empty (see this file's header
-- comment) - most callers pass the provider's own "states" field straight
-- through, which is already omitted (not an empty list) in that case.
function M.build(states)
  if type(states) ~= "table" or #states == 0 then
    return { rank = DEFAULT_RANK, hl = DEFAULT_HL }
  end
  local n = #states
  local rank, hl = {}, {}
  for i, s in ipairs(states) do
    if rank[s] == nil then
      rank[s] = i
      local group
      if i == 1 then
        group = "AzureCliWiNew"
      elseif i == 2 then
        group = "AzureCliWiActive"
      elseif i == n then
        group = "AzureCliWiRemoved"
      elseif i == n - 1 then
        group = "AzureCliWiClosed"
      else
        group = "AzureCliWiImplemented"
      end
      hl[s] = group
    end
  end
  return { rank = rank, hl = hl }
end

-- Rank for `state` under `built` (M.build's return): any state not covered
-- (an unconfigured state name reported by the server, or the state name of
-- an old item that predates a states: list edit) ranks last, below every
-- named state, rather than colliding with a real rank.
function M.rank(built, state)
  return built.rank[state] or 9999
end

-- Highlight group for `state` under `built`: a neutral colour
-- (AzureCliWiOther) for anything not covered - see M.rank.
function M.hl(built, state)
  return built.hl[state] or "AzureCliWiOther"
end

return M
