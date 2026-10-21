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
-- value. cb(nil) means cancelled (Esc, q, an empty pick), quietly.
--
-- With ui.confirm = "popup" (the default) a yes/no question and a short
-- menu are ui.lua's popup instead (M.choose): buttons in the middle of the
-- screen, a menu's entries numbered. Long lists, and ones a caller marks
-- `search`, are picker.lua's filter-as-you-type popup, and a text prompt
-- its one-line popup - but only while vim.ui.select / vim.ui.input are
-- Neovim's own (a command-line prompt or numbered list): a picker plugin
-- that has taken them over (telescope, fzf-lua, dressing, snacks) still
-- draws them. With ui.confirm = "select" everything is vim.ui.*.
local M = {}

-- Up to this many entries a menu is a popup; more go to vim.ui.select.
M.POPUP_MAX = 7

local function popup_style()
  local ok, cfg = pcall(function() return require("azure-cli.config").get() end)
  return not (ok and cfg and cfg.ui and cfg.ui.confirm == "select")
end

local notify = require("azure-cli.shell").notify

-- Whether vim.ui.<name> is still Neovim's built-in one (runtime/lua/vim/ui.lua).
local function builtin(name)
  local ok, info = pcall(debug.getinfo, vim.ui[name], "S")
  return ok and info and (info.source or ""):find("vim[/\\]ui%.lua$") ~= nil
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
--   opts.silent   no "Nothing to choose from." warning on an empty list
--   opts.search   always vim.ui.select (a list worth searching), never the
--                 popup
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
  if popup_style() and not opts.search and #items <= M.POPUP_MAX then
    local labels, focused = {}, 1
    for i, it in ipairs(items) do
      labels[i] = i .. "  " .. format(it)
      if is_current(it) then focused = i end
    end
    local keys = {}
    for i = 1, #items do keys[tostring(i)] = i end
    require("azure-cli.ui").choose({ title = (opts.prompt or "Choose"):gsub("[:%s]+$", ""), buttons = labels,
      default = focused, keys = keys, cancel = false, stack = true,
      hint = "1-" .. #items .. " or Enter picks \u{00B7} j / k move \u{00B7} Esc cancels" }, function(i)
      if not i then
        return cb(nil)
      end
      cb(items[i], i)
    end)
    return
  end
  if popup_style() and builtin("select") then
    require("azure-cli.picker").open({ title = (opts.prompt or "Choose"):gsub("[:%s]+$", ""), items = items,
      format = opts.format or function(item)
        return type(item) == "table" and tostring(item.label or item.name or item[1] or "?") or tostring(item)
      end, current = opts.current and is_current or nil }, function(choice, idx)
      if choice == nil then
        return cb(nil)
      end
      cb(choice, idx)
    end)
    return
  end
  local prompt = opts.prompt or "Choose:"
  if not prompt:match("[:?]%s*$") then prompt = prompt .. ":" end
  vim.ui.select(items, { prompt = prompt, format_item = format, kind = opts.kind or "azure-cli" },
    function(choice, idx)
      if choice == nil then
        cb(nil)
        return
      end
      cb(choice, idx)
    end)
end

-- M.input(opts, cb): a one-line text prompt.
--   opts.prompt, opts.default, opts.completion (vim.ui.input's own fields)
--   opts.allow_empty  pass "" through instead of treating it as a cancel
-- cb(text) with the (whitespace-trimmed) text, or cb(nil) on cancel /
-- empty. Multi-line text belongs in lua/azure-cli/editor.lua, not here.
function M.input(opts, cb)
  opts = opts or {}
  local prompt = opts.prompt or "> "
  if not prompt:match("%s$") then prompt = prompt .. " " end
  local ask = (popup_style() and builtin("input")) and require("azure-cli.picker").input or vim.ui.input
  ask({ prompt = prompt, default = opts.default, completion = opts.completion }, function(text)
    if text == nil then
      cb(nil)
      return
    end
    text = vim.trim(text)
    if text == "" and not opts.allow_empty then
      cb(nil)
      return
    end
    cb(text)
  end)
end

-- M.confirm(opts, cb): a yes/no question, answered Yes or Cancel (Yes
-- focused). opts.title and opts.prompt are the question (a title alone
-- will do), opts.details text shown above it. cb(true) only for Yes;
-- anything else - including Esc - is cb(false).
function M.confirm(opts, cb)
  opts = opts or {}
  local yes, no = "Yes", "Cancel"
  if popup_style() then
    -- With a title, the question can be the title alone (no prompt).
    local body = opts.prompt and { opts.prompt } or (opts.title and {} or { "Are you sure?" })
    return require("azure-cli.ui").confirm({ title = opts.title, lines = body, yes = yes, no = no,
      details = opts.details, details_ft = opts.details_ft }, cb)
  end
  M.select({ prompt = opts.prompt or "Are you sure?", items = { yes, no }, silent = true }, function(choice)
    cb(choice == yes)
  end)
end

return M
