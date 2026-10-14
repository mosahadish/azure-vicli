-- test-innertabs.lua: innertabs.lua's pure helpers - the strip's text,
-- next/previous wrapping, where closing an inner tab goes.
--
-- Usage: luajit test-innertabs.lua <innertabs.lua path>

dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local path = arg[1]
assert(path, "usage: luajit test-innertabs.lua <innertabs.lua path>")

vim = nil  -- the pure half only: the module stops before anything needs Neovim
local M = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail and ("\n     " .. tostring(detail)) or ""))
  end
end

-- M.wrap ---------------------------------------------------------------
check("wrap: next from the list", M.wrap(1, 1, 3) == 2)
check("wrap: next from the last goes to the list", M.wrap(3, 1, 3) == 1)
check("wrap: previous from the list goes to the last", M.wrap(1, -1, 3) == 3)
check("wrap: previous", M.wrap(3, -1, 3) == 2)
check("wrap: nothing to wrap in", M.wrap(1, 1, 0) == nil)

-- M.close_target ---------------------------------------------------------
check("close: the first item goes back to the list", M.close_target(1) == 0)
check("close: a later item goes to the one before it", M.close_target(3) == 2)

-- M.strip_text -----------------------------------------------------------
local SEP = " \u{2502} "
do
  local fmt, plain = M.strip_text({ "Pull requests", "!101 Fix auth", "!102 Cache" }, 3, 120)
  check("strip: home first, each item, the current one marked",
    plain == "Pull requests" .. SEP .. "!101 Fix auth" .. SEP .. "[!102 Cache]", plain)
  check("strip: the current one in the title group",
    fmt:find("%#AzureCliWinbarTitle#[!102 Cache]", 1, true) ~= nil, fmt)
  check("strip: ends with the bar before the window's own winbar", fmt:find("\u{2503}", 1, true) ~= nil, fmt)
end
do
  local _, plain = M.strip_text({ "Pull requests", "!101 A very long pull request title that goes on and on",
    "!102 Another long one about caching things" }, 2, 40)
  check("strip: narrow - other labels cut with an ellipsis", plain:find("\u{2026}", 1, true) ~= nil, plain)
  check("strip: narrow - the current one keeps more of its title than the others",
    plain:find("[!101 A very long", 1, true) ~= nil, plain)
end
do
  local fmt, plain = M.strip_text({ "Pull requests", "!7 100% done" }, 2, 80)
  check("strip: a % in a title is escaped", fmt:find("100%% done", 1, true) ~= nil, fmt)
  check("strip: and reads as itself", plain:find("100% done", 1, true) ~= nil, plain)
end
check("strip: nothing to show", select(2, M.strip_text({}, 1, 80)) == "")

-- Work items (stage 2): a key per board, never a PR's (hosts.lua's key: the
-- id on Azure, owner~repo~n on GitHub), and the home each opens in.
check("item key: Azure", M.item_key("azure", 3001) == "wi:azure:3001")
check("item key: GitHub", M.item_key("github", "acme~web~7") == "wi:github:acme~web~7")
check("item key: unknown board is Azure", M.item_key(nil, "3001") == "wi:azure:3001")
check("item key: never a PR's", M.item_key("azure", 101) ~= "101" and M.item_key("github", "acme~web~7") ~= "acme~web~7")
check("item key: W's #7 and I's #7 differ", M.item_key("azure", 7) ~= M.item_key("github", 7))
check("item home: Work items", M.item_home("azure") == "workitems" and M.item_home(nil) == "workitems")
check("item home: Issues", M.item_home("github") == "issues")

print(fails == 0 and "innertabs: all cases pass" or ("innertabs: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
