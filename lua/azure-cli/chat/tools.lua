-- lua/azure-cli/chat/tools.lua: the tools the chat agent can call (through
-- `azure-cli.py --mcp` and chat/bridge.lua).
--
-- Reads answer straight away. Writes come in two kinds, set by the user's
-- choice for this feature: low-risk ones run directly and are reported in
-- the chat (linking a PR and a work item, creating a branch, drafting a
-- reply or comment - a draft only lands in the PR's batch-review queue, gS
-- still sends it); the rest - voting, changing a work item's state - ask in
-- Neovim first, and a "no" is returned to the agent as the tool's answer.
--
-- Every tool is { name, description, schema (JSON Schema for arguments),
-- risk = "read"|"write"|"ask", run = function(args, env, done) }, where
-- done(result) answers with a table (sent as JSON) or a string, and
-- done(nil, err) reports a failure. `env` is chat/init.lua's: main_win()
-- (the window the user was last in), log(line) (a line in the chat
-- transcript), confirm(question, cb).
local M = {}

local function STATE() return require("azure-cli.state") end
local function CONFIG() return require("azure-cli.config") end

-- ---------------------------------------------------------------------------
-- Helpers.

function M.pr_record(id)
  local cache = STATE().PR_LIST_CACHE
  for _, p in ipairs((cache and cache.prs) or {}) do
    if tostring(p.id) == tostring(id) then return p end
  end
  local cur = STATE().PR_CURRENT
  if cur and tostring(cur.id) == tostring(id) then return cur end
  return nil
end
local pr_record = M.pr_record

-- Where the PR's repository is cloned: <clones_dir>/<repo> (the
-- dashboard's rule), else AZVICLI_REPO_PATH. "" when neither.
function M.clone_path(pr)
  local dir = ((pr and pr.clonesDir) or ""):gsub("\\", "/"):gsub("^/([a-zA-Z])/", "%1:/")
  if dir ~= "" and pr.repo and pr.repo ~= "" then return dir .. "/" .. pr.repo end
  return ((vim.env.AZVICLI_REPO_PATH or ""):gsub("^/([a-zA-Z])/", "%1:/"))
end

-- Repository `repo`'s org, project and local clone: from a PR in that
-- repository when there is one, else the work-item account's org/project
-- and <clones_dir>/<repo> from any PR (one clones_dir per account).
function M.repo_location(repo)
  local org, project, clone, dir = "", "", "", nil
  for _, p in ipairs((STATE().PR_LIST_CACHE or {}).prs or {}) do
    if p.repo == repo then return p.org or "", p.project or "", M.clone_path(p) end
    dir = dir or (p.clonesDir ~= "" and p.clonesDir or nil)
  end
  org, project = vim.env.AZVICLI_WI_COLLECTION or "", vim.env.AZVICLI_WI_PROJECT or ""
  if dir then clone = M.clone_path({ clonesDir = dir, repo = repo }) end
  return org, project, clone
end

function M.pr_env(pr)
  return {
    AZVICLI_PR = tostring(pr.id), AZVICLI_REPO = pr.repo or "", AZVICLI_PROJECT = pr.project or "",
    AZVICLI_ORG = pr.org or "", AZVICLI_SOURCE = pr.source or "", AZVICLI_TARGET = pr.target or "",
    AZVICLI_REPO_PATH = M.clone_path(pr),
  }
end

local pr_env = M.pr_env

function M.need_pr(args, done)
  local pr = M.pr_record(args.pr_id)
  if not pr then
    done(nil, "PR #" .. tostring(args.pr_id) .. " isn't in the user's pull request list (open the PR dashboard to load it).")
  end
  return pr
end

local need_pr = M.need_pr

-- Runs a provider subcommand: cb(ok, stdout_text, err_text).
function M.provider(argv, env, cb)
  local out, err = {}, {}
  local full = CONFIG().provider_argv()
  vim.list_extend(full, argv)
  require("azure-cli.rpc").run(full, {
    env = env, stdout_buffered = true, stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        cb(code == 0, table.concat(out, "\n"), table.concat(vim.tbl_filter(function(l) return l ~= "" end, err), "\n"))
      end)
    end,
  })
end

local provider = M.provider

function M.git(argv, cb)
  local out, err = {}, {}
  local ok, job = pcall(vim.fn.jobstart, argv, {
    stdout_buffered = true, stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function() cb(code == 0, table.concat(out, "\n"), table.concat(err, "\n")) end)
    end,
  })
  if not ok or job <= 0 then vim.schedule(function() cb(false, "", "could not run git") end) end
end

local git = M.git

-- The provider's --threads JSON as a plain list - system comments and
-- deleted threads/comments dropped, the code anchor flattened. Pure.
function M.simplify_threads(decoded)
  local out = {}
  local list = type(decoded) == "table" and (decoded.value or decoded) or {}
  for _, t in ipairs(type(list) == "table" and list or {}) do
    if type(t) == "table" and t.isDeleted ~= true then
      local comments = {}
      for _, c in ipairs(type(t.comments) == "table" and t.comments or {}) do
        if type(c) == "table" and c.commentType ~= "system" and c.isDeleted ~= true
            and type(c.content) == "string" and c.content:match("%S") then
          comments[#comments + 1] = {
            id = c.id, author = type(c.author) == "table" and c.author.displayName or "?",
            date = c.publishedDate, content = c.content,
          }
        end
      end
      if #comments > 0 then
        local th = { id = t.id, status = t.status, comments = comments }
        local tc = type(t.threadContext) == "table" and t.threadContext or nil
        if tc and type(tc.filePath) == "string" then
          th.file = tc.filePath:gsub("^/", "")
          local s, side = tc.rightFileStart, "R"
          if type(s) ~= "table" then s, side = tc.leftFileStart, "L" end
          if type(s) == "table" and s.line then th.side, th.line = side, s.line end
        end
        out[#out + 1] = th
      end
    end
  end
  return out
end

-- A PR record cut down to what an agent needs.
local function pr_summary(p, full)
  local s = {
    id = p.id, title = p.title, repo = p.repo, author = p.author, section = p.state,
    source = p.source, target = p.target, votes = p.voteRatio, is_draft = p.isDraft,
    build = p.buildStatus, merge_conflict = p.mergeConflict, active_threads = p.activeThreads,
    total_threads = p.totalThreads, updated = p.updatedHuman,
  }
  if full then
    s.description, s.url, s.org, s.project = p.description, p.url, p.org, p.project
    s.reviewers = {}
    for _, r in ipairs(type(p.reviewers) == "table" and p.reviewers or {}) do
      s.reviewers[#s.reviewers + 1] = { name = r.name, vote = r.vote }
    end
    s.missing_reviewers, s.auto_complete = p.missingReviewers, p.autoComplete
  end
  return s
end

-- Puts `item` (review/batch.lua's shape) in PR `pr_id`'s batch-review queue
-- and turns batch mode on: through the live reviewer when that PR is open
-- (so it shows at once, tagged "(queued)"), else straight into
-- STATE.batch, where the reviewer picks it up when the PR is opened.
function M.queue_draft(pr_id, item)
  local st = STATE()
  local live = st.batch_live and st.batch_live[tostring(pr_id)]
  if live and live(item) then return end
  st.batch = st.batch or {}
  local s = st.batch[tostring(pr_id)]
  if not s then
    s = { on = false, items = {} }
    st.batch[tostring(pr_id)] = s
  end
  s.on = true
  table.insert(s.items, item)
end

local queue_draft = M.queue_draft

-- Takes a queued draft back out (the undo of draft_reply/draft_comment):
-- through the live reviewer when that PR is open, else straight out of
-- STATE.batch.
function M.drop_draft(pr_id, item)
  local st = STATE()
  local live = st.batch_drop and st.batch_drop[tostring(pr_id)]
  if live and live(item) then return true end
  local s = st.batch and st.batch[tostring(pr_id)]
  for i, it in ipairs((s and s.items) or {}) do
    if it == item or (it.kind == item.kind and it.text == item.text and it.thread_id == item.thread_id) then
      table.remove(s.items, i)
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- The tools.

local VOTES = {
  approve = { "10", "Approve" }, approve_with_suggestions = { "5", "Approve with suggestions" },
  wait = { "-5", "Wait for author" }, reject = { "-10", "Reject" }, reset = { "0", "Reset vote" },
}

M.list = {
  {
    name = "current_view",
    description = "What the user is looking at right now in azure-vicli: the screen (PR dashboard, reviewer, "
      .. "work items, work item detail), and the pull request, work item, file, line, comment thread or "
      .. "selection under their cursor. Call this when the user says \"this PR\", \"this comment\", \"this work item\".",
    schema = { type = "object", properties = vim.empty_dict() },
    risk = "read",
    run = function(_, env, done)
      done((env.view and env.view()) or require("azure-cli.chat.view").snapshot(env.main_win()))
    end,
  },
  {
    name = "list_pull_requests",
    description = "The pull requests in the user's dashboard (assigned to them or created by them), with section "
      .. "(Actionable, Waiting, SignedOff, Drafts, Created), branches, votes, build and thread counts.",
    schema = { type = "object", properties = vim.empty_dict() },
    risk = "read",
    run = function(_, _, done)
      local cache = STATE().PR_LIST_CACHE
      local out = {}
      for _, p in ipairs((cache and cache.prs) or {}) do out[#out + 1] = pr_summary(p) end
      done(out)
    end,
  },
  {
    name = "get_pull_request",
    description = "One pull request: title, description, branches, author, reviewers and votes, build, url.",
    schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
    risk = "read",
    run = function(args, _, done)
      local pr = need_pr(args, done)
      if pr then done(pr_summary(pr, true)) end
    end,
  },
  {
    name = "get_pr_threads",
    description = "Every comment thread on a pull request (fetched fresh): id, status (active, fixed, wontFix, "
      .. "closed, byDesign, pending), file/side/line when anchored to code (side R = source branch), and comments.",
    schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
    risk = "read",
    run = function(args, _, done)
      local pr = need_pr(args, done)
      if not pr then return end
      provider({ "--threads" }, pr_env(pr), function(ok, out, err)
        if not ok then return done(nil, "could not fetch the threads: " .. err) end
        local okd, decoded = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
        if not okd then return done(nil, "the threads came back malformed") end
        done(M.simplify_threads(decoded))
      end)
    end,
  },
  {
    name = "get_pr_diff",
    description = "The pull request's change as a unified diff (target...source), optionally for one file path. "
      .. "Long diffs are cut off.",
    schema = { type = "object", properties = { pr_id = { type = "integer" }, path = { type = "string" } }, required = { "pr_id" } },
    risk = "read",
    run = function(args, _, done)
      local pr = need_pr(args, done)
      if not pr then return end
      local clone = M.clone_path(pr)
      if clone == "" or vim.fn.isdirectory(clone .. "/.git") == 0 then
        return done(nil, "the PR's repository isn't cloned locally")
      end
      local argv = { "git", "-C", clone, "diff", "origin/" .. (pr.target or "") .. "...origin/" .. (pr.source or "") }
      if args.path and args.path ~= "" then vim.list_extend(argv, { "--", args.path }) end
      git(argv, function(ok, out, err)
        if not ok then return done(nil, "git diff failed: " .. err) end
        if #out > 80000 then out = out:sub(1, 80000) .. "\n... (cut off - ask for one path at a time)" end
        done(out ~= "" and out or "(no changes)")
      end)
    end,
  },
  {
    name = "list_work_items",
    description = "The work items in the user's current sprint view: id, type, title, state, assignee, linked PRs.",
    schema = { type = "object", properties = vim.empty_dict() },
    risk = "read",
    run = function(_, _, done)
      local function shape(items)
        local out = {}
        for _, it in ipairs(items or {}) do
          if type(it) == "table" and it.id then
            local prs = {}
            for _, p in ipairs(type(it.pullRequests) == "table" and it.pullRequests or {}) do prs[#prs + 1] = p.id or p end
            out[#out + 1] = { id = it.id, type = it.type, title = it.title, state = it.state,
              assigned_to = it.assignedTo, parent = it.parentId, pull_requests = prs }
          end
        end
        return out
      end
      local cache = STATE().WI_LIST_CACHE
      if cache and cache.items then return done(shape(cache.items)) end
      provider({ "--wi-list" }, nil, function(ok, out, err)
        if not ok then return done(nil, "could not list work items: " .. err) end
        local items = {}
        for _, l in ipairs(vim.split(out, "\n", { plain = true })) do
          local okd, rec = pcall(vim.json.decode, l)
          if okd and type(rec) == "table" and not rec._meta then items[#items + 1] = rec end
        end
        done(shape(items))
      end)
    end,
  },
  {
    name = "get_work_item",
    description = "One work item in full: fields, description, parent, children, comments, linked pull requests.",
    schema = { type = "object", properties = { id = { type = "integer" } }, required = { "id" } },
    risk = "read",
    run = function(args, _, done)
      provider({ "--wi-detail", tostring(args.id) }, nil, function(ok, out, err)
        if not ok then return done(nil, "could not read #" .. tostring(args.id) .. ": " .. err) end
        local okd, decoded = pcall(vim.json.decode, out)
        done(okd and decoded or out)
      end)
    end,
  },
  {
    name = "link_pr_to_work_item",
    description = "Links a pull request to a work item (shows on both). Runs without asking.",
    schema = { type = "object", properties = { pr_id = { type = "integer" }, work_item_id = { type = "integer" } },
      required = { "pr_id", "work_item_id" } },
    risk = "write",
    run = function(args, _, done)
      local pr = need_pr(args, done)
      if not pr then return end
      provider({ "--wi-edit", "link-pr", tostring(args.work_item_id), pr.org or "", pr.project or "", pr.repo or "",
        tostring(pr.id) }, nil, function(ok, _, err)
        if not ok then return done(nil, "linking failed: " .. err) end
        pcall(require("azure-cli.workitems.linked_prs").link_changed, tostring(args.work_item_id), tostring(pr.id), true)
        done("Linked PR #" .. pr.id .. " to work item #" .. args.work_item_id .. ".", nil,
          { op = "unlink", work_item_id = args.work_item_id, pr_id = pr.id })
      end)
    end,
  },
  {
    name = "create_branch",
    description = "Creates a branch on the server from another branch's tip (e.g. from \"develop\"), links it to a "
      .. "work item when work_item_id is given (it then shows in the work item's Development section), and with "
      .. "checkout=true also checks it out in the user's local clone. Runs without asking. Suggest a name like "
      .. "feature/<work item id>-<short-title>; ask the user which repository when it isn't clear.",
    schema = { type = "object", properties = {
      repo = { type = "string", description = "repository name" },
      from = { type = "string", description = "branch to start from, e.g. develop" },
      name = { type = "string", description = "the new branch's name, without refs/heads/" },
      work_item_id = { type = "integer" },
      checkout = { type = "boolean" },
    }, required = { "repo", "from", "name" } },
    risk = "write",
    run = function(args, env, done)
      local org, project, clone = M.repo_location(args.repo)
      provider({ "--wi-edit", "create-branch", tostring(args.work_item_id or 0), org, project, args.repo, args.from,
        args.name }, nil, function(ok, out, err)
        if not ok then return done(nil, "creating the branch failed: " .. err) end
        local okd, res = pcall(vim.json.decode, out)
        res = okd and res or {}
        local undo = { op = "delete_branch", org = org, project = project, repo = args.repo, name = args.name,
          sha = res.objectId }
        local msg = "Created branch " .. args.name .. " from " .. args.from .. " in " .. args.repo
          .. (res.linked and (" and linked it to #" .. tostring(res.linked)) or "")
          .. (res.linkError and (" (linking to the work item failed: " .. res.linkError .. ")") or "") .. "."
        if not args.checkout then return done(msg, nil, undo) end
        if clone == "" or vim.fn.isdirectory(clone .. "/.git") == 0 then
          return done(msg .. " Not checked out: no local clone of " .. args.repo .. " is configured.", nil, undo)
        end
        env.log("git fetch + switch in " .. clone)
        git({ "git", "-C", clone, "fetch", "-q", "origin", args.name }, function(fok, _, ferr)
          if not fok then return done(msg .. " Fetching it failed: " .. ferr, nil, undo) end
          git({ "git", "-C", clone, "switch", "-c", args.name, "--track", "origin/" .. args.name }, function(sok, _, serr)
            done(msg .. (sok and (" Checked out in " .. clone .. ".") or (" Checking it out failed: " .. serr)), nil, undo)
          end)
        end)
      end)
    end,
  },
  {
    name = "draft_reply",
    description = "Drafts a reply to a comment thread. It is NOT posted: it goes into the PR's batch-review queue, "
      .. "where the user reviews it and sends it with gS. Runs without asking.",
    schema = { type = "object", properties = { pr_id = { type = "integer" }, thread_id = { type = "integer" },
      text = { type = "string" } }, required = { "pr_id", "thread_id", "text" } },
    risk = "write",
    run = function(args, _, done)
      local pr = need_pr(args, done)
      if not pr then return end
      local item = { kind = "reply", thread_id = args.thread_id, text = args.text }
      queue_draft(pr.id, item)
      done("Drafted a reply to thread #" .. args.thread_id .. " on PR #" .. pr.id
        .. " - queued for the user to review and send (gQ lists the queue, gS sends it).", nil,
        { op = "drop_draft", pr_id = pr.id, item = item })
    end,
  },
  {
    name = "draft_comment",
    description = "Drafts a new comment on a pull request: on a line of a file (file + line; side \"R\" source "
      .. "branch, the default, or \"L\" target), on a whole file (file only), or on the PR itself. NOT posted - "
      .. "queued for the user like draft_reply. Runs without asking.",
    schema = { type = "object", properties = { pr_id = { type = "integer" }, text = { type = "string" },
      file = { type = "string" }, line = { type = "integer" }, side = { type = "string", enum = { "R", "L" } } },
      required = { "pr_id", "text" } },
    risk = "write",
    run = function(args, _, done)
      local pr = need_pr(args, done)
      if not pr then return end
      local file = args.file and args.file:gsub("^/", "") or nil
      local item
      if file and args.line then
        local side = args.side == "L" and "L" or "R"
        local where = file .. "\t" .. side .. "\t" .. args.line
        item = { kind = "thread", args = { "--post", file, side, tostring(args.line), args.text }, bucket = "line",
          where = where, path = file, side = side, lineno = args.line, text = args.text,
          label = "Comment on " .. file .. " " .. side .. ":" .. args.line }
      elseif file then
        item = { kind = "thread", args = { "--file-comment", file, args.text }, bucket = "file", where = file,
          path = file, text = args.text, label = "File comment on " .. file }
      else
        item = { kind = "thread", args = { "--pr-comment", args.text }, bucket = "general", text = args.text,
          label = "PR comment" }
      end
      queue_draft(pr.id, item)
      done("Drafted: " .. item.label .. " on PR #" .. pr.id .. " - queued for the user (gQ lists, gS sends).", nil,
        { op = "drop_draft", pr_id = pr.id, item = item })
    end,
  },
  {
    name = "vote",
    description = "Casts the user's vote on a pull request. Asks the user to confirm first.",
    schema = { type = "object", properties = { pr_id = { type = "integer" },
      vote = { type = "string", enum = { "approve", "approve_with_suggestions", "wait", "reject", "reset" } } },
      required = { "pr_id", "vote" } },
    risk = "ask",
    confirm = function(args)
      return "vote \"" .. ((VOTES[args.vote] or {})[2] or tostring(args.vote)) .. "\" on PR #" .. tostring(args.pr_id)
    end,
    run = function(args, _, done)
      local pr = need_pr(args, done)
      if not pr then return end
      local v = VOTES[args.vote]
      if not v then return done(nil, "unknown vote " .. tostring(args.vote)) end
      local before = 0
      for _, r in ipairs(type(pr.reviewers) == "table" and pr.reviewers or {}) do
        if r.name == pr.myName or (pr.myId and r.id == pr.myId) then before = tonumber(r.vote) or 0 end
      end
      provider({ "--vote", v[1] }, pr_env(pr), function(ok, _, err)
        if not ok then return done(nil, "voting failed: " .. err) end
        if STATE().PR_DASHBOARD_RENDER then pcall(STATE().PR_DASHBOARD_RENDER) end
        done("Voted " .. v[2] .. " on PR #" .. pr.id .. ".", nil, { op = "vote", pr_id = pr.id, vote = tostring(before) })
      end)
    end,
  },
  {
    name = "set_work_item_state",
    description = "Changes a work item's state (e.g. Active, Resolved, Closed - whatever its workflow allows). "
      .. "Asks the user to confirm first.",
    schema = { type = "object", properties = { id = { type = "integer" }, state = { type = "string" },
      reason = { type = "string" } }, required = { "id", "state" } },
    risk = "ask",
    confirm = function(args)
      return "set work item #" .. tostring(args.id) .. " to \"" .. tostring(args.state) .. "\""
    end,
    run = function(args, _, done)
      local argv = { "--wi-state", "set", tostring(args.id), args.state }
      if args.reason and args.reason ~= "" then argv[#argv + 1] = args.reason end
      M.work_item_field(args.id, "state", function(before)
        provider(argv, nil, function(ok, _, err)
          if not ok then return done(nil, "changing the state failed: " .. err) end
          pcall(require("azure-cli.pr_workitems").patch_state, args.id, args.state)
          done("Work item #" .. args.id .. " is now " .. args.state .. ".", nil,
            before and { op = "set_state", id = args.id, state = before } or nil)
        end)
      end)
    end,
  },
}

-- A work item's current `field` ("state", "assignedTo", "iterationPath",
-- "title") - from the work-items list when it's loaded, else read with
-- --wi-detail - cb(value or nil). What an undo goes back to.
function M.work_item_field(id, field, cb)
  for _, it in ipairs((STATE().WI_LIST_CACHE or {}).items or {}) do
    if type(it) == "table" and tostring(it.id) == tostring(id) and it[field] ~= nil then return cb(it[field]) end
  end
  provider({ "--wi-detail", tostring(id) }, nil, function(ok, out)
    if not ok then return cb(nil) end
    local okd, d = pcall(vim.json.decode, out)
    local item = okd and type(d) == "table" and (d.item or d) or {}
    cb(item[field])
  end)
end

-- The other tool groups.
for _, mod in ipairs({ "azure-cli.chat.tools_pr", "azure-cli.chat.tools_board", "azure-cli.chat.tools_fix" }) do
  vim.list_extend(M.list, require(mod)(M))
end

M.by_name = {}
for _, t in ipairs(M.list) do M.by_name[t.name] = t end

-- How a tool may run: setup({ chat = { permissions = { name = "allow" |
-- "ask" | "deny" } } }), else its own default - reads and the low-risk
-- writes allow, the rest ask.
function M.permission(tool, perms)
  local p = perms and perms[tool.name]
  if p == "allow" or p == "ask" or p == "deny" then return p end
  return tool.risk == "ask" and "ask" or "allow"
end

local function perms() return (require("azure-cli.config").get().chat or {}).permissions end

-- tools/list's answer: every tool not denied.
function M.describe()
  local out = {}
  local p = perms()
  for _, t in ipairs(M.list) do
    if M.permission(t, p) ~= "deny" then
      out[#out + 1] = { name = t.name, description = t.description, inputSchema = t.schema }
    end
  end
  return out
end

-- Runs tool `name` with `args`: cb(text, is_error). Asks first when its
-- permission says so (env.confirm, with the tool's `details` shown when it
-- has them); logs every call in the chat; records every successful change
-- (risk "write"/"ask") in the audit log with its undo, when it has one.
function M.call(name, args, env, cb)
  local tool = M.by_name[name or ""]
  if not tool then return cb("unknown tool " .. tostring(name), true) end
  args = type(args) == "table" and args or {}
  local perm = M.permission(tool, perms())
  if perm == "deny" then return cb("The user doesn't allow " .. name .. ".", true) end
  local function finish(result, err, undo)
    if err then
      env.log("\u{2717} " .. name .. ": " .. tostring(err))
      return cb(tostring(err), true)
    end
    if type(result) ~= "string" then
      local ok, text = pcall(vim.json.encode, result)
      result = ok and text or tostring(result)
    end
    if tool.risk == "write" or tool.risk == "ask" then
      local summary = result:gsub("%s+", " ")
      if #summary > 160 then summary = summary:sub(1, 157) .. "..." end
      pcall(require("azure-cli.chat.store").audit_add, { tool = name, args = M.audit_args(args), summary = summary,
        undo = undo })
      if undo and M.undoers[undo.op] then M.last_undo = undo end
    end
    cb(result, false)
  end
  local function go()
    env.log(((tool.risk == "write" or tool.risk == "ask") and "\u{270E} " or "\u{00B7} ") .. name .. M.args_label(args))
    local ok, err = pcall(tool.run, args, env, finish)
    if not ok then finish(nil, err) end
  end
  if perm == "ask" then
    local what = tool.confirm and tool.confirm(args) or name
    local function ask(details)
      env.confirm("The agent wants to " .. what .. ".", function(yes)
        if yes then
          go()
        else
          env.log("\u{2717} " .. name .. ": declined")
          cb("The user declined: " .. what .. ".", true)
        end
      end, details)
    end
    if tool.details then tool.details(args, ask) else ask(nil) end
  else
    go()
  end
end

-- The arguments as kept in the audit log: long text cut.
function M.audit_args(args)
  local out = {}
  for k, v in pairs(args or {}) do
    if type(v) == "string" and #v > 200 then v = v:sub(1, 197) .. "..." end
    out[k] = v
  end
  return out
end

-- Undoing what a tool did: op -> function(undo, cb(ok, message)).
M.undoers = {
  unlink = function(u, cb)
    provider({ "--wi-edit", "unlink-pr", tostring(u.work_item_id), tostring(u.pr_id) }, nil, function(ok, _, err)
      if ok then pcall(require("azure-cli.workitems.linked_prs").link_changed, tostring(u.work_item_id), tostring(u.pr_id), false) end
      cb(ok, ok and ("Unlinked PR !" .. u.pr_id .. " from #" .. u.work_item_id .. ".") or err)
    end)
  end,
  delete_branch = function(u, cb)
    provider({ "--wi-edit", "delete-branch", u.org or "", u.project or "", u.repo, u.name, u.sha or "" }, nil,
      function(ok, _, err) cb(ok, ok and ("Deleted branch " .. u.name .. ".") or err) end)
  end,
  drop_draft = function(u, cb)
    local ok = u.item and M.drop_draft(u.pr_id, u.item)
    cb(ok and true or false, ok and "Removed the draft from the queue." or "That draft isn't queued any more.")
  end,
  vote = function(u, cb)
    local pr = M.pr_record(u.pr_id)
    if not pr then return cb(false, "PR !" .. u.pr_id .. " isn't in the list") end
    provider({ "--vote", u.vote }, pr_env(pr), function(ok, _, err) cb(ok, ok and "Vote put back." or err) end)
  end,
  set_state = function(u, cb)
    provider({ "--wi-state", "set", tostring(u.id), u.state }, nil, function(ok, _, err)
      if ok then pcall(require("azure-cli.pr_workitems").patch_state, u.id, u.state) end
      cb(ok, ok and ("#" .. u.id .. " is " .. u.state .. " again.") or err)
    end)
  end,
  set_field = function(u, cb)
    provider({ "--wi-edit", "set", tostring(u.id), u.field, u.value or "" }, nil, function(ok, _, err)
      cb(ok, ok and ("#" .. u.id .. "'s " .. u.field .. " is back to " .. tostring(u.value) .. ".") or err)
    end)
  end,
  thread_status = function(u, cb)
    local pr = M.pr_record(u.pr_id)
    if not pr then return cb(false, "PR !" .. u.pr_id .. " isn't in the list") end
    provider({ "--status", tostring(u.thread_id), u.status }, pr_env(pr), function(ok, _, err)
      cb(ok, ok and ("Thread #" .. u.thread_id .. " is " .. u.status .. " again.") or err)
    end)
  end,
  description = function(u, cb)
    local pr = M.pr_record(u.pr_id)
    if not pr then return cb(false, "PR !" .. u.pr_id .. " isn't in the list") end
    provider({ "--set-description", u.text or "" }, pr_env(pr), function(ok, _, err)
      cb(ok, ok and "Description put back." or err)
    end)
  end,
}

-- Undoes audit item `item` (from store.audit()): cb(ok, message).
function M.undo(item, cb)
  local u = item and item.undo
  local f = u and M.undoers[u.op]
  if not f then return cb(false, "That change can't be undone from here.") end
  f(u, cb)
end

-- " (pr_id=101, thread_id=4711)" - the short arguments of a call, for the
-- transcript. Long text arguments are left out. Pure.
function M.args_label(args)
  local parts = {}
  for k, v in pairs(args or {}) do
    if type(v) ~= "table" and not (type(v) == "string" and #v > 40) then
      parts[#parts + 1] = k .. "=" .. tostring(v)
    end
  end
  table.sort(parts)
  return #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
end

return M
