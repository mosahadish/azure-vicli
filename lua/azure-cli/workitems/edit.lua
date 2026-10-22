-- lua/azure-cli/workitems/edit.lua: ge - edit a work item (or issue) in
-- one place. A popup in the middle of the item's view, its border and
-- title marked "Editing", lists every field that can change: title,
-- state, assignee, priority, sprint, parent, tags, hours (where the type
-- has them) and, where the host takes it back as written, the description.
--
-- <CR> on a field changes it: text in a one-line popup, a choice from a
-- list. A change is only held - marked "●" with its old value beside it -
-- until <C-s> saves them all (one --wi-edit set each); u takes the one
-- under the cursor back, q / <Esc> closes (asking first when something is
-- held). State and parent are their own popups (gs's, gU's), which save
-- at once.
--
-- M.open(ctx) -> form, from workitems/view.lua, which calls
-- form.refresh(item, parent) after each reload. M.rows and M.value_text
-- are pure, for tests.
local M = {}

local function PROMPT() return require("azure-cli.prompt") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end

-- The hours the provider reports (item.hours), in its order.
M.HOURS = {
  { key = "originalEstimate", label = "Original estimate" },
  { key = "remainingWork", label = "Remaining work" },
  { key = "completedWork", label = "Completed work" },
}

-- "8", "1.5" - hours without a trailing ".0"; "" for none.
function M.hours_text(v)
  if v == nil or v == vim.NIL or v == "" then return "" end
  local n = tonumber(v)
  if not n then return tostring(v) end
  return (string.format("%.2f", n):gsub("%.?0+$", ""))
end

-- The form's rows for `item` on `board` (workitems/board.lua: its host,
-- caps and words): { key, label, kind, value }. kind: "text",
-- "hours", "assign", "priority", "sprint", "editor" (held until saved) or
-- "state", "parent" (their own popups, saved at once).
function M.rows(item, parent, board)
  local rows = {
    { key = "title", label = "Title", kind = "text", value = item.title or "" },
    { key = "state", label = "State", kind = "state", value = item.state or "" },
    { key = "assignedTo", label = "Assigned to", kind = "assign", value = item.assignedTo or "" },
  }
  if type(item.priority) == "number" or board.host ~= "github" then
    rows[#rows + 1] = { key = "priority", label = "Priority", kind = "priority", value = item.priority }
  end
  local sprint = (board.words and board.words.sprint) or "sprint"
  rows[#rows + 1] = { key = "iteration", label = (sprint:gsub("^%l", string.upper)),
    kind = "sprint", value = item.iterationPath or "" }
  rows[#rows + 1] = { key = "parent", label = "Parent", kind = "parent",
    value = parent and ("#" .. tostring(parent.id) .. "  " .. tostring(parent.title or "")) or "" }
  rows[#rows + 1] = { key = "tags", label = board.host == "github" and "Labels" or "Tags", kind = "text",
    value = item.tags or "" }
  -- The hours this item's type has: the provider sends "" for an unset one.
  if type(item.hours) == "table" then
    for _, h in ipairs(M.HOURS) do
      if item.hours[h.key] ~= nil then
        rows[#rows + 1] = { key = h.key, label = h.label, kind = "hours", value = item.hours[h.key] }
      end
    end
  end
  if board.caps and board.caps.description then
    rows[#rows + 1] = { key = "description", label = "Description", kind = "editor", value = item.description or "" }
  end
  return rows
end

-- A row's value as the form shows it. A sprint is named as `sprints` (the
-- board's list) labels it, not by its path.
function M.value_text(row, v, sprints)
  if row.kind == "priority" then return v and ("P" .. tostring(v)) or "(none)" end
  if row.kind == "hours" then
    local t = M.hours_text(v)
    return t == "" and "(none)" or (t .. " h")
  end
  if row.kind == "sprint" and type(v) == "table" then return v.label or v.name or v.path or "" end
  if row.kind == "assign" and type(v) == "table" then return v.label end
  if row.kind == "sprint" then
    for _, sp in ipairs(sprints or {}) do
      if sp.path == v or sp.name == v then return sp.label or sp.name or v end
    end
  end
  if row.kind == "editor" then
    local first = vim.split(tostring(v or ""), "\n", { plain = true })[1] or ""
    local more = tostring(v or ""):find("\n") and " \u{2026}" or ""
    return first == "" and "(none)" or (first .. more)
  end
  v = tostring(v == nil and "" or v)
  return v == "" and "(none)" or v
end

-- What `held[key]` sends: a sprint's path, a person's account (the picker
-- gives { value, label } for someone found in the directory), everything
-- else as text.
local function wire(row, v)
  if row.kind == "sprint" and type(v) == "table" then return v.path end
  if row.kind == "assign" and type(v) == "table" then return v.value end
  if row.kind == "hours" then return M.hours_text(v) end
  return tostring(v)
end

-- ctx: { board, id (the ref), shown, item, parent, sprints (S.WI_SPRINTS_CACHE.list),
--   pick_assignee(current, cb) (optional), state(), parent_pick(),
--   saved(changes) after a save (reload + the dashboard's own patches) }
function M.open(ctx)
  local UI = require("azure-cli.ui")
  UI.link_hl({ AzureCliEditBorder = "DiagnosticWarn", AzureCliEditTitle = "DiagnosticWarn",
    AzureCliEditHeld = "DiagnosticWarn", AzureCliEditOld = "Comment" })
  local B = ctx.board
  local item, parent = ctx.item, ctx.parent
  local rows = M.rows(item, parent, B)
  local held, failed = {}, {}
  local saving = false
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "azure-cli-wi-edit"
  local width = math.min(90, vim.o.columns - 4)
  local function title()
    return " \u{270E} Editing " .. ((item.type and item.type ~= "") and (item.type .. " ") or "") .. "#" .. ctx.shown .. " "
  end
  local cfg = { relative = "editor", width = width, height = #rows, style = "minimal", border = UI.border(),
    row = math.max(0, math.floor((vim.o.lines - #rows - 4) / 2)), col = math.floor((vim.o.columns - width) / 2),
    title = title(), title_pos = "left" }
  local win = vim.api.nvim_open_win(buf, true, cfg)
  UI.wo(win, "winhighlight", UI.FLOAT_HL .. ",FloatBorder:AzureCliEditBorder,FloatTitle:AzureCliEditTitle")
  UI.wo(win, "cursorline", true)
  UI.wo(win, "wrap", false)
  local ns = vim.api.nvim_create_namespace("azure_cli_wi_edit")
  local form = {}

  local function count()
    local n = 0
    for _ in pairs(held) do n = n + 1 end
    return n
  end
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local lines, marks = {}, {}
    local n = count()
    for i, r in ipairs(rows) do
      local has = held[r.key] ~= nil
      local mark = failed[r.key] and "\u{2716}" or (has and "\u{25CF}" or " ")
      local label = string.format(" %s %-18s", mark, r.label)
      local now = M.value_text(r, has and held[r.key] or r.value, ctx.sprints)
      local line = label .. now
      local old_s
      if has then
        old_s = #line
        line = line .. "   (was " .. M.value_text(r, r.value, ctx.sprints) .. ")"
      end
      -- One row each, cut to the window ("(was …)" can be long).
      if vim.fn.strdisplaywidth(line) > width - 1 then line = UI.fit(line, width - 1) end
      if old_s and old_s >= #line then old_s = nil end
      lines[#lines + 1] = line
      marks[#marks + 1] = { row = i - 1, has = has, failed = failed[r.key], label_end = #label, old_s = old_s }
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_add_highlight(buf, ns, m.failed and "ErrorMsg" or (m.has and "AzureCliEditHeld" or "AzureCliWiViewLabel"),
        m.row, 0, m.label_end)
      if m.old_s then vim.api.nvim_buf_add_highlight(buf, ns, "AzureCliEditOld", m.row, m.old_s, -1) end
    end
    local foot = " <CR> change \u{00B7} " .. (n > 0 and ("<C-s> save " .. n .. " \u{00B7} u undo \u{00B7} ") or "")
      .. "q close "
    pcall(vim.api.nvim_win_set_config, win, { title = title(), title_pos = "left", footer = foot, footer_pos = "right" })
  end

  local function back()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  end
  local function row_here()
    local l = vim.api.nvim_win_get_cursor(win)[1]
    return rows[l]
  end
  local function hold(r, v)
    failed[r.key] = nil
    local same = (r.kind == "hours" and M.hours_text(v) == M.hours_text(r.value))
      or (r.kind == "sprint" and type(v) == "table" and v.path == r.value)
      or (r.kind ~= "sprint" and tostring(v) == tostring(r.value == nil and "" or r.value))
    held[r.key] = (not same) and v or nil
    render()
    back()
  end

  local function change()
    local r = row_here()
    if not r or saving then return end
    local cur = held[r.key] ~= nil and held[r.key] or r.value
    if r.kind == "state" then return ctx.state() end
    if r.kind == "parent" then return ctx.parent_pick() end
    if r.kind == "text" then
      return PROMPT().input({ prompt = r.label, default = tostring(cur or ""), allow_empty = r.key ~= "title",
        silent = true }, function(t)
        if t ~= nil then hold(r, t) else back() end
      end)
    end
    if r.kind == "hours" then
      return PROMPT().input({ prompt = r.label .. " (hours; empty clears)", default = M.hours_text(cur),
        allow_empty = true, silent = true }, function(t)
        if t == nil then return back() end
        t = t:gsub(",", ".")
        if t ~= "" and not tonumber(t) then
          notify("\"" .. t .. "\" isn't a number of hours.", vim.log.levels.WARN)
          return back()
        end
        hold(r, t == "" and "" or tonumber(t))
      end)
    end
    if r.kind == "assign" then
      local function got(v, name)
        if v == nil then return back() end
        hold(r, (name and name ~= v) and { value = v, label = name } or v)
      end
      if ctx.pick_assignee then return ctx.pick_assignee(tostring(cur or ""), got) end
      return PROMPT().input({ prompt = "Assign to (empty = me)", default = tostring(cur or ""), allow_empty = true,
        silent = true }, got)
    end
    if r.kind == "priority" then
      return PROMPT().select({ prompt = "Priority", items = { 1, 2, 3, 4 }, silent = true,
        format = function(p) return "P" .. p end,
        current = function(p) return tostring(p) == tostring(cur) end }, function(p)
        if p then hold(r, p) else back() end
      end)
    end
    if r.kind == "sprint" then
      local list = ctx.sprints or {}
      if #list == 0 then return notify("The " .. r.label:lower() .. " list isn't loaded yet.", vim.log.levels.WARN) end
      local at = type(cur) == "table" and cur.path or cur
      return PROMPT().select({ prompt = r.label, items = list, silent = true,
        format = function(sp) return sp.label or sp.name or sp.path end,
        current = function(sp) return sp.path == at or sp.name == at end }, function(sp)
        if sp then hold(r, sp) else back() end
      end)
    end
    if r.kind == "editor" then
      local EDITOR = require("azure-cli.editor")
      return EDITOR.open({ title = EDITOR.format_title("description", { id = ctx.shown }), anchor = "center",
        initial = tostring(cur or ""), allow_empty = true,
        on_submit = function(text) hold(r, text) end, on_cancel = function() back() end })
    end
  end

  local function close(force)
    if not force and count() > 0 then
      return PROMPT().confirm({ title = "Discard " .. count() .. " unsaved change" .. (count() == 1 and "" or "s") .. "?" }, function(yes)
        if yes then close(true) else back() end
      end)
    end
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end

  -- Each held change, one --wi-edit set at a time (in the rows' order);
  -- what fails stays held and marked.
  local function save()
    if saving or count() == 0 then return end
    saving = true
    local todo, done = {}, {}
    for _, r in ipairs(rows) do
      if held[r.key] ~= nil then todo[#todo + 1] = r end
    end
    notify("Saving " .. #todo .. " change" .. (#todo == 1 and "" or "s") .. " to #" .. ctx.shown .. "\u{2026}")
    local errors = {}
    local function step(i)
      local r = todo[i]
      if not r then
        saving = false
        if #done > 0 then ctx.saved(done) end
        if #errors == 0 then
          notify("Saved #" .. ctx.shown .. ".")
          held = {}
          return close(true)
        end
        notify("Some changes to #" .. ctx.shown .. " didn't save:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
        return render()
      end
      local v = held[r.key]
      local err = {}
      B.run({ "--wi-edit", "set", ctx.id, r.key, wire(r, v) }, {
        detach = true, stdout_buffered = true, stderr_buffered = true,
        on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              done[#done + 1] = { key = r.key, value = wire(r, v), from = r.value,
                label = type(v) == "table" and v.label or nil }
              held[r.key] = nil
            else
              failed[r.key] = true
              errors[#errors + 1] = r.label .. ": " .. require("azure-cli.shell").job_error("#" .. ctx.shown, code, err)
            end
            step(i + 1)
          end)
        end,
      })
    end
    step(1)
  end

  local function undo()
    local r = row_here()
    if r and held[r.key] ~= nil then
      held[r.key], failed[r.key] = nil, nil
      render()
    end
  end

  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", change, kopts)
  vim.keymap.set({ "n", "i" }, "<C-s>", save, kopts)
  vim.keymap.set("n", "u", undo, kopts)
  vim.keymap.set("n", "q", function() close(false) end, kopts)
  vim.keymap.set("n", "<Esc>", function() close(false) end, kopts)
  render()
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  function form.valid() return vim.api.nvim_win_is_valid(win) end
  function form.focus() back() end
  -- After the view reloads (a state or parent change, a save): the fields'
  -- new values; held changes stay held.
  function form.refresh(new_item, new_parent)
    item, parent = new_item or item, new_parent
    rows = M.rows(item, parent, B)
    pcall(vim.api.nvim_win_set_config, win, { height = #rows })
    render()
  end
  form.close = close
  return form
end

return M
