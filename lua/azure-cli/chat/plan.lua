-- lua/azure-cli/chat/plan.lua: the agent's plan - what it means to change,
-- and why - shown to the user before any code changes, like a PR in the
-- reviewer: a tab with the plan's sections on the left and the plan itself
-- (rendered markdown, from a template) on the right, the chat alongside.
--
-- The agent writes it with submit_plan (one plan per work item or PR; a
-- new call is a new revision of the same plan). The user reads it, asks
-- about any line with ga - "why did you choose this here?" - and gets the
-- answer under that line (chat/threads.lua), then approves it (gA) or asks
-- for changes (gR). gf opens the plan's file to edit it by hand; saving it
-- makes that the version the agent gets.
--
-- The gate: start_fix and start_story (chat/tools_fix.lua) refuse until the
-- plan for their PR / work item is approved (setup({ chat = { plan_first =
-- true | false | "stories" } }), default true). Pushing the change
-- (commit_and_push_fix) marks the plan done, so the next change needs a
-- plan of its own.
--
-- Kept under stdpath("data")/azure-cli-chat/plans/: <key>.md (the plan's
-- text, the file gf edits) and <key>.json (its title, status, revisions
-- and questions), key = "wi-<id>" or "pr-<id>".
--
--   pure:   key, target_label, sections, section_at, missing, gate_check,
--           approval_message, revise_message, status_label
--   Neovim: load, save, open, refresh, describe, gate, mark_done, tools
local M = {}

M.TEMPLATE = [[# <Title>

## Goal
What this change achieves, in a sentence or two.

## Approach
How you'll do it, and why this way - the alternatives you considered and why not them.

## Files
- `path/to/file` - what changes there, and why

## Risks
What could break, and how the change avoids or contains it.

## Test plan
How it gets checked: the tests you'll add or run, what to try by hand. Put the command that runs them in a sh
code block - the user can run it on your change.

## Open questions
Anything the user should decide before you start (or "None").]]

local function STORE() return require("azure-cli.chat.store") end
local function UI() return require("azure-cli.ui") end
local function KEYS() return require("azure-cli.keys") end
local function THREADS() return require("azure-cli.chat.threads") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function config() return require("azure-cli.config").get().chat or {} end

function M.template() return config().plan_template or M.TEMPLATE end

-- ---------------------------------------------------------------------------
-- Pure helpers.

-- "wi-3001" for { work_item_id = 3001 }, "pr-101" for { pr_id = 101 }, nil
-- for neither.
function M.key(target)
  if type(target) ~= "table" then return nil end
  if target.work_item_id then return "wi-" .. tostring(target.work_item_id) end
  if target.pr_id then return "pr-" .. tostring(target.pr_id) end
  return nil
end

function M.target_label(target)
  if target.work_item_id then return "#" .. tostring(target.work_item_id) end
  return "PR !" .. tostring(target.pr_id)
end

-- The markdown headings of `lines`: { { title, level, line, items } },
-- items = the list entries under it (the Files section's count). Lines in
-- ``` fences don't count. Pure.
function M.sections(lines)
  local out, fenced = {}, false
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    if not fenced then
      local hashes, title = l:match("^(#+)%s+(.-)%s*$")
      if hashes and title ~= "" then
        out[#out + 1] = { title = title, level = #hashes, line = i, items = 0 }
      elseif #out > 0 and l:match("^%s*[-*+]%s+%S") then
        out[#out].items = out[#out].items + 1
      end
    end
  end
  return out
end

-- The section line `line` is in (the last heading at or above it). Pure.
function M.section_at(sections, line)
  local cur
  for _, s in ipairs(sections) do
    if s.line <= line then cur = s else break end
  end
  return cur
end

-- The paths the plan's Files section lists: each entry's first `code`
-- span, else its first word (a leading "./" dropped). Pure.
function M.planned_files(lines)
  local out, inside, fenced = {}, false, false
  for _, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    local hashes, title = l:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced then
      inside = #hashes == 2 and title:lower():find("file", 1, true) ~= nil
    elseif inside and not fenced then
      local item = l:match("^%s*[-*+]%s+(.+)$")
      if item then
        local path = item:match("`([^`]+)`") or item:match("^(%S+)")
        path = path and path:gsub("^%./", ""):gsub("[,:;]$", "")
        if path and path ~= "" then out[#out + 1] = path end
      end
    end
  end
  return out
end

local function same_path(a, b)
  a, b = a:gsub("\\", "/"), b:gsub("\\", "/")
  return a == b or a:sub(-#b - 1) == "/" .. b or b:sub(-#a - 1) == "/" .. a
end

-- The change's files against the plan's: { unplanned = changed paths the
-- plan doesn't list, missing = planned paths the change doesn't touch }.
-- A planned path matches a changed one when either ends with the other
-- (the plan may say `throttle.py` for src/throttle.py). Pure.
function M.check_files(planned, changed)
  local out = { unplanned = {}, missing = {} }
  for _, c in ipairs(changed) do
    local hit = false
    for _, p in ipairs(planned) do if same_path(c, p) then hit = true end end
    if not hit then out.unplanned[#out.unplanned + 1] = c end
  end
  for _, p in ipairs(planned) do
    local hit = false
    for _, c in ipairs(changed) do if same_path(c, p) then hit = true end end
    if not hit then out.missing[#out.missing + 1] = p end
  end
  return out
end

-- The plan line that carries out a step: the line whose text is `anchor`
-- nearest to `line` (the plan may have changed since the link was made),
-- else `line` itself while it's inside the plan. Pure.
function M.resolve_line(lines, line, anchor)
  local want = anchor and vim.trim(anchor) or ""
  if want ~= "" then
    local best
    for i, l in ipairs(lines) do
      if vim.trim(l) == want and (not best or math.abs(i - line) < math.abs(best - line)) then best = i end
    end
    if best then return best end
  end
  if line and line >= 1 and line <= #lines then return line end
  return nil
end

-- The Files entry for `path` in the plan: its line, or nil. Pure.
function M.file_entry_line(lines, path)
  local inside, fenced = false, false
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    local hashes, title = l:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced then
      inside = #hashes == 2 and title:lower():find("file", 1, true) ~= nil
    elseif inside and not fenced then
      local item = l:match("^%s*[-*+]%s+(.+)$")
      local p = item and (item:match("`([^`]+)`") or item:match("^(%S+)"))
      p = p and p:gsub("^%./", ""):gsub("[,:;]$", "")
      if p and same_path(p, path) then return i end
    end
  end
  return nil
end

-- The path a Files entry on plan line `line` names, or nil. Pure.
function M.file_at_line(lines, line)
  for _, p in ipairs(M.planned_files(lines)) do
    if M.file_entry_line(lines, p) == line then return p end
  end
  return nil
end

-- The step links (show_fix's `steps`, kept on the plan as rec.links: {
-- file, line, plan_line, plan_anchor, note }) on plan line `line`, and the
-- one nearest above-or-at diff line `line` of `file`. Pure.
function M.links_on_plan_line(links, lines, line)
  local out = {}
  for _, k in ipairs(links or {}) do
    if M.resolve_line(lines, k.plan_line, k.plan_anchor) == line then out[#out + 1] = k end
  end
  return out
end

function M.link_for_code(links, file, line)
  local best
  for _, k in ipairs(links or {}) do
    if same_path(k.file or "", file) and k.line and k.line <= line and (not best or k.line > best.line) then best = k end
  end
  return best
end

-- The plan for the change in worktree `dir` (start_fix's <repo>-<pr id>,
-- start_story's <repo>-wi<id>): its record, or nil.
function M.for_worktree(dir)
  local name = vim.fn.fnamemodify((dir or ""):gsub("[/\\]+$", ""), ":t")
  local wi = name:match("%-wi(%d+)$")
  if wi then return M.load("wi-" .. wi) end
  local pr = name:match("%-(%d+)$")
  return pr and M.load("pr-" .. pr) or nil
end

-- What revision `new` changed against `old` (both lists of lines), from
-- `hunks` = vim.diff's { start_old, count_old, start_new, count_new }
-- indices: { changed = { [new line] = true }, removed = { [new line] =
-- old lines gone just above it } } - removed lines at the very end sit on
-- line #new + 1. Pure.
function M.revision_changes(old, new, hunks)
  local out = { changed = {}, removed = {} }
  for _, h in ipairs(hunks or {}) do
    local so, co, sn, cn = h[1], h[2], h[3], h[4]
    for i = sn, sn + cn - 1 do if cn > 0 then out.changed[i] = true end end
    if co > cn then
      -- More lines went than came: the extra old ones show as removed,
      -- above the line after the hunk.
      local at = cn > 0 and (sn + cn) or (sn + 1)
      local gone = {}
      for i = so + cn, so + co - 1 do gone[#gone + 1] = old[i] end
      out.removed[at] = gone
    end
  end
  return out
end

-- The command the plan's Test plan section gives: its first ``` block
-- (sh, bash, shell, cmd, pwsh, powershell or no language), lines joined
-- with " && ", or nil. Pure.
local SHELL_LANGS = { [""] = true, sh = true, bash = true, shell = true, cmd = true, pwsh = true, powershell = true,
  console = true }
function M.test_command(lines)
  local inside, block, lang = false, nil, nil
  for _, l in ipairs(lines) do
    local fence = l:match("^%s*```%s*([%w]*)%s*$")
    if block then
      if fence then
        local cmd = {}
        for _, c in ipairs(block) do
          c = vim.trim((c:gsub("^%s*%$%s+", "")))
          if c ~= "" and not c:match("^#") then cmd[#cmd + 1] = c end
        end
        if #cmd > 0 and SHELL_LANGS[lang] then return table.concat(cmd, " && ") end
        block = nil
      else
        block[#block + 1] = l
      end
    elseif fence and inside then
      block, lang = {}, fence:lower()
    else
      local hashes, title = l:match("^(#+)%s+(.-)%s*$")
      if hashes then inside = #hashes == 2 and title:lower():find("test", 1, true) ~= nil end
    end
  end
  return nil
end

-- The template's "## " headings `markdown` doesn't have. Pure.
function M.missing(markdown, template)
  local have = {}
  for _, s in ipairs(M.sections(vim.split(markdown or "", "\n", { plain = true }))) do have[s.title:lower()] = true end
  local out = {}
  for _, s in ipairs(M.sections(vim.split(template or "", "\n", { plain = true }))) do
    if s.level == 2 and not have[s.title:lower()] then out[#out + 1] = s.title end
  end
  return out
end

-- Whether a change may start for `target`, given its plan record `rec`
-- (nil: none yet) and the plan_first setting `mode`: ok, why. Pure.
function M.gate_check(rec, mode, target)
  if mode == nil then mode = true end
  if mode == false or (mode == "stories" and not target.work_item_id) then return true end
  if rec and rec.status == "approved" then return true end
  local label = M.target_label(target)
  if not rec then
    return false, "No plan for " .. label .. " yet. Write one with submit_plan first (following its template), then "
      .. "stop and wait: the user reads it, may ask about it, and approves it before you change any code."
  end
  if rec.status == "changes_requested" then
    return false, "The user asked for changes to the plan for " .. label .. ". Revise it with submit_plan and wait "
      .. "for their approval."
  end
  if rec.status == "done" then
    return false, "The plan for " .. label .. " was implemented and pushed already. For more changes, write a new "
      .. "plan with submit_plan and wait for the user to approve it."
  end
  return false, "The plan for " .. label .. " isn't approved yet. Wait for the user - they'll tell you when it is "
    .. "(or what to change)."
end

-- Whether an approved plan lets its change be pushed without asking:
-- you chose that when approving (rec.allow_push), it's still approved (a
-- new revision takes it back), and - when the plan has a test command -
-- the tests passed on exactly the change being pushed (`result` = the last
-- run, `fp` = the change's fingerprint now). ok, why-not. Pure.
function M.push_check(rec, has_cmd, result, fp)
  if not (rec and rec.allow_push) then return false, "you didn't allow pushes for this plan" end
  if rec.status ~= "approved" then return false, "the plan isn't approved (any more)" end
  if has_cmd then
    if not result then return false, "the plan's tests haven't run on this change" end
    if result.fingerprint ~= fp then return false, "the tests ran on an earlier version of the change" end
    if result.code ~= 0 then return false, "the tests failed" end
  end
  return true
end

local STATUS = {
  draft = { "\u{25CF} Waiting for your review", "AzureCliStatusDraft" },
  approved = { "\u{2713} Approved", "AzureCliStatusOk" },
  changes_requested = { "\u{21BA} Changes asked for", "AzureCliStatusBad" },
  done = { "\u{2713} Implemented", "AzureCliStatusDone" },
}
-- The status line in the section list: text, highlight group. Pure.
function M.status_label(rec)
  local s = STATUS[rec.status] or STATUS.draft
  return s[1], s[2]
end

local function last_rev(rec) return rec.revisions[#rec.revisions] end

-- What approving sends the agent. Pure.
function M.approval_message(rec)
  local label = M.target_label(rec.target)
  local rev = last_rev(rec)
  local text = "I approve the plan for " .. label .. " (revision " .. #rec.revisions .. "). Go ahead and make the "
    .. "change as planned, then show_fix it to me - with `steps` tying the parts of the change to the plan lines "
    .. "they carry out."
  if rev and rev.by == "you" then
    text = text .. "\n\nI edited the plan before approving - follow this version:\n\n" .. rev.markdown
  end
  return text
end

-- What asking for changes sends the agent: `feedback`, and the changes
-- asked for on lines of the plan (`requests`: threads of kind "request" -
-- { line, section, anchor, question }). Pure.
function M.revise_message(rec, feedback, requests)
  local parts = { "Please revise the plan for " .. M.target_label(rec.target) .. ": " .. feedback }
  if requests and #requests > 0 then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "On its lines:"
    for _, r in ipairs(requests) do
      parts[#parts + 1] = "- line " .. tostring(r.line) .. (r.section and (" (" .. r.section .. ")") or "")
        .. (r.anchor and r.anchor ~= "" and (" \"" .. r.anchor .. "\"") or "") .. ": " .. r.question
    end
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Submit the new version with submit_plan, then wait for me again."
  return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Storage.

function M.root() return STORE().root() .. "/plans" end
function M.path(key) return M.root() .. "/" .. key .. ".md" end

function M.load(key)
  if not key then return nil end
  local ok, lines = pcall(vim.fn.readfile, M.root() .. "/" .. key .. ".json")
  if not ok or #lines == 0 then return nil end
  local okd, rec = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not okd or type(rec) ~= "table" then return nil end
  rec.revisions = rec.revisions or {}
  rec.threads = rec.threads or {}
  return rec
end

function M.save(rec)
  vim.fn.mkdir(M.root(), "p")
  vim.fn.writefile({ vim.json.encode(rec) }, M.root() .. "/" .. rec.key .. ".json")
end

-- The plan's text as it is on disk now (the user may have edited it).
local function current_lines(rec)
  local ok, lines = pcall(vim.fn.readfile, M.path(rec.key))
  if ok and #lines > 0 then return lines end
  local rev = last_rev(rec)
  return vim.split(rev and rev.markdown or "", "\n", { plain = true })
end

-- The plan's Files check for a change: `changed` = its paths.
function M.check_change(rec, changed)
  if not rec then return nil end
  return M.check_files(M.planned_files(current_lines(rec)), changed)
end

-- A new revision `markdown` by `by` ("agent" / "you"): the file rewritten
-- (when the agent wrote it), the questions moved to their lines, the status
-- back to waiting for the user.
local function add_revision(rec, markdown, by)
  rec.revisions[#rec.revisions + 1] = { at = os.time(), by = by, markdown = markdown }
  local lines = vim.split(markdown, "\n", { plain = true })
  if by == "agent" then
    vim.fn.mkdir(M.root(), "p")
    vim.fn.writefile(lines, M.path(rec.key))
  end
  THREADS().reanchor(rec.threads, lines)
  rec.status = "draft"
  rec.approved_rev = nil
  rec.allow_push = nil
end

-- ---------------------------------------------------------------------------
-- The viewer.

local view = nil  -- { tab, list_win, plan_win, list_buf, plan_buf, key, rec, sections, rows, width }
local goto_code  -- forward
local list_ns = vim.api.nvim_create_namespace("azure_cli_plan_list")

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end
local function valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end

local function key_of(surface, action)
  local k = KEYS().resolve(surface, action)
  if type(k) == "table" then k = k[1] end
  return k
end

local LIST_HELP = {
  "Sections",
  { "open", "go to the section" },
  "The plan",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", "ask for changes (you say what)" },
  { "open_file", "edit the plan by hand (saving it makes that the version the agent gets)" },
  { "refresh", "reload it" },
  { "chat", "go to the chat" },
  { "resize_less", "shrink the section list" }, { "resize_more", "grow the section list" },
  { "quit", "close" }, { "help", "this help" },
}
local PLAN_HELP = {
  "Ask",
  { "ask", "ask the agent about this line (in visual mode: these lines) - the answer shows under it" },
  { "request", "queue a change on this line (in visual mode: these lines) - gR sends them together" },
  { "delete_thread", "forget the question or change under this line" },
  { "since", "mark what this revision changed against the one before (on by default; toggles)" },
  { "expand_thread", "show all of the answer under this line / fold it again" },
  { "view_thread", "the question and answer in a popup" },
  { "next_thread", "next question" }, { "prev_thread", "previous question" },
  "The plan",
  { "approve", "approve it - the agent goes ahead" },
  { "revise", "ask for changes: what you write, plus the ones queued on lines (gc)" },
  { "open_file", "edit the plan by hand" },
  { "goto_code", "the code this line became (a linked step, or a Files entry's file)" },
  { "back", "back to the section list" },
  { "refresh", "reload it" },
  { "chat", "go to the chat (in visual mode: send the selected lines)" },
  { "quit", "close" }, { "help", "this help" },
}

local function help(tbl)
  UI().open_float(KEYS().help_lines("plan", "Plan keys", tbl, { notes = {
    "The agent waits for you: it can't start changing code (start_fix / start_story) until you approve the plan.",
  } }), { title = "Keys", min_width = 60 })
end

local function close()
  if view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(view.tab))
  end
end

local function resize(delta)
  if not (view and valid_win(view.list_win)) then return end
  view.width = math.max(20, vim.api.nvim_win_get_width(view.list_win) + delta)
  pcall(vim.api.nvim_win_set_width, view.list_win, view.width)
end

local link_ns = vim.api.nvim_create_namespace("azure_cli_plan_links")

-- "→ auth.py:13" at the end of each plan line a step of the change carries
-- out (show_fix's `steps`).
local function draw_links()
  if not (view and valid_buf(view.plan_buf)) then return end
  vim.api.nvim_buf_clear_namespace(view.plan_buf, link_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local by_line = {}
  for _, k in ipairs(view.rec.links or {}) do
    local l = M.resolve_line(lines, k.plan_line, k.plan_anchor)
    if l then
      by_line[l] = by_line[l] or {}
      table.insert(by_line[l], vim.fn.fnamemodify(k.file or "?", ":t") .. ":" .. tostring(k.line))
    end
  end
  for l, where in pairs(by_line) do
    pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, link_ns, l - 1, 0, {
      virt_text = { { "  \u{2192} " .. table.concat(where, ", "), "AzureCliMuted" } }, virt_text_pos = "eol" })
  end
end

local since_ns = vim.api.nvim_create_namespace("azure_cli_plan_since")

-- What this revision changed against the one before it, or nil (the first
-- revision, or gi turned it off): revision_changes' { changed, removed }.
local function since()
  local revs = view.rec.revisions
  if view.since_off or #revs < 2 then return nil end
  local old = vim.split(revs[#revs - 1].markdown or "", "\n", { plain = true })
  local new = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local diff = (vim.text and vim.text.diff) or vim.diff
  local ok, hunks = pcall(diff, table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n",
    { result_type = "indices" })
  return M.revision_changes(old, new, ok and hunks or {})
end

-- The bar beside each line this revision changed, and the lines it took
-- out (struck through, where they were).
local function draw_since()
  if not (view and valid_buf(view.plan_buf)) then return end
  vim.api.nvim_buf_clear_namespace(view.plan_buf, since_ns, 0, -1)
  local ch = since()
  view.changes = ch
  if not ch then return end
  local n = vim.api.nvim_buf_line_count(view.plan_buf)
  for l in pairs(ch.changed) do
    pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, since_ns, l - 1, 0,
      { sign_text = "\u{258E}", sign_hl_group = "AzureCliPlanChanged", priority = 5 })
  end
  for at, gone in pairs(ch.removed) do
    local vl = {}
    for _, g in ipairs(gone) do vl[#vl + 1] = { { "\u{2212} " .. g, "AzureCliPlanRemoved" } } end
    if at <= n then
      pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, since_ns, at - 1, 0, { virt_lines = vl, virt_lines_above = true })
    else
      pcall(vim.api.nvim_buf_set_extmark, view.plan_buf, since_ns, n - 1, 0, { virt_lines = vl })
    end
  end
end

local function draw_threads()
  if not (view and valid_buf(view.plan_buf)) then return end
  THREADS().draw(view.plan_buf, view.plan_win, view.rec.threads, function(th) return th.line end)
  draw_links()
end

local function set_winbars()
  if not view then return end
  local rec = view.rec
  local short = { draft = "draft", approved = "approved", changes_requested = "changes asked", done = "done" }
  local tags = { "[" .. (short[rec.status] or "draft") .. "]" }
  local nq, nr = THREADS().counts(rec.threads)
  if nq > 0 then tags[#tags + 1] = "[?" .. nq .. "]" end
  if nr > 0 then tags[#tags + 1] = "[\u{270E}" .. nr .. " queued]" end
  if last_rev(rec) and last_rev(rec).by == "you" then tags[#tags + 1] = "[edited by you]" end
  if rec.allow_push and rec.status == "approved" then tags[#tags + 1] = "[may push]" end
  if view.changes then tags[#tags + 1] = "[\u{00B1} since rev " .. (#rec.revisions - 1) .. "]" end
  if valid_win(view.plan_win) then
    pcall(UI().wo, view.plan_win, "winbar", UI().winbar({ "Plan " .. M.target_label(rec.target),
      #rec.revisions > 1 and ("rev " .. #rec.revisions) or nil }, tags))
  end
  if valid_win(view.list_win) then
    pcall(UI().wo, view.list_win, "winbar", UI().winbar({ "Sections" }, {}))
  end
end

-- Whether section `s` has lines this revision changed or took out.
local function section_changed(s)
  local ch = view.changes
  if not ch then return false end
  local stop = math.huge
  for _, o in ipairs(view.sections) do
    if o.line > s.line and o.level <= s.level then stop = o.line break end
  end
  for l in pairs(ch.changed) do if l >= s.line and l < stop then return true end end
  for l in pairs(ch.removed) do if l > s.line and l <= stop then return true end end
  return false
end

-- The section list: the plan's title and status, its sections (with how
-- many questions each has, and the Files count), then the keys that matter.
local function render_list()
  if not (view and valid_buf(view.list_buf)) then return end
  local rec = view.rec
  local width = valid_win(view.list_win) and vim.api.nvim_win_get_width(view.list_win) or 30
  local lines, hls, rows = {}, {}, {}
  local function add(text, hl, from)
    lines[#lines + 1] = text
    if hl then hls[#hls + 1] = { #lines - 1, from or 0, hl } end
  end
  add(" " .. UI().fit(M.target_label(rec.target) .. "  " .. (rec.title or ""), width - 2), "AzureCliSection")
  local st, st_hl = M.status_label(rec)
  if rec.allow_push and rec.status == "approved" then st = st .. " \u{00B7} may push" end
  add(" " .. st .. (#rec.revisions > 1 and ("  \u{00B7} revision " .. #rec.revisions) or ""), st_hl)
  add("")
  local per, per_req = {}, {}
  for _, th in ipairs(rec.threads) do
    local s = M.section_at(view.sections, th.line)
    local into = th.kind == "request" and per_req or per
    if s and not (th.kind == "request" and th.status == "sent") then into[s.line] = (into[s.line] or 0) + 1 end
  end
  for _, s in ipairs(view.sections) do
    if s.level >= 2 then
      local badge = ""
      if per[s.line] then badge = "?" .. per[s.line] end
      if per_req[s.line] then badge = (badge ~= "" and (badge .. " ") or "") .. "\u{270E}" .. per_req[s.line] end
      if section_changed(s) then badge = (badge ~= "" and (badge .. " ") or "") .. "\u{00B1}" end
      if s.items > 0 and s.title:lower():find("file", 1, true) then badge = (badge ~= "" and (badge .. " ") or "") .. s.items end
      local indent = string.rep("  ", math.max(0, s.level - 2))
      local name = UI().fit(indent .. s.title, math.max(8, width - 4 - vim.fn.strdisplaywidth(badge)))
      add("   " .. name .. badge, nil)
      if badge ~= "" then hls[#hls + 1] = { #lines - 1, #lines[#lines] - #badge, "AzureCliAccent" } end
      rows[#lines] = s
    end
  end
  add("")
  local hints = {}
  if rec.status ~= "approved" and rec.status ~= "done" then
    hints[#hints + 1] = { key_of("plan", "approve"), "approve" }
    hints[#hints + 1] = { key_of("plan", "revise"), "ask for changes" }
  end
  hints[#hints + 1] = { key_of("plan", "ask"), "ask about a line" }
  hints[#hints + 1] = { key_of("plan", "request"), "ask a change on a line" }
  hints[#hints + 1] = { key_of("plan", "open_file"), "edit it yourself" }
  hints[#hints + 1] = { key_of("plan", "help"), "all keys" }
  for _, h in ipairs(hints) do
    if h[1] then
      add(" " .. h[1] .. "  " .. h[2], "AzureCliMuted")
      hls[#hls + 1] = { #lines - 1, 1, "AzureCliKeyHint", 1 + #h[1] }
    end
  end
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, lines)
  vim.bo[view.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.list_buf, list_ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, view.list_buf, list_ns, h[1], h[2],
      { end_col = h[4] or #lines[h[1] + 1], hl_group = h[3] })
  end
  view.rows = rows
end

local function render_plan()
  if not (view and valid_buf(view.plan_buf)) then return end
  local lines = current_lines(view.rec)
  view.sections = M.sections(lines)
  vim.bo[view.plan_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.plan_buf, 0, -1, false, lines)
  vim.bo[view.plan_buf].modifiable = false
  draw_threads()
end

local function render()
  render_plan()
  draw_since()
  render_list()
  set_winbars()
end

-- Saves the plan and redraws the viewer if it shows it.
local function changed(rec)
  M.save(rec)
  if view and view.key == rec.key then
    view.rec = rec
    render_list()
    set_winbars()
    draw_threads()
  end
end

local function send(text, display)
  local CHAT = require("azure-cli.chat")
  if CHAT.busy() then
    notify("The agent is still answering - tell it once it's done (it can read the plan with get_plan).",
      vim.log.levels.WARN)
    return false
  end
  return CHAT.send(text, { view_win = valid_win(view and view.plan_win) and view.plan_win or nil, display = display })
    ~= nil
end

-- gA: approve - and, if you say so, let the change be pushed without
-- asking once the plan's tests pass on it (M.push_check).
local function approve()
  local rec = view and view.rec
  if not rec then return end
  if rec.status == "approved" then return notify("Already approved.") end
  if rec.status == "done" then return notify("This plan was implemented already.") end
  local has_cmd = M.test_command(current_lines(rec)) ~= nil
  local plain, with_push = "Approve", has_cmd and "Approve, and let it push once the tests pass"
    or "Approve, and let it push without asking"
  require("azure-cli.prompt").select({ prompt = "Approve the plan for " .. M.target_label(rec.target),
    items = { plain, with_push } }, function(choice)
    if not choice then return end
    rec.status = "approved"
    rec.approved_rev = #rec.revisions
    rec.approved_at = os.time()
    rec.allow_push = choice == with_push or nil
    changed(rec)
    send(M.approval_message(rec), "Approved the plan for " .. M.target_label(rec.target)
      .. (rec.allow_push and " (it may push once the tests pass)." or "."))
    notify("Plan approved - the agent can change the code now.")
  end)
end

-- gR: ask for changes - what you write here, plus every change queued on
-- a line with gc.
local function revise()
  local rec = view and view.rec
  if not rec then return end
  local queued = {}
  for _, th in ipairs(rec.threads) do
    if th.kind == "request" and th.status ~= "sent" then queued[#queued + 1] = th end
  end
  require("azure-cli.editor").open({
    title = "What should change in the plan?" .. (#queued > 0 and (" (+" .. #queued .. " on its lines)") or ""),
    initial = #queued > 0 and "See my comments on its lines." or "", anchor = "center",
    on_submit = function(text)
      if send(M.revise_message(rec, text, queued), "Changes to the plan: " .. text
          .. (#queued > 0 and (" (+" .. #queued .. " on its lines)") or "")) then
        rec.status = "changes_requested"
        for _, th in ipairs(queued) do th.status = "sent" end
        changed(rec)
      end
    end,
  })
end

-- gc: queue a change on this line (or these lines) for gR.
local function request(from, to)
  local rec = view.rec
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, from - 1, to, false)
  local sec = M.section_at(view.sections, from)
  require("azure-cli.editor").open({
    title = "Change \u{00B7} plan:" .. (from == to and from or (from .. "-" .. to)) .. " (queued for gR)",
    initial = "", anchor = { win = view.plan_win, row = to }, context_lines = lines,
    on_submit = function(text)
      table.insert(rec.threads, { id = tostring(os.time()) .. "-" .. math.random(1000, 9999), kind = "request",
        line = to, anchor = vim.trim(lines[#lines] or ""), section = sec and sec.title, question = text,
        status = "queued", at = os.time() })
      changed(rec)
      local _, r = THREADS().counts(rec.threads)
      notify(r .. " change" .. (r == 1 and "" or "s") .. " queued - " .. (key_of("plan", "revise") or "gR")
        .. " sends " .. (r == 1 and "it" or "them") .. ".")
    end,
  })
end

-- dd: forget the question or change request under the cursor.
local function delete_here()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local _, i = THREADS().at_line(view.rec.threads, row)
  if not i then return notify("Nothing under this line.") end
  table.remove(view.rec.threads, i)
  changed(view.rec)
end

local function open_file()
  if not view then return end
  local path = M.path(view.key)
  local row = valid_win(view.plan_win) and vim.api.nvim_win_get_cursor(view.plan_win)[1] or 1
  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
end

-- Saving the plan's file by hand: that's a revision by you, which needs
-- approving again.
vim.api.nvim_create_autocmd("BufWritePost", {
  group = vim.api.nvim_create_augroup("AzureCliPlanFile", { clear = true }),
  pattern = "*.md",
  callback = function(ev)
    local file = vim.fn.fnamemodify(ev.match, ":p"):gsub("\\", "/")
    local root = vim.fn.fnamemodify(M.root(), ":p"):gsub("\\", "/")
    if file:sub(1, #root) ~= root then return end
    local key = vim.fn.fnamemodify(file, ":t:r")
    local rec = M.load(key)
    if not rec then return end
    local text = table.concat(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false), "\n")
    local rev = last_rev(rec)
    if rev and rev.markdown == text then return end
    local was = rec.status
    add_revision(rec, text, "you")
    M.save(rec)
    if view and view.key == key then
      view.rec = rec
      render()
    end
    notify("Plan saved as your version" .. ((was == "approved") and " - approve it again (gA) for the agent to use it." or "."))
  end,
})

local function thread_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return THREADS().at_line(view.rec.threads, row)
end

local function jump_thread(dir)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, th in ipairs(view.rec.threads) do
    if (dir > 0 and th.line > row and (not best or th.line < best))
        or (dir < 0 and th.line < row and (not best or th.line > best)) then
      best = th.line
    end
  end
  if not best then return notify(dir > 0 and "No further questions." or "No earlier questions.") end
  vim.api.nvim_win_set_cursor(0, { best, 0 })
end

local function ask(from, to)
  local rec = view.rec
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, from - 1, to, false)
  local quote = table.concat(lines, "\n")
  local sec = M.section_at(view.sections, from)
  local where = (sec and ("section \"" .. sec.title .. "\", ") or "") .. (from == to and ("line " .. from)
    or ("lines " .. from .. "-" .. to))
  THREADS().ask({
    win = view.plan_win, row = to, line = to, anchor = vim.trim(lines[#lines] or ""), section = sec and sec.title,
    ctx = { what = "your plan for " .. M.target_label(rec.target) .. " (\"" .. (rec.title or "") .. "\")", where = where },
    quote = quote,
    label = "plan:" .. (from == to and from or (from .. "-" .. to)),
    threads = rec.threads,
    changed = function() changed(rec) end,
  })
end

-- gd on a plan line: the code it became - a step of the change linked to
-- this line (show_fix's `steps`), or the file a Files entry names.
goto_code = function()
  local rec = view.rec
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(view.plan_buf, 0, -1, false)
  local links = M.links_on_plan_line(rec.links, lines, row)
  local function go(path, line)
    require("azure-cli.chat.tools_fix").open_at(rec.target, path, line, function(err)
      if err then notify(err, vim.log.levels.WARN) end
    end)
  end
  if #links == 1 then return go(links[1].file, links[1].line) end
  if #links > 1 then
    return require("azure-cli.prompt").select({ prompt = "Which part of the change", items = links,
      format = function(k) return k.file .. ":" .. tostring(k.line) .. (k.note and ("  " .. k.note) or "") end },
      function(k) if k then go(k.file, k.line) end end)
  end
  local file = M.file_at_line(lines, row)
  if file then return go(file, nil) end
  notify("Nothing in the change is linked to this line (a Files entry opens its file).")
end

local function bind_common(buf)
  local K = KEYS()
  K.bind(buf, "plan", "approve", approve, { desc = "approve the plan" })
  K.bind(buf, "plan", "revise", revise, { desc = "ask for changes to the plan" })
  K.bind(buf, "plan", "open_file", open_file, { desc = "edit the plan by hand" })
  K.bind(buf, "plan", "refresh", function() M.refresh() end, { desc = "reload the plan" })
  K.bind(buf, "plan", "chat", function() require("azure-cli.chat").toggle() end, { desc = "go to the chat" })
  K.bind(buf, "plan", "chat", function() require("azure-cli.chat").capture_selection() end,
    { desc = "send the selected lines to the chat", mode = "x" })
  K.bind(buf, "plan", "resize_less", function() resize(-5) end, { desc = "shrink the section list" })
  K.bind(buf, "plan", "resize_more", function() resize(5) end, { desc = "grow the section list" })
  K.bind(buf, "plan", "quit", close, { desc = "close" })
end

local function goto_section(s, focus)
  if not (s and valid_win(view.plan_win)) then return end
  pcall(vim.api.nvim_win_set_cursor, view.plan_win, { s.line, 0 })
  vim.api.nvim_win_call(view.plan_win, function() vim.cmd("normal! zt") end)
  if focus then vim.api.nvim_set_current_win(view.plan_win) end
end

local function setup_list(buf)
  local K = KEYS()
  K.bind(buf, "plan", "open", function()
    goto_section(view.rows[vim.api.nvim_win_get_cursor(0)[1]], true)
  end, { desc = "go to the section" })
  K.bind(buf, "plan", "help", function() help(LIST_HELP) end, { desc = "keys" })
  bind_common(buf)
  -- Moving through the sections scrolls the plan to each one.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local s = view and view.rows and view.rows[vim.api.nvim_win_get_cursor(0)[1]]
      if s then goto_section(s, false) end
    end,
  })
end

local function setup_plan(buf)
  local K = KEYS()
  K.bind(buf, "plan", "ask", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    ask(r, r)
  end, { desc = "ask the agent about this line" })
  K.bind(buf, "plan", "ask", function()
    local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    ask(a, b)
  end, { desc = "ask the agent about these lines", mode = "x" })
  K.bind(buf, "plan", "expand_thread", function()
    local th = thread_at_cursor()
    if not th then return notify("No question on this line (" .. (key_of("plan", "ask") or "ga") .. " asks one).") end
    THREADS().toggle(th)
    draw_threads()
  end, { desc = "show all of the answer / fold it" })
  K.bind(buf, "plan", "view_thread", function() THREADS().show(thread_at_cursor()) end, { desc = "the question and answer" })
  K.bind(buf, "plan", "request", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    request(r, r)
  end, { desc = "queue a change on this line" })
  K.bind(buf, "plan", "request", function()
    local a, b = vim.fn.getpos("v")[2], vim.api.nvim_win_get_cursor(0)[1]
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    request(a, b)
  end, { desc = "queue a change on these lines", mode = "x" })
  K.bind(buf, "plan", "delete_thread", delete_here, { desc = "forget the question / change under this line" })
  K.bind(buf, "plan", "since", function()
    view.since_off = not view.since_off
    render()
    notify(view.since_off and "Not marking what changed." or (view.changes and "Marking what changed since revision "
      .. (#view.rec.revisions - 1) .. ".") or "This is the first revision.")
  end, { desc = "mark what this revision changed (toggle)" })
  K.bind(buf, "plan", "next_thread", function() jump_thread(1) end, { desc = "next question" })
  K.bind(buf, "plan", "prev_thread", function() jump_thread(-1) end, { desc = "previous question" })
  K.bind(buf, "plan", "back", function()
    if valid_win(view.list_win) then vim.api.nvim_set_current_win(view.list_win) end
  end, { desc = "back to the section list" })
  K.bind(buf, "plan", "goto_code", function() goto_code() end, { desc = "the code this line became" })
  K.bind(buf, "plan", "help", function() help(PLAN_HELP) end, { desc = "keys" })
  bind_common(buf)
end

-- Opens (or brings to the front, reloaded) the plan `key`, at plan line
-- `line` when given.
function M.open(key, line)
  local rec = M.load(key)
  if not rec then return nil, "no plan " .. tostring(key) end
  UI().theme()
  if view and view.tab and vim.api.nvim_tabpage_is_valid(view.tab) and valid_win(view.list_win)
      and valid_win(view.plan_win) then
    view.key, view.rec = key, rec
    vim.api.nvim_set_current_tabpage(view.tab)
  else
    local width = view and view.width or 32
    view = { key = key, rec = rec, width = width, sections = {}, rows = {} }
    vim.cmd("tabnew")
    view.tab = vim.api.nvim_get_current_tabpage()
    view.list_win = vim.api.nvim_get_current_win()
    view.list_buf = vim.api.nvim_get_current_buf()
    vim.bo[view.list_buf].buftype = "nofile"
    vim.bo[view.list_buf].bufhidden = "wipe"
    vim.bo[view.list_buf].filetype = "azurecli-plan"
    pcall(vim.api.nvim_buf_set_name, view.list_buf, "azure-cli://plan")
    setup_list(view.list_buf)
    vim.cmd("belowright vsplit")
    view.plan_win = vim.api.nvim_get_current_win()
    view.plan_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[view.plan_buf].buftype = "nofile"
    vim.bo[view.plan_buf].bufhidden = "wipe"
    vim.bo[view.plan_buf].filetype = "markdown"
    vim.b[view.plan_buf].azure_cli_view = "azurecli-plan"
    vim.b[view.plan_buf].azure_cli_title = "Plan"
    pcall(vim.api.nvim_buf_set_name, view.plan_buf, "azure-cli://plan/" .. key)
    vim.api.nvim_win_set_buf(view.plan_win, view.plan_buf)
    pcall(vim.treesitter.start, view.plan_buf, "markdown")
    setup_plan(view.plan_buf)
    UI().plain_window(view.list_win, { cursorline = true })
    UI().plain_window(view.plan_win, {})
    UI().wo(view.plan_win, "wrap", true)
    UI().wo(view.plan_win, "linebreak", true)
    UI().wo(view.plan_win, "breakindent", true)
    UI().wo(view.plan_win, "conceallevel", 2)
    UI().wo(view.plan_win, "concealcursor", "")
    UI().wo(view.plan_win, "signcolumn", "yes:2")
    pcall(vim.api.nvim_win_set_width, view.list_win, width)
    vim.api.nvim_create_autocmd("WinResized", {
      buffer = view.list_buf,
      callback = function() vim.schedule(function() if view then render_list() draw_threads() end end) end,
    })
  end
  vim.t[view.tab].azure_cli_title = "Plan " .. M.target_label(rec.target)
  render()
  -- The plan gets the focus - again after the chat panel has followed into
  -- this tab (it opens on a scheduled callback).
  local function focus()
    if view and valid_win(view.plan_win) then vim.api.nvim_set_current_win(view.plan_win) end
  end
  if line then
    pcall(vim.api.nvim_win_set_cursor, view.plan_win, { line, 0 })
    vim.api.nvim_win_call(view.plan_win, function() vim.cmd("normal! zz") end)
  end
  focus()
  vim.schedule(function() vim.schedule(focus) end)
  return view.tab
end

function M.refresh()
  if not view then return end
  local rec = M.load(view.key)
  if not rec then return end
  view.rec = rec
  render()
end

-- The open viewer (tests): { tab, list_win, plan_win, list_buf, plan_buf, key, rec }.
function M.current() return view end

-- The chat's description of the plan window.
function M.describe(win)
  if not view then return nil end
  local rec = view.rec
  local snap = { screen = "plan", plan = { key = rec.key, title = rec.title, status = rec.status,
    revision = #rec.revisions, file = M.path(rec.key) } }
  if rec.target.work_item_id then
    snap.work_item = { id = rec.target.work_item_id }
  else
    snap.pr = require("azure-cli.chat.tools").pr_record(rec.target.pr_id) or { id = rec.target.pr_id }
  end
  snap.note = "Looking at your plan for " .. M.target_label(rec.target) .. " \"" .. tostring(rec.title) .. "\" ("
    .. (M.status_label(rec)):gsub("^%S+ ", "") .. ", revision " .. #rec.revisions .. ", file " .. snap.plan.file .. ")"
  if win == view.plan_win and valid_win(win) then
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local sec = M.section_at(view.sections, row)
    snap.plan_line, snap.plan_section = row, sec and sec.title
    snap.plan_text = vim.api.nvim_buf_get_lines(view.plan_buf, row - 1, row, false)[1]
  end
  return snap
end

require("azure-cli.chat.view").register("azurecli-plan", function(win) return M.describe(win) end)

-- The plan's text as it is now (the user's edits included).
function M.lines(rec) return current_lines(rec) end

-- show_fix's `steps`: which lines of the change carry out which plan
-- lines. Replaces the plan's links; returns how many were kept (a step
-- needs a file, a line and a plan line inside the plan).
function M.set_links(target, steps)
  local rec = M.load(M.key(target))
  if not rec or type(steps) ~= "table" then return 0 end
  local lines = current_lines(rec)
  local links = {}
  for _, s in ipairs(steps) do
    local pl = tonumber(type(s) == "table" and s.plan_line)
    if type(s.file) == "string" and tonumber(s.line) and pl and pl >= 1 and pl <= #lines then
      links[#links + 1] = { file = s.file, line = tonumber(s.line), plan_line = pl, plan_anchor = lines[pl],
        note = type(s.note) == "string" and s.note or nil }
    end
  end
  rec.links = links
  changed(rec)
  return #links
end

-- ---------------------------------------------------------------------------
-- The gate (chat/tools_fix.lua).

function M.gate(target)
  return M.gate_check(M.load(M.key(target)), config().plan_first, target)
end

-- Whether commit_and_push_fix may skip its question for `target`'s change
-- in worktree `dir`: cb(ok, why).
function M.push_allowed(target, dir, cb)
  local rec = M.load(M.key(target))
  if not (rec and rec.allow_push) then return cb(false, "not allowed") end
  local TR = require("azure-cli.chat.tests_run")
  local has_cmd = M.test_command(current_lines(rec)) ~= nil
  require("azure-cli.chat.tools_fix").diff(dir, function(ok, diff)
    if not ok then return cb(false, diff) end
    cb(M.push_check(rec, has_cmd, TR.load(dir), TR.fingerprint(diff)))
  end, require("azure-cli.chat.tools").git)
end

-- commit_and_push_fix pushed the change: its plan is done.
function M.mark_done(target)
  local rec = M.load(M.key(target))
  if rec and rec.status == "approved" then
    rec.status = "done"
    rec.done_at = os.time()
    changed(rec)
  end
end

-- ---------------------------------------------------------------------------
-- Tools (chat/tools.lua).

function M.tools(T)
  local target_props = {
    work_item_id = { type = "integer", description = "the work item the plan is for (implementing a story/bug/task)" },
    pr_id = { type = "integer", description = "the pull request the plan is for (fixing a review comment)" },
  }
  local function target_of(args)
    if args.work_item_id then return { work_item_id = args.work_item_id } end
    if args.pr_id then return { pr_id = args.pr_id } end
    return nil
  end
  return {
    {
      name = "submit_plan",
      description = "Shows the user your plan for a change - before you change any code (start_fix / start_story "
        .. "refuse until the user approves it). Give work_item_id or pr_id, a short title, and the plan in markdown "
        .. "following this template (keep its ## headings; say why for each choice, the user can ask about any line):\n\n"
        .. M.template() .. "\n\nCalling it again for the same work item / PR replaces the plan with a new revision "
        .. "(it then needs approving again). After calling it, STOP and wait: the user will approve it or ask for "
        .. "changes in the chat.",
      schema = { type = "object", properties = {
        work_item_id = target_props.work_item_id, pr_id = target_props.pr_id,
        title = { type = "string", description = "a few words" },
        markdown = { type = "string", description = "the plan, in markdown, following the template" },
      }, required = { "title", "markdown" } },
      risk = "write",
      run = function(args, _, done)
        local target = target_of(args)
        if not target then return done(nil, "give work_item_id or pr_id") end
        if type(args.markdown) ~= "string" or vim.trim(args.markdown) == "" then return done(nil, "the plan is empty") end
        local key = M.key(target)
        local rec = M.load(key) or { key = key, target = target, revisions = {}, threads = {}, created = os.time() }
        if rec.status == "done" then rec.threads = {} end
        rec.title = args.title
        add_revision(rec, args.markdown, "agent")
        M.save(rec)
        M.open(key)
        done({
          shown = true, revision = #rec.revisions, file = M.path(key),
          missing_sections = M.missing(args.markdown, M.template()),
          next = "Stop here and wait for the user: they read the plan, may ask about lines of it, then approve it "
            .. "(you'll get a message) or ask for changes. Don't call start_fix / start_story before it's approved.",
        })
      end,
    },
    {
      name = "get_plan",
      description = "Reads your plan for a work item or PR as it is now - the user may have edited it - with its "
        .. "status (draft, approved, changes_requested, done) and the questions the user asked about its lines.",
      schema = { type = "object", properties = target_props },
      risk = "read",
      run = function(args, _, done)
        local target = target_of(args)
        if not target then return done(nil, "give work_item_id or pr_id") end
        local rec = M.load(M.key(target))
        if not rec then return done(nil, "no plan for " .. M.target_label(target) .. " - write one with submit_plan") end
        local qs = {}
        for _, th in ipairs(rec.threads) do
          qs[#qs + 1] = { line = th.line, about = th.anchor, question = th.question, answer = th.answer }
        end
        local rev = last_rev(rec)
        done({ title = rec.title, status = rec.status, revision = #rec.revisions,
          edited_by_user = rev and rev.by == "you" or false,
          markdown = table.concat(current_lines(rec), "\n"), questions = qs })
      end,
    },
  }
end

return M
