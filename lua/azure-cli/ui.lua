-- lua/azure-cli/ui.lua: shared winbar formatting and column-layout helpers.
--
-- Every winbar in this plugin used to spell out its own "(key: hint  key:
-- hint  ...)" chip list, which overflowed a normal terminal width once a
-- surface grew past a dozen actions. UI.winbar replaces that with a fixed
-- shape - what you're looking at, active mode tags, then a single "?: help"
-- pointer to the `?` popup (which still lists every key) - built in one
-- place so every dashboard/reviewer/work-items winbar builder produces the
-- same shape instead of hand-rolling it. UI.layout is the pure column-width
-- solver the PR dashboard's table uses to scale its columns to the window
-- instead of the fixed widths it used to hard-code.
--
-- Both functions are pure (no vim.* calls at all), so tests/test-ui.lua
-- exercises them directly under plain luajit, the same way review/*.lua's
-- pure helpers are tested.
local M = {}

-- Makes `win` a plain list/diff window: no line numbers, no sign column,
-- no wrapping - set on the window (vim.wo), never on vim.o, so nothing the
-- user configured globally is touched. `opts.number`/`opts.cursorline`
-- turn those two back on for a window that wants them (the diff pane, a
-- list with a highlighted row).
function M.plain_window(win, opts)
  opts = opts or {}
  M.wo(win, "number", opts.number and true or false)
  M.wo(win, "relativenumber", false)
  M.wo(win, "signcolumn", "no")
  M.wo(win, "wrap", false)
  M.wo(win, "cursorline", opts.cursorline and true or false)
  M.wo(win, "foldenable", false)
  -- No "~" below the last line: the screens end where their text does.
  M.wo(win, "fillchars", "eob: ")
  M.theme()
end

-- Row numbers inside the dashboards' boxes (setup({row_numbers=...})).
-- A dashboard reserves a blank column M.number_width() cells wide just
-- inside the box's left border, and M.paint_numbers() overlays each boxed
-- line's number there: its distance from the cursor by default, so 5j/5k
-- lands on the row marked 5 (the cursor row shows its own line number,
-- like 'number' + 'relativenumber'), or the plain line number with
-- "absolute". Relative numbers repaint on every cursor move.
local painted = {}  -- buf -> { first, last, col, width } (0-based lines, byte col)

-- The reserved column's width for a buffer whose lines run up to
-- `max_line`: its digits plus a space, at least 4; 0 when row_numbers is
-- false (no column at all).
function M.number_width(max_line)
  if require("azure-cli.config").get().row_numbers == false then return 0 end
  return math.max(3, #tostring(max_line)) + 1
end

-- The number text for 0-based line `l` with the cursor on 0-based `cur`,
-- `width` cells wide (the last one a space).
function M.number_text(l, cur, width, relative)
  local digits = width - 1
  if not relative then return string.format("%" .. digits .. "d ", l + 1) end
  if l == cur then return string.format("%-" .. digits .. "d ", l + 1) end
  return string.format("%" .. digits .. "d ", math.abs(l - cur))
end

local function draw_numbers(buf)
  local p = painted[buf]
  if not p or not vim.api.nvim_buf_is_valid(buf) then return end
  local ns = vim.api.nvim_create_namespace("azure_cli_row_numbers")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if p.width == 0 then return end
  local win = vim.fn.bufwinid(buf)
  local cur = (win ~= -1) and (vim.api.nvim_win_get_cursor(win)[1] - 1) or -1
  local relative = require("azure-cli.config").get().row_numbers ~= "absolute"
  for l = p.first, p.last do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, l, p.col, {
      virt_text = { { M.number_text(l, cur, p.width, relative), l == cur and "CursorLineNr" or "LineNr" } },
      virt_text_pos = "overlay",
    })
  end
end

-- Number the boxed lines `first`..`last` (0-based) of `buf` in the
-- `width`-cell column at byte `col`; call again after every render (the
-- lines and column move with the window size). Keeps them in step with
-- the cursor from then on.
function M.paint_numbers(buf, first, last, col, width)
  if not painted[buf] then
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufWipeout" }, {
      buffer = buf,
      callback = function(ev)
        if ev.event == "BufWipeout" then
          painted[buf] = nil
          return true
        end
        draw_numbers(buf)
      end,
    })
  end
  painted[buf] = { first = first, last = last, col = col, width = width }
  draw_numbers(buf)
end

-- `win`'s text width: its width less the number/sign/fold gutter, which
-- is what a centred layout has to fit into.
function M.text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return vim.api.nvim_win_get_width(win) - ((info and info.textoff) or 0)
end

-- A popup picker, like gW's: `opts.items` ({label, ...}) one per line in
-- a float with the cursor line highlighted; <CR> closes it and calls
-- cb(item) with the one under the cursor, q/<Esc> just close it.
-- opts.title, opts.action (the footer's "<CR> <action>", default "pick"),
-- opts.center (mid-screen instead of at the cursor). "#123"/"!123" ids and
-- "[State]" tokens are coloured.
function M.pick_popup(opts, cb)
  local items = opts.items or {}
  local lines = {}
  for i, it in ipairs(items) do lines[i] = "  " .. tostring(it.label or "") end
  local win, buf = M.open_float(lines, {
    title = opts.title, footer = "<CR> " .. (opts.action or "pick"), min_width = 50, center = opts.center,
  })
  if not win then return end
  M.wo(win, "cursorline", true)
  M.wo(win, "wrap", false)
  local ns = vim.api.nvim_create_namespace("azure_cli_pick_popup")
  for i, l in ipairs(lines) do
    local s, e = l:find("[#!]%d+")
    if s then vim.api.nvim_buf_add_highlight(buf, ns, "Identifier", i - 1, s - 1, e) end
    local bs, be = l:find("%[.-%]")
    if bs then vim.api.nvim_buf_add_highlight(buf, ns, "Special", i - 1, bs - 1, be) end
  end
  vim.keymap.set("n", "<CR>", function()
    local it = items[vim.api.nvim_win_get_cursor(win)[1]]
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if it then cb(it) end
  end, { buffer = buf, silent = true, nowait = true })
end

-- Define highlight groups as links to existing ones, all with
-- { default = true } so a user's colorscheme or their own :highlight always
-- wins. `map` is { AzureCliThing = "LinkTarget", ... }. Both dashboards
-- carried the same nvim_set_hl/tbl_extend one-liner and their own loop over
-- it; only the group tables actually differ.
function M.link_hl(map)
  for name, target in pairs(map) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
end

-- The shared look: the groups every screen's chrome is drawn with - the
-- winbars (M.winbar), the floats (M.open_float and the other popups, via
-- M.border/M.float_hl), section headings, the plan window and the inline
-- question threads (chat/plan.lua, chat/threads.lua). Linked to standard
-- groups (default = true, like everything else here), so any colorscheme
-- gives a consistent result; the standalone launcher sets its own palette.
M.THEME = {
  AzureCliWinbar = "WinBar", AzureCliWinbarTitle = "Title", AzureCliWinbarSep = "NonText",
  AzureCliWinbarTag = "Special", AzureCliWinbarHelp = "Comment",
  AzureCliFloat = "NormalFloat", AzureCliFloatBorder = "FloatBorder", AzureCliFloatTitle = "FloatTitle",
  AzureCliFloatFooter = "Comment",
  AzureCliSection = "Title", AzureCliMuted = "Comment", AzureCliAccent = "Special",
  AzureCliKeyHint = "Special",
  AzureCliStatusDraft = "DiagnosticWarn", AzureCliStatusOk = "DiagnosticOk", AzureCliStatusBad = "DiagnosticError",
  AzureCliStatusDone = "Comment",
  AzureCliThreadBar = "Special", AzureCliThreadQuestion = "Function", AzureCliThreadAnswer = "Normal",
  AzureCliThreadMeta = "Comment", AzureCliThreadRequest = "DiagnosticWarn",
  AzureCliPlanChanged = "DiagnosticHint", AzureCliPlanRemoved = "Comment",
  AzureCliButton = "Pmenu", AzureCliButtonActive = "PmenuSel",
}

local themed = false
-- Defines M.THEME's groups (once; again after every :colorscheme, which
-- clears them).
function M.theme()
  if themed then return end
  themed = true
  M.link_hl(M.THEME)
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("AzureCliTheme", { clear = true }),
    callback = function() M.link_hl(M.THEME) end,
  })
end

-- What a window of azure-vicli's is, in a few words: its buffer's
-- vim.b.azure_cli_title (set by the screens that know better), else by
-- filetype, else the buffer's own name. nil for a buffer that isn't ours.
local FT_TITLE = {
  ["azurecli-dashboard"] = "Pull requests", ["azurecli-workitems"] = "Work items",
  ["azurecli-workitem"] = "Work item", ["azurecli-issues"] = "Issues", ["azurecli-issue"] = "Issue", ["azurecli-changes"] = "Change", ["azurecli-plan"] = "Plan",
  ["azurecli-agents"] = "Agents",
}
function M.buf_title(buf)
  local t = vim.b[buf].azure_cli_title
  if t and t ~= "" then return t end
  local ft = vim.bo[buf].filetype
  if ft == "azurecli-files" and vim.b[buf].azure_cli_pr then
    return "PR " .. (vim.b[buf].azure_cli_pr_ref or ("!" .. tostring(vim.b[buf].azure_cli_pr)))
  end
  if vim.b[buf].azure_cli_chat then return "Chat" end
  return FT_TITLE[ft]
end

-- A tab's label: the tab's vim.t.azure_cli_title, else the title of the
-- first of our windows in it, else its current buffer's file name.
function M.tab_title(tab)
  local ok, t = pcall(vim.api.nvim_tabpage_get_var, tab, "azure_cli_title")
  if ok and t and t ~= "" then return t end
  local chat
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local title = M.buf_title(vim.api.nvim_win_get_buf(w))
      if title == "Chat" then chat = title elseif title then return title end
    end
  end
  if chat then return chat end
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab)))
  return name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
end

-- 'tabline': every tab by its title (the standalone launcher sets it;
-- plugin users can: vim.o.tabline = "%!v:lua.require'azure-cli.ui'.tabline()").
-- A home tab's inner tabs (lua/azure-cli/innertabs.lua) aren't listed: the
-- home is, selected while you're in one of them.
function M.tabline()
  M.theme()
  local INNER = require("azure-cli.innertabs")
  local cur = vim.api.nvim_get_current_tabpage()
  local cur_home = INNER.is_member(cur) and INNER.home_of(cur) or cur
  local out = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not INNER.is_member(tab) then
      local hl = tab == cur_home and "%#TabLineSel#" or "%#TabLine#"
      out[#out + 1] = hl .. "%" .. i .. "T " .. (M.tab_title(tab):gsub("%%", "%%%%")) .. " "
    end
  end
  -- The chat's status strip on the right: the agent working, a question
  -- waiting for you, plans waiting for your review.
  local ok, strip = pcall(function() return require("azure-cli.chat").strip() end)
  local right = (ok and strip ~= "") and ("%=%#AzureCliWinbarTag# " .. strip:gsub("%%", "%%%%") .. " ") or ""
  return table.concat(out) .. "%#TabLineFill#%T" .. right
end

-- 'statusline' for the standalone launcher: what the window is, and where
-- the cursor is - not "[Scratch] [-]".
function M.statusline()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(win) then buf = vim.api.nvim_win_get_buf(win) end
  local title = M.buf_title(buf)
  if not title and vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == "nofile" then
    -- One of our unnamed panes (a diff, a revision): what its tab is.
    title = M.tab_title(vim.api.nvim_win_get_tabpage(win))
  end
  if not title then
    local name = vim.api.nvim_buf_get_name(buf)
    title = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
    if vim.bo[buf].modified then title = title .. " [+]" end
  end
  return " " .. title:gsub("%%", "%%%%") .. "%=%l/%L "
end

-- The border every float uses: setup({ ui = { border = ... } }), "rounded"
-- by default (any 'winborder' value: "single", "double", "solid",
-- "shadow", "none", or a list of eight characters).
function M.border()
  local ok, cfg = pcall(function() return require("azure-cli.config").get() end)
  local b = ok and cfg and cfg.ui and cfg.ui.border
  return b or "rounded"
end

-- The 'winhighlight' a float gets so its body, border, title and footer
-- use the theme's groups.
M.FLOAT_HL = "NormalFloat:AzureCliFloat,FloatBorder:AzureCliFloatBorder,FloatTitle:AzureCliFloatTitle,"
  .. "FloatFooter:AzureCliFloatFooter"
function M.float_hl(win)
  M.theme()
  pcall(M.wo, win, "winhighlight", M.FLOAT_HL)
end

-- The shared "big float" size: roughly 70% of the columns and 65% of the
-- lines, floored so a small window still gets something usable and capped
-- so a very wide one doesn't produce an unreadable measure. Used by
-- open_float's opts.big below and by the reviewer, which had its own copy
-- of these four magic numbers.
function M.big_dims()
  local width = math.min(math.max(70, math.floor(vim.o.columns * 0.7)), 110)
  local height = math.min(math.max(18, math.floor(vim.o.lines * 0.65)), 34)
  return width, height
end

-- The plugin's one floating-window builder for read-only text (help
-- popups, descriptions, comment threads, pickers' hosts): every surface
-- used to carry its own copy with slightly different caps and none of
-- them said how to close or that there was more below the fold.
--
--   lines           the text
--   opts.focus      false keeps the cursor where it is (default: focus it)
--   opts.big        the shared large centred size (comment threads)
--   opts.center     sized to fit like the default, but centred on the
--                   screen instead of opening at the cursor
--   opts.title      border title
--   opts.min_width / opts.min_height
--   opts.footer     extra footer text; the close hint (and a scroll hint
--                   when the text doesn't fit) is always appended
--   opts.on_close   called once when the window goes away
--
-- Height is capped by the screen, not a constant, and a cursor-anchored
-- float that wouldn't fit below the cursor opens above it instead of
-- being clipped. q / <Esc> close a focused float. Returns win, buf.
-- The float `win` (M.open_float's, centred or not) grown or shrunk to its
-- buffer's lines now - after they changed under it (a reply added to a
-- comment thread) - within the screen, a centred one kept centred.
function M.refit_float(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local cfg = vim.api.nvim_win_get_config(win)
  local width = cfg.width
  local rows = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) do
    local w = vim.fn.strdisplaywidth(l)
    rows = rows + (w <= width and 1 or 1 + math.ceil((w - width) / math.max(1, width - 4)))
  end
  local height = math.min(math.max(rows, 1), math.max(5, vim.o.lines - 4))
  if height == cfg.height then return end
  local new = { height = height }
  if cfg.relative == "editor" then
    new.relative, new.col = "editor", cfg.col
    new.row = math.floor((vim.o.lines - height) / 2)
  end
  pcall(vim.api.nvim_win_set_config, win, new)
end

function M.open_float(lines, opts)
  if not lines or #lines == 0 then return nil end
  opts = opts or {}
  local focus = opts.focus ~= false
  local screen_h = vim.o.lines - 4
  local width, height
  if opts.big then
    width, height = M.big_dims()
  else
    width = opts.min_width or 20
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.min(width, math.max(20, vim.o.columns - 6), 110)
  end
  -- The screen rows the lines take once wrapped (a continuation row can
  -- be up to 4 cells narrower, with breakindent), so a long one isn't cut.
  local rows = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    rows = rows + (w <= width and 1 or 1 + math.ceil((w - width) / math.max(1, width - 4)))
  end
  if not opts.big then
    height = math.min(math.max(rows, opts.min_height or 1), math.max(5, screen_h))
  end
  local scrolls = rows > height

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"

  local cfg = { width = width, height = height, style = "minimal", border = M.border() }
  if opts.big or opts.center then
    cfg.relative = "editor"
    cfg.row = math.floor((vim.o.lines - height) / 2)
    cfg.col = math.floor((vim.o.columns - width) / 2)
  else
    cfg.relative = "cursor"
    cfg.col = 0
    -- Flip above the cursor when the float wouldn't fit below it.
    local cur_row = vim.fn.screenrow()
    local room_below = vim.o.lines - cur_row - 3
    if height + 2 > room_below and cur_row - 2 > room_below then
      cfg.row = 0
      cfg.anchor = "SW"
    else
      cfg.row = 1
      cfg.anchor = "NW"
    end
  end
  if opts.title then
    cfg.title = " " .. opts.title .. " "
    cfg.title_pos = "left"
  end
  local hints = {}
  if opts.footer and opts.footer ~= "" then hints[#hints + 1] = opts.footer end
  if scrolls then hints[#hints + 1] = "\u{2193} j/k scroll" end
  if focus then hints[#hints + 1] = "q closes" end
  if #hints > 0 then
    cfg.footer = " " .. table.concat(hints, " \u{00B7} ") .. " "
    cfg.footer_pos = "right"
  end

  local ok, win = pcall(vim.api.nvim_open_win, buf, focus, cfg)
  if not ok then
    -- Older Neovim without border title/footer support.
    cfg.title, cfg.title_pos, cfg.footer, cfg.footer_pos = nil, nil, nil, nil
    win = vim.api.nvim_open_win(buf, focus, cfg)
  end
  M.wo(win, "wrap", true)
  M.wo(win, "linebreak", true)
  M.wo(win, "breakindent", true)
  -- A help line ("  key   what it does", "↑ key ...") that wraps continues
  -- under its description, not under the key.
  vim.bo[buf].formatlistpat = "^[\u{2191} ] \\S.\\{-}\\s\\{2,}"
  M.wo(win, "breakindentopt", "list:-1")
  M.wo(win, "cursorline", false)
  M.float_hl(win)
  if focus then
    local kopts = { buffer = buf, silent = true, nowait = true }
    local function close()
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end
    vim.keymap.set("n", "q", close, kopts)
    vim.keymap.set("n", "<Esc>", close, kopts)
  end
  if opts.on_close then
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win), once = true,
      callback = function() opts.on_close() end,
    })
  end
  return win, buf
end

-- A one-line filter box that narrows a list as you type: a tiny floating
-- buffer in insert mode at the top of `opts.win` (the list it filters).
-- opts.on_change(text) runs on every keystroke, opts.on_submit(text) on
-- <CR>, and opts.on_cancel() on <Esc> - which also means "clear the
-- filter", the way a search box's Esc does, since "how do I remove the
-- filter?" was the question the old modal prompt left open.
-- opts.prompt is the title, opts.default the starting text.
function M.filter_prompt(opts)
  opts = opts or {}
  local host = (opts.win and vim.api.nvim_win_is_valid(opts.win)) and opts.win or 0
  local width = math.min(60, math.max(30, vim.api.nvim_win_get_width(host) - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default or "" })
  local cfg = {
    relative = "win", win = host, row = 0, col = math.max(0, math.floor((vim.api.nvim_win_get_width(host) - width) / 2)),
    width = width, height = 1, style = "minimal", border = M.border(),
    title = " " .. (opts.prompt or "Filter") .. " ", title_pos = "left",
    footer = " <CR> keep \u{00B7} <Esc> clear ", footer_pos = "right",
  }
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, cfg)
  if not ok then
    cfg.title, cfg.title_pos, cfg.footer, cfg.footer_pos = nil, nil, nil, nil
    win = vim.api.nvim_open_win(buf, true, cfg)
  end
  M.float_hl(win)
  local done = false
  local function text()
    return vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  end
  local function finish(kind)
    if done then return end
    done = true
    local t = text()
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if kind == "submit" then
      if opts.on_submit then opts.on_submit(t) end
    else
      if opts.on_cancel then opts.on_cancel() end
    end
  end
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function() if opts.on_change then opts.on_change(text()) end end,
  })
  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set({ "i", "n" }, "<CR>", function() finish("submit") end, kopts)
  vim.keymap.set({ "i", "n" }, "<Esc>", function() finish("cancel") end, kopts)
  vim.keymap.set("n", "q", function() finish("cancel") end, kopts)
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = function() finish("submit") end })
  vim.cmd("startinsert!")
  return win, buf
end

-- The tabpage showing a buffer `pred(buf)` accepts, or nil. Lets
-- `:AzureCli dashboard` (and <CR> on a PR that's already open) jump to
-- the tab that exists instead of stacking another one whose twin then
-- silently stops polling.
function M.find_tab(pred)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
      if ok and vim.api.nvim_buf_is_valid(buf) and pred(buf) then return tab, win end
    end
  end
  return nil
end

-- Jumps to the tab/window `pred` finds (see M.find_tab); true when it did.
function M.goto_tab(pred)
  local tab, win = M.find_tab(pred)
  if not tab then return false end
  pcall(vim.api.nvim_set_current_tabpage, tab)
  pcall(vim.api.nvim_set_current_win, win)
  return true
end

-- Sets a window option on `win` ONLY (`:setlocal`). `vim.wo[win].x = v`
-- is NOT that: for a plain window-local option ('number', 'signcolumn',
-- 'wrap', ...) it behaves like `:set`, which also rewrites the global
-- value every later window inherits - the plugin used to turn line
-- numbers off for the user's whole session that way. Every window-option
-- write in this plugin goes through here.
-- A winbar gets the inner-tab strip in front (lua/azure-cli/innertabs.lua's
-- M.bar: empty except in the widest window of a home tab with inner tabs,
-- or of one of those), so no winbar builder has to know about it.
M.STRIP = "%{%v:lua.require'azure-cli.innertabs'.bar()%}"
function M.wo(win, name, value)
  if name == "winbar" and type(value) == "string" and value ~= "" and value:sub(1, #M.STRIP) ~= M.STRIP then
    value = M.STRIP .. value
  end
  vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
end

-- `win`'s own winbar: its 'winbar' without the strip M.wo put in front.
function M.own_winbar(win)
  local v = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
  if v:sub(1, #M.STRIP) == M.STRIP then v = v:sub(#M.STRIP + 1) end
  return v
end

-- Pads `s` to exactly `n` display cells, or truncates it to n-1 cells plus
-- an ellipsis. Truncation counts cells, never bytes, so a multi-byte or
-- double-width character is never cut in half (which used to leave a row
-- misaligned with mojibake at the cut).
function M.fit(s, n)
  s = tostring(s or "")
  if n <= 0 then return "" end
  local w = vim.fn.strdisplaywidth(s)
  if w <= n then return s .. string.rep(" ", n - w) end
  local k = vim.fn.strchars(s)
  while k > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(s, 0, k)) > n - 1 do
    k = k - 1
  end
  return vim.fn.strcharpart(s, 0, k) .. "\u{2026}"
end


-- Joins `parts` (a list of "what you're looking at" context strings, left to
-- right, e.g. {"PR #123", "feature/x -> main", "14 files"}; blank/nil
-- entries are skipped) with " \u{00B7} " (a middle dot), then `tags` (a list
-- of already-bracketed mode-tag strings, e.g. "[active-only]",
-- "[since abc123 \u{00B7} 2 new iterations]" - callers build these
-- themselves since each mode's exact wording is already tested/expected
-- elsewhere) joined by a single space, then always "?: help" - the three
-- groups (context, tags, help) are joined by three spaces so the tags read
-- as a distinct cluster of flags rather than more context.
--
-- The result is a 'winbar' value in the shared look: the first context
-- part (what the screen is) in AzureCliWinbarTitle, the rest in
-- AzureCliWinbar, the dots between them in AzureCliWinbarSep, the tags in
-- AzureCliWinbarTag and the help pointer in AzureCliWinbarHelp. A "%" in
-- the text is escaped, so a path with one in it shows as it is.
-- M.strip_hl(M.winbar(...)) is the plain text. Pure.
local function esc(s) return (s:gsub("%%", "%%%%")) end

function M.winbar(parts, tags)
  local ctx = {}
  for _, p in ipairs(parts or {}) do
    if p and p ~= "" then ctx[#ctx + 1] = p end
  end
  local segments = {}
  if #ctx > 0 then
    local bits = {}
    for i, p in ipairs(ctx) do
      bits[i] = (i == 1 and "%#AzureCliWinbarTitle#" or "%#AzureCliWinbar#") .. esc(p)
    end
    -- Too long for the window: cut after the title, not before it.
    local rest = #bits > 1 and ("%#AzureCliWinbarSep# \u{00B7} " .. table.concat(bits, "%#AzureCliWinbarSep# \u{00B7} ", 2)) or ""
    segments[#segments + 1] = bits[1] .. "%<" .. rest
  end
  local tagbits = {}
  for _, t in ipairs(tags or {}) do
    if t and t ~= "" then tagbits[#tagbits + 1] = esc(t) end
  end
  if #tagbits > 0 then segments[#segments + 1] = "%#AzureCliWinbarTag#" .. table.concat(tagbits, " ") end
  segments[#segments + 1] = "%#AzureCliWinbarHelp#?: help"
  return " " .. table.concat(segments, "%#AzureCliWinbar#   ") .. "%#AzureCliWinbar#"
end

-- A 'winbar'/'statusline' value without its %#Group# codes, "%%" back to
-- "%", and the leading pad M.winbar adds: what it reads as. Pure.
function M.strip_hl(s)
  s = (s or ""):gsub("%%#[%w_]*#", ""):gsub("%%%*", ""):gsub("%%<", ""):gsub("%%%%", "%%")
  return (s:gsub("^ ", ""))
end

-- Solves column widths for a row of scaling columns against `available_width`
-- (the display cells free for them - the caller has already subtracted every
-- fixed-width segment, like the dashboard's id/badge/build columns, and the
-- inter-column gaps). `columns` is an ordered list of:
--   { key, min, ideal, weight, priority, grow }
--     key       identifies the column in the returned widths/dropped tables
--     min       never shrunk below this (unless dropped outright)
--     ideal     the width this column grows to before any leftover space
--               goes to the `grow` columns instead (nil/== min: never grows)
--     weight    how a group of under-ideal (or, for `grow` columns, past-
--               ideal) columns split space between them; default 1
--     priority  present (a number) only on a column that may be dropped
--               entirely when even the minimums don't fit; lower drops
--               first. Columns with no `priority` (e.g. an id column) are
--               never dropped.
--     grow      true for a column that keeps growing past its own `ideal`
--               once every column has reached its own ideal, splitting
--               whatever width is still left over by weight (e.g. the
--               dashboard's title/reviewer-summary columns, so the table
--               fills a wide window instead of leaving a blank margin)
--
-- Returns { widths = {[key] = n, ...}, dropped = {key, ...}, narrow = bool }.
-- `dropped` lists every column priority-dropped to make the minimums fit
-- (in drop order); `narrow` is true exactly when that happened, for a
-- caller that wants to flag it (e.g. the dashboard's "[narrow]" winbar tag).
function M.layout(columns, available_width)
  available_width = math.max(0, available_width or 0)

  local active = {}
  for _, c in ipairs(columns) do active[#active + 1] = c end

  local function min_total()
    local t = 0
    for _, c in ipairs(active) do t = t + c.min end
    return t
  end

  -- Drop the lowest-priority droppable column, one at a time, until the
  -- remaining columns' minimums fit (or nothing left is droppable).
  local dropped, narrow = {}, false
  while min_total() > available_width do
    local victim, victim_i
    for i, c in ipairs(active) do
      if c.priority and (not victim or c.priority < victim.priority) then
        victim, victim_i = c, i
      end
    end
    if not victim then break end
    table.remove(active, victim_i)
    dropped[#dropped + 1] = victim.key
    narrow = true
  end

  local widths = {}
  for _, c in ipairs(active) do widths[c.key] = c.min end
  local remaining = available_width - min_total()

  -- Grow every under-ideal column, in weighted rounds, until each hits its
  -- own ideal or the width runs out.
  if remaining > 0 then
    local growable = {}
    for _, c in ipairs(active) do
      if c.ideal and c.ideal > c.min and (c.weight or 1) > 0 then
        growable[#growable + 1] = c
      end
    end
    while remaining > 0 and #growable > 0 do
      local weight_sum = 0
      for _, c in ipairs(growable) do weight_sum = weight_sum + (c.weight or 1) end
      local progressed = false
      for i = #growable, 1, -1 do
        local c = growable[i]
        local share = math.max(1, math.floor(remaining * (c.weight or 1) / weight_sum))
        local room = c.ideal - widths[c.key]
        local take = math.min(share, room, remaining)
        if take > 0 then
          widths[c.key] = widths[c.key] + take
          remaining = remaining - take
          progressed = true
        end
        if widths[c.key] >= c.ideal then table.remove(growable, i) end
      end
      if not progressed then break end
    end
  end

  -- Everything is at its ideal and width is still left over: hand it to the
  -- `grow`-marked columns, split by weight, so the table fills the window.
  if remaining > 0 then
    local growers = {}
    for _, c in ipairs(active) do
      if c.grow then growers[#growers + 1] = c end
    end
    if #growers > 0 then
      local weight_sum = 0
      for _, c in ipairs(growers) do weight_sum = weight_sum + (c.weight or 1) end
      for i, c in ipairs(growers) do
        local share
        if i == #growers then
          share = remaining  -- last grower mops up any rounding remainder
        else
          share = math.floor(remaining * (c.weight or 1) / weight_sum)
        end
        widths[c.key] = widths[c.key] + share
        remaining = remaining - share
      end
    end
  end

  return { widths = widths, dropped = dropped, narrow = narrow }
end

-- The question popup's lines and highlights (M.choose): the body wrapped
-- to `width`, a blank line, the buttons - in a row when they fit, else one
-- per line (always with `stack`, a menu), as wide as the popup - the
-- focused one AzureCliButtonActive (all of them plain while `waiting`, the
-- first moment keys don't count yet), then `hint`, muted. Returns lines,
-- hls ({ row, from, to, group }), the buttons' rows. Pure.
function M.choose_lines(body, labels, focused, width, hint, waiting, stack)
  local lines, hls = {}, {}
  -- `l` as lines of the popup: as it is when it fits (spacing and all),
  -- else wrapped at word boundaries, one cell of margin on each side. The
  -- wrapped lines keep its indent - under the text of a "- " item - and a
  -- word too long for the rest of a line starts the next one, never split.
  local function add(l)
    if l == "" then lines[#lines + 1] = "" return end
    if vim.fn.strdisplaywidth(l) <= width - 2 then lines[#lines + 1] = " " .. l return end
    local lead = l:match("^%s*")
    local hang = lead .. (l:sub(#lead + 1):match("^[-*] ") and "  " or "")
    local cur, empty = lead, true
    for word in l:gmatch("%S+") do
      if not empty and vim.fn.strdisplaywidth(cur .. " " .. word) > width - 2 then
        lines[#lines + 1] = " " .. cur
        cur = hang .. word
      else
        cur = empty and (cur .. word) or (cur .. " " .. word)
      end
      empty = false
    end
    lines[#lines + 1] = " " .. cur
  end
  for _, l in ipairs(body or {}) do add(l) end
  lines[#lines + 1] = ""
  local caps = {}
  for i, l in ipairs(labels) do caps[i] = "  " .. l .. "  " end
  local row_text = " " .. table.concat(caps, "   ")
  local rows = {}
  local function group(i) return (i == focused and not waiting) and "AzureCliButtonActive" or "AzureCliButton" end
  if not stack and vim.fn.strdisplaywidth(row_text) <= width then
    lines[#lines + 1] = row_text
    local col = 1
    for i, c in ipairs(caps) do
      hls[#hls + 1] = { #lines - 1, col, col + #c, group(i) }
      col = col + #c + 3
    end
    for i = 1, #caps do rows[i] = #lines end
  else
    -- As wide as the popup (or the widest label), so they read as a list.
    local widest = width - 6
    for _, l in ipairs(labels) do widest = math.max(widest, vim.fn.strdisplaywidth(l)) end
    for i, l in ipairs(labels) do
      local c = "  " .. l .. string.rep(" ", widest - vim.fn.strdisplaywidth(l)) .. "  "
      lines[#lines + 1] = " " .. c
      hls[#hls + 1] = { #lines - 1, 1, 1 + #c, group(i) }
      rows[i] = #lines
    end
  end
  if hint and hint ~= "" then
    lines[#lines + 1] = ""
    local from = #lines
    add(hint)
    for r = from, #lines - 1 do hls[#hls + 1] = { r, 0, #lines[r + 1], "AzureCliMuted" } end
  end
  return lines, hls, rows
end

-- The question popup's details (M.choose) as rows no wider than `width`, so
-- the window shows one row per line and scrolling by line skips nothing: a
-- long line breaks at a space (a word longer than a row, anywhere), its
-- later rows indented like it - with a diff's +/- in front of them too
-- (`diff`), so they keep its colour. Pure.
function M.wrap_details(lines, width, diff)
  width = math.max(8, width)
  local out = {}
  -- The longest head of `s` that fits in `room` cells.
  local function head(s, room)
    local lo, hi = 1, vim.fn.strchars(s)
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if vim.fn.strdisplaywidth(vim.fn.strcharpart(s, 0, mid)) <= room then lo = mid else hi = mid - 1 end
    end
    return vim.fn.strcharpart(s, 0, lo)
  end
  for _, l in ipairs(lines or {}) do
    if vim.fn.strdisplaywidth(l) <= width then
      out[#out + 1] = l
    else
      local mark = diff and l:match("^[+%-]") or ""
      local prefix = mark .. l:sub(#mark + 1):match("^%s*")
      if vim.fn.strdisplaywidth(prefix) > width / 2 then prefix = mark end
      local rest, first = l, true
      while rest ~= "" do
        local room = first and width or (width - vim.fn.strdisplaywidth(prefix))
        local row = rest
        if vim.fn.strdisplaywidth(rest) > room then
          row = head(rest, room)
          -- Back to the last space, unless the cut already falls on one.
          if not rest:sub(#row + 1, #row + 1):match("%s") then
            local at = row:match("^.*()%s")
            if at and row:sub(1, at - 1):match("%S") then row = row:sub(1, at - 1) end
          end
        end
        rest = rest:sub(#row + 1):gsub("^%s+", "")
        out[#out + 1] = (first and "" or prefix) .. row:gsub("%s+$", "")
        first = false
      end
    end
  end
  return out
end

-- A question as a popup in the middle of the screen, answered with buttons:
--   title, lines    what it's about (wrapped)
--   buttons         their labels; default = the one focused first (1)
--   keys            shortcuts: { y = 1, n = 2 } presses that button
--   cancel          what <Esc> / q / leaving the popup answers (the last;
--                   false: nothing - cb(nil), for a menu with no Cancel)
--   stack           one button per line, numbered keys up to the caller
--                   (prompt.lua's menus)
--   details         longer text (a diff, the text a tool would send) in a
--                   window above, as tall as it needs (M.wrap_details),
--                   details_ft its filetype - scrolled from the popup with
--                   <C-d> / <C-u> / <C-e> / <C-y>
--   full            what o opens, to read or yank: the details as they are,
--                   unwrapped (default: details) - q there goes back
--   hint            the keys line under the buttons, when the one made from
--                   `keys` would be too long (long labels)
--   arm_ms          keys count only after this long, so typing already
--                   under way when an agent's question pops up can't answer
--                   it (the buttons light up once they work); any key that
--                   does nothing waits that long again, and q doesn't cancel
--   checks          booleans for the first #checks buttons, which become
--                   tick boxes ("[x] "/"[ ] "): <CR>, <Space>, x and their
--                   keys tick them instead of answering; another button
--                   answers, and cb gets the ticks as its second argument
-- <Tab> / <S-Tab> / h / l / j / k / the arrows move between the buttons,
-- <CR> presses the focused one; every other key does nothing. Opened from
-- insert mode it leaves it, and goes back to it after (give_back: not in
-- the chat's input box). cb(index), once.
-- With ui.confirm = "select" it's vim.ui.select (prompt.lua) instead - the
-- details in a float beside it.
-- How many of those popups are open, and what waits for them all to close
-- (M.after_choose): a view that would move the cursor while one asks - the
-- chat panel following into a tab, a viewer taking the focus - and with it
-- close the popup, answering its cancel button.
-- One asked while another is open waits in `queued` (issue #72): opening
-- on top would take the focus, and that answers the open one's cancel - an
-- agent's question used to cancel the plan's Approve that way. Each keeps
-- its own cb, so each answer goes to who asked.
local choosing, after_choose, queued = 0, {}, {}
function M.choosing() return choosing > 0 or #queued > 0 end
function M.after_choose(fn)
  if not M.choosing() then return fn() end
  after_choose[#after_choose + 1] = fn
end
-- None open any more: the next one waiting, else what waits for them all.
-- Scheduled, so one opened from the answered one's cb (the next of an
-- agent's questions, a menu's next step) goes first; the one waiting stays
-- first in line for when that's answered.
local function settle()
  if choosing > 0 then return end
  if #queued > 0 then
    vim.schedule(function()
      if choosing > 0 or #queued == 0 then return end
      local nxt = table.remove(queued, 1)
      M.choose(nxt[1], nxt[2])
    end)
  elseif #after_choose > 0 then
    local waiting = after_choose
    after_choose = {}
    vim.schedule(function() for _, fn in ipairs(waiting) do pcall(fn) end end)
  end
end

-- Where the popup gives the focus back once answered (issue #55): the
-- window it was opened from (in its tab), in the mode it was in - insert
-- only there. That window gone (closed while it asked): the screen next to
-- the chat, in normal mode. The chat's input box gets it back in normal
-- mode, never insert: the popup left insert mode, so what you type next
-- looks like commands to you - and <CR> there sends.
local function give_back(prev_win, was_insert)
  local back = false
  if vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
    back = vim.api.nvim_get_current_win() == prev_win
  end
  -- (only when the chat is loaded already: a popup doesn't start it)
  local chat = _G.package.loaded["azure-cli.chat"]
  if not back and type(chat) == "table" and chat.main_win then
    local ok, main = pcall(chat.main_win)
    if ok and main and vim.api.nvim_win_is_valid(main) then pcall(vim.api.nvim_set_current_win, main) end
  end
  local in_chat = type(chat) == "table" and chat.is_chat_buf and chat.is_chat_buf(vim.api.nvim_get_current_buf())
  if back and was_insert and not in_chat then
    vim.cmd("startinsert")
  elseif vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
end

function M.choose(opts, cb)
  opts = opts or {}
  M.theme()
  local labels = opts.buttons or { "Yes", "Cancel" }
  local cancel = opts.cancel
  if cancel == nil then cancel = #labels elseif cancel == false then cancel = nil end
  local done, counted = false, false
  local details_win, full_win
  local checks = opts.checks and vim.deepcopy(opts.checks) or nil
  local function checkable(i) return checks ~= nil and i ~= nil and i <= #checks end
  -- The buttons as drawn: tick boxes in front of the checkable ones.
  local function shown()
    if not checks then return labels end
    local out = {}
    for i, l in ipairs(labels) do out[i] = checkable(i) and ((checks[i] and "[x] " or "[ ] ") .. l) or l end
    return out
  end
  local function finish(i)
    if done then return end
    done = true
    for _, w in ipairs({ details_win, full_win }) do
      if type(w) == "number" and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
    if counted then choosing = choosing - 1 end
    settle()
    cb(i, checks)
  end
  local function details_float(focus_row)
    if not (opts.details and #opts.details > 0) then return end
    details_win = M.open_float(opts.details, focus_row)
    local db = details_win and vim.api.nvim_win_get_buf(details_win)
    if db and opts.details_ft then vim.bo[db].filetype = opts.details_ft end
  end
  local cfgok, cfg = pcall(function() return require("azure-cli.config").get() end)
  local style = cfgok and cfg and cfg.ui and cfg.ui.confirm
  local function as_select()
    details_float({ big = true, title = "Details", focus = false })
    local prompt = (opts.title or "") .. ((opts.lines and opts.lines[1]) and (": " .. opts.lines[1]) or "")
    require("azure-cli.prompt").select({ prompt = prompt, items = labels, silent = true, search = true }, function(_, i)
      finish(i or cancel)
    end)
  end
  if style == "select" then return as_select() end
  -- Another one open: this one waits for it (no window yet - nil).
  if choosing > 0 then
    queued[#queued + 1] = { opts, cb }
    return nil
  end

  local was_insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  local prev_win = vim.api.nvim_get_current_win()
  local focused = opts.default or 1
  local uv = vim.uv or vim.loop
  local arm_ms = opts.arm_ms or 0
  local armed_at = uv.hrtime() + arm_ms * 1e6
  local function armed() return uv.hrtime() >= armed_at end
  local full = opts.full or opts.details
  if not (full and #full > 0) then full = nil end
  local full_key = full and not (opts.keys or {}).o and "o" or nil
  local hint_parts, shortcuts = {}, {}
  for k, i in pairs(opts.keys or {}) do shortcuts[#shortcuts + 1] = { k = k, i = i } end
  table.sort(shortcuts, function(a, b) return a.i < b.i or (a.i == b.i and a.k < b.k) end)
  for _, s in ipairs(shortcuts) do hint_parts[#hint_parts + 1] = s.k .. " " .. labels[s.i]:lower() end
  hint_parts[#hint_parts + 1] = cancel and ("Esc " .. labels[cancel]:lower()) or "Esc cancels"
  if #labels > 1 then hint_parts[#hint_parts + 1] = "Tab moves" end
  if opts.details and #opts.details > 0 then hint_parts[#hint_parts + 1] = "C-d / C-u scroll" end
  if full_key then hint_parts[#hint_parts + 1] = full_key .. " shows all" end
  local hint = opts.hint or table.concat(hint_parts, " \u{00B7} ")

  local width = math.max(40, math.min(vim.fn.strdisplaywidth(hint) + 2, 80))
  for _, l in ipairs(shown()) do width = math.max(width, vim.fn.strdisplaywidth(l) + 6) end
  width = math.min(width, math.max(30, math.min(80, vim.o.columns - 4)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local ns = vim.api.nvim_create_namespace("azure_cli_confirm")
  local rows, spans = {}, {}
  local function draw()
    local lines, hls
    lines, hls, rows = M.choose_lines(opts.lines, shown(), focused, width, hint, not armed(), opts.stack)
    for i = 1, #labels do spans[i] = hls[i] end  -- the buttons come first: { row, from, to, group }
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
    return #lines
  end
  local height = draw()

  -- The details above the popup, both centred together: one row per line,
  -- as many as they take while there's room.
  local dh, drows = 0, nil
  if opts.details and #opts.details > 0 then
    drows = M.wrap_details(opts.details, width, opts.details_ft == "diff")
    dh = math.max(1, math.min(#drows, vim.o.lines - height - 8))
  end
  local total = height + 2 + (dh > 0 and dh + 2 or 0)
  local top = math.max(0, math.floor((vim.o.lines - total) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  if dh > 0 then
    local dbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[dbuf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, drows)
    vim.bo[dbuf].modifiable = false
    if opts.details_ft then vim.bo[dbuf].filetype = opts.details_ft end
    local dcfg = { relative = "editor", row = top, col = col, width = width, height = dh, style = "minimal",
      border = M.border(), focusable = false, zindex = 199, title = " Details ", title_pos = "left" }
    local ok
    ok, details_win = pcall(vim.api.nvim_open_win, dbuf, false, dcfg)
    if not ok then
      dcfg.title, dcfg.title_pos = nil, nil
      ok, details_win = pcall(vim.api.nvim_open_win, dbuf, false, dcfg)
      if not ok then details_win = nil end
    end
    if details_win then
      M.float_hl(details_win)
      vim.wo[details_win].wrap = false  -- wrapped already: a row is a line
    end
    top = top + dh + 2
  end
  local wcfg = { relative = "editor", row = top, col = col, width = width, height = height, style = "minimal",
    border = M.border(), zindex = 200 }
  if opts.title then wcfg.title, wcfg.title_pos = " " .. opts.title .. " ", "center" end
  -- Counted before it opens: opening it fires autocmds already.
  choosing, counted = choosing + 1, true
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, wcfg)
  if not ok then
    wcfg.title, wcfg.title_pos = nil, nil
    ok, win = pcall(vim.api.nvim_open_win, buf, true, wcfg)
  end
  if not ok then
    -- Can't take the focus here (the command line, say): the menu instead.
    choosing, counted = choosing - 1, false
    if details_win and vim.api.nvim_win_is_valid(details_win) then pcall(vim.api.nvim_win_close, details_win, true) end
    details_win = nil
    return as_select()
  end
  M.float_hl(win)
  if was_insert then vim.cmd("stopinsert") end
  -- The cursor sits on the focused button, and <CR> presses the one under
  -- the cursor - however it got there (the mouse, <C-w>, a motion).
  local function place()
    pcall(vim.api.nvim_win_set_cursor, win, { rows[focused] or 1, spans[focused] and spans[focused][2] or 0 })
  end
  local function under_cursor()
    if not vim.api.nvim_win_is_valid(win) then return nil end
    local pos = vim.api.nvim_win_get_cursor(win)
    for i, s in ipairs(spans) do
      if rows[i] == pos[1] and pos[2] >= s[2] and pos[2] < s[3] then return i end
    end
  end
  place()
  -- Once keys count, the buttons light up.
  local function light_when_armed()
    vim.defer_fn(function()
      if not done and armed() and vim.api.nvim_buf_is_valid(buf) then draw() place() end
    end, arm_ms + 10)
  end
  if not armed() then light_when_armed() end
  -- A key that does nothing (typing meant for somewhere else, or an answer
  -- before keys count) waits arm_ms again: a burst of typing never answers
  -- this question, nor the one after it.
  local function rearm()
    if arm_ms <= 0 or done then return end
    local was = armed()
    armed_at = uv.hrtime() + arm_ms * 1e6
    if was then draw() place() end
    light_when_armed()
  end

  local function answer(i)
    if done then return end
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    give_back(prev_win, was_insert)
    finish(i)
  end
  local function guarded(fn) return function() if armed() then fn() else rearm() end end end
  local kopts = { buffer = buf, silent = true, nowait = true }
  local on_leave  -- (below)
  local bound = {}
  local function bind(k, fn) bound[k] = true vim.keymap.set("n", k, fn, kopts) end
  local function move(d) focused = (focused - 1 + d) % #labels + 1; draw(); place() end
  for _, k in ipairs({ "<Tab>", "l", "j", "<Right>", "<Down>" }) do bind(k, guarded(function() move(1) end)) end
  for _, k in ipairs({ "<S-Tab>", "h", "k", "<Left>", "<Up>" }) do bind(k, guarded(function() move(-1) end)) end
  -- A tick box's button ticks it (focused on it) and keeps asking.
  local function press(i)
    if not checkable(i) then return answer(i) end
    checks[i] = not checks[i]
    focused = i
    draw()
    place()
  end
  bind("<CR>", guarded(function() press(under_cursor() or focused) end))
  for k, i in pairs(opts.keys or {}) do bind(k, guarded(function() press(i) end)) end
  if checks then
    for _, k in ipairs({ "<Space>", "x" }) do
      if not bound[k] then bind(k, guarded(function() if checkable(focused) then press(focused) end end)) end
    end
  end
  -- Never guarded: backing out is always safe. q too, but not in a question
  -- that can pop up while you type (arm_ms): there it's a stray key.
  bind("<Esc>", function() answer(cancel) end)
  if arm_ms <= 0 then bind("q", function() answer(cancel) end) end
  for key, cmd in pairs({ ["<C-d>"] = "\4", ["<C-u>"] = "\21", ["<C-e>"] = "\5", ["<C-y>"] = "\25" }) do
    bind(key, function()
      if details_win and vim.api.nvim_win_is_valid(details_win) then
        vim.api.nvim_win_call(details_win, function() vim.cmd("normal! " .. cmd) end)
      end
    end)
  end
  -- o: all of it, as it is, in a window of its own to read or yank from
  -- (the popup keeps asking); q / <Esc> there come back.
  if full_key then
    bind(full_key, function()
      if full_win then return end
      local fbuf = vim.api.nvim_create_buf(false, true)
      vim.bo[fbuf].bufhidden = "wipe"
      vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, full)
      vim.bo[fbuf].modifiable = false
      if opts.details_ft then vim.bo[fbuf].filetype = opts.details_ft end
      local fcfg = { relative = "editor", row = 1, col = 2, width = math.max(20, vim.o.columns - 6),
        height = math.max(3, vim.o.lines - 6), border = M.border(), zindex = 210,
        title = " All of it \u{00B7} q goes back ", title_pos = "left" }
      full_win = true  -- leaving the popup for it isn't an answer (on_leave)
      local fok, fwin = pcall(vim.api.nvim_open_win, fbuf, true, fcfg)
      if not fok then
        fcfg.title, fcfg.title_pos = nil, nil
        fok, fwin = pcall(vim.api.nvim_open_win, fbuf, true, fcfg)
      end
      if not fok then full_win = nil return end
      full_win = fwin
      M.float_hl(fwin)
      vim.wo[fwin].wrap = true
      for _, k in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", k, function() pcall(vim.api.nvim_win_close, fwin, true) end, { buffer = fbuf, silent = true, nowait = true })
      end
      vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(fwin), once = true, callback = function()
        full_win = nil
        vim.schedule(function()
          if done or not vim.api.nvim_win_is_valid(win) then return end
          pcall(vim.api.nvim_set_current_win, win)
          vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = on_leave })
        end)
      end })
    end)
  end
  -- Every other key does nothing: typing meant for somewhere else (a :
  -- command, <C-w>, q:) can't leave the popup, which would answer it.
  local function ignore() rearm() end
  for c = 33, 126 do
    local k = string.char(c)
    if not bound[k] then vim.keymap.set("n", k, ignore, kopts) end
  end
  for c = string.byte("a"), string.byte("z") do
    local k = "<C-" .. string.char(c) .. ">"
    -- (<C-i> is <Tab> and <C-m> is <CR>)
    if not bound[k] and c ~= string.byte("i") and c ~= string.byte("m") then vim.keymap.set("n", k, ignore, kopts) end
  end
  for _, k in ipairs({ "<Space>", "<BS>", "<Del>" }) do
    if not bound[k] then vim.keymap.set("n", k, ignore, kopts) end
  end
  -- The button the cursor lands on lights up (before keys count, arming
  -- puts the cursor back on the focused one).
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = function()
    local i = armed() and under_cursor()
    if i and i ~= focused then focused = i; draw() end
  end })
  -- Leaving it answers its cancel button - unless that happens before its
  -- keys count: then it wasn't you (a split opening, a view taking the
  -- cursor), and the popup takes the focus back and keeps asking. Going to
  -- what o opened isn't leaving either: closing that comes back.
  on_leave = function()
    local early, into_full = not armed(), full_win ~= nil
    vim.schedule(function()
      if done or into_full then return end
      if early and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_set_current_win, win)
        if vim.api.nvim_get_current_win() == win then
          vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = on_leave })
          return
        end
      end
      answer(cancel)
    end)
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = on_leave })
  return win
end

-- A yes/no question (M.choose with two buttons): opts.title, opts.lines,
-- opts.yes / opts.no (default "Yes" / "Cancel"), opts.default = "no" to
-- focus No first, plus M.choose's details / arm_ms. y and n press them.
-- cb(true) only for yes.
function M.confirm(opts, cb)
  opts = opts or {}
  return M.choose({ title = opts.title, lines = opts.lines, buttons = { opts.yes or "Yes", opts.no or "Cancel" },
    default = opts.default == "no" and 2 or 1, keys = { y = 1, n = 2 }, cancel = 2, details = opts.details,
    details_ft = opts.details_ft, arm_ms = opts.arm_ms }, function(i) cb(i == 1) end)
end

return M
