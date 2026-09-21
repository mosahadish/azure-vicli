-- test-nav.lua: extracts def_score (and the tables it uses) out of
-- pr-review.lua by pattern, verbatim, and checks it on real code lines -
-- both the C# and Lua this repo is written in, plus a couple of other
-- languages the heuristic targets. Also checks git grep output parsing
-- against a real `git grep` run.
--
-- Usage: luajit test-nav.lua <pr-review.lua path>
-- Run with cwd inside the repo (run.sh runs it from the real azure-vicli
-- checkout, where AccountConfig exists in azure-cli.py).

vim = { pesc = function(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")) end,
        trim = function(s) return s:match("^%s*(.-)%s*$") end }

local path = arg[1]
assert(path, "usage: luajit test-nav.lua <pr-review.lua path>")
local src = io.open(path):read("*a")
-- Pull DEF_KEYWORDS/DECL_MODIFIERS/def_score verbatim out of the nav block.
local chunk = src:match("(local DEF_KEYWORDS = .-\nlocal NOT_A_TYPE = .-\nlocal function def_score.-\nend\n)")
assert(chunk, "def_score not found")
local def_score = assert(load(chunk .. "\nreturn def_score"))()

local cases = {
  -- {word, line, expect_definition}
  { "ComputeState", "        private async Task<PrState?> ComputeState(GitHttpClient client, GitPullRequest pr, Guid userId, AccountConfig accountConfig, Func<Task<List<GitPullRequestCommentThread>>> loadThreads)", true },
  { "ComputeState", "                PrState? state = await ComputeState(client, pr, userId, account, LoadThreads).ConfigureAwait(false);", false },
  { "ComputeState", "        /// Computes the state; see ComputeState for details.", false },
  { "AccountConfig", "    public sealed class AccountConfig", true },
  { "AccountConfig", "                AccountConfig newAccount = new AccountConfig", false },
  { "ClonesDirectory", "        public string? ClonesDirectory { get; set; }", true },
  { "ClonesDirectory", "                    newAccount.ClonesDirectory = accountNode.GetString(YamlFieldClonesDirectoryToken);", false },
  { "m_gate", "        private readonly SemaphoreSlim m_gate = new SemaphoreSlim(MaxConcurrentPullRequests);", true },
  { "m_gate", "            await m_gate.WaitAsync().ConfigureAwait(false);", false },
  { "MaxConcurrentPullRequests", "        private const int MaxConcurrentPullRequests = 8;", true },
  { "prefetch_content", "local function prefetch_content(pr, cb)", true },
  { "prefetch_content", "      prefetch_content(pr, function() prefetch_each(i + 1) end)", false },
  { "warm_all", "      warm_all(fresh)", false },
  { "resolve_current", "def resolve_current():", true },
  { "resolve_current", "    cur = resolve_current()", false },
  { "resolve_pat_into", "resolve_pat_into() {", false },  -- bash: no type/keyword before; acceptable miss
  { "PrState", "    public enum PrState", true },
  { "PrState", "        PrState State { get; set; }", false },  -- used as a type here
  { "M", "local M = {}", true },
  { "split_diff", "function M.split_diff(raw)", true },
}
local fails = 0
for _, c in ipairs(cases) do
  local word, line, want = c[1], c[2], c[3]
  local s = def_score(word, line)
  local got = s >= 4
  local mark = (got == want) and "ok  " or "FAIL"
  if got ~= want then fails = fails + 1 end
  print(string.format("%s score=%2d want=%-5s %s", mark, s, tostring(want), line:sub(1, 90)))
end
print(fails == 0 and "def_score: all cases pass" or ("def_score: " .. fails .. " unexpected"))

-- Grep parsing against real output. Scoped to azure-cli.py (where
-- AccountConfig is a real python identifier) so this doesn't also match
-- the literal string "AccountConfig" inside this test file once tests/ is
-- itself tracked by git.
local ref = "HEAD"
local p = io.popen("git grep -n -w -I -F --no-color -e AccountConfig " .. ref .. " -- azure-cli.py")
local hits = {}
for l in p:lines() do
  local prefix = ref .. ":"
  if l:sub(1, #prefix) == prefix then
    local file_path, lnum, text = l:sub(#prefix + 1):match("^(.-):(%d+):(.*)$")
    if file_path then hits[#hits + 1] = { path = file_path, lnum = tonumber(lnum), text = text } end
  end
end
p:close()
assert(#hits > 0, "grep hits")
for _, h in ipairs(hits) do assert(h.path:match("%.py$") and h.lnum > 0, "parsed " .. h.path) end
print("git grep parse ok: " .. #hits .. " hits, e.g. " .. hits[1].path .. ":" .. hits[1].lnum)

if fails > 0 then os.exit(1) end
