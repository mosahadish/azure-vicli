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

-- PR #101's row gets its linked work item (#3001) once the background read
-- lands, and gW on it opens #3001's detail view in a new tab.
local prrow
ok = vim.wait(15000, function()
  for i, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
    if l:find("#101 ", 1, true) and l:find("#3001", 1, true) then prrow = i return true end
  end
end, 100)
if not ok then return fail("PR #101's row never showed its linked work item #3001", dash) end
vim.api.nvim_set_current_win(vim.fn.bufwinid(dash))
vim.api.nvim_win_set_cursor(0, { prrow, 0 })
local dash_tab = vim.api.nvim_get_current_tabpage()
-- gW: a popup listing it with its state, type, title and assignee; <CR> on
-- it opens the detail view in a new tab.
feed("gW")
local wpop
ok = vim.wait(15000, function()
  wpop = float_text()
  return wpop ~= nil and wpop:find("#3001  [Active]  User Story  Throttle repeated login failures", 1, true) ~= nil
end, 100)
if not ok then return fail("gW on PR #101 didn't pop up its work item #3001\n" .. tostring(wpop)) end
print("== gW popup ==")
print(wpop)
-- At the cursor, not centred (nvim reports a cursor float as "win").
if vim.api.nvim_win_get_config(0).relative == "editor" then
  return fail("the PR dashboard's gW popup should open at the cursor, not mid-screen")
end
feed("<CR>")
local wview
ok = vim.wait(15000, function()
  wview = find_buf("azurecli-workitem")
  return wview ~= nil and text(wview):find("#3001", 1, true) ~= nil
end, 100)
if not ok then return fail("<CR> in gW's popup didn't open work item #3001") end
vim.cmd("tabclose")
vim.api.nvim_set_current_tabpage(dash_tab)
print("PRWI-SMOKE-OK")

-- <Space> folds like za: a PR dashboard section collapses and comes back.
local function header_row(b, pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if l:find(pat, 1, true) then return i, l end
  end
end
vim.api.nvim_set_current_win(vim.fn.bufwinid(dash))
vim.api.nvim_win_set_cursor(0, { header_row(dash, "\u{2500}\u{2500} Waiting for author"), 0 })
feed("<Space>")
local _, hl = header_row(dash, "\u{2500}\u{2500} Waiting for author")
if not hl:find("(collapsed)", 1, true) then return fail("<Space> didn't collapse the Waiting section: " .. hl) end
vim.api.nvim_win_set_cursor(0, { header_row(dash, "\u{2500}\u{2500} Waiting for author"), 0 })
feed("<Space>")
_, hl = header_row(dash, "\u{2500}\u{2500} Waiting for author")
if hl:find("(collapsed)", 1, true) then return fail("<Space> again didn't expand the Waiting section: " .. hl) end

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

-- gW in the reviewer: the same popup, and <CR> opens the item.
local review_tab = vim.api.nvim_get_current_tabpage()
vim.api.nvim_set_current_win(vim.fn.bufwinid(files))
feed("gW")
ok = vim.wait(15000, function()
  local p = float_text()
  return p ~= nil and p:find("#3001  [Active]", 1, true) ~= nil
end, 100)
if not ok then return fail("gW in the reviewer didn't pop up #3001\n" .. tostring(float_text())) end
-- ...in the middle of the screen, not at the cursor.
do
  local c = vim.api.nvim_win_get_config(0)
  local mid_col = math.floor((vim.o.columns - c.width) / 2)
  if c.relative ~= "editor" or math.abs(c.col - mid_col) > 1 then
    return fail("the reviewer's gW popup isn't centred: " .. vim.inspect({ c.relative, c.col, mid_col }))
  end
end
feed("<CR>")
local rview
ok = vim.wait(15000, function()
  rview = find_buf("azurecli-workitem")
  return rview ~= nil and vim.api.nvim_get_current_tabpage() ~= review_tab and text(rview):find("#3001", 1, true) ~= nil
end, 100)
if not ok then return fail("gW in the reviewer didn't open work item #3001") end
vim.cmd("tabclose")
vim.api.nvim_set_current_tabpage(review_tab)
print("REVIEW-WI-SMOKE-OK")

-- Code navigation (gd/gr/gf and the peek view) - the reviewer's least
-- automated surface, and the one whose helpers other review/* modules
-- reach through ctx. PR #101 adds src/throttle.py's is_locked() and calls
-- it from src/auth.py, so `gd` on that call has a real definition to find
-- in another file, through a real `git grep` over the fake clone.


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
goto_row(3001)
feed("<Space>")
if text(wis):find("#3011", 1, true) then return fail("<Space> didn't fold #3001 like za", wis) end
feed("<Space>")
if not text(wis):find("#3011", 1, true) then return fail("<Space> again didn't unfold #3001", wis) end
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

-- Linking updates both dashboards at once, from either side. gl/gL open a
-- popup picker: land on the line containing `want` and press <CR>.
local function choose_popup(want)
  local pwin, pline
  local found = vim.wait(10000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
          if l:find(want, 1, true) then pwin, pline = w, i return true end
        end
      end
    end
  end, 50)
  if not found then return fail("no popup offered " .. want .. "\n" .. tostring(float_text())) end
  vim.api.nvim_set_current_win(pwin)
  vim.api.nvim_win_set_cursor(pwin, { pline, 0 })
  feed("<CR>")
  return true
end
local function row_text(b, id)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if l:find("#" .. id .. " ", 1, true) then return l end
  end
  return ""
end
local function both(what, cond)
  if not vim.wait(15000, cond, 100) then
    return fail(what .. "\nwork items #3002: " .. row_text(wis, 3002) .. "\nPR #102: " .. row_text(dash, 102)
      .. "\nPR #104: " .. row_text(dash, 104) .. "\nwork items #3001: " .. row_text(wis, 3001))
  end
  return true
end
local function at_row(b, id)
  vim.cmd("tab sbuffer " .. b)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if l:find("#" .. id .. " ", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) return end
  end
end

-- gl on the work-items dashboard: PR !102 onto #3002 (which has !104).
at_row(wis, 3002)
feed("gl")
if not choose_popup("!102  ") then return end
if not both("gl on #3002 didn't show PR !102 on both dashboards", function()
  return row_text(wis, 3002):find("!104 +1", 1, true) and row_text(dash, 102):find("#3003 +1", 1, true)
end) then return end

-- gL on the PR dashboard: unlink #3002 from PR #102 again.
at_row(dash, 102)
feed("gL")
if not choose_popup("#3002  [") then return end
if not both("gL on PR #102 didn't drop #3002 from both dashboards", function()
  return not row_text(wis, 3002):find("+1", 1, true) and not row_text(dash, 102):find("+1", 1, true)
    and row_text(dash, 102):find("#3003", 1, true)
end) then return end

-- gl on the PR dashboard: link #3001 to PR #104 (whose item is #3002).
at_row(dash, 104)
feed("gl")
if not choose_popup("#3001  [") then return end
if not both("gl on PR #104 didn't show #3001 on both dashboards", function()
  return row_text(dash, 104):find("#3002 +1", 1, true) and row_text(wis, 3001):find("!101 +1", 1, true)
end) then return end
print("LINK-SMOKE-OK")

-- The chat panel (lua/azure-cli/chat/): tests/fake-chat-agent.py stands in
-- for Claude Code and speaks real MCP to `azure-cli.py --mcp`, which relays
-- to the panel's bridge. From auth.py's diff, on bob's thread: gq opens the
-- panel; "triage" sees the view (PR, file, line, thread), reads the threads
-- and drafts a reply into the batch queue (not posted); gm picks a model;
-- "branch" creates a branch on the fake origin linked to #3001 (no
-- question asked); "vote" asks first and the "Deny" goes back to the agent.
-- The panel follows into the dashboard's tab, and gq hides it.
do
  local CHAT = require("azure-cli.chat")
  local fake_chat = require("azure-cli.config").plugin_root() .. "/tests/fake-chat-agent.py"
  local agent_cmd = { "python3", fake_chat, "--mcp-config", "{mcp_config}", "--model", "{model}" }
  require("azure-cli").setup({ chat = { agent = {
    label = "Fake Claude", cmd = agent_cmd, models = { "fast", "smart" }, timeout_seconds = 60,
    followup = { cmd = vim.list_extend(vim.deepcopy(agent_cmd), { "--resume", "{session_id}" }) },
  } } })
  local answer
  local real_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    for i, it in ipairs(items) do
      local label = opts.format_item and opts.format_item(it) or tostring(it)
      if answer and label:find(answer, 1, true) then return cb(it, i) end
    end
    return cb(nil)
  end

  require("azure-cli").open_review(101)
  local lb
  ok = vim.wait(20000, function()
    lb = find_buf("azurecli-files")
    return lb ~= nil and vim.fn.bufwinid(lb) ~= -1 and text(lb):find("auth.py", 1, true) ~= nil
  end, 100)
  if not ok then return fail("the reviewer didn't open PR #101 for the chat") end
  vim.api.nvim_set_current_win(vim.fn.bufwinid(lb))
  for i, l in ipairs(vim.api.nvim_buf_get_lines(lb, 0, -1, false)) do
    if l:find("auth.py", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) break end
  end
  feed("<CR>")
  local dbuf
  ok = vim.wait(10000, function()
    dbuf = vim.api.nvim_get_current_buf()
    return dbuf ~= lb and require("azure-cli.state").chat_views ~= nil
      and (vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)[1] or "") ~= "Loading diff…"
  end, 50)
  -- The thread on new-side line 12.
  local tl
  for i, l in ipairs(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)) do
    if l:find("is_locked", 1, true) then tl = tl or i end
  end
  local map = require("azure-cli.review.pane").entry(dbuf)
  for bl = 1, vim.api.nvim_buf_line_count(dbuf) do
    local m = map and map.map and map.map[bl]
    if m and m.side == "R" and m.lineno == 12 then tl = bl break end
  end
  vim.api.nvim_win_set_cursor(0, { tl, 0 })
  local diff_win = vim.api.nvim_get_current_win()

  local function ask(msg)
    local st = require("azure-cli.state").chat
    local n = #st.entries
    local input = st.wins[vim.api.nvim_get_current_tabpage()].input
    vim.api.nvim_set_current_win(input)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(input), 0, -1, false, { msg })
    vim.cmd("stopinsert")
    feed("<CR>")
    local e
    local okw = vim.wait(30000, function()
      e = st.entries[#st.entries]
      return #st.entries == n + 2 and e.status ~= "running"
    end, 100)
    if not okw then return nil, "no answer to \"" .. msg .. "\": " .. vim.inspect(st.entries[#st.entries]) end
    return e
  end

  feed("gq")
  local st = require("azure-cli.state").chat
  local wins = st.wins[vim.api.nvim_get_current_tabpage()]
  if not (wins and vim.api.nvim_win_is_valid(wins.log) and vim.api.nvim_get_current_win() == wins.input) then
    return fail("gq didn't open the chat panel with the input focused")
  end
  if vim.api.nvim_win_get_position(wins.log)[2] <= vim.api.nvim_win_get_position(diff_win)[2] then
    return fail("the chat panel isn't on the right")
  end
  -- Straight from the input box gq focused, the way a user types: the
  -- view must still be the diff's, not the panel's own windows.
  local e, why = ask("triage this PR's comments")
  if not e then return fail(why) end
  local log = text(vim.api.nvim_win_get_buf(wins.log))
  if e.status ~= "done" or not e.text:find("FAKE-CHAT-RAN", 1, true)
      or not e.text:find("view: reviewer: a file's diff, PR 101, file src/auth.py, line 12, thread 5000", 1, true)
      or not e.text:find("message had the view: True", 1, true) or not e.text:find("model: fast", 1, true)
      or not e.text:find("threads: 3, active: 2", 1, true) or not log:find("\u{270E} draft_reply", 1, true) then
    return fail("the triage turn went wrong:\n" .. log)
  end
  local b = require("azure-cli.state").batch["101"]
  if not (b and b.on and b.items[#b.items].kind == "reply" and b.items[#b.items].text == "Agreed - a reason code it is.") then
    return fail("draft_reply didn't queue the reply: " .. vim.inspect(b))
  end
  for l in io.open(vim.env.AZVICLI_FAKE_WS .. "/calls.log"):read("*a"):gmatch("[^\n]+") do
    if l:find("--reply", 1, true) then return fail("a drafted reply was posted: " .. l) end
  end

  -- gm: the next turn uses "smart", and resumes the session.
  answer = "smart"
  vim.api.nvim_set_current_win(wins.log)
  feed("gm")
  vim.api.nvim_set_current_win(diff_win)
  e, why = ask("create a branch from main for 3001")
  if not e then return fail(why) end
  if not e.text:find("model: smart", 1, true) or not e.text:find("resumed: fake-chat-1", 1, true)
      or not e.text:find("Created branch feature/3001-throttle-login from main in widgets and linked it to #3001", 1, true) then
    return fail("the branch turn went wrong:\n" .. e.text)
  end
  local bare = vim.env.AZVICLI_FAKE_WS .. "/origin/widgets.git"
  if vim.fn.system({ "git", "--git-dir", bare, "rev-parse", "--verify", "-q", "refs/heads/feature/3001-throttle-login" }) == "" then
    return fail("the branch isn't on the fake origin")
  end

  -- vote asks first: "Deny" is what the agent hears back.
  answer = "Deny"
  vim.api.nvim_set_current_win(diff_win)
  e, why = ask("vote approve")
  if not e then return fail(why) end
  if not e.text:find("vote: The user declined", 1, true) then return fail("the vote wasn't asked/declined:\n" .. e.text) end
  print("== chat ==")
  print(text(vim.api.nvim_win_get_buf(wins.log)))

  -- Follows into the PR dashboard's tab; gq there hides it.
  vim.cmd("tab sbuffer " .. dash)
  ok = vim.wait(3000, function()
    local w = st.wins[vim.api.nvim_get_current_tabpage()]
    return w and vim.api.nvim_win_is_valid(w.log)
  end, 50)
  if not ok then return fail("the chat panel didn't follow into the dashboard's tab") end
  vim.api.nvim_set_current_win(vim.fn.bufwinid(dash))
  feed("gq")
  if st.visible or st.wins[vim.api.nvim_get_current_tabpage()] then return fail("gq didn't hide the chat") end
  vim.ui.select = real_select
  print("CHAT-SMOKE-OK")
end
print("DEMO-SMOKE-OK")
vim.cmd("qa!")
