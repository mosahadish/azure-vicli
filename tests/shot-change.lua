-- tests/shot-change.lua: the scene for docs/images/chat-ask-why.png - the
-- change viewer on a made-up change for #3001, with a question answered under
-- one of its lines (seeded in the questions file, as ga would leave it).
local dir = vim.fn.stdpath("cache") .. "/azure-cli/fix-worktrees/widgets-wi3001"
vim.fn.mkdir(dir, "p")
local why = require("azure-cli.chat.store").root() .. "/why/widgets-wi3001.json"
vim.fn.mkdir(vim.fn.fnamemodify(why, ":h"), "p")
vim.fn.writefile({ vim.json.encode({ { id = "c1", file = "src/auth.py", line = 13, side = "R",
  anchor = "if is_locked(name):", question = "Why here and not in register()?", status = "answered", agent = "Copilot",
  answer = "register() never checks a password, so there's nothing to throttle there. The lock only matters where a "
    .. "guess is checked - login() - and checking it before the hash keeps a locked account cheap to reject." } }) }, why)
local raw = {
  "diff --git a/src/auth.py b/src/auth.py", "--- a/src/auth.py", "+++ b/src/auth.py", "@@ -1,12 +1,19 @@",
  " import hashlib", " ", "+from throttle import is_locked, record_failure", "+", " USERS = {}", " ", " ",
  " def register(name, password):", "     USERS[name] = hashlib.sha256(password.encode()).hexdigest()", " ", " ",
  " def login(name, password):", "+    if is_locked(name):", "+        return False",
  "     digest = hashlib.sha256(password.encode()).hexdigest()", "-    return USERS.get(name) == digest",
  "+    ok = USERS.get(name) == digest", "+    if not ok:", "+        record_failure(name)", "+    return ok",
  "diff --git a/src/throttle.py b/src/throttle.py", "new file mode 100644", "--- /dev/null", "+++ b/src/throttle.py",
  "@@ -0,0 +1,3 @@", "+LIMIT = 5", "+def is_locked(name):", "+    return False",
}
require("azure-cli.chat.changes").open("Proposed change - #3001", dir, raw)
vim.defer_fn(function()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l == "    if is_locked(name):" then vim.api.nvim_set_current_win(w) vim.api.nvim_win_set_cursor(w, { i, 0 }) end
    end
  end
end, 500)
