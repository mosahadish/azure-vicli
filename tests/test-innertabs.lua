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
    "!102 Another long one about caching things" }, 2, 70)
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

-- The strip gives way to the window's own winbar (#107): M.bar gives it
-- min(60% of the window, what the own winbar leaves). Its width all told:
-- the plain text, the leading pad and the closing " ┃".
local function chars(s) return #(s:gsub("[\128-\191]", "")) end
local function strip_w(plain, wfn) return plain == "" and 0 or ((wfn or chars)(plain) + 3) end
local PLANS = { "Agents", "#99 Plan view: skip the agent's open questions",
  "#104 Discard a plan from the plan view too", "#103 Discard a plan from the plan view too; tidy the dd question",
  "#106 Look-only: gh api graphql queries" }
-- The plan pane's own status, as plan_view.lua builds it, plus its pad.
local OWN = 1 + chars("Plan #103 \u{00B7} rev 3   [draft] [2 to answer]   ?: help")
local function marked(plain)
  local n = 0
  for _ in plain:gmatch("%[") do n = n + 1 end
  return n
end
for _, width in ipairs({ 80, 120 }) do
  for _, nplans in ipairs({ 1, 3, 4 }) do
    local labels = {}
    for i = 1, nplans + 1 do labels[i] = PLANS[i] end
    for _, cur in ipairs({ nplans + 1, 2, 1 }) do
      local room = math.min(math.floor(width * 0.6), width - OWN)
      local _, plain = M.strip_text(labels, cur, room)
      local what = width .. " cols, " .. nplans .. " plan(s), current " .. cur .. ": "
      check(what .. "the strip and the plan's status both fit", strip_w(plain) + OWN <= width, plain)
      local id = labels[cur]:match("^([#!]%S+)") or labels[cur]
      check(what .. "the current one is marked, and only it", marked(plain) == 1
        and plain:find("[" .. id, 1, true) ~= nil, plain)
    end
  end
end
do
  local labels = { PLANS[1], PLANS[2], PLANS[3], PLANS[4] }
  local _, wide = M.strip_text(labels, 2, 72)
  check("strip: roomy - full labels", wide:find("[#99 Plan view", 1, true) ~= nil, wide)
  local _, ids = M.strip_text(labels, 4, 40)
  check("strip: narrower - the others as their ids", ids:find("#99 \u{2502} #104 \u{2502} [#103 Disc", 1, true) ~= nil, ids)
  local _, bare = M.strip_text(labels, 4, 32)
  check("strip: narrower still - the current one as its id", bare == "Agents \u{2502} #99 \u{2502} #104 \u{2502} [#103]", bare)
  local _, over = M.strip_text(labels, 3, 28)
  check("strip: +N on either side of the current one", over == "Agents \u{2502} +1 \u{2502} [#104] \u{2502} +1", over)
  local _, home = M.strip_text(labels, 1, 20)
  check("strip: the home current, the rest counted", home == "[Agents] \u{2502} +3", home)
  local _, alone = M.strip_text(labels, 3, 10)
  check("strip: only the current one", alone == "[#104]", alone)
  local fmt, none = M.strip_text(labels, 3, 5)
  check("strip: no room - nothing", none == "" and fmt == "", none)
end
do
  -- Multibyte titles: cut on a character, never inside one, and a wide
  -- character (CJK: two cells) counted as two.
  local function wide(s)
    local w = 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local b = ch:byte()
      w = w + ((b >= 227 and b <= 233) and 2 or 1)
    end
    return w
  end
  local labels = { "Agents", "#7 \u{00DC}n\u{00EF}c\u{00F8}d\u{00E9} t\u{00EF}tl\u{00E9} that is long enough",
    "#8 \u{8a08}\u{753b}\u{306e}\u{8868}\u{793a}\u{3092}\u{76f4}\u{3059}\u{8a08}\u{753b}\u{306e}\u{8868}\u{793a}" }
  for room = 12, 60 do
    for cur = 1, 3 do
      local _, plain = M.strip_text(labels, cur, room, wide)
      if strip_w(plain, wide) > room or not plain:find("^[%z\1-\127\194-\244]") and plain ~= ""
        or plain:find("[\194-\244]$") or plain:find("[\194-\244][\1-\127]") then
        check("strip: multibyte at " .. room .. " cells, current " .. cur, false, plain)
      end
    end
  end
  local _, p = M.strip_text(labels, 3, 30, wide)
  check("strip: a wide title fits its room", strip_w(p, wide) <= 30 and p:find("[#8 ", 1, true) ~= nil, p)
end

-- Work items (stage 2): a key per board, never a PR's (hosts.lua's key: the
-- id on Azure, owner~repo~n on GitHub), and the home each opens in.
check("item key: Azure", M.item_key("azure", 3001) == "wi:azure:3001")
check("item key: GitHub", M.item_key("github", "acme~web~7") == "wi:github:acme~web~7")
check("item key: unknown board is Azure", M.item_key(nil, "3001") == "wi:azure:3001")
check("item key: never a PR's", M.item_key("azure", 101) ~= "101" and M.item_key("github", "acme~web~7") ~= "acme~web~7")
check("item key: W's #7 and I's #7 differ", M.item_key("azure", 7) ~= M.item_key("github", 7))
check("item home: Work items", M.item_home("azure") == "workitems" and M.item_home(nil) == "workitems")
check("item home: Issues", M.item_home("github") == "issues")
check("plan key", M.plan_key("wi-3001") == "plan:wi-3001")
check("plan key: never a work item's or a PR's",
  M.plan_key("wi-3001") ~= M.item_key("azure", 3001) and M.plan_key("pr-101") ~= "101")

print(fails == 0 and "innertabs: all cases pass" or ("innertabs: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
