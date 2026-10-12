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

-- Whether shell command `cmd` is the plan's test command (`test_cmd`,
-- test_command's " && "-joined lines) or one of its lines - give or take
-- whitespace and a leading "cd <dir> &&". Pure.
function M.is_test_command(cmd, test_cmd)
  if type(cmd) == "table" then cmd = table.concat(cmd, " ") end
  if type(cmd) ~= "string" or not test_cmd then return false end
  local function norm(s) return vim.trim((s:gsub("%s+", " "))) end
  cmd = norm(cmd):gsub("^cd [^&;]+ ?&& ?", "")
  if cmd == "" then return false end
  if cmd == norm(test_cmd) then return true end
  for part in (test_cmd .. " && "):gmatch("(.-) && ") do
    if norm(part) == cmd then return true end
  end
  return false
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

-- The plan's questions for you: the lines of its Open questions section
-- that ask something (a list entry, or a line ending in "?"), not "None".
-- { { line, text } }. Pure.
function M.open_questions(lines)
  local out, inside, fenced = {}, false, false
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then fenced = not fenced end
    local hashes, title = l:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced then
      inside = #hashes == 2 and title:lower():find("question", 1, true) ~= nil
    elseif inside and not fenced then
      local item = l:match("^%s*[-*+]%s+(.+)$") or l:match("^%s*%d+[.)]%s+(.+)$")
      local text = vim.trim(item or l)
      if text ~= "" and not text:lower():match("^none") and (item or text:match("%?%s*$")) then
        out[#out + 1] = { line = i, text = text }
      end
    end
  end
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
