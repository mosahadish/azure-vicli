-- lua/azure-cli/people.lua: finding people on a PR's host - gR's "add a
-- reviewer" and the comment editor's <C-t> "tag someone".
--
--   search        the provider's --find-people (Azure: Identities by name,
--                 account or email; GitHub: the repository's people by
--                 login or name, else that login) as a list of { name, id,
--                 account / login }; everyone found is remembered
--                 (hosts.remember), so "@" completion offers them after
--   pick          asks for a name, searches, and lets you pick one
--   add_reviewer  pick, then (Azure) optional or required, then
--                 --add-reviewer with the person's id
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

-- Asks for a name (`title` names what it's for), searches and offers the
-- matches: cb(person) once one is picked, nothing on a cancel.
function M.pick(pr, title, cb)
  local PROMPT = require("azure-cli.prompt")
  PROMPT.input({ prompt = title .. " - name, account or email: " }, function(q)
    q = q and vim.trim(q) or ""
    if q == "" then return end
    notify("Searching for \"" .. q .. "\"\u{2026}")
    M.search(pr, q, function(list, err)
      if not list then return notify("Search failed: " .. err, vim.log.levels.ERROR) end
      if #list == 0 then return notify("Nobody matches \"" .. q .. "\".", vim.log.levels.WARN) end
      PROMPT.select({ prompt = title, items = list, format = M.label, search = #list > 9 }, function(p)
        if p then cb(p) end
      end)
    end)
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
            table.insert(pr.reviewers, { name = p.name, id = p.id, vote = 0, isRequired = required or nil })
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
  end)
end

return M
