-- lua/azure-cli/people.lua: finding people on a PR's host - gR's "add a
-- reviewer" and the comment editor's <C-t> "tag someone".
--
--   search        the provider's --find-people (Azure: Identities by name,
--                 account or email; GitHub: the repository's people by
--                 login or name, else that login) as a list of { name, id,
--                 account / login }; everyone found is remembered
--                 (hosts.remember), so "@" completion offers them after
--   pick          a popup listing everyone who can review (the project's
--                 teams / the repo's assignable people) that typing
--                 narrows (picker.lua), searching the host for more
--   add_reviewer  pick, then (Azure) optional or required, then
--                 --add-reviewer with the person's id
--   remove_reviewer  gX: pick one of the PR's reviewers, confirm, then
--                 --remove-reviewer (take_off, which the chat's tool uses too)
local M = {}

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function T() return require("azure-cli.chat.tools") end
local function HOSTS() return require("azure-cli.hosts") end

-- cb(list) or cb(nil, err).
function M.search(pr, query, cb)
  T().provider({ "--find-people", query }, T().pr_env(pr), function(ok, out, err)
    if not ok then return cb(nil, (err ~= "" and err) or "the search failed") end
    local okj, list = pcall(vim.json.decode, out)
    if not okj or type(list) ~= "table" then return cb(nil, "the search gave an unexpected answer") end
    for _, p in ipairs(list) do HOSTS().remember(pr, p.id, p.name) end
    cb(list)
  end)
end

-- "Jane Doe  jane@contoso.com" / "Jane Doe  jdoe".
function M.label(p)
  local extra = p.account or p.login
  return tostring(p.name or p.id) .. ((extra and extra ~= "" and extra ~= p.name) and ("  " .. extra) or "")
end

-- How many characters a typed search of the host takes, and the list's rows.
M.MIN_CHARS, M.MAX_ROWS = 2, 10

-- Lower-cased id -> true for `pr`'s reviewers: gR doesn't offer them.
local function reviewer_ids(pr)
  local out = {}
  for _, r in ipairs(type(pr.reviewers) == "table" and pr.reviewers or {}) do
    if r.id then out[tostring(r.id):lower()] = true end
  end
  return out
end

-- Everyone who can review on a PR's project (Azure: its teams' members;
-- GitHub: the repository's assignable people), per project, for the
-- session: --find-people with no query, fetched once.
M.everyone = {}
local function everyone_key(pr)
  return table.concat({ HOSTS().host(pr), pr.org or "", pr.project or "", pr.repo or "" }, "|")
end

-- Asks for a person (`title` names what it's for) in picker.lua's popup,
-- listing everyone who can review on the PR's project (M.everyone) as it
-- opens; typing narrows and orders that list, and each pause in typing
-- also searches the host's directory and adds whoever else that finds -
-- only people the host itself returns, nobody from anywhere else.
-- cb(person) once one is picked, nothing on a cancel.
-- opts.skip_reviewers leaves out the PR's reviewers (gR).
function M.pick(pr, title, cb, opts)
  opts = opts or {}
  local skip = opts.skip_reviewers and reviewer_ids(pr) or {}
  local by_id, asked = {}, {}
  -- `list` less the skipped, as the entries already listed where they
  -- are: (the new ones, all of them).
  local function sort(list)
    local new, all = {}, {}
    for _, p in ipairs(list or {}) do
      local k = tostring(p.id):lower()
      if not skip[k] then
        if not by_id[k] then
          by_id[k] = p
          new[#new + 1] = p
        end
        all[#all + 1] = by_id[k]
      end
    end
    return new, all
  end
  local api = require("azure-cli.picker").open({
    title = title, items = {}, format = M.label,
    width = 70, height = M.MAX_ROWS, ft = "azure-cli-people", empty = "Nobody to list",
    on_query = function(q, api)
      if #q < M.MIN_CHARS or asked[q:lower()] then return end
      asked[q:lower()] = true
      api.status("searching\u{2026}")
      M.search(pr, q, function(list, err)
        if api.done() then return end
        api.status(list and "" or ("search failed: " .. tostring(err)))
        local new, all = sort(list)
        api.add(new)
        api.keep(q, all)
      end)
    end,
  }, function(p)
    if p then cb(p) end
  end)
  local cached = M.everyone[everyone_key(pr)]
  if cached then return api.add((sort(cached))) end
  api.status("loading people\u{2026}")
  M.search(pr, "", function(list, err)
    if list then M.everyone[everyone_key(pr)] = list end
    if api.done() then return end
    api.status(list and "" or ("couldn't list people: " .. tostring(err)))
    api.add((sort(list)))
  end)
end

-- gR: adds a reviewer to `pr`, then on_done(person) once the host has
-- them (the record's reviewers list has them too, and the PR dashboard is
-- redrawn and refetched).
function M.add_reviewer(pr, on_done)
  if not pr then return notify("No PR here.", vim.log.levels.WARN) end
  if not HOSTS().caps(pr).add_reviewer then
    return notify("Adding reviewers isn't available for this PR.", vim.log.levels.WARN)
  end
  M.pick(pr, "Add a reviewer to " .. HOSTS().ref(pr), function(p)
    local function go(required)
      notify("Adding " .. p.name .. "\u{2026}")
      T().provider({ "--add-reviewer", tostring(p.id), required and "true" or "false" }, T().pr_env(pr),
        function(ok, out, err)
          if not ok then return notify("Couldn't add " .. p.name .. ": " .. err, vim.log.levels.ERROR) end
          pr.reviewers = pr.reviewers or {}
          local have = false
          for _, r in ipairs(pr.reviewers) do
            if tostring(r.id or ""):lower() == tostring(p.id):lower() then have = true end
          end
          if not have then
            table.insert(pr.reviewers, { name = p.name, id = p.id, vote = 0, isRequired = required or nil,
              requested = HOSTS().host(pr) == "github" or nil })
            require("azure-cli.prs").recompute(pr)
          end
          local okj, d = pcall(vim.json.decode, out)
          local note = okj and type(d) == "table" and d.note
          notify("Added " .. p.name .. " as a " .. (required and "required " or "") .. "reviewer"
            .. (note and (" (" .. note .. ")") or "") .. ".")
          -- The PR dashboard shows them at once (the record is its own),
          -- then as the host has them.
          local STATE = require("azure-cli.state")
          if STATE.PR_DASHBOARD_RENDER then STATE.PR_DASHBOARD_RENDER() end
          if STATE.PR_DASHBOARD_RELOAD then STATE.PR_DASHBOARD_RELOAD() end
          if on_done then on_done(p) end
        end)
    end
    if HOSTS().host(pr) == "azure" then
      require("azure-cli.prompt").select({ prompt = "Add " .. p.name .. " as", items = {
        { key = "optional", label = "Optional reviewer" },
        { key = "required", label = "Required reviewer" },
      } }, function(o) if o then go(o.key == "required") end end)
    else
      go(false)
    end
  end, { skip_reviewers = true })
end

-- What the PR dashboard and reviewer redraw after a reviewer change: the
-- dashboard at once (the record is its own), then as the host has it.
local function redraw()
  local STATE = require("azure-cli.state")
  if STATE.PR_DASHBOARD_RENDER then STATE.PR_DASHBOARD_RENDER() end
  if STATE.PR_DASHBOARD_RELOAD then STATE.PR_DASHBOARD_RELOAD() end
end

-- "Bob Brown · approved", "Carol Chen · required, no vote" - a reviewer as
-- gX lists them.
function M.reviewer_label(pr, r)
  local vote = "no vote"
  for _, v in ipairs(HOSTS().caps(pr).votes or {}) do
    if tostring(v.key) == tostring(r.vote or 0) and tostring(r.vote or 0) ~= "0" then vote = v.label:lower() end
  end
  return tostring(r.name or r.id) .. "  \u{00B7}  " .. (r.isRequired and "required, " or "") .. vote
end

-- The reviewers gX can take off `pr`: all of them on Azure; on GitHub only
-- those whose review is still a request (GitHub keeps a submitted review).
function M.removable(pr)
  local out = {}
  for _, r in ipairs(type(pr.reviewers) == "table" and pr.reviewers or {}) do
    if r.id and r.id ~= "" and (HOSTS().host(pr) ~= "github" or r.requested) then out[#out + 1] = r end
  end
  return out
end

-- Takes reviewer `r` (one of M.removable(pr)) off `pr` with
-- --remove-reviewer; the record loses them and the dashboard is redrawn.
-- cb(ok, err). gX's and the chat's remove_reviewer.
function M.take_off(pr, r, cb)
  T().provider({ "--remove-reviewer", tostring(r.id) }, T().pr_env(pr), function(ok, _, err)
    if not ok then return cb(false, err) end
    for i, x in ipairs(pr.reviewers or {}) do
      if x == r then table.remove(pr.reviewers, i) break end
    end
    require("azure-cli.prs").recompute(pr)
    redraw()
    cb(true)
  end)
end

-- The one of `list` (reviewers or people) `who` names - its id, account,
-- login or name, exactly (any case), else as the only one whose name or
-- account contains it. nil, and the names that matched, when it isn't one.
function M.match(list, who)
  local w = vim.trim(tostring(who or "")):gsub("^@", ""):lower()
  if w == "" then return nil, {} end
  local function fields(p) return { p.id, p.account, p.login, p.name } end
  for _, p in ipairs(list) do
    for _, f in ipairs(fields(p)) do
      if f and tostring(f):lower() == w then return p, {} end
    end
  end
  local hits = {}
  for _, p in ipairs(list) do
    for _, f in ipairs({ p.name, p.account, p.login }) do
      if f and tostring(f):lower():find(w, 1, true) then hits[#hits + 1] = p break end
    end
  end
  if #hits == 1 then return hits[1], {} end
  return nil, vim.tbl_map(function(p) return tostring(p.name or p.id) end, hits)
end

-- gX: picks one of `pr`'s reviewers, asks, and takes them off; then
-- on_done(reviewer) once the host has (the record loses them too, and the
-- PR dashboard is redrawn and refetched).
function M.remove_reviewer(pr, on_done)
  if not pr then return notify("No PR here.", vim.log.levels.WARN) end
  if not HOSTS().caps(pr).remove_reviewer then
    return notify("Removing reviewers isn't available for this PR.", vim.log.levels.WARN)
  end
  local list = M.removable(pr)
  if #list == 0 then
    return notify(HOSTS().host(pr) == "github"
      and "No review requests to take back on " .. HOSTS().ref(pr) .. "."
      or "No reviewers on " .. HOSTS().ref(pr) .. ".", vim.log.levels.WARN)
  end
  local PROMPT = require("azure-cli.prompt")
  PROMPT.select({ prompt = "Remove a reviewer from " .. HOSTS().ref(pr), items = list,
    format = function(r) return M.reviewer_label(pr, r) end }, function(r)
    if not r then return end
    PROMPT.confirm({ title = "Remove " .. tostring(r.name or r.id) .. "?" }, function(yes)
      if not yes then return end
      notify("Removing " .. tostring(r.name or r.id) .. "\u{2026}")
      M.take_off(pr, r, function(ok, err)
        if not ok then
          return notify("Couldn't remove " .. tostring(r.name or r.id) .. ": " .. err, vim.log.levels.ERROR)
        end
        notify("Removed " .. tostring(r.name or r.id) .. " from " .. HOSTS().ref(pr) .. ".")
        if on_done then on_done(r) end
      end)
    end)
  end)
end

return M
