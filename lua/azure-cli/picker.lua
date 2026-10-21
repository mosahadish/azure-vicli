-- lua/azure-cli/picker.lua: the plugin's own popups for typing and
-- choosing, in the middle of the screen - what prompt.lua shows where
-- Neovim's built-in vim.ui.input / vim.ui.select would otherwise put a
-- prompt or a numbered list on the command line.
--
--   M.open(opts, cb)   a list with a search line over it: typing narrows
--                      it fuzzily (M.rank), <C-n>/<C-p> move, <CR> picks
--   M.input(opts, cb)  one line to type in, <CR> takes it
--   M.rank             the fuzzy ordering, pure enough for tests
local M = {}

M.MAX_ROWS, M.DEBOUNCE_MS = 12, 250

local function UI() return require("azure-cli.ui") end

-- `items` narrowed and ordered by `q`, fuzzily ("grgory" finds "Stein,
-- Gregory", "tal gross" finds "Gross, Tal"). A typed word that is a whole
-- word of the text ("gross": "Gross, Tal") beats one that only starts a
-- word ("Grossman, Avi"), which beats a scattered match - fuzzy scores
-- alone put the shorter text first. `text(item)` is what's matched;
-- `keep` are items that stay in (after the rest) whether or not they
-- match - a search's own answer, matched on what the text doesn't show.
function M.rank(items, q, text, keep)
  q = vim.trim((q or ""):gsub("[,;]", " "))
  if q == "" then return vim.list_slice(items, 1, #items) end
  -- matchfuzzypos hands back copies of what it's given: match {i, t} pairs
  -- and map each back to the item itself, so `keep` and the caller's
  -- index still find it.
  local cands = {}
  for i, it in ipairs(items) do cands[i] = { i = i, t = text(it) } end
  local m = vim.fn.matchfuzzypos(cands, q, { key = "t" })
  local words = vim.split(q:lower(), "%s+", { trimempty = true })
  local scored = {}
  for i, c in ipairs(m[1]) do
    local it = items[c.i]
    local score = m[3][i]
    for word in text(it):lower():gmatch("[^%s,;]+") do
      for _, w in ipairs(words) do
        if word == w then score = score + 1000
        elseif word:sub(1, #w) == w then score = score + 500 end
      end
    end
    scored[i] = { it = it, score = score, i = i }
  end
  table.sort(scored, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.i < b.i end)
  local out, seen = {}, {}
  for i, s in ipairs(scored) do out[i] = s.it; seen[s.it] = true end
  for _, it in ipairs(keep or {}) do
    if not seen[it] then seen[it] = true; out[#out + 1] = it end
  end
  return out
end

-- The search line's float and, under it, the list's - centred on the
-- editor, `width` wide and `height` rows of list.
local function frames(title, width, height, footer)
  local ui = UI()
  width = math.max(20, math.min(width, vim.o.columns - 4))
  local row = math.max(0, math.floor((vim.o.lines - height - 5) / 2))
  local col = math.floor((vim.o.columns - width) / 2)
  local lbuf, lwin
  if height > 0 then
    lbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[lbuf].bufhidden = "wipe"
    lwin = vim.api.nvim_open_win(lbuf, false, { relative = "editor", row = row + 3, col = col,
      width = width, height = height, style = "minimal", border = ui.border(), focusable = false })
    ui.float_hl(lwin)
    ui.wo(lwin, "winhighlight", ui.FLOAT_HL .. ",CursorLine:PmenuSel")
    ui.wo(lwin, "cursorline", true)
  end
  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].bufhidden = "wipe"
  local cfg = { relative = "editor", row = row, col = col, width = width, height = 1, style = "minimal",
    border = ui.border(), title = " " .. title .. " ", title_pos = "left" }
  if footer and not lwin then cfg.footer, cfg.footer_pos = " " .. footer .. " ", "right" end
  local ok, iwin = pcall(vim.api.nvim_open_win, ibuf, true, cfg)
  if not ok then  -- Neovim 0.9: no footer
    cfg.footer, cfg.footer_pos = nil, nil
    iwin = vim.api.nvim_open_win(ibuf, true, cfg)
  end
  ui.float_hl(iwin)
  return ibuf, iwin, lbuf, lwin
end

-- Shared by both: closes the floats once, then cb(answer) after insert
-- mode has ended (a caller may start it again).
local function closer(wins, cb)
  local done = false
  return function(answer)
    if done then return end
    done = true
    vim.cmd("stopinsert")
    for _, w in ipairs(wins) do
      if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
    vim.schedule(function() cb(answer) end)
  end, function() return done end
end

-- M.open(opts, cb): a list to pick from.
--   opts.title     what it's for
--   opts.items     the entries; opts.format(item) is each one's text
--   opts.current   predicate: the entry that's the present value -
--                  marked "(current)" and selected at first
--   opts.height    rows of list (default: as many as there are, to
--                  M.MAX_ROWS); opts.width likewise
--   opts.ft        the search line's filetype (tests find it by it)
--   opts.on_query(q, api)  after each pause in typing: a host search,
--                  say; api.add(list, q) adds entries (those for `q` stay
--                  listed while `q` is typed even where they don't match
--                  the text), api.status(s) shows a word in the footer
--   opts.empty     the list's line while it has nothing ("Nobody to list")
-- cb(item, index) - index into opts.items, nil for an added entry - or
-- cb(nil) on <Esc>.
function M.open(opts, cb)
  local items = vim.list_slice(opts.items or {}, 1, #(opts.items or {}))
  local index = {}
  for i, it in ipairs(items) do index[it] = i end
  local format = opts.format or function(it)
    return type(it) == "table" and tostring(it.label or it.name or it[1] or "?") or tostring(it)
  end
  local function text(it)
    return format(it) .. ((opts.current and opts.current(it)) and "  (current)" or "")
  end
  local widest = vim.fn.strdisplaywidth(opts.title or "") + 4
  for _, it in ipairs(items) do widest = math.max(widest, vim.fn.strdisplaywidth(text(it)) + 3) end
  local width = opts.width or math.min(100, math.max(50, widest))
  local height = opts.height or math.max(1, math.min(#items, M.MAX_ROWS))
  local ibuf, iwin, lbuf, lwin = frames(opts.title or "Choose", width, height)
  vim.bo[ibuf].filetype = opts.ft or "azure-cli-pick"
  vim.bo[lbuf].filetype = (opts.ft or "azure-cli-pick") .. "-list"

  local shown, sel, status, kept, timer = {}, 1, "", {}, nil
  for i, it in ipairs(items) do
    if opts.current and opts.current(it) then sel = i end
  end
  local finish, is_done = closer({ iwin, lwin }, function(it)
    if timer then timer:stop(); timer:close() end
    cb(it, it and index[it] or nil)
  end)
  local function query()
    return vim.api.nvim_buf_is_valid(ibuf) and vim.trim(vim.api.nvim_buf_get_lines(ibuf, 0, 1, false)[1] or "") or ""
  end
  local function render()
    if is_done() or not vim.api.nvim_win_is_valid(lwin) then return end
    local q = query()
    shown = M.rank(items, q, text, kept[q])
    sel = math.max(1, math.min(sel, #shown))
    local lines = {}
    for i, it in ipairs(shown) do lines[i] = " " .. text(it) end
    if #lines == 0 then
      lines = { "  " .. (status ~= "" and status or (q == "" and (opts.empty or "Nothing to choose from") or "Nothing matches")) }
    end
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
    pcall(vim.api.nvim_win_set_cursor, lwin, { sel, 0 })
    UI().wo(lwin, "cursorline", #shown > 0)
    local count = status ~= "" and status or (#shown .. (q == "" and "" or (" of " .. #items)))
    pcall(vim.api.nvim_win_set_config, lwin, { footer = " " .. count
      .. " \u{00B7} <CR> pick \u{00B7} <C-n>/<C-p> move \u{00B7} <Esc> cancel ", footer_pos = "right" })
  end
  local api = {
    add = function(list, q)
      if q then kept[q] = kept[q] or {} end
      for _, it in ipairs(list or {}) do
        items[#items + 1] = it
        if q then table.insert(kept[q], it) end
      end
      render()
    end,
    keep = function(q, list) kept[q] = list; render() end,
    status = function(s) status = s or ""; render() end,
    items = function() return items end,
    done = is_done,
  }
  local function changed()
    if is_done() then return end
    sel = 1
    render()
    if not opts.on_query then return end
    local q = query()
    timer = timer or (vim.uv or vim.loop).new_timer()
    timer:stop()
    timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      if not is_done() and query() == q then opts.on_query(q, api) end
    end))
  end
  local function move(d)
    if #shown == 0 then return end
    sel = (sel - 1 + d) % #shown + 1
    pcall(vim.api.nvim_win_set_cursor, lwin, { sel, 0 })
  end
  vim.api.nvim_buf_attach(ibuf, false, { on_lines = function() vim.schedule(changed) end })
  local kopts = { buffer = ibuf, silent = true, nowait = true }
  vim.keymap.set({ "i", "n" }, "<CR>", function() if shown[sel] then finish(shown[sel]) end end, kopts)
  for _, k in ipairs({ "<Esc>", "<C-c>" }) do vim.keymap.set({ "i", "n" }, k, function() finish(nil) end, kopts) end
  vim.keymap.set("n", "q", function() finish(nil) end, kopts)
  for _, k in ipairs({ "<C-n>", "<Down>", "<Tab>", "<C-j>" }) do vim.keymap.set({ "i", "n" }, k, function() move(1) end, kopts) end
  for _, k in ipairs({ "<C-p>", "<Up>", "<S-Tab>", "<C-k>" }) do vim.keymap.set({ "i", "n" }, k, function() move(-1) end, kopts) end
  vim.api.nvim_create_autocmd("BufLeave", { buffer = ibuf, once = true, callback = function() finish(nil) end })
  render()
  vim.cmd("startinsert")
  return api
end

-- M.input(opts, cb): one line to type. opts.prompt is the title,
-- opts.default the starting text. cb(text) on <CR> (untrimmed), cb(nil)
-- on <Esc>.
function M.input(opts, cb)
  local title = vim.trim((opts.prompt or "Type"):gsub("[:%s]+$", ""))
  local width = math.min(100, math.max(50, vim.fn.strdisplaywidth(title) + 6,
    vim.fn.strdisplaywidth(opts.default or "") + 4))
  local ibuf, iwin = frames(title, width, 0, "<CR> ok \u{00B7} <Esc> cancel")
  vim.bo[ibuf].filetype = opts.ft or "azure-cli-input"
  vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { opts.default or "" })
  local finish = closer({ iwin }, cb)
  local kopts = { buffer = ibuf, silent = true, nowait = true }
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    finish(vim.api.nvim_buf_get_lines(ibuf, 0, 1, false)[1] or "")
  end, kopts)
  for _, k in ipairs({ "<Esc>", "<C-c>" }) do vim.keymap.set({ "i", "n" }, k, function() finish(nil) end, kopts) end
  vim.api.nvim_create_autocmd("BufLeave", { buffer = ibuf, once = true, callback = function() finish(nil) end })
  vim.cmd("startinsert!")
end

return M
