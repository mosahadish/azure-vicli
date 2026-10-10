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
-- Tabs and status lines named after the screens, not "[Scratch]".
vim.o.showtabline = 2
vim.o.tabline = "%!v:lua.require'azure-cli.ui'.tabline()"
vim.o.statusline = "%!v:lua.require'azure-cli.ui'.statusline()"
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

-- Standalone's colour palette (lua/azure-cli/palette.lua): there's no
-- colorscheme here to inherit (`nvim -u` skips it), so azure-vicli's own -
-- set explicitly, so it wins over every surface's default links - plus the
-- tab line and status lines.
require("azure-cli.palette").apply({ chrome = true })

azure_cli.open_dashboard()
