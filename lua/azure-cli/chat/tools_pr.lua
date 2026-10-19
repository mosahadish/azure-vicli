-- lua/azure-cli/chat/tools_pr.lua: the chat agent's pull-request tools
-- beyond the basics in chat/tools.lua - a failed build's log and tests, thread
-- status, reviewers, the description, opening and completing PRs,
-- re-queueing the build - plus the two that act on the screen rather than
-- on Azure DevOps: open_in_ui (show the user something) and annotate_code
-- (leave a note on a line of the diff, review/chat.lua draws it).
--
-- Returns function(T) -> list of tools, T being chat/tools.lua (its
-- helpers: pr_record, pr_env, need_pr, provider).
return function(T)
  local function STATE() return require("azure-cli.state") end

  -- The build behind the PR's status: the buildId in its build link.
  local function build_id(pr)
    return tostring(pr.buildUrl or ""):match("[?&]buildId=(%d+)")
  end

  -- A tool's `unsupported`: why PR `args.pr_id`'s host can't `what` (its
  -- HOSTS.caps lacks `cap`), else nil - a PR not loaded is need_pr's to say.
  local HOST_NAMES = { azure = "Azure DevOps", github = "GitHub" }
  local function needs(cap, what)
    return function(args)
      local pr = T.pr_record(args.pr_id)
      if not pr then return nil end
      local HOSTS = require("azure-cli.hosts")
      if HOSTS.caps(pr)[cap] then return nil end
      local host = HOSTS.host(pr)
      return HOSTS.ref(pr) .. " is on " .. (HOST_NAMES[host] or host) .. ", which can't " .. what .. " from azure-vicli."
    end
  end

  -- update_pr_description's title, nil when left out or blank (a blank one
  -- would empty the PR's title).
  local function new_title(args)
    local t = type(args.title) == "string" and vim.trim(args.title) or ""
    return t ~= "" and t or nil
  end

  -- Shows a reviewer tab for PR `id` (opening the reviewer when it isn't
  -- open yet) and, once it's there, calls review/chat.lua's opener with
  -- `path`/`side`/`line`. cb(ok, message).
  local function show_in_reviewer(id, path, side, line, cb)
    id = tostring(id)
    local tries = 0
    local function attempt()
      local opener = STATE().review_openers and STATE().review_openers[id]
      if opener and opener(path, side, line) then
        return cb(true, "Showing PR !" .. id .. (path and (" at " .. path .. (line and (":" .. line) or "")) or "") .. ".")
      end
      tries = tries + 1
      if tries > 150 then return cb(false, "the reviewer didn't open for PR !" .. id) end
      vim.defer_fn(attempt, 200)
    end
    local opener = STATE().review_openers and STATE().review_openers[id]
    if not (opener and opener(nil)) then
      if not T.pr_record(id) then return cb(false, "PR !" .. id .. " isn't in the user's PR list") end
      require("azure-cli").open_review(id)
    end
    attempt()
  end

  return {
    {
      name = "get_build_log",
      description = "Why a pull request's build failed: every failed job/task with its errors, and the end of "
        .. "each failed task's log.",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "read",
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local bid = build_id(pr)
        if not bid then return done("PR !" .. pr.id .. " has no build (status: " .. tostring(pr.buildStatus) .. ").") end
        T.provider({ "--build-log", bid }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, "could not read build " .. bid .. ": " .. err) end
          local okd, d = pcall(vim.json.decode, out)
          if okd and type(d) == "table" then
            d.status = pr.buildStatus
            if #(d.failed or {}) == 0 then d.note = "No failed steps in this build." end
          end
          done(okd and d or out)
        end)
      end,
    },
    {
      name = "get_test_results",
      description = "The tests that failed in a pull request's build: each failed test's name, its error message "
        .. "and the start of its stack trace, from the build's test runs. Use this (not the shell, curl or az) to see "
        .. "why CI tests failed; get_build_log gives the failed steps' logs.",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "read",
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local bid = build_id(pr)
        if not bid then return done("PR !" .. pr.id .. " has no build (status: " .. tostring(pr.buildStatus) .. ").") end
        T.provider({ "--test-results", bid }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, "could not read the test results of build " .. bid .. ": " .. err) end
          local okd, d = pcall(vim.json.decode, out)
          if okd and type(d) == "table" then
            d.status = pr.buildStatus
            if #(d.runs or {}) == 0 then d.note = "This build published no test results - get_build_log shows its logs."
            elseif #(d.failed or {}) == 0 then d.note = "No test failed in this build." end
          end
          done(okd and d or out)
        end)
      end,
    },
    {
      name = "set_thread_status",
      description = "Sets a comment thread's status: active, fixed, wontfix, closed, bydesign or pending "
        .. "(\"resolve\" = fixed). Asks the user first.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, thread_id = { type = "integer" },
        status = { type = "string", enum = { "active", "fixed", "wontfix", "closed", "bydesign", "pending" } } },
        required = { "pr_id", "thread_id", "status" } },
      risk = "ask",
      confirm = function(a) return "set thread #" .. tostring(a.thread_id) .. " on PR !" .. tostring(a.pr_id) .. " to " .. tostring(a.status) end,
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        T.provider({ "--threads" }, T.pr_env(pr), function(_, out)
          local before
          local okd, d = pcall(vim.json.decode, out or "")
          for _, t in ipairs(okd and type(d) == "table" and (d.value or d) or {}) do
            if type(t) == "table" and tostring(t.id) == tostring(args.thread_id) then before = t.status end
          end
          T.provider({ "--status", tostring(args.thread_id), args.status }, T.pr_env(pr), function(ok, _, err)
            if not ok then return done(nil, "changing the status failed: " .. err) end
            done("Thread #" .. args.thread_id .. " is now " .. args.status .. ".", nil,
              before and { op = "thread_status", pr_id = pr.id, thread_id = args.thread_id,
                status = tostring(before):lower() } or nil)
          end)
        end)
      end,
    },
    {
      name = "add_reviewer",
      description = "Adds a reviewer to a pull request - Azure DevOps: by name or email, optionally as required; "
        .. "GitHub: a login, @login, a name, or org/team (GitHub has no required reviewers). Says so when the PR's "
        .. "host can't. Asks first.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, who = { type = "string" },
        required = { type = "boolean" } }, required = { "pr_id", "who" } },
      risk = "ask",
      unsupported = needs("add_reviewer", "add reviewers"),
      confirm = function(a) return "add " .. tostring(a.who) .. " as a" .. (a.required and " required" or "") .. " reviewer on PR !" .. tostring(a.pr_id) end,
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        T.provider({ "--add-reviewer", args.who, args.required and "true" or "false" }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, err) end
          local okd, d = pcall(vim.json.decode, out)
          d = okd and type(d) == "table" and d or {}
          done("Added " .. (d.added or args.who) .. " as a reviewer on PR !" .. pr.id .. "."
            .. (d.note and (" Note: " .. d.note .. ".") or ""))
        end)
      end,
    },
    {
      name = "update_pr_description",
      description = "Replaces a pull request's description (markdown; on GitHub, its body), and its title when "
        .. "title is given. Says so when the PR's host can't. Asks first.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, description = { type = "string" },
        title = { type = "string", description = "new title; leave out to keep it" } },
        required = { "pr_id", "description" } },
      risk = "ask",
      unsupported = needs("set_description", "change the description"),
      confirm = function(a)
        return "replace the " .. (new_title(a) and "title and " or "") .. "description of PR !" .. tostring(a.pr_id)
      end,
      details = function(a, cb)
        local lines = vim.split(a.description or "", "\n", { plain = true })
        if new_title(a) then lines = vim.list_extend({ "Title: " .. new_title(a), "" }, lines) end
        cb(lines)
      end,
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local before, title, before_title = pr.description, new_title(args), pr.title
        -- No title keeps the argv (and so the request) as it always was.
        local argv = { "--set-description", args.description }
        if title then argv[3] = title end
        T.provider(argv, T.pr_env(pr), function(ok, _, err)
          if not ok then return done(nil, err) end
          pr.description = args.description
          if title then pr.title = title end
          done("Updated the " .. (title and "title and " or "") .. "description of PR !" .. pr.id .. ".", nil,
            { op = "description", pr_id = pr.id, text = before or "", title = title and (before_title or "") or nil })
        end)
      end,
    },
    {
      name = "create_pull_request",
      description = "Opens a pull request from one branch into another in a repository, optionally linking work "
        .. "items (on GitHub, issues: a \"Closes #n\" line each). Leave description out to use your approved plan's (its Goal, Approach, Risks and Test plan), or "
        .. "give both description and from_plan = true for yours followed by the plan's. Asks first.",
      schema = { type = "object", properties = { repo = { type = "string" }, source = { type = "string" },
        target = { type = "string" }, title = { type = "string" }, description = { type = "string" },
        from_plan = { type = "boolean", description = "add the plan's sections after description" },
        work_item_ids = { type = "array", items = { type = "integer" } }, draft = { type = "boolean" },
        board = T.board_props.board },
        required = { "repo", "source", "target", "title" } },
      risk = "ask",
      confirm = function(a) return "open a pull request \"" .. tostring(a.title) .. "\" from " .. tostring(a.source) .. " into " .. tostring(a.target) .. " in " .. tostring(a.repo) end,
      details = function(a, cb)
        local d = require("azure-cli.chat.plan").description_for(a.description, a.from_plan, a.work_item_ids, a.source,
          nil, a.repo)
        cb(d ~= "" and vim.list_extend({ "Description:", "" }, vim.split(d, "\n", { plain = true })) or nil)
      end,
      -- The PR of a plan you approved with pushing allowed opens without asking.
      preapproved = function(a, cb) require("azure-cli.chat.plan").pr_allowed(a, cb) end,
      run = function(args, env, done)
        args.description = require("azure-cli.chat.plan").description_for(args.description, args.from_plan,
          args.work_item_ids, args.source, env, args.repo)
        -- The repository's org/project: a PR of it on the dashboard, else the
        -- board's account (on GitHub its API root and owner; work_item_ids
        -- then become "Closes #n" lines in the description).
        local org, project = T.repo_location(args.repo, T.board_for(args, env))
        local repo = tostring(args.repo):match("/(.+)$") or args.repo
        local ids = {}
        for _, w in ipairs(args.work_item_ids or {}) do ids[#ids + 1] = tostring(w) end
        T.provider({ "--create-pr", args.source, args.target, args.title, args.description or "", table.concat(ids, ","),
          args.draft and "true" or "false" },
          { AZVICLI_ORG = org, AZVICLI_PROJECT = project, AZVICLI_REPO = repo, AZVICLI_PR = "0" },
          function(ok, out, err)
            if not ok then return done(nil, err) end
            local okd, d = pcall(vim.json.decode, out)
            local id = okd and d.id or "?"
            -- Its reviewers' comments (chat/watch.lua).
            if okd and d.id then
              pcall(require("azure-cli.chat.watch").add, { id = d.id, org = org, project = project, repo = repo,
                title = args.title, key = d.key, host = d.key and "github" or nil })
              -- The plans it was opened for know it (the Agents screen).
              pcall(require("azure-cli.chat.plan").link_pr, args.work_item_ids, args.source,
                { id = d.id, org = org, project = project, key = d.key }, env, args.repo)
            end
            done("Opened PR !" .. tostring(id) .. " (" .. ((okd and d.url) or "") .. "). It shows on the dashboard at its next refresh."
              .. ((okd and d.note) and (" Note: " .. d.note .. ".") or ""))
          end)
      end,
    },
    {
      name = "complete_pull_request",
      description = "Completes (merges) a pull request with a strategy its host allows - Azure DevOps: squash "
        .. "(default), noFastForward, rebase or rebaseMerge; GitHub: squash, merge or rebase, as the repository "
        .. "allows (squash by default when allowed). Deletes the source branch unless told not to, and on Azure "
        .. "completes linked work items unless told not to. When GitHub would refuse (a required check failed, a "
        .. "review is needed, a conflict), it says why instead. Asks first.",
      schema = { type = "object", properties = { pr_id = { type = "integer" },
        strategy = { type = "string", enum = { "squash", "noFastForward", "rebase", "rebaseMerge", "merge" } },
        delete_source_branch = { type = "boolean" }, complete_work_items = { type = "boolean" } },
        required = { "pr_id" } },
      risk = "ask",
      confirm = function(a) return "complete (merge) PR !" .. tostring(a.pr_id) .. " with " .. tostring(a.strategy or "squash") end,
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local HOSTS = require("azure-cli.hosts")
        -- Only a strategy the PR's host (and, on GitHub, its repository)
        -- allows; never mapped from another host's name.
        local keys = {}
        for _, mt in ipairs(HOSTS.caps(pr).merge_methods or {}) do keys[#keys + 1] = mt.key end
        local strategy = args.strategy
        if not strategy then strategy = vim.tbl_contains(keys, "squash") and "squash" or keys[1] end
        if not vim.tbl_contains(keys, strategy) then
          return done(nil, tostring(strategy) .. " isn't a merge strategy " .. HOSTS.ref(pr) .. " allows: "
            .. table.concat(keys, ", "))
        end
        T.provider({ "--complete", strategy, args.delete_source_branch == false and "false" or "true",
          args.complete_work_items == false and "false" or "true" }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, (err ~= "" and err or out)) end
          if STATE().PR_DASHBOARD_RENDER then pcall(STATE().PR_DASHBOARD_RENDER) end
          done("Completed PR " .. HOSTS.ref(pr) .. " (" .. strategy .. ")." .. (out ~= "" and (" " .. out) or ""))
        end)
      end,
    },
    {
      name = "requeue_build",
      description = "Queues the pull request's build validation again (e.g. after a flaky failure); on GitHub, "
        .. "re-runs the failed jobs of its head's failed workflow runs.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, repo = { type = "string",
        description = "GitHub only: the PR's repository (owner/repo), when two PRs share pr_id" } },
        required = { "pr_id" } },
      risk = "write",
      run = function(args, env, done)
        -- The agent's own PR first, so one GitHub #7 never means another (#109).
        local target = require("azure-cli.chat.plan").pr_target_for(args.pr_id, env, args.repo) or {}
        local pr = T.pr_record(target.pr_key or args.pr_id, not target.pr_key and args.repo or nil)
        if not pr then
          return done(nil, "PR !" .. tostring(args.pr_id) .. (args.repo and (" in " .. args.repo) or "")
            .. " isn't loaded - call get_pull_request for it first.")
        end
        -- The PR's env routes it: a GitHub PR's never reaches Azure's requeue (#111).
        T.provider({ "--requeue", tostring(pr.id) }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, err ~= "" and err or out) end
          out = vim.trim(out or "")
          done(out ~= "" and out or ("Re-queued the build of PR !" .. pr.id .. "."))
        end)
      end,
    },
    {
      name = "open_in_ui",
      description = "Shows the user something in azure-vicli: a pull request in the reviewer (optionally at a "
        .. "file and line), or a work item (with board = \"github\", an issue). Use it when the user asks to be "
        .. "shown or taken somewhere.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, file = { type = "string" },
        line = { type = "integer" }, side = { type = "string", enum = { "R", "L" } }, work_item_id = { type = "integer" },
        board = T.board_props.board, item_repo = T.board_props.repo_of_item } },
      risk = "read",
      run = function(args, env, done)
        if args.work_item_id then
          local B = T.board_for(args, env)
          require("azure-cli.pr_workitems").open_item(args.work_item_id, B, T.wi_ref(B, args.work_item_id, args.item_repo))
          return done("Showing " .. T.wi_name(B, args.work_item_id) .. ".")
        end
        if not args.pr_id then return done(nil, "give pr_id (and file/line) or work_item_id") end
        local file = args.file and (args.file:gsub("^/", "")) or nil
        show_in_reviewer(args.pr_id, file, args.side or "R", args.line, function(ok, msg)
          if ok then done(msg) else done(nil, msg) end
        end)
      end,
    },
    {
      name = "annotate_code",
      description = "Leaves a note on a line of a pull request's diff, shown under that line in the reviewer (only "
        .. "to the user - nothing is posted). kind: info, warning or issue.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, file = { type = "string" },
        line = { type = "integer" }, side = { type = "string", enum = { "R", "L" } }, text = { type = "string" },
        kind = { type = "string", enum = { "info", "warning", "issue" } } },
        required = { "pr_id", "file", "line", "text" } },
      risk = "read",
      run = function(args, _, done)
        local id = tostring(args.pr_id)
        local count = require("azure-cli.chat.notes").add(id, { file = (args.file:gsub("^/", "")), line = args.line,
          side = args.side == "L" and "L" or "R", text = args.text, kind = args.kind or "info" })
        local redraw = STATE().review_redecorate and STATE().review_redecorate[id]
        if redraw then pcall(redraw) end
        done("Noted " .. args.file .. ":" .. args.line .. " (" .. count .. " notes on PR !" .. id .. ").")
      end,
    },
    {
      name = "clear_annotations",
      description = "Removes the notes annotate_code left on a pull request (they're kept across restarts until then).",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "read",
      run = function(args, _, done)
        local id = tostring(args.pr_id)
        require("azure-cli.chat.notes").clear(id)
        local redraw = STATE().review_redecorate and STATE().review_redecorate[id]
        if redraw then pcall(redraw) end
        done("Cleared the notes on PR !" .. id .. ".")
      end,
    },
  }
end
