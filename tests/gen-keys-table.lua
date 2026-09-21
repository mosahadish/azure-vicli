-- gen-keys-table.lua: prints docs/commands-and-keys.md's key table straight from
-- lua/azure-cli/config.lua's DEFAULT_KEYS, so the two can't drift apart -
-- when an action is added/renamed/rebound there, re-run this and paste the
-- output over the marked section of docs/commands-and-keys.md.
--
-- Usage: luajit tests/gen-keys-table.lua [path/to/config.lua]
-- (defaults to lua/azure-cli/config.lua next to the repo root this file's
-- own path implies - run from anywhere, same as the other tests/*.lua).

local function this_dir()
  return (arg[0] or "gen-keys-table.lua"):match("^(.*)[/\\][^/\\]*$") or "."
end
local config_path = arg[1] or (this_dir() .. "/../lua/azure-cli/config.lua")

-- Minimal vim shim: config.lua's module-load-time code only needs
-- vim.deepcopy (used by M.setup, not at load time, but harmless to have)
-- and nothing else runs until M.get()/M.setup() are called, neither of
-- which this script calls - it reads the DEFAULT_KEYS local directly via a
-- small source-level trick instead (see below), so the shim just needs to
-- be enough for dofile() to load the file without erroring.
vim = {
  deepcopy = function(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = vim.deepcopy(v) end
    return out
  end,
  fn = { fnamemodify = function(p) return p end, executable = function() return 0 end },
  env = {},
}

local config = dofile(config_path)
-- DEFAULT_KEYS is a local inside config.lua, not exposed on M - but M.setup({})
-- with no overrides resolves to exactly the defaults, and M.get() returns
-- that resolved table, which is all this generator needs.
config.setup({})
local keys = config.get().keys

-- Stable surface order (matches docs/commands-and-keys.md's section order).
local SURFACES = {
  "dashboard", "list", "diff", "overview", "nav", "workitems", "workitem_view",
}

local function keystr(v)
  if type(v) == "table" then
    local parts = {}
    for _, k in ipairs(v) do parts[#parts + 1] = "`" .. k .. "`" end
    return table.concat(parts, " / ")
  end
  if v == false then return "*(unbound)*" end
  return "`" .. tostring(v) .. "`"
end

for _, surface in ipairs(SURFACES) do
  local actions = keys[surface]
  if actions then
    print("#### " .. surface)
    print("")
    print("| Action | Default key(s) |")
    print("|---|---|")
    local names = {}
    for action in pairs(actions) do names[#names + 1] = action end
    table.sort(names)
    for _, action in ipairs(names) do
      print("| `" .. action .. "` | " .. keystr(actions[action]) .. " |")
    end
    print("")
  end
end
