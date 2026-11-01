-- lua/azure-cli/chat/plan_discard.lua: throwing a plan away yourself (#98) -
-- dd on an Agents screen row, gD in its plan view (#103, which closes that
-- view's tab). It asks first, at once - nothing before the question runs
-- git (#119) - Discard or Cancel, Discard first, saying what goes; refuses
-- while that agent is working. Discard deletes everything the agent left
-- on this machine: the plan's files, its conversation's, its place in the
-- queue, then in the background, all worktrees in parallel, each worktree
-- (forced: uncommitted and unpushed changes go with it) and the local
-- branch it was on; one toast says what went. The branch on the server
-- stays. The main chat's discard_plan (chat/plan.lua) moves an orphan
-- plan's files to plans/discarded/ with M.move_files.
--
--   M.inspect(key, cb)        what discarding plan `key` touches, no git:
--                             cb(info), at once
--   M.confirm_lines(info)     the question: what goes, what stays (pure)
--   M.move_files(key, stamp)  plans/<key>.json/.md into plans/discarded/:
--                             the directory and stamp, or nil and why
--   M.discard(key, on_gone, on_done)  does it: on_gone(err) once the plan
--                             is gone, on_done(what it did) once the
--                             worktrees' git jobs have finished
--   M.ask(row, after)         dd / gD: all of the above, `after` once it's gone
local M = {}

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function PLAN() return require("azure-cli.chat.plan") end
local function CHAT() return require("azure-cli.chat") end
local function FIX() return require("azure-cli.chat.tools_fix") end
local function git(argv, cb) require("azure-cli.chat.tools").git(argv, cb) end

-- The local branch worktree `dir` is on, from <dir>.branch (a story's), or
-- nil. No git.
local function branch_of(dir)
  local ok, lines = pcall(vim.fn.readfile, dir .. ".branch")
  local b = ok and lines[1] and vim.trim(lines[1]) or ""
  return b ~= "" and b or nil
end

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
  if target.work_item_id or target.task_id then
    out = FIX().story_dirs(target)
  elseif target.pr_id then
    local d = FIX().dir_for(target)
    if d then out[#out + 1] = d end
  end
  return out
end

-- What discarding plan `key` touches, from what needs no git: cb({ key,
-- label, target, plan (its record or nil), conv, running, turns (yours and
-- the agent's), queued, conversations (files), worktrees ({ dir, branch
-- (its local one, or nil) }) }), at once.
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
  if not info.running and target then
    for _, d in ipairs(worktree_dirs(target)) do info.worktrees[#info.worktrees + 1] = { dir = d, branch = branch_of(d) } end
  end
  cb(info)
end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

-- A worktree as an item: its folder's name, the whole path (~ for your
-- home) on a line of its own under it, so the popup never breaks it.
local function worktree_item(w, what)
  return { "its worktree " .. vim.fn.fnamemodify(w.dir, ":t") .. " " .. what, vim.fn.fnamemodify(w.dir, ":~") }
end

-- The question's lines (UI.choose): what goes, what stays - every item
-- "  - ", its extra lines (a path) "    " under its text. Pure.
function M.confirm_lines(info)
  local goes, stays = {}, {}
  if info.plan then
    goes[#goes + 1] = { "the plan (plans/" .. info.key .. ".json, .md)" }
  end
  if info.turns > 0 or #info.conversations > 0 then
    goes[#goes + 1] = { "its conversation (" .. plural(info.turns, "turn")
      .. (#info.conversations > 0 and (", " .. plural(#info.conversations, "saved file")) or "") .. ")" }
  else
    goes[#goes + 1] = { "no conversation" }
  end
  if info.queued then goes[#goes + 1] = { "its place in the queue" } end
  for _, w in ipairs(info.worktrees) do
    goes[#goes + 1] = worktree_item(w, "- with any uncommitted or unpushed changes in it")
    if w.branch then goes[#goes + 1] = { "its local branch " .. w.branch } end
  end
  stays[#stays + 1] = { info.label .. " itself, and its branch on the server" }
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
  lines[#lines + 1] = ""
  lines[#lines + 1] = "This can't be undone."
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

-- Deletes worktree `dir` and the local branch `branch` it was on (nil:
-- none), from the repository the worktree belongs to: `git worktree remove
-- --force`, so its changes go too; when git can't (its repository is gone),
-- the folder, which is always under the fix-worktrees root. Never the
-- branch on the server. cb(gone, why not, the branch deleted or nil,
-- problems).
local function delete_worktree(dir, branch, cb)
  local problems = {}
  local function by_hand(why)
    if not FIX().inside(FIX().root(), dir) or vim.fn.delete(dir, "rf") ~= 0 then return cb(false, why, nil, problems) end
    pcall(vim.fn.delete, dir .. ".branch")
    cb(true, nil, nil, problems)
  end
  git({ "git", "-C", dir, "rev-parse", "--git-common-dir" }, function(ok, common)
    common = vim.trim(common or "")
    if not ok or common == "" then return by_hand("git couldn't find its repository") end
    if not (common:sub(1, 1) == "/" or common:match("^%a:[/\\]")) then common = dir .. "/" .. common end
    git({ "git", "-C", common, "worktree", "remove", "--force", dir }, function(rok, _, err)
      if not rok then return by_hand("git wouldn't remove it: " .. vim.trim(err or "")) end
      pcall(vim.fn.delete, dir .. ".branch")
      if not branch then return cb(true, nil, nil, problems) end
      git({ "git", "-C", common, "rev-parse", "-q", "--verify", "refs/heads/" .. branch }, function(has)
        if not has then return cb(true, nil, nil, problems) end
        git({ "git", "-C", common, "branch", "-D", branch }, function(bok, _, berr)
          if not bok then problems[#problems + 1] = "couldn't delete the local branch " .. branch .. ": " .. vim.trim(berr or "") end
          cb(true, nil, bok and branch or nil, problems)
        end)
      end)
    end)
  end)
end

local function refusal(label)
  return label .. "'s agent is working - stop it with " .. require("azure-cli.keys").name("agents", "cancel")
    .. " first."
end

-- The worktrees a discard's git jobs are deleting right now: a second
-- discard (a new plan under the same key) leaves them alone, so none is
-- deleted twice.
local busy = {}

-- Worktree `w` after its plan went, unless an earlier discard is at it.
-- cb(gone, why not, the branch deleted or nil, problems).
local function delete_once(w, cb)
  if busy[w.dir] then return cb(false, "an earlier discard is still deleting it", nil, {}) end
  busy[w.dir] = true
  delete_worktree(w.dir, w.branch, function(...)
    busy[w.dir] = nil
    cb(...)
  end)
end

-- Discards plan `key`, looking again at what it touches (the question
-- waited for you). The plan goes at once, no git: on_gone(err, its label
-- when refused because its agent is working). Its worktrees and their
-- local branches are then deleted in the background, all in parallel:
-- on_result({ label, removed = { dir }, branches = { name }, kept = {
-- "dir (why)" }, problems }) once the last git job has finished.
local function discard_one(key, on_gone, on_result)
  M.inspect(key, function(info)
    if info.running then return on_gone(refusal(info.label), info.label) end
    require("azure-cli.chat.agents").unqueue(key)
    -- Its plan view's tab closes; from inside it (gD) you go back to the
    -- inner tab before it, as its q does - one in the background stays put.
    local view = PLAN().open_views()[key]
    if view and vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
      if vim.api.nvim_get_current_tabpage() == view.tab then pcall(require("azure-cli.innertabs").closing) end
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(view.tab))
    end
    local root = PLAN().root()
    for _, ext in ipairs({ ".json", ".md" }) do
      local f = root .. "/" .. key .. ext
      if vim.fn.filereadable(f) == 1 and vim.fn.delete(f) ~= 0 then return on_gone("couldn't delete " .. f) end
    end
    PLAN().forget(key)
    local problems = {}
    for _, f in ipairs(info.conversations) do
      if vim.fn.delete(f) ~= 0 then problems[#problems + 1] = "couldn't delete " .. f end
    end
    CHAT().drop_conversation(key)
    on_gone(nil)
    -- In the worktrees' order, whichever job finishes first.
    local results, left = {}, #info.worktrees
    local function finish()
      local kept, removed, branches = {}, {}, {}
      for i, w in ipairs(info.worktrees) do
        local r = results[i]
        if r.ok then removed[#removed + 1] = w.dir
        else kept[#kept + 1] = w.dir .. " (" .. r.why .. ")" end
        if r.branch then branches[#branches + 1] = r.branch end
        vim.list_extend(problems, r.problems)
      end
      if on_result then
        on_result({ label = info.label, removed = removed, branches = branches, kept = kept, problems = problems })
      end
    end
    if left == 0 then return finish() end
    for i, w in ipairs(info.worktrees) do
      delete_once(w, function(ok, why, branch, probs)
        results[i] = { ok = ok, why = why, branch = branch, problems = probs }
        left = left - 1
        if left == 0 then finish() end
      end)
    end
  end)
end

-- Discards plan `key` (discard_one): on_gone(err), on_done(the toast).
function M.discard(key, on_gone, on_done)
  discard_one(key, function(err) on_gone(err) end, function(r)
    local msg = "Discarded " .. r.label .. ": deleted its plan and conversation."
    if #r.removed > 0 then msg = msg .. " Deleted its worktree " .. table.concat(r.removed, ", ") .. "." end
    if #r.branches > 0 then msg = msg .. " Deleted its local branch " .. table.concat(r.branches, ", ") .. "." end
    if #r.kept > 0 then
      local kept = {}
      for i, k in ipairs(r.kept) do kept[i] = "its worktree " .. k end
      msg = msg .. " Couldn't delete " .. table.concat(kept, "; ") .. "."
    end
    if #r.problems > 0 then msg = msg .. " But: " .. table.concat(r.problems, "; ") .. "." end
    if on_done then on_done(msg) end
  end)
end

-- dd on an Agents screen row, gD in a plan view ({ key = its key }):
-- refused while its agent works, else the question (at once, no git),
-- then discarded; `after` (a redraw) as soon as the plan is gone, the
-- toast once its worktrees have been dealt with.
function M.ask(row, after)
  if not row then return end
  M.inspect(row.key, function(info)
    if info.running then return notify(refusal(info.label)) end
    if not (info.plan or info.conv or info.queued) then return notify("There's nothing to discard for " .. info.label .. ".") end
    require("azure-cli.ui").choose({ title = "Discard everything for " .. info.label .. "?", lines = M.confirm_lines(info),
      buttons = { "Discard", "Cancel" }, default = 1, keys = { y = 1, n = 2 }, cancel = 2 }, function(i)
      if i ~= 1 then return end
      M.discard(row.key, function(err)
        if err then notify(err, vim.log.levels.WARN) end
        if after then after() end
      end, function(msg) notify(msg) end)
    end)
  end)
end

return M
