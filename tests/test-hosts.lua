-- test-hosts.lua: lua/azure-cli/hosts.lua's per-host capabilities.
-- Usage: luajit test-hosts.lua <hosts.lua path>
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local path = arg[1]
assert(path, "usage: luajit test-hosts.lua <hosts.lua path>")
local H = dofile(path)

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

local azure = { id = 101, title = "x" }
check("host: absent reads as azure", H.host(azure) == "azure")
check("host: unknown reads as azure", H.host({ host = "nope" }) == "azure")
check("host: nil record", H.host(nil) == "azure")
check("caps: azure votes", #H.caps(azure).votes == 5 and H.caps(azure).votes[1].key == "10")
check("caps: azure statuses", #H.caps(azure).thread_statuses == 6)
check("caps: azure merge methods", #H.caps(azure).merge_methods == 4)
check("caps: nil record", H.caps(nil).host == "azure")

local over = H.caps({ caps = { merge_methods = { { key = "squash", label = "Squash" } } } })
check("caps: record overrides lay over the host's", #over.merge_methods == 1 and #over.votes == 5)
check("caps: overriding doesn't touch the host table", #H.HOSTS.azure.merge_methods == 4)

check("key: azure is the id itself", H.key(azure) == 101)
check("key: a record's own key wins", H.key({ id = 12, key = "o+r+12" }) == "o+r+12")
check("key: a bare id passes through", H.key(7) == 7)
check("ref: azure", H.ref(azure) == "!101")

check("vote: by number", H.vote(azure, 10).label == "Approve")
check("vote: by string", H.vote(azure, "-5").name == "wait")
check("vote: unknown", H.vote(azure, 3) == nil)
check("vote: reject confirms", H.vote(azure, -10).confirm == true)
check("glyph: approve", H.vote_glyph(azure, 10) == "\u{2713}")
check("glyph: suggestions", H.vote_glyph(azure, 5) == "\u{2713}")
check("glyph: suggestions, detail", H.vote_glyph(azure, 5, true) == "\u{2713}~")
check("glyph: wait", H.vote_glyph(azure, -5) == "~")
check("glyph: reject", H.vote_glyph(azure, -10) == "\u{2717}")
check("glyph: none", H.vote_glyph(azure, 0) == "\u{00B7}" and H.vote_glyph(azure, nil) == "\u{00B7}")

check("is_open: active", H.is_open("active"))
check("is_open: pending", H.is_open("pending"))
check("is_open: nil (just made)", H.is_open(nil))
check("is_open: fixed", not H.is_open("fixed"))
check("is_open: wontFix", not H.is_open("wontFix"))
check("is_open: byDesign", not H.is_open("byDesign"))

local m = H.mentions({ reviewers = { { name = "Doe, Jane", id = "g-1" }, { name = "" }, { name = "No Id" } } })
check("mentions: named reviewers only", #m == 2)
check("mentions: azure token is the guid form", m[1].token == "@<g-1>")
check("mentions: no id, no token", m[2].token == nil)

local gh = { host = "github", id = 12, repo = "cli", key = "o~cli~12",
  caps = { merge_methods = { { key = "squash", label = "Squash and merge" } } },
  reviewers = { { name = "Bob", id = "bob" } } }
check("github: host", H.host(gh) == "github")
check("github: key", H.key(gh) == "o~cli~12")
check("github: ref names the repo", H.ref(gh) == "cli#12")
check("github: three votes", #H.caps(gh).votes == 3 and H.vote(gh, -5).label == "Request changes")
check("github: request changes is no sign-off", not H.vote(gh, -5).signed)
check("github: two statuses", #H.caps(gh).thread_statuses == 2)
check("github: the repo's merge methods", #H.caps(gh).merge_methods == 1)
check("github: mention by login", H.mentions(gh)[1].token == "@bob")

if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("all ok")
