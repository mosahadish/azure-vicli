-- standalone/init.lua: entry point for the "azure-cli"/"azure-cli.cmd"
-- launcher (azure-cli.py's launch_dashboard runs `nvim -u <this file>`
-- instead of `-u NONE -c luafile ...`, exactly the same principle, just
-- routed through the plugin's own require()-based modules instead of
-- dofile()/:luafile-ing the old standalone scripts directly).
--
-- Loaded with `-u`, so it stands in for a whole init.vim/init.lua: nothing
-- else is sourced first, which is why this is the one place that has to
-- add the plugin root to 'runtimepath' by hand before require("azure-cli")
-- resolves - a plugin-manager install (lazy.nvim, packer, ...) already puts
-- it there before plugin/azure-cli.lua or any require() call ever runs.
local function this_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(path, ":p:h")
end

-- This file's own directory is standalone/ - one directory up is the plugin
-- root (repo root, since the plugin lives there rather than nested).
local ROOT = vim.fn.fnamemodify(this_dir(), ":h")
vim.opt.rtp:prepend(ROOT)

if vim.fn.has("nvim-0.9") == 0 then
  local v = vim.version and vim.version() or {}
  vim.api.nvim_echo({ { "azure-cli needs Neovim 0.9 or newer (this is " .. tostring(v.major or "?") .. "."
    .. tostring(v.minor or "?") .. "). Install a newer Neovim and run the launcher again.", "ErrorMsg" } }, true, {})
  return
end

local azure_cli = require("azure-cli")
azure_cli.set_standalone(true)

-- Session-wide options for the launcher's own Neovim (there is no user
-- init.lua here to have set them). In plugin mode these are the user's
-- business and never touched - each surface only sets window-local
-- options on its own windows (lua/azure-cli/ui.lua's UI.plain_window).
vim.o.hidden = true
vim.o.termguicolors = true
vim.o.laststatus = 2
vim.o.mouse = "a"
vim.cmd("syntax on")

-- Standalone users have no init.lua of their own to call setup() from, so
-- an optional azure-cli.lua next to the YAML config (same directory as
-- config.config_path(): %APPDATA% on Windows, the XDG config dir elsewhere)
-- may `return { keys = {...}, timing = {...}, ... }` - exactly the table
-- setup() takes in plugin mode. A broken file is reported and ignored
-- rather than preventing the dashboard from opening.
local function standalone_opts()
  local yml = require("azure-cli.config").config_path()
  local path = yml:gsub("%.yml$", ".lua")
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, opts = pcall(dofile, path)
  if not ok then
    vim.schedule(function()
      vim.notify("azure-cli.lua could not be loaded: " .. tostring(opts), vim.log.levels.ERROR)
    end)
    return {}
  end
  if type(opts) ~= "table" then
    vim.schedule(function()
      vim.notify("azure-cli.lua must return a table of setup() options; ignoring it.", vim.log.levels.ERROR)
    end)
    return {}
  end
  return opts
end
azure_cli.setup(standalone_opts())

-- Standalone's colour palette. Every highlight group the dashboard/reviewer/
-- work-items surfaces define is `default = true, link = <standard group>`
-- (see their own UI.link_hl calls), so a plugin-mode install inherits
-- the colorscheme already active in the user's session. Standalone is the
-- one case with no colorscheme to inherit (`nvim -u` skips it entirely), so
-- this is the one place that still wants the tool's own fixed hex palette,
-- matching every release before this plugin restructure - applied here,
-- BEFORE open_dashboard()/etc. below ever define their own groups: a
-- highlight group set explicitly (no `default`, as these calls are) is
-- never overridden by a later `default = true` call for the same group
-- (see :h nvim_set_hl's `default` field), so setting the real colours first
-- and letting each surface's own `default = true` links land second/no-op
-- is what makes them win over the standard-group links.
local function hl(name, o) vim.api.nvim_set_hl(0, name, o) end
local function apply_palette()
  -- Dashboard (lua/azure-cli/dashboard.lua's UI.link_hl call).
  hl("AzureCliHeader", { fg = "#89b4fa", bold = true })
  hl("AzureCliId", { fg = "#cba6f7" })
  hl("AzureCliRepo", { fg = "#94e2d5" })
  hl("AzureCliAuthor", { fg = "#bac2de" })
  hl("AzureCliVote", { fg = "#89dceb" })
  hl("AzureCliThread", { fg = "#f9e2af", bold = true })
  hl("AzureCliThreadDone", { fg = "#a6e3a1", bold = true })
  hl("AzureCliAged", { fg = "#6c7086" })
  hl("AzureCliUpdated", { fg = "#7f849c" })
  hl("AzureCliBuildOk", { fg = "#a6e3a1", bold = true })
  hl("AzureCliBuildFail", { fg = "#f38ba8", bold = true })
  hl("AzureCliBuildRun", { fg = "#f9e2af", bold = true })
  hl("AzureCliBuildExpired", { fg = "#fab387", bold = true })
  hl("AzureCliConflict", { fg = "#f38ba8", bold = true })
  hl("AzureCliAutoComplete", { fg = "#a6e3a1", bold = true })
  hl("AzureCliUnread", { fg = "#f38ba8", bold = true })
  hl("AzureCliMention", { fg = "#f5c2e7", bold = true })
  hl("AzureCliSyncing", { fg = "#89b4fa" })
  hl("AzureCliReady", { fg = "#6c7086" })
  hl("AzureCliBorder", { fg = "#585b70" })
  hl("AzureCliColHeader", { fg = "#6c7086", italic = true })
  hl("AzureCliMe", { fg = "#f5c2e7", bold = true })

  -- Work-items dashboard + detail view (workitems/{dashboard,view}.lua's
  -- UI.link_hl call - both define the same AzureCliWi* groups).
  hl("AzureCliWiHeader",      { fg = "#89b4fa", bold = true })
  hl("AzureCliWiId",          { fg = "#cba6f7" })
  hl("AzureCliWiActive",      { fg = "#a6e3a1", bold = true })
  hl("AzureCliWiNew",         { fg = "#89dceb" })
  hl("AzureCliWiImplemented", { fg = "#f9e2af" })
  hl("AzureCliWiResolved",    { fg = "#94e2d5" })
  hl("AzureCliWiClosed",      { fg = "#6c7086" })
  hl("AzureCliWiRemoved",     { fg = "#f38ba8" })
  hl("AzureCliWiOther",       { fg = "#bac2de" })
  hl("AzureCliWiDivider",     { fg = "#45475a" })
  hl("AzureCliWiTabActive",   { fg = "#1e1e2e", bg = "#89b4fa", bold = true })
  hl("AzureCliWiTabInactive", { fg = "#6c7086" })
  hl("AzureCliWiDate",        { fg = "#7f849c", italic = true })
  hl("AzureCliWiBorder",      { fg = "#585b70" })
  hl("AzureCliWiViewTitle",       { bold = true })
  hl("AzureCliWiViewLabel",       { fg = "#fab387" })

  -- Reviewer diff-pane decorations (lua/azure-cli/review/init.lua).
  hl("AzureCliDiffAddBg",   { bg = "#20302a" })
  hl("AzureCliDiffDelBg",   { bg = "#332329" })
  hl("AzureCliDiffAddSign", { fg = "#a6e3a1", bg = "#20302a", bold = true })
  hl("AzureCliDiffDelSign", { fg = "#f38ba8", bg = "#332329", bold = true })
  hl("AzureCliDiffAddWord", { bg = "#2d5940", bold = true })
  hl("AzureCliDiffDelWord", { bg = "#5a2d36", bold = true })
  hl("AzureCliPeekLine",     { bg = "#45475a" })
  hl("AzureCliPeekWord",     { bg = "#f9e2af", fg = "#1e1e2e", bold = true })
  hl("AzureCliComment",      { fg = "#e5c07b", bold = true })
  hl("AzureCliCommentNew",   { fg = "#f38ba8", bold = true })
  hl("AzureCliCommentResolved", { fg = "#6c7086" })
  hl("AzureCliInline",       { fg = "#a6adc8", italic = true })
  hl("AzureCliCommentRange", { bg = "#3a3a1f" })
  hl("AzureCliCurrentFile",  { bg = "#313244", bold = true })

  -- Reviewer file-list grouping (lua/azure-cli/review/filelist.lua).
  hl("AzureCliFileDir",     { fg = "#94e2d5" })
  hl("AzureCliFileAdded",   { fg = "#a6e3a1", bold = true })
  hl("AzureCliFileDeleted", { fg = "#f38ba8", bold = true })
  hl("AzureCliFileRenamed", { fg = "#f5c2e7", bold = true })
  hl("AzureCliFileViewed",  { fg = "#6c7086" })
end
apply_palette()

azure_cli.open_dashboard()
