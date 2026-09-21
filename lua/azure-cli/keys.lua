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

-- Binds `fn` to every key resolved for surface/action on `buf`, or does
-- nothing when the action is unbound. `opts.mode` defaults to "n" (pass
-- "x" for a visual-mode mapping, e.g. the diff pane's comment_range);
-- `opts.desc` is forwarded to vim.keymap.set (which-key etc. read it).
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
  for _, n in ipairs(opts.notes or {}) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = n
  end
  return lines
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
