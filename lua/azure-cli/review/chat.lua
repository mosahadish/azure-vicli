-- lua/azure-cli/review/chat.lua: the chat panel in the reviewer - a
-- reviewer-feature module (see docs/development.md, "Extending the
-- reviewer"). gq shows/hides the panel (lua/azure-cli/chat/) from the file
-- list, the diff pane, the Overview and the revision buffers, and this
-- registers what the chat is told the reviewer shows: the PR, and the file,
-- line, code and comment thread under the cursor (chat/view.lua).
local M = {}

-- A thread (review/init.lua's parse_threads shape) as the chat sees it.
function M.thread(t)
  local comments = {}
  for _, c in ipairs(t.comments or {}) do
    comments[#comments + 1] = { author = c.author, content = c.content }
  end
  return { id = t.id, status = t.status, file = t.path, side = t.side, line = t.lineno, comments = comments }
end

local function setup(ctx)
  local ID = tostring(ctx.ID)
  for _, kind in ipairs({ "list", "diff", "overview", "nav" }) do
    ctx.add_key(kind, "chat", function() require("azure-cli.chat").toggle() end, "show/hide the chat panel")
  end
  require("azure-cli.chat.view").register("review:" .. ID, function(win)
    local buf = vim.api.nvim_win_get_buf(win)
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local pr = { id = tonumber(ID) or ID, source = ctx.SOURCE, target = ctx.TARGET }
    local rec = ctx.current_pr_record()
    if rec and tostring(rec.id) == ID then pr.title, pr.repo, pr.author = rec.title, rec.repo, rec.author end
    local snap = { screen = "reviewer", pr = pr }
    local path = ctx.paths_by_buf[buf]
    if path then
      snap.screen = "reviewer: a file's diff"
      snap.file = path
      local m = (ctx.maps_by_buf[buf] or {})[lnum]
      if m and m.lineno then snap.side, snap.line = m.side, m.lineno end
      snap.code_line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    elseif buf == ctx.overview_buf() then
      snap.screen = "reviewer: Overview (description, commits, PR-level comments)"
    elseif vim.bo[buf].filetype == "azurecli-files" then
      snap.screen = "reviewer: file list"
      local f = ctx.ext.filelist and ctx.ext.filelist.row_to_file[lnum - 1]
      if f then snap.file = f end
    end
    local threads = (ctx.comments_by_buf[buf] or {})[lnum]
    if threads and threads[1] and type(threads[1].id) == "number" then
      snap.thread = M.thread(threads[1])
      if #threads > 1 then snap.note = #threads .. " threads are on this line; get_pr_threads lists them all." end
    end
    return snap
  end)
  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
