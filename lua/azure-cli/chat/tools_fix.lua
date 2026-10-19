-- lua/azure-cli/chat/tools_fix.lua: "fix this comment" end to end.
--
--   start_fix            a git worktree of the PR's source branch, under
--                        stdpath("cache")/azure-cli/fix-worktrees/ ({fix_root}
--                        in the agent's command), at its current tip - the
--                        agent edits files there with its own tools, never
--                        in the user's checkout
--   start_story          the same for implementing a work item: a new branch
--                        on the server (linked to the work item, as
--                        create_branch makes it) and a worktree of it
--   show_fix             the change so far, shown to the user file by file in
--                        a tab of its own (chat/changes.lua) and returned to
--                        the agent
--   commit_and_push_fix  commits it and pushes it to the branch - asks first,
--                        showing the diff
--   discard_fix          throws the change away
--   delete_fix_file      deletes a file inside the worktree (the agent's
--                        own file tools can't), refusing any path outside it
--
-- show/commit/discard take pr_id for a PR's fix, work_item_id for a story.
-- start_fix / start_story first need an approved plan (chat/plan.lua's
-- gate, unless setup({ chat = { plan_first = false } })); a push marks it
-- done.
--
-- Returns function(T) -> list of tools, T being chat/tools.lua.
local M = {}

function M.root()
  return vim.fn.stdpath("cache") .. "/azure-cli/fix-worktrees"
end

-- The worktree for PR `pr`: <root>/<repo>-<id> on Azure; where the PR's key
-- is more than its id (GitHub: owner~repo~n), <root>/<its plan key>, e.g.
-- pr-github-o~cli~7 (#113: a GitHub number repeats across repos). That name
-- holds only [%w._~-] (plan_text.key), and an Azure one never a "~".
function M.path(pr)
  local PLAN = require("azure-cli.chat.plan")
  local target = PLAN.pr_target(pr)
  if target.pr_key then return M.root() .. "/" .. PLAN.key(target) end
  return M.legacy_path(pr)
end

-- <root>/<repo>-<id>: every PR's worktree before #113, Azure's still.
function M.legacy_path(pr)
  return M.root() .. "/" .. (tostring(pr.repo or "repo") .. "-" .. tostring(pr.id)):gsub("[^%w%._%-]", "_")
end

local function is_repo(p)
  return p ~= "" and (vim.fn.isdirectory(p .. "/.git") == 1 or vim.fn.filereadable(p .. "/.git") == 1)
end

-- The worktree PR `pr`'s fix is in: M.path(pr) - or, for a GitHub PR whose
-- fix began before #113, its <repo>-<id> one when no other listed PR has
-- that name (then neither claims it). Only looked up, never moved.
function M.fix_dir(pr)
  local p = M.path(pr)
  if is_repo(p) then return p end
  local old = M.legacy_path(pr)
  if old == p or not is_repo(old) then return p end
  local STATE = require("azure-cli.state")
  local cands = vim.list_extend({}, (STATE.PR_LIST_CACHE and STATE.PR_LIST_CACHE.prs) or {})
  if STATE.PR_CURRENT then cands[#cands + 1] = STATE.PR_CURRENT end
  local HOSTS = require("azure-cli.hosts")
  for _, o in ipairs(cands) do
    if tostring(HOSTS.key(o)) ~= tostring(HOSTS.key(pr)) and M.legacy_path(o) == old then return p end
  end
  return old
end

-- The worktree for work item `target` (a plan target, or an id) in
-- repository `repo`: <root>/<repo>-wi<id>; for a GitHub issue's target
-- (#114: a number repeats across repos) <root>/<its plan key>, e.g.
-- wi-github-o~cli~7, as #113 names a GitHub PR's. Its branch is kept next
-- to it in <dir>.branch: the worktree is on that branch (#59), unless git
-- couldn't put it there (the branch is out in the user's clone or another
-- worktree, or has commits origin hasn't) - then its HEAD is detached,
-- like a fix's.
function M.story_path(repo, target)
  if type(target) == "table" and target.item_key then
    return M.root() .. "/" .. require("azure-cli.chat.plan").key(target)
  end
  local id = type(target) == "table" and target.work_item_id or target
  return M.root() .. "/" .. (tostring(repo) .. "-wi" .. tostring(id)):gsub("[^%w%._%-]", "_")
end

-- `path` (relative to worktree `wt`, or absolute inside it; / or \) as a
-- path relative to `wt`, or nil when it points outside it. Pure.
function M.inside(wt, path)
  if type(path) ~= "string" or path == "" then return nil end
  local root = (wt:gsub("\\", "/"):gsub("/+$", ""))
  local p = path:gsub("\\", "/")
  if p:match("^%a:/") or p:sub(1, 1) == "/" then
    local fold = vim.fn.has("win32") == 1 and string.lower or function(x) return x end
    if fold(p:sub(1, #root + 1)) ~= fold(root .. "/") then return nil end
    p = p:sub(#root + 2)
  end
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      if #parts == 0 then return nil end
      table.remove(parts)
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  if #parts == 0 or parts[1] == ".git" then return nil end
  return table.concat(parts, "/")
end

-- The worktrees work item `target` (a plan target, or an id) may have: a
-- GitHub issue's under its key; else <repo>-wi<id>, whichever repository.
function M.story_dirs(target)
  if type(target) == "table" and target.item_key then
    local d = M.story_path(nil, target)
    return is_repo(d) and { d } or {}
  end
  local id = type(target) == "table" and target.work_item_id or target
  local out = {}
  for _, d in ipairs(vim.fn.glob(M.root() .. "/*-wi" .. tostring(id), false, true)) do
    if is_repo(d) then out[#out + 1] = d end
  end
  return out
end

-- Work item `target`'s story worktree (M.story_dirs): dir, branch, the
-- branch it started from when start_story recorded it, and whether the
-- branch existed before start_story (then the change is pushed straight to
-- it, with no PR - #57). <dir>.branch: the branch, its base, "existing".
function M.find_story(target)
  for _, d in ipairs(M.story_dirs(target)) do
    if is_repo(d) then
      local ok, lines = pcall(vim.fn.readfile, d .. ".branch")
      local branch = ok and lines[1] and vim.trim(lines[1]) or ""
      local base = ok and lines[2] and vim.trim(lines[2]) or ""
      local existing = ok and lines[3] and vim.trim(lines[3]) == "existing" or false
      if branch ~= "" then return d, branch, base ~= "" and base or nil, existing end
    end
  end
  return nil
end

-- Adds worktree `wt` of `clone` on branch `name` (its origin/<name> just
-- fetched): a new local branch tracking it, or the local one fast-forwarded
-- to it. When git can't (the branch is out elsewhere, or has commits origin
-- hasn't), a detached worktree at origin/<name> instead. cb(ok, err, note) -
-- note says why it's detached.
function M.add_story_worktree(clone, wt, name, cb, git)
  local remote = "origin/" .. name
  local function detached(why)
    git({ "git", "-C", clone, "worktree", "add", "-q", "--detach", wt, remote }, function(ok, _, err)
      if not ok then return cb(false, err) end
      cb(true, nil, "The worktree is detached at " .. remote .. " (" .. why .. "); commit_and_push_fix still pushes "
        .. "to " .. name .. ".")
    end)
  end
  local function on_branch(argv, why_not)
    git(argv, function(ok, _, err)
      if ok then return cb(true) end
      git({ "git", "-C", clone, "worktree", "prune" }, function() detached(why_not(vim.trim(err or ""))) end)
    end)
  end
  git({ "git", "-C", clone, "rev-parse", "-q", "--verify", "refs/heads/" .. name }, function(has_local)
    if not has_local then
      return on_branch({ "git", "-C", clone, "worktree", "add", "-q", "--track", "-b", name, wt, remote },
        function(err) return "git couldn't make the local branch: " .. err end)
    end
    git({ "git", "-C", clone, "merge-base", "--is-ancestor", "refs/heads/" .. name, remote }, function(behind)
      if not behind then return detached("the local " .. name .. " has commits " .. remote .. " hasn't") end
      -- git refuses to move (or check out) a branch that's out elsewhere.
      git({ "git", "-C", clone, "branch", "-f", name, remote }, function(fok, _, ferr)
        if not fok then return detached("git couldn't move the local " .. name .. ": " .. vim.trim(ferr or "")) end
        on_branch({ "git", "-C", clone, "worktree", "add", "-q", wt, name },
          function(err) return "git couldn't check it out: " .. err end)
      end)
    end)
  end)
end

-- The CI of the pull request behind a change (#51): PR `pr_id` for a fix,
-- else the dashboard's PR from `branch` (a story's). { pr, build, note }, or
-- nil when there's no such PR. Only reported, never waited on.
function M.ci(pr_id, branch)
  local pr = pr_id and require("azure-cli.chat.tools").pr_record(pr_id)
  if not pr and branch then
    for _, p in ipairs((require("azure-cli.state").PR_LIST_CACHE or {}).prs or {}) do
      if p.source == branch then pr = p break end
    end
  end
  if not pr then return nil end
  local build = pr.buildStatus
  return { pr = pr.id, build = (build and build ~= "") and build or "none",
    note = "The PR's CI as the dashboard last saw it. The change isn't done until it passes: get_pull_request "
      .. "reads it fresh, get_build_log says why it failed." }
end

-- The worktree's change: `git add -A -N` first so new files show, then the
-- diff against its base. cb(ok, diff, stat).
function M.diff(wt, cb, git)
  git({ "git", "-C", wt, "add", "-A", "-N" }, function()
    git({ "git", "-C", wt, "diff", "HEAD" }, function(ok, out, err)
      if not ok then return cb(false, err) end
      git({ "git", "-C", wt, "diff", "--stat", "HEAD" }, function(_, stat)
        cb(true, out, stat)
      end)
    end)
  end)
end

-- The change in its own tab, file by file, like a PR in the reviewer.
function M.show(title, dir, diff)
  M.last = { title = title, dir = dir }
  return require("azure-cli.chat.changes").open(title, dir, vim.split(diff, "\n", { plain = true }))
end

-- The change in worktree `dir` for viewing: its uncommitted change, or once
-- that's committed, its last commit. cb(ok, diff_or_err, last_commit).
function M.load(dir, git, cb)
  M.diff(dir, function(ok, diff)
    if not ok then return cb(false, diff) end
    if vim.trim(diff) ~= "" then return cb(true, diff, false) end
    git({ "git", "-C", dir, "diff", "HEAD~1", "HEAD" }, function(cok, out)
      cb(true, cok and out or "", cok)
    end)
  end, git)
end

-- The chat's gd: the change last shown, else the most recently touched fix
-- or story worktree (see M.load). cb(err) when there's none.
function M.open_latest(git, cb)
  local dir, title = M.last and M.last.dir, M.last and M.last.title
  if not (dir and is_repo(dir)) then
    dir, title = nil, nil
    local newest = -1
    for _, d in ipairs(vim.fn.glob(M.root() .. "/*", false, true)) do
      local t = is_repo(d) and vim.fn.getftime(d) or -1
      if t > newest then newest, dir = t, d end
    end
    if not dir then return cb("The agent hasn't started a change yet (start_fix / start_story).") end
    local name = vim.fn.fnamemodify(dir, ":t")
    local wi = name:match("%-wi(%d+)$")
    local key = name:find("~", 1, true) and name:match("^pr%-github%-(.+)$")
    local ikey = name:find("~", 1, true) and name:match("^wi%-github%-(.+)$")
    title = "Proposed change - " .. (wi and ("#" .. wi)
      or (ikey and require("azure-cli.chat.plan").target_label({ item_key = ikey }))
      or (key and require("azure-cli.chat.plan").target_label({ pr_key = key }))
      or ("PR !" .. (name:match("%-(%d+)$") or name)))
  end
  title = title:gsub(" %(last commit%)$", "")
  M.load(dir, git, function(ok, diff, last)
    if not ok then return cb(diff) end
    M.show(title .. (last and " (last commit)" or ""), dir, diff)
    cb(nil)
  end)
end

-- The worktree of the change for `target` ({ work_item_id } / { pr_id,
-- pr_key }), or nil when none was started.
function M.dir_for(target)
  if target.work_item_id then return (M.find_story(target)) end
  local pr = require("azure-cli.chat.tools").pr_record(target.pr_key or target.pr_id)
  local d = pr and M.fix_dir(pr)
  return (d and is_repo(d)) and d or nil
end

-- Opens the change for `target` in the change viewer at `path` (and line
-- `line` of its new version, else its first change): the plan's gd.
-- cb(err) when there's no change to show.
function M.open_at(target, path, line, cb)
  local dir = M.dir_for(target)
  local label = require("azure-cli.chat.plan").target_label(target)
  if not dir then return cb("There's no change for " .. label .. " yet - the agent hasn't started it.") end
  M.load(dir, require("azure-cli.chat.tools").git, function(ok, diff, last)
    if not ok then return cb(diff) end
    M.show("Proposed change - " .. label .. (last and " (last commit)" or ""), dir, diff)
    local found = require("azure-cli.chat.changes").jump_to(path, line)
    cb(not found and (path .. " isn't part of the change.") or nil)
  end)
end

setmetatable(M, { __call = function(_, T)
  local function need_clone(args, done)
    local pr = T.need_pr(args, done)
    if not pr then return nil end
    local clone = T.clone_path(pr)
    if not is_repo(clone) then
      done(nil, "PR !" .. pr.id .. "'s repository isn't cloned locally")
      return nil
    end
    return pr, clone
  end

  -- What show/commit/discard act on: { dir, branch, label, wi, target },
  -- or nil and the reason. `env` (optional) picks the calling agent's own
  -- PR when two share pr_id (#109).
  local function locate(args, env)
    if args.work_item_id then
      local PLAN = require("azure-cli.chat.plan")
      local target = PLAN.item_target_for(args.work_item_id, env)
      local dir, branch = M.find_story(target)
      if not dir then return nil, "no story in progress for " .. PLAN.target_label(target) .. " - call start_story first" end
      return { dir = dir, branch = branch, label = PLAN.target_label(target), wi = args.work_item_id, target = target }
    end
    local target = require("azure-cli.chat.plan").pr_target_for(args.pr_id, env) or { pr_id = args.pr_id }
    local pr = T.pr_record(target.pr_key or args.pr_id)
    if not pr then
      return nil, "PR !" .. tostring(args.pr_id) .. " isn't loaded - call get_pull_request for it first."
    end
    local dir = M.fix_dir(pr)
    if not is_repo(dir) then return nil, "no fix in progress - call start_fix first" end
    return { dir = dir, branch = pr.source, label = "PR !" .. pr.id, target = target }
  end

  -- The plan target of located change `t`.
  local function target_of_change(t)
    return t.target
  end

  local target_schema = { type = "object", properties = {
    pr_id = { type = "integer", description = "for a start_fix change" },
    work_item_id = { type = "integer", description = "for a start_story change" },
  } }

  -- start_story before its plan is approved (#71): a worktree of the branch
  -- the story goes on - origin/<name>, or origin/<from> for a new branch -
  -- for the planner to read the code in. Detached (so a branch out
  -- elsewhere doesn't matter), nothing made on the server, and no
  -- <dir>.branch, so find_story, show_fix and commit_and_push_fix don't
  -- see it. Called again, it moves to the branch's tip when it's clean.
  local function preview(clone, wt, args, done)
    T.git({ "git", "-C", clone, "ls-remote", "--heads", "origin", "refs/heads/" .. args.name }, function(_, heads)
      local branch = vim.trim(heads or "") ~= "" and args.name or args.from
      local ref = "origin/" .. branch
      T.git({ "git", "-C", clone, "fetch", "-q", "origin", branch }, function(fok, _, ferr)
        if not fok then return done(nil, "fetching " .. branch .. " failed: " .. ferr) end
        local function ready(kept)
          T.git({ "git", "-C", wt, "rev-parse", "--short", "HEAD" }, function(_, sha)
            sha = vim.trim(sha or "")
            done({ directory = wt, ref = ref, sha = sha, read_only = true,
              note = "A read-only worktree for planning, detached at " .. ref .. " (" .. sha .. ")"
                .. (kept and ", kept where it was: it has uncommitted changes" or "") .. ". Nothing was created "
                .. "on the server. Read files here with your Read and Grep tools, don't change them, and say in the "
                .. "plan that its line numbers refer to " .. ref .. " @ " .. sha .. ".",
              next = "Write the plan with submit_plan and wait for the user's approval; then call start_story again "
                .. "with the same arguments - this directory becomes the story's worktree." })
          end)
        end
        if is_repo(wt) then
          T.git({ "git", "-C", wt, "status", "--porcelain" }, function(_, st)
            if vim.trim(st or "") ~= "" then return ready(true) end
            T.git({ "git", "-C", wt, "checkout", "-q", "--detach", ref }, function(ok, _, err)
              if not ok then return done(nil, "moving the worktree to " .. ref .. " failed: " .. err) end
              ready()
            end)
          end)
        else
          vim.fn.mkdir(M.root(), "p")
          T.git({ "git", "-C", clone, "worktree", "prune" }, function()
            T.git({ "git", "-C", clone, "worktree", "add", "-q", "--detach", wt, ref }, function(ok, _, err)
              if not ok then return done(nil, "creating the worktree failed: " .. err) end
              ready()
            end)
          end)
        end
      end)
    end)
  end

  -- Removes the planning worktree at `wt`, if there is one, then cont().
  local function clear_preview(clone, wt, done, cont)
    if not is_repo(wt) then return cont() end
    T.git({ "git", "-C", clone, "worktree", "remove", wt }, function(ok, _, err)
      if not ok then
        return done(nil, "the read-only worktree " .. wt .. " from planning has changes, so it wasn't replaced by "
          .. "the story's (" .. vim.trim(err or "") .. "). Ask the user what to do with them.")
      end
      cont()
    end)
  end

  return {
    {
      name = "start_fix",
      description = "Prepares a git worktree of the pull request's source branch, at its latest commit, for "
        .. "changing code (e.g. to address a review comment). Returns the directory: edit files ONLY there, then "
        .. "call show_fix and, when the user agrees, commit_and_push_fix. Runs without asking (nothing leaves the "
        .. "machine until commit_and_push_fix).",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "write",
      run = function(args, env, done)
        local target = require("azure-cli.chat.plan").pr_target_for(args.pr_id, env)
        local refused = require("azure-cli.chat.plan").main_chat_refusal(env, "start_fix", target)
        if refused then return done(nil, refused) end
        -- The PR this agent's own plan opened: its fix is that story's.
        local story = require("azure-cli.chat.plan").plan_target_for(args.pr_id, env)
        if story and not story.pr_id then
          local label, wi = require("azure-cli.chat.plan").target_label(story), tostring(story.work_item_id)
          return done(nil, "PR !" .. tostring(args.pr_id) .. " is the one your plan for " .. label .. " opened: plan "
            .. "the fix as a new revision of that plan (submit_plan with work_item_id " .. wi .. "), then make it in "
            .. "your story's worktree (start_story for " .. label .. " reuses it) and push it with commit_and_push_fix "
            .. "(work_item_id " .. wi .. ") - the PR picks it up")
        end
        local planned, why = require("azure-cli.chat.plan").gate(target)
        if not planned then return done(nil, why) end
        local pr, clone = need_clone(args, done)
        if not pr then return end
        local wt = M.fix_dir(pr)
        local ref = "origin/" .. tostring(pr.source)
        env.log("git fetch " .. pr.source)
        T.git({ "git", "-C", clone, "fetch", "-q", "origin", pr.source }, function(fok, _, ferr)
          if not fok then return done(nil, "fetching " .. pr.source .. " failed: " .. ferr) end
          local function ready(note)
            T.git({ "git", "-C", wt, "rev-parse", "--short", "HEAD" }, function(_, sha)
              done({ directory = wt, branch = pr.source, base = vim.trim(sha), note = note,
                next = "Edit files under the directory, then call show_fix." })
            end)
          end
          if is_repo(wt) then
            T.git({ "git", "-C", wt, "status", "--porcelain" }, function(_, st)
              if vim.trim(st) ~= "" then return ready("It already has uncommitted changes from before - kept as they were.") end
              T.git({ "git", "-C", wt, "checkout", "-q", "--detach", ref }, function(ok, _, err)
                if not ok then return done(nil, "moving the worktree to " .. ref .. " failed: " .. err) end
                ready()
              end)
            end)
          else
            vim.fn.mkdir(M.root(), "p")
            T.git({ "git", "-C", clone, "worktree", "prune" }, function()
              T.git({ "git", "-C", clone, "worktree", "add", "-q", "--detach", wt, ref }, function(ok, _, err)
                if not ok then return done(nil, "creating the worktree failed: " .. err) end
                ready()
              end)
            end)
          end
        end)
      end,
    },
    {
      name = "start_story",
      description = "Starts implementing a work item (user story, bug, task): creates branch `name` from `from` on "
        .. "the server, linked to the work item, and a git worktree on it. Returns the directory: edit files ONLY "
        .. "there, then call show_fix and, when the user agrees, commit_and_push_fix (both with work_item_id), then "
        .. "offer create_pull_request. Ask the user which repository and base branch when they aren't clear; name "
        .. "the branch like feature/<id>-<short-title>. To work on an existing branch itself (e.g. from = name), "
        .. "give its name: no branch is created, the change is pushed straight to it, and no pull request is "
        .. "offered. Calling it again for the same work item reuses the worktree. Before its plan is approved it "
        .. "only gives a read-only worktree of that branch (detached, nothing created on the server) to read the "
        .. "code there while planning; called again once the plan is approved, the same directory becomes the "
        .. "story's worktree. Runs without asking (nothing but the empty branch leaves the machine until commit_and_push_fix). "
        .. "For a GitHub issue (board = \"github\"), the branch is linked to the issue (its Development section).",
      schema = { type = "object", properties = {
        work_item_id = { type = "integer" },
        repo = { type = "string", description = "repository name (owner/repo on GitHub also works)" },
        from = { type = "string", description = "branch to start from, e.g. develop" },
        name = { type = "string", description = "the new branch's name, or an existing branch's to work on it "
          .. "directly; without refs/heads/" },
        board = T.board_props.board,
        item_repo = T.board_props.repo_of_item,
      }, required = { "work_item_id", "repo", "from", "name" } },
      risk = "write",
      run = function(args, env, done)
        local id = args.work_item_id
        local PLAN = require("azure-cli.chat.plan")
        local B = T.board_for(args, env)
        -- A GitHub issue's by its key (#114), the calling agent's own first.
        local target = PLAN.item_target_for(id, env, args.item_repo, B.host)
        local refused = PLAN.main_chat_refusal(env, "start_story", target)
        if refused then return done(nil, refused) end
        local planned, why = PLAN.gate(target)
        -- Not approved yet: a read-only worktree to plan in (#71) - unless
        -- the plan was carried out already, which needs a new one first.
        local rec = not planned and PLAN.load(PLAN.key(target))
        if rec and rec.status == "done" then return done(nil, why) end
        local existing, ebranch = M.find_story(target)
        if existing then
          if not planned then
            return done({ directory = existing, branch = ebranch, read_only = true,
              note = "The story's worktree, started before; its plan isn't approved yet, so read files here but "
                .. "don't change them.",
              next = "Write the plan with submit_plan and wait for the user's approval." })
          end
          return done({ directory = existing, branch = ebranch, note = "Already started - kept as it was.",
            next = "Edit files under the directory, then call show_fix with work_item_id." })
        end
        local org, project, clone, tried = T.repo_location(args.repo, B)
        local repo = tostring(args.repo):match("/(.+)$") or args.repo
        if not is_repo(clone) then
          return done(nil, args.repo .. " isn't cloned locally - "
            .. (#(tried or {}) > 0 and ("looked in " .. table.concat(tried, ", ") .. "; no git repository there")
              or "no clones_dir is known for it")
            .. " (set clones_dir in azure-cli.yml, or open one of its PRs from the dashboard to clone it)")
        end
        local wt = M.story_path(repo, target)
        if not planned then return preview(clone, wt, args, done) end
        local undo
        local function failed(what)
          done(nil, what .. (undo and (" (" .. args.name .. " was created on the server; start_story again uses it)") or ""))
        end
        local function checkout(existing)
          env.log("git fetch " .. args.name)
          T.git({ "git", "-C", clone, "fetch", "-q", "origin", args.name }, function(fok, _, ferr)
            if not fok then return failed("fetching " .. args.name .. " failed: " .. ferr) end
            vim.fn.mkdir(M.root(), "p")
            T.git({ "git", "-C", clone, "worktree", "prune" }, function()
              M.add_story_worktree(clone, wt, args.name, function(ok, err, note)
                if not ok then return failed("creating the worktree failed: " .. err) end
                vim.fn.writefile({ args.name, args.from or "", existing and "existing" or "" }, wt .. ".branch")
                done({ directory = wt, branch = args.name, repo = repo, note = note,
                  existing_branch = existing or nil,
                  next = "Edit files under the directory, then call show_fix with work_item_id."
                    .. (existing and (" It's the existing branch " .. args.name .. ": commit_and_push_fix pushes "
                      .. "straight to it, and there's no pull request to open.") or "") }, nil, undo)
              end, T.git)
            end)
          end)
        end
        -- The read-only worktree planning used (no <dir>.branch, so
        -- find_story didn't take it) gives way to the story's - not forced:
        -- a change made in it stops here rather than being thrown away.
        clear_preview(clone, wt, done, function()
          -- An existing branch (made by hand, or by create_branch) is used as it is.
          T.git({ "git", "-C", clone, "ls-remote", "--heads", "origin", "refs/heads/" .. args.name }, function(_, heads)
            if vim.trim(heads or "") ~= "" then return checkout(true) end
            if args.name == args.from then
              return done(nil, "there's no branch " .. args.name .. " on origin to work on (from and name are the same)")
            end
            T.provider({ "--wi-edit", "create-branch", T.wi_ref(B, id, args.item_repo), org, project, repo, args.from,
              args.name }, B.env,
              function(ok, out, err)
                if not ok then return done(nil, "creating the branch failed: " .. err) end
                local okd, res = pcall(vim.json.decode, out)
                res = okd and type(res) == "table" and res or {}
                undo = { op = "delete_branch", org = org, project = project, repo = repo, name = args.name,
                  sha = res.objectId, board = B.host }
                env.log("created " .. args.name .. " from " .. args.from
                  .. (res.linked and (", linked to #" .. tostring(res.linked)) or "")
                  .. (res.linkError and (" (not linked: " .. res.linkError .. ")") or ""))
                checkout()
              end)
          end)
        end)
      end,
    },
    {
      name = "show_fix",
      description = "Makes the change in the start_fix or start_story directory ready for the user to review (they're "
        .. "told it's waiting on the Agents screen; nothing opens by itself) and returns the diff, plus plan_check "
        .. "when the change and its plan's Files section disagree (files changed that the plan doesn't list, files it "
        .. "lists that weren't changed). Give pr_id for a fix, work_item_id for a story.",
      schema = { type = "object", properties = {
        pr_id = target_schema.properties.pr_id, work_item_id = target_schema.properties.work_item_id,
        steps = { type = "array", description = "optional: which lines of the change carry out which lines of the "
          .. "plan (submit_plan's markdown, 1-based lines), so the user can jump between them",
          items = { type = "object", properties = {
            file = { type = "string" }, line = { type = "integer", description = "line in the file's new version" },
            plan_line = { type = "integer" }, note = { type = "string" },
          }, required = { "file", "line", "plan_line" } } },
      } },
      risk = "read",
      run = function(args, env, done)
        local t, why = locate(args, env)
        if not t then return done(nil, why) end
        local target = target_of_change(t)
        local linked = args.steps and require("azure-cli.chat.plan").set_links(target, args.steps) or nil
        M.diff(t.dir, function(ok, diff, stat)
          if not ok then return done(nil, diff) end
          -- Never opened by itself, not even for the agent in the
          -- foreground (#120): it says it's ready (gd opens M.last), and an
          -- open plan view's Changes section picks the change up.
          M.last = { title = "Proposed change - " .. t.label, dir = t.dir }
          require("azure-cli.shell").notify(t.label .. "'s change is ready for you - the Agents screen opens it.")
          pcall(function() require("azure-cli.chat").alert("azure-vicli: " .. t.label .. "'s change is ready",
            "Waiting for your review on the Agents screen") end)
          pcall(function() require("azure-cli.chat.plan_changes").poke() end)
          -- Its change viewer, when it's open, redrawn where it is (#126).
          pcall(require("azure-cli.chat.changes").refresh, t.dir, { quiet = true })
          -- Against the plan: what it changed that the plan doesn't list,
          -- and what the plan lists that it didn't change.
          local PLAN = require("azure-cli.chat.plan")
          local paths = {}
          for _, f in ipairs(require("azure-cli.chat.changes").files(vim.split(diff, "\n", { plain = true }))) do
            paths[#paths + 1] = f.path
          end
          local check = PLAN.check_change(PLAN.load(PLAN.key(target)), paths)
          local plan_check
          if check and (#check.unplanned > 0 or #check.missing > 0) then
            plan_check = { not_in_plan = check.unplanned, planned_not_changed = check.missing,
              note = "The user sees these flagged next to the change. Say why, or fix it." }
            env.log("! against the plan: " .. #check.unplanned .. " file(s) not in it, "
              .. #check.missing .. " planned file(s) not changed")
          end
          if #diff > 60000 then diff = diff:sub(1, 60000) .. "\n... (cut off)" end
          done({ stat = stat, diff = diff, plan_check = plan_check, steps_linked = linked,
            shown = false, ci = M.ci(args.pr_id, t.branch),
            note = "The change isn't on screen: it waits for the user on the Agents screen - say it's ready, not "
              .. "that you opened it." })
        end, T.git)
      end,
    },
    {
      name = "commit_and_push_fix",
      description = "Commits the start_fix / start_story change with a message and pushes it to its branch (the "
        .. "pull request's source branch, or the story's). Give pr_id for a fix, work_item_id for a story. Asks the "
        .. "user first, showing the diff. If the change is already committed (nothing to commit, HEAD ahead of the "
        .. "branch), it pushes those commits. It only fast-forwards: if the branch has moved, it says so and you "
        .. "rebase onto origin/<branch> and call it again. Never git reset --soft onto a branch HEAD isn't directly "
        .. "on: that silently reverts the commits it doesn't have.",
      schema = { type = "object", properties = { pr_id = target_schema.properties.pr_id,
        work_item_id = target_schema.properties.work_item_id, message = { type = "string" } }, required = { "message" } },
      risk = "ask",
      confirm = function(a)
        local t = locate(a)
        return "commit \"" .. tostring(a.message) .. "\" and push it to "
          .. (t and t.branch or (a.work_item_id and ("#" .. tostring(a.work_item_id)) or ("PR !" .. tostring(a.pr_id))))
      end,
      details = function(a, cb)
        local t = locate(a)
        if not t then return cb(nil) end
        M.diff(t.dir, function(_, diff)
          -- The plan's tests' last run - which one, and whether it was on
          -- this change - above the diff.
          local TR = require("azure-cli.chat.tests_run")
          local function show(shown)
            local lines = vim.split(shown or "", "\n", { plain = true })
            table.insert(lines, 1, TR.describe(TR.load(t.dir), TR.fingerprint(diff or ""),
              { key = require("azure-cli.keys").name("diff", "run_tests"), running = TR.running(t.dir) }))
            table.insert(lines, 2, "")
            cb(lines)
          end
          if vim.trim(diff or "") ~= "" then return show(diff) end
          -- Already committed (#102): what the push takes over origin's tip.
          T.git({ "git", "-C", t.dir, "diff", "refs/remotes/origin/" .. t.branch, "HEAD" }, function(ok, out)
            show(ok and out or diff)
          end)
        end, T.git)
      end,
      preapproved = function(a, cb)
        local t = locate(a)
        if not t then return cb(false) end
        local target = target_of_change(t)
        require("azure-cli.chat.plan").push_allowed(target, t.dir, function(ok, why)
          cb(ok, ok and "the approved plan (pushing allowed, tests passed)" or why)
        end)
      end,
      run = function(args, env, done)
        local t, why = locate(args, env)
        if not t then return done(nil, why) end
        local wt = t.dir
        local remote = "refs/remotes/origin/" .. t.branch
        -- Commits only what's staged: a change the agent already committed
        -- (#102) goes straight to the push.
        local function commit(cb)
          T.git({ "git", "-C", wt, "diff", "--cached", "--quiet" }, function(clean)
            if clean then return cb(false) end
            T.git({ "git", "-C", wt, "commit", "-q", "-m", args.message }, function(cok, cout, cerr)
              if not cok then return done(nil, "commit failed: " .. vim.trim(cerr ~= "" and cerr or cout)) end
              cb(true)
            end)
          end)
        end
        -- Fast-forward only: origin's tip fetched fresh must be under HEAD.
        -- cb() to push; a fetch that fails leaves it to the push itself.
        local function check_target(committed, cb)
          T.git({ "git", "-C", wt, "fetch", "-q", "origin", "+refs/heads/" .. t.branch .. ":" .. remote }, function(fok)
            if not fok then return cb() end
            T.git({ "git", "-C", wt, "rev-parse", "--short", remote }, function(_, tip)
              T.git({ "git", "-C", wt, "rev-parse", "--short", "HEAD" }, function(_, head)
                tip, head = vim.trim(tip or ""), vim.trim(head or "")
                if not committed and tip == head then
                  return done(nil, "nothing to push: no change, and HEAD is already at origin/" .. t.branch
                    .. " (" .. tip .. ")")
                end
                T.git({ "git", "-C", wt, "merge-base", "--is-ancestor", remote, "HEAD" }, function(ff)
                  if ff then return cb() end
                  done(nil, "the target branch moved - rebase onto it first: origin/" .. t.branch .. " is at " .. tip
                    .. ", HEAD " .. head .. " isn't on top of it. Run git rebase origin/" .. t.branch
                    .. ", then call commit_and_push_fix again (never git reset --soft onto it).")
                end)
              end)
            end)
          end)
        end
        T.git({ "git", "-C", wt, "add", "-A" }, function()
          commit(function(committed)
          check_target(committed, function()
            env.log("git push " .. t.branch)
            T.git({ "git", "-C", wt, "push", "-q", "origin", "HEAD:refs/heads/" .. t.branch }, function(pok, _, perr)
              if not pok then
                return done(nil, "push failed (the branch may have moved since): " .. vim.trim(perr or ""):gsub("%s*\n%s*", " "))
              end
              -- The plan behind it is done: the next change needs its own.
              local target = target_of_change(t)
              pcall(require("azure-cli.chat.plan").mark_done, target)
              -- Its reviewers' answers to the fix (chat/watch.lua).
              if not t.wi and args.pr_id then
                pcall(require("azure-cli.chat.watch").add, T.pr_record(target.pr_key or args.pr_id) or { id = args.pr_id })
              end
              T.git({ "git", "-C", wt, "rev-parse", "--short", "HEAD" }, function(_, sha)
                pcall(require("azure-cli.chat.plan").event_for_worktree, wt, "pushed",
                  "Pushed " .. vim.trim(sha) .. " to " .. t.branch .. ": " .. tostring(args.message))
                local PLAN = require("azure-cli.chat.plan")
                local rec = t.wi and PLAN.load(PLAN.key(t.target))
                local base, existing
                if t.wi then base, existing = select(3, M.find_story(t.target)) end
                local next_step = ""
                if existing then
                  -- Worked on an existing branch: pushed straight to it, no PR (#57).
                  next_step = " " .. t.branch .. " is the existing branch the story works on: the change is on it "
                    .. "now, and there's no pull request to open."
                elseif rec and rec.allow_push and rec.pr == nil then
                  next_step = " The approved plan lets you open its pull request without asking: call "
                    .. "create_pull_request now - source " .. t.branch .. ", target " .. (base or "the branch you started from")
                    .. ", work_item_ids [" .. t.wi .. "], no description (the plan's is used), not a draft."
                elseif t.wi and not (rec and rec.pr) then
                  next_step = " Offer to open a pull request for it (create_pull_request, linking the work item)."
                end
                -- CI runs on what was just pushed: not done until it passes.
                local ci = M.ci(args.pr_id, t.branch)
                local ci_step = ci and (" CI on PR !" .. tostring(ci.pr) .. " now runs on " .. vim.trim(sha)
                  .. " (it was " .. ci.build .. " before this push): it isn't done until that passes - check "
                  .. "get_pull_request, and get_build_log if it fails, before calling it done.")
                  or " If this branch has a pull request, its CI now runs on it: check it passes before calling it done."
                done("Pushed " .. vim.trim(sha) .. " to " .. t.branch .. " (" .. t.label .. ")." .. ci_step .. next_step)
              end)
            end)
          end)
          end)
        end)
      end,
    },
    {
      name = "run_tests",
      description = "Runs the tests on the start_fix / start_story change, in its directory: the user's own test "
        .. "command for the repository when they set one, else the command in your plan's Test plan section (a "
        .. "```sh block), or `command`. Asks the user first, showing the command (not for their own, nor for an "
        .. "approved plan's). "
        .. "Returns the exit code and the end of the output. Give pr_id for a fix, work_item_id for a story.",
      schema = { type = "object", properties = { pr_id = target_schema.properties.pr_id,
        work_item_id = target_schema.properties.work_item_id,
        command = { type = "string", description = "instead of the plan's" } } },
      risk = "ask",
      confirm = function(a)
        local t = locate(a)
        local PLAN = require("azure-cli.chat.plan")
        local cmd = a.command or (t and require("azure-cli.chat.tests_run").command(t.dir, PLAN.for_worktree(t.dir)))
        return "run `" .. tostring(cmd or "?") .. "` in " .. (t and vim.fn.fnamemodify(t.dir, ":t") or "the worktree")
      end,
      -- The user's own command (chat.test_cmd) needs no question, nor does
      -- the Test plan command of a plan you approved.
      preapproved = function(a, cb)
        local t = locate(a)
        if a.command or not t then return cb(false) end
        local rec = require("azure-cli.chat.plan").for_worktree(t.dir)
        local _, source = require("azure-cli.chat.tests_run").command(t.dir, rec)
        if source == "plan" then
          return cb(rec.status == "approved", rec.status == "approved" and "the approved plan's Test plan" or nil)
        end
        cb(source == "config", source == "config" and "your chat.test_cmd" or nil)
      end,
      run = function(args, env, done)
        local t, why = locate(args, env)
        if not t then return done(nil, why) end
        local PLAN = require("azure-cli.chat.plan")
        local TR = require("azure-cli.chat.tests_run")
        local cmd = args.command or TR.command(t.dir, PLAN.for_worktree(t.dir))
        if not cmd then return done(nil, "no test command: put one in the plan's Test plan section as a ```sh block, or pass command") end
        M.diff(t.dir, function(_, diff)
          env.log("$ " .. cmd)
          TR.run(t.dir, cmd, TR.fingerprint(diff or ""), function(r, err)
            if not r then return done(nil, err) end
            pcall(require("azure-cli.chat.changes").refresh, t.dir, { quiet = true })
            done({ exit_code = r.code, passed = r.code == 0, timed_out = r.timed_out, seconds = r.seconds,
              output = table.concat(TR.tail(r.output, 80), "\n") })
          end, { by = "agent" })
        end, T.git)
      end,
    },
    {
      name = "delete_fix_file",
      description = "Deletes a file in the start_fix or start_story directory (your own file tools can't delete). "
        .. "`path` is relative to that directory (or absolute inside it); anything outside it is refused. The "
        .. "deletion is part of the change show_fix shows and commit_and_push_fix commits. Give pr_id for a fix, "
        .. "work_item_id for a story. Runs without asking.",
      schema = { type = "object", properties = { pr_id = target_schema.properties.pr_id,
        work_item_id = target_schema.properties.work_item_id, path = { type = "string" } }, required = { "path" } },
      risk = "write",
      run = function(args, env, done)
        local t, why = locate(args, env)
        if not t then return done(nil, why) end
        local rel = M.inside(t.dir, args.path)
        if not rel then return done(nil, tostring(args.path) .. " isn't inside " .. t.dir .. " - refused") end
        local full = t.dir .. "/" .. rel
        -- Not through a symlinked directory that leads out of it either.
        local parent = vim.fn.resolve(vim.fn.fnamemodify(full, ":h"))
        local root = vim.fn.resolve(t.dir)
        if parent ~= root and not M.inside(root, parent) then
          return done(nil, tostring(args.path) .. " leads outside " .. t.dir .. " - refused")
        end
        if vim.fn.isdirectory(full) == 1 then return done(nil, rel .. " is a directory - delete its files one by one") end
        if vim.fn.filereadable(full) == 0 and vim.fn.getftype(full) == "" then return done(nil, rel .. " doesn't exist") end
        -- A tracked file through git (so it shows as deleted), an untracked
        -- one - the agent's own new file - simply removed.
        T.git({ "git", "-C", t.dir, "ls-files", "--error-unmatch", "--", rel }, function(tracked)
          local function finish(ok, err)
            if not ok then return done(nil, "deleting " .. rel .. " failed: " .. tostring(err)) end
            pcall(function() require("azure-cli.chat.plan_changes").poke() end)
            done("Deleted " .. rel .. " (" .. t.label .. ").")
          end
          if tracked then
            T.git({ "git", "-C", t.dir, "rm", "-q", "-f", "--", rel }, function(ok, _, err) finish(ok, err) end)
          else
            finish(vim.fn.delete(full) == 0, "could not remove the file")
          end
        end)
      end,
    },
    {
      name = "discard_fix",
      description = "Throws away the uncommitted change in the start_fix or start_story directory. Give pr_id for "
        .. "a fix, work_item_id for a story.",
      schema = target_schema,
      risk = "write",
      run = function(args, env, done)
        local t, why = locate(args, env)
        if not t then return done(why) end
        local wt = t.dir
        T.git({ "git", "-C", wt, "reset", "-q", "--hard" }, function()
          T.git({ "git", "-C", wt, "clean", "-q", "-fd" }, function()
            done("Discarded the change for " .. t.label .. ".")
          end)
        end)
      end,
    },
  }
end })

return M
