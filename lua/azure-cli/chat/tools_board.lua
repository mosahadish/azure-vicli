-- lua/azure-cli/chat/tools_board.lua: the chat agent's work-item tools
-- beyond reading and state changes (chat/tools.lua) - child tasks,
-- assignment, sprints and comments. Every one goes through the same
-- --wi-edit subcommands the work-items screens use, on the board
-- T.board_for picks (Azure work items, or the GitHub project's issues).
--
-- Returns function(T) -> list of tools, T being chat/tools.lua.
return function(T)
  -- Board B's sprints ({ name, path }) - GitHub's iterations or milestones -
  -- from its work-items screen's cache or --wi-list sprints. cb(list).
  local function sprints(B, cb)
    local c = B.state.WI_SPRINTS_CACHE
    if c and c.list and #c.list > 0 then return cb(c.list) end
    T.provider({ "--wi-list", "sprints" }, B.env, function(ok, out)
      local list = {}
      if ok then
        for _, l in ipairs(vim.split(out, "\n", { plain = true })) do
          local okd, d = pcall(vim.json.decode, l)
          if okd and type(d) == "table" and d._sprints then
            for _, sp in ipairs(d.sprints or d.list or {}) do list[#list + 1] = sp end
          end
        end
      end
      cb(list)
    end)
  end

  return {
    {
      name = "list_sprints",
      description = "The team's sprints (name and iteration path), for move_to_sprint. With board = \"github\", "
        .. "the GitHub project's iterations (or milestones).",
      schema = { type = "object", properties = { board = T.board_props.board } },
      risk = "read",
      run = function(args, env, done)
        sprints(T.board_for(args, env), function(list)
          local out = {}
          for _, sp in ipairs(list) do
            out[#out + 1] = { name = sp.name, path = sp.path, start = sp.start or sp.startDate, finish = sp.finish or sp.finishDate }
          end
          done(out)
        end)
      end,
    },
    {
      name = "create_child_task",
      description = "Creates a work item (a Task by default) under a parent work item, in the parent's sprint, "
        .. "assigned to the user. On GitHub (board = \"github\"): a sub-issue of the parent issue, in its "
        .. "iteration (type is the issue type, when the repository has them). Runs without asking.",
      schema = { type = "object", properties = T.with_board({ parent_id = { type = "integer" },
        title = { type = "string" }, type = { type = "string" } }), required = { "parent_id", "title" } },
      risk = "write",
      run = function(args, env, done)
        local B = T.board_for(args, env)
        local parent = T.wi_ref(B, args.parent_id, args.repo)
        local wtype = args.type or (B.host == "github" and "Issue" or "Task")
        T.work_item_field(args.parent_id, B.host == "github" and "iteration" or "iterationPath", function(iteration)
          T.provider({ "--wi-edit", "create", wtype, args.title, parent, iteration or "" },
            B.env, function(ok, out, err)
              if not ok then return done(nil, "creating it failed: " .. err) end
              local okd, d = pcall(vim.json.decode, out)
              local id = okd and d.id or "?"
              T.refresh_item(B, args.parent_id)
              done("Created " .. (B.host == "github" and "issue" or wtype) .. " #" .. tostring(id) .. " \""
                .. args.title .. "\" under #" .. args.parent_id .. "."
                .. ((okd and d.warning) and (" Note: " .. d.warning) or ""))
            end)
        end, B, args.repo)
      end,
    },
    {
      name = "assign_work_item",
      description = "Assigns a work item to someone (a display name or email; empty = the user; on GitHub, "
        .. "logins, comma-separated). Asks first.",
      schema = { type = "object", properties = T.with_board({ id = { type = "integer" },
        assignee = { type = "string" } }), required = { "id" } },
      risk = "ask",
      confirm = function(a)
        return "assign #" .. tostring(a.id) .. " to " .. ((a.assignee and a.assignee ~= "") and a.assignee or "you")
      end,
      run = function(args, env, done)
        local B = T.board_for(args, env)
        local ref = T.wi_ref(B, args.id, args.repo)
        T.work_item_field(args.id, "assignedTo", function(before)
          T.provider({ "--wi-edit", "set", ref, "assignedTo", args.assignee or "" }, B.env, function(ok, out, err)
            if not ok then return done(nil, "assigning failed: " .. err) end
            local okd, d = pcall(vim.json.decode, out)
            T.refresh_item(B, args.id)
            done("#" .. args.id .. " is assigned to " .. tostring(okd and d.value or args.assignee) .. ".", nil,
              { op = "set_field", id = args.id, field = "assignedTo", value = before or "", board = B.host, ref = ref })
          end)
        end, B, args.repo)
      end,
    },
    {
      name = "move_to_sprint",
      description = "Moves a work item to a sprint, by the sprint's name (\"Sprint 42\") or iteration path. "
        .. "On GitHub, an iteration (or milestone) of the project, by name. Runs without asking.",
      schema = { type = "object", properties = T.with_board({ id = { type = "integer" },
        sprint = { type = "string" } }), required = { "id", "sprint" } },
      risk = "write",
      run = function(args, env, done)
        local B = T.board_for(args, env)
        local ref = T.wi_ref(B, args.id, args.repo)
        sprints(B, function(list)
          local path, name
          for _, sp in ipairs(list) do
            if sp.path == args.sprint or (sp.name and sp.name:lower() == args.sprint:lower()) then
              path, name = sp.path, sp.name
            end
          end
          path = path or args.sprint
          -- GitHub's iteration paths are ids: say the name.
          local shown = B.host == "github" and (name or args.sprint) or path
          T.work_item_field(args.id, B.host == "github" and "iteration" or "iterationPath", function(before)
            T.provider({ "--wi-edit", "set", ref, "iteration", path }, B.env, function(ok, _, err)
              if not ok then return done(nil, "moving it failed: " .. err) end
              T.refresh_item(B, args.id)
              done("Moved #" .. args.id .. " to " .. shown .. ".", nil,
                before and { op = "set_field", id = args.id, field = "iteration", value = before, board = B.host,
                  ref = ref } or nil)
            end)
          end, B, args.repo)
        end)
      end,
    },
    {
      name = "comment_on_work_item",
      description = "Posts a comment in a work item's discussion (on GitHub, an issue comment). Asks first.",
      schema = { type = "object", properties = T.with_board({ id = { type = "integer" }, text = { type = "string" } }),
        required = { "id", "text" } },
      risk = "ask",
      confirm = function(a) return "comment on #" .. tostring(a.id) end,
      details = function(a, cb) cb(vim.split(a.text or "", "\n", { plain = true })) end,
      run = function(args, env, done)
        local B = T.board_for(args, env)
        T.provider({ "--wi-edit", "comment", T.wi_ref(B, args.id, args.repo), args.text }, B.env, function(ok, _, err)
          if not ok then return done(nil, "commenting failed: " .. err) end
          T.refresh_item(B, args.id)
          done("Commented on #" .. args.id .. ".")
        end)
      end,
    },
  }
end
