-- lua/azure-cli/chat/watch.lua: the pull requests the chat opened or pushed
-- a fix to, watched for new comments while azure-vicli runs - the PR
-- dashboard doesn't have to be open. What happens then is
-- chat.on_new_comments:
--
--   "suggest"  (default) a note in the chat saying so - /triage, or ask
--   "plan"     an agent plans the fix of the new comments, as gP does for a
--              PR's threads; its plan waits for you on the Agents screen
--
-- Comments arriving close together are taken together: a PR's new ones
-- are acted on at the first poll that finds no newer ones. Only other
-- people's comments count (not yours, nor the agent's - it posts as you).
-- A PR that's completed or abandoned stops being watched, and the plans
-- behind it are finished (plan.pr_closed). Kept in
-- stdpath("data")/azure-cli-chat/watched.json: per PR, where it is and the
-- comments already seen.
--
--   M.add(pr)       starts watching PR `pr` (id, org, project, repo, title)
--   M.watched(id)   whether PR `id` is watched
--   M.start()       the poll timer (chat.watch_seconds, default 120)
--   M.poll(cb)      one round now; cb() once every PR's been looked at
--   M.new_comments(threads, seen, me)  pure: the other people's comments
--                   not in `seen`, as { keys, threads (ids) }
local M = {}

M.DEFAULT_SECONDS = 120

local function CHAT() return require("azure-cli.chat") end
local function TOOLS() return require("azure-cli.chat.tools") end
local function STATE() return require("azure-cli.state") end
local function SHELL() return require("azure-cli.shell") end
local function config() return require("azure-cli.config").get().chat or {} end

local function file() return require("azure-cli.chat.store").root() .. "/watched.json" end

local poll_one  -- below
local list  -- id (string) -> { id, org, project, repo, title, seen = { "tid:cid" = true }, pending }
local function load()
  if not list then
    list = SHELL().read_json(file(), {}, { validate = function(t) return type(t) == "table" end })
  end
  return list
end
local function save()
  vim.fn.mkdir(require("azure-cli.chat.store").root(), "p")
  SHELL().write_json(file(), next(list) and list or vim.empty_dict())
end

function M.new_comments(threads, seen, me)
  local keys, ids = {}, {}
  for _, t in ipairs(type(threads) == "table" and threads or {}) do
    if type(t) == "table" and t.isDeleted ~= true then
      local fresh = false
      for _, c in ipairs(type(t.comments) == "table" and t.comments or {}) do
        local author = type(c) == "table" and type(c.author) == "table" and c.author or {}
        if type(c) == "table" and c.commentType ~= "system" and c.isDeleted ~= true
            and (me == nil or author.id ~= me) then
          local key = tostring(t.id) .. ":" .. tostring(c.id)
          if not seen[key] then keys[#keys + 1] = key; fresh = true end
        end
      end
      if fresh then ids[#ids + 1] = t.id end
    end
  end
  return { keys = keys, threads = ids }
end

function M.watched(id) return load()[tostring(id)] ~= nil end

function M.add(pr)
  if type(pr) ~= "table" or not pr.id then return end
  local w = load()
  local id = tostring(pr.id)
  local rec = w[id] or {}
  rec.id, rec.title = pr.id, pr.title or rec.title
  rec.org, rec.project, rec.repo = pr.org or rec.org, pr.project or rec.project, pr.repo or rec.repo
  w[id] = rec
  save()
  M.start()
  -- What's on it now isn't new: take that in right away, not at the
  -- first poll (a comment in between would count as already seen).
  if rec.seen == nil then vim.schedule(function() pcall(poll_one, rec, function() end) end) end
end

-- My identity in `org`/`project` (to tell my comments apart): the
-- reviewer's cache, a dashboard row's, else --whoami. cb(id or nil).
local function whoami(org, project, cb)
  STATE().whoami = STATE().whoami or {}
  local key = org .. "|" .. project
  if STATE().whoami[key] then return cb(STATE().whoami[key].id) end
  for _, p in ipairs((STATE().PR_LIST_CACHE or {}).prs or {}) do
    if p.org == org and p.project == project and p.myId and p.myId ~= "" then
      STATE().whoami[key] = { id = p.myId, displayName = p.myName or "" }
      return cb(p.myId)
    end
  end
  local argv = require("azure-cli.config").provider_argv()
  vim.list_extend(argv, { "--whoami", "--org", org, "--project", project })
  local out = {}
  local ok = pcall(vim.fn.jobstart, argv, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        local okd, rec = pcall(vim.json.decode, table.concat(out, ""))
        if code == 0 and okd and type(rec) == "table" and rec.id then
          STATE().whoami[key] = rec
          return cb(rec.id)
        end
        cb(nil)
      end)
    end,
  })
  if not ok then cb(nil) end
end

local function act(rec, pr, pending)
  local n = #pending.keys
  local what = "!" .. tostring(rec.id) .. " \"" .. tostring(rec.title or "") .. "\" got " .. n .. " new comment"
    .. (n == 1 and "" or "s")
  pcall(function() CHAT().alert("azure-vicli: PR !" .. tostring(rec.id), what) end)
  if config().on_new_comments == "plan" then
    local _, added = require("azure-cli.chat.agents").start_for_prs({ pr }, { [pr.id] = pending.threads })
    -- Its agent busy (or no agent set): try again at the next poll.
    if not added or #added == 0 then return false end
    CHAT().note(what .. " - an agent is planning the fix; the Agents screen shows it.")
  else
    CHAT().note(what .. " - open it and send /triage, or ask here.")
  end
  return true
end

poll_one = function(rec, done)
  local env = { AZVICLI_ORG = rec.org or "", AZVICLI_PROJECT = rec.project or "", AZVICLI_PR = tostring(rec.id) }
  TOOLS().provider({ "--get-pr" }, env, function(ok, out)
    local okd, pr = pcall(vim.json.decode, out or "")
    if not (ok and okd and type(pr) == "table" and pr.id) then return done() end  -- try again later
    -- Not active any more: stop watching it. (--get-pr's `state` is the
    -- PR's status; a dashboard row's is its section.)
    if pr.state == "completed" or pr.state == "abandoned" then
      list[tostring(rec.id)] = nil
      save()
      -- Its agents are finished (the Agents screen).
      pcall(require("azure-cli.chat.plan").pr_closed, rec.id, pr.state)
      return done()
    end
    TOOLS().fetched[tostring(rec.id)] = TOOLS().pr_record(rec.id) or pr
    rec.title, rec.repo = pr.title or rec.title, pr.repo or rec.repo
    whoami(rec.org or "", rec.project or "", function(me)
      if not me then return done() end  -- can't tell whose they are: wait
      TOOLS().provider({ "--threads" }, TOOLS().pr_env(TOOLS().pr_record(rec.id) or pr), function(tok, tout)
        local okt, decoded = pcall(vim.json.decode, tout or "", { luanil = { object = true, array = true } })
        if not (tok and okt and type(decoded) == "table") then return done() end
        local threads = decoded.value or decoded
        local first = rec.seen == nil
        rec.seen = rec.seen or {}
        local found = M.new_comments(threads, rec.seen, me)
        for _, k in ipairs(found.keys) do rec.seen[k] = true end
        if first then
          -- What's there when it starts being watched isn't new.
        elseif #found.keys > 0 then
          -- More are coming in: wait for a poll that finds none.
          rec.pending = rec.pending or { keys = {}, threads = {} }
          vim.list_extend(rec.pending.keys, found.keys)
          for _, t in ipairs(found.threads) do
            if not vim.tbl_contains(rec.pending.threads, t) then table.insert(rec.pending.threads, t) end
          end
        elseif rec.pending then
          if act(rec, TOOLS().pr_record(rec.id) or pr, rec.pending) then rec.pending = nil end
        end
        save()
        done()
      end)
    end)
  end)
end

local polling = false
function M.poll(cb)
  cb = cb or function() end
  if polling or not CHAT().current_agent() then return cb() end
  local ids = vim.tbl_keys(load())
  if #ids == 0 then return cb() end
  polling = true
  local i = 0
  local function nxt()
    i = i + 1
    local rec = list[ids[i]]
    if i > #ids then polling = false return cb() end
    if not rec then return nxt() end
    local ok = pcall(poll_one, rec, nxt)
    if not ok then nxt() end
  end
  nxt()
end

local timer
function M.start()
  if timer or not next(load()) then return end
  -- poll.lua slows it while you're away (up to timing.max_poll_seconds).
  timer = require("azure-cli.poll").every("chat-watch", {
    base = function() return tonumber(config().watch_seconds) or M.DEFAULT_SECONDS end,
    tick = function() M.poll() end,
  })
end

-- Tests: forget what's loaded (a "restart") and stop the timer.
function M._reset()
  list = nil
  polling = false
  if timer then require("azure-cli.poll").stop(timer); timer = nil end
end

return M
