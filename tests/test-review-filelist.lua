-- test-review-filelist.lua: review/filelist.lua's pure M.diff_stats/M.build.
-- Runs under plain luajit (no vim needed - M.build/M.diff_stats never touch
-- it), same style as test-review-commits.lua/test-review-batch.lua.
--
-- Usage: luajit test-review-filelist.lua <filelist.lua path>

local path = arg[1]
assert(path, "usage: luajit test-review-filelist.lua <filelist.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then
    print("ok    " .. name)
  else
    fails = fails + 1
    print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- --- M.diff_stats ------------------------------------------------------------

check("diff_stats: counts add/del, ignores ctx",
  (function()
    local s = M.diff_stats({ { kind = "add" }, { kind = "add" }, { kind = "del" }, { kind = "ctx" } })
    return s.adds == 2 and s.dels == 1
  end)())

check("diff_stats: empty map", (function()
  local s = M.diff_stats({})
  return s.adds == 0 and s.dels == 0
end)())

check("diff_stats: nil map treated as empty", (function()
  local s = M.diff_stats(nil)
  return s.adds == 0 and s.dels == 0
end)())

-- --- M.build: grouping, prefix trimming, header rows -------------------------

do
  -- All files share "src/" - trimmed into `prefix`; "DataSource/"/"Other/"
  -- become their own header rows relative to it.
  local files = { "src/DataSource/b.py", "src/DataSource/a.py", "src/Other/c.py" }
  local model = M.build(files, {}, {}, {})
  check("build: common prefix trimmed to 'src/'", model.prefix == "src/", model.prefix)
  check("build: two directory headers, sorted", model.lines[1] == "DataSource/" and model.lines[4] == "Other/",
    table.concat(model.lines, "|"))
  check("build: files within a directory sorted by basename",
    model.lines[2]:find("a.py", 1, true) ~= nil and model.lines[3]:find("b.py", 1, true) ~= nil,
    table.concat(model.lines, "|"))
  check("build: row_to_file skips header rows", model.row_to_file[1] == nil and model.row_to_file[4] == nil)
  check("build: row_to_file maps a file row to its full path",
    model.row_to_file[2] == "src/DataSource/a.py", model.row_to_file[2])
  check("build: file_to_row is the inverse", model.file_to_row["src/DataSource/a.py"] == 2)
  check("build: ordered_files is the grouped/sorted display order (not `files`' own order)",
    model.ordered_files[1] == "src/DataSource/a.py" and model.ordered_files[2] == "src/DataSource/b.py"
      and model.ordered_files[3] == "src/Other/c.py",
    table.concat(model.ordered_files, "|"))
  local dir_hl
  for _, h in ipairs(model.hl) do
    if h.line == 0 then dir_hl = h end
  end
  check("build: a directory header row is highlighted AzureCliFileDir",
    dir_hl ~= nil and dir_hl.group == "AzureCliFileDir", dir_hl and dir_hl.group)
end

do
  -- No shared directory at all (files at different top-level roots): prefix
  -- is "" and headers show the full directory path.
  local files = { "a.py", "sub/dir/b.py" }
  local model = M.build(files, {}, {}, {})
  check("build: no common prefix when files share nothing", model.prefix == "", model.prefix)
  check("build: a root-level file gets the './' header", model.lines[1] == "./", model.lines[1])
  check("build: a nested file's header is its full relative directory",
    model.lines[3] == "sub/dir/", model.lines[3])
end

do
  -- A single file still gets its own directory header (not just a bare row).
  local model = M.build({ "only/one/file.py" }, {}, {}, {})
  check("build: a lone file's directory still gets a header row",
    model.lines[1] == "only/one/" and model.lines[2]:find("file.py", 1, true) ~= nil,
    table.concat(model.lines, "|"))
end

do
  check("build: empty file list produces an empty model", (function()
    local model = M.build({}, {}, {}, {})
    return #model.lines == 0 and #model.ordered_files == 0 and model.prefix == ""
  end)())
end

-- --- M.build: status letters, stats formatting, thread counts, new marker ---

do
  local files = { "a/x.py" }
  local stats = { ["a/x.py"] = { adds = 3, dels = 1 } }
  local status = { ["a/x.py"] = "A" }
  local threads_info = { ["a/x.py"] = { closed = 1, total = 2, new = true } }
  local model = M.build(files, stats, status, threads_info)
  local row = model.lines[2]
  check("build: status letter shown", row:sub(3, 3) == "A", row)
  check("build: stats formatted as (+adds -dels)", row:find("(+3 \u{2212}1)", 1, true) ~= nil, row)
  check("build: new marker prefixes the basename", row:find("\u{1F195}", 1, true) ~= nil, row)
  check("build: thread count suffix", row:find("(1/2)", 1, true) ~= nil, row)
  local letter_hl
  for _, h in ipairs(model.hl) do
    if h.line == 1 then letter_hl = h end
  end
  check("build: an Added file's status letter is highlighted AzureCliFileAdded",
    letter_hl ~= nil and letter_hl.group == "AzureCliFileAdded" and letter_hl.s == 2 and letter_hl.e == 3,
    letter_hl and (letter_hl.group .. " " .. letter_hl.s .. "-" .. letter_hl.e))
end

do
  -- Uncached diff -> "(?)"; unknown status -> blank letter; no threads -> no suffix.
  local model = M.build({ "a/x.py" }, {}, {}, {})
  local row = model.lines[2]
  check("build: uncached stats render as (?)", row:find("(?)", 1, true) ~= nil, row)
  check("build: unknown status renders a blank letter", row:sub(3, 3) == " ", row)
  check("build: no thread count suffix when there are no threads", row:find("/", 1, true) == nil, row)
end

do
  -- A renamed/deleted file's letter gets its own highlight group; "M"
  -- (modified) deliberately gets none (reads fine as plain text).
  local model = M.build({ "d.py", "r.py", "m.py" }, {}, { ["d.py"] = "D", ["r.py"] = "R", ["m.py"] = "M" }, {})
  local groups = {}
  for _, h in ipairs(model.hl) do
    if h.group ~= "AzureCliFileDir" then groups[model.row_to_file[h.line + 1]] = h.group end
  end
  check("build: Deleted status highlighted", groups["d.py"] == "AzureCliFileDeleted", groups["d.py"])
  check("build: Renamed status highlighted", groups["r.py"] == "AzureCliFileRenamed", groups["r.py"])
  check("build: Modified status has no letter highlight", groups["m.py"] == nil, groups["m.py"])
end

print(fails == 0 and "test-review-filelist: all cases pass" or ("test-review-filelist: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
