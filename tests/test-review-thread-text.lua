-- test-review-thread-text.lua: review/thread_text.lua - how a comment reads
-- in the K popup: a markdown link as its text with the address under the
-- comment, "[KEY]: value" reference lines left out, text wrapped under the
-- gutter (an address never broken), and the popup's colours.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-review-thread-text.lua
--
-- Prints "all thread text tests passed" / exits non-zero.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

local TT = require("azure-cli.review.thread_text")
local G = "\u{2502}   "

-- A SonarQube bot's comment, as in the screenshot that asked for this.
local sonar = "Prefer 'static readonly' fields over constant array arguments if the called method is called "
  .. "repeatedly and is not mutating the passed array (external_roslyn:CA1861)\n\n"
  .. "[See it in SonarQube](https://codeanalysis.example.com/sonarqube/project/issues?id=SMT-WSC&pullRequest=51547"
  .. "&issues=4fac996b&open=4fac996b)\n\n[ISSUE_KEY]: 4fac996b-0ff6-4f4c-8d6f-bf371c381616\n[PROJECT_KEY]: SMT-WSC\n"
local text, urls = TT.clean(sonar)
check("clean: the link reads as its text and a number", text[3] == "See it in SonarQube [1]", vim.inspect(text))
check("clean: its address kept", #urls == 1 and urls[1]:find("^https://codeanalysis") ~= nil, vim.inspect(urls))
check("clean: reference lines and trailing blanks gone", #text == 3, vim.inspect(text))

local lines = TT.comment_lines(sonar, G, 60)
local widest = 0
for _, l in ipairs(lines) do
  check("every line has the gutter: " .. l:sub(1, 30), l:sub(1, #G) == G)
  if not l:find("://", 1, true) then widest = math.max(widest, vim.fn.strdisplaywidth(l)) end
end
check("wrapped to 60 cells", widest <= 60 and widest > 40, widest)
check("the address on a line of its own, whole", lines[#lines] == G .. "[1] " .. urls[1], lines[#lines])

check("wrap keeps the line's indent", vim.deep_equal(TT.wrap("  - one two three four", 12), { "  - one two", "  three four" }),
  vim.inspect(TT.wrap("  - one two three four", 12)))
check("no width: unwrapped", #TT.comment_lines("a b c", G, nil) == 1)
check("an empty comment still has a line", vim.deep_equal(TT.comment_lines("", G, 40), { G }))

-- The colours: header muted, author accent, address muted.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "\u{250C}\u{2500} thread [active]", "\u{2502} Bot:", G .. "hi",
  G .. "[1] https://x.example/y" })
TT.paint(buf)
local ns = vim.api.nvim_create_namespace("azure_cli_thread_popup")
local got = {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do got[m[2]] = m[4].hl_group end
check("paint: header, author, address", got[0] == "AzureCliMuted" and got[1] == "AzureCliAccent" and got[2] == nil
  and got[3] == "AzureCliMuted", vim.inspect(got))

-- "@<GUID>" mentions read as names: a comment author's, the signed-in
-- user's (state.whoami), else "@someone".
require("azure-cli.hosts").remember(nil, "AAAA-1111", "Bob Brown")
require("azure-cli.state").whoami = { ["org|proj"] = { id = "BBBB-2222", displayName = "Demo User" } }
check("mentions: an author's id, any case", TT.mentions("ask @<AAAA-1111> please") == "ask @Bob Brown please")
check("mentions: the signed-in user", TT.mentions("@<bbbb-2222> what?") == "@Demo User what?")
check("mentions: nobody seen", TT.mentions("cc @<cccc-3333>") == "cc @someone")
check("clean: mentions resolved in comment text", TT.clean("hi @<aaaa-1111>")[1] == "hi @Bob Brown")

if fails > 0 then
  print(fails .. " thread text test(s) failed")
  os.exit(1)
end
print("all thread text tests passed")
