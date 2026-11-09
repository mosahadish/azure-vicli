-- test-mdrender.lua: mdrender.lua - markdown drawn rendered: tables as boxes, markers hidden. The
-- pure half (split_row, delim, find, inline, layout) and, on Neovim 0.11+,
-- a buffer drawn on the screen: the table's lines hidden, the box in their
-- place, the raw text back while the cursor is in it.
--
-- Usage: nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-mdrender.lua"
-- Prints MDRENDER-OK when everything passed.

dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local M = require("azure-cli.mdrender")

local fails = 0
local function check(name, ok, got)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. (ok and "" or ("  got: " .. vim.inspect(got))))
  if not ok then fails = fails + 1 end
end

check("split_row", vim.deep_equal(M.split_row("| a | `x|y` | c \\| d |"), { "a", "`x|y`", "c | d" }),
  M.split_row("| a | `x|y` | c \\| d |"))
check("split_row without outer pipes", vim.deep_equal(M.split_row("a | b"), { "a", "b" }))
check("delim aligns", vim.deep_equal(M.delim("|---|:-:|--:|:--|"), { "left", "center", "right", "left" }))
check("delim rejects text", M.delim("| a | b |") == nil)
check("delim rejects a rule", M.delim("---") == nil)

local doc = {
  "intro",
  "| A | B |",
  "|---|---|",
  "| 1 | 2 |",
  "| 3 | 4 |",
  "",
  "```",
  "| no | table |",
  "|---|---|",
  "```",
  "| one | two |",
  "|---|---|---|",
}
local found = M.find(doc)
check("find: one table", #found == 1, found)
check("find: its lines", found[1] and found[1].first == 2 and found[1].last == 5, found[1])
check("find: rows", found[1] and #found[1].rows == 3)

-- marks: what each line hides (or swaps for a character) and styles.
local function marks_of(lines, n)
  local out = {}
  for _, m in ipairs(M.marks(lines)) do
    if m.line == n then
      out[#out + 1] = (m.conceal_line and "line") or (m.overlay or "") .. (m.conceal and ("hide" .. m.col .. "-" .. m.end_col
        .. (m.conceal ~= "" and "=" .. m.conceal or "")) or "") .. (m.hl and (m.hl .. m.col .. "-" .. m.end_col) or "")
    end
  end
  return table.concat(out, " ")
end
local md = { "# Title", "## Options ##", "#nope", "```", "# **code**", "```", "####### seven",
  "Setext", "===", "", "---", "- item", "  * [x] done", "> quote", "**b** *i* `c` ~~s~~ [t](u) \\* a_b_c", "Two", "---",
  "src/__init__.py and __bold__" }
check("marks: ATX heading", marks_of(md, 1) == "hide0-2 heading12-7", marks_of(md, 1))
check("marks: closing #s", marks_of(md, 2) == "hide0-3 hide10-13 heading3-10", marks_of(md, 2))
check("marks: not headings", marks_of(md, 3) == "" and marks_of(md, 5) == "" and marks_of(md, 7) == "")
check("marks: setext", marks_of(md, 8) == "heading10-6" and marks_of(md, 9) == "line", { marks_of(md, 8), marks_of(md, 9) })
check("marks: rule", marks_of(md, 11) == "rule", marks_of(md, 11))
check("marks: bullet", marks_of(md, 12) == "hide0-1=\u{2022}bullet0-1", marks_of(md, 12))
check("marks: task box", marks_of(md, 13) == "hide2-4 hide4-7=\u{2611}done4-7", marks_of(md, 13))
check("marks: quote", marks_of(md, 14) == "hide0-1=\u{258E}quote0-1", marks_of(md, 14))
check("marks: inline", marks_of(md, 15) == "hide0-2 hide3-5 bold2-3 hide6-7 hide8-9 italic7-8 hide10-11 code11-12 "
  .. "hide12-13 hide14-16 hide17-19 strike16-17 hide20-21 link21-22 hide22-26 hide27-28", marks_of(md, 15))
check("marks: a path's underscores stay", marks_of(md, 18) == "hide20-22 hide26-28 bold22-26", marks_of(md, 18))
check("marks: setext h2 over a rule", marks_of(md, 16) == "heading0-3" and marks_of(md, 17) == "line")

check("inline", vim.deep_equal(M.inline("**Bold** and `code` [link](http://x) *it*"),
  { { "Bold", "bold" }, { " and ", nil }, { "code", "code" }, { " ", nil }, { "link", "link" }, { " ", nil },
    { "it", "italic" } }), M.inline("**Bold** and `code` [link](http://x) *it*"))
check("inline keeps snake_case", vim.deep_equal(M.inline("a_b_c"), { { "a_b_c", nil } }), M.inline("a_b_c"))

local function text(vl)
  local out = {}
  for _, line in ipairs(vl) do
    local s = {}
    for _, ch in ipairs(line) do s[#s + 1] = ch[1] end
    out[#out + 1] = table.concat(s)
  end
  return out
end
local dw = vim.fn.strdisplaywidth

local small = text(M.layout(M.find({ "| A | Bee |", "|---|--:|", "| 1 | 2 |" })[1], 80, { dw = dw }))
check("layout: natural widths", vim.deep_equal(small, {
  "\u{250C}\u{2500}\u{2500}\u{2500}\u{252C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}",
  "\u{2502} A \u{2502} Bee \u{2502}",
  "\u{251C}\u{2500}\u{2500}\u{2500}\u{253C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}",
  "\u{2502} 1 \u{2502}   2 \u{2502}",
  "\u{2514}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}",
}), small)

local wide = M.find({
  "| Option | What can be reused |",
  "|---|---|",
  "| Avalonia UI | ViewModels (after extraction), all gRPC clients, CommunityToolkit.Mvvm, OxyPlot |",
})[1]
local lines = text(M.layout(wide, 40, { dw = dw }))
local ok_width = true
for _, l in ipairs(lines) do if dw(l) > 40 then ok_width = false end end
check("layout: fits the width", ok_width, lines)
check("layout: a cell wraps", #lines > 5, lines)
local whole = false
for _, l in ipairs(lines) do if l:find("CommunityToolkit.Mvvm", 1, true) then whole = true end end
check("layout: a long word stays whole when it can", whole, lines)
check("layout: too narrow gives nil", M.layout(wide, 8, { dw = dw }) == nil)

local function finish()
  if fails == 0 then print("MDRENDER-OK") end
  vim.cmd("qa!")
end

if vim.fn.has("nvim-0.11") == 0 then
  print("skip  the drawing (Neovim older than 0.11)")
  return finish()
end

vim.o.columns = 60
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "top", "| Col | Other |", "|---|---|", "| x | y |", "## after" })
M.attach(buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local function row(r)
  local s = {}
  for c = 1, 20 do s[#s + 1] = vim.fn.screenstring(r, c) end
  return vim.trim(table.concat(s))
end

vim.defer_fn(function()
  vim.cmd("redraw")
  check("drawn: the box replaces the text", row(2):find("\u{250C}", 1, true) == 1 and row(3):find("Col", 1, true)
    and row(7) == "after", { row(2), row(3), row(7) })
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("redraw")
  check("the cursor's heading stays drawn", row(7) == "after", row(7))
  -- The cursor on the body row's second cell: still drawn, that cell lit.
  vim.api.nvim_win_set_cursor(0, { 4, 5 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  vim.defer_fn(function()
    vim.cmd("redraw")
    local lit = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local cell_hl = false
    for _, m in ipairs(lit) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        for _, ch in ipairs(vl) do
          local hl = type(ch[2]) == "table" and ch[2][1] or ch[2]
          if hl == M.HL.cell and vim.trim(ch[1]) == "y" then cell_hl = true end
        end
      end
    end
    check("cursor in it: still drawn", row(2):find("\u{250C}", 1, true) == 1, row(2))
    check("cursor in it: its cell lit", cell_hl)
    vim.api.nvim_feedkeys("i", "n", false)
  vim.defer_fn(function()
    vim.cmd("redraw")
    check("typing in it: the text is back", row(2) == "| Col | Other |", row(2))
    vim.api.nvim_feedkeys("\27", "n", false)
  vim.defer_fn(function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "| a | b |", "|---|---|" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    vim.defer_fn(function()
      vim.cmd("redraw")
      check("an edit draws again", row(2):find("\u{250C}", 1, true) == 1, row(2))
      -- The chat replaces all its text on every redraw: the very next
      -- screen already has the box, never a frame of the raw table.
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "TOP", "| Col | Other |", "|---|---|", "| x | y |", "end" })
      vim.cmd("redraw")
      check("replaced text: no raw frame", row(1) == "TOP" and row(2):find("\u{250C}", 1, true) == 1, { row(1), row(2) })
      finish()
    end, 50)
  end, 50)
  end, 50)
  end, 50)
end, 50)
