-- lua/azure-cli/review/images.lua: images in a PR's description and
-- comments (#134). An image there is Markdown or HTML - on a TFS PR an
-- attachment URL that needs the PAT, on GitHub a user-attachments URL that
-- needs the token for a private repository - so the Overview used to show
-- it as raw text with no way to see it.
--
-- Wired in by review/init.lua as EXT.images = require(this file)(ctx), the
-- same __call pattern as review/comments.lua: the table's own fields are
-- pure helpers tests/test-review-images.lua exercises without nvim.
--
-- Fallback, always there: Enter and gx on an image line or an image link
-- (the Overview, and the K comment popup) download it through the provider
-- (azure-cli.py --fetch-image, which holds the credential) into a file in
-- Neovim's private temp directory and open that in the system viewer
-- (shell.lua's open_url: vim.ui.open on 0.10+, else open/xdg-open/start).
-- The provider only sends the credential to the PR's own server; a URL on
-- another host comes back as exit 3 with no request made, and is opened in
-- the browser without credentials instead - what Neovim's own gx does.
-- On a line with no image the keys do what they did before: the Overview's
-- <CR> goes on to open_commit (ctx.add_key's chain), gx opens the URL under
-- the cursor, and the popup's <CR> moves down a line.
--
-- Inline, when it can: snacks.nvim's image module or image.nvim, found at
-- runtime with pcall(require) and never required, draws each image (the
-- first MAX_INLINE ones, Markdown/<img> only) under its line in the
-- Overview, from the same downloaded file. Every call into either plugin
-- is pcall'd; one that fails turns inline off for the session, leaving the
-- fallback. Images from another host are never fetched for this.

local M = {}

M.FOREIGN = 3        -- azure-cli.py's FETCH_IMAGE_FOREIGN
M.MAX_INLINE = 10
M.MAX_HEIGHT = 15

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true }

-- True when a link's URL looks like an image: an image extension, an Azure
-- DevOps attachment (PR or work item, or fileName=x.png), or a GitHub
-- user-attachments asset.
function M.looks_like_image(url)
  local path = url:match("^[^?#]*") or url
  local ext = path:match("%.(%w+)$")
  if ext and IMAGE_EXT[ext:lower()] then return true end
  if path:find("/pullRequests/%d+/attachments/") or path:find("/_apis/wit/attachments/")
      or path:find("/user%-attachments/assets/") then
    return true
  end
  local fname = url:match("[?&][Ff]ile[Nn]ame=([^&#]+)")
  local fext = fname and fname:match("%.(%w+)$")
  return fext ~= nil and IMAGE_EXT[fext:lower()] == true
end

local function unescape(url)
  return (url:gsub("&amp;", "&"))
end

-- Every image reference on one line, in column order: { s, e, url, image }
-- with s/e 1-based byte columns, image=true for ![alt](url) and <img src>
-- (drawn inline), false for a [text](url) link or a bare URL that looks
-- like an image (opened only). http(s) URLs only. A reference overlapping
-- an earlier-found one is skipped ([![x](a)](b) is one image).
function M.refs(line)
  local found = {}
  local function overlaps(s, e)
    for _, r in ipairs(found) do
      if s <= r.e and e >= r.s then return true end
    end
    return false
  end
  local function add(s, e, url, image)
    url = unescape(url)
    if not url:match("^[Hh][Tt][Tt][Pp][Ss]?://") or overlaps(s, e) then return end
    found[#found + 1] = { s = s, e = e, url = url, image = image }
  end
  local function scan(pattern, each)
    local init = 1
    while true do
      local s, e, cap = line:find(pattern, init)
      if not s then return end
      each(s, e, cap)
      init = e + 1
    end
  end
  scan("!%[[^%]]*%]%(%s*<?([^%s%)>]+)>?[^%)]*%)", function(s, e, url) add(s, e, url, true) end)
  scan("<[Ii][Mm][Gg]%s[^>]*>", function(s, e)
    local tag = line:sub(s, e)
    local url = tag:match('[Ss][Rr][Cc]%s*=%s*"([^"]+)"') or tag:match("[Ss][Rr][Cc]%s*=%s*'([^']+)'")
    if url then add(s, e, url, true) end
  end)
  scan("%[[^%]]*%]%(%s*<?([^%s%)>]+)>?[^%)]*%)", function(s, e, url)
    if M.looks_like_image(url) then add(s, e, url, false) end
  end)
  scan("[Hh][Tt][Tt][Pp][Ss]?://[^%s%)%]>\"'<]+", function(s, e)
    local url = line:sub(s, e)
    if M.looks_like_image(url) then add(s, e, url, false) end
  end)
  table.sort(found, function(a, b) return a.s < b.s end)
  return found
end

-- The reference under 1-based column col, else the first on the line.
function M.ref_at(line, col)
  local refs = M.refs(line or "")
  for _, r in ipairs(refs) do
    if col >= r.s and col <= r.e then return r end
  end
  return refs[1]
end

-- The images to draw inline for a buffer's lines: { row (1-based), url },
-- Markdown/<img> only, the first `max` of them.
function M.inline_refs(lines, max)
  local out = {}
  for row, line in ipairs(lines) do
    for _, r in ipairs(M.refs(line)) do
      if r.image then
        if #out >= max then return out end
        out[#out + 1] = { row = row, url = r.url }
      end
    end
  end
  return out
end

-- The image protocol the terminal speaks, from its environment (getenv:
-- name -> value or nil): "kitty" for the kitty graphics protocol (kitty,
-- WezTerm, Ghostty), "sixel" for the terminals known to draw sixel, else
-- nil. Through tmux the outer terminal's variables usually still show.
function M.terminal_protocol(getenv)
  local term, prog = getenv("TERM") or "", getenv("TERM_PROGRAM") or ""
  if term:find("kitty") or getenv("KITTY_WINDOW_ID") or prog == "WezTerm" or getenv("WEZTERM_EXECUTABLE")
      or prog == "ghostty" or term:find("ghostty") or getenv("GHOSTTY_RESOURCES_DIR") then
    return "kitty"
  end
  if term:find("^foot") or term:find("mlterm") or term:find("contour") or term:find("sixel") then
    return "sixel"
  end
  return nil
end

-- Which inline renderer to use, or nil for the fallback only. req is a
-- pcall(require)-alike (tests stub it), getenv as above.
--   snacks.nvim  require("snacks.image"): supports_terminal() decides (it
--                knows kitty/WezTerm/Ghostty and tmux passthrough); kitty
--                graphics only.
--   image.nvim   require("image"): is_enabled() (set up by the user) and a
--                terminal M.terminal_protocol recognises - kitty graphics,
--                or sixel for its sixel backend.
function M.pick_renderer(req, getenv)
  local ok, snacks = req("snacks.image")
  if ok and type(snacks) == "table" and type(snacks.supports_terminal) == "function" then
    local ok2, yes = pcall(snacks.supports_terminal)
    if ok2 and yes then return { kind = "snacks", mod = snacks } end
  end
  local ok3, image = req("image")
  if ok3 and type(image) == "table" and type(image.from_file) == "function" then
    local enabled = type(image.is_enabled) ~= "function" or select(2, pcall(image.is_enabled)) == true
    if enabled and M.terminal_protocol(getenv) then return { kind = "image.nvim", mod = image } end
  end
  return nil
end

-- Draws one downloaded image under 1-based `row` of buf (shown in win).
-- Returns a handle for M.remove, or raises (callers pcall).
function M.place(renderer, buf, win, row, path)
  if renderer.kind == "snacks" then
    local mod = renderer.mod
    if type(mod.supports_file) == "function" and not mod.supports_file(path) then return nil end
    local p = mod.placement.new(buf, path, { pos = { row, 0 }, inline = true, max_height = M.MAX_HEIGHT })
    return { kind = "snacks", obj = p }
  end
  -- y is 0-based: the image's own line, padded below it.
  local img = renderer.mod.from_file(path, {
    buffer = buf, window = win, x = 0, y = row - 1, inline = true, with_virtual_padding = true, height = M.MAX_HEIGHT,
  })
  if not img then return nil end
  img:render()
  return { kind = "image.nvim", obj = img }
end

function M.remove(handle)
  if not handle or not handle.obj then return end
  if handle.kind == "snacks" then handle.obj:close() else handle.obj:clear() end
end

local function setup(ctx)
  local SHELL = require("azure-cli.shell")
  local KEYS = require("azure-cli.keys")
  local cache = {}   -- url -> { path, err, foreign, done, waiting }
  local files = {}   -- every file downloaded, deleted on VimLeavePre
  local renderer     -- nil: not looked up yet; false: none (or it failed)
  local placed = {}  -- the Overview's current inline handles
  -- Bumped on every redraw, so a download landing after the next render
  -- doesn't place onto lines that moved. Every render redraws: its
  -- set_lines squashes the old placements' extmarks even when nothing
  -- changed. The files are cached, so that's no new download.
  local generation = 0

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      for _, f in ipairs(files) do pcall(os.remove, f) end
    end,
  })

  -- cb(path, err, foreign) once the provider has answered for url. One
  -- download per URL per session; a failure isn't kept, so trying again
  -- asks again.
  local function fetch(url, cb)
    local c = cache[url]
    if c and c.done then return cb(c.path, c.err, c.foreign) end
    if c then
      table.insert(c.waiting, cb)
      return
    end
    c = { waiting = { cb } }
    cache[url] = c
    local out, err = {}, {}
    ctx.rpc.run(ctx.provider({ "--fetch-image", url, vim.fn.tempname() }), {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
      on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
      on_exit = function(_, code)
        vim.schedule(function()
          c.done = true
          if code == 0 then
            local ok, res = pcall(vim.json.decode, table.concat(out, "\n"))
            if ok and type(res) == "table" and type(res.path) == "string" then
              c.path = res.path
              files[#files + 1] = res.path
            else
              c.err = "the provider's answer wasn't understood"
            end
          elseif code == M.FOREIGN then
            c.foreign = true
          else
            local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
            c.err = msg ~= "" and msg or ("exit " .. tostring(code))
            cache[url] = nil
          end
          local waiting = c.waiting
          c.waiting = {}
          for _, f in ipairs(waiting) do f(c.path, c.err, c.foreign) end
        end)
      end,
    })
  end

  local function open_image(url)
    fetch(url, function(path, err, foreign)
      if foreign then
        local host = url:match("^%a+://([^/?#]+)") or url
        ctx.notify(host .. " isn't this PR's server - opened in the browser without your credentials.")
        local ok, why = SHELL.open_url(url)
        if not ok then ctx.notify("Couldn't open the image: " .. tostring(why), vim.log.levels.WARN) end
      elseif path then
        local ok, why = SHELL.open_url(path)
        if not ok then ctx.notify("Couldn't open the image: " .. tostring(why), vim.log.levels.WARN) end
      else
        ctx.notify("Couldn't download the image: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end
  M.open_image = open_image

  -- The image under the cursor in the current window, if any.
  local function ref_here()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    return M.ref_at(vim.api.nvim_get_current_line(), col)
  end

  -- What the key did before this module, on a line with no image: the
  -- handler it chains onto, else gx opens the URL under the cursor (as
  -- Neovim's own gx) and any other key does its built-in motion.
  local function fall_through(prev, key)
    if prev then return prev() end
    if key == "gx" then
      local cfile = vim.fn.expand("<cfile>")
      if cfile:match("^%a[%w+.-]*://") then SHELL.open_url(cfile) end
      return
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
  end

  local function handle(prev, key)
    local ref = ref_here()
    if ref then return open_image(ref.url) end
    fall_through(prev, key)
  end

  ctx.add_key("overview", "open_image", handle, "open the image under the cursor (a viewer, with your credentials)",
    nil, { chain = true })

  -- The K popup: a fresh buffer per view, so bound here; it takes the
  -- Overview's open_image keys.
  ctx.on_comment_popup(function(fbuf)
    local keyspec = KEYS.resolve("overview", "open_image")
    if not keyspec then return end
    for _, k in ipairs(type(keyspec) == "table" and keyspec or { keyspec }) do
      vim.keymap.set("n", k, function() handle(nil, k) end,
        { buffer = fbuf, silent = true, nowait = true, desc = "open the image under the cursor" })
    end
  end)

  -- Inline in the Overview.
  local function clear_placed()
    for _, h in ipairs(placed) do pcall(M.remove, h) end
    placed = {}
  end

  local function get_renderer()
    if renderer == nil then
      local cfg = require("azure-cli.config").get().images or {}
      renderer = cfg.inline ~= false and M.pick_renderer(function(name) return pcall(require, name) end,
        function(name) return vim.env[name] end) or false
    end
    return renderer or nil
  end

  local function draw(buf, lines)
    local r = get_renderer()
    if not r then return end
    generation = generation + 1
    local gen = generation
    clear_placed()
    for _, w in ipairs(M.inline_refs(lines, M.MAX_INLINE)) do
      fetch(w.url, function(path, err)
        if gen ~= generation or not renderer then return end
        if not path then
          if err then require("azure-cli.log").record("images", "inline image: " .. tostring(err)) end
          return
        end
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local win = vim.fn.bufwinid(buf)
        if win == -1 then return end  -- not on screen: the next render draws it
        local ok, h = pcall(M.place, r, buf, win, w.row, path)
        if ok then
          if h then placed[#placed + 1] = h end
        else
          renderer = false
          clear_placed()
          require("azure-cli.log").record("images",
            "inline images are off for this session - Enter/gx still opens them: " .. tostring(h))
        end
      end)
    end
  end

  ctx.on_overview_render(function(buf, lines)
    vim.schedule(function() draw(buf, lines) end)
  end)

  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
