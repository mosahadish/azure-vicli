-- test-agent.lua: unit tests for lua/azure-cli/agent.lua's pure helpers
-- (placeholder expansion, parsing an agent's output into markdown +
-- suggestions, simplifying the provider's thread JSON, annotating
-- suggestions with their threads, rendering a result, picking the actions a
-- PR qualifies for) and review/agent.lua's M.virt_lines - under plain
-- luajit, with a small JSON decoder standing in for vim.json.decode.
--
-- Usage: luajit test-agent.lua <agent.lua path> <review/agent.lua path>

local path, review_path = arg[1], arg[2]
assert(path and review_path, "usage: luajit test-agent.lua <agent.lua> <review/agent.lua>")
local M = dofile(path)
local R = dofile(review_path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- A minimal JSON decoder (objects, arrays, strings with the common
-- escapes, numbers, true/false/null) - errors on anything malformed, like
-- vim.json.decode does.
local function decode(s)
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local value
  local function str()
    local out = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == "" then error("unterminated string") end
      if c == '"' then i = i + 1 return table.concat(out) end
      if c == "\\" then
        local e = s:sub(i + 1, i + 1)
        out[#out + 1] = ({ n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" })[e] or e
        i = i + 2
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  value = function()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}
      i = i + 1
      ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        ws()
        if s:sub(i, i) ~= '"' then error("expected key at " .. i) end
        local k = str()
        ws()
        if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
        i = i + 1
        t[k] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "}" then return t end
        if d ~= "," then error("expected , at " .. i) end
      end
    elseif c == "[" then
      local t = {}
      i = i + 1
      ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "]" then return t end
        if d ~= "," then error("expected , in array at " .. i) end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
    else
      local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      if not n or n == "" then error("unexpected '" .. c .. "' at " .. i) end
      i = i + #n
      return tonumber(n)
    end
  end
  local v = value()
  ws()
  if i <= #s then error("trailing data at " .. i) end
  return v
end

-- --- expand ---------------------------------------------------------------

do
  local vars = { pr_id = "42", prompt = "say \"hi\"", file = "" }
  check("expand: substitutes", M.expand("/triage {pr_id}", vars) == "/triage 42")
  check("expand: unknown names stay", M.expand("{nope} {pr_id}", vars) == "{nope} 42")
  check("expand: empty value", M.expand("[{file}]", vars) == "[]")
  check("expand: % in a value is literal", M.expand("{x}", { x = "100%" }) == "100%")
  check("expand: quote applied per value",
    M.expand("run {prompt}", vars, function(v) return "'" .. v .. "'" end) == "run 'say \"hi\"'")
  check("expand: non-string passes through", M.expand(nil, vars) == nil)
end

-- --- normalize_item -------------------------------------------------------

do
  local t = M.normalize_item({ thread_id = 7, verdict = "fix", note = "n", reply = "r" })
  check("item: thread reply", t.kind == "thread" and t.thread_id == 7 and t.text == "r" and t.verdict == "fix")
  local t2 = M.normalize_item({ threadId = "8", comment = "c" })
  check("item: threadId spelling, comment as reply", t2.kind == "thread" and t2.thread_id == 8 and t2.text == "c")
  local l = M.normalize_item({ path = "/src\\a.cs", line = 4, end_line = 6, comment = "x" })
  check("item: line, path normalised", l.kind == "line" and l.file == "src/a.cs" and l.line == 4
    and l.end_line == 6 and l.side == "R")
  local lt = M.normalize_item({ file = "a", line = 3, side = "left", comment = "x", end_line = 2 })
  check("item: target side, bogus end_line dropped", lt.side == "L" and lt.end_line == nil)
  check("item: file-level", M.normalize_item({ file = "a", comment = "x" }).kind == "file")
  check("item: pr-level", M.normalize_item({ comment = "x" }).kind == "pr")
  local n = M.normalize_item({ note = "just saying" })
  check("item: note only", n.kind == "note" and n.text == nil)
  check("item: nothing usable -> nil", M.normalize_item({ line = 3 }) == nil)
  check("item: not a table -> nil", M.normalize_item("x") == nil)
  check("item: blank strings ignored", M.normalize_item({ comment = "   " }) == nil)
  check("item: bad line ignored", M.normalize_item({ file = "a", line = "x", comment = "c" }).kind == "file")
  check("normalize_items drops junk", #M.normalize_items({ { comment = "a" }, 5, { line = 1 } }) == 1)
end

-- --- parse_output -----------------------------------------------------------

do
  local out = table.concat({
    "# Triage", "", "Two things.", "",
    "```json",
    '{"summary": "1 fix", "items": [{"thread_id": 5, "reply": "ok"}, {"comment": "general"}]}',
    "```", "",
  }, "\n")
  local p = M.parse_output(out, decode)
  check("parse: markdown kept, json block removed", table.concat(p.lines, "\n") == "# Triage\n\nTwo things.")
  check("parse: items", #p.items == 2 and p.items[1].kind == "thread" and p.items[2].kind == "pr")
  check("parse: summary", p.summary == "1 fix")

  local two = "```json\n{\"items\": [{\"comment\": \"first\"}]}\n```\ntext\n```json\n{\"items\": [{\"comment\": \"last\"}]}\n```"
  local p2 = M.parse_output(two, decode)
  check("parse: the last suggestions block wins", #p2.items == 1 and p2.items[1].text == "last")
  check("parse: an earlier block stays in the text", table.concat(p2.lines, "\n"):find("first", 1, true) ~= nil)

  local other = "```json\n{\"name\": \"not suggestions\"}\n```"
  local p3 = M.parse_output(other, decode)
  check("parse: a json block without items stays as text", #p3.items == 0 and #p3.lines == 3)

  local broken = "hello\n```json\n{oops\n```"
  local p4 = M.parse_output(broken, decode)
  check("parse: malformed json is just text", #p4.items == 0 and #p4.lines == 4)

  local p5 = M.parse_output('{"items": [{"file": "a", "line": 2, "comment": "c"}]}', decode)
  check("parse: bare json document", #p5.lines == 0 and #p5.items == 1 and p5.items[1].kind == "line")

  local p6 = M.parse_output('[{"comment": "a"}, {"comment": "b"}]', decode)
  check("parse: bare json list", #p6.items == 2)

  local env = '{"type": "result", "result": "Hi\\n```json\\n{\\"items\\": [{\\"comment\\": \\"x\\"}]}\\n```\\n"}'
  local p7 = M.parse_output(env, decode)
  check("parse: claude --output-format json envelope", table.concat(p7.lines, "\n") == "Hi" and #p7.items == 1)

  local p8 = M.parse_output("\r\n\r\nline one\r\nline two\r\n\r\n", decode)
  check("parse: CRLF and blank edges trimmed", #p8.lines == 2 and p8.lines[1] == "line one")
  check("parse: empty output", #M.parse_output("", decode).lines == 0)
end

-- --- simplify_threads / annotate_items --------------------------------------

local raw_threads = {
  value = {
    { id = 1, status = "active", threadContext = { filePath = "/src/a.cs", rightFileStart = { line = 4 },
        rightFileEnd = { line = 6 } },
      comments = {
        { id = 1, author = { displayName = "Bob" }, content = "Why not a constant? It is used in three places and should really live in exactly one place.",
          publishedDate = "2026-10-01T10:00:00Z", commentType = "text" },
        { id = 2, author = { displayName = "Al" }, content = "ok", commentType = "text" },
      } },
    { id = 2, status = "fixed", threadContext = { filePath = "/src/b.cs", leftFileStart = { line = 9 } },
      comments = { { id = 1, author = { displayName = "Bob" }, content = "old side", commentType = "text" } } },
    { id = 3, status = "active", comments = {
        { id = 1, author = { displayName = "Sys" }, content = "voted", commentType = "system" } } },
    { id = 4, status = "active", isDeleted = true,
      comments = { { id = 1, author = { displayName = "Bob" }, content = "gone", commentType = "text" } } },
    { id = 5, status = "active", threadContext = { filePath = "/README.md" },
      comments = { { id = 1, author = { displayName = "Bob" }, content = "file-level", commentType = "text" },
        { id = 2, author = { displayName = "Bob" }, content = "   ", commentType = "text" } } },
  },
}

do
  local th = M.simplify_threads(raw_threads)
  check("threads: system-only and deleted threads dropped", #th == 3)
  check("threads: right-side anchor and range", th[1].file == "src/a.cs" and th[1].side == "R"
    and th[1].line == 4 and th[1].end_line == 6 and #th[1].comments == 2 and th[1].comments[1].author == "Bob")
  check("threads: left-side anchor", th[2].side == "L" and th[2].line == 9 and th[2].end_line == nil)
  check("threads: file-level, blank comment dropped", th[3].file == "README.md" and th[3].line == nil
    and th[3].side == nil and #th[3].comments == 1)
  check("threads: a bare list works too", #M.simplify_threads(raw_threads.value) == 3)
  check("threads: junk in -> empty", #M.simplify_threads(nil) == 0)

  local items = M.annotate_items(M.normalize_items({ { thread_id = 1, reply = "r" }, { thread_id = 99, reply = "x" },
    { comment = "pr" } }), th)
  check("annotate: location from its thread", items[1].file == "src/a.cs" and items[1].line == 4 and items[1].status == "active")
  check("annotate: excerpt truncated", items[1].excerpt:sub(1, 5) == "Bob: " and #items[1].excerpt <= 75
    and items[1].excerpt:sub(-3) == "...")
  check("annotate: unknown thread flagged", items[2].missing == true)
  check("annotate: non-thread items untouched", items[3].file == nil and items[3].missing == nil)
end

-- --- item_location / render_lines -----------------------------------------

do
  check("location: thread", M.item_location({ kind = "thread", thread_id = 3, file = "a.cs", line = 4, side = "R" })
    == "thread #3 \u{00B7} a.cs:4")
  check("location: range on the target", M.item_location({ kind = "line", file = "a.cs", line = 4, end_line = 6, side = "L" })
    == "a.cs:4-6 (target)")
  check("location: file", M.item_location({ kind = "file", file = "a.cs" }) == "a.cs (file)")
  check("location: pr", M.item_location({ kind = "pr" }) == "pull request")

  local run = {
    label = "Triage", pr_id = "42", status = "done", started = 1000, finished = 1075, exit = 0,
    summary = "two", lines = { "# Hi", "body" },
    items = {
      { kind = "thread", thread_id = 3, file = "a.cs", line = 4, side = "R", verdict = "fix", note = "n1\nn2", text = "reply", accepted = true },
      { kind = "note", note = "fyi" },
    },
    stderr = { "warn" },
  }
  local lines, item_at = M.render_lines(run, 2000)
  local all = table.concat(lines, "\n")
  check("render: heading", lines[1] == "# Triage  \u{00B7}  PR #42")
  check("render: status and duration", lines[2]:find("^done") ~= nil and lines[2]:find("took 1m 15s", 1, true) ~= nil)
  check("render: summary and body", all:find("**two**", 1, true) and all:find("# Hi\nbody", 1, true))
  check("render: suggestions heading", all:find("## Suggestions (2)", 1, true) ~= nil)
  local head
  for ln, l in ipairs(lines) do if l:find("^\u{25B8} thread #3") then head = ln end end
  check("render: item heading mapped", head and item_at[head] == 1 and lines[head]:find("[fix]", 1, true)
    and lines[head]:find("drafted", 1, true))
  check("render: note and draft lines mapped too", item_at[head + 1] == 1 and all:find("  > reply", 1, true))
  check("render: stderr hidden on success with output", not all:find("## stderr", 1, true))

  local failed = { label = "T", pr_id = "1", status = "failed", exit = 2, started = 1, finished = 2,
    lines = {}, items = {}, stderr = { "boom" } }
  local fl = table.concat(M.render_lines(failed, 3), "\n")
  check("render: failure shows exit and stderr", fl:find("failed (exit 2)", 1, true) and fl:find("    boom", 1, true))
  local running = { label = "T", pr_id = "1", status = "running", started = 100 }
  local rl = M.render_lines(running, 130)
  check("render: running", rl[2]:find("^running") and rl[2]:find("30s so far", 1, true) and #rl == 4)
  local empty = table.concat(M.render_lines({ label = "T", pr_id = "1", status = "done", started = 1, finished = 1 }, 1), "\n")
  check("render: nothing printed", empty:find("(the agent printed nothing)", 1, true) ~= nil)
end

-- --- available / is_author / misc --------------------------------------------

do
  local actions = {
    zeta = { cmd = { "z" } },
    alpha = { cmd = { "a" }, label = "Alpha", when = "author" },
    beta = { cmd = { "b" }, when = "reviewer" },
    gamma = { cmd = { "g" }, when = function(info) return info.file ~= nil end },
    broken = { cmd = { "x" }, when = function() error("boom") end },
  }
  local function names(list)
    local out = {}
    for _, a in ipairs(list) do out[#out + 1] = a.name end
    return table.concat(out, ",")
  end
  check("available: reviewer", names(M.available(actions, { is_author = false })) == "beta,zeta")
  check("available: author, sorted by label", names(M.available(actions, { is_author = true, file = "x" })) == "alpha,gamma,zeta")
  check("available: none configured", #M.available(nil, {}) == 0)

  check("is_author: Created", M.is_author({ state = "Created" }))
  check("is_author: by name", M.is_author({ state = "Drafts", author = "Me", myName = "Me" }))
  check("is_author: someone else", not M.is_author({ state = "Actionable", author = "Bob", myName = "Me" }))
  check("is_author: no name", not M.is_author({ author = "", myName = "" }))
  check("slug", M.slug("my repo/x:1") == "my_repo_x_1")
  check("duration", M.human_duration(5) == "5s" and M.human_duration(3725) == "1h 2m")
  check("status_text", M.status_text({ status = "timeout" }) == "timed out" and M.status_text({ status = "done" }) == "done")
end

-- --- follow-ups: session ids, resume vs replay, conversation rendering -------

do
  local env = '{"type": "result", "result": "Hi", "session_id": "abc-123"}'
  check("session: from the claude envelope", M.parse_output(env, decode).session_id == "abc-123")
  check("session: none in plain text", M.parse_output("Hi", decode).session_id == nil)
  check("find_session: stdout first", M.find_session("Session: (%S+)", "x\nSession: s-1\n", "Session: s-2") == "s-1")
  check("find_session: then stderr", M.find_session("Session: (%S+)", "nothing", "Session: s-2") == "s-2")
  check("find_session: no match", M.find_session("Session: (%S+)", "a", "b") == nil)
  check("find_session: a broken pattern is no match", M.find_session("(", "a") == nil)

  local resume = { followup = { cmd = { "claude", "-p", "--resume", "{session_id}" }, stdin = "{message}" } }
  check("can_resume: needs the session it names", not M.can_resume(resume, {}) and M.can_resume(resume, { session_id = "s" }))
  check("can_resume: an empty session id doesn't count", not M.can_resume(resume, { session_id = "" }))
  local cont = { followup = { cmd = { "claude", "-p", "--continue" }, stdin = "{message}" } }
  check("can_resume: a followup without {session_id} always can", M.can_resume(cont, {}))
  check("can_resume: no followup -> replay", not M.can_resume({ cmd = { "x" } }, { session_id = "s" }))
  check("can_resume: {session_id} in the followup's stdin counts", not M.can_resume(
    { followup = { cmd = "agent", stdin = "resume {session_id}" } }, {}))

  local run = {
    label = "Triage", pr_id = "7", status = "done", started = 100, finished = 160,
    lines = { "first answer" },
    items = { { kind = "pr", text = "a" }, { kind = "pr", text = "b", turn = 1 } },
    conversation = {
      { message = "why?\nreally", status = "done", started = 200, finished = 230, lines = { "because" }, mode = "resume" },
      { message = "and?", status = "running", started = 300, mode = "replay" },
    },
  }
  local lines, item_at = M.render_lines(run, 330, "R ask a follow-up")
  local all = table.concat(lines, "\n")
  check("render: first answer's suggestions only under it", all:find("## Suggestions (1)", 1, true) ~= nil)
  check("render: your message, both lines", all:find("## You \u{00B7} ", 1, true) and all:find("why?\nreally", 1, true))
  check("render: the answer and its suggestions", all:find("## Triage \u{00B7} done \u{00B7} took 30s", 1, true)
    and all:find("because", 1, true) and all:find("### Suggestions (1)", 1, true))
  local second
  for ln, l in ipairs(lines) do if l == "\u{25B8} pull request" then second = ln end end
  check("render: a follow-up's suggestion maps to its global index", second and item_at[second] == 2)
  check("render: a running turn", all:find("running \u{00B7} 30s so far \u{00B7} replayed the conversation", 1, true)
    and all:find("Working on it", 1, true))
  check("render: footer last", lines[#lines] == "R ask a follow-up")

  local text = M.replay_text(run, "and?")
  check("replay: carries the first answer", text:find("first answer", 1, true) ~= nil)
  check("replay: carries the earlier turn", text:find("The user then asked:\nwhy?\nreally", 1, true)
    and text:find("and you answered:\nbecause", 1, true))
  check("replay: ends with the new question", text:find("Now the user asks:\nand?\n", 1, true) ~= nil)
  check("replay: the pending turn itself isn't repeated", select(2, text:gsub("and%?", "")) == 1)
end

-- --- review/agent.lua's virt_lines -------------------------------------------

do
  local v = R.virt_lines({ kind = "thread", verdict = "fix", note = "a\nb\nc\nd\ne", text = "reply" }, "Triage")
  check("virt: heading", v[1][1][1] == "    \u{2726} Triage \u{00B7} fix  (ga drafts the reply)")
  check("virt: note capped at four lines", #v == 1 + 5 + 1 and v[6][1][1] == "      \u{2026}")
  check("virt: draft text quoted", v[7][1][1] == "      > reply")
  local d = R.virt_lines({ kind = "line", text = "c", accepted = true }, "T")
  check("virt: drafted", d[1][1][1]:find("drafted", 1, true) ~= nil and not d[1][1][1]:find("ga drafts", 1, true))
  local n = R.virt_lines({ kind = "note", note = "fyi" }, nil)
  check("virt: note without a draft", #n == 2 and not n[1][1][1]:find("ga", 1, true))
end

if fails > 0 then
  print(fails .. " failure(s)")
  os.exit(1)
end
print("all agent tests passed")
