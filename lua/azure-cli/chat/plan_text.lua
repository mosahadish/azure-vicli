-- lua/azure-cli/chat/plan_text.lua: the pure parts of the agent's plan -
-- reading its markdown (sections, the Files and Test plan sections, open
-- questions), matching a change against it, and writing what goes to the
-- agent (approving, asking for changes), into a PR description and into
-- the run log. chat/plan.lua copies all of it onto itself, so callers and
-- tests keep using require("azure-cli.chat.plan").
local M = {}

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

-- Extensions that make a word without a "/" a file name (B.words isn't).
local EXTS = {}
for e in ([[lua py md json sh bash cmd bat ps1 psm1 txt toml yml yaml ini cfg conf js mjs cjs ts tsx jsx
  cs csproj sln go rs vim html htm css scss xml svg png jpg gif c h cpp hpp java kt rb php sql
  lock env log rst adoc tf proto]]):gmatch("%S+") do EXTS[e] = true end
local BARE = { README = true, LICENSE = true, Makefile = true, Dockerfile = true, CHANGELOG = true }

-- Whether `tok` reads as a file path, not a code word: no call parens,
-- globs, #refs or --flags, and a "/" in it, a known extension or a known
-- extensionless name. Pure.
function M.is_path_like(tok)
  if tok == "" or tok:find("[()*#<>%[%]{}=\"']") or tok:match("^%-") or tok:match("^%.+$") then return false end
  if tok:find("/", 1, true) then return tok:match("[%w_]") ~= nil end
  local ext = tok:match("^[^.].*%.([%w]+)$")
  return (ext and EXTS[ext:lower()]) or BARE[tok] or false
end

-- The path-like words of `text`, split on commas and spaces, each with
-- its backticks, leading "./", trailing punctuation and a trailing line
-- ref (:12, :10-20, :3:5, #L7, #L7-L9) off. A ref's ":" needs digits after
-- it, so a drive letter (C:\x.lua) stays. Pure.
local function path_tokens(text)
  local out = {}
  for tok in text:gsub("`", " "):gmatch("[^,%s]+") do
    tok = tok:gsub("^%./", ""):gsub("[,:;.]+$", "")
    tok = tok:gsub("#L%d+%-?L?%d*$", ""):gsub(":%d+[-:]%d+$", ""):gsub(":%d+$", "")
    if M.is_path_like(tok) then out[#out + 1] = tok end
  end
  return out
end

-- The paths one Files entry (a list item's text) names: the path-like
-- words of its head - the text before its description (" - ", ": ",
-- " — "). A head that names none ("New: ...") gives the whole entry's
-- instead. A line ref on a path (docs/chat.md:692, b.lua#L7) is dropped,
-- so the entry names the file. Pure.
function M.entry_paths(item)
  local head = item
  for _, sep in ipairs({ " - ", " \u{2013} ", " \u{2014} ", ": " }) do
    local at = head:find(sep, 1, true)
    if at then head = head:sub(1, at - 1) end
  end
  local out = path_tokens(head)
  if #out == 0 and head ~= item then out = path_tokens(item) end
  return out
end

-- Each Files entry of the plan: { line, paths } for the list items of a
-- "## ...file..." section, outside ``` fences. Pure.
local function file_entries(lines)
  local out, inside, fenced = {}, false, false
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    local hashes, title = l:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced then
      inside = #hashes == 2 and title:lower():find("file", 1, true) ~= nil
    elseif inside and not fenced then
      local item = l:match("^%s*[-*+]%s+(.+)$")
      if item then out[#out + 1] = { line = i, paths = M.entry_paths(item) } end
    end
  end
  return out
end

-- The paths the plan's Files section lists: every path-like name at the
-- head of each entry (entry_paths). Pure.
function M.planned_files(lines)
  local out = {}
  for _, e in ipairs(file_entries(lines)) do vim.list_extend(out, e.paths) end
  return out
end

local function same_path(a, b)
  a, b = a:gsub("\\", "/"), b:gsub("\\", "/")
  return a == b or a:sub(-#b - 1) == "/" .. b or b:sub(-#a - 1) == "/" .. a
end

-- Whether every one of `paths` (relative to the change's worktree) is one
-- the plan lists, matched as check_files does. Pure.
function M.paths_planned(planned, paths)
  if #paths == 0 then return false end
  for _, c in ipairs(paths) do
    local hit = false
    for _, p in ipairs(planned) do if same_path(c, p) then hit = true end end
    if not hit then return false end
  end
  return true
end

-- The change's files against the plan's: { unplanned = changed paths the
-- plan doesn't list (nor `allowed`, the ones you let the agent change on
-- top of it), missing = planned paths the change doesn't touch - never an
-- allowed one, that was a permission, not a promise }. A planned path
-- matches a changed one when either ends with the other (the plan may
-- say `throttle.py` for src/throttle.py). Pure.
function M.check_files(planned, changed, allowed)
  local out = { unplanned = {}, missing = {} }
  for _, c in ipairs(changed) do
    local hit = false
    for _, p in ipairs(planned) do if same_path(c, p) then hit = true end end
    for _, p in ipairs(allowed or {}) do if same_path(c, p) then hit = true end end
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
  for _, e in ipairs(file_entries(lines)) do
    for _, p in ipairs(e.paths) do if same_path(p, path) then return e.line end end
  end
  return nil
end

-- The (first) path a Files entry on plan line `line` names, or nil. Pure.
function M.file_at_line(lines, line)
  for _, e in ipairs(file_entries(lines)) do
    if e.line == line then return e.paths[1] end
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
-- with " && ". Without one, its inline `code` that starts with a test
-- runner or build tool (`dotnet test`, `npm test`, `pytest -q`, ...),
-- joined the same way. Else nil. Pure.
local SHELL_LANGS = { [""] = true, sh = true, bash = true, shell = true, cmd = true, pwsh = true, powershell = true,
  console = true }
local RUNNERS = { dotnet = true, npm = true, pnpm = true, yarn = true, npx = true, cargo = true, go = true, mvn = true,
  gradle = true, ["./gradlew"] = true, gradlew = true, pytest = true, python = true, python3 = true, py = true,
  make = true, ctest = true, tox = true, nox = true, jest = true, vitest = true, rspec = true, bundle = true,
  ["./run-tests"] = true, ["./build.sh"] = true, ["./test.sh"] = true }
-- Test runners that are a whole command on their own (`pytest`): only
-- these may be given more arguments when the plan's line is one word -
-- a bare `python` or `npx` would let anything through.
local ONE_WORD = { pytest = true, jest = true, vitest = true, rspec = true, ctest = true, tox = true, nox = true,
  make = true, ["./run-tests"] = true, ["./build.sh"] = true, ["./test.sh"] = true }
local function inline_command(lines)
  local inside, fenced, out, seen = false, false, {}, {}
  for _, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    local hashes, title = l:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced then
      inside = #hashes == 2 and title:lower():find("test", 1, true) ~= nil
    elseif inside and not fenced then
      for code in l:gmatch("`([^`]+)`") do
        code = vim.trim(code)
        local first = code:match("^(%S+)") or ""
        if RUNNERS[first] and (code:find(" ", 1, true) or ONE_WORD[first]) and not code:find("[|&;<>$(){}]")
            and not seen[code] then
          seen[code] = true
          out[#out + 1] = code
        end
      end
    end
  end
  return #out > 0 and table.concat(out, " && ") or nil
end
local function fenced_command(lines)
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
function M.test_command(lines)
  return fenced_command(lines) or inline_command(lines)
end

-- The steps that go with a test runner: building and restoring the same
-- way runs the same code the tests do. tool -> the subcommands allowed
-- (with any arguments) when the plan's test command uses that tool.
local COMPANIONS = {
  dotnet = { "build", "restore", "test" }, npm = { "ci", "install", "test", "run build", "run test" },
  pnpm = { "install", "test", "run build", "run test" }, yarn = { "install", "test", "build", "run build", "run test" },
  cargo = { "build", "check", "test" }, go = { "build", "vet", "test" }, mvn = { "compile", "test", "verify" },
  gradle = { "build", "test" }, ["./gradlew"] = { "build", "test" }, ["gradlew"] = { "build", "test" },
}

-- Whether shell command `cmd` runs the plan's tests (`test_cmd`,
-- test_command's " && "-joined lines). Each step of `cmd` (split on &&
-- and ;) has to be one of its lines - or one with more arguments, or the
-- same tool's build/restore (COMPANIONS) - optionally piped into commands
-- that only look (`| tail -50`, `| Select-Object -Last 50`) and with
-- 2>&1; a leading cd / Set-Location / pushd into a directory is dropped.
-- Nothing else - no redirect into a file, no $(...), no other program.
-- Pure.
function M.is_test_command(cmd, test_cmd)
  if type(cmd) == "table" then cmd = table.concat(cmd, " ") end
  if type(cmd) ~= "string" or not test_cmd then return false end
  local function norm(s) return vim.trim((s:gsub("%s+", " "))) end
  local lines = {}
  for part in (test_cmd .. " && "):gmatch("(.-) && ") do
    if norm(part) ~= "" then lines[#lines + 1] = norm(part) end
  end
  local function extra_ok(rest)
    return rest == "" or (rest:sub(1, 1) == " " and not rest:find("[|&;<>`$(){}]"))
  end
  local function runs_tests(step)
    for _, l in ipairs(lines) do
      if step == l then return true end
      if (l:find(" ", 1, true) or ONE_WORD[l]) and step:sub(1, #l) == l and extra_ok(step:sub(#l + 1)) then
        return true
      end
      local tool = l:match("^(%S+)")
      for _, sub in ipairs(COMPANIONS[tool] or {}) do
        local head = tool .. " " .. sub
        if step:sub(1, #head) == head and extra_ok(step:sub(#head + 1)) then return true end
      end
    end
    return false
  end
  cmd = norm(cmd):gsub(" 2>&1", "")
  if cmd == "" or cmd:find("||", 1, true) then return false end
  local steps = {}
  for step in (cmd:gsub(" ?&& ?", ";") .. ";"):gmatch("(.-);") do
    step = norm(step)
    if step ~= "" then steps[#steps + 1] = step end
  end
  if #steps == 0 then return false end
  local CORE = require("azure-cli.chat.core")
  for i, step in ipairs(steps) do
    local lower = step:lower()
    local dir_change = i < #steps and (lower:match("^cd ") or lower:match("^set%-location ") or lower:match("^sl ")
      or lower:match("^pushd ")) and not step:find("[|&<>`$(){}]")
    if not dir_change then
      local first, piped = step:match("^([^|]-) ?| ?(.+)$")
      if not first then first = step end
      if not runs_tests(norm(first)) then return false end
      if piped and not CORE.look_only_command(piped) then return false end
    end
  end
  return true
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
  -- Its PR merged or abandoned (plan.pr_closed): finished, whatever it was.
  if rec.pr_state == "completed" then return "\u{2713} Finished: PR merged", "AzureCliStatusDone" end
  if rec.pr_state == "abandoned" then return "\u{2717} Finished: PR abandoned", "AzureCliMuted" end
  local s = STATUS[rec.status] or STATUS.draft
  return s[1], s[2]
end

local function last_rev(rec) return rec.revisions[#rec.revisions] end

-- The plan's questions for you: the lines of its Open questions section
-- that ask something (a list entry, or a line ending in "?"), not "None".
-- A lead-in that isn't about questions - a "###" heading, a line ending
-- in ":" or one in bold, like "Follow-ups, out of scope:" - ends them (one
-- that is starts them again), and entries that say they're a follow-up
-- or out of scope don't count. { { line, text } }. Pure.
function M.open_questions(lines)
  local out, inside, fenced, asking = {}, false, false, true
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    local hashes, title = l:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced and #hashes <= 2 then
      inside, asking = #hashes == 2 and title:lower():find("question", 1, true) ~= nil, true
    elseif inside and not fenced then
      local item = l:match("^%s*[-*+]%s+(.+)$") or l:match("^%s*%d+[.)]%s+(.+)$")
      local text = vim.trim(item or l)
      local low = text:lower()
      if not item and text ~= "" and (hashes or text:match(":%**$") or text:match("^%*%*.*%*%*$")) then
        asking = low:find("question", 1, true) ~= nil
      elseif asking and text ~= "" and not low:match("^none") and (item or text:match("%?%s*$"))
        and not low:gsub("^[%*_]+", ""):match("^follow.?ups?[%s:,]") and not low:gsub("^[%*_]+", ""):match("^out of scope") then
        out[#out + 1] = { line = i, text = text }
      end
    end
  end
  return out
end

-- The plan's open questions (`lines`), each with your answer to it - the
-- thread of kind "answer" on its line in `threads` - or none:
-- { { line, text, answer = thread|nil } }. Pure.
function M.question_status(lines, threads)
  local answers = {}
  for _, th in ipairs(threads or {}) do if th.kind == "answer" then answers[th.line] = th end end
  local out = M.open_questions(lines)
  for _, q in ipairs(out) do q.answer = answers[q.line] end
  return out
end

-- How many of the plan's open questions (`lines`) have no answer of yours
-- (a thread of kind "answer" on their line) in `threads`. Pure.
function M.unanswered(lines, threads)
  local n = 0
  for _, q in ipairs(M.question_status(lines, threads)) do if not q.answer then n = n + 1 end end
  return n
end

-- How many of your answers to the plan's open questions (`lines`) haven't
-- gone to the agent yet - neither with a change request (gR) nor with the
-- approval. One on a line that's no longer a question doesn't count. Pure.
function M.unsent_answers(lines, threads)
  local n = 0
  for _, q in ipairs(M.question_status(lines, threads)) do
    if q.answer and q.answer.status ~= "sent" then n = n + 1 end
  end
  return n
end

-- Where ]t / [t stop in the plan (`lines`): every open question, answered
-- or not, and every thread's line, sorted, each once; a thread past the
-- end is left out. Pure.
function M.jump_stops(lines, threads)
  local seen, out = {}, {}
  local function add(l)
    if l and l >= 1 and l <= #lines and not seen[l] then seen[l] = true out[#out + 1] = l end
  end
  for _, q in ipairs(M.open_questions(lines)) do add(q.line) end
  for _, th in ipairs(threads or {}) do add(th.line) end
  table.sort(out)
  return out
end

-- Your answers (threads of kind "answer") as lines for a message: "- <the
-- question>: <your answer>", in plan order. Pure.
function M.answers_block(rec, lines)
  local out = {}
  local answers = {}
  for _, th in ipairs(rec.threads or {}) do
    if th.kind == "answer" then answers[#answers + 1] = th end
  end
  table.sort(answers, function(a, b) return a.line < b.line end)
  for _, a in ipairs(answers) do
    local q = vim.trim((lines and lines[a.line]) or a.anchor or ""):gsub("^[-*+]%s+", "")
    out[#out + 1] = "- " .. q .. " " .. a.question
  end
  return out
end

-- What approving sends the agent: the go-ahead, your answers to its open
-- questions, and your version of the plan if you edited it. Pure.
function M.approval_message(rec, lines)
  local label = M.target_label(rec.target)
  local rev = last_rev(rec)
  local text = "I approve the plan for " .. label .. " (revision " .. #rec.revisions .. "). Go ahead and make the "
    .. "change as planned, then show_fix it to me - with `steps` tying the parts of the change to the plan lines "
    .. "they carry out."
  if rec.allow_push then
    local id = rec.target.work_item_id and ("work_item_id " .. rec.target.work_item_id) or ("pr_id " .. tostring(rec.target.pr_id))
    text = text .. "\n\nYou may push without waiting for me: after show_fix, "
      .. (M.test_command(lines) and ("run the plan's tests with run_tests (only run_tests counts - not your own "
        .. "shell), fix the change until they pass, then ") or "")
      .. "call commit_and_push_fix (" .. id .. ") - it won't ask."
      .. (rec.target.work_item_id and (" Then open its pull request with create_pull_request (source your story "
        .. "branch, target the branch you started from, work_item_ids [" .. rec.target.work_item_id .. "], no "
        .. "description - the plan's is used - and not a draft); it won't ask either.") or "")
      .. " If the tests keep failing, stop and tell me what's wrong instead of pushing."
  end
  local answers = M.answers_block(rec, lines)
  if #answers > 0 then
    text = text .. "\n\nMy answers to your open questions:\n" .. table.concat(answers, "\n")
  end
  if rev and rev.by == "you" then
    text = text .. "\n\nI edited the plan before approving - follow this version:\n\n" .. rev.markdown
  end
  return text
end

-- What asking for changes sends the agent: `feedback`, the changes asked
-- for on lines of the plan (`requests`: threads of kind "request" - {
-- line, section, anchor, question }), and your answers to its open
-- questions (`lines` = the plan's text, for them). Pure.
function M.revise_message(rec, feedback, requests, lines)
  local parts = { "Please revise the plan for " .. M.target_label(rec.target) .. ": " .. feedback }
  local answers = M.answers_block(rec, lines)
  if #answers > 0 then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "My answers to your open questions:"
    vim.list_extend(parts, answers)
  end
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

-- The text under heading `title` (any level 2 heading containing it,
-- case ignored), up to the next heading at that level or above. Pure.
function M.section_text(lines, title)
  local out, inside, fenced = {}, false, false
  for _, l in ipairs(lines) do
    local fence = l:match("^%s*```")
    local hashes, t = l:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced and #hashes <= 2 then
      if inside then break end
      inside = #hashes == 2 and t:lower():find(title:lower(), 1, true) ~= nil
    elseif inside then
      out[#out + 1] = l
    end
    if fence then fenced = not fenced end
  end
  while #out > 0 and vim.trim(out[1]) == "" do table.remove(out, 1) end
  while #out > 0 and vim.trim(out[#out]) == "" do table.remove(out) end
  return out
end

-- A pull request's description from the plan behind it: its Goal,
-- Approach, Risks and Test plan, and a line saying where it came from.
-- Pure.
M.PR_SECTIONS = { "Goal", "Approach", "Risks", "Test plan" }
function M.pr_description(rec, lines)
  local out = {}
  for _, s in ipairs(M.PR_SECTIONS) do
    local body = M.section_text(lines, s)
    if #body > 0 then
      if #out > 0 then out[#out + 1] = "" end
      out[#out + 1] = "## " .. s
      vim.list_extend(out, body)
    end
  end
  local q = 0
  for _, th in ipairs(rec.threads or {}) do if th.kind ~= "request" and th.answer then q = q + 1 end end
  out[#out + 1] = ""
  out[#out + 1] = "_From the plan for " .. M.target_label(rec.target) .. " (revision " .. #(rec.revisions or {})
    .. (q > 0 and (", " .. q .. " question" .. (q == 1 and "" or "s") .. " answered") or "") .. ")._"
  return table.concat(out, "\n")
end

-- The run log: everything that happened to a plan and its change, as
-- markdown (gH in the plan opens it). `o` = { threads = the change
-- viewer's questions and requests, tests = the last test run, audit = the
-- agent's tool calls for this PR / work item (store.audit's), lines = the
-- plan as it is now }. Pure (`date` formats a timestamp).
function M.run_log(rec, o, date)
  o = o or {}
  date = date or function(ts) return tostring(ts) end
  local out = { "# Run log: " .. M.target_label(rec.target) .. " " .. tostring(rec.title or ""), "" }
  local st = M.status_label(rec)
  out[#out + 1] = "Status: " .. st:gsub("^%S+ ", "") .. (rec.allow_push and " (pushing allowed)" or "") .. " · "
    .. #rec.revisions .. " revision" .. (#rec.revisions == 1 and "" or "s")
  out[#out + 1] = ""
  -- One timeline: the plan's events, the questions, the agent's tool calls.
  local tl = {}
  for _, e in ipairs(rec.events or {}) do tl[#tl + 1] = { at = e.at or 0, text = e.text } end
  local function q_items(list, where)
    for _, th in ipairs(list or {}) do
      if th.kind == "request" then
        tl[#tl + 1] = { at = th.at or 0, text = "You asked for a change on " .. where(th) .. ": " .. tostring(th.question) }
      else
        tl[#tl + 1] = { at = th.at or 0, text = "You asked about " .. where(th) .. ": " .. tostring(th.question) }
      end
    end
  end
  q_items(rec.threads, function(th) return "plan line " .. tostring(th.line) end)
  q_items(o.threads, function(th) return tostring(th.file) .. ":" .. tostring(th.line) end)
  for _, a in ipairs(o.audit or {}) do
    tl[#tl + 1] = { at = a.at or 0, text = "Agent: " .. tostring(a.tool) .. (a.summary and (" - " .. a.summary) or "") }
  end
  table.sort(tl, function(a, b) return a.at < b.at end)
  out[#out + 1] = "## Timeline"
  out[#out + 1] = ""
  for _, x in ipairs(tl) do out[#out + 1] = "- " .. date(x.at) .. "  " .. x.text end
  if #tl == 0 then out[#out + 1] = "- (nothing yet)" end
  local function qa(list, where)
    local any = false
    for _, th in ipairs(list or {}) do
      if th.kind ~= "request" then
        if not any then out[#out + 1] = "" any = true end
        out[#out + 1] = "### " .. where(th) .. ": " .. tostring(th.question)
        out[#out + 1] = ""
        if th.anchor and th.anchor ~= "" then out[#out + 1] = "> " .. th.anchor out[#out + 1] = "" end
        for l in ((th.answer or ("(" .. tostring(th.status) .. ")")) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = l end
      end
    end
    return any
  end
  out[#out + 1] = ""
  out[#out + 1] = "## Questions"
  local any = qa(rec.threads, function(th) return "Plan line " .. tostring(th.line) end)
  any = qa(o.threads, function(th) return tostring(th.file) .. ":" .. tostring(th.line) end) or any
  if not any then out[#out + 1] = "" out[#out + 1] = "(none)" end
  if o.tests then
    out[#out + 1] = ""
    out[#out + 1] = "## Last test run"
    out[#out + 1] = ""
    out[#out + 1] = "`" .. tostring(o.tests.cmd) .. "` - exit " .. tostring(o.tests.code) .. ", " .. date(o.tests.at or 0)
    out[#out + 1] = ""
    out[#out + 1] = "```"
    local tail = o.tests.output or {}
    for i = math.max(1, #tail - 30), #tail do out[#out + 1] = tail[i] end
    out[#out + 1] = "```"
  end
  out[#out + 1] = ""
  out[#out + 1] = "## The plan (as it is now)"
  out[#out + 1] = ""
  for _, l in ipairs(o.lines or {}) do
    -- One level down, so its headings sit under this one.
    out[#out + 1] = l:match("^#") and ("#" .. l) or l
  end
  return out
end

return M
