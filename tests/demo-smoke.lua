-- tests/demo-smoke.lua - the headless half of tests/demo.sh (--headless):
-- with the fake provider wired up by demo.sh, open the dashboard, wait for
-- the fake PRs to render (through the --serve daemon and the warm-all
-- prefetch), open PR 101 in the reviewer via the same path <CR> takes,
-- wait for its file list, and print both buffers plus a DEMO-SMOKE-OK
-- marker. Any timeout prints DEMO-SMOKE-FAIL with what was on screen.
-- Run by `nvim --headless -u <ws>/init.lua -c "luafile tests/demo-smoke.lua"`.

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function find_buf(ft)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == ft then return b end
  end
  return nil
end

local function fail(why, buf)
  print("DEMO-SMOKE-FAIL: " .. why)
  if buf then print(text(buf)) end
  vim.cmd("qa!")
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

vim.cmd("AzureCli dashboard")
local dash = find_buf("azurecli-dashboard")
if not dash then return fail("no dashboard buffer") end

local ok = vim.wait(15000, function()
  local t = text(dash)
  return t:find("#101", 1, true) ~= nil and t:find("#201", 1, true) ~= nil
end, 100)
if not ok then return fail("the dashboard never listed the fake PRs #101 and #201", dash) end
print("== dashboard ==")
print(text(dash))

-- Relative row numbers inside the box (5j/5k): the cursor row shows its
-- own line number, the row below it "1", and they follow the cursor.
local function number_at(b, lnum0)
  local ns = vim.api.nvim_get_namespaces()["azure_cli_row_numbers"]
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns or -1, { lnum0, 0 }, { lnum0, -1 }, { details = true })) do
    local vt = m[4].virt_text
    if vt and vt[1] then return vim.trim(vt[1][1]), m[3] end
  end
  return nil
end
local function numbered_and_fits(b, what)
  local w = vim.fn.bufwinid(b)
  vim.api.nvim_set_current_win(w)
  if vim.wo[w].number or vim.wo[w].relativenumber then
    return fail(what .. " still shows Neovim's own number column")
  end
  local function check_at_cursor()
    local cur, here, col, below
    -- CursorMoved (the repaint) fires from the event loop, so let it run.
    vim.wait(2000, function()
      cur = vim.api.nvim_win_get_cursor(w)[1]
      here, col = number_at(b, cur - 1)
      below = number_at(b, cur)
      return here == tostring(cur) and below == "1"
    end, 20)
    local line = vim.api.nvim_buf_get_lines(b, cur - 1, cur, false)[1]
    if here ~= tostring(cur) or below ~= "1" then
      return fail(what .. ": cursor row " .. cur .. " numbered " .. tostring(here) .. ", next " .. tostring(below))
    end
    -- The number sits just inside the left border, in blank reserved cells.
    if not line:sub(1, col):find("\u{2502} $") then
      return fail(what .. ": the number isn't just inside the border: " .. line)
    end
    return true
  end
  if not check_at_cursor() then return end
  -- A headless nvim never fires CursorMoved for keys fed from a script
  -- (it's raised by the main loop, which this script is running inside),
  -- so after moving, raise it the way an interactive session would.
  feed("j")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = b })
  if not check_at_cursor() then return end
  feed("k")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = b })
  local room = require("azure-cli.ui").text_width(w)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if vim.fn.strdisplaywidth(l) > room then
      return fail(what .. "'s box is wider than its text area (" .. room .. "): " .. l)
    end
  end
  return true
end
if not numbered_and_fits(dash, "the PR dashboard") then return end

require("azure-cli").open_review(101)
local files
ok = vim.wait(20000, function()
  files = find_buf("azurecli-files")
  if not files then return false end
  local t = text(files)
  return t:find("auth.py", 1, true) ~= nil and t:find("throttle.py", 1, true) ~= nil
end, 100)
if not ok then return fail("the reviewer never listed PR #101's files", files) end
print("== reviewer file list (PR #101) ==")
print(text(files))

-- Code navigation (gd/gr/gf and the peek view) - the reviewer's least
-- automated surface, and the one whose helpers other review/* modules
-- reach through ctx. PR #101 adds src/throttle.py's is_locked() and calls
-- it from src/auth.py, so `gd` on that call has a real definition to find
-- in another file, through a real `git grep` over the fake clone.

-- Every open floating window's text, joined - the peek view is two floats
-- side by side (the hit list, and the file at that revision previewed next
-- to it), so a check for "the hits are showing" has to look at all of them.
local function float_text()
  local parts = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      parts[#parts + 1] = text(vim.api.nvim_win_get_buf(w))
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "\n")
end

-- Open auth.py's diff from the file list, the way <CR> does.
local row
for i, l in ipairs(vim.api.nvim_buf_get_lines(files, 0, -1, false)) do
  if l:find("auth.py", 1, true) then row = i break end
end
if not row then return fail("no auth.py row in the file list", files) end
vim.api.nvim_set_current_win(vim.fn.bufwinid(files))
vim.api.nvim_win_set_cursor(0, { row, 0 })
feed("<CR>")

local diff
ok = vim.wait(15000, function()
  diff = vim.api.nvim_get_current_buf()
  return diff ~= files and text(diff):find("is_locked", 1, true) ~= nil
end, 100)
if not ok then return fail("auth.py's diff never showed is_locked()", diff) end
print("== reviewer diff (src/auth.py) ==")
print(text(diff))

-- Put the cursor on the is_locked call and ask for its definition.
local dline, dcol
for i, l in ipairs(vim.api.nvim_buf_get_lines(diff, 0, -1, false)) do
  local c = l:find("is_locked(", 1, true)
  if c then dline, dcol = i, c - 1 break end
end
if not dline then return fail("no is_locked( call in auth.py's diff", diff) end
vim.api.nvim_win_set_cursor(0, { dline, dcol })
feed("gd")

-- is_locked has exactly one definition-looking hit, so gd jumps straight
-- into throttle.py at the PR's revision rather than offering candidates.
local rev
ok = vim.wait(20000, function()
  rev = vim.api.nvim_get_current_buf()
  return rev ~= diff and text(rev):find("def is_locked", 1, true) ~= nil
end, 100)
if not ok then return fail("gd on is_locked() never opened its definition in throttle.py", rev) end
if vim.bo[rev].modifiable then return fail("the revision buffer should be read-only", rev) end
print("== gd -> revision buffer (src/throttle.py) ==")
print(text(rev))

-- <BS> walks back one jump, to the diff it came from.
feed("<BS>")
ok = vim.wait(10000, function()
  return vim.api.nvim_get_current_buf() == diff
end, 100)
if not ok then return fail("<BS> didn't walk back to auth.py's diff") end

-- gr lists every reference instead: the import, the call, and the
-- definition - more than one hit, so this one does open the peek.
vim.api.nvim_win_set_cursor(0, { dline, dcol })
feed("gr")
local hits
ok = vim.wait(20000, function()
  hits = float_text()
  return hits ~= nil and hits:find("throttle.py", 1, true) ~= nil and hits:find("auth.py", 1, true) ~= nil
end, 100)
if not ok then return fail("gr on is_locked() never listed its references\n" .. tostring(hits)) end
print("== gr hits ==")
print(hits)

print("NAV-SMOKE-OK")

-- gu ("follow up on my comments") and gA inside it. PR #101 has exactly one
-- thread of mine and it is `fixed`, so the active-only filter has something
-- real to hide: the row is listed, gA hides it, gA again brings it back.
feed("q")
ok = vim.wait(10000, function() return float_text() == nil end, 100)
if not ok then return fail("q didn't close the peek\n" .. tostring(float_text())) end

vim.api.nvim_set_current_win(vim.fn.bufwinid(files))
feed("gu")
local picker
ok = vim.wait(20000, function()
  picker = float_text()
  return picker ~= nil and picker:find("throttle.py", 1, true) ~= nil
end, 100)
if not ok then return fail("gu never listed my thread on throttle.py\n" .. tostring(picker)) end
print("== gu picker ==")
print(picker)

-- The preview pane marks the commented line itself: the row is my thread on
-- src/throttle.py line 4, so the marker has to land on line 4 of the
-- previewed file, not merely somewhere in it. Virtual text isn't buffer
-- text, so this reads the extmark rather than the rendered lines.
local function comment_marker()
  local ns = vim.api.nvim_get_namespaces()["azure_cli_followup"]
  if not ns then return nil end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      local b = vim.api.nvim_win_get_buf(w)
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
        local vt = m[4] and m[4].virt_text
        if vt and vt[1] and tostring(vt[1][1]):find("your comment", 1, true) then
          return vt[1][1], m[2] + 1
        end
      end
    end
  end
  return nil
end

local marker, marker_line
ok = vim.wait(15000, function()
  marker, marker_line = comment_marker()
  return marker ~= nil
end, 100)
if not ok then return fail("the gu preview never marked the commented line") end
if marker_line ~= 4 then
  return fail("the comment marker landed on line " .. tostring(marker_line) .. ", expected 4: " .. marker)
end
print("== gu preview marker == line " .. marker_line .. ": " .. marker)

local HIDDEN = "hidden by the active-only filter"
feed("gA")
ok = vim.wait(10000, function()
  picker = float_text()
  return picker ~= nil and picker:find(HIDDEN, 1, true) ~= nil
end, 100)
if not ok then return fail("gA in the gu picker didn't hide my resolved thread\n" .. tostring(picker)) end
print("== gu picker, active-only ==")
print(picker)

feed("gA")
ok = vim.wait(10000, function()
  picker = float_text()
  return picker ~= nil and picker:find("throttle.py", 1, true) ~= nil
     and picker:find(HIDDEN, 1, true) == nil
end, 100)
if not ok then return fail("gA again didn't bring my thread back\n" .. tostring(picker)) end

print("FOLLOWUP-SMOKE-OK")

-- gs on the work-items dashboard: the popup for story #3001 lists its three
-- tasks, mapped onto the Task workflow by category. Its first reachable
-- state (Implemented) is InProgress, so #3011 is already there, #3012 moves
-- To Do -> In Progress, and #3013 could move back from Done but stays
-- unchecked. Checking "also set children" and applying must move exactly
-- #3001 and #3012.
-- Wide enough for the work-items box (~104 cells) plus the number gutter,
-- so the fit check below is about the gutter, not the headless 80 columns.
vim.o.columns = 140
require("azure-cli").open_workitems()
local wis
ok = vim.wait(15000, function()
  wis = find_buf("azurecli-workitems")
  return wis ~= nil and text(wis):find("#3001", 1, true) ~= nil
end, 100)
if not ok then return fail("the work-items dashboard never listed #3001", wis) end
if not numbered_and_fits(wis, "the work-items dashboard") then return end
print("ROWNUM-SMOKE-OK")

-- The progress column counts #3001's tasks even with the tree off.
ok = vim.wait(15000, function() return text(wis):find("1/3 done", 1, true) ~= nil end, 100)
if not ok then return fail("#3001's row never showed 1/3 done", wis) end

-- T: the tree view puts #3001's tasks (alice's, so not in my list) under
-- it, and #3012's own sub-task (#3014) under that.
vim.api.nvim_set_current_win(vim.fn.bufwinid(wis))
feed("T")
ok = vim.wait(15000, function()
  local t = text(wis)
  return t:find("\u{25BE}#3001", 1, true) ~= nil
    and t:find("\u{251C} #3011 +%[In Progress%]") ~= nil
    and t:find("\u{2514}\u{25BE}#3012 +%[To Do%]") ~= nil
    and t:find("  \u{2514} #3014 +%[To Do%]") ~= nil
    and t:find("Alice Andersson", 1, true) ~= nil
end, 100)
if not ok then return fail("T never showed #3001's tasks and #3012's sub-task under it", wis) end
local t = text(wis)
if t:find("#3001", 1, true) > t:find("#3011", 1, true) or t:find("#3012", 1, true) > t:find("#3014", 1, true) then
  return fail("the tree listed a child before its parent", wis)
end
print("== work items, tree view ==")
print(t)
local saved = vim.fn.readfile(vim.fn.stdpath("data") .. "/azure-cli-workitems.json")
if not table.concat(saved, ""):find('"tree":%s*true') then
  return fail("T wasn't remembered: " .. table.concat(saved, ""))
end

-- za on #3001 folds its children away (▸) and back; zM/zR fold everything.
local function goto_row(id)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(wis, 0, -1, false)) do
    if l:find("#" .. id .. " ", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) return true end
  end
end
goto_row(3001)
feed("za")
t = text(wis)
if not (t:find("\u{25B8}#3001", 1, true) and not t:find("#3011", 1, true)) then
  return fail("za didn't fold #3001's children", wis)
end
feed("za")
if not text(wis):find("#3014", 1, true) then return fail("za again didn't unfold #3001", wis) end
goto_row(3014)
feed("za")
t = text(wis)
if not (t:find("\u{2514}\u{25B8}#3012", 1, true) and not t:find("#3014", 1, true)) then
  return fail("za on #3014 didn't fold its parent #3012", wis)
end
if not vim.api.nvim_get_current_line():find("#3012", 1, true) then
  return fail("za on a child didn't land on its parent: " .. vim.api.nvim_get_current_line())
end
feed("zM")
if text(wis):find("#3011", 1, true) then return fail("zM left children showing", wis) end
feed("zR")
if not text(wis):find("#3014", 1, true) then return fail("zR didn't unfold everything", wis) end
print("TREE-SMOKE-OK")
local wrow
for i, l in ipairs(vim.api.nvim_buf_get_lines(wis, 0, -1, false)) do
  if l:find("#3001", 1, true) then wrow = i break end
end
vim.api.nvim_set_current_win(vim.fn.bufwinid(wis))
vim.api.nvim_win_set_cursor(0, { wrow, 0 })
feed("gs")
local popup
ok = vim.wait(15000, function()
  popup = float_text()
  return popup ~= nil and popup:find("#3012 Task  To Do \u{2192} In Progress", 1, true) ~= nil
    and popup:find("#3013 Task  Done \u{2192} In Progress", 1, true) ~= nil
    and popup:find("#3011 Task  In Progress  (already In Progress)", 1, true) ~= nil
    and popup:find("Reason:  \u{2039}", 1, true) ~= nil
end, 100)
if not ok then return fail("gs's popup never mapped #3001's tasks\n" .. tostring(popup)) end
print("== gs popup ==")
print(popup)
if not (popup:find("[ ] Also set children (2 of 4)", 1, true)
    and popup:find("      [ ] #3014 Task  To Do \u{2192} In Progress", 1, true)) then
  return fail("the children box should start unchecked with #3012 and its sub-task #3014 picked\n" .. popup)
end
local pbuf = vim.api.nvim_get_current_buf()
for i, l in ipairs(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)) do
  if l:find("Also set children", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) break end
end
feed("<Space>")
if not float_text():find("[x] Also set children (2 of 4)", 1, true) then
  return fail("<Space> didn't check the children box\n" .. float_text())
end
feed("<CR>")
local function wi_state(id)
  local out = vim.fn.system(require("azure-cli.config").provider_argv("--wi-detail", id))
  local okj, data = pcall(vim.json.decode, out)
  return okj and type(data) == "table" and data.item and data.item.state or out
end
local got
ok = vim.wait(15000, function()
  got = { wi_state("3001"), wi_state("3011"), wi_state("3012"), wi_state("3013"), wi_state("3014") }
  return got[1] == "Implemented" and got[3] == "In Progress" and got[5] == "In Progress"
end, 200)
if not ok or got[2] ~= "In Progress" or got[4] ~= "Done" then
  return fail("gs set the wrong states: " .. table.concat(got, ", "))
end
-- The tree picks the child's new state up without a refresh.
ok = vim.wait(10000, function()
  return text(wis):find("#3012 +%[In Progress%]") ~= nil
end, 100)
if not ok then return fail("the tree still shows #3012's old state", wis) end

-- gs on a visual selection (#3003, a Resolved story, down to #3002, a New
-- bug): #3003 picks the state; #3002 can't reach Closed (the first state),
-- so the box starts off; cycling to Active maps and checks #3002 too.
local function row_of(id)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(wis, 0, -1, false)) do
    if l:find("#" .. id .. " ", 1, true) then return i end
  end
end
vim.api.nvim_set_current_win(vim.fn.bufwinid(wis))
local r1, r2 = row_of(3003), row_of(3002)
vim.api.nvim_win_set_cursor(0, { r1, 0 })
feed("V" .. (r2 - r1) .. "jgs")
ok = vim.wait(15000, function()
  popup = float_text()
  return popup ~= nil and popup:find("#3002 Bug  New  (no matching state)", 1, true) ~= nil
end, 100)
if not ok then return fail("visual gs didn't list #3002 as another selected item\n" .. tostring(popup)) end
if not popup:find("[ ] Also set the other selected items (0 of 1)", 1, true) then
  return fail("visual gs's box should be off while #3002 can't move\n" .. popup)
end
pbuf = vim.api.nvim_get_current_buf()
for i, l in ipairs(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)) do
  if l:find("^State:") then vim.api.nvim_win_set_cursor(0, { i, 0 }) break end
end
feed("l")
ok = vim.wait(10000, function()
  popup = float_text()
  return popup:find("[x] Also set the other selected items (1 of 1)", 1, true) ~= nil
    and popup:find("[x] #3002 Bug  New \u{2192} Active", 1, true) ~= nil
end, 100)
if not ok then return fail("cycling to Active didn't check #3002\n" .. tostring(popup)) end
print("== visual gs popup ==")
print(popup)
feed("<CR>")
ok = vim.wait(15000, function() return wi_state("3003") == "Active" and wi_state("3002") == "Active" end, 200)
if not ok then return fail("visual gs set " .. wi_state("3003") .. ", " .. wi_state("3002")) end
print("SELECTION-SMOKE-OK")

-- Linked PRs: #3001's row carries !101, and its detail view lists the PR
-- with its title, status and branches.
local row3001
for _, l in ipairs(vim.api.nvim_buf_get_lines(wis, 0, -1, false)) do
  if l:find("#3001 ", 1, true) then row3001 = l break end
end
if not (row3001 and row3001:find("!101", 1, true)) then
  return fail("#3001's row doesn't show its linked PR: " .. tostring(row3001), wis)
end
for i, l in ipairs(vim.api.nvim_buf_get_lines(wis, 0, -1, false)) do
  if l:find("#3001 ", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) break end
end
feed("<CR>")
local view
ok = vim.wait(15000, function()
  view = find_buf("azurecli-workitem")
  return view ~= nil and text(view):find("Pull Requests (1)", 1, true) ~= nil
end, 100)
if not ok then return fail("#3001's detail view never listed its pull requests", view) end
local vt = text(view)
if not (vt:find("  !101    active     Throttle failed logins", 1, true)
    and vt:find("widgets  feature/login-throttle \u{2192} main  \u{00B7}  Alice Andersson", 1, true)) then
  return fail("the detail view's PR block is wrong", view)
end
print("== detail view, Pull Requests ==")
print(vt:match("Pull Requests.-\n\n") or vt)
-- gR from the detail view opens !101 in the reviewer (it's in the PR list).
local before = vim.api.nvim_get_current_tabpage()
feed("gR")
ok = vim.wait(15000, function()
  if vim.api.nvim_get_current_tabpage() == before then return false end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == "azurecli-files" and text(b):find("throttle.py", 1, true) then return true end
  end
  return false
end, 100)
if not ok then return fail("gR didn't open !101 in the reviewer (current ft: " .. vim.bo.filetype .. ")") end
print("PRS-SMOKE-OK")
print("GS-SMOKE-OK")
print("DEMO-SMOKE-OK")
vim.cmd("qa!")
