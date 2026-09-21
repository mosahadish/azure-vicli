-- lua/azure-cli/merge.lua: the "complete PR" dialog shared by the PR
-- dashboard's gm and the reviewer's gm - pick a merge type, toggle
-- "complete associated work items" / "delete source branch", see the
-- build state, unresolved thread count and votes (with a warning when any
-- of them argue against merging), then confirm. The dialog itself is
-- M.dialog; everything it renders comes from the pure helpers above it
-- (M.build_label / M.warnings / M.lines), which tests/test-merge.lua runs
-- under plain luajit.
local M = {}

-- Merge strategies offered when completing a PR (label + ADO strategy key).
M.MERGE_TYPES = {
  { key = "squash",        label = "Squash commit" },
  { key = "noFastForward", label = "Merge (no fast forward)" },
  { key = "rebase",        label = "Rebase and fast-forward" },
  { key = "rebaseMerge",   label = "Semi-linear merge" },
}

-- Which dialog row holds what, so <Space> on a row knows what to toggle.
M.ROW = { merge = 4, work_items = 5, delete_branch = 6 }

-- <Space> on `row`: flips the checkbox there (or cycles the merge type on
-- its row). Returns true when the state changed, false on any other row.
function M.toggle(st, row)
  if row == M.ROW.work_items then st.work_items = not st.work_items
  elseif row == M.ROW.delete_branch then st.delete_branch = not st.delete_branch
  elseif row == M.ROW.merge then st.merge = st.merge % #M.MERGE_TYPES + 1
  else return false end
  return true
end

-- Compact build-validation label ("build ✓", "build ● (queue #2)", ...)
-- from a PR record's buildStatus/queuePosition, or nil when unknown/none.
function M.build_label(pr)
  local s = pr and pr.buildStatus or nil
  if s == "succeeded" then return "build \u{2713}" end
  if s == "failed" then return "build \u{2717}" end
  if s == "expired" then return "build \u{21BB}" end
  if s == "running" then
    if pr and type(pr.queuePosition) == "number" and pr.queuePosition > 0 then
      return "build \u{25CF} (queue #" .. tostring(pr.queuePosition) .. ")"
    end
    return "build \u{25CF}"
  end
  return nil
end

-- What should give pause before merging: a build that isn't green, a merge
-- conflict, threads nobody has resolved. `spec` is the table M.dialog takes.
function M.warnings(spec)
  local w = {}
  local b = spec.build_label
  if b and not b:find("\u{2713}", 1, true) then w[#w + 1] = b end
  if spec.conflict then w[#w + 1] = "merge conflict" end
  local n = spec.unresolved
  if type(n) == "number" and n > 0 then
    w[#w + 1] = n .. " unresolved thread" .. (n == 1 and "" or "s")
  end
  return w
end

-- The dialog's lines for `spec` and the current toggle state `st`
-- ({ merge = index into MERGE_TYPES, work_items = bool, delete_branch = bool }).
function M.lines(spec, st)
  local rule = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
    .. "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
    .. "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
    .. "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
  local title = (spec.title and spec.title ~= "") and ("  " .. spec.title) or ""
  local source, target = spec.source or "", spec.target or ""
  local blabel = spec.build_label
  local unresolved = spec.unresolved
  local lines = {
    "Complete PR #" .. tostring(spec.id) .. title,
    "  " .. source .. " \u{2192} " .. target,
    rule,
    "Merge type: " .. M.MERGE_TYPES[st.merge].label,
    (st.work_items and "[x]" or "[ ]") .. " Complete associated work items",
    (st.delete_branch and "[x]" or "[ ]") .. " Delete source branch"
      .. (source ~= "" and (" (" .. source .. ")") or ""),
    rule,
    "Build: " .. (blabel and blabel:gsub("^build ", "") or "none") .. "   Threads: "
      .. (type(unresolved) == "number" and tostring(unresolved) or "?") .. " unresolved   Votes: "
      .. (spec.vote_ratio or "?"),
  }
  local warnings = M.warnings(spec)
  if #warnings > 0 then
    lines[#lines + 1] = "\u{26A0} " .. table.concat(warnings, ", ") .. " - merge anyway?"
  end
  lines[#lines + 1] = rule
  lines[#lines + 1] = "<Space>: toggle   m: merge type   <CR>: complete   q: cancel"
  return lines
end

-- Open the dialog for `spec` = { id, title, source, target, build_label,
-- conflict, unresolved, vote_ratio } (only `id` is required; `unresolved`
-- is a number, or nil when unknown). The cursor starts on the first
-- checkbox; <Space> toggles the checkbox under it (and cycles the merge
-- type on its row), `m` cycles the merge type from anywhere, <CR>
-- completes. `on_confirm(merge_type, delete_branch, work_items)` runs after
-- the window has closed; cancelling runs nothing.
function M.dialog(spec, on_confirm)
  local st = { merge = 1, work_items = true, delete_branch = true }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"

  local function draw()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(spec, st))
    vim.bo[buf].modifiable = false
  end
  draw()

  local lines = M.lines(spec, st)
  local width = 20
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
  })
  local UI = require("azure-cli.ui")
  UI.wo(win, "wrap", true)
  UI.wo(win, "linebreak", true)
  UI.wo(win, "breakindent", true)
  vim.api.nvim_win_set_cursor(win, { M.ROW.work_items, 0 })

  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "m", function()
    st.merge = st.merge % #M.MERGE_TYPES + 1
    draw()
  end, kopts)
  vim.keymap.set("n", "<Space>", function()
    if M.toggle(st, vim.api.nvim_win_get_cursor(win)[1]) then draw() end
  end, kopts)
  vim.keymap.set("n", "q", "<Cmd>close<CR>", kopts)
  vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", kopts)
  vim.keymap.set("n", "<CR>", function()
    local mt = M.MERGE_TYPES[st.merge]
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    on_confirm(mt, st.delete_branch, st.work_items)
  end, kopts)
end

return M
