-- lua/azure-cli/chat/tools_pr.lua: the chat agent's pull-request tools
-- beyond the basics in chat/tools.lua - a failed build's log, thread
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
      description = "Adds a reviewer to a pull request by name or email (optionally as required). Asks first.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, who = { type = "string" },
        required = { type = "boolean" } }, required = { "pr_id", "who" } },
      risk = "ask",
      confirm = function(a) return "add " .. tostring(a.who) .. " as a" .. (a.required and " required" or "") .. " reviewer on PR !" .. tostring(a.pr_id) end,
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        T.provider({ "--add-reviewer", args.who, args.required and "true" or "false" }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, err) end
          local okd, d = pcall(vim.json.decode, out)
          done("Added " .. ((okd and d.added) or args.who) .. " as a reviewer on PR !" .. pr.id .. ".")
        end)
      end,
    },
    {
      name = "update_pr_description",
      description = "Replaces a pull request's description (markdown). Asks first.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, description = { type = "string" } },
        required = { "pr_id", "description" } },
      risk = "ask",
      confirm = function(a) return "replace the description of PR !" .. tostring(a.pr_id) end,
      details = function(a, cb) cb(vim.split(a.description or "", "\n", { plain = true })) end,
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        local before = pr.description
        T.provider({ "--set-description", args.description }, T.pr_env(pr), function(ok, _, err)
          if not ok then return done(nil, err) end
          pr.description = args.description
          done("Updated the description of PR !" .. pr.id .. ".", nil, { op = "description", pr_id = pr.id, text = before or "" })
        end)
      end,
    },
    {
      name = "create_pull_request",
      description = "Opens a pull request from one branch into another in a repository, optionally linking work "
        .. "items. Asks first.",
      schema = { type = "object", properties = { repo = { type = "string" }, source = { type = "string" },
        target = { type = "string" }, title = { type = "string" }, description = { type = "string" },
        work_item_ids = { type = "array", items = { type = "integer" } }, draft = { type = "boolean" } },
        required = { "repo", "source", "target", "title" } },
      risk = "ask",
      confirm = function(a) return "open a pull request \"" .. tostring(a.title) .. "\" from " .. tostring(a.source) .. " into " .. tostring(a.target) .. " in " .. tostring(a.repo) end,
      run = function(args, _, done)
        local org, project
        for _, p in ipairs((STATE().PR_LIST_CACHE or {}).prs or {}) do
          if p.repo == args.repo then org, project = p.org, p.project break end
        end
        org = org or vim.env.AZVICLI_WI_COLLECTION or ""
        project = project or vim.env.AZVICLI_WI_PROJECT or ""
        local ids = {}
        for _, w in ipairs(args.work_item_ids or {}) do ids[#ids + 1] = tostring(w) end
        T.provider({ "--create-pr", args.source, args.target, args.title, args.description or "", table.concat(ids, ","),
          args.draft and "true" or "false" },
          { AZVICLI_ORG = org, AZVICLI_PROJECT = project, AZVICLI_REPO = args.repo, AZVICLI_PR = "0" },
          function(ok, out, err)
            if not ok then return done(nil, err) end
            local okd, d = pcall(vim.json.decode, out)
            local id = okd and d.id or "?"
            done("Opened PR !" .. tostring(id) .. " (" .. ((okd and d.url) or "") .. "). It shows on the dashboard at its next refresh.")
          end)
      end,
    },
    {
      name = "complete_pull_request",
      description = "Completes (merges) a pull request: merge strategy squash (default), noFastForward, rebase or "
        .. "rebaseMerge; deletes the source branch and completes linked work items unless told not to. Asks first.",
      schema = { type = "object", properties = { pr_id = { type = "integer" },
        strategy = { type = "string", enum = { "squash", "noFastForward", "rebase", "rebaseMerge" } },
        delete_source_branch = { type = "boolean" }, complete_work_items = { type = "boolean" } },
        required = { "pr_id" } },
      risk = "ask",
      confirm = function(a) return "complete (merge) PR !" .. tostring(a.pr_id) .. " with " .. tostring(a.strategy or "squash") end,
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        T.provider({ "--complete", args.strategy or "squash", args.delete_source_branch == false and "false" or "true",
          args.complete_work_items == false and "false" or "true" }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, (err ~= "" and err or out)) end
          if STATE().PR_DASHBOARD_RENDER then pcall(STATE().PR_DASHBOARD_RENDER) end
          done("Completed PR !" .. pr.id .. ".")
        end)
      end,
    },
    {
      name = "requeue_build",
      description = "Queues the pull request's build validation again (e.g. after a flaky failure).",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "write",
      run = function(args, _, done)
        local pr = T.need_pr(args, done)
        if not pr then return end
        T.provider({ "--requeue", tostring(pr.id) }, T.pr_env(pr), function(ok, out, err)
          if not ok then return done(nil, err ~= "" and err or out) end
          done("Re-queued the build of PR !" .. pr.id .. ".")
        end)
      end,
    },
    {
      name = "open_in_ui",
      description = "Shows the user something in azure-vicli: a pull request in the reviewer (optionally at a "
        .. "file and line), or a work item. Use it when the user asks to be shown or taken somewhere.",
      schema = { type = "object", properties = { pr_id = { type = "integer" }, file = { type = "string" },
        line = { type = "integer" }, side = { type = "string", enum = { "R", "L" } }, work_item_id = { type = "integer" } } },
      risk = "read",
      run = function(args, _, done)
        if args.work_item_id then
          require("azure-cli.pr_workitems").open_item(args.work_item_id)
          return done("Showing work item #" .. args.work_item_id .. ".")
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
        STATE().chat_notes = STATE().chat_notes or {}
        STATE().chat_notes[id] = STATE().chat_notes[id] or {}
        table.insert(STATE().chat_notes[id], { file = (args.file:gsub("^/", "")), line = args.line,
          side = args.side == "L" and "L" or "R", text = args.text, kind = args.kind or "info" })
        local redraw = STATE().review_redecorate and STATE().review_redecorate[id]
        if redraw then pcall(redraw) end
        done("Noted " .. args.file .. ":" .. args.line .. " (" .. #STATE().chat_notes[id] .. " notes on PR !" .. id .. ").")
      end,
    },
    {
      name = "clear_annotations",
      description = "Removes the notes annotate_code left on a pull request.",
      schema = { type = "object", properties = { pr_id = { type = "integer" } }, required = { "pr_id" } },
      risk = "read",
      run = function(args, _, done)
        local id = tostring(args.pr_id)
        if STATE().chat_notes then STATE().chat_notes[id] = nil end
        local redraw = STATE().review_redecorate and STATE().review_redecorate[id]
        if redraw then pcall(redraw) end
        done("Cleared the notes on PR !" .. id .. ".")
      end,
    },
  }
end
