-- lua/azure-cli/palette.lua: azure-vicli's own colours - a dark palette
-- for every AzureCli* group (the standalone launcher always uses it, since
-- it runs without a colorscheme). Everywhere else the groups link to your
-- colorscheme's (default = true, see ui.lua's link_hl), unless
-- setup({ ui = { palette = "azure-vicli" } }) asks for these instead.
--
-- Set explicitly (no `default`), so they win over the surfaces' own
-- default links whenever they're applied - before or after those.
--
--   M.GROUPS   { { name, spec } } - azure-vicli's groups
--   M.CHROME   the same for the tab line and status lines (the standalone
--              launcher's only: in your own Neovim they're yours)
--   M.apply(opts)  sets M.GROUPS (and M.CHROME with opts.chrome); with
--              opts.follow, again after every :colorscheme (which clears them)
local M = {}

M.GROUPS = {
  -- Dashboard (lua/azure-cli/dashboard.lua's UI.link_hl call).
  { "AzureCliHeader", { fg = "#89b4fa", bold = true } },
  { "AzureCliId", { fg = "#cba6f7" } },
  { "AzureCliRepo", { fg = "#94e2d5" } },
  { "AzureCliAuthor", { fg = "#bac2de" } },
  { "AzureCliVote", { fg = "#89dceb" } },
  { "AzureCliThread", { fg = "#f9e2af", bold = true } },
  { "AzureCliThreadDone", { fg = "#a6e3a1", bold = true } },
  { "AzureCliAged", { fg = "#6c7086" } },
  { "AzureCliUpdated", { fg = "#7f849c" } },
  { "AzureCliBuildOk", { fg = "#a6e3a1", bold = true } },
  { "AzureCliBuildFail", { fg = "#f38ba8", bold = true } },
  { "AzureCliBuildRun", { fg = "#f9e2af", bold = true } },
  { "AzureCliBuildExpired", { fg = "#fab387", bold = true } },
  { "AzureCliConflict", { fg = "#f38ba8", bold = true } },
  { "AzureCliAutoComplete", { fg = "#a6e3a1", bold = true } },
  { "AzureCliUnread", { fg = "#f38ba8", bold = true } },
  { "AzureCliMention", { fg = "#f5c2e7", bold = true } },
  { "AzureCliSyncing", { fg = "#89b4fa" } },
  { "AzureCliReady", { fg = "#6c7086" } },
  { "AzureCliBorder", { fg = "#585b70" } },
  { "AzureCliColHeader", { fg = "#6c7086", italic = true } },
  { "AzureCliMe", { fg = "#f5c2e7", bold = true } },

  -- Work-items dashboard + detail view (workitems/{dashboard,view}.lua's
  -- UI.link_hl call - both define the same AzureCliWi* groups).
  { "AzureCliWiHeader", { fg = "#89b4fa", bold = true } },
  { "AzureCliWiId", { fg = "#cba6f7" } },
  { "AzureCliWiActive", { fg = "#a6e3a1", bold = true } },
  { "AzureCliWiNew", { fg = "#89dceb" } },
  { "AzureCliWiImplemented", { fg = "#f9e2af" } },
  { "AzureCliWiResolved", { fg = "#94e2d5" } },
  { "AzureCliWiClosed", { fg = "#6c7086" } },
  { "AzureCliWiRemoved", { fg = "#f38ba8" } },
  { "AzureCliWiOther", { fg = "#bac2de" } },
  { "AzureCliWiDivider", { fg = "#45475a" } },
  { "AzureCliWiTabActive", { fg = "#1e1e2e", bg = "#89b4fa", bold = true } },
  { "AzureCliWiTabInactive", { fg = "#6c7086" } },
  { "AzureCliWiDate", { fg = "#7f849c", italic = true } },
  { "AzureCliWiBorder", { fg = "#585b70" } },
  { "AzureCliWiViewTitle", { bold = true } },
  { "AzureCliWiViewLabel", { fg = "#fab387" } },

  -- Chat panel (lua/azure-cli/chat/init.lua): foreground only, so the
  -- panel keeps the window's own background.
  { "AzureCliChatYou", { fg = "#89b4fa", bold = true } },
  { "AzureCliChatYouText", { fg = "#89b4fa" } },
  { "AzureCliChatAgent", { fg = "#a6e3a1", bold = true } },
  { "AzureCliChatMeta", { fg = "#7f849c", italic = true } },
  { "AzureCliChatToolRead", { fg = "#6c7086" } },
  { "AzureCliChatToolWrite", { fg = "#f9e2af" } },
  { "AzureCliChatToolErr", { fg = "#f38ba8" } },
  { "AzureCliChatNote", { fg = "#89dceb" } },
  -- The shared look (ui.lua's M.THEME): winbars, floats, the plan, the
  -- questions under a line.
  { "AzureCliWinbar", { fg = "#bac2de" } },
  { "AzureCliWinbarTitle", { fg = "#89b4fa", bold = true } },
  { "AzureCliWinbarSep", { fg = "#585b70" } },
  { "AzureCliWinbarTag", { fg = "#f9e2af" } },
  { "AzureCliWinbarHelp", { fg = "#6c7086", italic = true } },
  { "AzureCliFloatBorder", { fg = "#585b70" } },
  { "AzureCliFloatTitle", { fg = "#89b4fa", bold = true } },
  { "AzureCliFloatFooter", { fg = "#6c7086", italic = true } },
  { "AzureCliSection", { fg = "#89b4fa", bold = true } },
  { "AzureCliMuted", { fg = "#6c7086" } },
  { "AzureCliAccent", { fg = "#f9e2af", bold = true } },
  { "AzureCliKeyHint", { fg = "#94e2d5", bold = true } },
  { "AzureCliStatusDraft", { fg = "#f9e2af", bold = true } },
  { "AzureCliStatusOk", { fg = "#a6e3a1", bold = true } },
  { "AzureCliStatusBad", { fg = "#f38ba8", bold = true } },
  { "AzureCliStatusDone", { fg = "#6c7086", bold = true } },
  { "AzureCliThreadBar", { fg = "#94e2d5" } },
  { "AzureCliThreadQuestion", { fg = "#89b4fa", bold = true } },
  { "AzureCliThreadAnswer", { fg = "#cdd6f4" } },
  { "AzureCliThreadMeta", { fg = "#6c7086", italic = true } },
  { "AzureCliThreadRequest", { fg = "#fab387" } },
  { "AzureCliPlanChanged", { fg = "#94e2d5" } },
  { "AzureCliPlanRemoved", { fg = "#6c7086", strikethrough = true } },

  -- Reviewer diff-pane decorations (lua/azure-cli/review/init.lua).
  { "AzureCliDiffAddBg", { bg = "#20302a" } },
  { "AzureCliDiffDelBg", { bg = "#332329" } },
  { "AzureCliDiffAddSign", { fg = "#a6e3a1", bg = "#20302a", bold = true } },
  { "AzureCliDiffDelSign", { fg = "#f38ba8", bg = "#332329", bold = true } },
  { "AzureCliDiffAddWord", { bg = "#2d5940", bold = true } },
  { "AzureCliDiffDelWord", { bg = "#5a2d36", bold = true } },
  { "AzureCliPeekLine", { bg = "#45475a" } },
  { "AzureCliPeekWord", { bg = "#f9e2af", fg = "#1e1e2e", bold = true } },
  { "AzureCliComment", { fg = "#e5c07b", bold = true } },
  { "AzureCliCommentNew", { fg = "#f38ba8", bold = true } },
  { "AzureCliCommentResolved", { fg = "#6c7086" } },
  { "AzureCliInline", { fg = "#a6adc8", italic = true } },
  { "AzureCliCommentRange", { bg = "#3a3a1f" } },
  { "AzureCliCurrentFile", { bg = "#313244", bold = true } },

  -- Reviewer file-list grouping (lua/azure-cli/review/filelist.lua).
  { "AzureCliFileDir", { fg = "#94e2d5" } },
  { "AzureCliFileAdded", { fg = "#a6e3a1", bold = true } },
  { "AzureCliFileDeleted", { fg = "#f38ba8", bold = true } },
  { "AzureCliFileRenamed", { fg = "#f5c2e7", bold = true } },
  { "AzureCliFileViewed", { fg = "#6c7086" } },
}

M.CHROME = {
  { "TabLineSel", { fg = "#1e1e2e", bg = "#89b4fa", bold = true } },
  { "TabLine", { fg = "#a6adc8", bg = "#313244" } },
  { "TabLineFill", { bg = "#181825" } },
  { "StatusLine", { fg = "#bac2de", bg = "#313244" } },
  { "StatusLineNC", { fg = "#6c7086", bg = "#1e1e2e" } },
}

local followed = false
function M.apply(opts)
  opts = opts or {}
  local function set()
    for _, g in ipairs(M.GROUPS) do vim.api.nvim_set_hl(0, g[1], g[2]) end
    if opts.chrome then
      for _, g in ipairs(M.CHROME) do vim.api.nvim_set_hl(0, g[1], g[2]) end
    end
  end
  set()
  if opts.follow and not followed then
    followed = true
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("AzureCliPalette", { clear = true }),
      callback = set,
    })
  end
end

return M
