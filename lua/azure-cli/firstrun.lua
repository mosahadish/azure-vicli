-- lua/azure-cli/firstrun.lua: the first launch with no azure-cli.yml.
--
-- Neither the standalone launcher nor a plugin install has a setup step
-- (install.sh only checks dependencies): the first `./azure-cli` or
-- `:AzureCli` is what creates the config file. M.ensure(reopen) is called
-- by init.lua's open_dashboard()/open_workitems() before they build their
-- buffer:
--
--   config file exists  -> returns true, the caller carries on.
--   missing             -> asks the provider to write its template there
--                          (`azure-cli.py --init-config`, the one place the
--                          template text lives), opens that file for
--                          editing - current window in standalone mode,
--                          a new tab in plugin mode, cursor on the first
--                          TODO - and returns false so the caller opens
--                          nothing else. Saving the file once runs `reopen`
--                          (the caller itself), so filling in the TODOs and
--                          :w lands straight on the dashboard, no relaunch.
--
-- The template is written by python rather than here so `azure-cli
-- --init-config` from a terminal, --doctor's hint and this all agree on
-- one text; if python isn't runnable yet the file is opened empty with a
-- message saying so, which still beats an error screen.
local M = {}

function M.ensure(reopen)
  local CONFIG = require("azure-cli.config")
  local path = CONFIG.config_path()
  if vim.fn.filereadable(path) == 1 then return true end

  local argv = CONFIG.provider_cmd()
  argv[#argv + 1] = "--init-config"
  local out = vim.fn.system(argv)
  local written = vim.v.shell_error == 0 and vim.fn.filereadable(path) == 1

  if require("azure-cli").is_standalone() then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  else
    vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  end
  vim.bo.filetype = "yaml"
  local buf = vim.api.nvim_get_current_buf()
  if written then
    vim.fn.search("TODO", "w")
    vim.notify("azure-cli: first run - wrote a config template to " .. path
      .. ". Fill in the TODO lines (org_url, project_name, pat) and save: the dashboard opens when you do.",
      vim.log.levels.INFO)
  else
    vim.notify("azure-cli: no config file at " .. path .. " and the provider couldn't write a template ("
      .. vim.trim(out or "") .. "). Is python 3 on PATH? See docs/configuration.md for the fields; "
      .. "save this buffer to create the file.", vim.log.levels.WARN)
  end

  if type(reopen) == "function" then
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = buf, once = true,
      desc = "azure-cli: open the dashboard after the config's first save",
      callback = function() vim.schedule(reopen) end,
    })
  end
  return false
end

return M
