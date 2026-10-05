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
--
-- show/commit/discard take pr_id for a PR's fix, work_item_id for a story.
--
-- Returns function(T) -> list of tools, T being chat/tools.lua.
local M = {}

function M.root()
  return vim.fn.stdpath("cache") .. "/azure-cli/fix-worktrees"
end

-- The worktree for PR `pr`: <root>/<repo>-<id>.
function M.path(pr)
  return M.root() .. "/" .. (tostring(pr.repo or "repo") .. "-" .. tostring(pr.id)):gsub("[^%w%._%-]", "_")
end

local function is_repo(p)
  return p ~= "" and (vim.fn.isdirectory(p .. "/.git") == 1 or vim.fn.filereadable(p .. "/.git") == 1)
end

-- The worktree for work item `id` in repository `repo`: <root>/<repo>-wi<id>.
-- Its branch is kept next to it in <dir>.branch (the worktree's HEAD is
-- detached, like a fix's, so the user's clone may have the branch out too).
function M.story_path(repo, id)
  return M.root() .. "/" .. (tostring(repo) .. "-wi" .. tostring(id)):gsub("[^%w%._%-]", "_")
end

-- Work item `id`'s story worktree, whichever repository: dir, branch.
function M.find_story(id)
  for _, d in ipairs(vim.fn.glob(M.root() .. "/*-wi" .. tostring(id), false, true)) do
    if is_repo(d) then
      local ok, lines = pcall(vim.fn.readfile, d .. ".branch")
      local branch = ok and lines[1] and vim.trim(lines[1]) or ""
      if branch ~= "" then return d, branch end
    end
  end
  return nil
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

-- The chat's gd: the change last shown, else the most recently touched fix
-- or story worktree. cb(err) when there's none.
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
    title = "Proposed change - " .. (wi and ("#" .. wi) or ("PR !" .. (name:match("%-(%d+)$") or name)))
  end
  M.diff(dir, function(ok, diff)
    if not ok then return cb(diff) end
    M.show(title, dir, diff)
    cb(nil)
  end, git)
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

  -- What show/commit/discard act on: { dir, branch, label, wi }, or nil and
  -- the reason.
  local function locate(args)
    if args.work_item_id then
      local dir, branch = M.find_story(args.work_item_id)
      if not dir then return nil, "no story in progress for #" .. tostring(args.work_item_id) .. " - call start_story first" end
      return { dir = dir, branch = branch, label = "#" .. tostring(args.work_item_id), wi = args.work_item_id }
    end
    local pr = T.pr_record(args.pr_id)
    if not pr then
      return nil, "PR #" .. tostring(args.pr_id) .. " isn't in the user's pull request list (open the PR dashboard to load it)."
    end
    if not is_repo(M.path(pr)) then return nil, "no fix in progress - call start_fix first" end
    return { dir = M.path(pr), branch = pr.source, label = "PR !" .. pr.id }
  end

  local target_schema = { type = "object", properties = {
    pr_id = { type = "integer", description = "for a start_fix change" },
    work_item_id = { type = "integer", description = "for a start_story change" },
  } }

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
        local pr, clone = need_clone(args, done)
        if not pr then return end
        local wt = M.path(pr)
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
        .. "the server, linked to the work item, and a git worktree of it. Returns the directory: edit files ONLY "
        .. "there, then call show_fix and, when the user agrees, commit_and_push_fix (both with work_item_id), then "
        .. "offer create_pull_request. Ask the user which repository and base branch when they aren't clear; name "
        .. "the branch like feature/<id>-<short-title>. Calling it again for the same work item reuses the worktree. "
        .. "Runs without asking (nothing but the empty branch leaves the machine until commit_and_push_fix).",
      schema = { type = "object", properties = {
        work_item_id = { type = "integer" },
        repo = { type = "string", description = "repository name" },
        from = { type = "string", description = "branch to start from, e.g. develop" },
        name = { type = "string", description = "the new branch's name, without refs/heads/" },
      }, required = { "work_item_id", "repo", "from", "name" } },
      risk = "write",
      run = function(args, env, done)
        local id = args.work_item_id
        local existing, ebranch = M.find_story(id)
        if existing then
          return done({ directory = existing, branch = ebranch, note = "Already started - kept as it was.",
            next = "Edit files under the directory, then call show_fix with work_item_id." })
        end
        local org, project, clone = T.repo_location(args.repo)
        if not is_repo(clone) then
          return done(nil, args.repo .. " isn't cloned locally (clones_dir in azure-cli.yml, or open one of its PRs "
            .. "from the dashboard to clone it)")
        end
        local wt = M.story_path(args.repo, id)
        local undo
        local function failed(what)
          done(nil, what .. (undo and (" (" .. args.name .. " was created on the server; start_story again uses it)") or ""))
        end
        local function checkout()
          env.log("git fetch " .. args.name)
          T.git({ "git", "-C", clone, "fetch", "-q", "origin", args.name }, function(fok, _, ferr)
            if not fok then return failed("fetching " .. args.name .. " failed: " .. ferr) end
            vim.fn.mkdir(M.root(), "p")
            T.git({ "git", "-C", clone, "worktree", "prune" }, function()
              T.git({ "git", "-C", clone, "worktree", "add", "-q", "--detach", wt, "origin/" .. args.name }, function(ok, _, err)
                if not ok then return failed("creating the worktree failed: " .. err) end
                vim.fn.writefile({ args.name }, wt .. ".branch")
                done({ directory = wt, branch = args.name, repo = args.repo,
                  next = "Edit files under the directory, then call show_fix with work_item_id." }, nil, undo)
              end)
            end)
          end)
        end
        -- An existing branch (made by hand, or by create_branch) is used as it is.
        T.git({ "git", "-C", clone, "ls-remote", "--heads", "origin", "refs/heads/" .. args.name }, function(_, heads)
          if vim.trim(heads or "") ~= "" then return checkout() end
          T.provider({ "--wi-edit", "create-branch", tostring(id), org, project, args.repo, args.from, args.name }, nil,
            function(ok, out, err)
              if not ok then return done(nil, "creating the branch failed: " .. err) end
              local okd, res = pcall(vim.json.decode, out)
              res = okd and type(res) == "table" and res or {}
              undo = { op = "delete_branch", org = org, project = project, repo = args.repo, name = args.name,
                sha = res.objectId }
              env.log("created " .. args.name .. " from " .. args.from
                .. (res.linked and (", linked to #" .. tostring(res.linked)) or ""))
              checkout()
            end)
        end)
      end,
    },
    {
      name = "show_fix",
      description = "Shows the user the change made in the start_fix or start_story directory (in a tab, file by file) and "
        .. "returns the diff. Give pr_id for a fix, work_item_id for a story.",
      schema = target_schema,
      risk = "read",
      run = function(args, _, done)
        local t, why = locate(args)
        if not t then return done(nil, why) end
        M.diff(t.dir, function(ok, diff, stat)
          if not ok then return done(nil, diff) end
          M.show("Proposed change - " .. t.label, t.dir, diff)
          if #diff > 60000 then diff = diff:sub(1, 60000) .. "\n... (cut off)" end
          done({ stat = stat, diff = diff })
        end, T.git)
      end,
    },
    {
      name = "commit_and_push_fix",
      description = "Commits the start_fix / start_story change with a message and pushes it to its branch (the "
        .. "pull request's source branch, or the story's). Give pr_id for a fix, work_item_id for a story. Asks the "
        .. "user first, showing the diff.",
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
        M.diff(t.dir, function(_, diff) cb(vim.split(diff or "", "\n", { plain = true })) end, T.git)
      end,
      run = function(args, env, done)
        local t, why = locate(args)
        if not t then return done(nil, why) end
        local wt = t.dir
        T.git({ "git", "-C", wt, "add", "-A" }, function()
          T.git({ "git", "-C", wt, "commit", "-q", "-m", args.message }, function(cok, cout, cerr)
            if not cok then return done(nil, "commit failed: " .. (cerr ~= "" and cerr or cout)) end
            env.log("git push " .. t.branch)
            T.git({ "git", "-C", wt, "push", "-q", "origin", "HEAD:refs/heads/" .. t.branch }, function(pok, _, perr)
              if not pok then
                return done(nil, "push failed (the branch may have moved since): " .. perr)
              end
              T.git({ "git", "-C", wt, "rev-parse", "--short", "HEAD" }, function(_, sha)
                done("Pushed " .. vim.trim(sha) .. " to " .. t.branch .. " (" .. t.label .. ")."
                  .. (t.wi and " Offer to open a pull request for it (create_pull_request, linking the work item)." or ""))
              end)
            end)
          end)
        end)
      end,
    },
    {
      name = "discard_fix",
      description = "Throws away the uncommitted change in the start_fix or start_story directory. Give pr_id for "
        .. "a fix, work_item_id for a story.",
      schema = target_schema,
      risk = "write",
      run = function(args, _, done)
        local t, why = locate(args)
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
