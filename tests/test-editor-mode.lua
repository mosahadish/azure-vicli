-- test-editor-mode.lua: sending from the comment editor (<C-s> while
-- typing) leaves Neovim in normal mode in the window underneath - before,
-- insert mode carried over into a read-only plan or diff and the next key
-- failed with E21. Needs the main loop (real input events; nvim -l and
-- nvim_feedkeys(..., "x") both end insert mode by themselves), so:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-editor-mode.lua"
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
vim.cmd("enew")
local under = vim.api.nvim_get_current_win()
local submitted
require("azure-cli.editor").open({ title = "t", initial = "why?", anchor = "center",
  on_submit = function(text) submitted = text end })
local function finish(ok, why)
  io.stdout:write((ok and "EDITOR-MODE-OK" or ("EDITOR-MODE-FAIL: " .. why)) .. "\n")
  vim.cmd(ok and "qa!" or "cq!")
end
vim.defer_fn(function()
  if vim.api.nvim_get_mode().mode ~= "i" then return finish(false, "the editor didn't start in insert mode") end
  vim.api.nvim_input("<C-s>")
  vim.defer_fn(function()
    local mode = vim.api.nvim_get_mode().mode
    if submitted ~= "why?" then return finish(false, "nothing was submitted") end
    if vim.api.nvim_get_current_win() ~= under then return finish(false, "the focus didn't come back") end
    finish(mode == "n", "left in mode " .. mode)
  end, 200)
end, 200)
