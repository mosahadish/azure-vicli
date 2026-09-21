-- lua/azure-cli/prompt.lua: the one place this plugin asks the user to
-- pick or type something. Every menu used to be a vim.fn.inputlist() (a
-- numbered list in the command line, digit + Enter to choose) and every
-- text prompt a vim.fn.input(); both are synchronous and neither is
-- something a picker plugin (telescope, fzf-lua, dressing.nvim, snacks)
-- can take over. These wrappers go through vim.ui.select / vim.ui.input
-- instead, so whatever the user has installed draws the menu, and fall
-- back to Neovim's built-in ones otherwise.
--
-- Both are asynchronous: the answer arrives in `cb`, never as a return
-- value. cb(nil) means cancelled (Esc, q, an empty pick) - and unless
-- opts.silent is set, a cancel is also announced with a "Cancelled."
-- flash, since that used to be every call site's own first line.
local M = {}

local function notify(msg, level)
  require("azure-cli.notify").flash(msg, level or vim.log.levels.INFO)
end

-- M.select(opts, cb): a menu.
--   opts.prompt   the title ("Vote on PR #123")
--   opts.items    a list; each entry is a string, or a table with a
--                 `label` (what's shown) and anything else the caller wants
--                 back
--   opts.current  the entry (or a predicate on entries) that reflects the
--                 present value - it's shown with a "(current)" suffix so
--                 the user can tell "change" from "set" at a glance
--   opts.format   optional item -> string, instead of `label`/tostring
--   opts.silent   don't flash "Cancelled." on a cancel
-- cb(item, index) with the chosen entry (the caller's own table/string),
-- or cb(nil) on cancel.
function M.select(opts, cb)
  opts = opts or {}
  local items = opts.items or {}
  if #items == 0 then
    if not opts.silent then notify("Nothing to choose from.", vim.log.levels.WARN) end
    cb(nil)
    return
  end
  local function is_current(item)
    local cur = opts.current
    if cur == nil then return false end
    if type(cur) == "function" then return cur(item) and true or false end
    return item == cur
  end
  local function format(item)
    local s
    if opts.format then
      s = opts.format(item)
    elseif type(item) == "table" then
      s = tostring(item.label or item.name or item[1] or "?")
    else
      s = tostring(item)
    end
    if is_current(item) then s = s .. "  (current)" end
    return s
  end
  local prompt = opts.prompt or "Choose:"
  if not prompt:match("[:?]%s*$") then prompt = prompt .. ":" end
  vim.ui.select(items, { prompt = prompt, format_item = format, kind = opts.kind or "azure-cli" },
    function(choice, idx)
      if choice == nil then
        if not opts.silent then notify("Cancelled.") end
        cb(nil)
        return
      end
      cb(choice, idx)
    end)
end

-- M.input(opts, cb): a one-line text prompt.
--   opts.prompt, opts.default, opts.completion (vim.ui.input's own fields)
--   opts.allow_empty  pass "" through instead of treating it as a cancel
--   opts.silent       don't flash "Cancelled." on a cancel
-- cb(text) with the (whitespace-trimmed) text, or cb(nil) on cancel /
-- empty. Multi-line text belongs in lua/azure-cli/editor.lua, not here.
function M.input(opts, cb)
  opts = opts or {}
  local prompt = opts.prompt or "> "
  if not prompt:match("%s$") then prompt = prompt .. " " end
  vim.ui.input({ prompt = prompt, default = opts.default, completion = opts.completion }, function(text)
    if text == nil then
      if not opts.silent then notify("Cancelled.") end
      cb(nil)
      return
    end
    text = vim.trim(text)
    if text == "" and not opts.allow_empty then
      if not opts.silent then notify("Cancelled.") end
      cb(nil)
      return
    end
    cb(text)
  end)
end

-- M.confirm(opts, cb): a yes/no question. opts.prompt is the question,
-- opts.yes/opts.no relabel the two answers ("Merge", "Keep open"). cb(true)
-- only when the affirmative answer was picked; anything else - including
-- Esc - is cb(false), so a destructive action can never run by accident.
function M.confirm(opts, cb)
  opts = opts or {}
  local yes = opts.yes or "Yes"
  local no = opts.no or "Cancel"
  M.select({ prompt = opts.prompt or "Are you sure?", items = { yes, no }, silent = true }, function(choice)
    cb(choice == yes)
  end)
end

return M
