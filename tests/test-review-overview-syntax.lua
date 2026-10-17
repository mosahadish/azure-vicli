-- test-review-overview-syntax.lua: review/overview_syntax.lua (#135) - the
-- Overview draws only the description and comment bodies as Markdown, the
-- header, branches, reviewers and commits list as plain text, and never
-- marks an intraword `_` as markdownError, while the user's own
-- markdownError highlight stays as it was.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-review-overview-syntax.lua
--
-- Prints "all overview syntax tests passed" / exits non-zero.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local fails = 0
local function check(name, ok, detail)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
  if not ok then fails = fails + 1 end
end

vim.cmd("syntax enable")
-- The user's own markdownError colour, which the Overview must not touch.
vim.cmd("highlight markdownError guifg=#123456")
local function user_fg()
  return vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID("markdownError")), "fg#", "gui")
end

local SYN = require("azure-cli.review.overview_syntax")

-- Mirrors build_overview's layout (review/init.lua), with the issue's names.
local lines = {
  "PR #7  Fix DUNE_HardwareLink",                                   -- 1
  "tg/remote_HW_stubs -> master",                                   -- 2
  "Author: Jane_Roe    Votes: 1/2",                                 -- 3
  "Reviewers: some_user (approved), other_user",                    -- 4
  "",                                                               -- 5
  "Description:",                                                   -- 6
  "  ## Heading_one",                                               -- 7
  "  - item uses DUNE_HardwareLink and remote_HW_stubs",            -- 8
  "  Some `code_span` and **bold** and _italic_ text.",             -- 9
  "  See [the_link](http://x) here.",                               -- 10
  "  ```",                                                          -- 11
  "  local snake_case = 1",                                         -- 12
  "  ```",                                                          -- 13
  "",                                                               -- 14
  "Commits (who pushed):",                                          -- 15
  "  a1b2c3d  2024-01-15  Jane: Add DUNE_HardwareLink to tg/remote_HW_stubs", -- 16
  "",                                                               -- 17
  "Comments (1):",                                                  -- 18
  "",                                                               -- 19
  "┌─ thread [active]",                                             -- 20
  "│ some_user:",                                                   -- 21
  "│   **ok** see snake_case",                                      -- 22
}

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
SYN.attach(buf)

check("filetype is azurecli-overview", vim.bo[buf].filetype == SYN.FILETYPE, vim.bo[buf].filetype)

-- Every syntax group at each byte of line `l`, as { [col] = { names } }.
local function groups(l)
  local out = {}
  for col = 1, #lines[l] do
    local names = {}
    for _, id in ipairs(vim.fn.synstack(l, col)) do names[#names + 1] = vim.fn.synIDattr(id, "name") end
    out[col] = names
  end
  return out
end
local function has(l, name)
  for _, names in pairs(groups(l)) do
    for _, n in ipairs(names) do if n == name then return true end end
  end
  return false
end
local function plain(l)
  for col, names in pairs(groups(l)) do
    if #names > 0 then return false, col .. ": " .. table.concat(names, ",") end
  end
  return true
end

for _, l in ipairs({ 1, 2, 3, 4, 15, 16, 18, 20, 21 }) do
  local ok, why = plain(l)
  check("line " .. l .. " is plain text: " .. lines[l], ok, why)
end

for l = 1, #lines do
  check("no markdownError on line " .. l, not has(l, "markdownError"))
end

check("description heading", has(7, "markdownH2"))
check("description list marker", has(8, "markdownListMarker"))
check("description code span", has(9, "markdownCode"))
check("description bold", has(9, "markdownBold"))
check("description italic", has(9, "markdownItalic"))
check("description link", has(10, "markdownLinkText"))
check("description fenced block", has(12, "markdownCodeBlock"))
check("comment body bold", has(22, "markdownBold"))
-- An intraword `_` doesn't start an italic either.
check("no italic in DUNE_HardwareLink", not has(8, "markdownItalic"))

check("user's markdownError highlight untouched", user_fg():lower() == "#123456", user_fg())

-- Re-setting 'syntax' (as :syntax on does) re-applies it.
vim.bo[buf].syntax = "OFF"
vim.bo[buf].syntax = SYN.FILETYPE
check("re-applied after 'syntax' is re-set", has(7, "markdownH2") and plain(2))

if fails > 0 then
  print(fails .. " overview syntax test(s) failed")
  os.exit(1)
end
print("all overview syntax tests passed")
