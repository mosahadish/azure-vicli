-- lua/azure-cli/chat/repo_notes.lua: what agents learned about a
-- repository (its default branch, which files are CRLF, how its tests
-- run), so the next agent doesn't find it out again. One markdown file per
-- repository under stdpath("data")/azure-cli-chat/repo-notes/, a "- " line
-- per note; the user edits it by hand too (gn on the Agents screen), so
-- reading takes any "- " or "* " line and skips the rest.
--
-- A repository is { host, org, owner, name }: on GitHub owner/name; on
-- Azure the org (its URL's last part), the project as owner, and the repo.
-- Its file is <host>~[<org>~]<owner>~<name>.md, each part lowercased and
-- %-escaped outside [%w._-], so no two repositories share one.
--
--   M.of_pr(pr) / M.of_item(item) / M.of_snap(snap) / M.of_target(target)
--                          the repository of a PR record, a GitHub issue, a
--                          chat view, an agent's plan target (or nil)
--   M.locate(repo, host)   the repository a tool's `repo` names, or nil, err
--   M.path(r)              its notes file
--   M.read(r)              its notes, oldest first
--   M.add(r, note)         appends one: the note, or nil, why not
--   M.remove(r, note)      drops one: the note it dropped, or nil, why not
--   M.block(label, notes)  the text agents get - the last M.KEEP notes, at
--                          most M.MAX_BYTES (pure)
--   M.once(conv, r)        that text, the first time conversation `conv`'s
--                          agent process asks (nil after, and when empty)
--   M.tools(T)             remember and forget
local M = {}

M.KEEP = 40
M.MAX_BYTES = 4000
M.NOTE_MAX = 300

local function STATE() return require("azure-cli.state") end

local function enc(s)
  return (tostring(s or ""):lower():gsub("[^%w._-]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- "https://dev.azure.com/x/" -> "x"; a collection URL -> its collection.
local function org_name(url)
  return (tostring(url or ""):gsub("/+$", ""):match("([^/]+)$")) or ""
end

function M.key(r)
  if r.host == "github" then return "github~" .. enc(r.owner) .. "~" .. enc(r.name) end
  return "azure~" .. enc(org_name(r.org)) .. "~" .. enc(r.owner) .. "~" .. enc(r.name)
end

function M.label(r) return (r.owner ~= "" and (r.owner .. "/") or "") .. r.name end

local function dir() return require("azure-cli.chat.store").root() .. "/repo-notes" end
function M.path(r) return dir() .. "/" .. M.key(r) .. ".md" end

-- The PRs the plugin knows: the dashboard's, the reviewer's, get_pull_request's.
local function known_prs()
  local out = {}
  for _, p in ipairs((STATE().PR_LIST_CACHE or {}).prs or {}) do out[#out + 1] = p end
  if type(STATE().PR_CURRENT) == "table" then out[#out + 1] = STATE().PR_CURRENT end
  for _, p in pairs(require("azure-cli.chat.tools").fetched) do out[#out + 1] = p end
  return out
end

-- An Azure project's org: a PR's from that project, else the work-item account's.
local function azure_org(project)
  for _, p in ipairs(known_prs()) do
    if require("azure-cli.hosts").host(p) == "azure" and p.project == project and (p.org or "") ~= "" then return p.org end
  end
  return vim.env.AZVICLI_WI_COLLECTION or ""
end

function M.of_pr(pr)
  if type(pr) ~= "table" or (pr.repo or "") == "" then return nil end
  if require("azure-cli.hosts").host(pr) == "github" then
    local owner = tostring(pr.key or ""):match("^(.-)~.-~%d+$") or pr.project or ""
    return { host = "github", owner = owner, name = pr.repo }
  end
  local org = (pr.org or "") ~= "" and pr.org or azure_org(pr.project)
  return { host = "azure", org = org, owner = pr.project or "", name = pr.repo }
end

-- A GitHub issue (its key is owner~repo~n); an Azure work item has no repository.
function M.of_item(item)
  if type(item) ~= "table" or item.board ~= "github" then return nil end
  local owner, name = tostring(item.key or ""):match("^(.-)~(.-)~%d+$")
  if not owner then return nil end
  return { host = "github", owner = owner, name = name }
end

-- The repository in chat view `snap`: its PR's (the full record when one
-- is known - a describer's copy may leave fields out), else its issue's.
function M.of_snap(snap)
  if type(snap) ~= "table" then return nil end
  if type(snap.pr) == "table" then
    local full = require("azure-cli.chat.tools").pr_record(snap.pr.key or snap.pr.id)
    return M.of_pr(full or snap.pr)
  end
  local wi = snap.work_item
  if type(wi) == "table" and (wi.board or snap.board) == "github" then
    return M.of_item(vim.tbl_extend("force", wi, { board = "github" }))
  end
end

-- The repository an agent's plan target works in: its PR's (the one it
-- fixes or opened), its issue's, else its story worktree's <repo>-wi<n> /
-- <repo>-task<n>.
function M.of_target(target)
  if type(target) ~= "table" then return nil end
  local T = require("azure-cli.chat.tools")
  local PLAN = require("azure-cli.chat.plan")
  local rec = PLAN.load(PLAN.key(target))
  local pr = rec and type(rec.pr) == "table" and (T.pr_record(rec.pr.key or rec.pr.id) or rec.pr) or nil
  if not pr and (target.pr_key or target.pr_id) then pr = T.pr_record(target.pr_key or target.pr_id) end
  if pr then return M.of_pr(pr) end
  if target.item_key then return M.of_item({ board = "github", key = target.item_key }) end
  local d = require("azure-cli.chat.tools_fix").dir_for(target)
  local name = d and vim.fn.fnamemodify(d, ":t"):match("^(.-)%-wi%d+$") or d and vim.fn.fnamemodify(d, ":t"):match("^(.-)%-task%d+$")
  return name and M.locate(name) or nil
end

-- What a tool's `repo` (name, or owner/name) means: a known PR's
-- repository by that name first; else, on `host`'s board (default Azure's),
-- the issues account's owner or the work-item project.
function M.locate(repo, host)
  repo = vim.trim(tostring(repo or ""))
  if repo == "" then return nil, "give repo" end
  local owner, name = repo:match("^([^/]+)/(.+)$")
  name = name or repo
  local lname = name:lower()
  for _, p in ipairs(known_prs()) do
    local r = M.of_pr(p)
    if r and r.name:lower() == lname and (not owner or r.owner:lower() == owner:lower())
        and (not host or r.host == host) then
      return r
    end
  end
  if host == "github" then
    owner = owner or require("azure-cli.workitems.board").issues_account().owner
    if not owner or owner == "" then return nil, "give repo as owner/repo" end
    return { host = "github", owner = owner, name = name }
  end
  owner = owner or vim.env.AZVICLI_WI_PROJECT
  if not owner or owner == "" then return nil, "give repo as project/repo" end
  return { host = "azure", org = azure_org(owner), owner = owner, name = name }
end

local function squash(s) return vim.trim((tostring(s or ""):gsub("%s+", " "))) end

-- The file's lines, CRs dropped, and whether it has CRLF endings: written
-- back as the user's editor left it.
local function lines_of(r)
  local ok, lines = pcall(vim.fn.readfile, M.path(r), "b")
  if not ok then return {}, false end
  local crlf = lines[1] ~= nil and lines[1]:sub(-1) == "\r"
  if lines[#lines] == "" then lines[#lines] = nil end
  for i, l in ipairs(lines) do lines[i] = l:gsub("\r$", "") end
  return lines, crlf
end

-- A file line's note, or nil (a heading, a blank, anything else the user wrote).
local function note_of(line)
  local n = tostring(line):match("^%s*[-*]%s+(.-)%s*$")
  return (n and n ~= "") and n or nil
end

function M.read(r)
  local out = {}
  for _, l in ipairs(lines_of(r)) do out[#out + 1] = note_of(l) end
  return out
end

local function write(r, lines, crlf)
  vim.fn.mkdir(dir(), "p")
  if crlf then lines = vim.tbl_map(function(l) return l .. "\r" end, lines) end
  vim.fn.writefile(lines, M.path(r))
end

function M.add(r, note)
  note = squash(note):gsub("^[-*]%s+", "")
  if note == "" then return nil, "the note is empty" end
  if #note > M.NOTE_MAX then return nil, "keep a note to one short fact (under " .. M.NOTE_MAX .. " characters)" end
  local lines, crlf = lines_of(r)
  for _, l in ipairs(lines) do
    if note_of(l) and squash(note_of(l)):lower() == note:lower() then return nil, "already noted" end
  end
  if #lines == 0 then lines = { "# " .. M.label(r), "" } end
  lines[#lines + 1] = "- " .. note
  write(r, lines, crlf)
  return note
end

-- The note equal to `note` (spaces and case aside), else the one note
-- containing it.
function M.remove(r, note)
  local want = squash(note):gsub("^[-*]%s+", ""):lower()
  if want == "" then return nil, "give the note to drop" end
  local lines, crlf = lines_of(r)
  local at, found = nil, 0
  for i, l in ipairs(lines) do
    local n = note_of(l)
    if n and squash(n):lower() == want then at, found = i, 1 break end
    if n and squash(n):lower():find(want, 1, true) then at, found = i, found + 1 end
  end
  if found == 0 then return nil, "no such note on " .. M.label(r) end
  if found > 1 then return nil, found .. " notes on " .. M.label(r) .. " contain that - give the whole note" end
  local gone = note_of(lines[at])
  table.remove(lines, at)
  write(r, lines, crlf)
  return gone
end

function M.block(label, notes)
  local keep, size = {}, 0
  for i = #notes, math.max(1, #notes - M.KEEP + 1), -1 do
    size = size + #notes[i] + 3
    if size > M.MAX_BYTES then break end
    table.insert(keep, 1, "- " .. notes[i])
  end
  if #keep == 0 then return nil end
  return "Notes on " .. label .. " from earlier agents:\n" .. table.concat(keep, "\n")
end

-- conv.repo_notes_sent: the repositories whose notes its agent process has
-- (chat/run.lua forgets them when a new process starts).
function M.once(conv, r)
  if not r then return nil end
  local key = M.key(r)
  if conv and conv.repo_notes_sent and conv.repo_notes_sent[key] then return nil end
  local text = M.block(M.label(r), M.read(r))
  if text and conv then
    conv.repo_notes_sent = conv.repo_notes_sent or {}
    conv.repo_notes_sent[key] = true
  end
  return text
end

-- `done` for a tool that opens repository `repo` (start_story): its answer
-- (a table) gets the repository's notes, once.
function M.with_notes(done, conv, repo, host)
  return function(result, err, undo)
    if type(result) == "table" and not err then
      local ok, text = pcall(function() return M.once(conv, (M.locate(repo, host))) end)
      if ok and text then result.repo_notes = text end
    end
    return done(result, err, undo)
  end
end

function M.tools(T)
  local function where(args, env)
    return M.locate(args.repo, T.board_for(args, env).host == "github" and "github" or nil)
  end
  local props = {
    repo = { type = "string", description = "repository name (owner/repo on GitHub, project/repo on Azure DevOps "
      .. "also works)" },
    note = { type = "string" },
    board = T.board_props.board,
  }
  return {
    {
      name = "remember",
      description = "Saves one short, lasting fact about a repository that a later agent would need (its default "
        .. "branch, which files are CRLF, how its tests are run) - every agent started on that repository gets "
        .. "its notes. Not for what's only true of this change. Runs without asking.",
      schema = { type = "object", properties = props, required = { "repo", "note" } },
      risk = "write",
      run = function(args, env, done)
        local r, err = where(args, env)
        if not r then return done(nil, err) end
        local note, why = M.add(r, args.note)
        if not note then return done(nil, why) end
        done("Noted on " .. M.label(r) .. ".", nil, { op = "forget_note", repo = r, note = note })
      end,
    },
    {
      name = "forget",
      description = "Drops a note on a repository (remember's) that is no longer true: `note` is its text, or a "
        .. "part only it contains. Runs without asking.",
      schema = { type = "object", properties = props, required = { "repo", "note" } },
      risk = "write",
      run = function(args, env, done)
        local r, err = where(args, env)
        if not r then return done(nil, err) end
        local gone, why = M.remove(r, args.note)
        if not gone then return done(nil, why) end
        done("Dropped from " .. M.label(r) .. "'s notes: " .. gone, nil, { op = "remember_note", repo = r, note = gone })
      end,
    },
  }
end

return M
