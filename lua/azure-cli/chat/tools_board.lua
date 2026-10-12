-- lua/azure-cli/chat/tools_board.lua: the chat agent's work-item tools
-- beyond reading and state changes (chat/tools.lua) - child tasks,
-- assignment, sprints and comments. Every one goes through the same
-- --wi-edit subcommands the work-items screens use.
--
-- Returns function(T) -> list of tools, T being chat/tools.lua.
return function(T)
  local function STATE() return require("azure-cli.state") end

  -- The team's sprints ({ name, path }), from the work-items screen's cache
  -- or --wi-list sprints. cb(list).
  local function sprints(cb)
    local c = STATE().WI_SPRINTS_CACHE
    if c and c.list and #c.list > 0 then return cb(c.list) end
    T.provider({ "--wi-list", "sprints" }, nil, function(ok, out)
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

  -- A refresh of whichever work-item screens are open.
  local function refresh_board(id)
    local reload = STATE().WI_VIEW_RELOAD and STATE().WI_VIEW_RELOAD[tostring(id)]
    if reload then pcall(reload) end
  end

  return {
    {
      name = "list_sprints",
      description = "The team's sprints (name and iteration path), for move_to_sprint.",
      schema = { type = "object", properties = vim.empty_dict() },
      risk = "read",
      run = function(_, _, done)
        sprints(function(list)
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
        .. "assigned to the user. Runs without asking.",
      schema = { type = "object", properties = { parent_id = { type = "integer" }, title = { type = "string" },
        type = { type = "string" } }, required = { "parent_id", "title" } },
      risk = "write",
      run = function(args, _, done)
        T.work_item_field(args.parent_id, "iterationPath", function(iteration)
          T.provider({ "--wi-edit", "create", args.type or "Task", args.title, tostring(args.parent_id), iteration or "" },
            nil, function(ok, out, err)
              if not ok then return done(nil, "creating it failed: " .. err) end
              local okd, d = pcall(vim.json.decode, out)
              local id = okd and d.id or "?"
              refresh_board(args.parent_id)
              done("Created " .. (args.type or "Task") .. " #" .. tostring(id) .. " \"" .. args.title .. "\" under #"
                .. args.parent_id .. ".")
            end)
        end)
      end,
    },
    {
      name = "assign_work_item",
      description = "Assigns a work item to someone (a display name or email; empty = the user). Asks first.",
      schema = { type = "object", properties = { id = { type = "integer" }, assignee = { type = "string" } },
        required = { "id" } },
      risk = "ask",
      confirm = function(a)
        return "assign #" .. tostring(a.id) .. " to " .. ((a.assignee and a.assignee ~= "") and a.assignee or "you")
      end,
      run = function(args, _, done)
        T.work_item_field(args.id, "assignedTo", function(before)
          T.provider({ "--wi-edit", "set", tostring(args.id), "assignedTo", args.assignee or "" }, nil, function(ok, out, err)
            if not ok then return done(nil, "assigning failed: " .. err) end
            local okd, d = pcall(vim.json.decode, out)
            refresh_board(args.id)
            done("#" .. args.id .. " is assigned to " .. tostring(okd and d.value or args.assignee) .. ".", nil,
              { op = "set_field", id = args.id, field = "assignedTo", value = before or "" })
          end)
        end)
      end,
    },
    {
      name = "move_to_sprint",
      description = "Moves a work item to a sprint, by the sprint's name (\"Sprint 42\") or iteration path. "
        .. "Runs without asking.",
      schema = { type = "object", properties = { id = { type = "integer" }, sprint = { type = "string" } },
        required = { "id", "sprint" } },
      risk = "write",
      run = function(args, _, done)
        sprints(function(list)
          local path
          for _, sp in ipairs(list) do
            if sp.path == args.sprint or (sp.name and sp.name:lower() == args.sprint:lower()) then path = sp.path end
          end
          path = path or args.sprint
          T.work_item_field(args.id, "iterationPath", function(before)
            T.provider({ "--wi-edit", "set", tostring(args.id), "iteration", path }, nil, function(ok, _, err)
              if not ok then return done(nil, "moving it failed: " .. err) end
              refresh_board(args.id)
              done("Moved #" .. args.id .. " to " .. path .. ".", nil,
                before and { op = "set_field", id = args.id, field = "iteration", value = before } or nil)
            end)
          end)
        end)
      end,
    },
    {
      name = "comment_on_work_item",
      description = "Posts a comment in a work item's discussion. Asks first.",
      schema = { type = "object", properties = { id = { type = "integer" }, text = { type = "string" } },
        required = { "id", "text" } },
      risk = "ask",
      confirm = function(a) return "comment on #" .. tostring(a.id) end,
      details = function(a, cb) cb(vim.split(a.text or "", "\n", { plain = true })) end,
      run = function(args, _, done)
        T.provider({ "--wi-edit", "comment", tostring(args.id), args.text }, nil, function(ok, _, err)
          if not ok then return done(nil, "commenting failed: " .. err) end
          refresh_board(args.id)
          done("Commented on #" .. args.id .. ".")
        end)
      end,
    },
  }
end
