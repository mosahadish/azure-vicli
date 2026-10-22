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
-- plan of its own. Opening a PR for it links the PR (link_pr); when that
-- PR is merged or abandoned the plan is finished (pr_closed, from
-- chat/watch.lua).
--
-- Two plans changing the same files make PRs that conflict: approving one
-- that overlaps a plan still in flight says so, and can hold its go-ahead
-- back until that one is finished (wait_for; M.release_waiting).
--
-- Kept under stdpath("data")/azure-cli-chat/plans/: <key>.md (the plan's
-- text, the file gf edits) and <key>.json (its title, status, revisions
-- and questions), key = "wi-<id>", "pr-<id>" (Azure) or
-- "pr-github-<owner~repo~number>" (plan_text.lua's key). Only the last
-- chat.plan_revisions (3) revisions are kept, and the one last approved;
-- each keeps its real number (M.save, plan_text.lua's prune_revisions).
--
-- In three files, one module: this one (storage, the gate, approving,
-- the run log, the tools), chat/plan_text.lua (the pure helpers - key,
-- target_label, sections, section_at, missing, gate_check,
-- approval_message, revise_message, status_label, ...) and
-- chat/plan_view.lua (the tab - open, refresh, describe). Callers only
-- ever require this one.
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
local function THREADS() return require("azure-cli.chat.threads") end
local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function config() return require("azure-cli.config").get().chat or {} end
local function VIEW() return require("azure-cli.chat.plan_view") end

function M.template() return config().plan_template or M.TEMPLATE end

-- ---------------------------------------------------------------------------
-- The plan's text: chat/plan_text.lua's pure helpers are this module's too.

for k, v in pairs(require("azure-cli.chat.plan_text")) do M[k] = v end

-- ---------------------------------------------------------------------------
-- Finding a plan.

-- The plan for the change in worktree `dir` (start_fix's <repo>-<pr id>
-- or, for a GitHub PR, pr-github-<key>; start_story's <repo>-wi<id> or,
-- for a GitHub issue, wi-github-<key>): its record, or nil.
function M.for_worktree(dir)
  local name = vim.fn.fnamemodify((dir or ""):gsub("[/\\]+$", ""), ":t")
  -- A GitHub PR's or issue's worktree is named after its plan (#113,
  -- #114); only those have a "~".
  if name:find("~", 1, true) and (name:match("^pr%-github%-.") or name:match("^wi%-github%-.")) then
    return M.load(name)
  end
  local task = name:match("%-task(%d+)$")
  if task then return M.load("task-" .. task) end
  local wi = name:match("%-wi(%d+)$")
  if wi then return M.load("wi-" .. wi) end
  local pr = name:match("%-(%d+)$")
  if not pr then return nil end
  -- A GitHub PR's fix begun before #113 is in <repo>-<id>, its plan under
  -- its key (#109): the listed PR whose old fix worktree this is.
  local STATE = require("azure-cli.state")
  local TF = require("azure-cli.chat.tools_fix")
  local cands = vim.list_extend({}, (STATE.PR_LIST_CACHE and STATE.PR_LIST_CACHE.prs) or {})
  if STATE.PR_CURRENT then cands[#cands + 1] = STATE.PR_CURRENT end
  for _, p in ipairs(cands) do
    if tostring(p.id) == pr and vim.fn.fnamemodify(TF.legacy_path(p), ":t") == name then
      local rec = M.load(M.key(M.pr_target(p)))
      if rec then return rec end
    end
  end
  return M.load("pr-" .. pr)
end

-- ---------------------------------------------------------------------------
-- Task agents (#143): an agent the main chat started on a free-form task,
-- keyed task-<n>, its target { task_id = n }. Read-only until a plan of
-- its own is approved.

-- The calling agent's own task target ({ task_id }), or nil when `env`'s
-- conversation isn't a task agent's.
function M.task_target_for(env)
  local own = env and env.conv and env.conv.target
  if type(own) == "table" and own.task_id then return { task_id = own.task_id } end
  return nil
end

-- Whether conversation `conv` is a task agent without an approved plan:
-- then it changes no files and runs only M.TASK_TOOLS of the write tools.
function M.task_read_only(conv)
  if not (conv and type(conv.target) == "table" and conv.target.task_id) then return false end
  local rec = M.load(conv.plan_key or M.key(conv.target))
  return not (rec and (rec.status == "approved" or rec.status == "done"))
end

-- The tools beyond the read ones a read-only task agent may call: writing
-- its plan, drafts (queued for the user, never posted), and start_story /
-- start_fix, which only give a read-only worktree before approval.
M.TASK_TOOLS = { submit_plan = true, draft_reply = true, draft_comment = true, start_story = true, start_fix = true }

-- nil, or why tool `tool` ({ name, risk }) refuses a call from `conv`.
function M.task_refusal(conv, tool)
  if tool.risk == "read" or M.TASK_TOOLS[tool.name] or not M.task_read_only(conv) then return nil end
  return "a task agent is read-only until the user approves a plan: " .. tool.name .. " isn't available. If the "
    .. "user asked for a change, write a plan with submit_plan and wait for their approval."
end

-- The next task number: one more than any used before, kept in
-- plans/tasks.json so a key never repeats across restarts.
function M.next_task_id()
  local path = M.root() .. "/tasks.json"
  local ok, lines = pcall(vim.fn.readfile, path)
  local okd, d = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  local n = (okd and type(d) == "table" and tonumber(d.last) or 0) + 1
  vim.fn.mkdir(M.root(), "p")
  pcall(vim.fn.writefile, { vim.json.encode({ last = n }) }, path)
  return n
end

-- The target of PR `pr_id` as a tool call means it: the calling agent's
-- own PR when it's that number (so an agent on one GitHub #7 never means
-- another), else the listed PR (in `repo`, owner/repo or repo, when
-- given), else { pr_id } (#109).
function M.pr_target_for(pr_id, env, repo)
  if pr_id == nil then return nil end
  local own = env and env.conv and env.conv.target
  if type(own) == "table" and own.pr_id and tostring(own.pr_id) == tostring(pr_id) and not repo then
    return { pr_id = own.pr_id, pr_key = own.pr_key }
  end
  local pr = require("azure-cli.chat.tools").pr_record(pr_id, repo)
  return pr and M.pr_target(pr) or { pr_id = pr_id }
end

local function is_repo(p)
  return p ~= "" and (vim.fn.isdirectory(p .. "/.git") == 1 or vim.fn.filereadable(p .. "/.git") == 1)
end

-- Whether issue key "owner~repo~n" is in `repo` (owner/repo or repo).
local function key_in_repo(key, repo)
  local owner, name = tostring(key):match("^([^~]*)~(.-)~%d+$")
  return owner ~= nil and (tostring(repo) == name or tostring(repo) == owner .. "/" .. name)
end

-- GitHub issues looked up this session that no list showed yet (#127: one
-- created in the session, before the board is refreshed), by key.
local noted = {}

-- Remembers issue `item` (with its key) as listed, so its number finds it.
function M.note_issue(item)
  if type(item) == "table" and item.id and item.key and item.key ~= "" then noted[tostring(item.key)] = item end
end

-- For tests: forget the noted issues.
function M.reset_noted() noted = {} end

-- The GitHub issues numbered `id` listed this session (the Issues board's
-- list and its sprint tabs, and M.note_issue's), in `repo` when given,
-- once each.
local function listed_issues(id, repo)
  local S = require("azure-cli.workitems.board").get("github").state
  local lists = { (S.WI_LIST_CACHE or {}).items or {}, vim.tbl_values(noted) }
  for _, c in pairs(S.WI_SPRINT_ITEMS or {}) do lists[#lists + 1] = c.items or {} end
  local out, seen = {}, {}
  for _, items in ipairs(lists) do
    for _, it in ipairs(items) do
      if type(it) == "table" and tostring(it.id) == tostring(id) and it.key and it.key ~= "" and not seen[it.key]
          and (not repo or key_in_repo(it.key, repo)) then
        seen[it.key] = true
        out[#out + 1] = it
      end
    end
  end
  return out
end

-- The config has the Issues board and no Azure one (as refs.lua's).
local function issues_only()
  local b = require("azure-cli.state").BOARDS
  return b ~= nil and not b.workItems and require("azure-cli.workitems.board").has_issues() == true
end

-- Plan `key`'s agent's first view of its work item, { board, key }, or
-- nil: its live conversation's, else its saved one's (read once).
local recorded = nil
local function recorded_view(key)
  local function from(entries)
    for _, e in ipairs(entries or {}) do
      local w = e.role == "you" and type(e.view) == "table" and e.view.work_item
      if type(w) == "table" then return { board = w.board or "azure", key = w.key } end
    end
  end
  local ok, CHAT = pcall(require, "azure-cli.chat")
  local conv = ok and CHAT.find_conversation(key)
  local live = conv and from(conv.entries)
  if live then return live end
  if not recorded then
    recorded = {}
    for _, s in ipairs(STORE().list()) do  -- newest first
      if s.plan and recorded[s.plan] == nil then
        local rec = STORE().load(s.id)
        recorded[s.plan] = rec and from(rec.entries) or false
      end
    end
  end
  return recorded[key] or nil
end

-- For tests: read the saved conversations again.
function M.reset_recorded() recorded = nil end

-- Before #114 a GitHub issue's plan was keyed wi-<n> like an Azure item's,
-- with nothing in it saying which. Whether old plan wi-<n> is GitHub issue
-- `target`'s ({ work_item_id = n, item_key }): the issue key its agent's
-- conversation recorded; else (a GitHub board's plan) the repository of its
-- one <repo>-wi<n> worktree; else, with only the Issues board, the one
-- listed issue #n. Two candidates and nothing to tell them apart: neither
-- (the plan stays listed under its own key).
function M.legacy_is_for(target)
  local n = target and target.item_key and target.work_item_id
  if not n or not M.load("wi-" .. tostring(n)) then return false end
  local seen = recorded_view("wi-" .. tostring(n))
  if seen and seen.key then return tostring(seen.key) == tostring(target.item_key) end
  if seen and seen.board ~= "github" then return false end
  if not (seen or issues_only()) then return false end
  local repos = {}
  for _, d in ipairs(vim.fn.glob(require("azure-cli.chat.tools_fix").root() .. "/*-wi" .. tostring(n), false, true)) do
    if is_repo(d) then repos[#repos + 1] = vim.fn.fnamemodify(d, ":t"):match("^(.-)%-wi%d+$") end
  end
  if #repos > 0 then return #repos == 1 and key_in_repo(target.item_key, repos[1]) end
  local listed = listed_issues(n)
  return #listed == 1 and tostring(listed[1].key) == tostring(target.item_key)
end

-- Whether old plan wi-<n> is a GitHub issue's by its agent's conversation:
-- an Azure #n doesn't take it (#114).
function M.legacy_is_github(n)
  local seen = recorded_view("wi-" .. tostring(n))
  return seen ~= nil and seen.board == "github"
end

-- `target` as its plan is kept: a GitHub issue with no plan or story under
-- its key yet whose old wi-<n> plan is its own (M.legacy_is_for) is
-- { work_item_id = n } - that plan, its conversation and its <repo>-wi<n>
-- worktree, as before #114. Only looked up, never moved.
function M.resolve_item(target)
  if not (target and target.item_key) then return target end
  if M.load(M.key(target)) or is_repo(require("azure-cli.chat.tools_fix").story_path(nil, target)) then
    return target
  end
  if M.legacy_is_for(target) then return { work_item_id = target.work_item_id } end
  return target
end

-- The target of work item `id` as a tool call means it (#114, as
-- pr_target_for): the calling agent's own when it's that number, else
-- the one GitHub issue listed with it (in `repo` when given; not when
-- `board` is "azure", or the Azure list has it and no board is given),
-- else { work_item_id }.
function M.item_target_for(id, env, repo, board)
  if id == nil then return nil end
  local own = env and env.conv and env.conv.target
  if type(own) == "table" and own.work_item_id and tostring(own.work_item_id) == tostring(id)
      and not (repo and own.item_key and not key_in_repo(own.item_key, repo)) then
    return { work_item_id = own.work_item_id, item_key = own.item_key }
  end
  if board ~= "azure" then
    local in_azure = false
    if board == nil then
      for _, it in ipairs((require("azure-cli.state").WI_LIST_CACHE or {}).items or {}) do
        if type(it) == "table" and tostring(it.id) == tostring(id) then in_azure = true end
      end
    end
    local listed = listed_issues(id, repo)
    if #listed == 1 and not in_azure then return M.resolve_item(M.item_target(listed[1])) end
  end
  return { work_item_id = id }
end

-- The approved (or done) plan behind a pull request: the first of
-- `work_item_ids` with one (as `env`'s agent means them; on GitHub
-- issues of `repo`), else the story or task (#143) whose branch is `source`.
function M.for_pull_request(work_item_ids, source, env, repo)
  local function usable(rec) return rec and (rec.status == "approved" or rec.status == "done") end
  for _, id in ipairs(work_item_ids or {}) do
    local rec = M.load(M.key(M.item_target_for(id, env, repo)))
    if usable(rec) then return rec end
  end
  local files = vim.fn.glob(M.root() .. "/wi-*.json", false, true)
  vim.list_extend(files, vim.fn.glob(M.root() .. "/task-*.json", false, true))
  for _, f in ipairs(files) do
    local rec = M.load(vim.fn.fnamemodify(f, ":t:r"))
    if usable(rec) and type(rec.target) == "table" and (rec.target.work_item_id or rec.target.task_id) then
      local _, branch = require("azure-cli.chat.tools_fix").find_story(rec.target)
      if branch and branch == source then return rec end
    end
  end
  return nil
end

-- create_pull_request's description: `given` as it is, the plan's when
-- there's none, or both with `from_plan`.
function M.description_for(given, from_plan, work_item_ids, source, env, repo)
  given = given and vim.trim(given) or ""
  if given ~= "" and not from_plan then return given end
  local rec = M.for_pull_request(work_item_ids, source, env, repo)
  if not rec then return given end
  local planned = M.pr_description(rec, M.lines(rec))
  return given ~= "" and (given .. "\n\n" .. planned) or planned
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
  M.number_revisions(rec)
  return rec
end

-- key -> { status, label }, for the status strip: built from the files
-- once, kept up to date by M.save.
local index = nil

-- The index changed: the tab line's "N plans wait for you" (and a
-- statusline's strip()) drawn again (#117) - once, after the burst of
-- saves that changed it, out of the caller's way.
local redraw_pending = false
local function redraw_soon()
  if redraw_pending then return end
  redraw_pending = true
  vim.schedule(function()
    redraw_pending = false
    pcall(vim.cmd, "redrawstatus!")
    pcall(vim.cmd, "redrawtabline")
  end)
end

-- Saving keeps at most chat.plan_revisions (3) revisions - never the
-- newest, the one last approved (#90) or the one its PR was opened from
-- (the original plan, once the agent plans fixes to that PR) dropped. A
-- plan from before that with more is pruned the same way the next time
-- it's saved.
function M.save(rec)
  rec.revisions = rec.revisions or {}
  M.number_revisions(rec)
  rec.last_approved_rev = M.last_approved(rec)
  rec.revisions = M.prune_revisions(rec.revisions, config().plan_revisions or 3,
    { rec.last_approved_rev, M.pr_rev(rec) })
  if index then index[rec.key] = { status = rec.status, label = M.target_label(rec.target) } end
  vim.fn.mkdir(M.root(), "p")
  vim.fn.writefile({ vim.json.encode(rec) }, M.root() .. "/" .. rec.key .. ".json")
  redraw_soon()
end

-- Plan `key`'s files are gone (chat/plan_discard.lua): out of the index.
function M.forget(key)
  if index then index[key] = nil end
  redraw_soon()
  -- A plan waiting for this one may start now.
  vim.schedule(function() pcall(M.release_waiting) end)
end

local function last_rev(rec) return rec.revisions[#rec.revisions] end

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
  return M.check_files(M.files_section(rec), changed, vim.list_extend(vim.list_slice(M.allowed_paths(rec)), M.test_files(rec)))
end

-- The paths the plan's Files section lists: the approved revision's, so
-- an earlier revision's (stage's) files don't count; the text as it is
-- now while none is approved.
function M.files_section(rec)
  local rev = M.revision(rec, rec.approved_rev)
  return M.planned_files(rev and vim.split(rev.markdown or "", "\n", { plain = true }) or current_lines(rec))
end

-- The files you allowed the agent to change on top of the approved
-- revision (M.allow_files) - none left over from an earlier one.
function M.allowed_paths(rec)
  if not rec.allowed_files or rec.allowed_rev ~= rec.approved_rev then return {} end
  return rec.allowed_files
end

-- The test files its Test plan names (test_plan_files), in the approved
-- revision as files_section reads it.
function M.test_files(rec)
  local rev = M.revision(rec, rec.approved_rev)
  return M.test_plan_files(rev and vim.split(rev.markdown or "", "\n", { plain = true }) or current_lines(rec))
end

-- The files a plan covers: its Files section, the test files its Test plan
-- names, and the ones you allowed.
function M.planned_paths(rec)
  return vim.list_extend(vim.list_extend(M.files_section(rec), M.test_files(rec)), M.allowed_paths(rec))
end

-- The agent's permission request to change `paths` (absolute) against
-- the approved plans: "planned" (each inside one change's worktree whose
-- plan is approved, and covered by it), "unplanned" (inside such a
-- worktree, but not every file is covered), or nil (no approved plan
-- for it). Also returns the plan's record and the paths' relative forms.
function M.edit_check(paths)
  local TF = require("azure-cli.chat.tools_fix")
  local rec, rels = nil, {}
  for _, p in ipairs(paths or {}) do
    local under = TF.inside(TF.root(), p)
    local name, rel = (under or ""):match("^([^/]+)/(.+)$")
    if not rel then return nil end
    local r = M.for_worktree(TF.root() .. "/" .. name)
    if not (r and r.status == "approved") or (rec and rec.key ~= r.key) then return nil end
    rec, rels[#rels + 1] = r, rel
  end
  if not rec then return nil end
  return M.paths_planned(M.planned_paths(rec), rels) and "planned" or "unplanned", rec, rels
end

-- Whether the agent may run shell command `cmd` without asking: plan
-- `key` is approved and `cmd` runs its Test plan command (is_test_command:
-- a line of it, with more arguments, its tool's build step, ...).
function M.test_command_allowed(key, cmd)
  local rec = M.load(key)
  return rec ~= nil and rec.status == "approved" and M.is_test_command(cmd, M.test_command(current_lines(rec)))
end

-- You allowed changing `rels` once: from now on they're part of the plan.
function M.allow_files(rec, rels)
  rec = M.load(rec.key) or rec
  if rec.allowed_rev ~= rec.approved_rev then rec.allowed_files = nil end
  rec.allowed_files, rec.allowed_rev = rec.allowed_files or {}, rec.approved_rev
  for _, p in ipairs(rels) do
    if not M.paths_planned(rec.allowed_files, { p }) then rec.allowed_files[#rec.allowed_files + 1] = p end
  end
  M.save(rec)
end

-- A new revision `markdown` by `by` ("agent" / "you"): the file rewritten
-- (when the agent wrote it), the questions moved to their lines, the status
-- back to waiting for the user. The one last approved stays known
-- (last_approved_rev), so pruning keeps it.
function M.add_revision(rec, markdown, by)
  M.number_revisions(rec)
  rec.last_approved_rev = M.last_approved(rec)
  -- The revision it replaces keeps its questions as they were on its
  -- lines, so gh shows them with it (the ones going on move with the text).
  local prev = rec.revisions[#rec.revisions]
  if prev and #(rec.threads or {}) > 0 then
    prev.threads = vim.json.decode(vim.json.encode(rec.threads))
  end
  local n = M.rev_count(rec) + 1
  rec.revisions[#rec.revisions + 1] = { n = n, at = os.time(), by = by, markdown = markdown }
  rec.events = rec.events or {}
  table.insert(rec.events, { at = os.time(), kind = "revision", text = "Revision " .. n
    .. (by == "you" and ", edited by you" or ", by the agent") })
  local lines = vim.split(markdown, "\n", { plain = true })
  if by == "agent" then
    vim.fn.mkdir(M.root(), "p")
    vim.fn.writefile(lines, M.path(rec.key))
  end
  THREADS().reanchor(rec.threads, lines)
  rec.status = "draft"
  rec.approved_rev = nil
  rec.allow_push = nil
  rec.allowed_files, rec.allowed_rev = nil, nil
  rec.wait_for = nil
end

-- The labels of the plans waiting for your review (submitted, not yet
-- approved or sent back), e.g. { "#3002" }.
function M.waiting()
  if not index then
    index = {}
    for _, f in ipairs(vim.fn.glob(M.root() .. "/*.json", false, true)) do
      local key = vim.fn.fnamemodify(f, ":t:r")
      local rec = M.load(key)
      if rec and rec.target then index[key] = { status = rec.status, label = M.target_label(rec.target) } end
    end
  end
  local out = {}
  for _, v in pairs(index) do if v.status == "draft" then out[#out + 1] = v.label end end
  table.sort(out)
  return out
end

-- The plan's text as it is now (the user's edits included).
function M.lines(rec) return current_lines(rec) end

-- Records event `text` (kind: revision, approved, changes, tests, pushed,
-- took_out, ...) on plan `rec` (not saved - the caller saves).
function M.add_event(rec, kind, text)
  rec.events = rec.events or {}
  table.insert(rec.events, { at = os.time(), kind = kind, text = text })
end

-- The same for the plan of the change in worktree `dir`, saved.
function M.event_for_worktree(dir, kind, text)
  local rec = M.for_worktree(dir)
  if not rec then return end
  M.add_event(rec, kind, text)
  VIEW().changed(rec)
  -- A push, a hunk taken out: the plan view's Changes section reads it again.
  pcall(function() require("azure-cli.chat.plan_changes").poke() end)
end

-- gH: the run log, written to <plans>/<key>.log.md and opened in a tab.
function M.open_run_log(key)
  local rec = M.load(key)
  if not rec then return notify("No plan " .. tostring(key) .. ".") end
  local TF = require("azure-cli.chat.tools_fix")
  local dir = TF.dir_for(rec.target)
  local threads = {}
  if dir then
    local p = require("azure-cli.chat.store").root() .. "/why/" .. vim.fn.fnamemodify(dir, ":t"):gsub("[^%w%._%-]", "_") .. ".json"
    local ok, l = pcall(vim.fn.readfile, p)
    local okd, list = pcall(vim.json.decode, ok and table.concat(l, "\n") or "")
    if okd and type(list) == "table" then threads = list end
  end
  local audit = {}
  local id = tostring(rec.target.work_item_id or rec.target.pr_id)
  local field = rec.target.work_item_id and "work_item_id" or "pr_id"
  for _, a in ipairs(require("azure-cli.chat.store").audit()) do
    local args = a.args or {}
    if tostring(args[field] or (field == "work_item_id" and args.parent_id) or "") == id and (a.at or 0) >= (rec.created or 0) then
      audit[#audit + 1] = a
    end
  end
  local lines = M.run_log(rec, { threads = threads, tests = dir and require("azure-cli.chat.tests_run").load(dir),
    audit = audit, lines = current_lines(rec) }, function(ts) return os.date("%m-%d %H:%M", ts) end)
  local path = M.root() .. "/" .. key .. ".log.md"
  vim.fn.writefile(lines, path)
  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  vim.bo.modifiable = false
  vim.b.azure_cli_title = "Run log " .. M.target_label(rec.target)
  return path
end

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
  VIEW().changed(rec)
  return #links
end

-- The repository plan `rec`'s change is in, as far as it says: its
-- GitHub key's, its linked PR's, its listed PR's, else its worktree's
-- name (start_story makes one before approval, to read the code in). nil
-- when nothing does. Lower case, without the owner.
function M.repo_of(rec)
  local t = type(rec) == "table" and type(rec.target) == "table" and rec.target or {}
  local function name(s) return s and s ~= "" and tostring(s):lower() or nil end
  local key = t.pr_key or t.item_key or (type(rec.pr) == "table" and rec.pr.key)
  local from_key = key and tostring(key):match("^[^~]*~(.-)~%d+$")
  if from_key then return name(from_key) end
  if t.pr_id then
    local ok, pr = pcall(require("azure-cli.chat.tools").pr_record, t.pr_id)
    return name(ok and type(pr) == "table" and pr.repo or nil)
  end
  if t.work_item_id or t.task_id then
    local d = require("azure-cli.chat.tools_fix").story_dirs(t)[1]
    local dir = d and vim.fn.fnamemodify(d, ":t")
    return dir and name(dir:match("^(.-)%-wi%d+$") or dir:match("^(.-)%-task%d+$"))
  end
  return nil
end

-- The plans approved and not finished (M.in_flight) - and `also`, keys
-- approved along with it - that change some of plan `key`'s files:
-- M.overlaps'.
function M.overlapping(key, also)
  local rec = M.load(key)
  if not rec then return {} end
  local with = {}
  for _, k in ipairs(also or {}) do with[k] = true end
  local others = {}
  for _, f in ipairs(vim.fn.glob(M.root() .. "/*.json", false, true)) do
    local k = vim.fn.fnamemodify(f, ":t:r")
    local o = k ~= key and M.load(k)
    if o and type(o.target) == "table" and (with[k] or M.in_flight(o)) then
      others[#others + 1] = { key = k, label = M.target_label(o.target), repo = M.repo_of(o), files = M.planned_paths(o) }
    end
  end
  return M.overlaps({ key = key, repo = M.repo_of(rec), files = M.planned_paths(rec) }, others)
end

-- How to approve plans `keys` (one question for all of them): cb(allow_push,
-- wait_for) once you've picked - plain approval, or letting each push once
-- its tests pass (without asking, for a plan with no test command). When
-- one changes files a plan in flight changes too (M.overlapping; an earlier
-- of `keys` counts), the popup says which and offers to approve it to start
-- once those are finished: wait_for = key -> { { key, label } }.
function M.ask_approval(keys, cb)
  local has_cmd = false
  for _, k in ipairs(keys) do
    local rec = M.load(k)
    if rec and M.test_command(current_lines(rec)) then has_cmd = true end
  end
  local function label_of(k) return M.target_label(M.load(k).target) end
  local found, waits, blockers, seen = {}, nil, {}, {}
  for i, k in ipairs(keys) do
    found[k] = M.overlapping(k, vim.list_slice(keys, 1, i - 1))
    for _, o in ipairs(found[k]) do
      waits = waits or {}
      waits[k] = waits[k] or {}
      table.insert(waits[k], { key = o.key, label = o.label })
      if not seen[o.key] then seen[o.key] = true; blockers[#blockers + 1] = o.label end
    end
  end
  local what = #keys == 1 and ("the plan for " .. label_of(keys[1])) or (#keys .. " plans")
  local plain, with_push = "Approve", has_cmd and "Approve, and let it push and open the PR once the tests pass"
    or "Approve, and let it push and open the PR without asking"
  local buttons, bkeys = { plain, with_push }, { a = 1, p = 2 }
  local hint = "a approve \u{00B7} p approve and let it push \u{00B7} "
  if waits then
    buttons[3] = #keys == 1 and ("Approve after " .. table.concat(blockers, ", ")) or "Approve, each after the plans it overlaps"
    bkeys.w = 3
    hint = hint .. "w approve after \u{00B7} "
  end
  buttons[#buttons + 1] = "Cancel"
  require("azure-cli.ui").choose({ title = "Approve " .. what .. "?", lines = {
      -- #57: p on a plan that works on an existing branch opens no PR.
      "On an existing branch it pushes straight to it - no PR.",
    }, details = waits and M.overlap_lines(keys, found, label_of) or nil,
    buttons = buttons, keys = bkeys, cancel = #buttons,
    hint = hint .. "Esc cancel \u{00B7} Tab moves" }, function(i)
    if i == 1 or i == 2 then cb(i == 2) end
    if i == 3 and waits then cb(false, waits) end
  end)
end

-- Whether conversation `conv` has had no turn yet: only notes, or none -
-- an orphan plan's (chat/init.lua's restore_plans).
local function untouched(conv)
  for _, e in ipairs(conv and conv.entries or {}) do
    if e.role ~= "note" then return false end
  end
  return true
end

-- The go-ahead to approved plan `rec`'s agent (with your answers, and your
-- version if you edited it): its own conversation when it has one (a
-- board agent), else the main chat. `note`, when given, goes first.
local function go_ahead(rec, note, display)
  local CHAT = require("azure-cli.chat")
  local conv = CHAT.find_conversation(rec.key)
  local text = M.approval_message(rec, current_lines(rec))
  -- An orphan plan's agent (#86) starts with this: it knows nothing yet.
  if conv and untouched(conv) and not rec.target.task_id then
    text = "This plan was written before it had an agent; it's yours now - read it with get_plan ("
      .. (rec.target.work_item_id and ("work_item_id " .. rec.target.work_item_id) or ("pr_id " .. tostring(rec.target.pr_id)))
      .. ") and its " .. (rec.target.work_item_id and "work item" or "pull request") .. " first.\n\n" .. text
  end
  if note then text = note .. "\n\n" .. text end
  local entry = CHAT.send(text, {
    conv = conv, view_win = VIEW().plan_win(rec.key),
    display = display or ("Approved the plan for " .. M.target_label(rec.target)
      .. (rec.allow_push and " (it may push and open the PR once the tests pass)." or ".")),
  })
  if entry then
    for _, th in ipairs(rec.threads) do if th.kind == "answer" then th.status = "sent" end end
    VIEW().changed(rec)
  else
    notify("Approved " .. M.target_label(rec.target) .. " - its agent is still answering; tell it once it's done.",
      vim.log.levels.WARN)
  end
end

-- Approves plan `key`: its status, the run log, and the go-ahead to its
-- agent - held back while `wait_for` ({ { key, label } }, M.ask_approval's)
-- names plans to wait for: M.release_waiting sends it once they're
-- finished. False and why when it can't be approved now.
function M.approve(key, allow_push, wait_for)
  local rec = M.load(key)
  if not rec then return false, "no plan" end
  if rec.status ~= "draft" and rec.status ~= "changes_requested" then
    return false, ({ approved = "already approved", done = "implemented already" })[rec.status] or rec.status
  end
  rec.status = "approved"
  rec.approved_rev = M.rev_count(rec)
  rec.last_approved_rev = rec.approved_rev
  rec.approved_at = os.time()
  rec.allow_push = allow_push or nil
  rec.wait_for = (type(wait_for) == "table" and #wait_for > 0) and vim.deepcopy(wait_for) or nil
  local waits = M.waiting_on(rec)
  M.add_event(rec, "approved", "Approved revision " .. rec.approved_rev
    .. (rec.allow_push and " - pushing allowed once the tests pass" or "")
    .. (#waits > 0 and (" - to start after " .. table.concat(waits, ", ")) or ""))
  VIEW().changed(rec)
  if #waits == 0 then go_ahead(rec) end
  return true
end

-- Plan `key`, approved to start after others, starts now: its go-ahead
-- sent, with `note` (M.release_waiting's), or without (you didn't wait).
function M.start_waiting(key, note)
  local rec = M.load(key)
  local waits = M.waiting_on(rec)
  if #waits == 0 then return false end
  rec.wait_for = nil
  M.add_event(rec, "approved", note and ("Started: " .. table.concat(waits, ", ") .. " finished")
    or ("Started without waiting for " .. table.concat(waits, ", ")))
  VIEW().changed(rec)
  go_ahead(rec, note, "Approved the plan for " .. M.target_label(rec.target)
    .. (note and (" (after " .. table.concat(waits, ", ") .. ")") or "") .. ".")
  return true
end

-- The plans approved to start after others: each whose others are all
-- finished (merged, abandoned or discarded: no longer M.in_flight) gets
-- its go-ahead, told to start from the target branch as it is now; the
-- rest remember which have finished. Run when a plan finishes or goes,
-- and once a session (one may have while azure-vicli was closed). Returns
-- the keys started.
function M.release_waiting()
  local started = {}
  for _, f in ipairs(vim.fn.glob(M.root() .. "/*.json", false, true)) do
    local rec = M.load(vim.fn.fnamemodify(f, ":t:r"))
    if rec and rec.key and #M.waiting_on(rec) > 0 then
      local left, changed = 0, false
      for _, w in ipairs(rec.wait_for) do
        if not w.done and not M.in_flight(M.load(w.key)) then w.done, changed = true, true end
        if not w.done then left = left + 1 end
      end
      if left == 0 then
        local all = {}
        for _, w in ipairs(rec.wait_for) do
          all[#all + 1] = w.label
          w.done = nil  -- so start_waiting names them all
        end
        M.save(rec)
        pcall(require("azure-cli.chat").restore_plans)
        M.start_waiting(rec.key, table.concat(all, ", ") .. " (changing some of the same files) is finished: start "
          .. "from the target branch as it is now, fetched fresh - not an older checkout of it.")
        started[#started + 1] = rec.key
      elseif changed then
        VIEW().changed(rec)
      end
    end
  end
  return started
end

-- gA on a plan that waits for others: start it now, asking first. cb()
-- once it has.
function M.ask_start_now(key, cb)
  local rec = M.load(key)
  local waits = M.waiting_on(rec)
  if #waits == 0 then return end
  require("azure-cli.ui").choose({ title = "Start " .. M.target_label(rec.target) .. " now, without waiting for "
    .. table.concat(waits, ", ") .. "?", buttons = { "Start", "Cancel" }, keys = { s = 1 }, cancel = 2 }, function(i)
    if i == 1 and M.start_waiting(key) and cb then cb() end
  end)
end

-- ---------------------------------------------------------------------------
-- The gate (chat/tools_fix.lua).

-- nil, or why tool `name` refuses a call from the main chat (env.main_chat,
-- chat/init.lua's tool_env): plans and code changes are an agent's, one
-- per work item or PR (#86). `target` = { work_item_id } or { pr_id }.
function M.main_chat_refusal(env, name, target)
  if not (env and env.main_chat) then return nil end
  local repo = target and target.pr_key and tostring(target.pr_key):match("^(.-~.-)~%d+$")
  local which = (target and target.pr_id) and ("pr_id = " .. tostring(target.pr_id)
      .. (repo and (", repo = \"" .. repo:gsub("~", "/") .. "\"") or ""))
    or (target and target.work_item_id) and ("work_item_ids = { " .. tostring(target.work_item_id) .. " }")
    or "work_item_ids or pr_id"
  return name .. " isn't available in the main chat: planning and changing code is done by an agent of its own, one "
    .. "per work item or PR, so its plan, worktree and conversation stay together and show on the Agents screen. "
    .. "Call start_agents with " .. which .. " instead (pass board as you would here, and what the user asked as "
    .. "`instructions`)."
end

function M.gate(target)
  return M.gate_check(M.load(M.key(target)), config().plan_first, target)
end

-- Whether commit_and_push_fix may skip its question for `target`'s change
-- in worktree `dir`: cb(ok, why).
function M.push_allowed(target, dir, cb)
  local rec = M.load(M.key(target))
  if not (rec and rec.allow_push) then return cb(false) end  -- nothing to explain: you didn't allow it
  local TR = require("azure-cli.chat.tests_run")
  local has_cmd = M.test_command(current_lines(rec)) ~= nil
  require("azure-cli.chat.tools_fix").diff(dir, function(ok, diff)
    if not ok then return cb(false, diff) end
    cb(M.push_check(rec, has_cmd, TR.load(dir), TR.fingerprint(diff)))
  end, require("azure-cli.chat.tools").git)
end

-- Whether create_pull_request `a` may skip its question: the work item's
-- plan was approved with pushing allowed, its change is pushed, it has no
-- PR yet, and `a` is that PR - from its story's branch into the branch it
-- started from, linking the work item. cb(ok, why) - why only when the
-- plan allowed it but this isn't quite it.
function M.pr_allowed(a, cb)
  local rec = M.for_pull_request(a.work_item_ids, a.source, nil, a.repo)
  if not (rec and rec.allow_push and rec.target and (rec.target.work_item_id or rec.target.task_id)) then return cb(false) end
  local wi = rec.target.work_item_id
  local label = M.target_label(rec.target)
  local _, branch, base, existing = require("azure-cli.chat.tools_fix").find_story(rec.target)
  if existing then return cb(false, "the story for " .. label .. " works on the existing branch " .. branch .. " - no PR") end
  -- A task's PR (#143) has no work item to link.
  local linked = wi == nil
  for _, id in ipairs(a.work_item_ids or {}) do if tostring(id) == tostring(wi) then linked = true end end
  if type(rec.pr) == "table" then return cb(false, "the plan for " .. label .. " already opened PR !" .. tostring(rec.pr.id)) end
  if rec.status ~= "done" then return cb(false, "the plan's change isn't pushed yet") end
  if branch and a.source ~= branch then return cb(false, "it isn't from the story's branch (" .. branch .. ")") end
  if base and a.target ~= base then return cb(false, "it targets " .. tostring(a.target) .. ", not " .. base .. ", which the story started from") end
  if not linked then return cb(false, "it doesn't link #" .. wi) end
  cb(true, "the approved plan (pushing and its PR allowed)")
end

-- commit_and_push_fix pushed the change: its plan is done.
function M.mark_done(target)
  local rec = M.load(M.key(target))
  if rec and rec.status == "approved" then
    rec.status = "done"
    rec.done_at = os.time()
    VIEW().changed(rec)
  end
end

-- create_pull_request opened PR `pr` ({ id, org, project }): the plans of
-- `work_item_ids`, and the story's whose branch is `source`, know their PR
-- (the Agents screen shows it, and when it's closed - M.pr_closed). `env`
-- and `repo` say which issues the ids mean, as in M.for_pull_request.
function M.link_pr(work_item_ids, source, pr, env, repo)
  local recs, seen = {}, {}
  for _, id in ipairs(work_item_ids or {}) do
    local rec = M.load(M.key(M.item_target_for(id, env, repo)))
    if rec then recs[#recs + 1] = rec; seen[rec.key] = true end
  end
  local by_branch = M.for_pull_request(nil, source)
  if by_branch and not seen[by_branch.key] then recs[#recs + 1] = by_branch end
  local key = M.pr_target(pr).pr_key
  for _, rec in ipairs(recs) do
    rec.pr = { id = pr.id, org = pr.org, project = pr.project, key = key, rev = M.last_approved(rec) }
    rec.pr_state, rec.closed_at = nil, nil
    M.add_event(rec, "pr", "Opened PR !" .. tostring(pr.id))
    VIEW().changed(rec)
  end
end

-- `pr` (a PR record, or a bare id) as a target.
local function as_target(pr)
  if type(pr) == "table" then return M.pr_target(pr) end
  return { pr_id = pr }
end

-- Whether a plan's linked PR `linked` ({ id, key }) is `target`'s: by key
-- when either has one (a GitHub number repeats across repos), else by id.
local function same_pr(linked, target)
  if type(linked) ~= "table" then return false end
  if linked.key or target.pr_key then return tostring(linked.key) == tostring(target.pr_key) end
  return tostring(linked.id) == tostring(target.pr_id)
end

-- The work item's plan that opened PR `pr` (a record, or an Azure id;
-- link_pr) while that PR is still open: its agent is the one to fix what
-- reviewers say. A PR opened before plans recorded theirs is found by its
-- `source` branch being the story's. Or nil.
function M.owner_of_pr(pr, source)
  local target = as_target(pr)
  for _, f in ipairs(vim.fn.glob(M.root() .. "/wi-*.json", false, true)) do
    local rec = M.load(vim.fn.fnamemodify(f, ":t:r"))
    if rec and same_pr(rec.pr, target) and not rec.pr_state then return rec end
  end
  local rec = source and source ~= "" and M.for_pull_request(nil, source) or nil
  if rec and rec.pr == nil and not rec.pr_state then return rec end
  return nil
end

-- The plan PR `pr_id` means for `env`'s agent: its own work item's when
-- that plan opened the PR (owner_of_pr) - so planning a fix to it is a new
-- revision of the plan behind it, which the Agents screen shows - else
-- the PR's own (pr_target_for).
function M.plan_target_for(pr_id, env, repo)
  local target = M.pr_target_for(pr_id, env, repo)
  local own = env and env.conv and env.conv.plan_key
  if not (target and own and own ~= M.key(target)) then return target end
  local rec = M.load(own)
  if not (rec and type(rec.target) == "table" and (rec.target.work_item_id or rec.target.item_key)) then
    return target
  end
  local pr = require("azure-cli.chat.tools").pr_record(target.pr_key or pr_id, not target.pr_key and repo or nil)
  local owner = M.owner_of_pr(pr or target.pr_id, pr and pr.source)
  if owner and owner.key == own then return rec.target end
  return target
end

-- PR `pr` (a record, or an Azure id) was completed or abandoned (`state`;
-- chat/watch.lua saw it): the plans behind it - the PR's own, and the
-- stories it was opened for - are finished. Returns how many it marked.
function M.pr_closed(pr, state)
  local target = as_target(pr)
  local own = M.key(target)
  local n = 0
  for _, f in ipairs(vim.fn.glob(M.root() .. "/*.json", false, true)) do
    local rec = M.load(vim.fn.fnamemodify(f, ":t:r"))
    if rec and rec.key and not rec.pr_state and (rec.key == own or same_pr(rec.pr, target)) then
      rec.pr_state, rec.closed_at = state, os.time()
      M.add_event(rec, "closed", M.target_label(target) .. (state == "completed" and " was merged" or " was abandoned"))
      VIEW().changed(rec)
      n = n + 1
    end
  end
  if n > 0 then pcall(M.release_waiting) end
  return n
end

-- ---------------------------------------------------------------------------
-- Tools (chat/tools.lua).

function M.tools(T)
  local target_props = {
    work_item_id = { type = "integer", description = "the work item the plan is for (implementing a story/bug/task)" },
    pr_id = { type = "integer", description = "the pull request the plan is for (fixing a review comment)" },
    repo = { type = "string", description = "GitHub only: the PR's or issue's repository (owner/repo), when two "
      .. "share the number" },
  }
  -- Without work_item_id or pr_id, a task agent's own task (#143).
  local function target_of(args, env)
    if args.work_item_id then return M.item_target_for(args.work_item_id, env, args.repo) end
    if args.pr_id then return M.plan_target_for(args.pr_id, env, args.repo) end
    return M.task_target_for(env)
  end
  -- A task agent (#143) planning for a work item or PR becomes that
  -- plan's agent: its conversation moves to the plan's key, so approving
  -- it reaches this agent. Nil, or why it can't.
  local function adopt(env, target)
    local conv = env and env.conv
    if not (conv and type(conv.target) == "table" and conv.target.task_id) or target.task_id then return nil end
    local key = M.key(target)
    local CHAT = require("azure-cli.chat")
    local other = CHAT.find_conversation(key)
    if other and other ~= conv then
      return M.target_label(target) .. " already has an agent of its own - ask the user to have the main chat "
        .. "message_agent it instead"
    end
    CHAT.rekey_conversation(conv.plan_key, key, { target = target, label = M.target_label(target) })
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
        .. "changes in the chat. A task agent leaves both out for a plan of its task's own; giving one makes it "
        .. "that work item's or PR's agent.",
      schema = { type = "object", properties = {
        work_item_id = target_props.work_item_id, pr_id = target_props.pr_id,
        title = { type = "string", description = "a few words" },
        markdown = { type = "string", description = "the plan, in markdown, following the template" },
      }, required = { "title", "markdown" } },
      risk = "write",
      run = function(args, env, done)
        local target = target_of(args, env)
        local refused = M.main_chat_refusal(env, "submit_plan", target)
        if refused then return done(nil, refused) end
        if not target then return done(nil, "give work_item_id or pr_id") end
        if type(args.markdown) ~= "string" or vim.trim(args.markdown) == "" then return done(nil, "the plan is empty") end
        local not_adopted = adopt(env, target)
        if not_adopted then return done(nil, not_adopted) end
        local key = M.key(target)
        local rec = M.load(key) or { key = key, target = target, revisions = {}, threads = {}, created = os.time() }
        -- A plan already carried out starts its next round without the old
        -- questions - they stay with the revision they were on (gh).
        local fresh = rec.status == "done"
        rec.title = args.title
        M.add_revision(rec, args.markdown, "agent")
        if fresh then rec.threads = {} end
        M.save(rec)
        -- No agent pulls you into its plan, not even the one in the
        -- foreground (#120): it says it's ready, and a view of the plan
        -- that's already open shows the new revision where it is.
        notify("The plan for " .. M.target_label(target) .. " is ready on the Agents screen.")
        pcall(function() require("azure-cli.chat").alert("azure-vicli: plan " .. M.target_label(target) .. " is ready",
          tostring(args.title or "") .. " - waiting for your review") end)
        VIEW().show(key, rec)
        done({
          shown = false, revision = M.rev_count(rec), file = M.path(key),
          missing_sections = M.missing(args.markdown, M.template()),
          -- How the tests run: without one the user can't run them (gb)
          -- and every test run of yours asks.
          test_command = M.test_command(current_lines(rec)) or vim.NIL,
          test_command_note = not M.test_command(current_lines(rec))
            and "Your Test plan has no command to run the tests. Add it in a ```sh block under ## Test plan (one "
              .. "command per line) with submit_plan again, so the user can run it and, once the plan is approved, "
              .. "you can run it (with more arguments, after its build step) without asking." or nil,
          next = "Stop here and wait for the user: they read the plan, may ask about lines of it, then approve it "
            .. "(you'll get a message) or ask for changes. Don't call start_fix / start_story before it's approved.",
          note = "The plan isn't on screen: it waits for the user on the Agents screen - say it's ready, not that "
            .. "you opened it.",
          stored_as = (args.pr_id and not target.pr_id) and ("a new revision of your plan for " .. M.target_label(target)
            .. ", which opened PR !" .. tostring(args.pr_id) .. " - use its work item from here on (start_story, "
            .. "commit_and_push_fix)") or nil,
        })
      end,
    },
    {
      name = "get_plan",
      description = "Reads your plan for a work item or PR as it is now - the user may have edited it - with its "
        .. "status (draft, approved, changes_requested, done) and the questions the user asked about its lines.",
      schema = { type = "object", properties = target_props },
      risk = "read",
      run = function(args, env, done)
        local target = target_of(args, env)
        if not target then return done(nil, "give work_item_id or pr_id") end
        local rec = M.load(M.key(target))
        if not rec then return done(nil, "no plan for " .. M.target_label(target) .. " - write one with submit_plan") end
        local qs = {}
        for _, th in ipairs(rec.threads) do
          qs[#qs + 1] = { line = th.line, about = th.anchor, question = th.question, answer = th.answer }
        end
        local rev = last_rev(rec)
        done({ title = rec.title, status = rec.status, revision = M.rev_count(rec),
          edited_by_user = rev and rev.by == "you" or false,
          markdown = table.concat(current_lines(rec), "\n"), questions = qs })
      end,
    },
    {
      name = "discard_plan",
      description = "The main chat only: discards a plan no agent has worked on - one written in the main chat "
        .. "before planning moved to agents (the Agents screen says so). Its files move to plans/discarded/. A plan "
        .. "an agent wrote or worked on can't be discarded this way.",
      schema = { type = "object", properties = target_props },
      risk = "ask",
      confirm = function(a)
        return "discard the plan for " .. M.target_label(target_of(a) or {}) .. " (its files move to plans/discarded/)"
      end,
      run = function(args, env, done)
        if not (env and env.main_chat) then return done(nil, "only the main chat discards plans") end
        local target = target_of(args, env)
        if not target then return done(nil, "give work_item_id or pr_id") end
        local key = M.key(target)
        if not M.load(key) then return done(nil, "no plan for " .. M.target_label(target)) end
        local CHAT = require("azure-cli.chat")
        local conv = CHAT.find_conversation(key)
        if conv and (conv.running or not untouched(conv)) then
          return done(nil, "an agent has worked on the plan for " .. M.target_label(target)
            .. " - it isn't discarded this way (message_agent it, or the user reviews it)")
        end
        local dir, err = require("azure-cli.chat.plan_discard").move_files(key)
        if not dir then return done(nil, err) end
        CHAT.drop_conversation(key)
        done("Discarded the plan for " .. M.target_label(target) .. " (moved to " .. dir .. ").")
      end,
    },
  }
end

-- ---------------------------------------------------------------------------
-- The viewer (chat/plan_view.lua): open, refresh, current, open_views,
-- describe, describe_view are this module's too. Loaded now, not on first
-- use: it also watches for the plan files being saved by hand.

for _, name in ipairs({ "open", "refresh", "current", "open_views", "describe", "describe_view" }) do
  M[name] = require("azure-cli.chat.plan_view")[name]
end

return M
