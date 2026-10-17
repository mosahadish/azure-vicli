-- test-review-images.lua: review/images.lua (#134) - finding image
-- references on a line, the terminal/renderer detection with stubbed
-- snacks.nvim / image.nvim (present and absent), placing and removing with
-- a stubbed renderer, and the Enter/gx flow end to end against
-- tests/fake-provider.py's --fetch-image: the download (a 0600 file),
-- auth only for the PR's own host, another host opened in the browser
-- without credentials, and keys on non-image lines doing what they did.
-- Usage: luajit test-review-images.lua <review/images.lua> <fake-provider.py>
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
assert(arg[2], "usage: luajit test-review-images.lua <review/images.lua> <fake-provider.py>")
vim = nil
local M = dofile(arg[1])
local FAKE = arg[2]

local fails = 0
local function check(name, cond, detail)
  if cond then print("ok    " .. name) else fails = fails + 1; print("FAIL  " .. name .. (detail and (" - " .. tostring(detail)) or "")) end
end

-- --- refs / ref_at / inline_refs ---------------------------------------------

local ATT = "https://tfs.example.org/tfs/C/P/_apis/git/repositories/r/pullRequests/51343/attachments/arch.png"
do
  local r = M.refs("  ![Hardware simulator architecture](" .. ATT .. ")")
  check("refs: a Markdown image", #r == 1 and r[1].url == ATT and r[1].image == true and r[1].s == 3)
  r = M.refs('![x](https://h.example/a.png "a title")')
  check("refs: a title after the URL", #r == 1 and r[1].url == "https://h.example/a.png")
  r = M.refs("![x](<https://h.example/a.png>)")
  check("refs: an <angle-bracketed> URL", #r == 1 and r[1].url == "https://h.example/a.png")
  r = M.refs('<img width="300" alt="shot" src="https://github.com/user-attachments/assets/abc-123" />')
  check("refs: an <img> tag", #r == 1 and r[1].url == "https://github.com/user-attachments/assets/abc-123" and r[1].image)
  r = M.refs("see [the diagram](" .. ATT .. ") and [docs](https://h.example/readme)")
  check("refs: an image link, not a plain one", #r == 1 and r[1].image == false and r[1].url == ATT)
  r = M.refs("[![x](https://h.example/a.png)](https://h.example/big.png)")
  check("refs: a linked image - the image, then its link's target", #r == 2 and r[1].url == "https://h.example/a.png"
    and r[1].image and r[2].url == "https://h.example/big.png" and not r[2].image, #r)
  r = M.refs("bare https://h.example/shot.jpeg here")
  check("refs: a bare image URL", #r == 1 and r[1].url == "https://h.example/shot.jpeg" and not r[1].image)
  r = M.refs("![x](https://h.example/a.png?x=1&amp;fileName=a.png)")
  check("refs: &amp; decoded", r[1] and r[1].url == "https://h.example/a.png?x=1&fileName=a.png")
  check("refs: no image, nothing", #M.refs("Author: someone    Votes: 1/2") == 0)
  check("refs: not http(s)", #M.refs("![x](file:///etc/passwd.png)") == 0)
  check("refs: an svg link isn't an image link", #M.refs("[d](https://h.example/d.svg)") == 0)
  check("looks_like_image: fileName=", M.looks_like_image("https://h.example/_apis/x?fileName=a.PNG"))

  local line = "![a](https://h.example/a.png) and ![b](https://h.example/b.png)"
  check("ref_at: the one under the cursor", M.ref_at(line, 40).url == "https://h.example/b.png")
  check("ref_at: else the first", M.ref_at(line, 31).url == "https://h.example/a.png")
  check("ref_at: none", M.ref_at("plain", 1) == nil)

  local lines = { "Description:", "  ![a](https://h.example/a.png)", "  [l](https://h.example/l.png)", "x",
    "  ![b](https://h.example/b.png) ![c](https://h.example/c.png)" }
  local want = M.inline_refs(lines, 10)
  check("inline_refs: images only, with rows", #want == 3 and want[1].row == 2 and want[2].row == 5 and want[3].row == 5)
  check("inline_refs: capped", #M.inline_refs(lines, 2) == 2)
end

-- --- terminal / renderer detection --------------------------------------------

local function env(t) return function(name) return t[name] end end
check("terminal: kitty", M.terminal_protocol(env({ TERM = "xterm-kitty" })) == "kitty")
check("terminal: WezTerm", M.terminal_protocol(env({ TERM_PROGRAM = "WezTerm" })) == "kitty")
check("terminal: Ghostty", M.terminal_protocol(env({ TERM = "xterm-ghostty" })) == "kitty")
check("terminal: foot (sixel)", M.terminal_protocol(env({ TERM = "foot" })) == "sixel")
check("terminal: plain xterm", M.terminal_protocol(env({ TERM = "xterm-256color" })) == nil)

local function req_with(mods)
  return function(name)
    if mods[name] then return true, mods[name] end
    return false, "module '" .. name .. "' not found"
  end
end
local snacks_yes = { supports_terminal = function() return true end, placement = {} }
local snacks_no = { supports_terminal = function() return false end, placement = {} }
local imagenvim = { from_file = function() end, is_enabled = function() return true end }
check("renderer: none installed -> fallback only", M.pick_renderer(req_with({}), env({ TERM = "xterm-kitty" })) == nil)
check("renderer: snacks when its terminal check says yes",
  (M.pick_renderer(req_with({ ["snacks.image"] = snacks_yes }), env({})) or {}).kind == "snacks")
check("renderer: snacks says no, nothing else",
  M.pick_renderer(req_with({ ["snacks.image"] = snacks_no }), env({ TERM = "xterm-kitty" })) == nil)
check("renderer: image.nvim in kitty",
  (M.pick_renderer(req_with({ ["snacks.image"] = snacks_no, image = imagenvim }), env({ TERM = "xterm-kitty" })) or {}).kind
    == "image.nvim")
check("renderer: image.nvim in a terminal with no image protocol",
  M.pick_renderer(req_with({ image = imagenvim }), env({ TERM = "xterm-256color" })) == nil)
check("renderer: image.nvim not enabled",
  M.pick_renderer(req_with({ image = { from_file = function() end, is_enabled = function() return false end } }),
    env({ TERM = "xterm-kitty" })) == nil)
check("renderer: a broken snacks doesn't raise",
  M.pick_renderer(req_with({ ["snacks.image"] = { supports_terminal = function() error("boom") end } }), env({})) == nil)

-- --- place / remove with stubbed renderers ------------------------------------

do
  local got, closed = nil, false
  local snacks = { supports_file = function() return true end, placement = {
    new = function(buf, src, opts) got = { buf = buf, src = src, opts = opts }
      return { close = function() closed = true end } end } }
  local h = M.place({ kind = "snacks", mod = snacks }, 5, 9, 12, "/tmp/x.png")
  check("snacks: placed under its row, inline", got and got.buf == 5 and got.src == "/tmp/x.png"
    and got.opts.pos[1] == 12 and got.opts.pos[2] == 0 and got.opts.inline == true and got.opts.max_height == M.MAX_HEIGHT)
  M.remove(h)
  check("snacks: removed with close()", closed)

  local opts, rendered, cleared = nil, false, false
  local image = { from_file = function(_, o) opts = o
    return { render = function() rendered = true end, clear = function() cleared = true end } end }
  h = M.place({ kind = "image.nvim", mod = image }, 5, 9, 12, "/tmp/x.png")
  check("image.nvim: bound to buffer and window, 0-based y, rendered", opts and opts.buffer == 5 and opts.window == 9
    and opts.y == 11 and opts.inline and opts.with_virtual_padding and rendered)
  M.remove(h)
  check("image.nvim: removed with clear()", cleared)
end

-- --- the flow, against the fake provider ----------------------------------------

local function sh(cmd)
  local a, _b, c = os.execute(cmd)
  if type(a) == "number" then return a > 255 and math.floor(a / 256) or a end
  return a == true and 0 or (c or 1)
end
local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local tmp = os.tmpname()
os.remove(tmp)
assert(sh("mkdir -p '" .. tmp .. "/ws' '" .. tmp .. "/nvim'") == 0)
do
  local f = assert(io.open(tmp .. "/ws/state.json", "w"))
  f:write('{"prs": [{"id": 7, "repo": "r"}], "threads": {}}')
  f:close()
end
local ORG = "https://dev.azure.com/demo-org"
local OWN = ORG .. "/Demo/_apis/git/repositories/r/pullRequests/7/attachments/arch.png"
local FOREIGN = "https://imgs.example.com/arch.png"

local tempn = 0  -- across sessions, as Neovim's tempname() never repeats
local function stub_vim(state)
  vim = {
    env = state.env or {},
    log = { levels = { DEBUG = 0, INFO = 2, WARN = 3, ERROR = 4 } },
    schedule = function(fn) fn() end,
    list_extend = function(dst, src) for _, v in ipairs(src) do dst[#dst + 1] = v end return dst end,
    tbl_filter = function(fn, t) local o = {} for _, v in ipairs(t) do if fn(v) then o[#o + 1] = v end end return o end,
    json = { decode = function(s)
      local path = s:match('"path":%s*"([^"]*)"')
      if not path then error("not JSON") end
      return { path = path, contentType = s:match('"contentType":%s*"([^"]*)"') }
    end },
    fn = {
      tempname = function() tempn = tempn + 1 return tmp .. "/nvim/" .. tempn end,
      expand = function() return state.cfile or "" end,
      bufwinid = function() return 9 end,
    },
    api = {
      nvim_create_autocmd = function(ev, o) state.autocmds[ev] = o.callback end,
      nvim_get_current_line = function() return state.line end,
      nvim_win_get_cursor = function() return { 1, state.col or 0 } end,
      nvim_feedkeys = function(k) state.fed[#state.fed + 1] = k end,
      nvim_replace_termcodes = function(k) return k end,
      nvim_buf_is_valid = function() return true end,
    },
    keymap = { set = function(_, k, fn, o) state.maps[o.buffer .. " " .. k] = fn end },
  }
  package.loaded["azure-cli.shell"] = { open_url = function(u) state.opened[#state.opened + 1] = u return true end }
  package.loaded["azure-cli.keys"] = { resolve = function(s, a)
    if s == "overview" and a == "open_image" then return { "<CR>", "gx" } end end }
  package.loaded["azure-cli.config"] = { get = function() return { images = { inline = state.inline ~= false } } end }
  package.loaded["azure-cli.log"] = { record = function(_, t) state.logged[#state.logged + 1] = t end }
end

local function new_session(state)
  state.autocmds, state.fed, state.maps, state.opened, state.logged = {}, {}, {}, {}, {}
  state.keys, state.popup, state.render, state.runs = {}, {}, {}, 0
  stub_vim(state)
  local ctx = {
    notify = function(msg) state.notes = (state.notes or "") .. msg .. "\n" end,
    provider = function(args) return args end,
    rpc = { run = function(argv, o)
      state.runs = state.runs + 1
      local q = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
      local out, err = tmp .. "/out", tmp .. "/err"
      local code = sh("AZVICLI_FAKE_WS=" .. q(tmp .. "/ws") .. " AZVICLI_ORG=" .. q(state.org or ORG)
        .. " AZVICLI_PROJECT=Demo AZVICLI_REPO=r AZVICLI_PR=7 python3 " .. q(FAKE) .. " azure-cli.py "
        .. table.concat((function() local t = {} for _, a in ipairs(argv) do t[#t + 1] = q(a) end return t end)(), " ")
        .. " >" .. q(out) .. " 2>" .. q(err))
      o.on_stdout(nil, { slurp(out) or "" })
      o.on_stderr(nil, { slurp(err) or "" })
      o.on_exit(nil, code)
    end },
    add_key = function(kind, action, fn, desc, mode, opts)
      state.keys[#state.keys + 1] = { kind = kind, action = action, fn = fn, chain = opts and opts.chain }
    end,
    on_comment_popup = function(fn) state.popup[#state.popup + 1] = fn end,
    on_overview_render = function(fn) state.render[#state.render + 1] = fn end,
  }
  M(ctx)
  return ctx
end

do
  local st = {}
  new_session(st)
  local reg = st.keys[1]
  check("overview: open_image registered, chained", reg and reg.kind == "overview" and reg.action == "open_image"
    and reg.chain == true)

  -- Enter on an image from the PR's own server.
  st.line = "  ![arch](" .. OWN .. ")"
  local prev_called = false
  local prev = function() prev_called = true end
  reg.fn(prev, "<CR>")
  local path = st.opened[1]
  check("own host: downloaded and opened in the viewer", path and path:match("/nvim/1%.png$") and slurp(path) ~= nil, path)
  check("own host: the earlier <CR> isn't run on an image", not prev_called)
  local mode = io.popen("stat -c %a '" .. tostring(path) .. "' 2>/dev/null"):read("*l")
  check("own host: the file is 0600", mode == "600", mode)
  local log = slurp(tmp .. "/ws/calls.log") or ""
  check("own host: the provider used the credential", log:find("auth: yes", 1, true) ~= nil)
  check("own host: no credential on argv", not log:find("not-a-real-token", 1, true))

  -- Again: no second download.
  reg.fn(prev, "<CR>")
  check("cached: one download per URL", st.runs == 1 and st.opened[2] == path, st.runs)

  -- An image on another host.
  st.line = "![x](" .. FOREIGN .. ")"
  reg.fn(prev, "gx")
  log = slurp(tmp .. "/ws/calls.log") or ""
  check("another host: no credential", log:find("auth: no", 1, true) ~= nil)
  check("another host: opened in the browser as is", st.opened[3] == FOREIGN, st.opened[3])
  check("another host: said so", (st.notes or ""):find("imgs.example.com isn't this PR's server", 1, true) ~= nil)
  local leftovers = io.popen("ls '" .. tmp .. "/nvim'"):read("*a")
  check("another host: no file written", leftovers == "1.png\n", leftovers)

  -- A line with no image: <CR> goes on to what it did before (open_commit).
  st.line = "  abc1234  2026-10-01  Alice: fix it"
  reg.fn(prev, "<CR>")
  check("no image: <CR> goes on to the earlier handler", prev_called)
  st.cfile = "https://h.example/readme"
  local before = #st.opened
  reg.fn(nil, "gx")
  check("no image: gx opens the URL under the cursor", st.opened[before + 1] == "https://h.example/readme")

  -- The K popup.
  st.popup[1](42)
  check("popup: <CR> and gx bound", st.maps["42 <CR>"] and st.maps["42 gx"])
  st.line = "│   plain words"
  st.maps["42 <CR>"]()
  check("popup: <CR> on a non-image line moves as before", st.fed[1] == "<CR>")
  st.line = "│   ![arch](" .. OWN .. ")"
  before = #st.opened
  st.maps["42 <CR>"]()
  check("popup: <CR> on an image opens it", st.opened[before + 1] == path)

  -- Cleanup on exit.
  st.autocmds.VimLeavePre()
  check("cleanup: downloaded files deleted on exit", slurp(path) == nil)
end

-- Inline: with a renderer present, and absent.
do
  local placed = {}
  package.loaded["snacks.image"] = { supports_terminal = function() return true end,
    supports_file = function() return true end,
    placement = { new = function(_, src, o) placed[#placed + 1] = { src = src, row = o.pos[1] }
      return { close = function() end } end } }
  local st = {}
  new_session(st)
  st.render[1](3, { "Description:", "  ![arch](" .. OWN .. ")", "  ![x](" .. FOREIGN .. ")", "Comments (0):" })
  check("inline: the own-host image drawn under its line", #placed == 1 and placed[1].row == 2
    and placed[1].src:match("%.png$"), #placed)
  check("inline: another host's image never fetched with a credential", #placed == 1)

  package.loaded["snacks.image"] = nil
  local st2 = {}
  new_session(st2)
  placed = {}
  st2.render[1](3, { "  ![arch](" .. OWN .. ")" })
  check("inline: no renderer, nothing drawn and nothing fetched", #placed == 0 and st2.runs == 0)

  package.loaded["snacks.image"] = { supports_terminal = function() return true end,
    placement = { new = function() error("api changed") end } }
  local st3 = {}
  new_session(st3)
  st3.render[1](3, { "  ![arch](" .. OWN .. ")" })
  check("inline: a failing renderer turns inline off, logged", #st3.logged == 1)
  local runs = st3.runs
  st3.render[1](3, { "  ![arch](" .. OWN .. ")" })
  check("inline: and stays off", st3.runs == runs)

  package.loaded["snacks.image"] = { supports_terminal = function() return true end,
    placement = { new = function() placed[#placed + 1] = 1 return { close = function() end } end } }
  local st4 = { inline = false }
  new_session(st4)
  placed = {}
  st4.render[1](3, { "  ![arch](" .. OWN .. ")" })
  check("inline: images.inline = false turns it off", #placed == 0)
  package.loaded["snacks.image"] = nil
end

sh("rm -rf '" .. tmp .. "'")
print(fails == 0 and "test-review-images: all cases pass" or ("test-review-images: " .. fails .. " unexpected"))
os.exit(fails == 0 and 0 or 1)
