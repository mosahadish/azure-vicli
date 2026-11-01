-- test-editor-mode.lua: <C-j> while typing in the comment editor breaks
-- the line; sending (<CR> while typing) leaves Neovim in normal mode in the window underneath - before,
-- insert mode carried over into a read-only plan or diff and the next key
-- failed with E21. Then opts.allow_empty: an emptied buffer's <CR> submits
-- "" with it (an issue's description being cleared), and cancels without
-- it (a comment). Needs the main loop (real input events; nvim -l and
-- nvim_feedkeys(..., "x") both end insert mode by themselves), so:
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-editor-mode.lua"
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
local EDITOR = require("azure-cli.editor")
vim.cmd("enew")
local under = vim.api.nvim_get_current_win()
local submitted, cancelled
EDITOR.open({ title = "t", initial = "why?", anchor = "center",
  on_submit = function(text) submitted = text end })
local function finish(ok, why)
  io.stdout:write((ok and "EDITOR-MODE-OK" or ("EDITOR-MODE-FAIL: " .. why)) .. "\n")
  vim.cmd(ok and "qa!" or "cq!")
end

-- Opens an editor prefilled with "old", empties it and sends it; then(sub, can).
local function send_emptied(allow_empty, after)
  submitted, cancelled = nil, false
  EDITOR.open({ title = "t", initial = "old", anchor = "center", allow_empty = allow_empty,
    on_submit = function(text) submitted = text end, on_cancel = function() cancelled = true end })
  vim.defer_fn(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
    vim.api.nvim_input("<CR>")
    vim.defer_fn(function() after(submitted, cancelled) end, 200)
  end, 200)
end

vim.defer_fn(function()
  if vim.api.nvim_get_mode().mode ~= "i" then return finish(false, "the editor didn't start in insert mode") end
  vim.api.nvim_input("<C-j>x")
  vim.defer_fn(function()
  if submitted then return finish(false, "<C-j> sent it") end
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "why?", "x" }) then
    return finish(false, "<C-j> gave " .. vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
  end
  vim.api.nvim_input("<CR>")
  vim.defer_fn(function()
    local mode = vim.api.nvim_get_mode().mode
    if submitted ~= "why?\nx" then return finish(false, "<CR> submitted " .. vim.inspect(submitted)) end
    if vim.api.nvim_get_current_win() ~= under then return finish(false, "the focus didn't come back") end
    if mode ~= "n" then return finish(false, "left in mode " .. mode) end
    send_emptied(true, function(sub, can)
      if sub ~= "" or can then
        return finish(false, "allow_empty: an emptied buffer should submit \"\", got " .. vim.inspect(sub))
      end
      send_emptied(nil, function(sub2, can2)
        if sub2 ~= nil or not can2 then
          return finish(false, "without allow_empty an emptied buffer should cancel, got " .. vim.inspect(sub2))
        end
        finish(true)
      end)
    end)
  end, 200)
  end, 200)
end, 200)
