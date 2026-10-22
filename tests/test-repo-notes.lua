-- test-repo-notes.lua: chat/repo_notes.lua - remember and forget write a
-- repository's notes file and read it back (a hand-edited one too), their
-- undo, the cap, the key scheme, and the notes reaching an agent's first
-- message (compose, start_story's answer) once per process:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-repo-notes.lua
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local NOTES = require("azure-cli.chat.repo_notes")
local TOOLS = require("azure-cli.chat.tools")
local CORE = require("azure-cli.chat.core")
local STATE = require("azure-cli.state")

STATE.PR_LIST_CACHE = { prs = {
  { id = 7, key = "o~web~7", host = "github", repo = "web", project = "o", org = "https://api.github.com" },
  { id = 8, key = "p~web~8", host = "github", repo = "web", project = "p", org = "https://api.github.com" },
  { id = 101, repo = "My Repo", project = "Proj", org = "https://dev.azure.com/x/" },
} }

local logged = {}
local env = { log = function(l) logged[#logged + 1] = l end, confirm = function(_, cb) cb(false) end,
  view = function() return {} end }
local function call(name, args)
  local text, is_err
  TOOLS.call(name, args, env, function(t, e) text, is_err = t, e end)
  return text, is_err
end

-- --- the tools' shape --------------------------------------------------------
check("remember and forget: writes that don't ask", TOOLS.by_name.remember.risk == "write"
  and TOOLS.by_name.forget.risk == "write" and TOOLS.permission(TOOLS.by_name.remember, nil) == "allow")

-- --- keys ---------------------------------------------------------------------
local o_web, p_web = NOTES.locate("o/web"), NOTES.locate("p/web")
check("locate: owner/repo picks that owner's", o_web and o_web.owner == "o" and p_web and p_web.owner == "p")
check("key: GitHub repos of two owners don't share a file", NOTES.path(o_web) ~= NOTES.path(p_web)
  and NOTES.key(o_web) == "github~o~web", NOTES.key(o_web))
local az = NOTES.locate("my repo")
check("key: Azure has org, project and repo, escaped and lowercased", az
  and NOTES.key(az) == "azure~x~proj~my%20repo", az and NOTES.key(az))
check("of_pr: the same repository as locate", NOTES.key(NOTES.of_pr(STATE.PR_LIST_CACHE.prs[3])) == NOTES.key(az))
check("of_snap: a GitHub issue by its key", NOTES.key(NOTES.of_snap({ board = "github",
  work_item = { id = 3, key = "o~web~3" } })) == "github~o~web")
check("of_target: an agent's PR's repository (the Agents screen's gn)",
  NOTES.key(NOTES.of_target({ pr_key = "o~web~7", pr_id = 7 })) == "github~o~web")
check("of_snap: an Azure work item has none", NOTES.of_snap({ work_item = { id = 3001 } }) == nil)
local _, err = NOTES.locate("nowhere")
check("locate: an unknown bare name with no project known says so", err ~= nil, err)

-- --- remember / forget --------------------------------------------------------
local text, is_err = call("remember", { repo = "o/web", note = "  The default   branch is master " })
check("remember: noted", not is_err and text:find("o/web", 1, true), text)
local lines = vim.fn.readfile(NOTES.path(o_web))
check("remember: a heading, then a \"- \" line, spaces squashed", lines[1] == "# o/web"
  and lines[#lines] == "- The default branch is master", vim.inspect(lines))
call("remember", { repo = "o/web", note = "Tests run on nvim 0.9.5 and 0.12" })
text, is_err = call("remember", { repo = "o/web", note = "the default branch is MASTER" })
check("remember: the same note again is refused", is_err and text:find("already", 1, true), text)
text, is_err = call("remember", { repo = "o/web", note = string.rep("x", 400) })
check("remember: one short fact only", is_err, text)
check("read: both, oldest first", vim.deep_equal(NOTES.read(o_web),
  { "The default branch is master", "Tests run on nvim 0.9.5 and 0.12" }), vim.inspect(NOTES.read(o_web)))
local audit = require("azure-cli.chat.store").audit()
local last = audit[#audit]
check("remember: in the audit log with its undo", last.tool == "remember" and last.undo and last.undo.op == "forget_note")

local undone
TOOLS.undo(last, function(ok, msg) undone = { ok, msg } end)
check("undo remember: the note goes", undone[1] and #NOTES.read(o_web) == 1
  and NOTES.read(o_web)[1] == "The default branch is master", vim.inspect(NOTES.read(o_web)))

call("remember", { repo = "o/web", note = "CRLF: install.sh" })
call("remember", { repo = "o/web", note = "CRLF: cache.lua" })
text, is_err = call("forget", { repo = "o/web", note = "CRLF" })
check("forget: a part two notes contain is ambiguous", is_err and text:find("2 notes", 1, true), text)
text, is_err = call("forget", { repo = "o/web", note = "install.sh" })
check("forget: the one note containing it", not is_err and text:find("CRLF: install.sh", 1, true)
  and not vim.tbl_contains(NOTES.read(o_web), "CRLF: install.sh"), text)
audit = require("azure-cli.chat.store").audit()
TOOLS.undo(audit[#audit], function(ok, msg) undone = { ok, msg } end)
check("undo forget: the note is back", undone[1] and vim.tbl_contains(NOTES.read(o_web), "CRLF: install.sh"))
text, is_err = call("forget", { repo = "o/web", note = "not there" })
check("forget: no such note", is_err, text)

-- --- a hand-edited file -------------------------------------------------------
vim.fn.writefile({ "# Web\r", "\r", "Some prose the user wrote.\r", "* starred note\r", "  -   indented one  \r",
  "-no space, not a note\r", "- \r", "" }, NOTES.path(p_web), "b")
check("read: a hand-edited file - '* ' and indented lines, CRLF, prose skipped",
  vim.deep_equal(NOTES.read(p_web), { "starred note", "indented one" }), vim.inspect(NOTES.read(p_web)))
call("remember", { repo = "p/web", note = "new one" })
local raw = vim.fn.readfile(NOTES.path(p_web), "b")
check("remember: the user's lines and CRLF endings stay", raw[3] == "Some prose the user wrote.\r"
  and raw[#raw - 1] == "- new one\r" and raw[#raw] == "", vim.inspect(raw))

-- --- the cap ------------------------------------------------------------------
local many = {}
for i = 1, 60 do many[i] = "note " .. i end
local b = NOTES.block("o/web", many)
local _, n = b:gsub("\n%- ", "")
check("block: the last " .. NOTES.KEEP .. " notes", n == NOTES.KEEP and b:find("- note 60", 1, true)
  and b:find("- note 21\n", 1, true) and not b:find("- note 20\n", 1, true), b)
local big = {}
for i = 1, 40 do big[i] = i .. string.rep("y", 200) end
b = NOTES.block("o/web", big)
check("block: at most " .. NOTES.MAX_BYTES .. " bytes, the newest kept", #b <= NOTES.MAX_BYTES + 100
  and b:find("40" .. string.rep("y", 200), 1, true) ~= nil, #b)
check("block: nothing for no notes", NOTES.block("o/web", {}) == nil)

-- --- reaching the agent -------------------------------------------------------
local conv = {}
local first = NOTES.once(conv, NOTES.of_snap({ pr = { id = 7, key = "o~web~7" } }))
check("once: the block, headed for its repository", first and first:find("^Notes on o/web from earlier agents:\n%- ")
  and first:find("- The default branch is master", 1, true), first)
check("once: not twice in one process", NOTES.once(conv, o_web) == nil)
local msg = CORE.compose("hi", "Screen: x", { first = true, repo_notes = first })
check("compose: the notes go in the message, before it", msg:find(first, 1, true)
  and msg:find(first, 1, true) < msg:find("## Message\nhi", 1, true))
check("compose: none when there are none", not CORE.compose("hi", "v", {}):find("Notes on", 1, true))
check("preamble: tells agents to remember", CORE.PREAMBLE:find("remember", 1, true) ~= nil)

local got
local wrapped = NOTES.with_notes(function(r) got = r end, {}, "o/web", "github")
wrapped({ directory = "/x" })
check("with_notes: start_story's answer gets them", got.repo_notes and got.repo_notes:find("Notes on o/web", 1, true))
wrapped = NOTES.with_notes(function(r, e) got = { r, e } end, {}, "o/web", "github")
wrapped(nil, "failed")
check("with_notes: not on an error", got[1] == nil and got[2] == "failed")

-- --- gn on the Agents screen --------------------------------------------------
do
  require("azure-cli.config").setup({ chat = { agent = { label = "fake", cmd = { "true" } } } })
  local CHAT = require("azure-cli.chat")
  local c = CHAT.conversation("pr-github-o~web~7", { target = { pr_key = "o~web~7", pr_id = 7 }, label = "!7" })
  c.entries = { { role = "you", text = "/plan !7" }, { role = "agent", text = "x", status = "done" } }
  local AV = require("azure-cli.chat.agents_view")
  AV.open()
  local av = AV.current()
  for i, l in ipairs(vim.api.nvim_buf_get_lines(av.buf, 0, -1, false)) do
    if l:find("!7", 1, true) then vim.api.nvim_win_set_cursor(av.win, { i, 0 }) end
  end
  vim.api.nvim_feedkeys("gn", "x", false)
  local name = vim.api.nvim_buf_get_name(0)
  check("gn: the row's repository's notes file, in a split", name == NOTES.path(o_web)
    and vim.api.nvim_get_current_win() ~= av.win
    and vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "# o/web", name)
  vim.cmd("close")
end

pcall(vim.fn.delete, NOTES.path(o_web))
pcall(vim.fn.delete, NOTES.path(p_web))
if fails > 0 then
  print(fails .. " failure(s)")
  vim.cmd("cq")
end
print("all repo-notes tests passed")
vim.cmd("qa!")
