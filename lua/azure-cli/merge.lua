-- lua/azure-cli/merge.lua: the "complete PR" dialog shared by the PR
-- dashboard's gm and the reviewer's gm - pick a merge type, toggle
-- "complete associated work items" / "delete source branch" / "auto-complete
-- when policies pass" (instead of completing now), see the
-- build state, unresolved thread count and votes (with a warning when any
-- of them argue against merging), then confirm. The dialog itself is
-- M.dialog; everything it renders comes from the pure helpers above it
-- (M.build_label / M.warnings / M.lines), which tests/test-merge.lua runs
-- under plain luajit.
local M = {}

-- Merge strategies offered when completing a PR (label + the key --complete
-- takes): Azure DevOps' four, unless the dialog's spec.methods (the PR's
-- host's, lua/azure-cli/hosts.lua) says otherwise.
M.MERGE_TYPES = require("azure-cli.hosts").HOSTS.azure.merge_methods

local function methods(st) return st.methods or M.MERGE_TYPES end

-- The dialog's words per host: Azure completes a PR, GitHub merges one.
local WORDS = {
  azure = { verb = "complete", title = "Complete PR ", auto = "Auto-complete when policies pass",
    auto_verb = "auto-complete", ing = "Completing", done = "completed" },
  github = { verb = "merge", title = "Merge PR ", auto = "Auto-merge when requirements pass",
    auto_verb = "auto-merge", ing = "Merging", done = "merged" },
}
local function words(spec) return WORDS[spec and spec.host or "azure"] or WORDS.azure end

-- The same words for texts outside the dialog (the reviewer's notifies and
-- winbars), plus `name`, how they name the PR: the host's ref where it has
-- one ("owner/repo#7" on GitHub, lua/azure-cli/hosts.lua), else "PR #<id>".
-- `pr` is the PR's record (nil: unknown, read as Azure), `id` its number.
function M.pr_words(pr, id)
  local HOSTS = require("azure-cli.hosts")
  local w = {}
  for k, v in pairs(words({ host = HOSTS.host(pr) })) do w[k] = v end
  w.name = (type(pr) == "table" and HOSTS.caps(pr).ref) and HOSTS.ref(pr) or ("PR #" .. tostring(id))
  return w
end

-- Which dialog row holds what, so <Space> on a row knows what to toggle.
-- A row the PR's host doesn't have (spec.work_items / spec.auto false:
-- GitHub completes no work items, and a repo may not allow auto-merge) is
-- left out and the ones below move up. M.ROW is Azure's, every row there.
function M.rows(spec)
  spec = spec or {}
  local rows, n = { merge = 4 }, 4
  if spec.work_items ~= false then n = n + 1 rows.work_items = n end
  n = n + 1 rows.delete_branch = n
  if spec.auto ~= false then n = n + 1 rows.auto = n end
  rows.last = n
  return rows
end
M.ROW = M.rows({})

-- <Space> on `row`: flips the checkbox there (or cycles the merge type on
-- its row). Returns true when the state changed, false on any other row.
function M.toggle(st, row, spec)
  local R = M.rows(spec)
  if row == R.work_items then st.work_items = not st.work_items
  elseif row == R.delete_branch then st.delete_branch = not st.delete_branch
  elseif row == R.auto then st.auto = not st.auto
  elseif row == R.merge then st.merge = st.merge % #methods(st) + 1
  else return false end
  return true
end

-- Whether <CR> may go ahead: true, or false and why. spec.blockers are the
-- reasons the host would refuse a merge now (github_host.py's
-- mergeability); auto-merge is for waiting them out, except a conflict,
-- which nothing waits out.
function M.confirm_allowed(spec, st)
  local blockers = spec.blockers or {}
  if st.auto then
    if spec.conflict and spec.host == "github" then return false, "merge conflict: resolve it first" end
    return true
  end
  if #blockers > 0 then return false, "Can't " .. words(spec).verb .. ": " .. blockers[1] end
  return true
end

-- `spec` with what the PR's host says (lua/azure-cli/hosts.lua): its merge
-- methods, which rows it has, its wording - and, for GitHub, `m`, the
-- mergeability --get-pr read just now (nil when that failed: the checks
-- are then unknown, and GitHub's own refusal is the word on it).
function M.host_spec(spec, pr, m)
  local HOSTS = require("azure-cli.hosts")
  local caps = HOSTS.caps(pr)
  spec.methods = caps.merge_methods
  spec.host = HOSTS.host(pr)
  spec.work_items = caps.complete_work_items ~= false
  spec.auto = caps.auto_complete ~= false or (spec.auto_on and true or false)
  if spec.host ~= "github" then return spec end
  spec.ref = HOSTS.ref(pr)
  if type(m) ~= "table" then
    spec.warnings = { "checks unknown (GitHub didn't answer)" }
    spec.delete_on_merge = caps.delete_branch_on_merge and true or false
    return spec
  end
  spec.blockers, spec.warnings, spec.checks = m.blockers or {}, m.warnings or {}, m.checks or {}
  spec.conflict = spec.conflict or m.conflict and true or false
  spec.delete_on_merge = m.deleteBranchOnMerge and true or false
  if m.autoMerge ~= nil then spec.auto_on = m.autoMerge and true or false end
  return spec
end

-- For a GitHub PR, its mergeability as --get-pr reads it now: cb(m), or
-- cb(nil) when the call fails. `argv` is the provider's --get-pr command,
-- `env` the PR's AZVICLI_* (nil: this process's own, the reviewer's).
function M.fetch_state(argv, env, cb)
  local out = {}
  require("azure-cli.rpc").run(argv, {
    env = env, stdout_buffered = true, stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then return cb(nil) end
        local ok, rec = pcall(vim.json.decode, table.concat(out, "\n"))
        cb(ok and type(rec) == "table" and type(rec.mergeability) == "table" and rec.mergeability or nil)
      end)
    end,
  })
end

local CHECK_GLYPH = { ok = "\u{2713}", failed = "\u{2717}", pending = "\u{25CF}" }
local MAX_CHECKS = 8

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
-- With `auto` (setting auto-complete rather than completing now) a build
-- that isn't green yet is no warning: waiting for it is the point.
function M.warnings(spec, auto)
  local w = {}
  local b = spec.build_label
  if b and not auto and not b:find("\u{2713}", 1, true) then w[#w + 1] = b end
  if spec.conflict then w[#w + 1] = "merge conflict" end
  local n = spec.unresolved
  if type(n) == "number" and n > 0 then
    w[#w + 1] = n .. " unresolved thread" .. (n == 1 and "" or "s")
  end
  for _, x in ipairs(spec.warnings or {}) do w[#w + 1] = x end
  return w
end

-- The dialog's lines for `spec` and the current toggle state `st`
-- ({ merge = index into st.methods (default MERGE_TYPES), work_items = bool,
-- delete_branch = bool, auto = bool }).
function M.lines(spec, st)
  local rule = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
    .. "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
    .. "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
    .. "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
  local W = words(spec)
  local title = (spec.title and spec.title ~= "") and ("  " .. spec.title) or ""
  local source, target = spec.source or "", spec.target or ""
  local blabel = spec.build_label
  local unresolved = spec.unresolved
  local lines = {
    W.title .. (spec.ref or ("#" .. tostring(spec.id))) .. title,
    "  " .. source .. " \u{2192} " .. target,
    rule,
    "Merge type: " .. methods(st)[st.merge].label,
  }
  if spec.work_items ~= false then
    lines[#lines + 1] = (st.work_items and "[x]" or "[ ]") .. " Complete associated work items"
  end
  if st.auto and spec.delete_on_merge ~= nil then
    -- GitHub's auto-merge deletes the branch only by the repo's own setting.
    lines[#lines + 1] = "[-] Delete source branch: the repo's setting decides ("
      .. (spec.delete_on_merge and "on" or "off") .. ")"
  else
    lines[#lines + 1] = (st.delete_branch and "[x]" or "[ ]") .. " Delete source branch"
      .. (source ~= "" and (" (" .. source .. ")") or "")
  end
  if spec.auto ~= false then
    lines[#lines + 1] = (st.auto and "[x]" or "[ ]") .. " " .. W.auto
      .. (spec.auto_on and (" (on" .. ((spec.auto_by or "") ~= "" and (", set by " .. spec.auto_by) or "") .. ")") or "")
  end
  lines[#lines + 1] = rule
  lines[#lines + 1] = "Build: " .. (blabel and blabel:gsub("^build ", "") or "none") .. "   Threads: "
    .. (type(unresolved) == "number" and tostring(unresolved) or "?") .. " unresolved   Votes: "
    .. (spec.vote_ratio or "?")
  local checks = spec.checks or {}
  for i, c in ipairs(checks) do
    if i > MAX_CHECKS then
      lines[#lines + 1] = "  \u{2026} " .. (#checks - MAX_CHECKS) .. " more checks"
      break
    end
    lines[#lines + 1] = "  " .. (CHECK_GLYPH[c.state] or "?") .. " " .. tostring(c.name or "")
      .. (c.required and "  (required)" or "")
  end
  local blockers = spec.blockers or {}
  if #blockers > 0 then
    lines[#lines + 1] = (st.auto and (W.auto_verb:gsub("^%l", string.upper) .. " waits for: ") or "\u{26D4} Can't " .. W.verb .. ": ")
      .. table.concat(blockers, "; ")
  end
  local warnings = M.warnings(spec, st.auto)
  if #warnings > 0 then
    lines[#lines + 1] = "\u{26A0} " .. table.concat(warnings, ", ")
      .. ((#blockers > 0 and not st.auto) and "" or (st.auto and (" - set " .. W.auto_verb .. " anyway?") or " - merge anyway?"))
  end
  lines[#lines + 1] = rule
  lines[#lines + 1] = "<Space>: toggle   m: merge type   <CR>: "
    .. (st.auto and ("set " .. W.auto_verb) or W.verb)
    .. (spec.auto_on and ("   x: cancel " .. W.auto_verb) or "") .. "   q: close"
  return lines
end

-- Open the dialog for `spec` = { id, title, source, target, build_label,
-- conflict, unresolved, vote_ratio, auto_on, auto_by, on_auto_off,
-- methods, host, ref, work_items, auto, delete_on_merge, blockers,
-- warnings, checks } (only
-- `id` is required; `unresolved` is a number, or nil when unknown;
-- `auto_on`/`auto_by` say auto-complete is already set, and by whom;
-- `work_items`/`auto` false leave those rows out; `blockers`, `warnings`
-- and `checks` are github_host.py's mergeability, `delete_on_merge` the
-- repo's own branch setting). The
-- cursor starts on the first checkbox; <Space> toggles the checkbox under
-- it (and cycles the merge type on its row), `m` cycles the merge type
-- from anywhere, <CR> completes - or, with the auto-complete box checked
-- (it starts checked when `auto_on`), sets auto-complete with those
-- options; while M.confirm_allowed says no, <CR> says why and the dialog
-- stays. `on_confirm(merge_type, delete_branch, work_items, auto)` runs
-- after the window has closed; cancelling runs nothing. When `auto_on`,
-- `x` closes the dialog and runs `spec.on_auto_off()` to cancel it.
function M.dialog(spec, on_confirm)
  local st = { merge = 1, work_items = spec.work_items ~= false, delete_branch = true,
    auto = spec.auto_on and true or false, methods = spec.methods }
  local R = M.rows(spec)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  local win

  -- Sized for the wider of both auto states, so checking the box doesn't
  -- push the hint line past the border, but no wider than the screen; the
  -- height follows the line count, wrapped (the build warning and the
  -- blockers come and go with it).
  local width = 20
  for _, auto in ipairs({ false, true }) do
    local probe = { merge = st.merge, work_items = st.work_items, delete_branch = st.delete_branch, auto = auto,
      methods = st.methods }
    for _, l in ipairs(M.lines(spec, probe)) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  end
  width = math.max(20, math.min(width, vim.o.columns - 4))
  local function height(lines)
    local h = 0
    for _, l in ipairs(lines) do h = h + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width)) end
    return math.min(h, math.max(1, vim.o.lines - 4))
  end

  local function draw()
    local lines = M.lines(spec, st)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_height(win, height(lines)) end
  end
  draw()

  local lines = M.lines(spec, st)
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height(lines)) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height(lines),
    style = "minimal",
    border = require("azure-cli.ui").border(),
  })
  local UI = require("azure-cli.ui")
  UI.wo(win, "wrap", true)
  UI.wo(win, "linebreak", true)
  UI.wo(win, "breakindent", true)
  UI.float_hl(win)
  vim.api.nvim_win_set_cursor(win, { R.work_items or R.delete_branch, 0 })

  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "m", function()
    st.merge = st.merge % #methods(st) + 1
    draw()
  end, kopts)
  vim.keymap.set("n", "<Space>", function()
    if M.toggle(st, vim.api.nvim_win_get_cursor(win)[1], spec) then draw() end
  end, kopts)
  vim.keymap.set("n", "q", "<Cmd>close<CR>", kopts)
  vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", kopts)
  vim.keymap.set("n", "<CR>", function()
    local ok, why = M.confirm_allowed(spec, st)
    if not ok then
      vim.api.nvim_echo({ { why, "WarningMsg" } }, false, {})
      return
    end
    local mt = methods(st)[st.merge]
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    on_confirm(mt, st.delete_branch, st.work_items, st.auto)
  end, kopts)
  if spec.auto_on and spec.on_auto_off then
    vim.keymap.set("n", "x", function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      spec.on_auto_off()
    end, kopts)
  end
end

return M
