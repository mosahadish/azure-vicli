-- lua/azure-cli/workitems/parent.lua: gU - change or remove a work item's
-- parent, from the work-items / issues dashboard and the item view.
--
-- M.choose(B, it) offers the candidates (--wi-list parents: on Azure the
-- project's open items on a higher backlog level, on GitHub the project's
-- open issues but the issue itself and what's under it), "(type an id…)"
-- and "(no parent)", then runs --wi-edit set-parent and tells every screen
-- showing the item (M.changed - the chat's set_work_item_parent calls it
-- too). The provider's own error says what didn't take.
--
-- M.items is pure, for tests.
local M = {}

-- The picker's lines: `recs` (list records) then the two fixed choices.
-- `current` is the item's parent id (nil: none), marked "(current)".
function M.items(recs, current, host)
  local out = {}
  for _, r in ipairs(recs) do
    local is_cur = current ~= nil and tostring(r.id) == tostring(current)
    out[#out + 1] = {
      label = "#" .. tostring(r.id) .. "  " .. (r.type or "") .. "  [" .. (r.state or "") .. "]  " .. (r.title or "")
        .. ((host == "github" and r.repo and r.repo ~= "") and ("  (" .. r.repo .. ")") or "")
        .. (is_cur and "  (current)" or ""),
      value = (host == "github" and r.key) or tostring(r.id),
    }
  end
  out[#out + 1] = { label = "(type an id\u{2026})", typed = true }
  out[#out + 1] = { label = "(no parent)" .. (current == nil and "  (current)" or ""), value = "none" }
  return out
end

-- Splits --wi-list parents' output: its {"_parents"} line and the records.
function M.parse(lines)
  local meta, recs = {}, {}
  for _, l in ipairs(lines or {}) do
    if l:gsub("%s", "") ~= "" then
      local ok, d = pcall(vim.json.decode, l, { luanil = { object = true, array = true } })
      if ok and type(d) == "table" then
        if d._parents then meta = d else recs[#recs + 1] = d end
      end
    end
  end
  return meta, recs
end

-- Whether cache/view key `k` (an id, or GitHub's owner~repo~n) is item `id`.
local function is_ref(k, id)
  id = tostring(id)
  return k == id or k:match("~(%d+)$") == id
end

-- After `ref` (id `id`) moved from parent `old` to `new` (ids, nil = none)
-- on board B: the dashboard regroups its tree (S.WI_PARENT_CHANGED), and the
-- detail caches and open views of the item and both parents are refreshed.
function M.changed(B, ref, id, old, new)
  local S = B.state
  if S.WI_PARENT_CHANGED then pcall(S.WI_PARENT_CHANGED, ref, id, old, new) end
  for _, x in ipairs({ id, old, new }) do
    if x ~= nil then
      for k in pairs(S.WI_DETAIL_CACHE or {}) do
        if is_ref(k, x) then S.WI_DETAIL_CACHE[k] = nil end
      end
      for k, reload in pairs(S.WI_VIEW_RELOAD or {}) do
        if is_ref(k, x) then vim.schedule(reload) end
      end
    end
  end
end

-- Runs set-parent for `it` (a record: id, key on GitHub) to `value` (an
-- id/ref or "none"); done(ok) after.
function M.set(B, it, value, done)
  local SHELL = require("azure-cli.shell")
  local ref = B.ref(it)
  local shown = "#" .. tostring(it.id)
  SHELL.notify("Moving " .. shown .. " \u{2026}")
  local out, err = {}, {}
  B.run({ "--wi-edit", "set-parent", ref, value }, {
    detach = true,  -- finish the write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          SHELL.notify("Moving " .. shown .. " failed: " .. SHELL.job_error(B.words.item .. " " .. shown, code, err),
            vim.log.levels.ERROR)
          if done then done(false) end
          return
        end
        local ok, res = pcall(vim.json.decode, table.concat(out, ""), { luanil = { object = true, array = true } })
        res = ok and type(res) == "table" and res or {}
        if res.unchanged then
          SHELL.notify(shown .. (res.parent and (" is already under #" .. tostring(res.parent)) or " has no parent already")
            .. " - nothing changed.")
        else
          SHELL.notify(res.parent and ("Moved " .. shown .. " under #" .. tostring(res.parent) .. ".")
            or (shown .. " has no parent now."))
          M.changed(B, ref, it.id, res.previous, res.parent)
        end
        if done then done(true) end
      end)
    end,
  })
end

-- gU: the picker for `it` (its record; it.parentId its parent, if known),
-- then the move.
function M.choose(B, it, done)
  local SHELL = require("azure-cli.shell")
  local UI = require("azure-cli.ui")
  local shown = "#" .. tostring(it.id)
  local out, err = {}, {}
  SHELL.notify("Finding parents for " .. shown .. " \u{2026}")
  B.run({ "--wi-list", "parents", B.ref(it) }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          SHELL.notify("Couldn't list parents for " .. shown .. ": "
            .. SHELL.job_error(B.words.item .. " " .. shown, code, err), vim.log.levels.ERROR)
          return
        end
        local meta, recs = M.parse(out)
        if meta.subIssues == false then
          SHELL.notify("This GitHub server has no sub-issues, so issues can't have a parent here.",
            vim.log.levels.WARN)
          return
        end
        local title = "Parent of " .. shown
          .. ((meta.levels == false and B.host ~= "github") and " (backlog levels unknown: any other type)" or "")
        UI.pick_popup({ title = title, items = M.items(recs, it.parentId, B.host), action = "move" }, function(choice)
          if not choice.typed then return M.set(B, it, choice.value, done) end
          require("azure-cli.prompt").input({ prompt = "Parent of " .. shown .. " (id, or none):" }, function(t)
            t = vim.trim(t or ""):gsub("^#", "")
            if t ~= "" then M.set(B, it, t, done) end
          end)
        end)
      end)
    end,
  })
end

return M
