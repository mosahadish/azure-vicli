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
--   opts.title      border title
--   opts.min_width / opts.min_height
--   opts.footer     extra footer text; the close hint (and a scroll hint
--                   when the text doesn't fit) is always appended
--   opts.on_close   called once when the window goes away
--
-- Height is capped by the screen, not a constant, and a cursor-anchored
-- float that wouldn't fit below the cursor opens above it instead of
-- being clipped. q / <Esc> close a focused float. Returns win, buf.
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
    height = math.min(math.max(#lines, opts.min_height or 1), math.max(5, screen_h))
  end
  local scrolls = #lines > height

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"

  local cfg = { width = width, height = height, style = "minimal", border = "rounded" }
  if opts.big then
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
  M.wo(win, "cursorline", false)
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
    width = width, height = 1, style = "minimal", border = "rounded",
    title = " " .. (opts.prompt or "Filter") .. " ", title_pos = "left",
    footer = " <CR> keep \u{00B7} <Esc> clear ", footer_pos = "right",
  }
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, cfg)
  if not ok then
    cfg.title, cfg.title_pos, cfg.footer, cfg.footer_pos = nil, nil, nil, nil
    win = vim.api.nvim_open_win(buf, true, cfg)
  end
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
function M.wo(win, name, value)
  vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
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
function M.winbar(parts, tags)
  local ctx = {}
  for _, p in ipairs(parts or {}) do
    if p and p ~= "" then ctx[#ctx + 1] = p end
  end
  local segments = {}
  if #ctx > 0 then segments[#segments + 1] = table.concat(ctx, " \u{00B7} ") end
  local tagbits = {}
  for _, t in ipairs(tags or {}) do
    if t and t ~= "" then tagbits[#tagbits + 1] = t end
  end
  if #tagbits > 0 then segments[#segments + 1] = table.concat(tagbits, " ") end
  segments[#segments + 1] = "?: help"
  return table.concat(segments, "   ")
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

return M
