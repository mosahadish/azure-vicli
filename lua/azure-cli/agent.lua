-- lua/azure-cli/agent.lua: agent actions - commands you configure in
-- setup({agent_actions = {...}}) (Claude Code, the Copilot CLI, codex, a
-- shell script, ...) run headless against a pull request, with what they
-- print kept and shown inside the plugin.
--
-- The plugin ships no actions of its own; docs/agents.md has examples. An
-- action is a command template plus a prompt template. This module fills
-- in their {placeholders}, prepares the job and stores the result:
--
--   1. a workspace: a git worktree of the PR's source branch, kept per PR
--      under stdpath("cache"), so the agent never touches your own checkout
--      (or the clone itself, or nothing - `workspace` in the action);
--   2. a context bundle: pr.json (title, description, branches, reviewers,
--      commits), threads.json (every comment thread, simplified), diff.patch
--      (target...source) and README.md (what these are and the optional
--      suggestions format below) - see M.CONTEXT_README;
--   3. the run: vim.fn.jobstart, stdout/stderr collected, stdin closed (or
--      fed the `stdin` template), killed after `timeout_seconds`;
--   4. the result: stdout is markdown, shown as-is on the reviewer's Agent
--      page and in the dashboard's result float. When it ends with a fenced
--      ```json block holding { "items": [...] }, those items become
--      suggestions anchored on the threads/lines they name (see
--      M.normalize_items) - review/agent.lua shows them inline and turns an
--      accepted one into a batch-review draft.
--
-- Results live under stdpath("data")/azure-cli-agent/<pr id>/<run id>/
-- (result.json plus the context bundle the agent saw), the last
-- M.KEEP_RUNS per PR, so they survive restarting Neovim. A finished run
-- stays "unread" until it's shown, which is what the dashboard's badge and
-- the reviewer's [agent: new result] tag report.
--
-- The pure helpers at the top take no vim at all (tests/test-agent.lua runs
-- them under plain luajit); everything below "Runtime" needs a real Neovim.
local M = {}

M.KEEP_RUNS = 10
M.DEFAULT_TIMEOUT = 1800

-- The README.md written into every context bundle, so a prompt can just
-- say "read {context_dir}/README.md" and a skill can rely on it.
M.CONTEXT_README = [[
# Pull request context (azure-vicli agent action)

This directory was prepared for you by azure-vicli's agent action.

- `pr.json`      the pull request: id, title, description, url, source and
                 target branches, author, reviewers and their votes, build
                 status, the commits (newest first), and `my_name` - the
                 person who started this action.
- `threads.json` every comment thread: `id`, `status` (active, fixed,
                 wontFix, closed, byDesign, pending), `file`/`side`/`line`/
                 `end_line` when it is anchored to code (`side` "R" is the
                 source branch, "L" the target), and its `comments`
                 (`author`, `date`, `content`), oldest first.
- `diff.patch`   `git diff <target>...<source>` - the whole change.

The working directory is a checkout of the source branch (unless the action
says otherwise). Do not push.

## Output

Write your answer to stdout as markdown; it is shown as-is.

To suggest replies or new comments the user can accept with one key, end
your output with a fenced json block:

```json
{
  "summary": "one line, optional",
  "items": [
    { "thread_id": 4711, "verdict": "fix", "note": "why", "reply": "draft reply" },
    { "file": "src/Foo.cs", "line": 42, "comment": "a new comment on that line" },
    { "file": "src/Foo.cs", "comment": "a new comment on the whole file" },
    { "comment": "a new comment on the pull request" }
  ]
}
```

`thread_id` refers to `threads.json`. `line` is a line of the source-branch
file (add `"side": "L"` for the target branch, `"end_line"` for a range).
`verdict` and `note` are free text shown next to the suggestion. Nothing is
posted until the user accepts a suggestion, edits it and submits it.
]]

-- ---------------------------------------------------------------------------
-- Pure helpers (no vim).

-- Replaces every {name} in `template` with vars[name]. An unknown name is
-- left as written, so a literal "{...}" in a prompt survives. `quote`
-- (optional) is applied to each substituted value - the shell-escaping a
-- string `cmd` needs.
function M.expand(template, vars, quote)
  if type(template) ~= "string" then return template end
  return (template:gsub("{([%w_]+)}", function(name)
    local v = vars[name]
    if v == nil then return nil end
    v = tostring(v)
    if quote then v = quote(v) end
    return v
  end))
end

local function str(v)
  if type(v) == "string" then
    local s = v:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
  end
  if type(v) == "number" then return tostring(v) end
  return nil
end

local function num(v)
  local n = tonumber(v)
  if n and n == math.floor(n) and n > 0 then return n end
  return nil
end

-- One suggestion out of the agent's json block, in the shape the rest of
-- the plugin uses, or nil when it names nothing usable:
--   kind      "thread" (a reply to thread_id), "line" (a new comment on
--             file:line), "file" (on the whole file), "pr" (on the pull
--             request) or "note" (nothing to post, just a remark)
--   text      what accepting it drafts: the reply, or the new comment
--   verdict, note, thread_id, file, side ("R"/"L"), line, end_line
-- A few spellings agents tend to reach for are accepted too (threadId,
-- path, body, explanation).
function M.normalize_item(e)
  if type(e) ~= "table" then return nil end
  local it = {
    thread_id = num(e.thread_id or e.threadId or e.thread),
    file = str(e.file or e.path),
    line = num(e.line),
    end_line = num(e.end_line or e.endLine),
    verdict = str(e.verdict or e.label or e.classification),
    note = str(e.note or e.explanation or e.reason or e.summary),
  }
  if it.file then it.file = it.file:gsub("\\", "/"):gsub("^/+", "") end
  local side = type(e.side) == "string" and e.side:lower() or ""
  it.side = (side == "l" or side == "left" or side == "target") and "L" or "R"
  local reply = str(e.reply)
  local comment = str(e.comment or e.body)
  if it.thread_id then
    it.kind, it.text = "thread", reply or comment
  elseif it.file and it.line then
    it.kind, it.text = "line", comment or reply
  elseif it.file then
    it.kind, it.text = "file", comment or reply
  elseif comment or reply then
    it.kind, it.text = "pr", comment or reply
  elseif it.note or it.verdict then
    it.kind = "note"
  else
    return nil
  end
  if it.end_line and it.line and it.end_line <= it.line then it.end_line = nil end
  return it
end

function M.normalize_items(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for _, e in ipairs(list) do
    local it = M.normalize_item(e)
    if it then out[#out + 1] = it end
  end
  return out
end

-- The fenced ```json blocks in `lines`, in order: { first, last, body } with
-- first/last the fence lines themselves (1-based).
function M.json_blocks(lines)
  local blocks, open = {}, nil
  for i, l in ipairs(lines) do
    if not open then
      if l:match("^%s*```%s*[Jj][Ss][Oo][Nn]%s*$") then open = { first = i, body = {} } end
    elseif l:match("^%s*```%s*$") then
      open.last = i
      open.body = table.concat(open.body, "\n")
      blocks[#blocks + 1] = open
      open = nil
    else
      open.body[#open.body + 1] = l
    end
  end
  return blocks
end

local function suggestions_of(decoded)
  if type(decoded) ~= "table" then return nil end
  if type(decoded.items) == "table" then return decoded.items, str(decoded.summary) end
  -- A bare list of items.
  if decoded[1] ~= nil and type(decoded[1]) == "table" then return decoded, nil end
  return nil
end

-- Splits an agent's stdout into { lines, items, summary }: the markdown to
-- show (minus the json block the suggestions came from) and the normalized
-- suggestions. The last ```json block that decodes to { items = [...] }
-- (or a bare list) wins. Output that is nothing but such a JSON document
-- works too, and so does Claude Code's `--output-format json` envelope
-- ({ "result": "<the text>" }), which is unwrapped first. `decode` is
-- vim.json.decode at runtime; injected so this stays testable.
function M.parse_output(text, decode, depth)
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  if (depth or 0) < 1 and (trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[") then
    local ok, decoded = pcall(decode, trimmed)
    if ok and type(decoded) == "table" then
      if type(decoded.result) == "string" and decoded.items == nil then
        return M.parse_output(decoded.result, decode, 1)
      end
      local list, summary = suggestions_of(decoded)
      if list then return { lines = {}, items = M.normalize_items(list), summary = summary } end
    end
  end
  local lines = {}
  for l in (trimmed .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  if trimmed == "" then lines = {} end
  local items, summary = {}, nil
  local blocks = M.json_blocks(lines)
  for i = #blocks, 1, -1 do
    local b = blocks[i]
    local ok, decoded = pcall(decode, b.body)
    local list, s = suggestions_of(ok and decoded or nil)
    if list then
      items, summary = M.normalize_items(list), s
      for _ = b.first, b.last do table.remove(lines, b.first) end
      break
    end
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  while #lines > 0 and lines[1]:match("^%s*$") do table.remove(lines, 1) end
  return { lines = lines, items = items, summary = summary }
end

-- The provider's --threads JSON (decoded) as the plain list threads.json
-- carries: system comments (votes, policy updates) and deleted threads/
-- comments dropped, the code anchor flattened - the same rules
-- review/init.lua's parse_threads applies on screen.
function M.simplify_threads(decoded)
  local out = {}
  local list = type(decoded) == "table" and (decoded.value or decoded) or {}
  if type(list) ~= "table" then return out end
  for _, t in ipairs(list) do
    if type(t) == "table" and t.isDeleted ~= true then
      local comments = {}
      for _, c in ipairs(type(t.comments) == "table" and t.comments or {}) do
        if type(c) == "table" and c.commentType ~= "system" and c.isDeleted ~= true
            and type(c.content) == "string" and c.content:match("%S") then
          comments[#comments + 1] = {
            id = c.id,
            author = type(c.author) == "table" and c.author.displayName or "?",
            date = c.publishedDate or c.lastUpdatedDate,
            content = c.content,
          }
        end
      end
      if #comments > 0 then
        local th = { id = t.id, status = t.status, comments = comments }
        local tc = type(t.threadContext) == "table" and t.threadContext or nil
        if tc and type(tc.filePath) == "string" then
          th.file = tc.filePath:gsub("^/", "")
          local s, e = tc.rightFileStart, tc.rightFileEnd
          th.side = "R"
          if type(s) ~= "table" then s, e, th.side = tc.leftFileStart, tc.leftFileEnd, "L" end
          if type(s) == "table" and s.line then
            th.line = s.line
            if type(e) == "table" and e.line and e.line > s.line then th.end_line = e.line end
          else
            th.side = nil
          end
        end
        out[#out + 1] = th
      end
    end
  end
  return out
end

-- Fills each thread suggestion's location and a short "who said what" from
-- `threads` (M.simplify_threads' shape), so a result can say where a
-- suggestion points even where the live threads aren't loaded (the
-- dashboard's result float).
function M.annotate_items(items, threads)
  local by_id = {}
  for _, t in ipairs(threads or {}) do by_id[tostring(t.id)] = t end
  for _, it in ipairs(items or {}) do
    if it.kind == "thread" then
      local t = by_id[tostring(it.thread_id)]
      if t then
        it.file = it.file or t.file
        it.side = t.side or it.side
        it.line = it.line or t.line
        it.status = t.status
        local first = t.comments[1]
        local excerpt = (first.content or ""):gsub("%s+", " ")
        if #excerpt > 70 then excerpt = excerpt:sub(1, 67) .. "..." end
        it.excerpt = first.author .. ": " .. excerpt
      else
        it.missing = true
      end
    end
  end
  return items
end

-- Where an item points, for a one-line heading: "thread #12 · src/a.cs:4",
-- "src/a.cs:4-9", "src/a.cs (file)", "pull request".
function M.item_location(it)
  local loc
  if it.file then
    loc = it.file
    if it.line then
      loc = loc .. ":" .. it.line .. (it.end_line and ("-" .. it.end_line) or "")
      if it.side == "L" then loc = loc .. " (target)" end
    elseif it.kind == "file" then
      loc = loc .. " (file)"
    end
  end
  if it.kind == "thread" then
    return "thread #" .. tostring(it.thread_id) .. (loc and (" \u{00B7} " .. loc) or "")
  end
  if it.kind == "pr" then return "pull request" end
  if it.kind == "note" then return loc or "note" end
  return loc or "?"
end

-- What accepting an item does, for its heading.
local KIND_LABEL = { thread = "reply", line = "new comment", file = "new file comment", pr = "new PR comment", note = "note" }

local function human_duration(s)
  if not s or s < 0 then return "" end
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m " .. (s % 60) .. "s" end
  return math.floor(s / 3600) .. "h " .. math.floor((s % 3600) / 60) .. "m"
end
M.human_duration = human_duration

-- "done", "failed (exit 2)", "timed out", "cancelled", "running".
function M.status_text(run)
  if run.status == "failed" then return "failed (exit " .. tostring(run.exit) .. ")" end
  if run.status == "timeout" then return "timed out" end
  return run.status or "?"
end

-- The text a run renders as (the reviewer's Agent page and the dashboard's
-- float share it): a heading, the agent's markdown, then a Suggestions
-- section, then stderr when the run failed or printed nothing. Returns
-- lines plus item_at (line -> index into run.items) for the keys that act
-- on "the suggestion under the cursor". `now` is os.time() (injected).
function M.render_lines(run, now)
  local lines, item_at = {}, {}
  local function add(l) lines[#lines + 1] = l end
  add("# " .. (run.label or run.action or "Agent") .. "  \u{00B7}  PR #" .. tostring(run.pr_id))
  local when = run.started and os.date("%Y-%m-%d %H:%M", run.started) or "?"
  local took = (run.finished and run.started) and (" \u{00B7} took " .. human_duration(run.finished - run.started))
    or (run.started and now and (" \u{00B7} " .. human_duration(now - run.started) .. " so far") or "")
  add(M.status_text(run) .. " \u{00B7} " .. when .. took)
  if run.workspace_note then add("(" .. run.workspace_note .. ")") end
  add("")
  if run.status == "running" then
    add("Running in the background - this page fills in when it finishes.")
    return lines, item_at
  end
  if run.summary then
    add("**" .. run.summary .. "**")
    add("")
  end
  for _, l in ipairs(run.lines or {}) do add(l) end
  local items = run.items or {}
  if #items > 0 then
    add("")
    add("## Suggestions (" .. #items .. ")")
    for i, it in ipairs(items) do
      add("")
      local head = "\u{25B8} " .. M.item_location(it)
      if it.verdict then head = head .. "  [" .. it.verdict .. "]" end
      if it.accepted then head = head .. "  \u{2713} drafted" end
      if it.missing then head = head .. "  (thread not found)" end
      add(head)
      item_at[#lines] = i
      if it.excerpt then add("  " .. it.excerpt); item_at[#lines] = i end
      if it.note then
        for nl in (it.note .. "\n"):gmatch("(.-)\n") do add("  " .. nl); item_at[#lines] = i end
      end
      if it.text then
        add("  " .. (KIND_LABEL[it.kind] or "draft") .. ":")
        item_at[#lines] = i
        for tl in (it.text .. "\n"):gmatch("(.-)\n") do add("  > " .. tl); item_at[#lines] = i end
      end
    end
  end
  local stderr = run.stderr or {}
  if #stderr > 0 and (run.status ~= "done" or #(run.lines or {}) == 0) then
    add("")
    add("## stderr")
    for _, l in ipairs(stderr) do add("    " .. l) end
  end
  if #(run.lines or {}) == 0 and #items == 0 and #stderr == 0 then
    add("(the agent printed nothing)")
  end
  return lines, item_at
end

-- The actions to offer for a PR, sorted by label: configured `actions`
-- (name -> spec) filtered by each spec's `when` - nil/"always", "author"
-- (my own PR), "reviewer" (someone else's), or a function(info) -> bool.
-- `info` is { pr, is_author, surface, file, line, thread_id }.
function M.available(actions, info)
  local out = {}
  for name, spec in pairs(actions or {}) do
    local ok = true
    local w = spec.when
    if w == "author" then ok = info.is_author == true
    elseif w == "reviewer" then ok = info.is_author ~= true
    elseif type(w) == "function" then
      local fine, res = pcall(w, info)
      ok = fine and res and true or false
    end
    if ok then out[#out + 1] = { name = name, spec = spec, label = spec.label or name } end
  end
  table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
  return out
end

-- True when `pr` (a --list record) is one I created: the provider files
-- those under "Created"; a record without that (a draft, or one opened by
-- id) falls back to comparing the author with my own name.
function M.is_author(pr)
  if type(pr) ~= "table" then return false end
  if pr.state == "Created" then return true end
  return type(pr.myName) == "string" and pr.myName ~= "" and pr.author == pr.myName
end

-- "<repo>-<id>" made safe for a directory name.
function M.slug(s)
  return (tostring(s or ""):gsub("[^%w%._%-]", "_"))
end

-- ---------------------------------------------------------------------------
-- Runtime.

local function state()
  local STATE = require("azure-cli.state")
  STATE.agent = STATE.agent or { running = {}, runs = {}, listeners = {} }
  return STATE.agent
end

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end

local function data_root() return vim.fn.stdpath("data") .. "/azure-cli-agent" end
local function pr_root(pr_id) return data_root() .. "/" .. M.slug(pr_id) end

local function write_file(path, text)
  local lines = vim.split(text or "", "\n", { plain = true })
  return pcall(vim.fn.writefile, lines, path, "b")
end

local function join_output(chunks)
  -- buffered on_stdout data: a list of lines, with "" artefacts at the end.
  local lines = vim.deepcopy(chunks or {})
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  for i, l in ipairs(lines) do lines[i] = l:gsub("\r$", "") end
  return lines
end

-- Every listener gets (pr_id, run) whenever a run starts, finishes or is
-- marked read. Keyed so a surface that's re-opened replaces its own old
-- listener instead of stacking one per visit.
function M.subscribe(key, fn)
  state().listeners[key] = fn
end
function M.unsubscribe(key)
  state().listeners[key] = nil
end
local function emit(pr_id, run)
  for _, fn in pairs(state().listeners) do
    pcall(fn, tostring(pr_id), run)
  end
end

-- The persisted part of a run - everything but the job bookkeeping.
local PERSIST = {
  "id", "pr_id", "action", "label", "status", "exit", "started", "finished", "read",
  "lines", "items", "summary", "stderr", "workspace", "workspace_note", "dir",
}
function M.save(run)
  if not run.dir then return end
  local rec = {}
  for _, k in ipairs(PERSIST) do rec[k] = run[k] end
  require("azure-cli.shell").write_json(run.dir .. "/result.json", rec)
end

-- Every stored run for `pr_id`, newest first (read from disk once a
-- session, then kept current in memory), with any still-running ones on
-- top.
function M.runs(pr_id)
  pr_id = tostring(pr_id)
  local st = state()
  if not st.runs[pr_id] then
    local list = {}
    for _, dir in ipairs(vim.fn.glob(pr_root(pr_id) .. "/*", false, true)) do
      local rec = require("azure-cli.shell").read_json(dir .. "/result.json", nil)
      if type(rec) == "table" and rec.id then
        rec.dir = dir
        -- Neovim was closed while it ran: it isn't running any more.
        if rec.status == "running" then rec.status = "cancelled" end
        list[#list + 1] = rec
      end
    end
    table.sort(list, function(a, b) return (a.started or 0) > (b.started or 0) end)
    st.runs[pr_id] = list
  end
  return st.runs[pr_id]
end

-- "running" when an action is running for the PR, else "unread" when a
-- finished run hasn't been looked at, else nil.
function M.state(pr_id)
  pr_id = tostring(pr_id)
  local running = state().running[pr_id]
  if running and next(running) then return "running" end
  for _, r in ipairs(M.runs(pr_id)) do
    if r.status ~= "running" and not r.read then return "unread" end
  end
  return nil
end

function M.mark_read(run)
  if run and not run.read and run.status ~= "running" then
    run.read = true
    M.save(run)
    emit(run.pr_id, run)
  end
end

-- The newest finished run for the PR that has suggestions - what the
-- reviewer anchors inline (nil when none).
function M.latest_with_items(pr_id)
  for _, r in ipairs(M.runs(pr_id)) do
    if r.status ~= "running" and r.items and #r.items > 0 then return r end
  end
  return nil
end

local function prune(pr_id)
  local list = M.runs(pr_id)
  local finished = {}
  for _, r in ipairs(list) do
    if r.status ~= "running" then finished[#finished + 1] = r end
  end
  for i = M.KEEP_RUNS + 1, #finished do
    local r = finished[i]
    if r.dir then pcall(vim.fn.delete, r.dir, "rf") end
    for j = #list, 1, -1 do
      if list[j] == r then table.remove(list, j) end
    end
  end
end

-- Runs `argv` (git) and calls cb(ok, stdout_lines, stderr_lines).
local function sh(argv, cb, opts)
  local out, err = {}, {}
  local ok_start, job = pcall(vim.fn.jobstart, argv, vim.tbl_extend("force", {
    stdout_buffered = true, stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      vim.schedule(function() cb(code == 0, join_output(out), join_output(err)) end)
    end,
  }, opts or {}))
  if not ok_start or job <= 0 then
    vim.schedule(function() cb(false, {}, { "could not run " .. tostring(argv[1]) }) end)
  end
end

local function is_repo(path)
  return path and path ~= "" and (vim.fn.isdirectory(path .. "/.git") == 1 or vim.fn.filereadable(path .. "/.git") == 1)
end

-- Gets the action's working directory ready: cb(path, note) or cb(nil, nil,
-- why). "worktree" (the default) is a detached worktree of the PR's
-- source branch, created on first use and moved to the branch's current
-- tip on every later run - unless it has local changes (an agent that
-- edited files), which are left alone and noted instead.
local function prepare_workspace(kind, info, cb)
  if kind == "none" then cb(nil) return end
  local repo = info.repo_path
  if not is_repo(repo) then
    cb(nil, nil, "the PR's repository isn't cloned here (set clones_dir in your account, or open the PR once)")
    return
  end
  if kind == "repo" then cb(repo) return end
  local source = info.source
  if not source or source == "" then cb(nil, nil, "the PR's source branch is unknown") return end
  local ref = "origin/" .. source
  local wt = vim.fn.stdpath("cache") .. "/azure-cli/agent-worktrees/"
    .. M.slug((info.pr.repo or "repo") .. "-" .. tostring(info.pr.id))
  if is_repo(wt) then
    sh({ "git", "-C", wt, "status", "--porcelain" }, function(ok, out)
      if not ok then cb(nil, nil, "git status failed in " .. wt) return end
      if #out > 0 then
        cb(wt, "the worktree has local changes from an earlier run, so it was left as it was: " .. wt)
        return
      end
      sh({ "git", "-C", wt, "checkout", "-q", "--detach", ref }, function(ok2, _, err2)
        if not ok2 then cb(nil, nil, "could not move the worktree to " .. ref .. ": " .. table.concat(err2, " ")) return end
        cb(wt)
      end)
    end)
    return
  end
  vim.fn.mkdir(vim.fn.fnamemodify(wt, ":h"), "p")
  sh({ "git", "-C", repo, "worktree", "prune" }, function()
    sh({ "git", "-C", repo, "worktree", "add", "-q", "--detach", wt, ref }, function(ok, _, err)
      if not ok then cb(nil, nil, "git worktree add failed: " .. table.concat(err, " ")) return end
      cb(wt)
    end)
  end)
end

-- Writes the context bundle into `dir`, then cb(threads) with the
-- simplified threads (for annotating the result later). The diff, the
-- commit log and the threads are fetched in parallel; any of them failing
-- leaves an explanatory placeholder rather than failing the run.
local function build_context(info, dir, cb)
  local pending = 3
  local diff, commits, threads = {}, {}, {}
  local function done()
    pending = pending - 1
    if pending > 0 then return end
    local pr = info.pr or {}
    local reviewers = {}
    for _, r in ipairs(type(pr.reviewers) == "table" and pr.reviewers or {}) do
      reviewers[#reviewers + 1] = { name = r.name, vote = r.vote, required = r.isRequired or r.required }
    end
    local rec = {
      id = tonumber(pr.id) or pr.id, title = pr.title, description = pr.description, url = pr.url,
      org = pr.org, project = pr.project, repo = pr.repo, source = info.source, target = info.target,
      author = pr.author, is_draft = pr.isDraft, reviewers = reviewers, build_status = pr.buildStatus,
      merge_conflict = pr.mergeConflict, my_name = pr.myName, commits = commits,
    }
    write_file(dir .. "/pr.json", vim.json.encode(rec))
    write_file(dir .. "/threads.json", vim.json.encode(threads))
    write_file(dir .. "/diff.patch", table.concat(diff, "\n") .. "\n")
    write_file(dir .. "/README.md", M.CONTEXT_README)
    cb(threads)
  end
  if is_repo(info.repo_path) and info.source ~= "" and info.target ~= "" then
    local range3 = "origin/" .. info.target .. "...origin/" .. info.source
    local range2 = "origin/" .. info.target .. "..origin/" .. info.source
    sh({ "git", "-C", info.repo_path, "diff", range3 }, function(ok, out, err)
      diff = ok and out or { "# git diff " .. range3 .. " failed: " .. table.concat(err, " ") }
      done()
    end)
    sh({ "git", "-C", info.repo_path, "log", "--format=%h  %ad  %an: %s", "--date=short", range2 }, function(ok, out)
      commits = ok and out or {}
      done()
    end)
  else
    diff = { "# the repository isn't cloned here, so there is no diff" }
    pending = pending - 1
    done()
  end
  local raw = {}
  require("azure-cli.rpc").run(require("azure-cli.config").provider_argv("--threads"), {
    env = info.env, stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(raw, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          local ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"),
            { luanil = { object = true, array = true } })
          if ok then threads = M.simplify_threads(decoded) end
        end
        done()
      end)
    end,
  })
end

-- The {placeholder} values an action's cmd/prompt/stdin/env can use.
local function placeholders(info, run, ws)
  local pr = info.pr or {}
  local dir = run.dir
  return {
    pr_id = tostring(pr.id or ""), title = pr.title or "", url = pr.url or "",
    org = pr.org or "", project = pr.project or "", repo = pr.repo or "",
    source = info.source or "", target = info.target or "", author = pr.author or "",
    repo_path = info.repo_path or "", workspace = ws or dir, context_dir = dir,
    pr_file = dir .. "/pr.json", threads_file = dir .. "/threads.json",
    diff_file = dir .. "/diff.patch", readme_file = dir .. "/README.md",
    file = info.file or "", line = info.line and tostring(info.line) or "",
    side = info.side or "", thread_id = info.thread_id and tostring(info.thread_id) or "",
    action = run.action,
  }
end

local function finish(run, info, threads, code, out, err)
  local st = state()
  local running = st.running[run.pr_id]
  if running then running[run.action] = nil end
  if run.timer then pcall(vim.fn.timer_stop, run.timer); run.timer = nil end
  run.finished = os.time()
  run.exit = code
  if run.cancelled then run.status = "cancelled"
  elseif run.timed_out then run.status = "timeout"
  else run.status = (code == 0) and "done" or "failed" end
  local text = table.concat(out, "\n")
  write_file(run.dir .. "/output.md", text)
  if #err > 0 then write_file(run.dir .. "/stderr.txt", table.concat(err, "\n")) end
  local parsed = M.parse_output(text, vim.json.decode)
  run.lines, run.summary = parsed.lines, parsed.summary
  run.items = M.annotate_items(parsed.items, threads)
  local tail = {}
  for i = math.max(1, #err - 59), #err do tail[#tail + 1] = err[i] end
  run.stderr = tail
  run.read = false
  run.job = nil
  M.save(run)
  prune(run.pr_id)
  local n = #run.items
  local what = run.status == "done"
    and ("finished" .. (n > 0 and (" with " .. n .. " suggestion" .. (n == 1 and "" or "s")) or ""))
    or M.status_text(run)
  local hint = (info.result_hint and info.result_hint ~= "") and (" - " .. info.result_hint) or ""
  notify(run.label .. " on PR #" .. run.pr_id .. " " .. what .. hint,
    run.status == "done" and vim.log.levels.INFO or vim.log.levels.WARN)
  require("azure-cli.notify").toast("Agent " .. (run.status == "done" and "finished" or "stopped") .. ": " .. run.label,
    "PR #" .. run.pr_id .. " " .. (info.pr.title or "") .. " - " .. what)
  emit(run.pr_id, run)
end

-- Starts action `name` (spec from setup's agent_actions) for info.pr.
-- `info`: { pr (the PR record), env (AZVICLI_* for the provider - nil in
-- the reviewer, whose process env already carries them), repo_path,
-- source, target, file, line, side, thread_id (the cursor's, where there
-- is one), surface, result_hint (appended to the "finished" message) }.
function M.start(name, spec, info)
  local pr_id = tostring(info.pr.id)
  local st = state()
  st.running[pr_id] = st.running[pr_id] or {}
  if st.running[pr_id][name] then
    notify((spec.label or name) .. " is already running for PR #" .. pr_id .. ".", vim.log.levels.WARN)
    return
  end
  local started = os.time()
  local id = os.date("%Y%m%d-%H%M%S", started) .. "-" .. M.slug(name)
  local dir = pr_root(pr_id) .. "/" .. id
  vim.fn.mkdir(dir, "p")
  local run = {
    id = id, pr_id = pr_id, action = name, label = spec.label or name, status = "running",
    started = started, read = false, dir = dir, items = {}, lines = {}, stderr = {},
  }
  st.running[pr_id][name] = run
  table.insert(M.runs(pr_id), 1, run)
  M.save(run)
  emit(pr_id, run)
  notify("Started " .. run.label .. " on PR #" .. pr_id .. " in the background\u{2026}")

  local function fail(why)
    finish(run, info, {}, -1, {}, { why })
  end

  prepare_workspace(spec.workspace or "worktree", info, function(ws, note, why)
    if why then fail("workspace: " .. why) return end
    run.workspace, run.workspace_note = ws, note
    build_context(info, dir, function(threads)
      if run.cancelled then finish(run, info, threads, -1, {}, {}) return end
      local vars = placeholders(info, run, ws)
      vars.prompt = M.expand(spec.prompt or "", vars)
      local cmd
      if type(spec.cmd) == "table" then
        cmd = {}
        for i, a in ipairs(spec.cmd) do cmd[i] = M.expand(a, vars) end
        -- Windows: jobstart wants the real file for an npm-style .cmd shim.
        local exe = vim.fn.exepath(cmd[1])
        if exe == "" then fail("`" .. cmd[1] .. "` isn't on PATH") return end
        cmd[1] = exe
      else
        cmd = M.expand(spec.cmd, vars, vim.fn.shellescape)
      end
      local env = vim.tbl_extend("force", info.env or {}, {
        AZVICLI_AGENT_CONTEXT = dir, AZVICLI_AGENT_PR_FILE = vars.pr_file,
        AZVICLI_AGENT_THREADS_FILE = vars.threads_file, AZVICLI_AGENT_DIFF_FILE = vars.diff_file,
        AZVICLI_AGENT_WORKSPACE = vars.workspace, AZVICLI_AGENT_FILE = vars.file,
        AZVICLI_AGENT_LINE = vars.line, AZVICLI_AGENT_SIDE = vars.side,
        AZVICLI_AGENT_THREAD = vars.thread_id,
      })
      for k, v in pairs(spec.env or {}) do env[k] = M.expand(tostring(v), vars) end
      local out, err = {}, {}
      local ok_start, job = pcall(vim.fn.jobstart, cmd, {
        cwd = ws or dir, env = env,
        stdout_buffered = true, stderr_buffered = true,
        on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
        on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
        on_exit = function(_, code)
          vim.schedule(function() finish(run, info, threads, code, join_output(out), join_output(err)) end)
        end,
      })
      if not ok_start or job <= 0 then
        fail("could not start " .. (type(cmd) == "table" and cmd[1] or cmd) .. (ok_start and "" or (": " .. tostring(job))))
        return
      end
      run.job = job
      if spec.stdin then pcall(vim.fn.chansend, job, M.expand(spec.stdin, vars)) end
      pcall(vim.fn.chanclose, job, "stdin")
      local timeout = tonumber(spec.timeout_seconds) or M.DEFAULT_TIMEOUT
      run.timer = vim.fn.timer_start(timeout * 1000, function()
        run.timer = nil
        if run.job then
          run.timed_out = true
          pcall(vim.fn.jobstop, run.job)
        end
      end)
    end)
  end)
end

-- Stops a running action (its result is kept, marked cancelled).
function M.cancel(run)
  if not run or run.status ~= "running" then return end
  run.cancelled = true
  if run.job then pcall(vim.fn.jobstop, run.job) end
end

-- The actions configured in setup(), name -> spec.
function M.configured()
  return require("azure-cli.config").get().agent_actions or {}
end

-- gX: the picker. Lists the actions this PR qualifies for, a cancel entry
-- per running one and - when there are results already - a way to them
-- (info.open_results). `prepare(cb)` (optional) runs before starting the
-- chosen action: the dashboard uses it to make sure the clone and the
-- branches are there.
function M.pick(info, prepare)
  local pr_id = tostring(info.pr.id)
  local actions = M.configured()
  if next(actions) == nil then
    notify("No agent actions are configured - add some with setup({ agent_actions = { ... } }); "
      .. "see docs/agents.md for examples.", vim.log.levels.WARN)
    return
  end
  local items = {}
  local running = state().running[pr_id] or {}
  for _, run in pairs(running) do
    items[#items + 1] = { label = "Cancel " .. run.label .. " (running "
      .. human_duration(os.time() - (run.started or os.time())) .. ")", cancel = run }
  end
  for _, a in ipairs(M.available(actions, info)) do
    if not running[a.name] then
      items[#items + 1] = { label = a.label .. (a.spec.description and ("  - " .. a.spec.description) or ""), action = a }
    end
  end
  local runs = M.runs(pr_id)
  if #runs > 0 and info.open_results then
    local unread = 0
    for _, r in ipairs(runs) do if r.status ~= "running" and not r.read then unread = unread + 1 end end
    items[#items + 1] = { label = "Show results (" .. #runs .. (unread > 0 and (", " .. unread .. " new") or "") .. ")", results = true }
  end
  require("azure-cli.prompt").select({ prompt = "Agent action for PR #" .. pr_id, items = items }, function(choice)
    if not choice then return end
    if choice.cancel then
      M.cancel(choice.cancel)
      notify("Cancelling " .. choice.cancel.label .. "\u{2026}")
    elseif choice.results then
      info.open_results()
    elseif choice.action then
      local go = function() M.start(choice.action.name, choice.action.spec, info) end
      if prepare then
        prepare(function(ok) if ok then go() end end)
      else
        go()
      end
    end
  end)
end

-- Lets the user pick one of the PR's runs (newest first), cb(run). Skips
-- the menu when there's only one.
function M.choose_run(pr_id, cb)
  local runs = M.runs(pr_id)
  if #runs == 0 then
    notify("No agent results for PR #" .. tostring(pr_id) .. " yet (gX runs an action).")
    return
  end
  if #runs == 1 then cb(runs[1]) return end
  local items = {}
  for _, r in ipairs(runs) do
    local n = r.items and #r.items or 0
    items[#items + 1] = {
      label = (r.status ~= "running" and not r.read and "\u{25CF} " or "  ") .. r.label .. "  "
        .. os.date("%m-%d %H:%M", r.started or 0) .. "  " .. M.status_text(r)
        .. (n > 0 and ("  " .. n .. " suggestion" .. (n == 1 and "" or "s")) or ""),
      run = r,
    }
  end
  require("azure-cli.prompt").select({ prompt = "Agent results for PR #" .. tostring(pr_id), items = items },
    function(choice) if choice then cb(choice.run) end end)
end

-- Highlights for a rendered run in a markdown buffer: the status line and
-- suggestion headings.
local ns = nil
function M.highlight(buf, lines, item_at)
  ns = ns or vim.api.nvim_create_namespace("azure_cli_agent_page")
  require("azure-cli.ui").link_hl({
    AzureCliAgentStatus = "Comment", AzureCliAgentItem = "Title", AzureCliAgentDraft = "String",
    AzureCliAgentDone = "DiagnosticOk", AzureCliAgentFailed = "ErrorMsg",
  })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if lines[2] then
    local grp = lines[2]:match("^done") and "AzureCliAgentDone"
      or ((lines[2]:match("^failed") or lines[2]:match("^timed out")) and "AzureCliAgentFailed" or "AzureCliAgentStatus")
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, grp, 1, 0, -1)
  end
  for ln, _ in pairs(item_at) do
    local l = lines[ln] or ""
    local grp = l:match("^\u{25B8}") and "AzureCliAgentItem" or (l:match("^  > ") and "AzureCliAgentDraft" or nil)
    if grp then pcall(vim.api.nvim_buf_add_highlight, buf, ns, grp, ln - 1, 0, -1) end
  end
end

-- The dashboard's gz: the run (chosen when there are several) in a big
-- float, marked read. `open_in_reviewer` (optional) is bound to <CR> there.
function M.show_float(pr_id, open_in_reviewer)
  M.choose_run(pr_id, function(run)
    local lines, item_at = M.render_lines(run, os.time())
    local footer = open_in_reviewer and "<CR> open on the reviewer's Agent page" or nil
    local win, buf = require("azure-cli.ui").open_float(lines, { big = true, title = "Agent result", footer = footer })
    if not win then return end
    vim.bo[buf].filetype = "markdown"
    M.highlight(buf, lines, item_at)
    M.mark_read(run)
    if open_in_reviewer then
      vim.keymap.set("n", "<CR>", function()
        pcall(vim.api.nvim_win_close, win, true)
        open_in_reviewer(run)
      end, { buffer = buf, silent = true, nowait = true })
    end
  end)
end

return M
