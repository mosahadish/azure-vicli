-- lua/azure-cli/keys.lua: resolves a surface+action pair to the user's
-- configured key(s) (lua/azure-cli/config.lua) and binds it, so no UI file
-- ever hard-codes a key string at a `vim.keymap.set` call site - every one
-- goes through M.bind instead. `false` in the config unbinds an action;
-- a list of strings binds several keys to the same action; a per-surface
-- `keys.prefix` (config.lua's `keys.prefix`) is prepended to every key
-- resolved for that surface.
--
-- Also builds the `?` popup lines from the same resolved keys, so
-- overriding a key or unbinding an action is reflected there without a
-- second place to edit. Winbars themselves no longer spell out a key
-- legend at all (see lua/azure-cli/ui.lua's `UI.winbar` - every winbar is
-- "what you're looking at + mode tags + ?: help" now, and `?` has the
-- keys); M.label below is kept as a small reusable "key: hint" primitive.
local M = {}

local function config()
  return require("azure-cli.config").get()
end

-- Resolves `surface`/`action` to nil (unbound - `false` in the config, or
-- an unknown surface), a single key string, or a list of key strings - the
-- same shape M.bind/M.line/M.label all accept, with any configured prefix
-- for that surface applied.
function M.resolve(surface, action)
  local cfg = config()
  local surf = cfg.keys and cfg.keys[surface]
  if not surf then return nil end
  local keyspec = surf[action]
  if keyspec == nil or keyspec == false then return nil end

  local prefix = cfg.keys.prefix and cfg.keys.prefix[surface]
  if not prefix or prefix == "" then return keyspec end

  if type(keyspec) == "table" then
    local out = {}
    for _, k in ipairs(keyspec) do out[#out + 1] = prefix .. k end
    return out
  end
  return prefix .. keyspec
end

-- The first key resolved for surface/action, or nil when it's unbound - for
-- a message or hint that names the key ("approve it again (gA)").
function M.first(surface, action)
  local k = M.resolve(surface, action)
  if type(k) == "table" then k = k[1] end
  return k
end

-- Every normal-mode action bound on each buffer, in binding order, for the
-- palette: actions[buf] = { list = { { surface, action, key, desc, fn } },
-- at = { [surface .. "." .. action] = index }, surfaces = { [surface] = true } }.
local actions = {}

-- The palette (`palette`, g.): every action bound on `buf` by its
-- description and key, through vim.ui.select - so Telescope's / fzf-lua's
-- picker, when one replaces it, makes it searchable. The choice runs in the
-- window the palette was opened from, cursor where it was.
function M.palette(buf)
  local reg = actions[buf]
  if not reg then return end
  local items = {}
  for _, a in ipairs(reg.list) do
    if a.action ~= "palette" then items[#items + 1] = a end
  end
  local win = vim.api.nvim_get_current_win()
  require("azure-cli.prompt").select({ items = items, prompt = "Do", silent = true,
    format = function(a) return a.desc .. "  (" .. a.key .. ")" end }, function(a)
    if not a then return end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_set_current_win, win) end
      a.fn()
    end)
  end)
end

-- Notes surface/action as bound on `buf` (normal mode only - the palette
-- can't hand a visual selection over), and binds the palette key for that
-- surface the first time the buffer gets one of its keys. Not under the
-- plain-luajit shim the key tests run with (no vim.api there).
local function record(buf, surface, action, key, desc, fn)
  if not vim.api then return end
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local reg = actions[buf]
  if not reg then
    reg = { list = {}, at = {}, surfaces = {} }
    actions[buf] = reg
    pcall(vim.api.nvim_create_autocmd, "BufWipeout", { buffer = buf, once = true,
      callback = function() actions[buf] = nil end })
  end
  local id = surface .. "." .. action
  local entry = { surface = surface, action = action, key = key, desc = desc, fn = fn }
  if reg.at[id] then reg.list[reg.at[id]] = entry
  else
    reg.list[#reg.list + 1] = entry
    reg.at[id] = #reg.list
  end
  if not reg.surfaces[surface] then
    reg.surfaces[surface] = true
    if action ~= "palette" then
      M.bind(buf, surface, "palette", function() M.palette(buf) end, { desc = "every action here, searchable" })
    end
  end
end

-- Binds `fn` to every key resolved for surface/action on `buf`, or does
-- nothing when the action is unbound. `opts.mode` defaults to "n" (pass
-- "x" for a visual-mode mapping, e.g. the diff pane's comment_range);
-- `opts.desc` is forwarded to vim.keymap.set (which-key etc. read it).
-- A buffer's first key of a surface also binds that surface's palette.
function M.bind(buf, surface, action, fn, opts)
  opts = opts or {}
  local keyspec = M.resolve(surface, action)
  if not keyspec then return end
  local mode = opts.mode or "n"
  local kopts = { buffer = buf, silent = true, nowait = true }
  if opts.desc then kopts.desc = opts.desc end
  local keylist = type(keyspec) == "table" and keyspec or { keyspec }
  for _, k in ipairs(keylist) do
    vim.keymap.set(mode, k, fn, kopts)
  end
  if mode == "n" then
    record(buf, surface, action, keylist[1], opts.desc or (tostring(action):gsub("_", " ")), fn)
  end
end

-- One `?`-popup line for surface/action ("  key[, key2]    desc"), or nil
-- when the action is unbound (so a popup builder can just skip a nil line).
-- One popup line from an already-resolved key string (a module's
-- ctx.add_key entry, or M.line below): "  key         desc".
function M.line_raw(keystr, desc)
  local pad = math.max(1, 12 - vim.fn.strdisplaywidth(keystr))
  return "  " .. keystr .. string.rep(" ", pad) .. tostring(desc or "")
end

function M.line(surface, action, desc)
  local keyspec = M.resolve(surface, action)
  if not keyspec then return nil end
  -- A missing description must never take the whole popup down (it once
  -- did: a nil here made `?` throw) - fall back to the action's own name.
  desc = desc or (tostring(action):gsub("_", " "))
  local keystr = type(keyspec) == "table" and table.concat(keyspec, " / ") or keyspec
  return M.line_raw(keystr, desc)
end

-- The whole `?` popup body for a surface: `title`, then the current
-- state (`opts.now`, a list of strings - the mode tags / active filter -
-- so "why are comments missing?" is answerable from the popup), then
-- `table`'s entries grouped under headings. `table` is a flat list of
-- { action, desc } pairs with plain strings between them naming the
-- group that follows ("Navigate", "Comment", ...); `opts.fixed` lists
-- lines that go first under the first group (j/k and other native
-- motions this tool doesn't bind); `opts.extra` ({ key, desc } entries
-- from feature modules) goes under `opts.extra_title`; `opts.notes`
-- (strings) close the popup. Unbound actions are skipped, and a group
-- with nothing left in it is skipped too.
function M.help_lines(surface, title, table_, opts)
  opts = opts or {}
  local lines = { title }
  if opts.now and #opts.now > 0 then
    lines[#lines + 1] = "  now: " .. table.concat(opts.now, "  ")
  end
  local pending_group, group_open = nil, false
  local function open_group(name)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "\u{2500}\u{2500} " .. name .. " \u{2500}\u{2500}"
    group_open = true
  end
  local first = true
  for _, a in ipairs(table_) do
    if type(a) == "string" then
      pending_group = a
      group_open = false
    else
      local line = M.line(surface, a[1], a[2])
      if line then
        if pending_group and not group_open then open_group(pending_group) end
        if first and opts.fixed then
          for _, f in ipairs(opts.fixed) do lines[#lines + 1] = f end
        end
        first = false
        lines[#lines + 1] = line
      end
    end
  end
  if opts.extra and #opts.extra > 0 then
    open_group(opts.extra_title or "Features")
    for _, e in ipairs(opts.extra) do lines[#lines + 1] = M.line_raw(e.key, e.desc) end
  end
  local pal = M.first(surface, "palette")
  if pal then
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.line_raw(pal, "every action here, searchable")
  end
  for _, n in ipairs(opts.notes or {}) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = n
  end
  return lines
end

-- The "keys that matter now" block a screen's side list ends with (the
-- plan's sections, the change's files): " key  what it does" for each
-- { surface, action, desc } in `list` that's bound - the screen picks the
-- entries from its state, so a draft plan offers approve and an approved
-- one doesn't. Returns lines, hls: { block row (0-based), from, to, group }
-- - the line muted, its key in AzureCliKeyHint.
function M.hint_lines(list)
  local lines, hls = {}, {}
  for _, h in ipairs(list) do
    local k = M.first(h[1], h[2])
    if k then
      lines[#lines + 1] = " " .. k .. "  " .. h[3]
      hls[#hls + 1] = { #lines - 1, 0, #lines[#lines], "AzureCliMuted" }
      hls[#hls + 1] = { #lines - 1, 1, 1 + #k, "AzureCliKeyHint" }
    end
  end
  return lines, hls
end

-- The same block as one line for a wide screen (the Agents list):
-- "key what it does · key what it does", and hls as { from, to, group }.
function M.hint_line(list, lead)
  local text, hls = lead or "", {}
  for _, h in ipairs(list) do
    local k = M.first(h[1], h[2])
    if k then
      if #hls > 0 then text = text .. "  \u{00B7}  " end
      hls[#hls + 1] = { #text, #text + #k, "AzureCliKeyHint" }
      text = text .. k .. " " .. h[3]
    end
  end
  return text, hls
end

-- A short "key: hint" winbar chip for surface/action, or "" when unbound -
-- callers join a list of these with two spaces (see M.winbar).
function M.label(surface, action, hint)
  local keyspec = M.resolve(surface, action)
  if not keyspec then return "" end
  local keystr = type(keyspec) == "table" and keyspec[1] or keyspec
  return keystr .. ": " .. hint
end

return M
