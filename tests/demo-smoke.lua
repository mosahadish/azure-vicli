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
  -- Neovim 0.9 reports row/col as { [false] = n } (0.10+: plain numbers).
  local col = type(c.col) == "table" and c.col[false] or c.col
  if c.relative ~= "editor" or math.abs(col - mid_col) > 1 then
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

-- I: the Issues tab - the same screens on the fake's GitHub project (the
-- demo config's GitHub account has issues:), next to W. #3001 is an issue
-- there too, on purpose: neither tab may ever show the other's.
do
  local BOARD = require("azure-cli.workitems.board")
  local log_path = vim.env.AZVICLI_FAKE_WS .. "/calls.log"
  local function log_lines()
    local out = {}
    for l in io.open(log_path):read("*a"):gmatch("[^\n]+") do out[#out + 1] = l end
    return out
  end
  local before_i = #log_lines()
  local tabs_before = {}
  for _, tp in ipairs(vim.api.nvim_list_tabpages()) do tabs_before[tp] = true end
  -- `argv` run to the end with `env` added, its stdout as one string. Not
  -- vim.system: that's 0.10+, and CI runs apt's Neovim 0.9 (#51).
  local function run_sync(argv, env)
    local out = {}
    local job = vim.fn.jobstart(argv, { env = env, stdout_buffered = true,
      on_stdout = function(_, data) out = data end })
    if job <= 0 then return "" end
    vim.fn.jobwait({ job }, 10000)
    return table.concat(out, "\n")
  end
  local function gh_detail(ref)
    local out = run_sync(require("azure-cli.config").provider_argv("--wi-detail", ref), { AZVICLI_WI_HOST = "github" })
    local okj, data = pcall(vim.json.decode, out)
    return okj and type(data) == "table" and data.item or {}
  end
  local has
  ok = vim.wait(10000, function() has = BOARD.has_issues() return has ~= nil end, 50)
  if not has then return fail("--boards never reported the demo's GitHub project: " .. vim.inspect(require("azure-cli.state").BOARDS)) end

  at_row(wis, 3001)
  feed("I")
  local iss
  ok = vim.wait(15000, function()
    iss = find_buf("azurecli-issues")
    return iss ~= nil and text(iss):find("#3001 ", 1, true) ~= nil and text(iss):find("#12 ", 1, true) ~= nil
  end, 100)
  if not ok then return fail("I never listed the GitHub project's issues", iss) end
  local issues_tab = vim.api.nvim_get_current_tabpage()
  local it = text(iss)
  if not (it:find("Iteration 1", 1, true) and it:find("Iteration 2", 1, true) and it:find("Iteration 3", 1, true)) then
    return fail("the Issues tab doesn't show the project's iterations as tabs", iss)
  end
  if it:find("Throttle repeated login failures", 1, true) or not row_text(iss, 3001):find("Spin faster", 1, true) then
    return fail("the Issues tab shows Azure's #3001", iss)
  end
  local ibar = vim.wo[vim.fn.bufwinid(iss)].winbar
  if not (ibar:find("Issues", 1, true) and ibar:find("Iteration 2", 1, true)) then
    return fail("the Issues winbar should say Issues and the iteration: " .. ibar)
  end
  vim.api.nvim_set_current_win(vim.fn.bufwinid(iss))
  feed("T")
  ok = vim.wait(15000, function()
    local t2 = text(iss)
    return t2:find("\u{25BE}#12", 1, true) ~= nil and t2:find("\u{2514} #13 +%[Todo%]") ~= nil
  end, 100)
  if not ok then return fail("T on the Issues tab never put #13 under #12", iss) end
  print("== issues, tree view ==")
  print(text(iss))

  -- <CR>: the issue's Markdown body, "Comments" and its repository.
  at_row(iss, 3001)
  feed("<CR>")
  local iview
  ok = vim.wait(15000, function()
    iview = find_buf("azurecli-issue")
    return iview ~= nil and text(iview):find("Comments (1)", 1, true) ~= nil
  end, 100)
  if not ok then return fail("<CR> on #3001 never opened the issue with its comments", iview) end
  local ivt = text(iview)
  if not (ivt:find("The gizmo should **spin faster** when asked.", 1, true) and ivt:find("Started on it in gizmos#7.", 1, true))
      or ivt:find("Discussion", 1, true) or vim.bo[iview].syntax ~= "markdown" then
    return fail("the issue view should show the Markdown body under Comments wording (syntax "
      .. vim.bo[iview].syntax .. ")", iview)
  end
  if not ivt:find("Repository: demo-gh/gizmos", 1, true) or ivt:find("\nC[a-z]+ed: [^\n]*%dT%d%d:%d%d") then
    return fail("the issue's Details: Repository needs its space and dates their local format", iview)
  end
  local function tail(b) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") end
  if tail(iss) ~= "Issues" or tail(iview) ~= "Issue #3001" then
    return fail("Neovim's own tab line would say " .. tail(iss) .. " / " .. tail(iview) .. ", not Issues / Issue #3001")
  end
  print("== issue view ==")
  print(ivt)

  -- gc: a comment, posted to the issue.
  vim.api.nvim_set_current_win(vim.fn.bufwinid(iview))
  feed("gc")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Spins at 4000 rpm here." })
  vim.cmd("stopinsert")
  feed("ZZ")
  ok = vim.wait(15000, function()
    return run_sync(require("azure-cli.config").provider_argv("--wi-detail", "demo-gh~gizmos~3001"),
      { AZVICLI_WI_HOST = "github" }):find("Spins at 4000 rpm here.", 1, true) ~= nil
  end, 200)
  if not ok then return fail("gc never commented on the issue", iview) end
  -- Read back: the comment with its real author and a date, not "Me".
  ok = vim.wait(10000, function()
    return text(iview):find("demo%-user  %d+ %a%a%a %d%d%d%d %d%d:%d%d\n  Spins at 4000 rpm here%.") ~= nil
  end, 100)
  if not ok then return fail("the new comment didn't come back with its author and date", iview) end
  -- ?: GitHub's words, and what the ↑ keys change.
  vim.api.nvim_set_current_win(vim.fn.bufwinid(iview))
  feed("?")
  local ihelp = float_text() or ""
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
  end
  if not (ihelp:find("change this issue's state", 1, true) and ihelp:find("changes GitHub", 1, true))
      or ihelp:find("Azure DevOps", 1, true) then
    return fail("the issue view's ? should speak of issues and GitHub:\n" .. ihelp)
  end

  -- gs -> Done: a Status, the issue stays open.
  local function pick_state(row_id, state, reason)
    at_row(iss, row_id)
    feed("gs")
    local p
    if not vim.wait(15000, function() p = float_text() return p ~= nil and p:find("State:", 1, true) ~= nil end, 100) then
      return fail("gs on #" .. row_id .. " never opened the state popup")
    end
    local function to(kind, want)
      local pb = vim.api.nvim_get_current_buf()
      for i, l in ipairs(vim.api.nvim_buf_get_lines(pb, 0, -1, false)) do
        if l:find("^" .. kind .. ":") then vim.api.nvim_win_set_cursor(0, { i, 0 }) break end
      end
      for _ = 1, 6 do
        if vim.wait(2000, function() return (float_text() or ""):find(kind .. ":%s+\u{2039} " .. vim.pesc(want) .. " \u{203A}") ~= nil end, 50) then
          return true
        end
        feed("l")
      end
      return fail("couldn't cycle " .. kind .. " to " .. want .. "\n" .. tostring(float_text()))
    end
    if not to("State", state) then return end
    if reason and not to("Reason", reason) then return end
    print("== issues gs popup ==")
    print(float_text())
    feed("<CR>")
    return true
  end
  if not pick_state(3001, "Done") then return end
  ok = vim.wait(15000, function() local d = gh_detail("demo-gh~gizmos~3001") return d.state == "Done" end, 200)
  if not ok then return fail("gs didn't set #3001's Status to Done: " .. vim.inspect(gh_detail("demo-gh~gizmos~3001"))) end
  -- gs -> Closed, not planned.
  if not pick_state(13, "Closed", "not planned") then return end
  ok = vim.wait(15000, function()
    local d = gh_detail("13")
    return d.state == "Closed" and d.reason == "not planned"
  end, 200)
  if not ok then return fail("gs didn't close #13 as not planned: " .. vim.inspect(gh_detail("13"))) end
  ok = vim.wait(10000, function() return row_text(iss, 13):find("[Closed]", 1, true) ~= nil end, 100)
  if not ok then return fail("the Issues tab still shows #13 open", iss) end

  -- n on #12: a new issue in the open iteration, as #12's sub-issue.
  local real_input = vim.ui.input
  vim.ui.input = function(_, cb) cb("Wobble at 4000 rpm") end
  at_row(iss, 12)
  feed("n")
  vim.ui.input = real_input
  if not choose_popup("child of #12") then return end
  ok = vim.wait(15000, function()
    return text(iss):find("\u{2514} #3002 +%[Todo%] +Wobble at 4000 rpm") ~= nil
      or (row_text(iss, 3002):find("Wobble at 4000 rpm", 1, true) ~= nil)
  end, 100)
  -- In the iteration's own list, not only under #12 by the tree's sub-issue
  -- fetch: the fake's listing has it only 2 minutes after the create.
  ok = vim.wait(10000, function()
    local c = require("azure-cli.state").ISSUES.WI_SPRINT_ITEMS["it2"]
    for _, x in ipairs(c and c.items or {}) do if x.id == 3002 then return true end end
    return false
  end, 100)
  if not ok then return fail("n never listed the new issue #3002 (the fake's listing lags, like GitHub's)", iss) end

  -- /: "#13" filters by id like "13".
  local UIM = require("azure-cli.ui")
  local real_filter = UIM.filter_prompt
  local function filter(q)
    UIM.filter_prompt = function(o) o.on_submit(q) end
    vim.api.nvim_set_current_win(vim.fn.bufwinid(iss))
    feed("/")
    UIM.filter_prompt = real_filter
  end
  filter("#13")
  local ft13 = text(iss)
  filter("")
  if not (ft13:find("#13 ", 1, true) and not ft13:find("#3001 ", 1, true)) then
    return fail("/ #13 didn't filter to #13", iss)
  end
  local made = gh_detail("demo-gh~gizmos~3002")
  if made.iterationPath ~= "Iteration 2" then return fail("the new issue isn't in Iteration 2: " .. vim.inspect(made)) end
  print("ISSUES-SMOKE-OK")

  -- Back on W: #3001 is still the Azure item, in the list and its cache.
  at_row(wis, 3001)
  feed("r")
  ok = vim.wait(15000, function() return row_text(wis, 3001):find("Throttle repeated login failures", 1, true) ~= nil end, 100)
  if not ok then return fail("W's #3001 isn't the Azure item after I", wis) end
  local S = require("azure-cli.state")
  local wcache, icache = S.WI_DETAIL_CACHE["3001"], S.ISSUES.WI_DETAIL_CACHE["demo-gh~gizmos~3001"]
  if (wcache and wcache.body and not wcache.body:find("Throttle repeated login failures", 1, true))
      or (icache and icache.body and not icache.body:find("Spin faster on demand", 1, true)) then
    return fail("the two boards' #3001 caches got mixed up")
  end

  -- The host switch rode on the I tab's calls only: never before I opened,
  -- only on --wi-* calls, and on every one that names a GitHub issue or
  -- iteration.
  local lines, switched = log_lines(), 0
  for i, l in ipairs(lines) do
    local on = l:find("AZVICLI_WI_HOST=github", 1, true) ~= nil
    if on then switched = switched + 1 end
    if on and (i <= before_i or not l:find('%["%-%-wi%-')) then
      return fail("AZVICLI_WI_HOST leaked into a call: " .. l)
    end
    if not on and l:find('%["%-%-wi%-') and (l:find("demo-gh~", 1, true) or l:find('"it%d"')) then
      return fail("an Issues call went without AZVICLI_WI_HOST: " .. l)
    end
  end
  if switched < 5 then return fail("only " .. switched .. " calls carried AZVICLI_WI_HOST=github") end
  -- Leave the tabs as the rest of the smoke expects them: only the Issues
  -- tab I opened stays, not the ones at_row added.
  for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
    if not tabs_before[tp] and tp ~= issues_tab and vim.api.nvim_tabpage_is_valid(tp) then
      vim.cmd("tabclose! " .. vim.api.nvim_tabpage_get_number(tp))
    end
  end
  print("BOARDS-SMOKE-OK")
end

-- The chat panel (lua/azure-cli/chat/): tests/fake-chat-agent.py stands in
-- for Claude Code and speaks real MCP to `azure-cli.py --mcp`, which relays
-- to the panel's bridge. From auth.py's diff, on bob's thread: gq opens the
-- panel; "triage" sees the view (PR, file, line, thread), reads the threads
-- and drafts a reply into the batch queue (not posted); gm picks a model;
-- "branch" creates a branch on the fake origin linked to #3001 (no
-- question asked); "vote" asks first and the "Deny" goes back to the agent.
-- The panel follows into the dashboard's tab; gq there jumps into it, and
-- gq from inside it hides it.
do
  local CHAT = require("azure-cli.chat")
  local fake_chat = require("azure-cli.config").plugin_root() .. "/tests/fake-chat-agent.py"
  local agent_cmd = { "python3", fake_chat, "--mcp-config", "{mcp_config}", "--model", "{model}" }
  -- ui.confirm = "select": the questions come through vim.ui.select, which
  -- these blocks stub to answer them (the popup has tests/test-confirm.lua).
  require("azure-cli").setup({ ui = { confirm = "select" }, chat = { agent = {
    label = "Fake Claude", cmd = agent_cmd, models = { "fast", "smart" }, timeout_seconds = 60,
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
    local spun = false
    local okw = vim.wait(30000, function()
      if st.running then
        local bar = vim.wo[st.wins[vim.api.nvim_get_current_tabpage()].log].winbar
        spun = spun or bar:match("%[%S+ working%]") ~= nil
      end
      e = st.entries[#st.entries]
      return #st.entries == n + 2 and e.status ~= "running"
    end, 100)
    if not okw then return nil, "no answer to \"" .. msg .. "\": " .. vim.inspect(st.entries[#st.entries]) end
    -- (Its timer doesn't fire inside this vim.wait, so only that it shows.)
    if not spun then return nil, "no spinner in the winbar while the agent ran" end
    if require("azure-cli.chat").status() ~= "" or vim.wo[st.wins[vim.api.nvim_get_current_tabpage()].log].winbar:find("working", 1, true) then
      return nil, "the spinner is still showing after the answer"
    end
    return e
  end

  feed("gq")
  local st = require("azure-cli.state").chat
  local wins = st.wins[vim.api.nvim_get_current_tabpage()]
  if not (wins and vim.api.nvim_win_is_valid(wins.log) and vim.api.nvim_get_current_win() == wins.input) then
    return fail("gq didn't open the chat panel with the input focused")
  end
  -- > / < resize the panel.
  local w0 = vim.api.nvim_win_get_width(wins.log)
  vim.cmd("stopinsert")
  vim.api.nvim_set_current_win(wins.log)
  feed(">")
  local w1 = vim.api.nvim_win_get_width(wins.log)
  feed("<")
  if w1 ~= w0 + 5 or vim.api.nvim_win_get_width(wins.log) ~= w0 then
    return fail("> / < didn't resize the chat: " .. w0 .. " -> " .. w1 .. " -> " .. vim.api.nvim_win_get_width(wins.log))
  end
  vim.api.nvim_set_current_win(wins.input)
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
      or not e.text:find("threads: 3, active: 2", 1, true)
      or not (log:find("\u{270E} draft_reply", 1, true) or log:find("1 change  (<Tab> shows them)", 1, true))
      or not table.concat(e.tools or {}, "|"):find("\u{270E} draft_reply", 1, true) then
    return fail("the triage turn went wrong:\n" .. log)
  end
  local b = require("azure-cli.state").batch["101"]
  if not (b and b.on and b.items[#b.items].kind == "reply" and b.items[#b.items].text == "Agreed - a reason code it is.") then
    return fail("draft_reply didn't queue the reply: " .. vim.inspect(b))
  end
  for l in io.open(vim.env.AZVICLI_FAKE_WS .. "/calls.log"):read("*a"):gmatch("[^\n]+") do
    if l:find("--reply", 1, true) then return fail("a drafted reply was posted: " .. l) end
  end

  -- gm: the next turn uses "smart" - a new process started with it, which
  -- gets the conversation so far replayed.
  answer = "smart"
  vim.api.nvim_set_current_win(wins.log)
  feed("gm")
  vim.api.nvim_set_current_win(diff_win)
  e, why = ask("create a branch from main for 3001")
  if not e then return fail(why) end
  if not e.text:find("model: smart", 1, true) or not e.text:find("turn: 1", 1, true)
      or not e.text:find("message had the history: True", 1, true) or e.mode ~= "replay"
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
  -- gq from the dashboard while the panel shows: into its input box; gq
  -- again from there: hidden.
  vim.api.nvim_set_current_win(vim.fn.bufwinid(dash))
  feed("gq")
  vim.cmd("stopinsert")
  if vim.api.nvim_get_current_win() ~= st.wins[vim.api.nvim_get_current_tabpage()].input then
    return fail("gq on a screen didn't jump into the showing chat's input box")
  end
  feed("gq")
  if st.visible or st.wins[vim.api.nvim_get_current_tabpage()] then return fail("gq inside the chat didn't hide it") end
  vim.ui.select = real_select
  print("CHAT-SMOKE-OK")
end
-- The chat, part two: streamed answers (stream-json), a visual selection
-- and !refs in the message, a saved prompt (/build) reading a build log,
-- open_in_ui, annotate_code, the fix flow (worktree -> diff -> commit and
-- push, asked first), board tools with an undo from the audit log (gH, u),
-- gr drafting an answer as a reply, switching agents (gM) and going back to
-- an earlier conversation (gh).
do
  local CHAT = require("azure-cli.chat")
  local STATE = require("azure-cli.state")
  local fake_chat = require("azure-cli.config").plugin_root() .. "/tests/fake-chat-agent.py"
  local streamed = { "python3", fake_chat, "--mcp-config", "{mcp_config}", "--model", "{model}" }
  require("azure-cli").setup({ ui = { confirm = "select" }, chat = {
    default_agent = "claude",
    agents = {
      claude = { label = "Fake Claude", cmd = streamed, models = { "fast", "smart" }, timeout_seconds = 60 },
      plain = { label = "Plain", cmd = { "python3", fake_chat, "--mcp-config", "{mcp_config}" }, timeout_seconds = 60 },
    },
    plan_first = false,  -- the plan gate has a smoke of its own (PLAN-SMOKE-OK)
  } })
  vim.env.GIT_AUTHOR_NAME, vim.env.GIT_AUTHOR_EMAIL = "Fake Agent", "agent@example.com"
  vim.env.GIT_COMMITTER_NAME, vim.env.GIT_COMMITTER_EMAIL = "Fake Agent", "agent@example.com"
  local answer
  local real_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    for i, it in ipairs(items) do
      local label = opts.format_item and opts.format_item(it) or tostring(it)
      if answer and label:find(answer, 1, true) then return cb(it, i) end
    end
    return cb(nil)
  end
  local st = STATE.chat
  local function wins() return st.wins[vim.api.nvim_get_current_tabpage()] end
  local function ask(msg)
    local w = wins()
    local n = #st.entries
    vim.api.nvim_set_current_win(w.input)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(w.input), 0, -1, false, { msg })
    vim.cmd("stopinsert")
    feed("<CR>")
    local e
    local okw = vim.wait(40000, function()
      e = st.entries[#st.entries]
      return #st.entries >= n + 2 and e.role == "agent" and e.status ~= "running"
    end, 100)
    if not okw then return nil, "no answer to \"" .. msg .. "\": " .. vim.inspect(st.entries[#st.entries]) end
    return e
  end
  local function need(e, why, ...)
    if not e then return fail(why) end
    -- Older Neovims' vim.json.encode writes / as \/.
    local text = (e.text or ""):gsub("\\/", "/")
    for _, s in ipairs({ ... }) do
      if not text:find(s, 1, true) then return fail("\"" .. s .. "\" missing from the answer:\n" .. tostring(e.text)) end
    end
    return true
  end

  -- The reviewer on PR #101 at auth.py:12, through the opener open_in_ui uses.
  require("azure-cli").open_review(101)
  ok = vim.wait(20000, function()
    local o = STATE.review_openers and STATE.review_openers["101"]
    return o and o("src/auth.py", "R", 12)
  end, 100)
  if not ok then return fail("review_openers didn't show auth.py") end
  local diffwin
  ok = vim.wait(10000, function()
    diffwin = vim.api.nvim_get_current_win()
    local b = vim.api.nvim_win_get_buf(diffwin)
    local m = (require("azure-cli.review.pane").entry(b) or {}).map
    local cur = m and m[vim.api.nvim_win_get_cursor(diffwin)[1]]
    return cur and cur.side == "R" and cur.lineno == 12
  end, 100)
  if not ok then return fail("the opener didn't land on auth.py's line 12") end

  -- A selection of two lines + gq, then a message naming !102.
  CHAT.new_chat(true)
  feed("Vj")
  feed("gq")
  if not st.selection or st.selection.to - st.selection.from ~= 1 then return fail("gq in visual mode didn't capture the selection") end
  local e, why = ask("explain this, and compare with !102")
  if not need(e, why, "selection: 12-13", "refs: yes", "model: fast") then return end
  local streamed_tool = false
  for _, t in ipairs(e.tools or {}) do if t:find("Read src/auth.py", 1, true) then streamed_tool = true end end
  if not streamed_tool or st.session_id ~= "fake-chat-1" then
    return fail("the stream-json answer wasn't read: " .. vim.inspect(e.tools) .. " session " .. tostring(st.session_id))
  end

  -- /build: the saved prompt, about the PR with the failing build.
  e, why = ask("/build")
  -- The same process as the first message: its turn 2, nothing replayed.
  if not need(e, why, "get_build_log:", "expected 'x', got '--name'", "turn: 2", "message had the history: False") then return end
  if st.entries[#st.entries - 1].text ~= "/build" then return fail("the prompt name should show as typed") end

  -- open_in_ui: throttle.py line 4 in the reviewer.
  e, why = ask("show me the lockout code")
  if not need(e, why, "open_in_ui: Showing PR !101 at src/throttle.py:4") then return end
  ok = vim.wait(5000, function()
    local w = vim.api.nvim_get_current_win()
    local b = vim.api.nvim_win_get_buf(w)
    return vim.api.nvim_buf_get_name(b) ~= "" or (require("azure-cli.review.pane").entry(b) or {}).map ~= nil
  end, 50)

  -- annotate_code: a note under auth.py:12.
  vim.api.nvim_set_current_win(diffwin)
  e, why = ask("annotate the risky lines")
  if not need(e, why, "annotate_code: Noted src/auth.py:12") then return end
  local nns = vim.api.nvim_get_namespaces()["azure_cli_chat_notes"]
  local noted = false
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, nns or -1, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        if vl[1][1]:find("Lockout check here", 1, true) then noted = true end
      end
    end
  end
  if not noted then return fail("the note isn't drawn in auth.py's diff") end
  -- Kept for the next session, with the line it was drawn under.
  local saved = require("azure-cli.shell").read_json(require("azure-cli.chat.store").root() .. "/notes/101.json", {})
  if not (saved[1] and saved[1].text == "Lockout check here" and type(saved[1].code) == "string" and saved[1].code ~= "") then
    return fail("the note wasn't saved with its line: " .. vim.inspect(saved))
  end
  -- ]a / [a: the diff shows throttle.py (open_in_ui above), after
  -- auth.py in the file list - [a goes back to auth.py's note, and with a
  -- note in throttle.py too, ]a goes on into it and [a back again.
  local function at_note(line)
    local b = vim.api.nvim_get_current_buf()
    local m = ((require("azure-cli.review.pane").entry(b) or {}).map or {})[vim.api.nvim_win_get_cursor(0)[1]]
    return vim.api.nvim_get_current_win() == diffwin and m ~= nil and m.side == "R" and m.lineno == line
  end
  local function on_text(t) return vim.api.nvim_get_current_line():find(t, 1, true) ~= nil end
  vim.api.nvim_set_current_win(diffwin)
  local throttle_buf = vim.api.nvim_get_current_buf()
  feed("[a")
  if not vim.wait(5000, function() return at_note(12) and vim.api.nvim_get_current_buf() ~= throttle_buf end, 50) then
    return fail("[a didn't go back to auth.py's note")
  end
  local auth_buf = vim.api.nvim_get_current_buf()
  local notes = require("azure-cli.state").chat_notes["101"]
  table.insert(notes, { file = "src/throttle.py", line = 3, text = "And here", kind = "info" })
  feed("]a")
  if not vim.wait(5000, function() return at_note(3) and on_text("FAILURES = {}") end, 50) then
    return fail("]a didn't go on into throttle.py's note")
  end
  feed("[a")
  if not vim.wait(5000, function() return at_note(12) and vim.api.nvim_get_current_buf() == auth_buf end, 50) then
    return fail("[a didn't come back to auth.py's note")
  end
  -- Back where open_in_ui left it: the steps below expect throttle.py.
  STATE.review_openers["101"]("src/throttle.py", "R", 4)
  if not vim.wait(5000, function() return at_note(4) and vim.api.nvim_get_current_buf() == throttle_buf end, 50) then
    return fail("couldn't go back to throttle.py:4")
  end
  table.remove(notes)

  -- The fix flow: the push asks first ("Allow"), then lands on the branch.
  answer = "Allow"
  local fix_tab = vim.api.nvim_get_current_tabpage()
  e, why = ask("fix it please")
  if not need(e, why, "start_fix:", "show_fix:", "commit_and_push_fix: Pushed") then return end
  -- show_fix opened the change in its own tab, like the reviewer: files on
  -- the left, the diff on the right, ]c through it, q closes.
  local function diff_focused()
    vim.wait(500, function() return false end, 50)  -- the chat follows into the tab meanwhile
    local b = vim.api.nvim_get_current_buf()
    return vim.api.nvim_buf_get_name(b) ~= "azure-cli://changes" and not vim.b[b].azure_cli_chat
      and (require("azure-cli.review.pane").entry(b) or {}).map ~= nil
  end
  if not diff_focused() then return fail("show_fix didn't leave the focus in the diff pane") end
  local cbuf = vim.fn.bufnr("azure-cli://changes")
  if cbuf < 0 or not table.concat(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), "\n"):find("M  src/auth.py", 1, true) then
    return fail("show_fix didn't open the change viewer with src/auth.py")
  end
  local ctab = vim.fn.win_findbuf(cbuf)[1] and vim.api.nvim_win_get_tabpage(vim.fn.win_findbuf(cbuf)[1])
  vim.api.nvim_set_current_tabpage(ctab)
  local dwin
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(ctab)) do
    local wb = vim.api.nvim_win_get_buf(w)
    if not vim.b[wb].azure_cli_chat
        and table.concat(vim.api.nvim_buf_get_lines(wb, 0, -1, false), "\n"):find("FIXED-BY-AGENT", 1, true) then dwin = w end
  end
  if not dwin then return fail("the change viewer doesn't show auth.py's diff") end
  vim.api.nvim_set_current_win(dwin)
  vim.api.nvim_win_set_cursor(dwin, { 1, 0 })
  feed("]c")
  local at = vim.api.nvim_get_current_line()
  if not at:find("FIXED-BY-AGENT", 1, true) then return fail("]c in the change viewer didn't reach the change: " .. at) end
  -- The chat describes the file and line here.
  local vsnap = require("azure-cli.chat.view").snapshot(dwin)
  if vsnap.file ~= "src/auth.py" or not vsnap.line or not (vsnap.code_line or ""):find("FIXED-BY-AGENT", 1, true) then
    return fail("the chat doesn't describe the change viewer: " .. vim.inspect(vsnap))
  end
  -- r picks up a later edit, staying on the file and line.
  local before_line = vim.api.nvim_win_get_cursor(dwin)[1]
  local wt_file = require("azure-cli.chat.tools_fix").path(require("azure-cli.chat.tools").pr_record(101)) .. "/src/auth.py"
  vim.fn.writefile({ "# MORE-BY-AGENT" }, wt_file, "a")
  feed("r")
  local refreshed = vim.wait(10000, function()
    local b = vim.api.nvim_win_get_buf(dwin)
    return vim.api.nvim_win_is_valid(dwin) and table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("MORE-BY-AGENT", 1, true) ~= nil
  end, 50)
  if not refreshed then return fail("r in the change viewer didn't pick up the new edit") end
  if vim.api.nvim_get_current_win() ~= dwin or vim.api.nvim_win_get_cursor(dwin)[1] ~= before_line then
    return fail("r moved off the line: " .. before_line .. " -> " .. vim.api.nvim_win_get_cursor(dwin)[1])
  end
  -- gq goes to the chat from here.
  feed("gq")
  local cw = require("azure-cli.state").chat.wins[ctab]
  if not (cw and vim.api.nvim_get_current_win() == cw.input) then return fail("gq in the change viewer didn't go to the chat") end
  vim.cmd("stopinsert")
  vim.api.nvim_set_current_win(dwin)
  feed("q")
  if vim.api.nvim_tabpage_is_valid(ctab) then return fail("q didn't close the change viewer") end
  vim.api.nvim_set_current_tabpage(fix_tab)
  -- gd in the chat opens it again - the last commit, now that it's pushed.
  vim.api.nvim_set_current_win(wins().log)
  feed("gd")
  local reopened = vim.wait(10000, function()
    local b = vim.fn.bufnr("azure-cli://changes")
    return b > 0 and #vim.fn.win_findbuf(b) > 0
  end, 50)
  if not reopened then return fail("gd in the chat didn't reopen the change") end
  if not diff_focused() then return fail("gd didn't leave the focus in the diff pane") end
  if not table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("FIXED-BY-AGENT", 1, true) then
    return fail("gd after the push didn't show the pushed commit")
  end
  cbuf = vim.fn.bufnr("azure-cli://changes")
  pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(vim.fn.win_findbuf(cbuf)[1])))
  vim.api.nvim_set_current_tabpage(fix_tab)
  local bare = vim.env.AZVICLI_FAKE_WS .. "/origin/widgets.git"
  local subject = vim.fn.system({ "git", "--git-dir", bare, "log", "-1", "--format=%s", "feature/login-throttle" })
  local content = vim.fn.system({ "git", "--git-dir", bare, "show", "feature/login-throttle:src/auth.py" })
  if not subject:find("Return a reason code on lockout", 1, true) or not content:find("FIXED-BY-AGENT", 1, true) then
    return fail("the fix wasn't pushed: " .. subject)
  end

  -- The story flow: a branch from main linked to #3001, a worktree of it,
  -- the change pushed there (asks first - answer is still "Allow").
  e, why = ask("implement the story")
  if not need(e, why, "start_story: {", "Already started", "show_fix:", "commit_and_push_fix: Pushed", "create_pull_request",
    "delete_fix_file: Deleted SCRATCH.md", "delete_fix_file: Deleted README.md", "outside.txt isn't inside") then return end
  local tree = vim.fn.system({ "git", "--git-dir", bare, "ls-tree", "-r", "--name-only", "feature/3001-story" })
  if tree:find("SCRATCH.md", 1, true) or tree:find("README.md", 1, true) then
    return fail("delete_fix_file's deletions aren't in the pushed story: " .. tree)
  end
  cbuf = vim.fn.bufnr("azure-cli://changes")
  if cbuf < 0 or not table.concat(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), "\n"):find("A  STORY.md", 1, true) then
    return fail("show_fix didn't list the story's new file")
  end
  pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(vim.fn.win_findbuf(cbuf)[1])))
  vim.api.nvim_set_current_tabpage(fix_tab)
  subject = vim.fn.system({ "git", "--git-dir", bare, "log", "-1", "--format=%s", "feature/3001-story" })
  content = vim.fn.system({ "git", "--git-dir", bare, "show", "feature/3001-story:STORY.md" })
  if not subject:find("Implement the login throttle story", 1, true) or not content:find("IMPLEMENTED-BY-AGENT", 1, true) then
    return fail("the story wasn't pushed: " .. subject)
  end

  -- The fix pushed to !101 (and the story's new PR) are watched for new
  -- comments, dashboard or not: Alice answering is said in the chat.
  local W = require("azure-cli.chat.watch")
  local wfile = require("azure-cli.chat.store").root() .. "/watched.json"
  ok = vim.wait(10000, function()
    local wl = require("azure-cli.shell").read_json(wfile, {})
    return wl["101"] ~= nil and wl["101"].seen ~= nil
  end, 100)
  if not ok then return fail("PR !101 isn't watched after the agent pushed its fix") end
  vim.fn.system({ "python3", "-c", [[
import json, os, sys
p = os.path.join(os.environ["AZVICLI_FAKE_WS"], "state.json")
s = json.load(open(p, encoding="utf-8"))
t = s["threads"]["101"][0]
t["comments"].append({"id": 900, "parentCommentId": 1, "content": "Thanks - one more thing here.",
  "author": {"id": "aaaaaaaa-0000-0000-0000-000000000001", "displayName": "Alice Andersson"},
  "publishedDate": "2026-10-12T00:00:00Z", "lastUpdatedDate": "2026-10-12T00:00:00Z",
  "commentType": "text", "isDeleted": False})
json.dump(s, open(p, "w", encoding="utf-8"))
]] })
  local function poll()
    local finished = false
    W.poll(function() finished = true end)
    vim.wait(10000, function() return finished end, 50)
  end
  poll(); poll()
  local said
  for _, en in ipairs(STATE.chat.entries) do
    if en.role == "note" and en.text:find("!101", 1, true) and en.text:find("1 new comment", 1, true) then said = en.text end
  end
  if not said then return fail("Alice's new comment on !101 wasn't said in the chat") end

  -- get_pull_request on a PR that isn't on the dashboard fetches it (and
  -- the other PR tools then work for it); the code-search tools.
  local cache = STATE.PR_LIST_CACHE
  local kept = cache.prs
  cache.prs = vim.tbl_filter(function(p) return tostring(p.id) ~= "102" end, kept)
  e, why = ask("look up those")
  cache.prs = kept
  if not need(e, why, "get_pull_request: {", "get_pr_threads: [", "PR !9999 wasn't found",
    "find_definition: {", "src/throttle.py", "def is_locked", "find_implementations: {") then return end

  -- Board tools, then u in gH undoes the link.
  e, why = ask("plan the work")
  if not need(e, why, "create_child_task: Created Task", "move_to_sprint: Moved #3002", "link_pr_to_work_item: Linked PR #102") then return end
  local items = require("azure-cli.chat.store").audit()
  if not (items[#items] and items[#items].tool == "link_pr_to_work_item" and items[#items].undo) then
    return fail("the link isn't in the audit log with an undo: " .. vim.inspect(items[#items]))
  end
  vim.api.nvim_set_current_win(wins().log)
  feed("gH")
  local fw = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(fw).relative == "" then return fail("gH didn't open the audit float") end
  vim.api.nvim_win_set_cursor(fw, { 1, 0 })
  feed("u")
  ok = vim.wait(10000, function()
    for l in io.open(vim.env.AZVICLI_FAKE_WS .. "/calls.log"):read("*a"):gmatch("[^\n]+") do
      if l:find("unlink-pr", 1, true) and l:find("3002", 1, true) then return true end
    end
  end, 100)
  if not ok then return fail("u in the audit log didn't unlink") end
  pcall(vim.api.nvim_win_close, fw, true)

  -- gr: the last answer as a reply to the thread its question was on.
  vim.api.nvim_set_current_win(wins().log)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  local before = #((STATE.batch or {})["101"] or { items = {} }).items
  feed("gr")
  local ed = vim.api.nvim_get_current_buf()
  if not table.concat(vim.api.nvim_buf_get_lines(ed, 0, -1, false), "\n"):find("FAKE-CHAT-RAN", 1, true) then
    return fail("gr didn't prefill the editor with the answer")
  end
  feed("<C-s>")
  ok = vim.wait(3000, function() return #STATE.batch["101"].items == before + 1 end, 50)
  if not ok then return fail("gr's reply wasn't queued") end

  -- The agent's board tools on the Issues board (GITHUB_PLAN.md phase 6
  -- stage 3): gq on #12 in the I tab, so calls without board= go to
  -- GitHub; start_story makes feature/12-wobble in gizmos, linked to #12;
  -- create_pull_request closes #12; linking gizmos#7 to #13 asks, adds
  -- "Closes #13" to its description, and u in gH takes it out again. Then
  -- gW on gizmos#7 opens its issue in the I view, and gP on #12 starts an
  -- agent that reads the issue without being told the board.
  do
    local home_tab = vim.api.nvim_get_current_tabpage()
    local ws = vim.env.AZVICLI_FAKE_WS
    local log_from = #vim.fn.readfile(ws .. "/calls.log")
    local function fake_state() return vim.json.decode(table.concat(vim.fn.readfile(ws .. "/state.json"), "\n")) end
    local function issue_in(s, n)
      for _, i in ipairs(s.issues) do if i.number == n and i.repo == "gizmos" then return i end end
    end
    local function gizmos_pr(s, pred)
      for _, p in ipairs(s.prs) do if p.host == "github" and p.repo == "gizmos" and pred(p) then return p end end
    end
    local iss = find_buf("azurecli-issues")
    if not iss then return fail("the Issues tab is gone before the agent's board tools") end
    at_row(iss, 12)
    local issue_tab = vim.api.nvim_get_current_tabpage()
    feed("gq")
    answer = "Allow"
    e, why = ask("work the issue")
    if not need(e, why, "view board: github, item 12", "list_work_items: [", "\"board\":\"github\"",
        "get_work_item: {", "set_work_item_state: Issue #12 is now In Progress", "comment_on_work_item: Commented on #12",
        "create_child_task: Created issue #", "start_story: {", "create_pull_request: Opened PR !",
        "link_pr_to_work_item: Linked PR #7 to issue #13 (\"Closes #13\" in its description).") then return end
    local s = fake_state()
    local i12 = issue_in(s, 12)
    local last = i12.comments[#i12.comments] or {}
    if i12.status ~= "In Progress" or last.text ~= "Picking this up." then
      return fail("the agent's state/comment didn't reach GitHub #12: " .. vim.inspect({ i12.status, last }))
    end
    local kid
    for _, i in ipairs(s.issues) do if i.parent == 12 and i.title == "Write the wobble test" then kid = i end end
    if not (kid and kid.iteration == "it2") then return fail("no sub-issue of #12 in its iteration: " .. vim.inspect(kid)) end
    local linked_branch = false
    for _, b in ipairs(i12.branches or {}) do if b.name == "feature/12-wobble" and b.repo == "gizmos" then linked_branch = true end end
    local tip = vim.fn.system({ "git", "--git-dir", ws .. "/origin/gizmos.git", "rev-parse", "-q", "--verify",
      "refs/heads/feature/12-wobble" })
    if not linked_branch or vim.v.shell_error ~= 0 then return fail("start_story didn't make feature/12-wobble linked to #12: " .. tip) end
    local opened = gizmos_pr(s, function(p) return p.source == "feature/12-wobble" end)
    if not (opened and (opened.description or ""):find("Closes #12", 1, true) and vim.tbl_contains(i12.prs, opened.id)) then
      return fail("create_pull_request didn't close #12: " .. vim.inspect(opened))
    end
    local p7 = gizmos_pr(s, function(p) return p.id == 7 end)
    if not (p7.description or ""):find("Closes #13", 1, true) then return fail("gizmos#7 doesn't close #13: " .. p7.description) end
    -- u in gH: the link goes, through the GitHub board.
    local items = require("azure-cli.chat.store").audit()
    local it = items[#items]
    if not (it and it.tool == "link_pr_to_work_item" and it.undo and it.undo.board == "github") then
      return fail("the GitHub link isn't in the audit log with its board: " .. vim.inspect(it))
    end
    vim.api.nvim_set_current_win(wins().log)
    feed("gH")
    local fw = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(fw, { 1, 0 })
    feed("u")
    ok = vim.wait(10000, function()
      local p = gizmos_pr(fake_state(), function(x) return x.id == 7 end)
      return not (p.description or ""):find("Closes #13", 1, true)
    end, 100)
    if not ok then return fail("u in the audit log didn't take \"Closes #13\" out of gizmos#7") end
    pcall(vim.api.nvim_win_close, fw, true)
    -- Every one of those board calls carried the host switch; no PR call did.
    local calls = vim.list_slice(vim.fn.readfile(ws .. "/calls.log"), log_from + 1)
    for _, want in ipairs({ '"--wi-list"]', '"--wi-detail", "12"', '"--wi-state", "set", "12", "In Progress"',
        '"comment", "12", "Picking this up."', '"create", "Issue", "Write the wobble test", "12"',
        '"create-branch", "12"', '"link-pr", "13"', '"unlink-pr", "13", "7"' }) do
      local seen = false
      for _, l in ipairs(calls) do
        if l:find(want, 1, true) then
          seen = true
          if not l:find("AZVICLI_WI_HOST=github", 1, true) then return fail("an Issues call went without the switch: " .. l) end
        end
      end
      if not seen then return fail("no " .. want .. " call in the log") end
    end
    for _, l in ipairs(calls) do
      if l:find("AZVICLI_WI_HOST=github", 1, true) and not l:find('%["%-%-wi%-') then
        return fail("AZVICLI_WI_HOST leaked into a call: " .. l)
      end
    end
    -- gW on gizmos#7: its issue (#3001) opens in the Issues view.
    local rec
    for _, p in ipairs((STATE.PR_LIST_CACHE or {}).prs or {}) do
      if p.host == "github" and p.repo == "gizmos" and tostring(p.id) == "7" then rec = p end
    end
    if not rec then return fail("gizmos#7 isn't in the PR list") end
    require("azure-cli.pr_workitems").choose(rec, require("azure-cli.chat.tools").pr_env(rec))
    if not choose_popup("#3001  [") then return end
    local iview
    ok = vim.wait(15000, function()
      iview = find_buf("azurecli-issue")
      return iview ~= nil and text(iview):find("Spin faster on demand", 1, true) ~= nil
    end, 100)
    if not ok then return fail("gW's <CR> on gizmos#7's issue didn't open it in the Issues view", iview) end
    pcall(vim.cmd, "tabclose")
    -- gP on #12: an agent of its own, whose view names the GitHub board.
    vim.api.nvim_set_current_tabpage(issue_tab)
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(iss)[1])
    at_row(iss, 12)
    local gp_tab = vim.api.nvim_get_current_tabpage()
    feed("gP")
    local AGENTS = require("azure-cli.chat.agents")
    ok = vim.wait(30000, function()
      local c = CHAT.find_conversation("wi-12")
      local en = c and c.entries[#c.entries]
      return en and en.role == "agent" and en.status == "done" and AGENTS.working() == 0
    end, 100)
    local c12 = CHAT.find_conversation("wi-12")
    local said = c12 and c12.entries[#c12.entries] and c12.entries[#c12.entries].text or ""
    if not ok or not said:find("planned issue #12 on board github: Doohickey wobbles at speed", 1, true) then
      return fail("gP on the Issues board's #12: " .. said)
    end
    -- The later smokes count the plans waiting for you: #12's isn't one.
    local PLAN = require("azure-cli.chat.plan")
    local p12 = PLAN.load("wi-12")
    if p12 then
      p12.status = "done"
      PLAN.save(p12)
    end
    for _, tp in ipairs({ gp_tab, issue_tab }) do
      if vim.api.nvim_tabpage_is_valid(tp) and tp ~= home_tab then
        pcall(vim.cmd, "tabclose! " .. vim.api.nvim_tabpage_get_number(tp))
      end
    end
    vim.api.nvim_set_current_tabpage(home_tab)
    CHAT.sync_active()
    print("ISSUE-TOOLS-SMOKE-OK")
  end

  -- gM: the other agent, which gets the conversation replayed.
  answer = "Plain"
  vim.api.nvim_set_current_win(wins().log)
  feed("gM")
  e, why = ask("hello")
  if not need(e, why, "turn: 1", "message had the history: True") then return end
  if e.label ~= "Plain" or e.mode ~= "replay" then return fail("gM didn't switch agents: " .. vim.inspect({ e.label, e.mode })) end

  -- A note from the dashboard, then gn and back with gh.
  CHAT.on_new_comments({ id = 102, title = "Reload config" }, 2)
  if not (st.entries[#st.entries].role == "note" and st.entries[#st.entries].text:find("!102", 1, true)) then
    return fail("on_new_comments left no note")
  end
  local turns = #st.entries
  vim.api.nvim_set_current_win(wins().log)
  feed("gn")
  if #st.entries ~= 0 then return fail("gn didn't start a new conversation") end
  answer = "explain this"
  feed("gh")
  if #st.entries ~= turns then return fail("gh didn't bring the conversation back: " .. #st.entries .. " vs " .. turns) end
  vim.ui.select = real_select
  print("== chat, part two ==")
  print(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins().log), 0, 40, false), "\n"))
  CHAT.hide()
  print("CHATPLUS-SMOKE-OK")
end
-- The plan: start_story is refused until there's an approved plan;
-- submit_plan opens it like the reviewer (sections left, the plan right);
-- ga on a line asks the agent about it and the answer lands under it; gf +
-- :w makes your edit a revision; gA approves it and the agent goes ahead;
-- ga in the change viewer asks about a line of the change the same way.
do
  local CHAT = require("azure-cli.chat")
  local STATE = require("azure-cli.state")
  local PLAN = require("azure-cli.chat.plan")
  local fake_chat = require("azure-cli.config").plugin_root() .. "/tests/fake-chat-agent.py"
  require("azure-cli").setup({ ui = { confirm = "select" }, chat = { agent = { label = "Fake Claude", timeout_seconds = 60,
    cmd = { "python3", fake_chat, "--mcp-config", "{mcp_config}" } } } })
  CHAT.new_chat(true)
  local st = STATE.chat
  -- Every yes/no in this block: answer with the item containing `pick`.
  local pick = "Allow"
  local real_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    for i, it in ipairs(items) do
      if (opts.format_item and opts.format_item(it) or tostring(it)):find(pick, 1, true) then return cb(it, i) end
    end
    cb(nil)
  end
  local function answered(n)
    local e
    local okw = vim.wait(40000, function()
      e = st.entries[#st.entries]
      return #st.entries >= n + 2 and e.role == "agent" and e.status ~= "running"
    end, 100)
    return okw and e or nil
  end
  local n = #st.entries
  CHAT.send("make a plan for #3002")
  local e = answered(n)
  if not e then return fail("no answer to the plan request: " .. vim.inspect(st.entries[#st.entries])) end
  for _, s in ipairs({ "No plan for #3002 yet", "submit_plan: {", "isn't approved yet" }) do
    if not e.text:find(s, 1, true) then return fail("\"" .. s .. "\" missing from the answer:\n" .. e.text) end
  end
  local v = PLAN.current()
  if not (v and vim.api.nvim_tabpage_is_valid(v.tab) and vim.api.nvim_win_is_valid(v.plan_win)) then
    return fail("submit_plan didn't open the plan")
  end
  if not CHAT.strip():find("plan #3002 waits for you", 1, true)
      or not require("azure-cli.ui").tabline():find("plan #3002 waits for you", 1, true) then
    return fail("the status strip doesn't say the plan waits: " .. CHAT.strip())
  end
  local outline = table.concat(vim.api.nvim_buf_get_lines(v.list_buf, 0, -1, false), "\n")
  for _, s in ipairs({ "#3002  Lockout reason codes", "Waiting for your review", "Approach", "Files", "Test plan", "gA  approve" }) do
    if not outline:find(s, 1, true) then return fail("the section list lacks \"" .. s .. "\":\n" .. outline) end
  end
  if not outline:match("Files%s+2") then return fail("the Files section doesn't count its 2 files:\n" .. outline) end
  if not vim.wo[v.plan_win].winbar:find("Plan", 1, true) or vim.wo[v.plan_win].fillchars ~= "eob: " then
    return fail("the plan pane lacks the shared look: " .. vim.wo[v.plan_win].winbar)
  end
  -- <CR> on a section goes there.
  vim.api.nvim_set_current_win(v.list_win)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(v.list_buf, 0, -1, false)) do
    if l:find("Approach", 1, true) then vim.api.nvim_win_set_cursor(v.list_win, { i, 0 }) end
  end
  feed("<CR>")
  if vim.api.nvim_get_current_win() ~= v.plan_win or vim.api.nvim_get_current_line() ~= "## Approach" then
    return fail("<CR> on Approach didn't go there: " .. vim.api.nvim_get_current_line())
  end
  -- ga on "Return a reason code from login().": asked, answered under it.
  feed("j")
  local row = vim.api.nvim_win_get_cursor(v.plan_win)[1]
  n = #st.entries
  feed("ga")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Why did you choose this?" })
  feed("<C-s>")
  local rec
  local okq = vim.wait(40000, function()
    rec = PLAN.load("wi-3002")
    return rec and rec.threads[1] and rec.threads[1].status ~= "asking"
  end, 100)
  if not okq then return fail("the question about the plan line wasn't answered: " .. vim.inspect(rec and rec.threads)) end
  local th = rec.threads[1]
  if th.line ~= row or th.question ~= "Why did you choose this?" or th.status ~= "answered"
      or not (th.answer or ""):find("BECAUSE-Return a reason code from login(). (asked on the plan, line " .. row .. ")", 1, true) then
    return fail("the plan question went wrong: " .. vim.inspect(th))
  end
  local function drawn(buf, s)
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, require("azure-cli.chat.threads").ns, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        for _, chunk in ipairs(vl) do if chunk[1]:find(s, 1, true) then return m[2] + 1 end end
      end
    end
  end
  if drawn(v.plan_buf, "BECAUSE-Return") ~= row then return fail("the answer isn't drawn under its plan line") end
  if not (st.entries[n + 1].text or ""):find("Why did you choose this?  (plan:" .. row .. ")", 1, true) then
    return fail("the question doesn't show in the chat as asked: " .. tostring(st.entries[n + 1].text))
  end
  -- gf, an edit, :w - a revision by you, which the plan pane shows.
  feed("gf")
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "## Open questions", "Should admins be exempt?" })
  vim.cmd("silent write")
  rec = PLAN.load("wi-3002")
  if #rec.revisions ~= 2 or rec.revisions[2].by ~= "you" or rec.status ~= "draft" then
    return fail("saving the plan by hand wasn't a revision: " .. vim.inspect({ #rec.revisions, rec.status }))
  end
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(v.tab)
  if not table.concat(vim.api.nvim_buf_get_lines(v.plan_buf, 0, -1, false), "\n"):find("Should admins be exempt?", 1, true) then
    return fail("the plan pane doesn't show your edit")
  end
  if not vim.wo[v.plan_win].winbar:find("edited by you", 1, true) then return fail("no [edited by you] tag") end
  -- gc queues a change on a line; gR sends it with the overall note, and
  -- the agent's next revision comes back.
  vim.api.nvim_set_current_win(v.plan_win)
  vim.api.nvim_win_set_cursor(v.plan_win, { 8, 0 })
  feed("gc")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Make it a thin wrapper" })
  feed("<C-s>")
  rec = PLAN.load("wi-3002")
  local req = rec.threads[#rec.threads]
  if not (req.kind == "request" and req.status == "queued" and req.line == 8) then
    return fail("gc didn't queue a change on line 8: " .. vim.inspect(req))
  end
  if drawn(v.plan_buf, "\u{270E} Make it a thin wrapper") ~= 8 or not vim.wo[v.plan_win].winbar:find("1 queued", 1, true) then
    return fail("the queued change isn't drawn under line 8 / counted")
  end
  n = #st.entries
  feed("gR")
  feed("<C-s>")
  e = answered(n)
  if not (e and e.text:find("requests: 1", 1, true)) then return fail("gR didn't send the line's change: " .. vim.inspect(e and e.text)) end
  rec = PLAN.load("wi-3002")
  if #rec.revisions ~= 3 or rec.status ~= "draft" or rec.threads[#rec.threads].status ~= "sent" then
    return fail("the revision after gR went wrong: " .. vim.inspect({ #rec.revisions, rec.status }))
  end
  if not table.concat(vim.api.nvim_buf_get_lines(v.plan_buf, 0, -1, false), "\n"):find("thin wrapper", 1, true)
      or not drawn(v.plan_buf, "sent with your change request") then
    return fail("the plan pane doesn't show the new revision with the sent change")
  end
  -- What revision 3 changed against yours: line 8 marked, your Open
  -- questions shown as taken out; gi turns the marks off.
  local sns = vim.api.nvim_get_namespaces()["azure_cli_plan_since"]
  local bar8, removed = false, false
  local qline
  for i, l in ipairs(vim.api.nvim_buf_get_lines(v.plan_buf, 0, -1, false)) do
    if l == "- Should admins be exempt?" then qline = i end
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(v.plan_buf, sns, 0, -1, { details = true })) do
    if m[2] == 7 and m[4].sign_text then bar8 = true end
    -- Your hand-written question: taken out, or rewritten as the agent's.
    if qline and m[2] == qline - 1 and m[4].sign_text then removed = true end
    for _, vl in ipairs(m[4].virt_lines or {}) do
      if vl[1][1]:find("Should admins be exempt?", 1, true) then removed = true end
    end
  end
  if not (bar8 and removed and vim.wo[v.plan_win].winbar:find("since rev 2", 1, true)) then
    return fail("revision 3's changes aren't marked: " .. vim.inspect({ bar8, removed, vim.wo[v.plan_win].winbar }))
  end
  if not table.concat(vim.api.nvim_buf_get_lines(v.list_buf, 0, -1, false), "\n"):match("Approach[^\n]*\u{00B1}") then
    return fail("the section list doesn't mark Approach as changed")
  end
  vim.api.nvim_set_current_win(v.plan_win)
  feed("gi")
  if #vim.api.nvim_buf_get_extmarks(v.plan_buf, sns, 0, -1, {}) ~= 0 then return fail("gi didn't turn the marks off") end
  feed("gi")
  -- gr on the plan's open question: your answer under it, sent with the approval.
  if not vim.wo[v.plan_win].winbar:find("1 to answer", 1, true) then return fail("no [1 to answer]: " .. vim.wo[v.plan_win].winbar) end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(v.plan_buf, 0, -1, false)) do
    if l == "- Should admins be exempt?" then vim.api.nvim_win_set_cursor(v.plan_win, { i, 0 }) end
  end
  feed("gr")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "No, admins too." })
  feed("<C-s>")
  if not drawn(v.plan_buf, "\u{21AA} you: No, admins too.") or vim.wo[v.plan_win].winbar:find("to answer", 1, true) then
    return fail("the answer isn't under its question, or still counted as open")
  end
  -- gA: approved; the agent starts the story now and shows the change.
  vim.api.nvim_set_current_win(v.plan_win)
  n = #st.entries
  pick = "let it push and open the PR once the tests pass"
  feed("gA")
  pick = "Allow"  -- the agent's run_tests asks next
  local strip_running = CHAT.strip()
  if not strip_running:find("Fake Claude", 1, true) or strip_running:find("waits for you", 1, true) then
    return fail("while it works the strip should name the agent, with no plan waiting: " .. strip_running)
  end
  e = answered(n)
  if not e then return fail("no answer after approving") end
  if not PLAN.load("wi-3002").allow_push or not vim.wo[v.plan_win].winbar:find("may push", 1, true) then
    return fail("approving with pushing allowed didn't stick: " .. vim.wo[v.plan_win].winbar)
  end
  if PLAN.load("wi-3002").status ~= "approved" or not e.text:find("start_story: {", 1, true)
      or not e.text:find("show_fix:", 1, true) then
    return fail("approving didn't let the story start: " .. e.text)
  end
  if st.entries[n + 1].text ~= "Approved the plan for #3002 (it may push and open the PR once the tests pass)." then
    return fail("the approval isn't in the chat as such: " .. st.entries[n + 1].text)
  end
  if not e.text:find('"passed":true', 1, true) then return fail("run_tests (asked, allowed) didn't pass: " .. e.text) end
  if not e.text:find("answers: - Should admins be exempt? No, admins too.", 1, true) then
    return fail("the approval didn't carry your answer: " .. e.text)
  end
  -- ga in the change viewer, on the agent's new line.
  local cbuf = vim.fn.bufnr("azure-cli://changes")
  local cwin = cbuf > 0 and vim.fn.win_findbuf(cbuf)[1]
  if not cwin then return fail("show_fix didn't open the change viewer") end
  local clist = table.concat(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), "\n")
  for _, s in ipairs({ "In the diff:", " ga  ask about a line", " gy  accept a hunk", " gb  run the plan's tests", " ?   all keys" }) do
    if not clist:find(s, 1, true) then return fail("the change list's keys lack " .. s .. ":\n" .. clist) end
  end
  local function v_list_win()
    return vim.fn.win_findbuf(vim.fn.bufnr("azure-cli://changes"))[1]
  end
  local function diff_winbar()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(cwin))) do
      if w ~= cwin and (vim.wo[w].winbar or ""):find("src/", 1, true) then return vim.wo[w].winbar end
    end
    return ""
  end
  if not diff_winbar():find("tests passed", 1, true) then
    return fail("the change viewer doesn't show the tests' result: " .. diff_winbar())
  end
  -- The plan listed src/throttle.py too: the viewer and show_fix say so.
  local listed = table.concat(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), "\n")
  if not (listed:find("In the plan, not changed:", 1, true) and listed:find("    src/throttle.py", 1, true))
      -- (Neovim 0.9's vim.json writes "/" as "\/".)
      or not e.text:gsub("\\/", "/"):find('"planned_not_changed":["src/throttle.py"]', 1, true)
      or not vim.wo[cwin].winbar:find("1 untouched", 1, true) then
    return fail("the change wasn't checked against the plan:\n" .. listed .. "\n" .. e.text)
  end
  vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(cwin))
  local dwin, drow
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
      if l == "PLANNED_CHANGE = True" then dwin, drow = w, i end
    end
  end
  if not dwin then return fail("the change viewer doesn't show the planned change") end
  vim.api.nvim_set_current_win(dwin)
  vim.api.nvim_win_set_cursor(dwin, { drow, 0 })
  feed("ga")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Why did you choose this?" })
  feed("<C-s>")
  local dbuf = vim.api.nvim_win_get_buf(dwin)
  local okd = vim.wait(40000, function() return drawn(dbuf, "BECAUSE-PLANNED_CHANGE = True") ~= nil end, 100)
  if not okd then return fail("the question in the change viewer wasn't answered under its line") end
  if drawn(dbuf, "BECAUSE-PLANNED_CHANGE") ~= drow then return fail("the change viewer's answer is on the wrong line") end
  -- r keeps it there; K shows it whole.
  feed("r")
  vim.wait(5000, function() return false end, 50)
  dbuf = vim.api.nvim_win_get_buf(dwin)
  vim.api.nvim_win_set_cursor(dwin, { drow, 0 })
  if drawn(dbuf, "BECAUSE-PLANNED_CHANGE") ~= drow then return fail("r lost the question under the line") end
  feed("K")
  if not float_text():find("BECAUSE-PLANNED_CHANGE", 1, true) then return fail("K didn't show the question") end
  feed("q")
  -- show_fix's steps: the line is marked with its plan line (the step
  -- pointing outside the plan was dropped), gp goes there, gd comes back.
  if not e.text:find('"steps_linked":1', 1, true) then return fail("show_fix didn't keep exactly the one good step: " .. e.text) end
  local lns = vim.api.nvim_get_namespaces()["azure_cli_chat_changes_links"]
  local marked
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(dbuf, lns, 0, -1, { details = true })) do
    if (m[4].virt_text or {})[1] and m[4].virt_text[1][1]:find("plan:7 the reason code", 1, true) then marked = m[2] + 1 end
  end
  if marked ~= drow then return fail("the planned line isn't marked with its plan line: " .. tostring(marked)) end
  vim.api.nvim_set_current_win(dwin)
  vim.api.nvim_win_set_cursor(dwin, { drow, 0 })
  feed("gp")
  v = PLAN.current()
  if vim.api.nvim_get_current_win() ~= v.plan_win or vim.api.nvim_win_get_cursor(v.plan_win)[1] ~= 7 then
    return fail("gp didn't open the plan at line 7: " .. vim.api.nvim_win_get_cursor(0)[1])
  end
  feed("gd")
  local back = vim.wait(10000, function()
    return vim.api.nvim_get_current_line() == "PLANNED_CHANGE = True"
  end, 50)
  if not back then return fail("gd on the plan line didn't come back to the code: " .. vim.api.nvim_get_current_line()) end
  dwin = vim.api.nvim_get_current_win()
  -- c queues a change on the line, gS sends the queue in one message.
  feed("c")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Name it LOCKOUT_REASON" })
  feed("<C-s>")
  dbuf = vim.api.nvim_win_get_buf(dwin)
  if not drawn(dbuf, "\u{270E} Name it LOCKOUT_REASON") or not vim.wo[dwin].winbar:find("1 queued", 1, true) then
    return fail("c didn't queue the change under the line: " .. vim.wo[dwin].winbar)
  end
  -- Sent from here with gS, not the plan's gR.
  if not drawn(dbuf, "queued - gS sends it") then return fail("the queued change doesn't say gS sends it") end
  n = #st.entries
  feed("gS")
  feed("<C-s>")
  e = answered(n)
  if not (e and e.text:find("fix requests: 1", 1, true)) then return fail("gS didn't send the queued change: " .. vim.inspect(e and e.text)) end
  if not drawn(dbuf, "sent with your change request") then return fail("the sent change isn't marked as sent") end
  -- gy accepts the hunk (a ✓, counted), gy again takes that back; gn
  -- takes it out of the worktree after asking.
  vim.api.nvim_set_current_win(dwin)
  vim.api.nvim_win_set_cursor(dwin, { drow, 0 })
  local hns = vim.api.nvim_get_namespaces()["azure_cli_chat_changes_hunks"]
  feed("gy")
  if #vim.api.nvim_buf_get_extmarks(dbuf, hns, 0, -1, {}) == 0 or not vim.wo[dwin].winbar:find("1/1 accepted", 1, true) then
    return fail("gy didn't accept the hunk: " .. vim.wo[dwin].winbar)
  end
  feed("gy")
  if #vim.api.nvim_buf_get_extmarks(dbuf, hns, 0, -1, {}) ~= 0 then return fail("gy again didn't take the accept back") end
  pick = "Yes"  -- take the hunk out
  feed("gn")
  local wt = require("azure-cli.chat.tools_fix").find_story(3002)
  local gone = vim.wait(10000, function()
    return not table.concat(vim.fn.readfile(wt .. "/src/auth.py"), "\n"):find("PLANNED_CHANGE", 1, true)
  end, 50)
  if not gone then return fail("gn didn't take the hunk out of the worktree") end
  local noted = vim.wait(5000, function()
    return st.entries[#st.entries].role == "note" and st.entries[#st.entries].text:find("took a change out", 1, true) ~= nil
  end, 50)
  if not noted then return fail("taking the hunk out left no note in the chat") end
  -- The tests ran on the change as it was: the list says so now.
  local stale = vim.wait(5000, function()
    cwin = v_list_win()
    return cwin and diff_winbar():find("tests stale - last run passed", 1, true) ~= nil
  end, 50)
  if not stale then return fail("the tests' result isn't marked stale: " .. diff_winbar()) end
  vim.ui.select = real_select
  -- create_pull_request without a description gets the plan's; with one
  -- and from_plan, both; the question shows it.
  local desc = PLAN.description_for(nil, false, { 3002 }, "feature/3002-planned")
  if not (desc:find("## Goal\nSay why a login was refused.", 1, true) and desc:find("_From the plan for #3002", 1, true)) then
    return fail("the PR description isn't the plan's: " .. desc)
  end
  if not PLAN.description_for("Mine.", true, nil, "feature/3002-planned"):find("^Mine%.\n\n## Goal") then
    return fail("from_plan didn't add the plan after the description (found by its branch)")
  end
  if PLAN.description_for("Mine.", false, { 3002 }, "x") ~= "Mine." then return fail("a given description was changed") end
  local shown
  require("azure-cli.chat.tools").by_name.create_pull_request.details({ work_item_ids = { 3002 } }, function(l) shown = l end)
  if not (shown and table.concat(shown, "\n"):find("Description:\n\n## Goal", 1, true)) then
    return fail("create_pull_request's question doesn't show the description")
  end

  -- gH in the plan: the run log, with everything that happened.
  vim.api.nvim_set_current_tabpage(v.tab)
  vim.api.nvim_set_current_win(v.plan_win)
  feed("gH")
  local logtext = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  for _, s in ipairs({ "# Run log: #3002 Lockout reason codes", "## Timeline", "Revision 1, by the agent", "Revision 2, edited by you",
    "You asked about plan line", "You asked for a change on plan line 8", "You asked for changes: See my comments",
    "Approved revision 3 - pushing allowed", "Agent: submit_plan", "Tests (grep -q PLANNED_CHANGE src/auth.py): \u{2713} tests passed",
    "You took out a change to src/auth.py", "You asked about src/auth.py:", "## Last test run", "## The plan (as it is now)" }) do
    if not logtext:find(s, 1, true) then return fail("the run log lacks \"" .. s .. "\":\n" .. logtext) end
  end
  vim.cmd("tabclose")
  -- ga on one of the agent's steps in the conversation: asked about it.
  CHAT.show(false)
  local lw = st.wins[vim.api.nvim_get_current_tabpage()].log
  local lb = vim.api.nvim_win_get_buf(lw)
  -- That turn's tool calls are folded into one line; <Tab> there lists them.
  local fold_row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(lb, 0, -1, false)) do
    if l:find("(<Tab> shows them)", 1, true) then fold_row = i end
  end
  if not fold_row then return fail("the approval turn's tool calls aren't folded into one line") end
  vim.api.nvim_set_current_win(lw)
  vim.api.nvim_win_set_cursor(lw, { fold_row, 0 })
  feed("<Tab>")
  local step_row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(lb, 0, -1, false)) do
    if l:find("show_fix (", 1, true) then step_row = i end
  end
  if not step_row then return fail("no show_fix step in the conversation") end
  vim.api.nvim_set_current_win(lw)
  vim.api.nvim_win_set_cursor(lw, { step_row, 0 })
  n = #st.entries
  feed("ga")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Why did you do this?" })
  feed("<C-s>")
  e = answered(n)
  if not (e and e.text:find("BECAUSE-", 1, true) and e.text:find("show_fix", 1, true)) then
    return fail("ga on a step didn't ask about it: " .. vim.inspect(e and e.text))
  end
  if not st.entries[n + 1].text:find("Why did you do this?  (about: ", 1, true) then
    return fail("the question isn't in the chat as asked: " .. st.entries[n + 1].text)
  end
  CHAT.hide()
  print("== the plan ==")
  print(table.concat(vim.api.nvim_buf_get_lines(v.list_buf, 0, -1, false), "\n"))
  pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(dwin)))
  pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(v.tab))
  print("PLAN-SMOKE-OK")
end
-- Several agents at once: gP on two work items of the board starts one
-- agent each (chat.max_agents = 1 here, so the second waits for the
-- first); each plans in a conversation of its own, in the background - no
-- tab opens - and the main conversation is left alone.
do
  local CHAT = require("azure-cli.chat")
  local STATE = require("azure-cli.state")
  local PLAN = require("azure-cli.chat.plan")
  local AGENTS = require("azure-cli.chat.agents")
  local fake_chat = require("azure-cli.config").plugin_root() .. "/tests/fake-chat-agent.py"
  require("azure-cli").setup({ ui = { confirm = "select" }, chat = { max_agents = 1, agent = { label = "Fake Claude", timeout_seconds = 60,
    cmd = { "python3", fake_chat, "--mcp-config", "{mcp_config}" } } } })
  local main_turns = #STATE.chat.entries
  local before3002 = #((PLAN.load("wi-3002") or { revisions = {} }).revisions)
  local bw = vim.fn.win_findbuf(wis)[1]
  if not bw then return fail("the work-items board isn't showing") end
  vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(bw))
  vim.api.nvim_set_current_win(bw)
  local board_tab = vim.api.nvim_get_current_tabpage()
  goto_row(3001)
  feed("gP")
  goto_row(3002)
  feed("gP")
  if #AGENTS.queued() ~= 1 or AGENTS.working() ~= 1 then
    return fail("with max_agents = 1 the second agent should wait: " .. #AGENTS.queued() .. " queued, " .. AGENTS.working() .. " working")
  end
  -- The Agents screen, meanwhile: #3001 working, #3002 waiting its turn.
  feed("A")
  local av = require("azure-cli.chat.agents_view").current()
  if not av or vim.api.nvim_get_current_buf() ~= av.buf then return fail("A on the board didn't open the Agents screen") end
  local function screen() return table.concat(vim.api.nvim_buf_get_lines(av.buf, 0, -1, false), "\n") end
  if not (screen():match("#3001[^\n]*working") and screen():match("#3002[^\n]*waiting for an agent")) then
    return fail("the Agents screen doesn't show one working and one waiting:\n" .. screen())
  end
  if not vim.wo[av.win].winbar:find("1 working", 1, true) then return fail("the Agents winbar: " .. vim.wo[av.win].winbar) end
  local both = vim.wait(60000, function()
    local a, b = PLAN.load("wi-3001"), PLAN.load("wi-3002")
    return a and a.status == "draft" and b and #b.revisions > before3002 and b.status == "draft"
      and AGENTS.working() == 0 and #AGENTS.queued() == 0
  end, 100)
  if not both then return fail("the two board agents didn't both plan: " .. vim.inspect({ AGENTS.working(), #AGENTS.queued() })) end
  local c1, c2 = CHAT.find_conversation("wi-3001"), CHAT.find_conversation("wi-3002")
  if not (c1 and c2 and c1 ~= c2 and c1.agent_id ~= c2.agent_id) then return fail("not one conversation per plan") end
  local function answer(c) local e = c.entries[#c.entries] return e and e.text or "" end
  if not answer(c1):find("planned #3001 as agent " .. c1.agent_id, 1, true)
      or not answer(c2):find("planned #3002 as agent " .. c2.agent_id, 1, true) then
    return fail("each agent's calls didn't reach its own conversation:\n" .. answer(c1) .. "\n" .. answer(c2))
  end
  if #STATE.chat.entries ~= main_turns then return fail("the main conversation got the agents' turns") end
  -- They run in the repository's clone, so they can read the code they plan for.
  if not (answer(c1):find(" in widgets", 1, true) and answer(c2):find(" in widgets", 1, true)) then
    return fail("a board agent didn't start in the widgets clone:\n" .. answer(c1) .. "\n" .. answer(c2))
  end
  if vim.api.nvim_get_current_tabpage() ~= vim.api.nvim_win_get_tabpage(av.win) then
    return fail("a background agent pulled the focus into its plan")
  end
  -- Both plans wait for you now; <CR> on #3001's row opens its plan.
  vim.wait(3000, function()
    return screen():match("#3001[^\n]*plan waits for you") ~= nil and screen():match("#3002[^\n]*plan waits for you") ~= nil
  end, 100)
  if not (screen():match("#3001[^\n]*plan waits for you") and screen():match("#3002[^\n]*plan waits for you")) then
    return fail("the Agents screen doesn't show both plans waiting:\n" .. screen())
  end
  if not screen():find("gA approve (2 waiting)", 1, true) then
    return fail("the Agents screen's keys don't offer approving both:\n" .. screen())
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(av.buf, 0, -1, false)) do
    if l:find("#3001", 1, true) then vim.api.nvim_win_set_cursor(av.win, { i, 0 }) end
  end
  feed("<CR>")
  if not (PLAN.current() and PLAN.current().key == "wi-3001" and vim.api.nvim_get_current_tabpage() == PLAN.current().tab) then
    return fail("<CR> on #3001's row didn't open its plan")
  end
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(av.win))
  vim.api.nvim_set_current_win(av.win)
  if not CHAT.strip():find("2 plans wait for you", 1, true) then return fail("the strip doesn't count both plans: " .. CHAT.strip()) end
  -- gA on both rows (visual): one question, each plan approved and its own
  -- agent sets off implementing it - both at once.
  local real_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    for i, it in ipairs(items) do
      local label = opts.format_item and opts.format_item(it) or tostring(it)
      if label == "Approve" then return cb(it, i) end  -- no "Allow": run_tests must not ask (test_cmd)
    end
    cb(nil)
  end
  require("azure-cli").setup({ ui = { confirm = "select" }, chat = { max_agents = 2, test_cmd = { widgets = "true" },
    agent = { label = "Fake Claude", timeout_seconds = 60, cmd = { "python3", fake_chat, "--mcp-config", "{mcp_config}" } } } })
  local r1, r2
  for i, l in ipairs(vim.api.nvim_buf_get_lines(av.buf, 0, -1, false)) do
    if l:find("#3001", 1, true) then r1 = i end
    if l:find("#3002", 1, true) then r2 = i end
  end
  vim.api.nvim_win_set_cursor(av.win, { math.min(r1, r2), 0 })
  feed("V" .. math.abs(r2 - r1) .. "j")
  feed("gA")
  if PLAN.load("wi-3001").status ~= "approved" or PLAN.load("wi-3002").status ~= "approved" then
    return fail("gA on both rows didn't approve both plans")
  end
  local built = vim.wait(30000, function() return AGENTS.working() == 0 end, 100)
  vim.ui.select = real_select
  if not built then return fail("the two approved agents didn't finish") end
  for _, pair in ipairs({ { c1, 3001 }, { c2, 3002 } }) do
    local c, id = pair[1], pair[2]
    local you = c.entries[#c.entries - 1]
    if not (you.text == "Approved the plan for #" .. id .. "." and answer(c):find("implemented #" .. id, 1, true)) then
      return fail("#" .. id .. "'s approval didn't reach its own agent: " .. tostring(you.text) .. " / " .. answer(c))
    end
    -- Your chat.test_cmd ran without a question.
    local last = c.entries[#c.entries]
    if not (table.concat(last.tools or {}, "|"):find("run_tests: allowed by your chat.test_cmd", 1, true)
        and answer(c):find('"passed":true', 1, true)) then
      return fail("#" .. id .. "'s run_tests didn't run your test_cmd without asking: " .. table.concat(last.tools or {}, "|"))
    end
  end
  feed("q")
  vim.api.nvim_set_current_tabpage(board_tab)
  -- Two plans open at once, a tab each; each tab's keys, description and
  -- chat are its own plan's.
  PLAN.open("wi-3001")
  local t1 = vim.api.nvim_get_current_tabpage()
  if STATE.chat.active ~= "wi-3001" then return fail("the plan's tab doesn't show its own conversation") end
  PLAN.open("wi-3002")
  local t2 = vim.api.nvim_get_current_tabpage()
  local open = PLAN.open_views()
  if t1 == t2 or not (open["wi-3001"] and open["wi-3002"]) then return fail("the second plan replaced the first one's tab") end
  if STATE.chat.active ~= "wi-3002" then return fail("the second plan's tab doesn't show its own conversation") end
  local d1 = require("azure-cli.chat.view").snapshot(open["wi-3001"].plan_win)
  if not (d1.plan and d1.plan.key == "wi-3001") then return fail("the first plan's window describes another plan: " .. vim.inspect(d1.plan)) end
  vim.api.nvim_set_current_tabpage(t1)
  vim.api.nvim_set_current_win(open["wi-3001"].plan_win)
  CHAT.sync_active()
  if PLAN.current().key ~= "wi-3001" or STATE.chat.active ~= "wi-3001" then
    return fail("back in the first plan's tab, it isn't the current plan / conversation")
  end
  feed("gi")  -- a key acts on this tab's plan
  if not open["wi-3001"].since_off or open["wi-3002"].since_off then return fail("gi in one plan's tab toggled another's") end
  feed("gi")
  -- Two changes open at once, too.
  local TF = require("azure-cli.chat.tools_fix")
  local opened = 0
  TF.open_at({ work_item_id = 3002 }, "src/auth.py", nil, function(err) if not err then opened = opened + 1 end end)
  TF.open_at({ pr_id = 101 }, "src/auth.py", nil, function(err) if not err then opened = opened + 1 end end)
  vim.wait(10000, function() return opened == 2 end, 50)
  local tabs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:find("azure-cli://changes/", 1, true) and #vim.fn.win_findbuf(b) > 0 then
      tabs[vim.api.nvim_win_get_tabpage(vim.fn.win_findbuf(b)[1])] = require("azure-cli.chat.view").snapshot(vim.fn.win_findbuf(b)[1]).worktree
    end
  end
  local worktrees = vim.tbl_values(tabs)
  table.sort(worktrees)
  if #worktrees ~= 2 or worktrees[1] == worktrees[2] then
    return fail("two changes didn't get a tab each: " .. vim.inspect(worktrees))
  end
  for tab in pairs(tabs) do pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab)) end
  for _, tab in ipairs({ t1, t2 }) do
    if vim.api.nvim_tabpage_is_valid(tab) then pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab)) end
  end
  vim.api.nvim_set_current_tabpage(board_tab)
  CHAT.sync_active()
  if STATE.chat.active ~= nil then return fail("back on the board, the panel should show the main conversation") end
  -- With room for two (max_agents = 2), two agents really work at once.
  require("azure-cli").setup({ ui = { confirm = "select" }, chat = { max_agents = 2, agent = { label = "Fake Claude", timeout_seconds = 60,
    cmd = { "python3", fake_chat, "--mcp-config", "{mcp_config}" } } } })
  vim.api.nvim_set_current_win(bw)
  goto_row(3001)
  feed("gP")
  goto_row(3002)
  feed("gP")
  if AGENTS.working() ~= 2 or #AGENTS.queued() ~= 0 then
    return fail("with max_agents = 2 both should work at once: " .. AGENTS.working() .. " working, " .. #AGENTS.queued() .. " queued")
  end
  if not CHAT.strip():find("2 agents working", 1, true) then return fail("the strip doesn't count two agents: " .. CHAT.strip()) end
  local together = vim.wait(30000, function() return AGENTS.working() == 0 end, 100)
  if not together then return fail("the two agents working at once didn't both finish") end
  for _, c in ipairs({ c1, c2 }) do
    local e = c.entries[#c.entries]
    if not (e.status == "done" and e.text:find("planned #", 1, true)) then
      return fail("a parallel agent's answer went wrong: " .. vim.inspect(e.text))
    end
  end
  if #STATE.chat.entries ~= main_turns then return fail("the main conversation got the parallel agents' turns") end
  -- gP on PR dashboard rows (visual): an agent per PR, each planning the
  -- fix of its review comments.
  local dw = vim.fn.win_findbuf(dash)[1]
  if not dw then return fail("the PR dashboard isn't showing") end
  vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(dw))
  vim.api.nvim_set_current_win(dw)
  local row101, row102
  for i, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
    if l:find("#101 ", 1, true) then row101 = i end
    if l:find("#102 ", 1, true) then row102 = i end
  end
  vim.api.nvim_win_set_cursor(dw, { math.min(row101, row102), 0 })
  feed("V" .. math.abs(row102 - row101) .. "j")
  feed("gP")
  local prs_done = vim.wait(30000, function()
    local a, b = PLAN.load("pr-101"), PLAN.load("pr-102")
    return a and a.status == "draft" and b and b.status == "draft" and AGENTS.working() == 0 and #AGENTS.queued() == 0
  end, 100)
  if not prs_done then return fail("gP on the dashboard rows didn't plan PR !101 and !102") end
  local p1 = CHAT.find_conversation("pr-101")
  if not (p1 and p1.label == "PR !101" and answer(p1):find("planned PR !101 for every active thread", 1, true)) then
    return fail("PR !101's agent: " .. (p1 and answer(p1) or "none"))
  end
  -- The PR dashboard's agent column shows !101's agent, and ga opens its
  -- conversation in a popup; q closes it again.
  CHAT.hide()
  vim.api.nvim_set_current_win(dw)
  local cols = vim.o.columns
  vim.o.columns = 200
  vim.cmd("only")
  pcall(vim.api.nvim_exec_autocmds, "VimResized", {})
  local function dash_row(id)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
      if l:find("#" .. id .. " ", 1, true) then return i, l end
    end
  end
  local shows = vim.wait(8000, function()
    local _, l = dash_row(101)
    return l and l:find("plan waits", 1, true) ~= nil
  end, 100)
  if not shows then return fail("the dashboard's agent column doesn't show !101's plan waiting", dash) end
  local hdr = false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
    if l:find("threads", 1, true) and l:find("agent", 1, true) then hdr = true end
  end
  if not hdr then return fail("the dashboard has no agent column header", dash) end
  vim.api.nvim_win_set_cursor(dw, { (dash_row(101)), 0 })
  feed("ga")
  local pw = CHAT.popup_wins()
  if not (pw and pw.key == "pr-101" and vim.api.nvim_get_current_win() == pw.log) then
    return fail("ga on #101 didn't open its agent's chat in a popup: " .. vim.inspect(pw))
  end
  local ptext = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pw.log), 0, -1, false), "\n")
  if not ptext:find("planned PR !101", 1, true) then return fail("the popup doesn't show !101's conversation:\n" .. ptext) end
  feed("q")
  vim.wait(500, function() return CHAT.popup_wins() == nil end, 20)
  if CHAT.popup_wins() or vim.api.nvim_win_is_valid(pw.log) or STATE.chat.popup_key then
    return fail("q didn't close the agent popup")
  end
  vim.o.columns = cols
  -- gP in the reviewer, on a commented line: just that thread.
  require("azure-cli").open_review(101)
  local landed = vim.wait(20000, function()
    local o = STATE.review_openers and STATE.review_openers["101"]
    return o and o("src/auth.py", "R", 12)
  end, 100)
  if not landed then return fail("the reviewer didn't open auth.py:12 for gP") end
  vim.wait(3000, function()
    local s = require("azure-cli.chat.view").snapshot(vim.api.nvim_get_current_win())
    return type(s.thread) == "table"
  end, 50)
  local tsnap = require("azure-cli.chat.view").snapshot(vim.api.nvim_get_current_win())
  if type(tsnap.thread) ~= "table" then return fail("no thread under the cursor at auth.py:12: " .. vim.inspect(tsnap.line)) end
  feed("gP")
  local one = vim.wait(30000, function()
    return answer(p1):find("planned PR !101 for " .. tostring(tsnap.thread.id), 1, true) ~= nil and AGENTS.working() == 0
  end, 100)
  if not one then return fail("gP on thread " .. tostring(tsnap.thread.id) .. " in the reviewer: " .. answer(p1)) end
  for _, c in ipairs(CHAT.conversations()) do
    if c ~= STATE.chat and c.persistent_job then pcall(vim.fn.jobstop, c.persistent_job.job) end
  end
  print("AGENTS-SMOKE-OK")
end
-- Batch review: gQ shows the place of the queued comment under the cursor
-- in the diff pane as it moves (focus stays in the list), <Tab> goes there;
-- gS sends the queue - everything at once - and leaving mid-send doesn't
-- count it as still queued.
do
  local STATE = require("azure-cli.state")
  local PANE = require("azure-cli.review.pane")
  local real_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    for i, it in ipairs(items) do
      local label = opts.format_item and opts.format_item(it) or tostring(it)
      if label:find("No vote", 1, true) then return cb(it, i) end
    end
    return cb(nil)
  end
  local opener = STATE.review_openers and STATE.review_openers["101"]
  if not (opener and opener()) then return fail("the reviewer for PR #101 isn't open for the batch check") end
  local s = STATE.batch["101"]
  for i = #s.items, 1, -1 do STATE.batch_drop["101"](s.items[i]) end
  -- A queued reply dropped after a background refresh is gone from the
  -- diff at once (the refresh re-carries it into a new copy of its thread).
  local function drawn_anywhere(text)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
          if l:find(text, 1, true) then return true end
        end
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do
          for _, vl in ipairs(m[4].virt_lines or {}) do
            for _, chunk in ipairs(vl) do if (chunk[1] or ""):find(text, 1, true) then return true end end
          end
          for _, chunk in ipairs(m[4].virt_text or {}) do if (chunk[1] or ""):find(text, 1, true) then return true end end
        end
      end
    end
  end
  local fst = vim.json.decode(table.concat(vim.fn.readfile(vim.env.AZVICLI_FAKE_WS .. "/state.json"), "\n"))
  local tid
  for _, t in ipairs(fst.threads["101"]) do
    if t.comments[1].content:find("distinct error", 1, true) then tid = t.id end
  end
  if not tid then return fail("no auth.py:12 thread on PR #101 for the queued-reply check") end
  -- Bob's thread's count as drawn ("N comments — Bob Brown"). Counted from
  -- the screen, not the fake's state: an earlier block writes Alice's reply
  -- into the state, and whether a given refresh has read it yet varies.
  local function bob_count()
    local n
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do
          for _, chunk in ipairs(m[4].virt_text or {}) do
            local c = (chunk[1] or ""):match("(%d+) comments \u{2014} Bob Brown")
            if c then n = math.max(n or 0, tonumber(c)) end
          end
        end
      end
    end
    return n
  end
  local function refresh()
    local refreshed = false
    -- A poll already in flight skips this one, so ask until one runs.
    return vim.wait(15000, function()
      if not refreshed then STATE.review_refresh_threads({ on_done = function() refreshed = true end }) end
      return refreshed
    end, 200)
  end
  if not refresh() then return fail("the thread refresh never finished") end
  local before = bob_count()
  if not before then return fail("Bob's thread on auth.py:12 isn't drawn for the queued-reply check") end
  if not STATE.batch_live["101"]({ kind = "reply", thread_id = tid, text = "batch smoke reply", label = "Reply",
      args = { "--reply", tostring(tid), "batch smoke reply" } }) then
    return fail("couldn't queue a reply on PR #101")
  end
  if not refresh() then return fail("the thread refresh never finished") end
  local with_reply = bob_count() or 0
  if with_reply < before + 1 then
    return fail("the queued reply doesn't show in the PR after a refresh (" .. before .. " -> " .. with_reply .. " comments)")
  end
  STATE.batch_drop["101"](s.items[#s.items])
  vim.wait(200)
  if #s.items ~= 0 then return fail("dropping the queued reply left it queued: " .. vim.inspect(s.items)) end
  if (bob_count() or 0) ~= with_reply - 1 or drawn_anywhere("batch smoke reply") then
    return fail("a queued reply dropped after a thread refresh still shows in the PR (" .. with_reply .. " -> "
      .. tostring(bob_count()) .. " comments)")
  end
  local function queue(path, line, text)
    STATE.batch_live["101"]({ kind = "thread", text = text, bucket = "line", where = path .. "\tR\t" .. line,
      path = path, side = "R", lineno = line, label = "Comment", args = { "--post", path, "R", tostring(line), text } })
  end
  queue("src/auth.py", 12, "batch smoke one")
  queue("src/throttle.py", 4, "batch smoke two")
  -- The diff pane's window, and the file/line its cursor is on.
  local function diff_at()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      local e = PANE.entry(b)
      if e and vim.api.nvim_win_get_config(w).relative == "" then
        local m = e.map and e.map[vim.api.nvim_win_get_cursor(w)[1]]
        return w, m
      end
    end
  end
  local lb = find_buf("azurecli-files")
  vim.api.nvim_set_current_win(vim.fn.bufwinid(lb))
  feed("gQ")
  local qwin = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(qwin).relative == "" then return fail("gQ didn't open the queue float") end
  local function shows(lineno)
    local _, m = diff_at()
    return m and m.side == "R" and m.lineno == lineno
  end
  ok = vim.wait(10000, function() return shows(12) end, 50)
  if not ok then return fail("gQ didn't show the first queued comment (auth.py:12) in the diff pane") end
  if vim.api.nvim_get_current_win() ~= qwin then return fail("gQ's preview took the focus away from the queue") end
  feed("j")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(qwin) })
  ok = vim.wait(10000, function() return shows(4) end, 50)
  if not ok then return fail("moving in gQ didn't show the second queued comment (throttle.py:4)") end
  feed("<Tab>")
  local dw = diff_at()
  vim.wait(5000, function() return shows(4) end, 50)
  if vim.api.nvim_win_is_valid(qwin) or vim.api.nvim_get_current_win() ~= dw or not shows(4) then
    return fail("<Tab> in gQ didn't go to throttle.py:4 in the diff pane")
  end
  -- gS: both sent; while they're out the queue counts as submitting.
  feed("gS")
  local was_submitting = s.submitting == true
  ok = vim.wait(15000, function() return #s.items == 0 and not s.submitting end, 50)
  if not ok then return fail("gS didn't send the queue: " .. vim.inspect(s.items)) end
  local log = io.open(vim.env.AZVICLI_FAKE_WS .. "/calls.log"):read("*a")
  if not (log:find("batch smoke one", 1, true) and log:find("batch smoke two", 1, true)) then
    return fail("the queued comments never reached the provider")
  end
  if not was_submitting then return fail("gS didn't mark the queue as submitting while it sent") end
  vim.ui.select = real_select

  -- My own comments aren't news: on the dashboard, PR #101's row gets no
  -- unread dot for the two comments gS just posted - and does get one once
  -- somebody else replies to one of them.
  local dwin = vim.fn.win_findbuf(dash)[1]
  if not dwin then return fail("the dashboard window is gone") end
  vim.fn.win_gotoid(dwin)
  local function row101()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
      if l:find("#101", 1, true) then return l end
    end
    return ""
  end
  feed("r")
  ok = vim.wait(15000, function() return row101():find("/5 ", 1, true) ~= nil end, 100)
  if not ok then return fail("the dashboard didn't pick up the two new threads on #101", dash) end
  -- The unread dot sits before the id (the agent column has its own dots).
  local function unread101() local l = row101() return (l:sub(1, (l:find("#101", 1, true) or 1))):find("\u{25CF}", 1, true) ~= nil end
  if unread101() then return fail("my own comments marked #101 unread", dash) end
  local path = vim.env.AZVICLI_FAKE_WS .. "/state.json"
  local st = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  local other
  for _, t in ipairs(st.threads["101"]) do
    for _, c in ipairs(t.comments) do
      if c.content ~= "batch smoke one" and not other and c.author.id ~= t.comments[#t.comments].author.id then other = c.author end
    end
  end
  for _, t in ipairs(st.threads["101"]) do
    if t.comments[1].content == "batch smoke one" then
      local c = vim.deepcopy(t.comments[1])
      c.id, c.parentCommentId, c.author, c.content = #t.comments + 1, 1, other, "a reply from someone else"
      table.insert(t.comments, c)
    end
  end
  vim.fn.writefile({ vim.json.encode(st) }, path)
  feed("r")
  ok = vim.wait(15000, function() return unread101() end, 100)
  if not ok then return fail("someone else's reply didn't mark #101 unread", dash) end
  print("BATCHQ-SMOKE-OK")
end

-- A GitHub account (github_host.py): the fake lists PR #7 from two
-- repositories. Each opens in its own reviewer, with its own threads -
-- per-PR state is keyed owner~repo~number, not by the number.
do
  local HOSTS = require("azure-cli.hosts")
  local CACHE = require("azure-cli.cache")
  vim.fn.win_gotoid(vim.fn.win_findbuf(dash)[1])
  feed("r")
  ok = vim.wait(15000, function()
    local t = text(dash)
    if not t:find("Gizmo: spin faster", 1, true) then return false end
    for _, p in ipairs(require("azure-cli.state").PR_LIST_CACHE.prs) do
      if p.title == "Doohickey: stop the wobble" then return true end
    end
    return false
  end, 100)
  if not ok then return fail("the dashboard never listed the two GitHub PR #7s", dash) end
  -- The chat keys agents "pr-<number>", which two GitHub #7s share: no
  -- agent is shown against a GitHub row until it keys by PR key.
  for _, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
    if l:find("Gizmo: spin faster", 1, true) and l:find("plan waits", 1, true) then
      return fail("a GitHub row shows an agent keyed by its bare number: " .. l)
    end
  end
  local recs = {}
  for _, p in ipairs(require("azure-cli.state").PR_LIST_CACHE.prs) do
    -- The two #7s (the Issues smoke's create_pull_request adds gizmos#8).
    if p.host == "github" and tostring(p.id) == "7" then recs[p.repo] = p end
  end
  if not (recs.gizmos and recs.doohickeys) then return fail("the GitHub records aren't in the list cache") end
  if #HOSTS.caps(recs.gizmos).votes ~= 3 or HOSTS.ref(recs.gizmos) ~= "gizmos#7" then
    return fail("a GitHub PR doesn't get GitHub's votes/ref: " .. HOSTS.ref(recs.gizmos))
  end
  local function open_and_wait(key, file)
    require("azure-cli").open_review(key)
    local b
    local opened = vim.wait(20000, function()
      for _, x in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(x) and vim.bo[x].filetype == "azurecli-files"
            and vim.b[x].azure_cli_pr_key == key and text(x):find(file, 1, true) then
          b = x
          return true
        end
      end
      return false
    end, 100)
    return opened and b or nil
  end
  local g = open_and_wait("demo-gh~gizmos~7", "gizmo.py")
  if not g then return fail("gizmos#7 never opened in the reviewer") end
  local gtab = vim.api.nvim_get_current_tabpage()
  if vim.b[g].azure_cli_pr_ref ~= "gizmos#7" then return fail("the reviewer names it " .. tostring(vim.b[g].azure_cli_pr_ref)) end
  ok = vim.wait(15000, function()
    local th = CACHE.threads("demo-gh~gizmos~7")
    return th ~= nil and th.json:find("Gizmo thread", 1, true) ~= nil
  end, 100)
  if not ok then return fail("gizmos#7's threads never loaded under its key") end
  -- gv offers GitHub's three verdicts; "Request changes" asks what needs
  -- changing and sends it with the vote, to gizmos' PR.
  require("azure-cli").setup({ ui = { confirm = "select" } })
  local real_select, real_input = vim.ui.select, vim.ui.input
  local offered
  vim.ui.select = function(items, _, cb)
    offered = {}
    for _, it in ipairs(items) do offered[#offered + 1] = it.label end
    for i, it in ipairs(items) do
      if it.label == "Request changes" then return cb(it, i) end
    end
    cb(nil)
  end
  vim.ui.input = function(_, cb) cb("rename spin()") end
  vim.api.nvim_set_current_win(vim.fn.bufwinid(g))
  feed("gv")
  -- Done, not just sent: nothing left in flight with the daemon (a request
  -- still out when the smoke quits can keep Neovim from exiting).
  local function provider_idle()
    local st = require("azure-cli.state").rpc
    return not st or next(st.pending or {}) == nil
  end
  ok = vim.wait(10000, function()
    local l = io.open(vim.env.AZVICLI_FAKE_WS .. "/calls.log"):read("*a")
    return l:find('["--vote", "-5", "rename spin()"]', 1, true) ~= nil and provider_idle()
  end, 100)
  vim.ui.select, vim.ui.input = real_select, real_input
  if table.concat(offered or {}, "|") ~= "Approve|Request changes|Dismiss my review" then
    return fail("gv on a GitHub PR offered " .. vim.inspect(offered))
  end
  if not ok then return fail("Request changes never reached the provider with its reason") end
  -- gS on GitHub: the queue goes out as one review, the Conversation reply
  -- as its body, nothing comment by comment.
  local STATE = require("azure-cli.state")
  local gkey = "demo-gh~gizmos~7"
  local live = STATE.batch_live and STATE.batch_live[gkey]
  if not (live and live({ kind = "thread", text = "native line", bucket = "line", where = "gizmo.py\tR\t2",
      path = "gizmo.py", side = "R", lineno = 2, args = { "--post", "gizmo.py", "R", "2", "native line" } })
      and live({ kind = "reply", thread_id = 0, text = "native conversation" })) then
    return fail("couldn't queue on gizmos#7")
  end
  vim.ui.select = function(items, _, cb)
    for i, it in ipairs(items) do if it.label == "Approve" then return cb(it, i) end end
    cb(nil)
  end
  vim.api.nvim_set_current_win(vim.fn.bufwinid(g))
  feed("gS")
  local review_line
  ok = vim.wait(10000, function()
    for l in io.lines(vim.env.AZVICLI_FAKE_WS .. "/calls.log") do
      if l:find('"--submit-review"', 1, true) then review_line = l end
    end
    return review_line ~= nil and #STATE.batch[gkey].items == 0
  end, 100)
  vim.ui.select = real_select
  if not ok then return fail("gS on gizmos#7 didn't submit one review: " .. vim.inspect(STATE.batch[gkey].items)) end
  if not (review_line:find("native line", 1, true) and review_line:find("native conversation", 1, true)
      and review_line:find('\\"event\\":\\"10\\"', 1, true)) then
    return fail("the review didn't carry the queue and the verdict: " .. review_line)
  end
  for l in io.lines(vim.env.AZVICLI_FAKE_WS .. "/calls.log") do
    if l:find('["--post"', 1, true) and l:find("native line", 1, true) then
      return fail("a queued comment went out on its own besides the review")
    end
  end
  vim.fn.win_gotoid(vim.fn.win_findbuf(dash)[1])
  local d = open_and_wait("demo-gh~doohickeys~7", "gizmo.py")
  if not d then return fail("doohickeys#7 never opened in the reviewer") end
  local dtab = vim.api.nvim_get_current_tabpage()
  if dtab == gtab then return fail("doohickeys#7 reused gizmos#7's tab") end
  ok = vim.wait(15000, function()
    local th = CACHE.threads("demo-gh~doohickeys~7")
    return th ~= nil and th.json:find("Doohickey thread", 1, true) ~= nil
  end, 100)
  if not ok then return fail("doohickeys#7's threads never loaded under its key") end
  if CACHE.threads("demo-gh~gizmos~7").json:find("Doohickey", 1, true) then
    return fail("doohickeys#7's threads landed in gizmos#7's cache")
  end
  local log = io.open(vim.env.AZVICLI_FAKE_WS .. "/calls.log"):read("*a")
  if not log:find("AZVICLI_REPO=doohickeys", 1, true) then
    return fail("no provider call named the doohickeys repository")
  end
  -- Back in gizmos#7's tab, a vote is gizmos' - though opening doohickeys
  -- rewrote the global AZVICLI_* environment since (the reviewer pins its
  -- own PR on every call).
  vim.api.nvim_set_current_tabpage(gtab)
  vim.api.nvim_set_current_win(vim.fn.bufwinid(g))
  vim.ui.select = function(items, _, cb) cb(items[1], 1) end
  feed("gv")
  local vote_line
  ok = vim.wait(10000, function()
    for l in io.lines(vim.env.AZVICLI_FAKE_WS .. "/calls.log") do
      if l:find('["--vote", "10"]', 1, true) then vote_line = l end
    end
    return vote_line ~= nil and provider_idle()
  end, 100)
  vim.ui.select = real_select
  if not ok then return fail("Approve from gizmos#7's tab never reached the provider") end
  if not vote_line:find("AZVICLI_REPO=gizmos ", 1, true) then
    return fail("a vote from gizmos#7's tab went to another PR: " .. vote_line)
  end
  vim.wait(10000, provider_idle, 100)
  vim.api.nvim_set_current_tabpage(dtab)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(gtab)
  vim.cmd("tabclose")

  -- gm on GitHub: the dialog reads the PR's mergeability fresh (--get-pr),
  -- speaks GitHub's words and offers only the repo's methods. doohickeys#7
  -- is blocked by a required check: <CR> says so and merges nothing, while
  -- auto-merge, which waits it out, can be set and cancelled.
  local function calls(pat, repo)
    local n = 0
    for l in io.lines(vim.env.AZVICLI_FAKE_WS .. "/calls.log") do
      if l:find(pat, 1, true) and (not repo or l:find("AZVICLI_REPO=" .. repo .. " ", 1, true)) then n = n + 1 end
    end
    return n
  end
  local function gm_on(title)
    vim.fn.win_gotoid(vim.fn.win_findbuf(dash)[1])
    -- doohickeys#7 is signed off (I approved it), a section that starts
    -- collapsed: <Space> on its header opens it.
    local hrow, hl = header_row(dash, "\u{2500}\u{2500} Signed off")
    if hrow and hl:find("(collapsed)", 1, true) then
      vim.api.nvim_win_set_cursor(0, { hrow, 0 })
      feed("<Space>")
    end
    for i, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
      if l:find(title, 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        feed("gm")
        local up = vim.wait(10000, function()
          local f = float_text()
          return f ~= nil and f:find("Merge PR ", 1, true) ~= nil
        end, 50)
        return up and float_text() or nil
      end
    end
  end
  local dlg = gm_on("Doohickey: stop the wobble")
  if not dlg then return fail("gm on doohickeys#7 never opened the merge dialog", dash) end
  if not (dlg:find("Merge PR doohickeys#7", 1, true) and dlg:find("\u{2717} ci / test  (required)", 1, true)
      and dlg:find("\u{26D4} Can't merge: required check `ci / test` failed", 1, true)
      and dlg:find("Auto-merge when requirements pass", 1, true)) then
    return fail("the GitHub merge dialog doesn't show the blocked check:\n" .. dlg)
  end
  if dlg:find("work items", 1, true) then return fail("the GitHub merge dialog offers to complete work items:\n" .. dlg) end
  feed("m")
  if not float_text():find("Merge type: Create a merge commit", 1, true) then return fail("m didn't cycle to merge") end
  feed("m")
  if not float_text():find("Merge type: Squash and merge", 1, true) then
    return fail("m offered a method the repo doesn't allow:\n" .. float_text())
  end
  feed("<CR>")
  vim.wait(300)
  if not (float_text() or ""):find("Merge PR doohickeys#7", 1, true) then
    return fail("<CR> on a blocked PR closed the dialog")
  end
  if calls('"--complete"', "doohickeys") > 0 then return fail("<CR> on a blocked PR sent --complete") end
  -- The auto-merge row (6: no work-items row on GitHub), then <CR>.
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  feed("<Space>")
  if not float_text():find("[-] Delete source branch: the repo's setting decides (off)", 1, true) then
    return fail("auto-merge doesn't say the repo's setting deletes the branch:\n" .. float_text())
  end
  feed("<CR>")
  ok = vim.wait(10000, function()
    return calls('["--auto-complete", "on", "squash"', "doohickeys") == 1 and provider_idle()
  end, 100)
  if not ok then return fail("auto-merge on doohickeys#7 never reached the provider") end
  dlg = gm_on("Doohickey: stop the wobble")
  if not (dlg and dlg:find("(on", 1, true) and dlg:find("x: cancel auto-merge", 1, true)) then
    return fail("gm doesn't show auto-merge as on:\n" .. tostring(dlg))
  end
  feed("x")
  ok = vim.wait(10000, function() return calls('["--auto-complete", "off"]', "doohickeys") == 1 and provider_idle() end, 100)
  if not ok then return fail("x never cancelled auto-merge on doohickeys#7") end

  -- gizmos#7 is mergeable: <CR> merges it with the branch deleted, and its
  -- row leaves the dashboard.
  ok = vim.wait(10000, function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(dash, 0, -1, false)) do
      if l:find("Gizmo: spin faster", 1, true) then return true end
    end
  end, 100)
  dlg = ok and gm_on("Gizmo: spin faster")
  if not (dlg and dlg:find("Merge PR gizmos#7", 1, true) and not dlg:find("Can't merge", 1, true)
      and not dlg:find("Auto-merge", 1, true)) then
    return fail("gm on gizmos#7 (clean, no auto-merge allowed) shows:\n" .. tostring(dlg))
  end
  feed("<CR>")
  ok = vim.wait(10000, function()
    if not (calls('["--complete", "squash", "true"', "gizmos") == 1 and provider_idle()
        and not text(dash):find("Gizmo: spin faster", 1, true)) then
      return false
    end
    for _, p in ipairs(STATE.PR_LIST_CACHE.prs) do
      if p.host == "github" and p.repo == "gizmos" and tostring(p.id) == "7" then return false end
    end
    return true
  end, 100)
  if not ok then return fail("gm on gizmos#7 didn't merge it and drop its row", dash) end

  -- The agent's complete_pull_request: doohickeys#7 (now the only #7) is
  -- refused with GitHub's reason, and a method its repo lacks is refused
  -- before any call.
  local TOOLS = require("azure-cli.chat.tools")
  local said
  local env = { main_win = function() end, log = function() end, confirm = function(_, cb) cb(true) end }
  TOOLS.call("complete_pull_request", { pr_id = 7, strategy = "rebase" }, env, function(t, e) said = { t, e } end)
  ok = vim.wait(5000, function() return said ~= nil end, 50)
  if not (ok and said[2] and said[1]:find("rebase isn't a merge strategy doohickeys#7 allows: squash, merge", 1, true)) then
    return fail("complete_pull_request took a method the repo lacks: " .. vim.inspect(said))
  end
  said = nil
  TOOLS.call("complete_pull_request", { pr_id = 7 }, env, function(t, e) said = { t, e } end)
  ok = vim.wait(10000, function() return said ~= nil and provider_idle() end, 100)
  if not (ok and said[2] and said[1]:find("Can't merge PR #7: required check `ci / test` failed", 1, true)) then
    return fail("complete_pull_request on a blocked GitHub PR answered " .. vim.inspect(said))
  end
  print("GITHUB-SMOKE-OK")
end
print("DEMO-SMOKE-OK")
vim.cmd("qa!")
