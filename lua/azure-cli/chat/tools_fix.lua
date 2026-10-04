-- lua/azure-cli/chat/tools_fix.lua: "fix this comment" end to end.
--
--   start_fix            a git worktree of the PR's source branch, under
--                        stdpath("cache")/azure-cli/fix-worktrees/ ({fix_root}
--                        in the agent's command), at its current tip - the
--                        agent edits files there with its own tools, never
--                        in the user's checkout
--   show_fix             the change so far, shown to the user in a diff float
--                        and returned to the agent
--   commit_and_push_fix  commits it and pushes it to the PR's branch - asks
--                        first, showing the diff
--   discard_fix          throws the change away
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

-- The diff in a float, for the user to read.
function M.show(title, diff)
  local lines = vim.split(diff ~= "" and diff or "(no changes yet)", "\n", { plain = true })
  local win, buf = require("azure-cli.ui").open_float(lines, { big = true, title = title, focus = false })
  if buf then vim.bo[buf].filetype = "diff" end
  return win
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
      name = "show_fix",
      description = "Shows the user the change made in the start_fix directory (a diff window) and returns the diff.",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "read",
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local wt = M.path(pr)
        if not is_repo(wt) then return done(nil, "no fix in progress - call start_fix first") end
        M.diff(wt, function(ok, diff, stat)
          if not ok then return done(nil, diff) end
          M.show("Proposed change - PR !" .. pr.id, diff)
          if #diff > 60000 then diff = diff:sub(1, 60000) .. "\n... (cut off)" end
          done({ stat = stat, diff = diff })
        end, T.git)
      end,
    },
    {
      name = "commit_and_push_fix",
      description = "Commits the start_fix change with a message and pushes it to the pull request's source "
        .. "branch. Asks the user first, showing the diff.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, message = { type = "string" } },
        required = { "pr_id", "message" } },
      risk = "ask",
      confirm = function(a) return "commit \"" .. tostring(a.message) .. "\" and push it to PR !" .. tostring(a.pr_id) .. "'s branch" end,
      details = function(a, cb)
        local pr = T.pr_record(a.pr_id)
        if not pr or not is_repo(M.path(pr)) then return cb(nil) end
        M.diff(M.path(pr), function(_, diff) cb(vim.split(diff or "", "\n", { plain = true })) end, T.git)
      end,
      run = function(args, env, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local wt = M.path(pr)
        if not is_repo(wt) then return done(nil, "no fix in progress - call start_fix first") end
        T.git({ "git", "-C", wt, "add", "-A" }, function()
          T.git({ "git", "-C", wt, "commit", "-q", "-m", args.message }, function(cok, cout, cerr)
            if not cok then return done(nil, "commit failed: " .. (cerr ~= "" and cerr or cout)) end
            env.log("git push " .. pr.source)
            T.git({ "git", "-C", wt, "push", "-q", "origin", "HEAD:refs/heads/" .. pr.source }, function(pok, _, perr)
              if not pok then
                return done(nil, "push failed (the branch may have moved - start_fix again to rebase onto it): " .. perr)
              end
              T.git({ "git", "-C", wt, "rev-parse", "--short", "HEAD" }, function(_, sha)
                done("Pushed " .. vim.trim(sha) .. " to " .. pr.source .. " (PR !" .. pr.id .. ").")
              end)
            end)
          end)
        end)
      end,
    },
    {
      name = "discard_fix",
      description = "Throws away the uncommitted change in the start_fix directory.",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "write",
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local wt = M.path(pr)
        if not is_repo(wt) then return done("There was no fix in progress.") end
        T.git({ "git", "-C", wt, "reset", "-q", "--hard" }, function()
          T.git({ "git", "-C", wt, "clean", "-q", "-fd" }, function()
            done("Discarded the change for PR !" .. pr.id .. ".")
          end)
        end)
      end,
    },
  }
end })

return M
