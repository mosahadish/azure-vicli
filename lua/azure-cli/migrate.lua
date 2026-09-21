-- lua/azure-cli/migrate.lua: one-time data-file migration for the names
-- this plugin's persisted files ("seen" snapshots, thread read counts,
-- comment filters - see README's Environment variables section) used
-- before this plugin was renamed from pr-dash.
--
-- M.ensure(old_path, new_path) copies old_path's content into new_path
-- verbatim the first time new_path doesn't exist yet but old_path does, so
-- nobody loses saved state across the rename, then leaves old_path alone
-- forever after (a no-op once new_path exists, or when neither file does).
local M = {}

function M.ensure(old_path, new_path)
  if vim.fn.filereadable(new_path) == 1 then return end
  if vim.fn.filereadable(old_path) ~= 1 then return end
  local ok, lines = pcall(vim.fn.readfile, old_path)
  if ok then pcall(vim.fn.writefile, lines, new_path) end
end

return M
