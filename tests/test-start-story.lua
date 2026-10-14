-- test-start-story.lua: start_story (chat/tools_fix.lua) against a real
-- scratch origin and clone in the sandbox, the provider stubbed:
--   #59 the worktree is on the branch (existing or new), detached only when
--       git can't put it there, and says why;
--   #64 the clone is found from the config's clones_dir (--boards) before
--       the PR list has loaded, and the error names where it looked;
--   #57 a story on an existing branch is pushed straight to it: no PR step,
--       and create_pull_request isn't preapproved for it.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-start-story.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

for k, v in pairs({ GIT_AUTHOR_NAME = "t", GIT_AUTHOR_EMAIL = "t@x", GIT_COMMITTER_NAME = "t",
  GIT_COMMITTER_EMAIL = "t@x", GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = "/dev/null" }) do
  vim.env[k] = v
end
local function sh(argv)
  local out = vim.fn.system(argv)
  assert(vim.v.shell_error == 0, table.concat(argv, " ") .. ": " .. out)
  return vim.trim(out)
end

local tmp = vim.fn.tempname()
local origin, seed, clones = tmp .. "/origin.git", tmp .. "/seed", tmp .. "/clones"
vim.fn.mkdir(clones, "p")
sh({ "git", "init", "-q", "--bare", "-b", "main", origin })
sh({ "git", "clone", "-q", origin, seed })
vim.fn.writefile({ "one" }, seed .. "/a.txt")
sh({ "git", "-C", seed, "add", "-A" })
sh({ "git", "-C", seed, "commit", "-q", "-m", "one" })
sh({ "git", "-C", seed, "push", "-q", "origin", "HEAD:refs/heads/main", "HEAD:refs/heads/host" })
local clone = clones .. "/repo"
sh({ "git", "clone", "-q", origin, clone })

local ST = require("azure-cli.state")
local T = require("azure-cli.chat.tools")
local FIX = require("azure-cli.chat.tools_fix")
local PLAN = require("azure-cli.chat.plan")
require("azure-cli.config").setup({ chat = { plan_first = false } })
ST.PR_LIST_CACHE = { prs = {} }  -- the PR list hasn't loaded
ST.BOARDS = { workItems = false, azureClonesDir = "",
  issues = { { owner = "o", project = "1", apiUrl = "https://api.github.com", clonesDir = clones } } }

-- create-branch: makes the branch on origin, as the server would.
local created = {}
T.provider = function(argv, _, cb)
  if argv[2] == "create-branch" then
    local from, name = argv[#argv - 1], argv[#argv]
    created[#created + 1] = name
    sh({ "git", "-C", seed, "push", "-q", "origin", "refs/remotes/origin/" .. from .. ":refs/heads/" .. name })
    return cb(true, vim.json.encode({ objectId = "x" }), "")
  end
  cb(false, "", "unexpected " .. table.concat(argv, " "))
end
sh({ "git", "-C", seed, "fetch", "-q" })

local env = { log = function() end, view = function() return { board = "github" } end }
local function call(name, args)
  local res, err, finished
  T.by_name[name].run(args, env, function(r, e) res, err, finished = r, e, true end)
  vim.wait(10000, function() return finished end, 10)
  return res, err
end
local function head(dir) return vim.fn.system({ "git", "-C", dir, "symbolic-ref", "-q", "--short", "HEAD" }):gsub("%s+$", "") end

-- #64: no PR list, the clone found from the config's clones_dir.
do
  local _, _, path, tried = T.repo_location("o/repo", require("azure-cli.workitems.board").get("github"))
  check("#64 repo_location: clones_dir from --boards before the PR list loads", path == clone, path)
  check("#64 repo_location: says where it looked", tried[1] and tried[1]:find(clone, 1, true)
    and tried[1]:find("azure-cli.yml", 1, true), vim.inspect(tried))
end

-- #59: an existing branch is checked out, not detached; #57: no PR.
do
  local res, err = call("start_story", { work_item_id = 1, repo = "o/repo", from = "host", name = "host", board = "github" })
  check("#59 existing branch: started", res and res.directory, err)
  local wt = res and res.directory or ""
  check("#59 existing branch: the worktree is on it", head(wt) == "host", head(wt))
  check("#59 existing branch: no branch created", #created == 0, vim.inspect(created))
  check("#57 existing branch: start_story says no PR", res and res.existing_branch == true
    and res.next:find("no pull request", 1, true), vim.inspect(res))
  local _, branch, base, existing = FIX.find_story(1)
  check("#57 find_story: knows it's an existing branch", branch == "host" and base == "host" and existing == true)

  vim.fn.writefile({ "two" }, wt .. "/a.txt")
  local out, perr = call("commit_and_push_fix", { work_item_id = 1, message = "two" })
  check("#59 push: fast-forwards the branch on origin", out and sh({ "git", "-C", origin, "rev-parse", "host" })
    == sh({ "git", "-C", wt, "rev-parse", "HEAD" }), perr)
  check("#57 push: no create_pull_request step", type(out) == "string" and not out:find("create_pull_request", 1, true)
    and out:find("no pull request to open", 1, true), out)

  PLAN.save({ key = "wi-1", target = { work_item_id = 1 }, status = "done", allow_push = true, revisions = {}, threads = {} })
  local ok, why
  PLAN.pr_allowed({ work_item_ids = { 1 }, source = "host", target = "host" }, function(o, w) ok, why = o, w end)
  check("#57 pr_allowed: refuses for an existing branch", ok == false and tostring(why):find("existing branch", 1, true), why)
end

-- #59: a new branch is made and checked out, tracking origin.
do
  local res, err = call("start_story", { work_item_id = 2, repo = "o/repo", from = "main", name = "feature/2-x", board = "github" })
  local wt = res and res.directory or ""
  check("#59 new branch: created and checked out", #created == 1 and head(wt) == "feature/2-x", err or head(wt))
  check("#59 new branch: tracks origin", vim.trim(vim.fn.system({ "git", "-C", wt, "rev-parse", "--abbrev-ref", "@{u}" }))
    == "origin/feature/2-x")
  check("#57 new branch: not marked existing", select(4, FIX.find_story(2)) == false)
end

-- #59: the branch is out in the user's clone: detached, and it says why.
do
  sh({ "git", "-C", seed, "push", "-q", "origin", "refs/remotes/origin/main:refs/heads/busy" })
  sh({ "git", "-C", clone, "fetch", "-q" })
  sh({ "git", "-C", clone, "checkout", "-q", "busy" })
  local res, err = call("start_story", { work_item_id = 3, repo = "o/repo", from = "busy", name = "busy", board = "github" })
  local wt = res and res.directory or ""
  check("#59 branch out elsewhere: falls back to detached", res and head(wt) == "", err or head(wt))
  check("#59 branch out elsewhere: the note says why", res and type(res.note) == "string"
    and res.note:find("detached", 1, true) and res.note:find("busy", 1, true), vim.inspect(res))
  sh({ "git", "-C", clone, "checkout", "-q", "main" })
end

-- from = name, but no such branch: an error, not a branch from itself.
do
  local res, err = call("start_story", { work_item_id = 4, repo = "o/repo", from = "nope", name = "nope", board = "github" })
  check("#57 from = name, no such branch: refused", res == nil and tostring(err):find("no branch nope", 1, true), err)
end

-- #64: not cloned - the error names the path it tried.
do
  ST.BOARDS.issues[1].clonesDir = tmp .. "/elsewhere"
  local res, err = call("start_story", { work_item_id = 5, repo = "o/repo", from = "main", name = "f", board = "github" })
  check("#64 not cloned: the error names the path", res == nil and tostring(err):find(tmp .. "/elsewhere/repo", 1, true)
    and tostring(err):find("no git repository there", 1, true), err)
  ST.BOARDS.issues[1].clonesDir = ""
  res, err = call("start_story", { work_item_id = 5, repo = "o/repo", from = "main", name = "f", board = "github" })
  check("#64 no clones_dir at all: says so", res == nil and tostring(err):find("no clones_dir is known", 1, true), err)
end

vim.fn.delete(tmp, "rf")
if fails > 0 then
  print(fails .. " start_story test(s) failed")
  vim.cmd("cquit 1")
end
print("all start_story tests passed")
vim.cmd("qa!")
