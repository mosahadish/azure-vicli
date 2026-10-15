-- lua/azure-cli/chat/plan_discard.lua: throwing a plan away yourself (#98) -
-- dd on an Agents screen row, gD in its plan view (#103, which closes that
-- view's tab). It asks first, saying what goes and what
-- stays; refuses while that agent is working; moves the plan's files and
-- its conversation's into plans/discarded/<key>-<time>.* (put them back by
-- hand to undo); and removes the change's worktree only when it has
-- nothing in it - one with uncommitted or unpushed changes is kept, and
-- the question says so. The main chat's discard_plan (chat/plan.lua) moves
-- an orphan plan's files with M.move_files.
--
--   M.inspect(key, cb)        what discarding plan `key` touches: cb(info)
--   M.confirm_lines(info)     the question: what goes, what stays (pure)
--   M.move_files(key, stamp)  plans/<key>.json/.md into plans/discarded/:
--                             the directory and stamp, or nil and why
--   M.discard(key, cb)        does it: cb(err, what it did)
--   M.ask(row, after)         dd / gD: all of the above, `after` once it's gone
local M = {}

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function PLAN() return require("azure-cli.chat.plan") end
local function CHAT() return require("azure-cli.chat") end
local function FIX() return require("azure-cli.chat.tools_fix") end
local function git(argv, cb) require("azure-cli.chat.tools").git(argv, cb) end

local function is_repo(p)
  return p ~= "" and (vim.fn.isdirectory(p .. "/.git") == 1 or vim.fn.filereadable(p .. "/.git") == 1)
end

local function queued_job(key)
  for _, q in ipairs(require("azure-cli.chat.agents").queued()) do
    if q.key == key then return q end
  end
  return nil
end

-- The saved files of plan `key`'s conversation: the live one's and any
-- older one saved for that plan.
local function conversation_files(key, conv)
  local STORE = require("azure-cli.chat.store")
  local dir = STORE.root() .. "/conversations"
  local out, seen = {}, {}
  local function add(id)
    local f = id and (dir .. "/" .. id .. ".json")
    if f and not seen[f] and vim.fn.filereadable(f) == 1 then
      seen[f] = true
      out[#out + 1] = f
    end
  end
  if conv then add(conv.conv_id) end
  for _, s in ipairs(STORE.list()) do
    if s.plan == key then add(s.id) end
  end
  return out
end

-- The worktrees of `target`'s change: a story's (and its read-only
-- planning one, which has no <dir>.branch), or a PR's fix.
local function worktree_dirs(target)
  local out = {}
  if target.work_item_id then
    for _, d in ipairs(vim.fn.glob(FIX().root() .. "/*-wi" .. tostring(target.work_item_id), false, true)) do
      if is_repo(d) then out[#out + 1] = d end
    end
  elseif target.pr_id then
    local d = FIX().dir_for(target)
    if d then out[#out + 1] = d end
  end
  return out
end

-- cb({ dir, dirty = files changed, unpushed = commits no remote has,
-- unknown = git couldn't tell }) - anything but a clean one is kept.
local function worktree_state(dir, cb)
  git({ "git", "-C", dir, "status", "--porcelain" }, function(ok, out)
    local dirty = 0
    for _, l in ipairs(vim.split(out or "", "\n", { plain = true })) do
      if vim.trim(l) ~= "" then dirty = dirty + 1 end
    end
    git({ "git", "-C", dir, "rev-list", "--count", "HEAD", "--not", "--remotes" }, function(rok, n)
      local unpushed = tonumber(vim.trim(n or ""))
      local w = { dir = dir, dirty = dirty, unpushed = unpushed or 0, unknown = not (ok and rok and unpushed) }
      w.keep = w.unknown or w.dirty > 0 or w.unpushed > 0
      cb(w)
    end)
  end)
end

-- What discarding plan `key` touches: cb({ key, label, target, plan (its
-- record or nil), conv, running, turns (yours and the agent's), queued,
-- conversations (files), worktrees (worktree_state's) }).
function M.inspect(key, cb)
  local rec = PLAN().load(key)
  local conv = CHAT().find_conversation(key)
  local job = queued_job(key)
  local target = (rec and rec.target) or (conv and conv.target) or (job and job.target) or nil
  local turns = 0
  for _, e in ipairs(conv and conv.entries or {}) do
    if e.role ~= "note" then turns = turns + 1 end
  end
  local info = { key = key, target = target, plan = rec, conv = conv, running = conv and conv.running or false,
    turns = turns, queued = job ~= nil, conversations = conversation_files(key, conv), worktrees = {},
    label = target and PLAN().target_label(target) or (conv and conv.label) or (job and job.label) or key }
  if info.running or not target then return cb(info) end
  local dirs = worktree_dirs(target)
  local i = 0
  local function next_dir()
    i = i + 1
    if i > #dirs then return cb(info) end
    worktree_state(dirs[i], function(w)
      info.worktrees[#info.worktrees + 1] = w
      next_dir()
    end)
  end
  next_dir()
end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function changes_of(w)
  if w.unknown then return "git couldn't tell what's in it" end
  local parts = {}
  if w.dirty > 0 then parts[#parts + 1] = plural(w.dirty, "uncommitted file") end
  if w.unpushed > 0 then parts[#parts + 1] = plural(w.unpushed, "unpushed commit") end
  return table.concat(parts, ", ")
end

-- A worktree as an item: its folder's name, the whole path (~ for your
-- home) on a line of its own under it, so the popup never breaks it.
local function worktree_item(w, what)
  return { "its worktree " .. vim.fn.fnamemodify(w.dir, ":t") .. " " .. what, vim.fn.fnamemodify(w.dir, ":~") }
end

-- The question's lines (UI.confirm): what goes, what stays - every item
-- "  - ", its extra lines (a path) "    " under its text. Pure.
function M.confirm_lines(info)
  local goes, stays = {}, {}
  if info.plan then
    goes[#goes + 1] = { "the plan (plans/" .. info.key .. ".json, .md) - moved to plans/discarded/" }
  end
  if info.turns > 0 or #info.conversations > 0 then
    goes[#goes + 1] = { "its conversation (" .. plural(info.turns, "turn")
      .. (#info.conversations > 0 and (", " .. plural(#info.conversations, "saved file") .. " moved too") or "") .. ")" }
  else
    goes[#goes + 1] = { "no conversation: the main chat wrote this plan before planning moved to agents" }
  end
  if info.queued then goes[#goes + 1] = { "its place in the queue" } end
  for _, w in ipairs(info.worktrees) do
    if not w.keep then goes[#goes + 1] = worktree_item(w, "(nothing in it) - removed") end
  end
  stays[#stays + 1] = { info.label .. " itself, and its branch on the server" }
  for _, w in ipairs(info.worktrees) do
    if w.keep then stays[#stays + 1] = worktree_item(w, "- " .. changes_of(w) .. ": kept") end
  end
  local lines = {}
  local function list(title, items)
    lines[#lines + 1] = title
    for _, item in ipairs(items) do
      for i, l in ipairs(item) do lines[#lines + 1] = (i == 1 and "  - " or "    ") .. l end
    end
  end
  list("Goes:", goes)
  lines[#lines + 1] = ""
  list("Stays:", stays)
  return lines
end

-- Moves plan `key`'s files into plans/discarded/<key>-<stamp>.json/.md and
-- forgets it. The directory and the stamp, or nil and why.
function M.move_files(key, stamp)
  local root = PLAN().root()
  local dir = root .. "/discarded"
  stamp = stamp or os.date("%Y%m%d-%H%M%S")
  vim.fn.mkdir(dir, "p")
  for _, ext in ipairs({ ".json", ".md" }) do
    local from = root .. "/" .. key .. ext
    if vim.fn.filereadable(from) == 1 and vim.fn.rename(from, dir .. "/" .. key .. "-" .. stamp .. ext) ~= 0 then
      return nil, "couldn't move " .. from
    end
  end
  PLAN().forget(key)
  return dir, stamp
end

-- `git worktree remove` from the repository the worktree belongs to, never
-- --force: git refuses one with changes, a second guard. cb(ok, err).
local function remove_worktree(dir, cb)
  git({ "git", "-C", dir, "rev-parse", "--git-common-dir" }, function(ok, common)
    common = vim.trim(common or "")
    if not ok or common == "" then return cb(false, "git couldn't find its repository") end
    if not (common:sub(1, 1) == "/" or common:match("^%a:[/\\]")) then common = dir .. "/" .. common end
    git({ "git", "-C", common, "worktree", "remove", dir }, function(rok, _, err)
      if rok then pcall(vim.fn.delete, dir .. ".branch") end
      cb(rok, vim.trim(err or ""))
    end)
  end)
end

local function refusal(label)
  return label .. "'s agent is working - stop it with " .. require("azure-cli.keys").name("agents", "cancel")
    .. " first."
end

-- Discards plan `key`, looking again at what it touches (the question
-- waited for you). cb(err, what it did).
function M.discard(key, cb)
  M.inspect(key, function(info)
    if info.running then return cb(refusal(info.label)) end
    require("azure-cli.chat.agents").unqueue(key)
    -- Its plan view's tab closes; from inside it (gD) you go back to the
    -- inner tab before it, as its q does - one in the background stays put.
    local view = PLAN().open_views()[key]
    if view and vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
      if vim.api.nvim_get_current_tabpage() == view.tab then pcall(require("azure-cli.innertabs").closing) end
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(view.tab))
    end
    local dir, stamp = M.move_files(key)
    if not dir then return cb(stamp) end
    local problems = {}
    for i, f in ipairs(info.conversations) do
      local to = dir .. "/" .. key .. "-" .. stamp .. ".conversation" .. (i > 1 and ("-" .. i) or "") .. ".json"
      if vim.fn.rename(f, to) ~= 0 then problems[#problems + 1] = "couldn't move " .. f end
    end
    CHAT().drop_conversation(key)
    local kept, removed = {}, {}
    local i = 0
    local function next_worktree()
      i = i + 1
      local w = info.worktrees[i]
      if not w then
        local msg = "Discarded the plan for " .. info.label .. " (moved to " .. dir .. ")."
        if #removed > 0 then msg = msg .. " Removed its worktree " .. table.concat(removed, ", ") .. "." end
        if #kept > 0 then msg = msg .. " Kept " .. table.concat(kept, "; ") .. "." end
        if #problems > 0 then msg = msg .. " But: " .. table.concat(problems, "; ") .. "." end
        return cb(nil, msg)
      end
      if w.keep then
        kept[#kept + 1] = "its worktree " .. w.dir .. " (" .. changes_of(w) .. ")"
        return next_worktree()
      end
      remove_worktree(w.dir, function(ok, err)
        if ok then removed[#removed + 1] = w.dir
        else kept[#kept + 1] = "its worktree " .. w.dir .. " (git wouldn't remove it: " .. err .. ")" end
        next_worktree()
      end)
    end
    next_worktree()
  end)
end

-- dd on an Agents screen row, gD in a plan view ({ key = its key }):
-- refused while its agent works, else the question, then discarded;
-- `after` (a redraw) once it's done.
function M.ask(row, after)
  if not row then return end
  M.inspect(row.key, function(info)
    if info.running then return notify(refusal(info.label)) end
    if not (info.plan or info.conv or info.queued) then return notify("There's nothing to discard for " .. info.label .. ".") end
    require("azure-cli.ui").confirm({ title = "Discard the plan for " .. info.label .. "?", lines = M.confirm_lines(info),
      yes = "Discard", default = "no" }, function(yes)
      if not yes then return end
      M.discard(row.key, function(err, msg)
        notify(err or msg, err and vim.log.levels.WARN or nil)
        if after then after() end
      end)
    end)
  end)
end

return M
