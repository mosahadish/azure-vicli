-- lua/azure-cli/diffbuf.lua: what a diff pane looks like and how you move
-- through it, shared by the reviewer (review/init.lua) and the chat's change
-- viewer (chat/changes.lua) so the two behave the same:
--
--   ft_for_path(path)      the filetype a diff buffer gets, for the file's
--                          own syntax colours (and the user's FileType setup)
--   setup_hl()             the diff and current-file highlight groups
--   ns                     the namespace the diff marks live in
--   decorate(buf, lines, map)  +/- signs, line colours, changed words
--   is_change(map, i)      whether buffer line i is an added/removed line
--   next_change(map, i, dir)   ]c / [c inside one buffer: the start of the
--                          next/previous block of changes, or nil at the end
--   edge_change(map, dir)  where ]c / [c land on entering a file: its first
--                          block for ]c, its last block for [c, nil if none
--   stats(map)             " (+adds −dels)" for the winbar
--   PREVIEW_MS             how long the cursor rests on a file-list row
--                          before that file's diff is shown
--
-- Everything but setup_hl/decorate is pure.
local M = {}

M.PREVIEW_MS = 80

M.ns = vim.api.nvim_create_namespace("azure_cli_diff")

-- Map a repo path to a bundled Vim syntax name so diff buffers get language
-- syntax colouring (no LSP). nil = leave unhighlighted.
local FT_BY_EXT = {
  cs = "cs", lua = "lua", py = "python", js = "javascript", jsx = "javascriptreact",
  ts = "typescript", tsx = "typescriptreact", c = "c", h = "c", cpp = "cpp",
  cc = "cpp", cxx = "cpp", hpp = "cpp", java = "java", go = "go", rb = "ruby",
  rs = "rust", php = "php", sh = "sh", bash = "sh", ps1 = "ps1", psm1 = "ps1",
  json = "json", yaml = "yaml", yml = "yaml", xml = "xml", html = "html",
  htm = "html", css = "css", scss = "scss", md = "markdown", sql = "sql",
  proto = "proto", toml = "toml", ini = "dosini", vim = "vim", kt = "kotlin",
  swift = "swift", scala = "scala", pl = "perl", r = "r", dart = "dart",
  fs = "fsharp", gradle = "groovy", groovy = "groovy", cshtml = "html",
}

function M.ft_for_path(path)
  -- Neovim's own detection first (Dockerfile, Makefile, *.tf, *.vue,
  -- *.csproj, ... - anything its filetype tables know); the extension
  -- table is the fallback for the few it doesn't.
  if vim.filetype and vim.filetype.match then
    local ok, ft = pcall(vim.filetype.match, { filename = path })
    if ok and ft and ft ~= "" then return ft end
  end
  local ext = (path or ""):match("%.([%w_]+)$")
  if not ext then return nil end
  return FT_BY_EXT[ext:lower()]
end

-- Diff add/remove markers: a gutter sign + subtle full-line background, so the
-- code keeps its language syntax colours while changes stay obvious now that the
-- +/- prefixes are stripped. Linked to the standard DiffAdd/DiffDelete/DiffText
-- groups with `default = true` (see UI.link_hl for why), so plugin mode picks
-- up the active colorscheme's own diff colours and standalone/init.lua's
-- explicit palette (applied after this, non-default) still wins there.
-- Word-level highlight inside a changed line pair (see CACHE.word_diff): the
-- same hue as the line background, stronger and bold, so a one-token edit on
-- a long line stands out instead of the whole line reading as uniformly
-- changed. DiffText is exactly vim's own "changed text within a changed line"
-- group. AzureCliCurrentFile marks the file-list row of the file shown in the
-- diff pane; unlike 'cursorline' it stays visible once focus moves into the
-- diff pane (where the list, now an inactive window, shows no cursor at all).
function M.setup_hl()
  for group, link in pairs({
    AzureCliDiffAddBg = "DiffAdd", AzureCliDiffDelBg = "DiffDelete",
    AzureCliDiffAddSign = "DiffAdd", AzureCliDiffDelSign = "DiffDelete",
    AzureCliDiffAddWord = "DiffText", AzureCliDiffDelWord = "DiffText",
    AzureCliCurrentFile = "CursorLine",
  }) do
    pcall(vim.api.nvim_set_hl, 0, group, { default = true, link = link })
  end
end

function M.decorate(buf, lines, map)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for bl, m in ipairs(map) do
    if m.kind == "add" or m.kind == "del" then
      local is_add = m.kind == "add"
      vim.api.nvim_buf_set_extmark(buf, M.ns, bl - 1, 0, {
        sign_text = is_add and "+" or "-",
        sign_hl_group = is_add and "AzureCliDiffAddSign" or "AzureCliDiffDelSign",
        line_hl_group = is_add and "AzureCliDiffAddBg" or "AzureCliDiffDelBg",
      })
    end
  end
  -- Narrow modified-block line pairs down to the bytes that actually
  -- changed (CACHE.word_diff pairs the i-th deleted line with the i-th
  -- added line of each such block), so a one-token change on a long line
  -- stands out instead of the whole line reading uniformly green/red.
  for _, w in ipairs(require("azure-cli.cache").word_diff(lines, map)) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, w.line - 1, w.s, {
      end_col = w.e,
      hl_group = w.kind == "add" and "AzureCliDiffAddWord" or "AzureCliDiffDelWord",
    })
  end
end

-- A changed line is one the diff marked as added or removed (tracked in the
-- map, since the +/- prefixes are stripped from the displayed text).
function M.is_change(map, i)
  local e = map and map[i]
  return (e ~= nil and (e.kind == "add" or e.kind == "del")) or false
end

-- The start of the next (dir=1) or previous (dir=-1) block of changed lines
-- from line i, skipping over the block i is in; nil past the last/first one.
function M.next_change(map, i, dir)
  local total = #(map or {})
  while i >= 1 and i <= total and M.is_change(map, i) do i = i + dir end
  while i >= 1 and i <= total and not M.is_change(map, i) do i = i + dir end
  if i < 1 or i > total then return nil end
  if dir < 0 then
    while i - 1 >= 1 and M.is_change(map, i - 1) do i = i - 1 end
  end
  return i
end

-- Where ]c (dir=1) / [c (dir=-1) land on entering a file: the start of its
-- first / last block of changes, or nil when it has none.
function M.edge_change(map, dir)
  local first, last
  for ln = 1, #(map or {}) do
    if M.is_change(map, ln) then
      first = first or ln
      last = ln
    end
  end
  if not first then return nil end
  local target = dir > 0 and first or last
  if dir < 0 then
    while target - 1 >= 1 and M.is_change(map, target - 1) do target = target - 1 end
  end
  return target
end

-- " (+adds −dels)" for a diff's winbar, "" without a map.
function M.stats(map)
  if not map then return "" end
  local adds, dels = 0, 0
  for _, m in ipairs(map) do
    if m.kind == "add" then adds = adds + 1
    elseif m.kind == "del" then dels = dels + 1 end
  end
  return " (+" .. adds .. " \u{2212}" .. dels .. ")"
end

return M
