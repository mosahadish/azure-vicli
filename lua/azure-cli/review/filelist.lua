-- lua/azure-cli/review/filelist.lua: the reviewer's file-list layout -
-- status letters, +/- diff stats, directory grouping - built as its own
-- module (see review/init.lua's 200-local comment: nowhere left there for
-- new locals) so it's independently pure/unit-tested
-- (tests/test-review-filelist.lua) and keeps review/init.lua's own body to
-- a thin wire-up (EXT.refresh_file_list, near mark_current_file/
-- refresh_file_rows there).
--
-- M.build(files, stats, status, threads_info) -> model (pure, no vim.* at
-- all, unlike M.render/M.diff_stats below which need a real buffer/vim):
--   files          ordered array of repo-relative paths - review/init.lua's
--                  own `files`, UNCHANGED by this module; the grouped/
--                  sorted display order lives only in the returned model
--   stats          path -> { adds = n, dels = n } | nil (diff not cached
--                  yet - rendered as "(?)")
--   status         path -> "A" | "M" | "D" | "R" | nil (name-status not
--                  fetched yet - rendered as a blank status column)
--   threads_info   path -> { closed = n, total = n, new = bool } | nil
--
-- model = {
--   lines         one row per directory header or file - NOT including the
--                 reviewer's own pinned Overview row (review/init.lua
--                 prepends that itself; see list_lines/refresh_file_rows/
--                 apply_files there)
--   row_to_file   row (1-based, within `lines`) -> path, or nil for a
--                 directory-header row - the row->file map every place that
--                 used to index `files` by row now goes through instead
--   file_to_row   path -> row (the inverse, for mark_current_file)
--   ordered_files files in the same grouped/sorted order they appear in
--                 `lines` - what cross-file ]c/]C/gd/etc. now step through
--                 (EXT.file_index/file_count/open_file_at) instead of
--                 `files`' own (git-reported) order
--   hl            { { line = 0-based, s = bytecol, e = bytecol,
--                 group = <highlight group name> }, ... }
--   prefix        the directory prefix common to every file in `files`
--                 (""  when there is none), trimmed from every header row
--                 and shown once instead - see set_list_winbar_impl in
--                 review/init.lua
-- }
local M = {}

-- Sums added/deleted line counts from a parsed diff's per-line map (the
-- same {kind = "add"|"del"|"ctx", ...} shape cache.lua's M.parse_diff and
-- the diff pane's own decorate_diff read). Pure.
function M.diff_stats(map)
  local adds, dels = 0, 0
  for _, m in ipairs(map or {}) do
    if m.kind == "add" then
      adds = adds + 1
    elseif m.kind == "del" then
      dels = dels + 1
    end
  end
  return { adds = adds, dels = dels }
end

-- The byte length of the common prefix of `a` and `b` (both plain strings,
-- compared byte-wise - repo paths are always '/'-separated regardless of
-- platform, so this needs no path-library help).
local function common_prefix_len(a, b)
  local n, max = 0, math.min(#a, #b)
  while n < max and a:byte(n + 1) == b:byte(n + 1) do
    n = n + 1
  end
  return n
end

-- The directory prefix every path in `sorted` (already lexicographically
-- sorted - irrelevant to the result, just avoids a second pass) shares, cut
-- back to the last "/" so it's always a whole directory path (never a
-- partial file/directory name) - "" when there's no common directory at
-- all, or when there's only zero/one file.
local function common_dir_prefix(sorted)
  if #sorted < 2 then return "" end
  local prefix = sorted[1]
  for i = 2, #sorted do
    local n = common_prefix_len(prefix, sorted[i])
    prefix = prefix:sub(1, n)
    if prefix == "" then return "" end
  end
  local slash
  for i = #prefix, 1, -1 do
    if prefix:sub(i, i) == "/" then slash = i break end
  end
  return slash and prefix:sub(1, slash) or ""
end

-- One file row's text plus the byte range of its status letter (for the
-- AzureCliFileAdded/Deleted/Renamed highlight - M omitted on purpose, it
-- reads fine as plain text and doesn't need its own colour).
local function file_row(f, status, stats, threads_info)
  local letter = status[f] or " "
  local basename = f:match("([^/]+)$") or f
  local marker = (threads_info[f] and threads_info[f].new) and "\u{1F195} " or ""

  local s = stats[f]
  local stat_text = s and (" (+" .. s.adds .. " \u{2212}" .. s.dels .. ")") or " (?)"

  local ti = threads_info[f]
  local thread_text = (ti and ti.total and ti.total > 0) and ("  (" .. ti.closed .. "/" .. ti.total .. ")") or ""

  local ti_viewed = threads_info[f] and threads_info[f].viewed
  local row = (ti_viewed and "\u{2713} " or "  ") .. letter .. "  " .. marker .. basename .. stat_text .. thread_text
  return row, letter, ti_viewed
end

-- See the module comment above for the full shape.
function M.build(files, stats, status, threads_info)
  stats = stats or {}
  status = status or {}
  threads_info = threads_info or {}

  local sorted = {}
  for _, f in ipairs(files or {}) do sorted[#sorted + 1] = f end
  table.sort(sorted)

  local prefix = common_dir_prefix(sorted)

  -- Group by directory relative to `prefix` - "" (files sitting directly at
  -- the trimmed root) is its own group, headed "./" for consistency with
  -- every other directory getting a header row, even a single-file one.
  local groups, order = {}, {}
  for _, f in ipairs(sorted) do
    local rel = f:sub(#prefix + 1)
    local dir = rel:match("^(.*/)") or ""
    if not groups[dir] then
      groups[dir] = {}
      order[#order + 1] = dir
    end
    groups[dir][#groups[dir] + 1] = f
  end
  table.sort(order)

  local lines, row_to_file, file_to_row, ordered_files, hl = {}, {}, {}, {}, {}
  for _, dir in ipairs(order) do
    lines[#lines + 1] = dir ~= "" and dir or "./"
    hl[#hl + 1] = { line = #lines - 1, s = 0, e = -1, group = "AzureCliFileDir" }

    for _, f in ipairs(groups[dir]) do
      local row, letter, viewed = file_row(f, status, stats, threads_info)
      lines[#lines + 1] = row
      local rownum = #lines
      row_to_file[rownum] = f
      file_to_row[f] = rownum
      ordered_files[#ordered_files + 1] = f

      local group = (letter == "A" and "AzureCliFileAdded")
        or (letter == "D" and "AzureCliFileDeleted")
        or (letter == "R" and "AzureCliFileRenamed")
        or nil
      if group then
        hl[#hl + 1] = { line = rownum - 1, s = 2, e = 3, group = group }
      end
      -- A viewed file's row is dimmed as a whole (its status colour, if
      -- any, was added first, so this wins over it).
      if viewed then
        hl[#hl + 1] = { line = rownum - 1, s = 0, e = -1, group = "AzureCliFileViewed" }
      end
    end
  end

  return {
    lines = lines, row_to_file = row_to_file, file_to_row = file_to_row,
    ordered_files = ordered_files, hl = hl, prefix = prefix,
  }
end

local ns = vim and vim.api.nvim_create_namespace("azure_cli_filelist")

-- Writes `model.lines` into `list_buf` starting at (1-based) line 2 -
-- review/init.lua's own pinned Overview row always occupies line 1, so this
-- never touches it - and applies `model.hl`. AzureCliFileDir/Added/Deleted/
-- Renamed all link to a standard group with `default = true` (see
-- dashboard.lua's define_hl for why - a real colorscheme picks these up
-- automatically, standalone/init.lua's explicit palette still wins there).
function M.render(list_buf, model)
  if not vim.api.nvim_buf_is_valid(list_buf) then return end
  local function hl(name, o) pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", { default = true }, o)) end
  hl("AzureCliFileDir", { link = "Directory" })
  hl("AzureCliFileAdded", { link = "String" })
  hl("AzureCliFileDeleted", { link = "ErrorMsg" })
  hl("AzureCliFileRenamed", { link = "Special" })
  hl("AzureCliFileViewed", { link = "Comment" })

  vim.bo[list_buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, list_buf, 1, -1, false, model.lines)
  vim.bo[list_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(list_buf, ns, 1, -1)
  for _, h in ipairs(model.hl) do
    pcall(vim.api.nvim_buf_add_highlight, list_buf, ns, h.group, h.line + 1, h.s, h.e)
  end
end

return M
