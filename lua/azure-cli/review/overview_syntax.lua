-- lua/azure-cli/review/overview_syntax.lua: the reviewer Overview's
-- highlighting (#135). Only the description and the comment bodies are
-- Markdown; the header (title, branches, author, reviewers), the commits
-- list and the thread headers are plain text. It used to be
-- filetype=markdown on the whole buffer, so every intraword `_` in a branch
-- name or commit subject (tg/remote_HW_stubs, DUNE_HardwareLink) was a red
-- markdownError.
--
-- Vim's own syntax/markdown.vim is pulled in as a contained cluster (so the
-- description looks exactly as it did) and only used inside two regions:
--   - the description: from "Description:" to the next unindented line -
--     build_overview prefixes every description line with two spaces, so
--     nothing inside it can end the region early;
--   - each comment content line ("│   ..."), which only ever got inline
--     Markdown since its "│" sits where a heading or list marker would.
-- markdownError is cleared in this buffer only (syntax is buffer-local), so
-- the user's own highlights stay as they are. Regex syntax rather than
-- treesitter ranges: it behaves the same on Neovim 0.9 and 0.12 and needs
-- no parser installed.
local M = {}

M.FILETYPE = "azurecli-overview"

-- Defines the Overview's syntax in `buf`. Called from the buffer's Syntax
-- autocmd (see M.attach), so it follows 'syntax' being (re)set - and does
-- nothing while syntax highlighting is off, like any other filetype.
function M.apply(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("syntax clear")
    vim.cmd("unlet! b:current_syntax")
    vim.cmd("syntax include @azOverviewMd syntax/markdown.vim")
    vim.cmd("unlet! b:current_syntax")
    vim.cmd("syntax clear markdownError")
    vim.cmd([[syntax region azOverviewDesc matchgroup=azOverviewLabel start="^Description:$" end="^\ze\S" keepend contains=@azOverviewMd]])
    vim.cmd([[syntax region azOverviewBody start="^│   " end="$" oneline keepend contains=@azOverviewMd]])
    vim.cmd("syntax sync fromstart")
    vim.b.current_syntax = M.FILETYPE
  end)
end

-- Gives the Overview buffer its filetype and keeps its syntax applied.
function M.attach(buf)
  vim.api.nvim_create_autocmd("Syntax", {
    buffer = buf,
    callback = function(ev)
      if ev.match == M.FILETYPE then M.apply(buf) end
    end,
  })
  vim.bo[buf].filetype = M.FILETYPE
end

return M
