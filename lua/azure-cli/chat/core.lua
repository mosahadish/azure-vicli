-- lua/azure-cli/chat/core.lua: the chat's pure helpers - no Neovim API
-- here, so tests/test-chat.lua can pin them down (it still runs in a real
-- nvim for vim.json/vim.split, which a few of them take as injected
-- arguments anyway).
--
--   compose        the text one message sends the agent
--   stream_*       reading the agent's stdout as it arrives: Claude Code's
--                  --output-format stream-json events, its single json
--                  envelope, or plain text, line by line
--   parse_answer   the same over a finished run's whole output
--   STREAM_JSON_STDIN  the default chat.agent.stdin: one stream-json request
--   interrupt_line     the stream-json control_request stopping a turn
--   expand         {placeholder} templates
--   render         the transcript's lines and what each one is
--   prompts        saved prompts ("/triage ...")
--   find_refs      #123 / !123 / PR 123 references in a text
local M = {}

M.PREAMBLE = [[You are the assistant inside azure-vicli, a Neovim plugin for Azure DevOps pull requests and work items. The user talks to you from a chat panel next to the screen they're on. Each message starts with "Current view", describing what they are looking at; "this PR", "this comment", "this work item" and "this code" mean what it names.

Use the azure-vicli tools to look things up and to act. Drafted replies and comments are queued for the user to review, never posted directly. Before changing code, plan it: write the plan with submit_plan (it has a markdown template) and stop - the user reads it, may ask you why about any line of it (answer just that, briefly), and approves it or asks for changes; start_fix refuses without an approved plan, and start_story then only gives you a read-only worktree. To read the code a work item's plan is about, call start_story first, with the repository and branches the story will use (ask when they aren't clear): it returns a worktree of that branch, nothing is created on the server, and you read files there with your Read and Grep tools, never by copying them out with git show or git archive. Say in the plan which branch and commit its line numbers refer to. Once the plan is approved, call start_story again: the same directory becomes the story's worktree. To change code for a review comment: call start_fix, edit files only inside the directory it returns, then show_fix to let the user see the change, and commit_and_push_fix once they agree; then draft a reply saying what you changed. To implement a work item (a story, bug or task): read it with get_work_item, call start_story (it makes the branch and a worktree; ask which repository and base branch when they aren't clear), edit files only inside the directory it returns, then show_fix and commit_and_push_fix with work_item_id, and offer create_pull_request linking the work item. If the branch moved under you, rebase onto it; never soft-reset onto a branch HEAD isn't directly on, because that silently reverts the other commits. Never edit files anywhere else. Make every file change with your Edit and Write tools, never with shell commands or scripts through Bash (python, sed -i, heredocs, redirects): a Bash command that writes files always asks the user to allow it, while Edit or Write on a file your approved plan lists doesn't, and keeps the file's line endings. Use Bash only to read and to run commands. Before changing a file your approved plan doesn't list under Files, say in one sentence why - the user is asked to allow it, and sees that sentence. Build and test with run_tests: under an approved plan, its Test plan command runs without asking. To delete a file there, use delete_fix_file. To find the types implementing an interface or deriving from a class, or where something is declared, use find_implementations and find_definition. get_pull_request reads any PR by id. Use open_in_ui only when the user asks to be shown something, and annotate_code to leave notes on lines of a diff.

Refer to pull requests as !<id> and work items as #<id>, so the user can open them from the chat. Answer briefly, in markdown.]]

-- The status strip (the tab line's right end, or a statusline): `s` = {
-- running = { frame, label, seconds } while the agent works, question =
-- true while a yes/no waits for you, waiting = labels of the plans waiting
-- for your review }. "" when there's nothing to say. Pure.
-- With several agents, `working` = { { label, seconds } } and `frame`:
-- one shows like `running`, more as "⠹ 3 agents working"; `queued` counts
-- the ones waiting for an agent, `more_questions` the questions
-- waiting behind the one asked.
function M.strip_text(s)
  s = s or {}
  local parts = {}
  local w = s.working or {}
  if #w > 1 then
    parts[#parts + 1] = (s.frame or "*") .. " " .. #w .. " agents working"
  elseif #w == 1 then
    parts[#parts + 1] = (s.frame or "*") .. " " .. w[1].label .. " " .. tostring(w[1].seconds) .. "s"
  elseif s.running then
    parts[#parts + 1] = s.running.frame .. " " .. s.running.label .. " " .. tostring(s.running.seconds) .. "s"
  end
  if (s.queued or 0) > 0 then parts[#parts + 1] = "\u{231B} " .. s.queued .. " queued" end
  if s.question then
    parts[#parts + 1] = "\u{26A0} " .. ((s.more_questions or 0) > 0 and ((s.more_questions + 1) .. " questions wait")
      or "a question waits") .. " for you"
  end
  local w = s.waiting or {}
  if #w == 1 then
    parts[#parts + 1] = "\u{25CF} plan " .. w[1] .. " waits for you"
  elseif #w > 1 then
    parts[#parts + 1] = "\u{25CF} " .. #w .. " plans wait for you"
  end
  return table.concat(parts, "  \u{00B7}  ")
end

-- A conversation's cost so far: the sum of its answers' `cost` (each the
-- difference in its process's running total - see send). nil when none
-- reported one (an agent that doesn't, like an ACP one). Pure.
function M.cost_of(entries)
  local sum, any = 0, false
  for _, e in ipairs(entries or {}) do
    if type(e.cost) == "number" then sum, any = sum + e.cost, true end
  end
  return any and sum or nil
end

-- A conversation's premium requests so far (Copilot bills a message as one
-- request times its model's multiplier - agent.premium_requests): the sum
-- of its messages' `requests`, or nil when none counted. Pure.
function M.requests_of(entries)
  local sum, any = 0, false
  for _, e in ipairs(entries or {}) do
    if type(e.requests) == "number" then sum, any = sum + e.requests, true end
  end
  return any and sum or nil
end

-- What one message to `agent` on `model` counts as, in premium requests:
-- agent.premium_requests[model], else its `default`; nil when the agent has
-- no premium_requests (it isn't billed that way). Pure.
function M.request_multiplier(agent, model)
  local p = type(agent) == "table" and agent.premium_requests
  if type(p) ~= "table" then return nil end
  local m = (model and model ~= "" and p[model]) or p.default
  if m == nil then m = 1 end
  return tonumber(m)
end

-- "12 req", "1.5 req", "" for nil. Pure.
function M.requests_label(n)
  if type(n) ~= "number" then return "" end
  return (n == math.floor(n) and tostring(math.floor(n)) or string.format("%.1f", n)) .. " req"
end

-- How full the agent's context is, from ACP's usage_update ({ used, size }):
-- "ctx 27%", "" when unknown. Pure.
function M.context_label(ctx)
  if type(ctx) ~= "table" or not tonumber(ctx.used) or not tonumber(ctx.size) or tonumber(ctx.size) <= 0 then
    return ""
  end
  return "ctx " .. math.floor(100 * tonumber(ctx.used) / tonumber(ctx.size) + 0.5) .. "%"
end

-- "$0.42", "<$0.01", "" for nil. Pure.
function M.money(x)
  if type(x) ~= "number" then return "" end
  if x > 0 and x < 0.005 then return "<$0.01" end
  return string.format("$%.2f", x)
end

-- What ga in the conversation sends: a question about one of the agent's steps (a tool call
-- it made, `kind` "step") or a line of its answer ("line"), with the
-- message it was answering. Pure.
function M.why_message(quote, kind, asked, question)
  local parts = { "About your " .. (kind == "step" and "step" or "answer") .. (asked and asked ~= ""
    and (" to my \"" .. (#asked > 120 and (asked:sub(1, 117) .. "...") or asked) .. "\"") or "") .. ":" }
  parts[#parts + 1] = "> " .. (quote or ""):gsub("^%s+", ""):gsub("%s+$", "")
  parts[#parts + 1] = ""
  parts[#parts + 1] = question
  parts[#parts + 1] = ""
  parts[#parts + 1] = "(Answer that question only, briefly. Don't redo or undo anything unless I ask.)"
  return table.concat(parts, "\n")
end

-- Default saved prompts (setup({chat = {prompts = {...}}}) adds, replaces,
-- or removes one with `name = false`). "/name rest" in the input box sends
-- the prompt followed by `rest`.
M.DEFAULT_PROMPTS = {
  triage = "Triage this pull request's open comment threads: for each, say whether the reviewer is right "
    .. "(fix / push back / question / already done) and why. Don't draft replies or change anything - "
    .. "I'll ask for replies if I want them.",
  review = "Review this pull request's change for correctness bugs, missing tests and risky spots. "
    .. "Leave notes on the lines that matter with annotate_code, and summarise here.",
  reviewers = "Suggest reviewers for this pull request: who knows the code it changes - git log and git blame on "
    .. "its files in the PR's clone, and CODEOWNERS if the repository has one. Leave out its author and current "
    .. "reviewers. Then call suggest_reviewers with each of them and why, in a few words.",
  explain = "Explain what this code or comment is about, and what the change does around it.",
  plan = "Make a plan for this - the work item, or the review comment, in view - with submit_plan, following its "
    .. "template. Read what you need first (get_work_item, get_pr_threads, the code - for a work item, in the "
    .. "read-only worktree start_story gives you), but don't change any code; "
    .. "stop once the plan is submitted.",
  build = "Why did this pull request's build fail? Read the build log and the failed tests, and point at the cause.",
  standup = "Write my standup: what moved since yesterday on my pull requests and work items, "
    .. "what's waiting on me, and anything blocked or failing.",
}

-- ACP tool-call kinds (agentclientprotocol.com's ToolKind) the agent's
-- permission requests are answered for without asking you: reading and
-- searching are always allowed; changing files is refused while a /plan
-- message runs (a plan changes no code), and allowed once the files are
-- in an approved plan (chat/plan.lua's edit_check).
M.READ_ONLY_KINDS = { read = true, search = true, think = true }
M.FILE_CHANGE_KINDS = { edit = true, delete = true, move = true }

-- Shell commands that only look (Copilot greps and lists through the
-- shell rather than a read tool), lower-cased, `.exe` dropped. Each maps
-- to the flags that would make it write or run something else.
local LOOK_ONLY = {
  rg = { "--pre", "--pre-glob" }, grep = {}, egrep = {}, fgrep = {}, findstr = {},
  find = { "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls" },
  fd = { "-x", "--exec", "-X", "--exec-batch" },
  ls = {}, dir = {}, tree = {}, cat = {}, type = {}, head = {}, tail = {}, wc = {}, sort = { "-o", "--output" },
  uniq = {}, cut = {}, echo = {}, printf = { "-v" }, pwd = {}, cd = {}, file = { "-C", "--compile" }, stat = {},
  which = {}, where = {}, basename = {}, dirname = {}, realpath = {},
  diff = { "-o", "--output" }, cmp = { "-o", "--output" }, comm = { "-o", "--output" },
  ["get-content"] = {}, gc = {}, ["get-childitem"] = {}, gci = {}, ["select-string"] = {}, sls = {},
  ["get-item"] = {}, ["test-path"] = {}, ["resolve-path"] = {}, ["get-location"] = {},
  ["where-object"] = {}, ["out-null"] = {}, ["select-object"] = {}, select = {}, ["sort-object"] = {},
  ["measure-object"] = {}, measure = {},
  ["format-table"] = {}, ft = {}, ["format-list"] = {}, fl = {}, ["out-string"] = {},
}
-- git's: what each would write with, besides --output / --ext-diff.
local GIT_LOOK_ONLY = {
  log = {}, show = {}, diff = {}, status = {}, blame = {}, grep = { "-O", "--open-files-in-pager" },
  ["ls-files"] = {}, ["ls-tree"] = {}, ["rev-parse"] = {}, describe = {}, shortlog = {}, ["cat-file"] = {},
  ["merge-base"] = {}, ["show-ref"] = {},
}
-- git worktree list's flags; any other worktree subcommand, or word, asks.
local WORKTREE_LIST = { ["--porcelain"] = true, ["-v"] = true, ["--verbose"] = true, ["-z"] = true }
-- gh's that only read, each with the flags that open a browser (gh run
-- list's -w is --workflow). gh api is gh_api_reads'.
local WEB = { "-w", "--web" }
local GH_LOOK_ONLY = {
  run = { list = { "--web" }, view = WEB, watch = { "--web" } },
  pr = { view = WEB, checks = WEB, diff = WEB, list = WEB, status = WEB },
  issue = { view = WEB, list = WEB, status = WEB },
}

-- A configured remote's name: no path or URL (another transport, or a
-- repo whose upload-pack runs).
local REMOTE_NAME = "^[%w][%w._-]*$"

-- Whether `git fetch` with `words` from `from` on only fetches: -q,
-- --quiet or --prune, then a remote's name and branches. That writes
-- origin/* and FETCH_HEAD only: a REMOTE_NAME, no x:y or +x refspec (a
-- local branch), and no other option (--upload-pack, -c,
-- --recurse-submodules, ...).
local function fetch_reads(words, from)
  local k = from
  while words[k] == "-q" or words[k] == "--quiet" or words[k] == "--prune" do k = k + 1 end
  if words[k] and not words[k]:match(REMOTE_NAME) then return false end
  for m = k + 1, #words do
    if not words[m]:match("^[%w_][%w._/-]*$") then return false end
  end
  return true
end

-- Whether `git remote` with `words` from `from` on only reads: -v or
-- --verbose, then nothing (the list), show [-n] NAME... (show without
-- -n asks the remote, as fetch does) or get-url [--push] [--all] NAME,
-- each a REMOTE_NAME. add, remove, rename, set-url, prune, update, ...
-- change something.
local function remote_reads(words, from)
  local k = from
  if words[k] == "-v" or words[k] == "--verbose" then k = k + 1 end
  local sub = words[k]
  if sub == nil then return true end
  k = k + 1
  if sub == "show" then
    if words[k] == "-n" then k = k + 1 end
  elseif sub == "get-url" then
    while words[k] == "--push" or words[k] == "--all" do k = k + 1 end
    if #words ~= k then return false end
  else
    return false
  end
  if not words[k] then return false end
  for m = k, #words do
    if not words[m]:match(REMOTE_NAME) then return false end
  end
  return true
end

-- Whether GraphQL document `q` only reads: each definition at the top
-- level a query (`query ...` or a bare `{ ... }`) or a fragment, at
-- least one of them a query. mutation or subscription anywhere at the
-- top level, any other definition, an unterminated string or unbalanced
-- brackets don't count. Strings ("..." and """..."""), # comments and
-- commas are skipped.
local BRACKETS = { ["{"] = "}", ["("] = ")", ["["] = "]" }
local function graphql_reads(q)
  local i, n, stack, start, ops = 1, #q, {}, true, 0
  while i <= n do
    local c = q:sub(i, i)
    if c:match("[%s,]") then
      i = i + 1
    elseif c == "#" then
      i = (q:find("\n", i, true) or n) + 1
    elseif q:sub(i, i + 2) == '"""' then
      -- \""" is a block string's only escape.
      local e = i + 3
      repeat
        e = q:find('"""', e, true)
        if not e then return false end
        e = e + 3
      until q:sub(e - 4, e - 4) ~= "\\"
      i = e
    elseif c == '"' then
      local k = i + 1
      while q:sub(k, k) ~= '"' do
        if k > n or q:sub(k, k) == "\n" then return false end
        k = k + (q:sub(k, k) == "\\" and 2 or 1)
      end
      i = k + 1
    elseif BRACKETS[c] then
      if start then
        if c ~= "{" then return false end
        start, ops = false, ops + 1
      end
      stack[#stack + 1] = BRACKETS[c]
      i = i + 1
    elseif c == "}" or c == ")" or c == "]" then
      if stack[#stack] ~= c then return false end
      stack[#stack] = nil
      -- A definition ends where its selection set closes.
      start = #stack == 0 and c == "}"
      i = i + 1
    elseif c:match("[%a_]") then
      local word = q:match("^[%w_]+", i)
      if #stack == 0 then
        if word == "mutation" or word == "subscription" then return false end
        if start then
          if word ~= "query" and word ~= "fragment" then return false end
          start, ops = false, ops + (word == "query" and 1 or 0)
        end
      end
      i = i + #word
    else
      if start then return false end
      i = i + 1
    end
  end
  return #stack == 0 and start and ops > 0
end

-- gh api's flags that only change what it prints: with a value, and
-- without; its fields' (-f raw, -F typed or @file).
local GH_API_VALUE = { ["-q"] = true, ["--jq"] = true, ["-t"] = true, ["--template"] = true, ["--cache"] = true }
local GH_API_SWITCH = {
  ["--paginate"] = true, ["--slurp"] = true, ["-i"] = true, ["--include"] = true, ["--silent"] = true,
  ["--verbose"] = true,
}
local GH_API_FIELD = { ["-f"] = true, ["--raw-field"] = true, ["-F"] = true, ["--field"] = true }

-- Whether `gh api` with `words` from `from` on only reads: a GraphQL
-- query (graphql_reads) sent to `graphql` - every query= field one, none
-- of the fields starting with @ (a file) - the method POST if it's
-- given, and GH_API_VALUE / GH_API_SWITCH besides. REST paths, --input,
-- -H, --hostname and any other flag ask. `unknown` (expand's): the
-- endpoint, a flag, a query or what it prints can't be unknown; another
-- field's value (a GraphQL variable's) may be "inside" one.
local function gh_api_reads(words, unknown, from)
  local endpoint, queries, k = nil, 0, from
  while words[k] do
    local w, u = words[k], unknown[k]
    if u == "free" then return false end
    if not w:match("^%-") then
      if u or endpoint then return false end
      endpoint = w
    elseif not GH_API_SWITCH[w] then
      local flag, value = w:match("^(%-%-[%w-]+)=(.*)$")
      if not flag then flag, value = w:match("^(%-[fFXqt])(.+)$") end
      flag = flag or w
      if not (GH_API_FIELD[flag] or GH_API_VALUE[flag] or flag == "-X" or flag == "--method") then return false end
      if not value then k = k + 1; value, u = words[k], unknown[k] end
      if not value or u == "free" then return false end
      if GH_API_FIELD[flag] then
        local key, v = value:match("^([^=]+)=(.*)$")
        if not key or v:sub(1, 1) == "@" then return false end
        if key == "query" then
          if u or not graphql_reads(v) then return false end
          queries = queries + 1
        end
      elseif u or ((flag == "-X" or flag == "--method") and value ~= "POST") then
        return false
      end
    end
    k = k + 1
  end
  return endpoint == "graphql" and queries > 0
end

-- A one-letter flag counts inside a cluster too (sort -ro out).
local function bad_flag(words, from, flags)
  for i = from, #words do
    local w = words[i]
    for _, f in ipairs(flags) do
      if w == f or w:sub(1, #f + 1) == f .. "=" then return true end
      if #f == 2 and w:match("^%-%w+$") and w:find(f:sub(2), 2, true) then return true end
    end
  end
end

-- Whether sed script `s` only prints: addresses (N, $, /re/, N~M, ranges,
-- !), the commands that print or move lines, and s/// and y/// - s's
-- flags only g p i I m M and a count. w W r R e write files, read them or
-- run commands; they (and anything not listed) don't count.
local function sed_reads(s)
  local i, n = 1, #s
  local function at(k) return s:sub(k or i, k or i) end
  -- Past a part closed by `d`, from just inside it. Jumps with find: a
  -- loop stepping over \x one character at a time went wrong once
  -- LuaJIT compiled it, refusing s/a\/b// after a few commands (#62).
  local function past(d)
    local stop = "[\\" .. d:gsub("%W", "%%%0") .. "]"
    while true do
      local k = s:find(stop, i)
      if not k then i = n + 1; return false end
      if s:sub(k, k) == d then i = k + 1; return true end
      i = k + 2
    end
  end
  local function space() while at():match("^%s$") do i = i + 1 end end
  local function digits() i = s:find("%D", i) or n + 1 end
  -- true, false when there's no address here, nil when it's malformed.
  local function address()
    local c = at()
    if c:match("^%d$") then
      digits()
      if at() == "~" then
        i = i + 1
        if not at():match("^%d$") then return nil end
        digits()
      end
      return true
    elseif c == "$" then
      i = i + 1
      return true
    elseif c == "/" or c == "\\" then
      local d = c == "/" and "/" or at(i + 1)
      i = i + (c == "/" and 1 or 2)
      if d == "" or d == "\\" or d == "\n" or not past(d) then return nil end
      while at() == "I" or at() == "M" do i = i + 1 end
      return true
    end
    return false
  end
  while true do
    while at():match("^[%s;]$") do i = i + 1 end
    if i > n then return true end
    local a = address()
    if a == nil then return false end
    if a then
      space()
      if at() == "," then
        i = i + 1
        space()
        if at() == "+" or at() == "~" then
          i = i + 1
          if not at():match("^%d$") then return false end
          digits()
        elseif address() ~= true then
          return false
        end
      end
    end
    space()
    if at() == "!" then i = i + 1; space() end
    local c = at()
    i = i + 1
    if c == "s" or c == "y" then
      local d = at()
      i = i + 1
      if d == "" or d:match("[%s\\]") or not past(d) or not past(d) then return false end
      if c == "s" then while at():match("^[gpiImM%d]$") do i = i + 1 end end
    elseif c == "q" or c == "Q" or c == "l" then
      space()
      while at():match("^%d$") do i = i + 1 end
    elseif not c:match("^[pdDnNPgGhHxz={}]$") then
      return false
    end
    space()
    if i <= n and not at():match("^[;}]$") then return false end
  end
end

-- Whether awk program `p` only reads and prints to stdout: outside its
-- strings, regexes and comments, no system, no | (|| is fine: "cmd" |
-- getline, print | "cmd", |&), no @ (gawk's @load, @include, indirect
-- calls), no < in a statement with getline (gawk opens /inet/ sockets
-- that way), and no > or >> in a print or printf statement but inside
-- its parentheses (print > f, printf(...) > f; not $3 > 5). A / where an
-- operand would go starts a regex, anywhere else (after a name, number,
-- ), ], string, ++ or --) it divides: a wrong guess scans more of it as
-- code, and asks. Jumps with find, as sed_reads' past does (#62).
local function awk_reads(p)
  local i, n = 1, #p
  -- operand: the last token ends one. depth: of ( and [. print_at: the
  -- depth the statement's print began at. getline: the statement has one.
  local operand, depth, print_at, getline = false, 0, nil, false
  local function stmt_end() operand, print_at, getline = false, nil, false end
  -- Past the string or regex closed by `d` at i, from just inside it
  -- (a regex's [...] too); false when it doesn't close on its line.
  local function past(d)
    local stop = d == "/" and "[/\\\n%[]" or '["\\\n]'
    i = i + 1
    while true do
      local k = p:find(stop, i)
      local c = k and p:sub(k, k)
      if not k or c == "\n" then return false end
      if c == d then i = k + 1; return true end
      if c == "\\" then
        i = k + 2
      else
        -- [ ... ]: a ] first (or after ^) is one of its characters.
        i = k + 1
        if p:sub(i, i) == "^" then i = i + 1 end
        if p:sub(i, i) == "]" then i = i + 1 end
        while true do
          local e = p:find("[%]\\\n]", i)
          if not e or p:sub(e, e) == "\n" then return false end
          if p:sub(e, e) == "]" then i = e + 1; break end
          i = e + 2
        end
      end
    end
  end
  while true do
    i = p:find("[^ \t\r]", i)
    if not i then return true end
    local c = p:sub(i, i)
    if c == '"' or (c == "/" and not operand) then
      if not past(c) then return false end
      operand = true
    elseif c == "#" then
      i = p:find("\n", i) or n + 1
    elseif c == "\n" then
      -- Ends the statement unless it's left open (after , && { ...).
      if operand then stmt_end() end
      i = i + 1
    elseif c == "\\" then
      -- Only a line continued.
      local nl = p:match("^\r?\n", i + 1)
      if not nl then return false end
      i = i + 1 + #nl
    elseif c:match("[%a_]") then
      local e = p:find("[^%w_]", i) or n + 1
      local word = p:sub(i, e - 1)
      if word == "system" then return false end
      if word == "print" or word == "printf" then print_at = print_at or depth end
      if word == "getline" then getline = true end
      operand, i = true, e
    elseif c:match("[%d.]") then
      operand, i = true, p:find("[^%w.]", i) or n + 1
    elseif c == "(" or c == "[" then
      depth, operand, i = depth + 1, false, i + 1
    elseif c == ")" or c == "]" then
      depth, operand, i = depth - 1, true, i + 1
      if depth < 0 then return false end
    elseif c == ";" or c == "{" or c == "}" then
      stmt_end()
      i = i + 1
    elseif c == "|" then
      if p:sub(i + 1, i + 1) ~= "|" then return false end
      operand, i = false, i + 2
    elseif c == ">" then
      if print_at and depth <= print_at then return false end
      operand, i = false, i + 1
    elseif c == "<" then
      if getline then return false end
      operand, i = false, i + 1
    elseif (c == "+" or c == "-") and p:sub(i + 1, i + 1) == c then
      operand, i = true, i + 2
    elseif c:match("^[,!~&?:=+%-*%%^$]$") then
      operand, i = false, i + 1
    elseif c == "/" then
      operand, i = false, i + 1
    else
      -- @, ` and anything else.
      return false
    end
  end
end

-- `words`: one command, after the shell's quoting and expansion.
-- `unknown` (expand's): the words with a value read from a file in them -
-- "free" when it could make them anything, a flag included. Those can't
-- name the command, go to sed (they'd be its script) or be a free word
-- for a command that a flag makes write.
local function look_only_part(words, unknown)
  unknown = unknown or {}
  if unknown[1] then return false end
  local free = false
  for _, u in pairs(unknown) do free = free or u == "free" end
  local name = (words[1] or ""):lower():gsub("%.exe$", "")
  if name == "git" then
    if free then return false end
    -- Only these before the subcommand: -c / --config-env would set a pager.
    local i = 2
    while words[i] == "--no-pager" or words[i] == "-C" or words[i] == "-P" do i = i + (words[i] == "-C" and 2 or 1) end
    if words[i] == "fetch" then return fetch_reads(words, i + 1) end
    if words[i] == "remote" then return remote_reads(words, i + 1) end
    if words[i] == "worktree" then
      for m = i + 2, #words do if not WORKTREE_LIST[words[m]] then return false end end
      return words[i + 1] == "list"
    end
    local flags = GIT_LOOK_ONLY[words[i] or ""]
    return flags ~= nil and not bad_flag(words, i + 1, { "--output", "--ext-diff" }) and not bad_flag(words, i + 1, flags)
  end
  if name == "gh" then
    if words[2] == "api" then return gh_api_reads(words, unknown, 3) end
    -- GH_LOOK_ONLY's; any other gh command asks.
    local flags = (GH_LOOK_ONLY[words[2] or ""] or {})[words[3] or ""]
    return flags and not free and not bad_flag(words, 4, flags) or false
  end
  if name == "nvim" then
    -- Only its version: anything else (-l, -c, +cmd, a file, an init) runs code.
    return #words == 2 and (words[2] == "--version" or words[2] == "-v") and next(unknown) == nil
  end
  if name == "sed" then
    -- Scripts that only print (sed_reads), given first or with -e; no -i,
    -- no -f script file.
    local script, given = nil, false
    local k = 2
    while k <= #words do
      local w = words[k]
      if w == "--expression" or w:match("^%-[nErsz]*e$") then
        k = k + 1
        if not words[k] or not sed_reads(words[k]) then return false end
        given = true
      elseif w:sub(1, 13) == "--expression=" then
        if not sed_reads(w:sub(14)) then return false end
        given = true
      elseif w == "--quiet" or w == "--silent" or w == "--regexp-extended" or w:match("^%-[nErsz]+$") then
        -- reading flags
      elseif w:match("^%-") then
        return false
      elseif not script then
        script = w
      end
      k = k + 1
    end
    return next(unknown) == nil and (given or (script ~= nil and sed_reads(script)))
  end
  if name == "awk" or name == "gawk" or name == "mawk" or name == "nawk" then
    -- -F and -v only, then a program that only prints (awk_reads); then
    -- files and var=val. Any other flag asks: -i inplace, -f, -l, -E,
    -- -e, and -o / -p / -d write a file.
    if next(unknown) ~= nil then return false end
    local k = 2
    while words[k] do
      local w = words[k]
      if w == "--" then k = k + 1; break end
      if w == "-F" or w == "-v" or w == "--field-separator" or w == "--assign" then
        k = k + 2
      elseif w:match("^%-[Fv].") or w:match("^%-%-field%-separator=") or w:match("^%-%-assign=") then
        k = k + 1
      elseif w:match("^%-.") then
        return false
      else
        break
      end
    end
    return words[k] ~= nil and awk_reads(words[k])
  end
  local flags = LOOK_ONLY[name]
  return flags ~= nil and not (free and #flags > 0) and not bad_flag(words, 2, flags)
end

local shell_tree

-- Where the $( at i closes: the index of its ), past quotes, backslashes
-- and a nested $( ... ). nil when it doesn't close, or holds an unquoted
-- ( ` or # (a comment could hide the ) - $(( is arithmetic).
local function sub_end(cmd, i)
  local k, n = i + 2, #cmd
  local function nested()
    local e = cmd:sub(k + 1, k + 1) == "(" and sub_end(cmd, k)
    k = e and e + 1
    return e
  end
  while k <= n do
    local c = cmd:sub(k, k)
    if c == ")" then return k end
    if c == "'" then
      k = cmd:find("'", k + 1, true)
      if not k then return nil end
      k = k + 1
    elseif c == '"' then
      k = k + 1
      while cmd:sub(k, k) ~= '"' do
        local d = cmd:sub(k, k)
        if d == "" then return nil end
        if d == "\\" or (d == "$" and cmd:sub(k + 1, k + 1):match("^[?#$]$")) then k = k + 2
        elseif d == "$" and cmd:sub(k + 1, k + 1) == "(" then
          if not nested() then return nil end
        else k = k + 1 end
      end
      k = k + 1
    elseif c == "\\" or (c == "$" and cmd:sub(k + 1, k + 1):match("^[?#$]$")) then
      -- $? $# $$ too: their # isn't a comment, their $ doesn't start a $(.
      k = k + 2
    elseif c == "$" and cmd:sub(k + 1, k + 1) == "(" then
      if not nested() then return nil end
    elseif c == "(" or c == "`" or c == "#" then
      return nil
    else
      k = k + 1
    end
  end
end

-- Whether a $(...)'s tree is one `git rev-parse` of literal revs, with
-- only options that print hashes or full ref names: its output is words
-- that can't be a flag or a glob (--abbrev-ref's could start with -).
local REV_PARSE_OPTS = { ["--verify"] = true, ["-q"] = true, ["--quiet"] = true, ["--short"] = true,
  ["--symbolic-full-name"] = true }
local function rev_parse_refs(tree)
  local s = #tree == 1 and tree[1].words
  if not s or #s < 2 then return false end
  local words = {}
  for k, w in ipairs(s) do
    if #w ~= 1 or not w[1].text then return false end
    words[k] = w[1].text
  end
  if words[1] ~= "git" or words[2] ~= "rev-parse" then return false end
  for k = 3, #words do
    local w = words[k]
    if w:match("^%-") then
      if not (REV_PARSE_OPTS[w] or w:match("^%-%-short=%d+$")) then return false end
    elseif w == "" or w:match("[%s*?%[]") then
      return false
    end
  end
  return true
end

-- `cmd` split the way the shell would: statements (split on |, &&, ||,
-- ; and newlines), each a list of words, each word a list of pieces -
-- { text, quoted } or { var = NAME, quoted } for $NAME / ${NAME} (and
-- for $? $# $$, NAME ? # or $: value_of's SPECIAL; with op and pat for
-- ${NAME%pat} ${NAME%%pat} ${NAME#pat} ${NAME##pat}: ref's), or
-- { sub = TREE, refs, quoted } for $(...), quoted or not: its commands
-- as shell_tree's nodes (look_only_tree checks them), refs when
-- rev_parse_refs. nil when it has anything else that runs or writes:
-- outside quotes > < & ( ) { } ` and other $ forms; inside double quotes
-- `. Throwing errors away, or merging them, writes nothing: 2>/dev/null,
-- 2>$null, *>$null, 2>&1 (a whole word each - 2>/dev/nullx is a file -
-- that ; & or | may end). A plain < (not <<, <( <& <>) is a word of its
-- own, { { redirect = "<" } }, which shell_tree allows only after a while
-- loop's done.
local function shell_words(cmd)
  local stmts, words, word = {}, {}, nil
  local function add(text, quoted)
    word = word or {}
    local last = word[#word]
    if last and last.text and last.quoted == quoted then last.text = last.text .. text
    else word[#word + 1] = { text = text, quoted = quoted } end
  end
  local function end_word() if word then words[#words + 1] = word; word = nil end end
  local function end_stmt()
    end_word()
    if #words > 0 then stmts[#stmts + 1] = words end
    words = {}
  end
  local function ref(i)
    local name = cmd:match("^%$([?#$])", i)
    if name then return name, i + 2 end
    name = cmd:match("^%$([%a_][%w_]*)", i)
    if name then return name, i + 1 + #name end
    name = cmd:match("^%${([%a_][%w_]*)}", i)
    if name then return name, i + 3 + #name end
    -- ${NAME%pat} ${NAME%%pat} ${NAME#pat} ${NAME##pat}: pat only plain
    -- characters, * and ? (no quotes, \, [...], extglob or expansion).
    local op, pat
    name, op, pat = cmd:match("^%${([%a_][%w_]*)([%%#]?)([^}]*)}", i)
    if name and op ~= "" then
      if pat:sub(1, 1) == op then op, pat = op .. op, pat:sub(2) end
      if not pat:find("[%$`{}%[%]()\\'\"]") then return name, i + 3 + #name + #op + #pat, op, pat end
    end
  end
  -- The $( at i as a piece of the word; past its ), nil when it won't do.
  local function sub(i, quoted)
    local close = sub_end(cmd, i)
    local stmts = close and shell_words(cmd:sub(i + 2, close - 1))
    local tree = stmts and shell_tree(stmts, 1, false)
    if not tree or #tree == 0 then return nil end
    word = word or {}
    word[#word + 1] = { sub = tree, refs = rev_parse_refs(tree), quoted = quoted }
    return close + 1
  end
  local i, n = 1, #cmd
  while i <= n do
    local c = cmd:sub(i, i)
    if c == "'" then
      local close = cmd:find("'", i + 1, true)
      if not close then return nil end
      add(cmd:sub(i + 1, close - 1), true)
      i = close + 1
    elseif c == '"' then
      add("", true)
      i = i + 1
      while true do
        local d = cmd:sub(i, i)
        if d == "" or d == "`" then return nil end
        if d == '"' then i = i + 1; break end
        if d == "\\" and cmd:sub(i + 1, i + 1):match('^[%$`"\\]$') then
          add(cmd:sub(i + 1, i + 1), true)
          i = i + 2
        elseif d == "$" then
          local name, j, op, pat = ref(i)
          if name then
            word[#word + 1] = { var = name, op = op, pat = pat, quoted = true }
            i = j
          elseif cmd:sub(i + 1, i + 1) == "(" then
            i = sub(i, true)
            if not i then return nil end
          elseif cmd:sub(i + 1, i + 1):match("^[%w_{(@*#?!%$%-]$") then
            return nil
          else
            add("$", true)
            i = i + 1
          end
        else
          add(d, true)
          i = i + 1
        end
      end
    elseif c == "\\" then
      -- What a backslash escapes is that character (a Windows path's
      -- backslashes go too, which doesn't matter for matching).
      if cmd:sub(i + 1, i + 1) ~= "\n" then add(cmd:sub(i + 1, i + 1), false) end
      i = i + 2
    elseif c == "$" and cmd:sub(i + 1, i + 1) == "(" then
      i = sub(i, false)
      if not i then return nil end
    elseif c == "$" then
      local name, j, op, pat = ref(i)
      if not name then return nil end
      word = word or {}
      word[#word + 1] = { var = name, op = op, pat = pat, quoted = false }
      i = j
    elseif c == "|" or c == ";" or c == "\n" then
      end_stmt()
      i = i + (cmd:sub(i, i + 1) == "||" and 2 or 1)
    elseif c == "&" then
      if cmd:sub(i + 1, i + 1) ~= "&" then return nil end
      end_stmt()
      i = i + 2
    elseif c == ">" then
      local fd = ""
      if word and #word == 1 and not word[1].quoted and (word[1].text or ""):match("^[12*]$") then
        fd, word = word[1].text, nil
      else
        end_word()
      end
      local after = cmd:match("^>%s*/dev/null()", i) or cmd:match("^>%s*%$null()", i)
        or (fd == "2" and cmd:match("^>&1()", i))
      if not after or not cmd:sub(after, after):match("^[%s;&|]?$") then return nil end
      i = after
    elseif c == "<" then
      if cmd:sub(i + 1, i + 1):match("^[<(&>]$") then return nil end
      end_word()
      words[#words + 1] = { { redirect = "<" } }
      i = i + 1
    elseif c:match("[<(){}`]") then
      return nil
    elseif c:match("%s") then
      end_word()
      i = i + 1
    else
      add(c, false)
      i = i + 1
    end
  end
  end_stmt()
  return stmts
end

-- Shell variables that change what other commands do even when not
-- exported; assigning those (or anything already in the environment,
-- which commands inherit) isn't looking.
local SHELL_VARS = {
  PATH = true, IFS = true, CDPATH = true, HOME = true, GLOBIGNORE = true, PS4 = true, PWD = true, OLDPWD = true,
  POSIXLY_CORRECT = true, TIMEFORMAT = true, TMOUT = true, OPTIND = true, OPTERR = true,
}
local function settable(name)
  return not SHELL_VARS[name] and not name:match("^BASH") and os.getenv(name) == nil
end

-- The value of a variable `while read` sets: whatever the file holds;
-- also what a $(...) prints.
local UNKNOWN = {}
-- What a rev_parse_refs $(...) prints: words that aren't flags or globs.
local REFS = {}

-- $? $# $$: always a number, so never a flag, a glob or two words; "0"
-- stands for it. Not $- (letters, a flag's) or $! $@ $* $0-$9.
local SPECIAL = { ["?"] = "0", ["#"] = "0", ["$"] = "0" }

-- `v` with the shortest (# %) or longest (## %%) prefix (#) or suffix (%)
-- matching glob `pat` (shell_words': * ? and plain characters) taken off.
local function glob_trim(v, op, pat)
  local re = "^" .. pat:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
  -- Cut after k characters, the first k that matches: going up finds #'s
  -- shortest prefix and %%'s longest suffix, going down ## and %.
  local n, suffix = #v, op:sub(1, 1) == "%"
  local first, last, step = n, 0, -1
  if op == "#" or op == "%%" then first, last, step = 0, n, 1 end
  for k = first, last, step do
    if suffix then
      if v:sub(k + 1):match(re) then return v:sub(1, k) end
    elseif v:sub(1, k):match(re) then
      return v:sub(k + 1)
    end
  end
  return v
end

-- A $(...) piece's value, or a variable's (trimmed by its ${NAME%pat}).
-- A trim of what read reads, or of a $(...)'s, is UNKNOWN: a ref name
-- trimmed could start with -.
local function value_of(p, vars)
  if p.sub then return p.refs and REFS or UNKNOWN end
  if p.op then
    local v = vars[p.var]
    if v == UNKNOWN or v == REFS then return UNKNOWN end
    return v and glob_trim(v, p.op, p.pat)
  end
  return p.text or SPECIAL[p.var] or vars[p.var]
end

-- What word `w` becomes with `vars` filled in: unquoted, a value splits
-- on spaces (so B='--output x' can't hide a flag), quoted it doesn't.
-- nil when a name isn't set by the command itself (trimmed or not). Second, which of the
-- words an UNKNOWN value is in: "free" when it starts the word, isn't
-- quoted or follows a - (it could be any word, or several, or finish a
-- flag), else "inside". REFS is "inside" when it's the whole word, else
-- UNKNOWN.
local function expand(w, vars)
  local out, unknown, cur, any, unk = {}, {}, "", false, nil
  local function push() out[#out + 1] = cur; unknown[#out] = unk end
  for _, p in ipairs(w) do
    local v = value_of(p, vars)
    if v == nil then return nil end
    if v == REFS then
      for _, q in ipairs(w) do
        if q ~= p and q.text ~= "" then v = UNKNOWN end
      end
    end
    if v == REFS then
      unk, any = unk or "inside", true
    elseif v == UNKNOWN then
      unk = (not p.quoted or cur == "" or cur:match("^%-")) and "free" or unk or "inside"
      any = true
    elseif p.text or p.quoted then
      cur, any = cur .. v, true
    else
      local chunks = vim.split(v, "%s+")
      cur = cur .. chunks[1]
      any = any or chunks[1] ~= ""
      for k = 2, #chunks do
        if any then push() end
        cur, any, unk = chunks[k], chunks[k] ~= "", nil
      end
    end
  end
  if any then push() end
  return out, unknown
end

-- NAME and its value when word `w` is an assignment (B=origin/main).
local function assignment(w, vars)
  local first = w[1]
  if not (first and first.text and not first.quoted) then return nil end
  local name, value = first.text:match("^([%a_][%w_]*)=(.*)$")
  if not name then return nil end
  for k = 2, #w do
    local v = value_of(w[k], vars)
    if v == nil then return nil end
    if v == REFS or value == REFS then
      -- REFS only as the whole value (sha=$(git rev-parse x)).
      value = (value == "" and v) or (v == "" and value) or UNKNOWN
    else
      value = (v == UNKNOWN or value == UNKNOWN) and UNKNOWN or value .. v
    end
  end
  return name, value
end

local function keyword(w, kw) return w and #w == 1 and w[1].text == kw and not w[1].quoted end
local function literal(w) return w and #w == 1 and not w[1].quoted and w[1].text end
local function name_word(w)
  local name = literal(w)
  return name and name:match("^[%a_][%w_]*$") and name
end
local function all_text(w)
  for _, p in ipairs(w) do if not p.text then return false end end
  return true
end

-- The names `while [IFS=...] read [-r -s, -d -n -N -t X] [NAME...]`
-- reads into (REPLY when none), nil for any other while condition.
-- IFS= only changes how this read splits. -u FD, -p, -a, -e and -i
-- don't count.
local function read_names(s)
  local k = 2
  local first = s[k] and s[k][1]
  if first and first.text and not first.quoted and first.text:match("^IFS=") and all_text(s[k]) then k = k + 1 end
  if not keyword(s[k], "read") then return nil end
  k = k + 1
  while (literal(s[k]) or ""):match("^%-") do
    local o = literal(s[k])
    if o:match("^%-[dnNt]$") then
      if not (s[k + 1] and all_text(s[k + 1])) then return nil end
      k = k + 1
    elseif not o:match("^%-[rs]+$") then
      return nil
    end
    k = k + 1
  end
  local names = {}
  for m = k, #s do
    local name = name_word(s[m])
    if not name then return nil end
    names[#names + 1] = name
  end
  if #names == 0 then names[1] = "REPLY" end
  return names
end

-- shell_words' statements from i on as commands, for loops and while
-- read loops, up to the `done` that closes the loop they're in (`inside`:
-- "for" or "while"); where they end, and the word a while loop reads
-- from (done < FILE). nil when they don't parse.
function shell_tree(stmts, i, inside)
  local nodes = {}
  while i <= #stmts do
    local s = stmts[i]
    if keyword(s[1], "done") then
      if not inside then return nil end
      if #s == 1 then return nodes, i + 1 end
      if inside == "while" and #s == 3 and s[2][1].redirect then return nodes, i + 1, s[3] end
      return nil
    elseif keyword(s[1], "for") or keyword(s[1], "while") then
      -- for NAME in WORDS / while read NAME...; do BODY; done (do may share
      -- a line with BODY).
      local node = {}
      if keyword(s[1], "for") then
        local name = name_word(s[2])
        if not (name and keyword(s[3], "in")) then return nil end
        node.names, node.list = { name }, vim.list_slice(s, 4)
      else
        node.names, node.read = read_names(s), true
        if not node.names then return nil end
      end
      local d = stmts[i + 1]
      if not (d and keyword(d[1], "do")) then return nil end
      stmts[i + 1] = vim.list_slice(d, 2)
      local body, j, from = shell_tree(stmts, i + 1, node.read and "while" or "for")
      if not body then return nil end
      node.body, node.from = body, from
      nodes[#nodes + 1] = node
      i = j
    else
      if s[1] then nodes[#nodes + 1] = { words = s } end
      i = i + 1
    end
  end
  if inside then return nil end
  return nodes, i
end

-- Whether a while loop may read file `path`: not bash's /dev/tcp,
-- /dev/udp or another device, but /dev/null and /dev/stdin.
local function readable(path)
  return path ~= "" and (not path:match("^/+dev/") or path == "/dev/null" or path == "/dev/stdin")
end

local look_only_tree

-- Whether every $(...) in `words` only looks, with `vars` in scope; what
-- one sets stays in it, as in a subshell.
local function subs_look_only(words, vars)
  for _, w in ipairs(words) do
    for _, p in ipairs(w) do
      if p.sub and not look_only_tree(p.sub, setmetatable({}, { __index = vars })) then return false end
    end
  end
  return true
end

-- Whether every command in shell_tree's `nodes` only looks, with
-- `vars` the variables set so far. A for loop's body is checked once per
-- value of its list (once with "" when it's empty), a while read loop's
-- once with UNKNOWN; the $(...)s in a node first.
function look_only_tree(nodes, vars)
  for _, node in ipairs(nodes) do
    if not subs_look_only(node.words or node.list or {}, vars) or (node.from and not subs_look_only({ node.from }, vars)) then
      return false
    end
    if node.body then
      for _, name in ipairs(node.names) do if not settable(name) then return false end end
      local values = {}
      if node.read then
        if node.from then
          local ws, unknown = expand(node.from, vars)
          if not ws or #ws ~= 1 or unknown[1] or not readable(ws[1]) then return false end
        end
        values[1] = UNKNOWN
      else
        for _, w in ipairs(node.list) do
          local ws, unknown = expand(w, vars)
          if not ws then return false end
          for k, v in ipairs(ws) do values[#values + 1] = unknown[k] and UNKNOWN or v end
        end
      end
      if #values == 0 then values[1] = "" end
      for _, v in ipairs(values) do
        local scope = setmetatable({}, { __index = vars })
        for _, name in ipairs(node.names) do scope[name] = v end
        if not look_only_tree(node.body, scope) then return false end
      end
    elseif assignment(node.words[1], vars) then
      -- Only on its own (B=x; ...): FOO=1 cmd puts FOO in cmd's environment.
      for _, w in ipairs(node.words) do
        local name, value = assignment(w, vars)
        if not name or not settable(name) then return false end
        vars[name] = value
      end
    else
      local words, unknown = {}, {}
      for _, w in ipairs(node.words) do
        local ws, u = expand(w, vars)
        if not ws then return false end
        for k, v in ipairs(ws) do
          words[#words + 1] = v
          unknown[#words] = u[k]
        end
      end
      if not look_only_part(words, unknown) then return false end
    end
  end
  return true
end

-- Whether shell command `cmd` (a string, or an argv list) only reads:
-- every command in it - split on |, &&, || and ;, inside for loops,
-- while read loops and $(...) too - is one of the commands above without a flag
-- that writes (sed and awk with a program that only prints, gh api with
-- a GraphQL query and no mutation), once the
-- variables the command sets itself (B=x; ... $B, or ${B%/*} and the
-- other trims of a plain pattern),
-- $? $# $$ (numbers) and its loop variables are filled in (what read reads could be
-- anything: look_only_part, as is what a $(...) of them prints, but a
-- lone git rev-parse's); and nothing in it redirects - but a while
-- loop's done < FILE - runs a script block or another kind of subcommand
-- (shell_words). Reads the environment only to refuse assigning a
-- variable that's already in it.
function M.look_only_command(cmd)
  if type(cmd) == "table" then cmd = table.concat(cmd, " ") end
  if type(cmd) ~= "string" or not cmd:match("%S") then return false end
  local stmts = shell_words(cmd)
  local tree = stmts and shell_tree(stmts, 1, false)
  return tree ~= nil and #tree > 0 and look_only_tree(tree, {})
end

-- The agent's reason for what it's about to do: the last paragraph it
-- wrote before the tool call (the preamble asks it to say why before
-- changing a file its plan doesn't list), on one line. Pure.
function M.last_reason(text)
  local last
  for para in ((text or "") .. "\n\n"):gmatch("(.-)\n%s*\n") do
    if para:match("%S") then last = para end
  end
  if not last then return "the agent didn't say." end
  last = last:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #last > 300 then last = last:sub(1, 297) .. "..." end
  return last
end

-- The paths an ACP tool call names: its locations, else the usual
-- rawInput fields. Pure.
function M.tool_paths(tool)
  local out, seen = {}, {}
  local function add(p)
    if type(p) == "string" and p ~= "" and not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  for _, l in ipairs(type(tool.locations) == "table" and tool.locations or {}) do
    if type(l) == "table" then add(l.path) end
  end
  local raw = type(tool.rawInput) == "table" and tool.rawInput or {}
  for _, k in ipairs({ "path", "file_path", "filePath", "fileName", "source", "destination" }) do add(raw[k]) end
  return out
end

-- The main chat's part (compose's opts.orchestrator): it coordinates the
-- agents rather than planning and changing code itself: submit_plan,
-- start_story and start_fix refuse its calls (#86).
M.ORCHESTRATOR = [[This is the main chat: you coordinate. Planning and changing code - implementing a work item, fixing a pull request's review comments - is done by agents of its own, one per work item or PR, each in its own conversation, and the user approves each plan. So for that, start agents with start_agents: submit_plan, start_story and start_fix don't work here, even when the user asks you to plan or change code yourself - say an agent does it, and start one (their words go in its instructions). list_agents shows what each agent is doing and whose plan waits for the user; get_plan reads a plan; message_agent passes the user's instructions on to an agent. Approving a plan is the user's, never yours. For research or a question that needs digging through code (no work item or PR), start a task agent: start_agents with `task` - it only reads, shows on the Agents screen, and its answer comes back to you with a later message.]]

-- The text one message sends: the preamble (first message, or every
-- replayed one), the earlier conversation (replay only), the current view,
-- what the message references, and the message. Pure.
function M.compose(message, view_text, opts)
  opts = opts or {}
  local parts = {}
  if opts.first or opts.history then
    parts[#parts + 1] = M.PREAMBLE
    if opts.orchestrator then parts[#parts + 1] = M.ORCHESTRATOR end
  end
  if opts.history and #opts.history > 0 then
    parts[#parts + 1] = "## The conversation so far"
    for _, e in ipairs(opts.history) do
      if e.role == "you" then
        parts[#parts + 1] = "User: " .. e.text
      elseif e.role == "agent" and e.text and e.text ~= "" then
        parts[#parts + 1] = "You: " .. e.text
      end
    end
  end
  parts[#parts + 1] = "## Current view\n" .. (view_text or "(unknown)")
  if opts.refs and opts.refs ~= "" then parts[#parts + 1] = "## Referenced in the message\n" .. opts.refs end
  -- The main chat's task agents' answers since its last message (#143).
  if opts.task_results and #opts.task_results > 0 then
    local lines = { "## Results from task agents since your last message" }
    for _, r in ipairs(opts.task_results) do
      lines[#lines + 1] = "### " .. r.label .. (r.title and r.title ~= "" and (" (" .. r.title .. ")") or "")
        .. "\n" .. r.text
    end
    parts[#parts + 1] = table.concat(lines, "\n\n")
  end
  parts[#parts + 1] = "## Message\n" .. message
  return table.concat(parts, "\n\n")
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

-- A line for an entry's `tools` log, as stored: CRLF / CR made "\n",
-- trailing blanks and newlines trimmed, blank lines dropped. Its inner
-- newlines stay (a git error over two lines): render shows them as
-- indented continuation lines (#101).
function M.tool_line(s)
  s = tostring(s or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%s+$", "")
  while s:find("\n[ \t]*\n") do s = s:gsub("\n[ \t]*\n", "\n") end
  return s
end

-- ---------------------------------------------------------------------------
-- Reading the agent's output.

-- A fresh stream reader. `strip` is a list of Lua patterns: plain-text lines
-- matching any are dropped (e.g. a CLI's own tool-call log).
function M.stream_new(strip)
  return { pending = "", texts = {}, plain = {}, final = nil, session = nil, tools = {}, strip = strip or {} }
end

local function stripped(st, line)
  for _, pat in ipairs(st.strip) do
    local ok, hit = pcall(string.find, line, pat)
    if ok and hit then return true end
  end
  return false
end

-- A short label for one of the agent's own tool calls (stream-json
-- tool_use), e.g. "Read src/a.py". Our own azure-vicli tools are logged by
-- the bridge already, so they're skipped here.
local function tool_label(item)
  local name = tostring(item.name or "?")
  if name:find("azure%-vicli") then return nil end
  local input = type(item.input) == "table" and item.input or {}
  local detail = input.file_path or input.path or input.pattern or input.command or input.url or input.query
  if type(detail) == "string" then
    detail = detail:gsub("%s+", " ")
    if #detail > 60 then detail = detail:sub(1, 57) .. "..." end
    return name .. " " .. detail
  end
  return name
end

local function stream_line(st, line, decode)
  line = line:gsub("\r$", "")
  if line:sub(1, 1) == "{" then
    local ok, ev = pcall(decode, line)
    if ok and type(ev) == "table" then
      if type(ev.session_id) == "string" and ev.session_id ~= "" then st.session = ev.session_id end
      if ev.type == "assistant" and type(ev.message) == "table" then
        local chunk = {}
        for _, c in ipairs(type(ev.message.content) == "table" and ev.message.content or {}) do
          if type(c) == "table" and c.type == "text" and type(c.text) == "string" then
            chunk[#chunk + 1] = c.text
          elseif type(c) == "table" and c.type == "tool_use" then
            local label = tool_label(c)
            if label then st.tools[#st.tools + 1] = label end
          end
        end
        if #chunk > 0 then st.texts[#st.texts + 1] = table.concat(chunk, "") end
        return
      end
      -- The turn's end. An interrupted one's (Claude Code's
      -- "error_during_execution") has no `result` text: the turn still
      -- ends (`ended`), and what it streamed so far stays the answer.
      if type(ev.result) == "string" or ev.type == "result" then
        if type(ev.result) == "string" then st.final = ev.result end
        st.ended = true
        st.is_error = ev.is_error == true
        -- Claude Code's cost so far for this process (cumulative), and this
        -- turn's tokens.
        if type(ev.total_cost_usd) == "number" then st.cost_total = ev.total_cost_usd end
        if type(ev.usage) == "table" then
          local u = ev.usage
          st.tokens = (tonumber(u.input_tokens) or 0) + (tonumber(u.output_tokens) or 0)
            + (tonumber(u.cache_creation_input_tokens) or 0) + (tonumber(u.cache_read_input_tokens) or 0)
        end
        return
      end
      -- The answer to one of our control_requests (M.interrupt_line):
      -- "success" or "error", by request_id.
      if ev.type == "control_response" and type(ev.response) == "table" then
        local id = ev.response.request_id
        if type(id) == "string" then
          st.control = st.control or {}
          st.control[id] = tostring(ev.response.subtype or "")
        end
        return
      end
      if ev.type then return end  -- system/user/other stream events
    end
  end
  if not stripped(st, line) then st.plain[#st.plain + 1] = line end
end

-- How much the reader has seen: stream_feed reports a change in it.
local function stream_seen(st)
  local n = 0
  for _ in pairs(st.control or {}) do n = n + 1 end
  return #st.texts + #st.plain + #st.tools + (st.final and 1 or 0) + (st.ended and 1 or 0) + n
end

-- Feeds jobstart's on_stdout `data` (a list whose first element continues
-- the previous chunk's last line, and whose last element is a partial
-- line). Returns true when something visible changed.
function M.stream_feed(st, data, decode)
  if not data or #data == 0 then return false end
  local before = stream_seen(st)
  st.pending = st.pending .. data[1]
  for i = 2, #data do
    stream_line(st, st.pending, decode)
    st.pending = data[i]
  end
  return stream_seen(st) ~= before
end

-- Flushes the last partial line (call when the job exits).
function M.stream_finish(st, decode)
  if st.pending ~= "" then stream_line(st, st.pending, decode) end
  st.pending = ""
end

-- What to show right now: the final answer once there is one, else the
-- assistant text so far, else the plain text so far.
function M.stream_text(st)
  if st.final then return trim(st.final) end
  if #st.texts > 0 then return trim(table.concat(st.texts, "\n\n")) end
  -- Plain output: drop leading/trailing blank lines only.
  local lines = {}
  for _, l in ipairs(st.plain) do lines[#lines + 1] = l end
  while #lines > 0 and lines[1]:match("^%s*$") do table.remove(lines, 1) end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  return table.concat(lines, "\n")
end

-- A finished run's whole output, read the same way. Returns text,
-- session_id. `pattern` (chat.agent.session_pattern) finds a session id in
-- plain output.
function M.parse_answer(out, err, decode, pattern, strip)
  local st = M.stream_new(strip)
  local lines = {}
  for l in ((out or "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  -- A multi-line json envelope (pretty-printed) is one document.
  local whole = trim(out)
  if whole:sub(1, 1) == "{" then
    local ok, d = pcall(decode, whole)
    if ok and type(d) == "table" then lines = { (whole:gsub("\n", " ")) } end
  end
  for _, l in ipairs(lines) do stream_line(st, l, decode) end
  local text = M.stream_text(st)
  if st.final and st.is_error and text == "" then text = "(the agent reported an error)" end
  local session = st.session
  if not session and type(pattern) == "string" and pattern ~= "" then
    session = M.find_session(pattern, out, err)
  end
  return text, session, st.tools
end

function M.find_session(pattern, ...)
  for _, s in ipairs({ ... }) do
    local ok, id = pcall(string.match, s or "", pattern)
    if ok and type(id) == "string" and id ~= "" then return id end
  end
  return nil
end

-- The default chat.agent.stdin: each message as one line of Claude Code's
-- --input-format stream-json "user message", which a CLI started with it
-- reads until stdin closes - the agent's process stays running between
-- messages. {message_json} is the message already JSON-quoted.
M.STREAM_JSON_STDIN = '{"type":"user","message":{"role":"user","content":[{"type":"text","text":{message_json}}]}}'

-- The stdin line that stops the turn in progress of a CLI reading
-- STREAM_JSON_STDIN, leaving its process and session running: Claude Code
-- answers it with a control_response for `id`, then ends the turn with a
-- `result` event. `id` is ours (letters, digits, dashes), so no quoting.
function M.interrupt_line(id)
  return '{"type":"control_request","request_id":"' .. id .. '","request":{"subtype":"interrupt"}}'
end

function M.expand(template, vars, quote)
  if type(template) ~= "string" then return template end
  return (template:gsub("{([%w_]+)}", function(name)
    local v = vars[name]
    if v == nil then return nil end
    v = tostring(v)
    return quote and quote(v) or v
  end))
end

-- An agent's models as { label, value } pairs: a string is both.
function M.models(agent)
  local out = {}
  for _, m in ipairs((agent and agent.models) or {}) do
    if type(m) == "string" then out[#out + 1] = { label = m, value = m }
    elseif type(m) == "table" and m.value then out[#out + 1] = { label = m.label or m.value, value = m.value } end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Saved prompts.

-- The prompts in effect: the defaults, then the user's (a string replaces
-- or adds one, false removes one). Pure.
function M.prompts(user)
  local out = {}
  for k, v in pairs(M.DEFAULT_PROMPTS) do out[k] = v end
  for k, v in pairs(user or {}) do
    if v == false then out[k] = nil else out[k] = v end
  end
  return out
end

-- "/name rest" -> the prompt (plus rest), name; anything else -> text, nil.
function M.expand_prompt(text, prompts)
  local name, rest = text:match("^/([%w_%-]+)%s*(.-)%s*$")
  if name and prompts[name] then
    return prompts[name] .. (rest ~= "" and ("\n\n" .. rest) or ""), name
  end
  return text, nil
end

-- ---------------------------------------------------------------------------
-- References.

-- Every #123 / !123 / "PR 123" / "PR #123" in `text`, in order, without
-- repeats: { kind = "pr"|"any", id, s, e } (byte span, 1-based). "!" and
-- "PR" mean a pull request; a bare "#" is either - a PR in the list or
-- else a work item (resolved later). Pure.
function M.find_refs(text)
  local out, seen = {}, {}
  local function add(kind, id, s, e)
    out[#out + 1] = { kind = kind, id = tonumber(id), s = s, e = e }
    seen[s] = true
  end
  local i = 1
  while true do
    local s, e, id = text:find("[Pp][Rr]%s*#?(%d+)", i)
    if not s then break end
    if s == 1 or not text:sub(s - 1, s - 1):match("[%w_]") then add("pr", id, s, e) end
    i = e + 1
  end
  for s, sigil, id, e in text:gmatch("()([#!])(%d+)()") do
    local covered = false
    for _, r in ipairs(out) do if s >= r.s and s <= r.e then covered = true end end
    local prev = s > 1 and text:sub(s - 1, s - 1) or ""
    if not covered and not prev:match("[%w_&]") then add(sigil == "!" and "pr" or "any", id, s, e - 1) end
  end
  table.sort(out, function(a, b) return a.s < b.s end)
  local uniq, keys = {}, {}
  for _, r in ipairs(out) do
    local key = r.kind .. r.id
    if not keys[key] then keys[key] = true; uniq[#uniq + 1] = r end
  end
  return uniq, out
end

-- ---------------------------------------------------------------------------
-- The transcript.

-- Lines plus what each line is, for colouring: a "You" / "<agent>"
-- heading per turn (the name, then a dimmer " · on PR #101" / " ·
-- working… 4s"), your text, the agent's tool calls as they happen, then
-- its markdown answer. Returns lines, roles (line -> one of you_head, you,
-- agent_head, agent, agent_log, tool_read, tool_write, tool_err, note,
-- intro, fold, queued_head, queued; nil for
-- the gap between turns), name_end (heading line -> byte where its dim
-- part starts) and entry_at (line -> index into entries, or "q<n>" for
-- the n-th of `queue`). Pure.
--
-- `queue` (optional): the messages you sent while the agent was answering
-- ({ text, held, editing }, chat/run.lua's st.queue), drawn after the
-- conversation as "You · queued (1 of 2)" until they go out.
--
-- A finished answer with more than COLLAPSE_TOOLS tool calls shows them as
-- one summary line ("· 6 lookups, 2 changes"), keeping the ones that
-- failed, were declined, were allowed without asking or warn (✗ ✓ !) on
-- their own lines; an answer longer than FOLD_LINES shows its first
-- KEEP_LINES and "… N more lines" (role "fold"). An entry with `open` set
-- (<Tab> on it) shows everything.
--
-- No line it returns has a newline (#101): a tool call over several lines
-- shows them indented under its first (TOOL_MORE_LINES of them, then
-- "… N more lines", unless open), a heading's parts are joined onto one
-- line, and any other line with one is split.
M.COLLAPSE_TOOLS, M.FOLD_LINES, M.KEEP_LINES, M.TOOL_MORE_LINES = 3, 40, 30, 6
function M.render(entries, now, agent_label, queue)
  queue = queue or {}
  local lines, roles, name_end, entry_at = {}, {}, {}, {}
  local cur
  -- A buffer line can't hold a newline (nvim_buf_set_lines refuses it):
  -- one that still has one is split here, each part with the same role.
  local function add(l, role)
    l = tostring(l or "")
    if l:find("\n", 1, true) then
      for part in (l .. "\n"):gmatch("(.-)\n") do add(part, role) end
      return
    end
    lines[#lines + 1] = l; roles[#lines] = role; entry_at[#lines] = cur
  end
  local function add_text(t, role) for l in ((t or "") .. "\n"):gmatch("(.-)\n") do add(l, role) end end
  local function flat(s)
    s = tostring(s or "")
    return s:find("\n", 1, true) and (trim(s):gsub("%s*\n%s*", " ")) or s
  end
  local function head(name, extra, role)
    name, extra = flat(name), flat(extra)
    add(name .. (extra ~= "" and ("  \u{00B7}  " .. extra) or ""), role)
    name_end[#lines] = #name
  end
  -- One tool call: its first line, then any more (a git error over two
  -- lines) indented under it in the same colour, at most
  -- TOOL_MORE_LINES of them unless the entry is open.
  local function add_tool(tl, role, open)
    local first, rest = M.tool_line(tl):match("^([^\n]*)\n?(.*)$")
    add("  " .. first, role)
    if rest == "" then return end
    local more = {}
    for l in (rest .. "\n"):gmatch("(.-)\n") do more[#more + 1] = l end
    local shown = (not open and #more > M.TOOL_MORE_LINES + 1) and M.TOOL_MORE_LINES or #more
    for k = 1, shown do add("    " .. more[k], role) end
    if shown < #more then add("    \u{2026} " .. (#more - shown) .. " more lines  (<Tab> shows them)", role) end
  end
  if #entries == 0 and #queue == 0 then
    add("Chat", "agent_head")
    name_end[1] = 4
    add("", "intro")
    add_text("Ask about what you're looking at - \"triage this PR's comments\", \"what do you think about "
      .. "this comment?\", \"create a branch from develop for this work item\".\nType below; "
      .. require("azure-cli.keys").name("chat", "send") .. " sends. "
      .. "/triage, /review, /build, /standup run saved prompts (" .. require("azure-cli.keys").name("chat", "prompts")
      .. " lists them); /skills lists the agent's skills.", "intro")
    return lines, roles, name_end, entry_at
  end
  for i, e in ipairs(entries) do
    cur = nil
    if i > 1 then add("", nil) end
    cur = i
    if e.role == "you" then
      head("You", e.where or "", "you_head")
      add_text(e.text, "you")
    elseif e.role == "agent" then
      local bits = {}
      if e.status == "running" then
        bits[#bits + 1] = "working\u{2026} " .. math.max(0, (now or 0) - (e.started or now or 0)) .. "s"
      elseif e.status and e.status ~= "done" then
        bits[#bits + 1] = e.status
      end
      if e.mode == "replay" then bits[#bits + 1] = "replayed" end
      head(e.label or agent_label or "Agent", table.concat(bits, "  \u{00B7}  "), "agent_head")
      local tools = e.tools or {}
      local function role_of(t) return t:find("^\u{2717}") and "tool_err" or (t:find("^\u{270E}") and "tool_write" or "tool_read") end
      if not e.open and e.status ~= "running" and #tools > M.COLLAPSE_TOOLS then
        local reads, writes, kept = 0, 0, {}
        for _, tl in ipairs(tools) do
          if tl:find("^\u{2717}") or tl:find("^\u{2713}") or tl:find("^!") then
            kept[#kept + 1] = tl
          elseif tl:find("^\u{270E}") then
            writes = writes + 1
          else
            reads = reads + 1
          end
        end
        local parts = {}
        if reads > 0 then parts[#parts + 1] = reads .. " lookup" .. (reads == 1 and "" or "s") end
        if writes > 0 then parts[#parts + 1] = writes .. " change" .. (writes == 1 and "" or "s") end
        add("  " .. (writes > 0 and "\u{270E} " or "\u{00B7} ") .. table.concat(parts, ", ") .. "  (<Tab> shows them)",
          writes > 0 and "tool_write" or "tool_read")
        for _, tl in ipairs(kept) do add_tool(tl, role_of(tl), e.open) end
      else
        for _, tl in ipairs(tools) do add_tool(tl, role_of(tl), e.open) end
      end
      if #(e.tools or {}) > 0 and (e.text or "") ~= "" then add("", "agent") end
      if e.text and e.text ~= "" then
        local body = {}
        for l in (e.text .. "\n"):gmatch("(.-)\n") do body[#body + 1] = l end
        local kinds = M.answer_roles(body)
        local shown = (not e.open and #body > M.FOLD_LINES) and M.KEEP_LINES or #body
        for k = 1, shown do add(body[k], kinds[k]) end
        if shown < #body then add("\u{2026} " .. (#body - shown) .. " more lines  (<Tab> unfolds)", "fold") end
      end
    else
      add_text(e.text or "", "note")
    end
  end
  if #queue > 0 then
    local KEYS = require("azure-cli.keys")
    for i, q in ipairs(queue) do
      cur = nil
      if #lines > 0 then add("", nil) end
      cur = "q" .. i
      local bits = { "queued (" .. i .. " of " .. #queue .. ")" }
      if q.editing then
        bits[#bits + 1] = "editing in the input box"
      elseif q.held then
        bits[#bits + 1] = "held - " .. KEYS.name("chat", "open_ref") .. " sends it"
      end
      bits[#bits + 1] = KEYS.name("chat", "queue_drop") .. " cancels, " .. KEYS.name("chat", "queue_edit") .. " edits"
      head("You", table.concat(bits, "  \u{00B7}  "), "queued_head")
      add_text(q.display or q.text, "queued")
    end
  end
  return lines, roles, name_end, entry_at
end

-- An agent CLI's own log of its steps inside its answer (Copilot's
-- "● Read x.cs" with "│ ..." / "└ 35 lines read" under it, "× Run ..." for
-- a failed one): the role each of `lines` gets - agent_log for a step and
-- the non-blank lines under it, tool_err for a failed one, agent for the
-- answer itself. Pure.
local STEP = { "^%s*\u{25CF}%s", "^%s*\u{2713}%s", "^%s*\u{2714}%s" }
local FAILED = { "^%s*\u{00D7}%s", "^%s*\u{2717}%s", "^%s*\u{2718}%s" }
function M.answer_roles(lines)
  local roles, block = {}, nil
  for i, l in ipairs(lines) do
    local start
    for _, p in ipairs(STEP) do if l:find(p) then start = "agent_log" end end
    for _, p in ipairs(FAILED) do if l:find(p) then start = "tool_err" end end
    if start then
      block = start
    elseif l:match("^%s*$") then
      block = nil
    elseif block and not l:match("^%s") and not l:find("^[\u{2502}\u{2514}\u{251C}]") then
      block = nil  -- unindented text right after a step: the answer again
    end
    roles[i] = start or block or "agent"
  end
  return roles
end

-- A conversation's title for the history list: its first message, cut.
function M.title(entries)
  for _, e in ipairs(entries or {}) do
    if e.role == "you" then
      local t = (e.text or ""):gsub("%s+", " ")
      if #t > 60 then t = t:sub(1, 57) .. "..." end
      return t
    end
  end
  return "(empty)"
end

return M
