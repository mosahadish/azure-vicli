-- test-migrate.lua: pure tests for lua/azure-cli/migrate.lua's M.ensure -
-- the one-time pre-rename ("this plugin was once called pr-dash") data-file
-- migration dashboard.lua and review/init.lua reach through shell.lua's
-- read_json(..., { migrate_from = ... }). Shims just enough of
-- vim.fn (filereadable/readfile/writefile) against a tiny in-memory fake
-- filesystem - no real files touched, no real Neovim needed.
--
-- Usage: luajit test-migrate.lua <migrate.lua path>

local fs = {}  -- path -> array of lines (a "file"); absent key = doesn't exist

vim = {
  fn = {
    filereadable = function(path) return fs[path] ~= nil and 1 or 0 end,
    readfile = function(path)
      assert(fs[path] ~= nil, "readfile on a missing path: " .. tostring(path))
      -- Return a fresh copy, the way a real read would, so the caller can't
      -- accidentally mutate the fake filesystem's own table.
      local copy = {}
      for i, l in ipairs(fs[path]) do copy[i] = l end
      return copy
    end,
    writefile = function(lines, path)
      local copy = {}
      for i, l in ipairs(lines) do copy[i] = l end
      fs[path] = copy
      return 0
    end,
  },
}

local M = dofile(arg[1])
assert(arg[1], "usage: luajit test-migrate.lua <migrate.lua path>")

local fails, total = 0, 0
local function check(name, cond, detail)
  total = total + 1
  if cond then
    print("ok    " .. name)
  else
    fails = fails + 1
    print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- 1. Old present, new absent: new is written with the old file's content,
-- verbatim (same lines, same order).
fs = { ["/data/old.json"] = { '{"prs":{"1":{"totalThreads":2}}}' } }
M.ensure("/data/old.json", "/data/new.json")
check("migrates old content into new", fs["/data/new.json"] ~= nil, "new file was never written")
check("migrated content matches old exactly",
  fs["/data/new.json"] and #fs["/data/new.json"] == 1
    and fs["/data/new.json"][1] == '{"prs":{"1":{"totalThreads":2}}}',
  fs["/data/new.json"] and fs["/data/new.json"][1])
check("old file is left alone (not deleted)", fs["/data/old.json"] ~= nil)

-- 2. New already present: old is ignored outright, even if old also exists
-- and has different content - new's own content must never be clobbered.
fs = {
  ["/data/old.json"] = { "OLD-CONTENT-should-never-be-copied" },
  ["/data/new.json"] = { "NEW-CONTENT-must-survive" },
}
M.ensure("/data/old.json", "/data/new.json")
check("new file's content is untouched when it already exists",
  fs["/data/new.json"][1] == "NEW-CONTENT-must-survive", fs["/data/new.json"][1])
check("old file is still left alone", fs["/data/old.json"][1] == "OLD-CONTENT-should-never-be-copied")

-- 3. Neither file exists: a harmless no-op, no error, nothing created.
fs = {}
local ok = pcall(M.ensure, "/data/old.json", "/data/new.json")
check("neither-exists case does not error", ok)
check("neither-exists case creates nothing", fs["/data/new.json"] == nil and fs["/data/old.json"] == nil)

-- 4. Multi-line file content is preserved line-for-line (not just the first line).
fs = { ["/data/old.json"] = { "line one", "line two", "line three" } }
M.ensure("/data/old.json", "/data/new.json")
check("multi-line content migrates in full",
  #fs["/data/new.json"] == 3
    and fs["/data/new.json"][1] == "line one"
    and fs["/data/new.json"][2] == "line two"
    and fs["/data/new.json"][3] == "line three")

print(string.format("test-migrate: %d check(s), %d failure(s)", total, fails))
os.exit(fails == 0 and 0 or 1)
