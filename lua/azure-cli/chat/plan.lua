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
-- Kept under stdpath("data")/azure-cli-chat/plans/: <key>.md (the plan's
-- text, the file gf edits) and <key>.json (its title, status, revisions
-- and questions), key = "wi-<id>" or "pr-<id>".
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

-- The plan for the change in worktree `dir` (start_fix's <repo>-<pr id>,
-- start_story's <repo>-wi<id>): its record, or nil.
function M.for_worktree(dir)
  local name = vim.fn.fnamemodify((dir or ""):gsub("[/\\]+$", ""), ":t")
  local wi = name:match("%-wi(%d+)$")
  if wi then return M.load("wi-" .. wi) end
  local pr = name:match("%-(%d+)$")
  return pr and M.load("pr-" .. pr) or nil
end

-- The approved (or done) plan behind a pull request: the first of
-- `work_item_ids` with one, else the story whose branch is `source`.
function M.for_pull_request(work_item_ids, source)
  local function usable(rec) return rec and (rec.status == "approved" or rec.status == "done") end
  for _, id in ipairs(work_item_ids or {}) do
    local rec = M.load("wi-" .. tostring(id))
    if usable(rec) then return rec end
  end
  for _, f in ipairs(vim.fn.glob(M.root() .. "/wi-*.json", false, true)) do
    local id = vim.fn.fnamemodify(f, ":t:r"):match("^wi%-(%d+)$")
    local _, branch = require("azure-cli.chat.tools_fix").find_story(id)
    if branch and branch == source then
      local rec = M.load("wi-" .. id)
      if usable(rec) then return rec end
    end
  end
  return nil
end

-- create_pull_request's description: `given` as it is, the plan's when
-- there's none, or both with `from_plan`.
function M.description_for(given, from_plan, work_item_ids, source)
  given = given and vim.trim(given) or ""
  if given ~= "" and not from_plan then return given end
  local rec = M.for_pull_request(work_item_ids, source)
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
  return rec
end

-- key -> { status, label }, for the status strip: built from the files
-- once, kept up to date by M.save.
local index = nil

function M.save(rec)
  if index then index[rec.key] = { status = rec.status, label = M.target_label(rec.target) } end
  vim.fn.mkdir(M.root(), "p")
  vim.fn.writefile({ vim.json.encode(rec) }, M.root() .. "/" .. rec.key .. ".json")
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
  return M.check_files(M.files_section(rec), changed, M.allowed_paths(rec))
end

-- The paths the plan's Files section lists: the approved revision's, so
-- an earlier revision's (stage's) files don't count; the text as it is
-- now while none is approved.
function M.files_section(rec)
  local rev = rec.approved_rev and rec.revisions[rec.approved_rev]
  return M.planned_files(rev and vim.split(rev.markdown or "", "\n", { plain = true }) or current_lines(rec))
end

-- The files you allowed the agent to change on top of the approved
-- revision (M.allow_files) - none left over from an earlier one.
function M.allowed_paths(rec)
  if not rec.allowed_files or rec.allowed_rev ~= rec.approved_rev then return {} end
  return rec.allowed_files
end

-- The files a plan covers: its Files section, plus the ones you allowed.
function M.planned_paths(rec)
  return vim.list_extend(M.files_section(rec), M.allowed_paths(rec))
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
-- back to waiting for the user.
function M.add_revision(rec, markdown, by)
  rec.revisions[#rec.revisions + 1] = { at = os.time(), by = by, markdown = markdown }
  rec.events = rec.events or {}
  table.insert(rec.events, { at = os.time(), kind = "revision", text = "Revision " .. #rec.revisions
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

-- How to approve plans `keys` (one question for all of them): cb(allow_push)
-- once you've picked - plain approval, or letting each push once its tests
-- pass (without asking, for a plan with no test command).
function M.ask_approval(keys, cb)
  local has_cmd = false
  for _, k in ipairs(keys) do
    local rec = M.load(k)
    if rec and M.test_command(current_lines(rec)) then has_cmd = true end
  end
  local what = #keys == 1 and ("the plan for " .. M.target_label(M.load(keys[1]).target)) or (#keys .. " plans")
  local plain, with_push = "Approve", has_cmd and "Approve, and let it push and open the PR once the tests pass"
    or "Approve, and let it push and open the PR without asking"
  require("azure-cli.ui").choose({ title = "Approve " .. what .. "?", lines = {
      "The agent goes ahead with it. Letting it push skips the questions before its push and its pull request"
        .. (has_cmd and ", once the plan's tests pass on its change." or "."),
    }, buttons = { plain, with_push, "Cancel" }, keys = { a = 1, p = 2 }, cancel = 3,
    hint = "a approve \u{00B7} p approve and let it push \u{00B7} Esc cancel \u{00B7} Tab moves" }, function(i)
    if i == 1 or i == 2 then cb(i == 2) end
  end)
end

-- Approves plan `key`: its status, the run log, and the go-ahead (with
-- your answers, and your version if you edited it) to the agent that
-- wrote it - its own conversation when it has one (a board agent), else
-- the main chat. False and why when it can't be approved now.
function M.approve(key, allow_push)
  local rec = M.load(key)
  if not rec then return false, "no plan" end
  if rec.status ~= "draft" and rec.status ~= "changes_requested" then
    return false, ({ approved = "already approved", done = "implemented already" })[rec.status] or rec.status
  end
  rec.status = "approved"
  rec.approved_rev = #rec.revisions
  rec.approved_at = os.time()
  rec.allow_push = allow_push or nil
  M.add_event(rec, "approved", "Approved revision " .. #rec.revisions
    .. (rec.allow_push and " - pushing allowed once the tests pass" or ""))
  VIEW().changed(rec)
  local CHAT = require("azure-cli.chat")
  local conv = CHAT.find_conversation(key)
  local entry = CHAT.send(M.approval_message(rec, current_lines(rec)), {
    conv = conv, view_win = VIEW().plan_win(key),
    display = "Approved the plan for " .. M.target_label(rec.target)
      .. (rec.allow_push and " (it may push and open the PR once the tests pass)." or "."),
  })
  if entry then
    for _, th in ipairs(rec.threads) do if th.kind == "answer" then th.status = "sent" end end
    VIEW().changed(rec)
  else
    notify("Approved " .. M.target_label(rec.target) .. " - its agent is still answering; tell it once it's done "
      .. "(it can read the plan with get_plan).", vim.log.levels.WARN)
  end
  return true
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
  local rec = M.for_pull_request(a.work_item_ids, a.source)
  if not (rec and rec.allow_push and rec.target and rec.target.work_item_id) then return cb(false) end
  local wi = rec.target.work_item_id
  local _, branch, base = require("azure-cli.chat.tools_fix").find_story(wi)
  local linked = false
  for _, id in ipairs(a.work_item_ids or {}) do if tostring(id) == tostring(wi) then linked = true end end
  if type(rec.pr) == "table" then return cb(false, "the plan for #" .. wi .. " already opened PR !" .. tostring(rec.pr.id)) end
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
-- (the Agents screen shows it, and when it's closed - M.pr_closed).
function M.link_pr(work_item_ids, source, pr)
  local recs, seen = {}, {}
  for _, id in ipairs(work_item_ids or {}) do
    local rec = M.load("wi-" .. tostring(id))
    if rec then recs[#recs + 1] = rec; seen[rec.key] = true end
  end
  local by_branch = M.for_pull_request(nil, source)
  if by_branch and not seen[by_branch.key] then recs[#recs + 1] = by_branch end
  for _, rec in ipairs(recs) do
    rec.pr = { id = pr.id, org = pr.org, project = pr.project }
    rec.pr_state, rec.closed_at = nil, nil
    M.add_event(rec, "pr", "Opened PR !" .. tostring(pr.id))
    VIEW().changed(rec)
  end
end

-- The work item's plan that opened PR `id` (link_pr) while that PR is
-- still open: its agent is the one to fix what reviewers say. A PR opened
-- before plans recorded theirs is found by its `source` branch being the
-- story's. Or nil.
function M.owner_of_pr(id, source)
  for _, f in ipairs(vim.fn.glob(M.root() .. "/wi-*.json", false, true)) do
    local rec = M.load(vim.fn.fnamemodify(f, ":t:r"))
    if rec and type(rec.pr) == "table" and tostring(rec.pr.id) == tostring(id) and not rec.pr_state then return rec end
  end
  local rec = source and source ~= "" and M.for_pull_request(nil, source) or nil
  if rec and rec.pr == nil and not rec.pr_state then return rec end
  return nil
end

-- PR `id` was completed or abandoned (`state`; chat/watch.lua saw it): the
-- plans behind it - the PR's own, and the stories it was opened for - are
-- finished. Returns how many it marked.
function M.pr_closed(id, state)
  local n = 0
  for _, f in ipairs(vim.fn.glob(M.root() .. "/*.json", false, true)) do
    local rec = M.load(vim.fn.fnamemodify(f, ":t:r"))
    if rec and rec.key and not rec.pr_state
        and (rec.key == "pr-" .. tostring(id) or (type(rec.pr) == "table" and tostring(rec.pr.id) == tostring(id))) then
      rec.pr_state, rec.closed_at = state, os.time()
      M.add_event(rec, "closed", "PR !" .. tostring(id) .. (state == "completed" and " was merged" or " was abandoned"))
      VIEW().changed(rec)
      n = n + 1
    end
  end
  return n
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
      run = function(args, env, done)
        local target = target_of(args)
        if not target then return done(nil, "give work_item_id or pr_id") end
        if type(args.markdown) ~= "string" or vim.trim(args.markdown) == "" then return done(nil, "the plan is empty") end
        local key = M.key(target)
        local rec = M.load(key) or { key = key, target = target, revisions = {}, threads = {}, created = os.time() }
        if rec.status == "done" then rec.threads = {} end
        rec.title = args.title
        M.add_revision(rec, args.markdown, "agent")
        M.save(rec)
        -- An agent working in the background (one of several) doesn't pull
        -- you into its plan; it says it's ready instead.
        if env and env.background and env.background() then
          notify("The plan for " .. M.target_label(target) .. " is ready for you - the Agents screen opens it.")
          pcall(function() require("azure-cli.chat").alert("azure-vicli: plan " .. M.target_label(target) .. " is ready",
            tostring(args.title or "") .. " - waiting for your review") end)
          VIEW().show(key, rec)
        else
          M.open(key)
        end
        done({
          shown = true, revision = #rec.revisions, file = M.path(key),
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
          shown = not (env and env.background and env.background()),
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

-- ---------------------------------------------------------------------------
-- The viewer (chat/plan_view.lua): open, refresh, current, open_views,
-- describe, describe_view are this module's too. Loaded now, not on first
-- use: it also watches for the plan files being saved by hand.

for _, name in ipairs({ "open", "refresh", "current", "open_views", "describe", "describe_view" }) do
  M[name] = require("azure-cli.chat.plan_view")[name]
end

return M
