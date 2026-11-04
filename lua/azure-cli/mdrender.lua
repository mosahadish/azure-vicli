-- lua/azure-cli/mdrender.lua: markdown drawn as what it means, in the chat,
-- a plan, a draft or any .md file. A pipe table is hidden line by line and
-- drawn in its place as a box whose cells wrap to the window's width;
-- headings (# and underlined) lose their markers and are drawn bold, rules
-- become a line, bullets and task boxes a symbol, quotes a bar, and bold,
-- italic, code, strikethrough and links lose theirs. It stays drawn under the
-- cursor ('concealcursor' nvc): the cursor still moves through a table's own
-- (hidden) lines, so yanks take the markdown, and its row and cell are lit
-- in the drawing. Only what you're typing in (Insert mode) shows its text.
--
-- Needs Neovim 0.11 (an extmark's conceal_lines); older ones show the text.
-- ui.render_markdown = false turns it off.
--
--   pure:   split_row, delim, find, marks, inline_marks, inline, layout
--   neovim: attach(buf), refresh(buf)

local M = {}

-- ---------------------------------------------------------------------------
-- Parsing (pure).

-- The cells of a table row: split on `|` outside `code` and not escaped,
-- the outer pipes dropped, each cell trimmed.
function M.split_row(line)
  local s = line:gsub("^%s+", ""):gsub("%s+$", "")
  local cells, cur, i, code = {}, {}, 1, false
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" and s:sub(i + 1, i + 1) == "|" then
      cur[#cur + 1] = "|"; i = i + 2
    else
      if c == "`" then code = not code end
      if c == "|" and not code then
        cells[#cells + 1] = table.concat(cur); cur = {}
      else
        cur[#cur + 1] = c
      end
      i = i + 1
    end
  end
  cells[#cells + 1] = table.concat(cur)
  if s:sub(1, 1) == "|" then table.remove(cells, 1) end
  if #cells > 0 and s:sub(-1) == "|" and s:sub(-2, -2) ~= "\\" then table.remove(cells) end
  for k, v in ipairs(cells) do cells[k] = v:gsub("^%s+", ""):gsub("%s+$", "") end
  return cells
end

-- A delimiter row (|---|:---:|--:|): each column's alignment, or nil.
function M.delim(line)
  if not (line:find("-", 1, true) and line:find("|", 1, true)) then return nil end
  local aligns = {}
  for _, c in ipairs(M.split_row(line)) do
    if not c:match("^:?%-+:?$") then return nil end
    local l, r = c:sub(1, 1) == ":", c:sub(-1) == ":"
    aligns[#aligns + 1] = (l and r) and "center" or (r and "right" or "left")
  end
  return #aligns > 0 and aligns or nil
end

-- The tables in `lines`: { first, last, indent, aligns, rows } with 1-based
-- line numbers, rows[1] the header. Fenced code is skipped. A table is a
-- header row, a delimiter row with as many columns, then every following
-- line with a pipe in it.
function M.find(lines)
  local out, i, fence = {}, 1, nil
  while i <= #lines do
    local l = lines[i]
    local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
    if fence then
      if f and f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then fence = nil end
      i = i + 1
    elseif f then
      fence = f; i = i + 1
    else
      local aligns = l:find("|", 1, true) and lines[i + 1] and M.delim(lines[i + 1])
      local head = aligns and M.split_row(l)
      if head and #head == #aligns then
        local t = { first = i, indent = l:match("^(%s*)"), aligns = aligns, rows = { head } }
        local j = i + 2
        while lines[j] and lines[j]:find("|", 1, true) and lines[j]:match("%S") do
          t.rows[#t.rows + 1] = M.split_row(lines[j])
          j = j + 1
        end
        t.last = j - 1
        out[#out + 1] = t
        i = j
      else
        i = i + 1
      end
    end
  end
  return out
end

-- The inline markup of `line` from byte `from` on: { col, end_col (0-based,
-- exclusive), conceal = "" or a character, hl = kind } specs - code spans,
-- bold, italic, strikethrough, links (their text kept) and escapes.
function M.inline_marks(line, from)
  local out, i = {}, from or 1
  local function hide(s, e, rep) out[#out + 1] = { col = s - 1, end_col = e, conceal = rep or "" } end
  local function paint(s, e, kind) if e >= s then out[#out + 1] = { col = s - 1, end_col = e, hl = kind } end end
  -- An _ next to a letter, / or . is part of a name (snake_case, __init__.py).
  local function word(c) return c ~= "" and c:match("[%w/.]") ~= nil end
  local function inner(s, e) for _, m in ipairs(M.inline_marks(line:sub(1, e), s)) do out[#out + 1] = m end end
  while i <= #line do
    local c = line:sub(i, i)
    local two = line:sub(i, i + 1)
    if c == "\\" and line:sub(i + 1, i + 1):match("[%p]") then
      hide(i, i); i = i + 2
    elseif c == "`" then
      local ticks = line:match("^`+", i)
      local e = line:find(ticks, i + #ticks, true)
      if e and not line:sub(e + #ticks, e + #ticks):match("`") then
        hide(i, i + #ticks - 1); paint(i + #ticks, e - 1, "code"); hide(e, e + #ticks - 1)
        i = e + #ticks
      else
        i = i + #ticks
      end
    elseif two == "**" or two == "__" or two == "~~" then
      local e = line:sub(i + 2, i + 2):match("%S") and line:find(two, i + 3, true)
      while e and line:sub(e - 1, e - 1):match("%s") do e = line:find(two, e + 2, true) end
      if e and two == "__" and (word(line:sub(i - 1, i - 1)) or word(line:sub(e + 2, e + 2))) then e = nil end
      if e then
        hide(i, i + 1); hide(e, e + 1)
        out[#out + 1] = { col = i + 1, end_col = e - 1, hl = two == "~~" and "strike" or "bold" }
        inner(i + 2, e - 1)
        i = e + 2
      else
        i = i + 2
      end
    elseif (c == "*" or c == "_") and line:sub(i + 1, i + 1):match("%S") and line:sub(i + 1, i + 1) ~= c then
      local e = line:find(c, i + 2, true)
      while e and (line:sub(e - 1, e - 1):match("%s") or line:sub(e + 1, e + 1) == c) do e = line:find(c, e + 2, true) end
      if e and c == "_" and (word(line:sub(i - 1, i - 1)) or word(line:sub(e + 1, e + 1))) then e = nil end
      if e then
        hide(i, i); hide(e, e)
        out[#out + 1] = { col = i, end_col = e - 1, hl = "italic" }
        inner(i + 1, e - 1)
        i = e + 1
      else
        i = i + 1
      end
    elseif c == "[" or (c == "!" and line:sub(i + 1, i + 1) == "[") then
      local o = c == "!" and i + 1 or i
      local s, e, text = line:find("^%[([^%]]*)%]%b()", o)
      if s and text ~= "" then
        hide(i, o); paint(o + 1, o + #text, "link"); hide(o + #text + 1, e)
        inner(o + 1, o + #text)
        i = e + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return out
end

-- Everything in `lines` drawn other than tables: a list of { line (1-based),
-- col, end_col, conceal, hl, overlay, conceal_line } specs. `skip[n]` lines
-- (a table's) and fenced code are left alone. ATX and setext headings, rules,
-- bullets, task boxes, quotes and inline markup.
local BULLETS = { "\u{2022}", "\u{25E6}", "\u{25AA}" }
function M.marks(lines, skip)
  skip = skip or {}
  local out, fence = {}, nil
  local function add(n, spec) spec.line = n; out[#out + 1] = spec end
  local function plain(l)
    return l:match("%S") and not l:match("^%s*[#>|]") and not l:match("^%s*[-*+]%s") and not l:match("^%s*%d+[.)]%s")
      and not l:match("^%s*```") and not l:match("^%s*~~~")
  end
  local prev_blank = true
  for n, l in ipairs(lines) do
    local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
    if fence then
      if f and f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then fence = nil end
    elseif f then
      fence = f
    elseif not skip[n] then
      local inline_from = 1
      local lead, hashes, sp = l:match("^( ? ? ?)(#+)(%s+)%S")
      local nxt = lines[n + 1] or ""
      if hashes and #hashes <= 6 then
        local mark = #lead + #hashes + #sp
        local close = l:find("%s+#+%s*$", mark + 1)
        add(n, { col = 0, end_col = mark, conceal = "" })
        if close then add(n, { col = close - 1, end_col = #l, conceal = "" }) end
        add(n, { col = mark, end_col = close and close - 1 or #l, hl = #hashes == 1 and "heading1" or "heading" })
        inline_from = mark + 1
      elseif plain(l) and not skip[n + 1] and (nxt:match("^ ? ? ?=+%s*$") or nxt:match("^ ? ? ?%-+%s*$")) then
        add(n, { col = 0, end_col = #l, hl = nxt:find("=", 1, true) and "heading1" or "heading" })
        add(n + 1, { conceal_line = true })
      elseif (l:match("^ ? ? ?%-[%s%-]*$") or l:match("^ ? ? ?%*[%s%*]*$") or l:match("^ ? ? ?_[%s_]*$"))
        and select(2, l:gsub("[-*_]", "")) >= 3 and (prev_blank or not plain(lines[n - 1] or "")) then
        add(n, { col = 0, end_col = #l, overlay = "rule" })
        inline_from = #l + 1
      else
        local q = l:match("^%s*>[>%s]*")
        if q then
          for k = 1, #q do
            if q:sub(k, k) == ">" then add(n, { col = k - 1, end_col = k, conceal = "\u{258E}", hl = "quote" }) end
          end
          inline_from = #q + 1
        end
        local ind, bullet, gap = l:match("^(%s*)([-*+])(%s+)", inline_from)
        if bullet then
          local at = (q and #q or 0) + #ind
          local box = l:match("^%[([ xX])%]%s", at + 1 + #gap + 1)
          if box then
            add(n, { col = at, end_col = at + 1 + #gap, conceal = "" })
            add(n, { col = at + 1 + #gap, end_col = at + #gap + 4, conceal = box == " " and "\u{2610}" or "\u{2611}",
              hl = box == " " and "box" or "done" })
          else
            local level = math.floor(#ind / 2) % #BULLETS + 1
            add(n, { col = at, end_col = at + 1, conceal = BULLETS[level], hl = "bullet" })
          end
          inline_from = at + 1 + #gap + 1
        end
      end
      for _, m in ipairs(M.inline_marks(l, inline_from)) do add(n, m) end
    end
    prev_blank = not l:match("%S")
  end
  return out
end

-- Table `t`'s row for buffer line `n` (rows[1] the header; the delimiter
-- line is nil), and the column byte `col` (0-based) of that line is in.
function M.cell_at(t, n, line, col)
  local r = n == t.first and 1 or (n >= t.first + 2 and n - t.first or nil)
  if not r then return nil end
  local s = line:sub(1, col)
  local pipes, code, i = 0, false, 1
  while i <= #s do
    local ch = s:sub(i, i)
    if ch == "\\" then i = i + 1
    elseif ch == "`" then code = not code
    elseif ch == "|" and not code then pipes = pipes + 1 end
    i = i + 1
  end
  local c = line:match("^%s*|") and pipes or pipes + 1
  return r, math.max(1, math.min(#t.aligns, c))
end

-- A cell's text as { text, kind } pieces, kind nil / "code" / "bold" /
-- "italic" / "link": the markers go, links keep their text.
function M.inline(s)
  local out, i = {}, 1
  local function add(t, kind)
    if t == "" then return end
    local last = out[#out]
    if last and last[2] == kind then last[1] = last[1] .. t else out[#out + 1] = { t, kind } end
  end
  while i <= #s do
    local c = s:sub(i, i)
    local code_e = c == "`" and s:find("`", i + 1, true)
    local bold = (s:sub(i, i + 1) == "**" or s:sub(i, i + 1) == "__") and s:sub(i, i + 1)
    local bold_e = bold and s:find(bold, i + 2, true)
    local ital_e = (c == "*" or c == "_") and not bold and s:sub(i + 1, i + 1):match("%S") and s:find(c, i + 1, true)
    if c == "_" and i > 1 and s:sub(i - 1, i - 1):match("[%w]") then ital_e = nil end
    local link_t, link_e = nil, nil
    if c == "[" then
      local a, b, t = s:find("^%[([^%]]*)%]%b()", i)
      if a then link_t, link_e = t, b end
    end
    if code_e then
      add(s:sub(i + 1, code_e - 1), "code"); i = code_e + 1
    elseif bold_e and bold_e > i + 2 then
      add(s:sub(i + 2, bold_e - 1), "bold"); i = bold_e + 2
    elseif ital_e and ital_e > i + 1 then
      add(s:sub(i + 1, ital_e - 1), "italic"); i = ital_e + 1
    elseif link_e then
      add(link_t, "link"); i = link_e + 1
    else
      add(c, nil); i = i + 1
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Layout (pure).

local function utf8_len(s) local _, n = s:gsub("[^\128-\191]", "") return n end

-- `pieces` wrapped to `w` cells: a list of lines, each a list of pieces.
local function wrap(pieces, w, dw)
  -- Words, each a list of pieces (a word can change kind mid-way: **a**b).
  local words, cur = {}, {}
  for _, p in ipairs(pieces) do
    local text = p[1]
    local pos = 1
    while pos <= #text do
      local sp = text:find("%s", pos)
      if sp == pos then
        if #cur > 0 then words[#words + 1] = cur; cur = {} end
        pos = pos + 1
      else
        local e = (sp or #text + 1) - 1
        cur[#cur + 1] = { text:sub(pos, e), p[2] }
        pos = e + 1
      end
    end
  end
  if #cur > 0 then words[#words + 1] = cur end
  local lines, line, used = {}, {}, 0
  local function flush() lines[#lines + 1] = line; line, used = {}, 0 end
  local function put(t, kind)
    local last = line[#line]
    if last and last[2] == kind then last[1] = last[1] .. t else line[#line + 1] = { t, kind } end
    used = used + dw(t)
  end
  for _, word in ipairs(words) do
    local ww = 0
    for _, p in ipairs(word) do ww = ww + dw(p[1]) end
    if used > 0 and used + 1 + ww > w then flush() end
    if used > 0 then put(" ", nil) end
    for _, p in ipairs(word) do
      -- A word wider than the column is cut, character by character.
      for ch in p[1]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if used + dw(ch) > w and used > 0 then flush() end
        put(ch, p[2])
      end
    end
  end
  if #line > 0 or #lines == 0 then flush() end
  return lines
end

-- Each column's width within `avail` cells: natural widths when they fit;
-- else each keeps room for its longest word (when there's room for every
-- column's) and the rest goes out in proportion to what's still missing.
local function widths(natural, longest, avail)
  local n, out, sum = #natural, {}, 0
  for c = 1, n do sum = sum + natural[c] end
  if sum <= avail then return natural end
  local floor, fsum = {}, 0
  for c = 1, n do floor[c] = math.min(natural[c], math.max(longest[c], 3)); fsum = fsum + floor[c] end
  if fsum > avail then
    for c = 1, n do floor[c] = math.min(natural[c], 3) end
    fsum = 0
    for c = 1, n do fsum = fsum + floor[c] end
  end
  local left, want = avail - fsum, 0
  for c = 1, n do want = want + natural[c] - floor[c] end
  local given = 0
  for c = 1, n do
    out[c] = floor[c] + (want > 0 and math.floor(left * (natural[c] - floor[c]) / want) or 0)
    given = given + out[c]
  end
  -- What rounding left over, to the columns still short, widest first.
  local c = 1
  while given < avail and c <= n * 2 do
    local k = (c - 1) % n + 1
    if out[k] < natural[k] then out[k] = out[k] + 1; given = given + 1 end
    c = c + 1
  end
  return out
end

M.HL = {
  border = "AzureCliMdTableBorder", head = "AzureCliMdTableHead", code = "AzureCliMdTableCode",
  bold = "AzureCliMdTableBold", italic = "AzureCliMdTableItalic", link = "AzureCliMdTableLink",
  heading = "AzureCliMdHeading", heading1 = "AzureCliMdHeading1", strike = "AzureCliMdStrike",
  rule = "AzureCliMdRule", quote = "AzureCliMdQuote", bullet = "AzureCliMdBullet", box = "AzureCliMdBox",
  done = "AzureCliMdDone", row = "AzureCliMdTableRow", cell = "AzureCliMdTableCell",
}

-- Table `t` (find's) drawn within `width` cells: a list of virtual lines,
-- each a list of { text, hl } chunks, or nil when it can't fit at all.
-- opts.dw is the display-width function (default: one cell a character);
-- opts.rows ({ [row] = true }, rows[1] the header) are drawn highlighted,
-- and opts.cell, a column, more so on them (where the cursor is).
function M.layout(t, width, opts)
  opts = opts or {}
  local dw = opts.dw or utf8_len
  local n = #t.aligns
  local cells, natural, longest = {}, {}, {}
  for c = 1, n do natural[c], longest[c] = 1, 1 end
  for r, row in ipairs(t.rows) do
    cells[r] = {}
    for c = 1, n do
      local p = M.inline(row[c] or "")
      cells[r][c] = p
      local w = 0
      for _, x in ipairs(p) do w = w + dw(x[1]) end
      natural[c] = math.max(natural[c], w)
      for _, x in ipairs(p) do
        for word in x[1]:gmatch("%S+") do longest[c] = math.max(longest[c], dw(word)) end
      end
    end
  end
  local indent = t.indent or ""
  local avail = width - dw(indent) - (3 * n + 1)
  if avail < 4 * n then return nil end
  local w = widths(natural, longest, avail)
  local B = M.HL.border
  local function rule(l, m, r, h)
    local parts = {}
    for c = 1, n do parts[c] = string.rep(h, w[c] + 2) end
    return { { indent .. l .. table.concat(parts, m) .. r, B } }
  end
  local out = { rule("\u{250C}", "\u{252C}", "\u{2510}", "\u{2500}") }
  local wrapped = {}
  local multi = false
  for r = 1, #cells do
    wrapped[r] = {}
    local h = 1
    for c = 1, n do
      wrapped[r][c] = wrap(cells[r][c], w[c], dw)
      h = math.max(h, #wrapped[r][c])
    end
    wrapped[r].h = h
    if r > 1 and h > 1 then multi = true end
  end
  for r = 1, #cells do
    if r == 2 then out[#out + 1] = rule("\u{251C}", "\u{253C}", "\u{2524}", "\u{2500}")
    elseif r > 2 and multi then out[#out + 1] = rule("\u{251C}", "\u{253C}", "\u{2524}", "\u{254C}") end
    for k = 1, wrapped[r].h do
      local line = { { indent .. "\u{2502}", B } }
      local on_row = opts.rows and opts.rows[r]
      for c = 1, n do
        local pieces = wrapped[r][c][k] or {}
        local mark = on_row and ((opts.cell == c and M.HL.cell) or M.HL.row) or nil
        local function with(hl)
          if not mark then return hl end
          if not hl then return mark end
          if type(hl) == "table" then return { mark, hl[1], hl[2] } end
          return { mark, hl }
        end
        local used = 0
        for _, p in ipairs(pieces) do used = used + dw(p[1]) end
        local pad = w[c] - used
        local lpad = t.aligns[c] == "right" and pad or (t.aligns[c] == "center" and math.floor(pad / 2) or 0)
        line[#line + 1] = { " " .. string.rep(" ", lpad), mark }
        for _, p in ipairs(pieces) do
          local hl = p[2] and M.HL[p[2]] or nil
          if r == 1 then hl = hl and { M.HL.head, hl } or M.HL.head end
          line[#line + 1] = { p[1], with(hl) }
        end
        line[#line + 1] = { string.rep(" ", pad - lpad) .. " ", mark }
        line[#line + 1] = { "\u{2502}", B }
      end
      out[#out + 1] = line
    end
  end
  out[#out + 1] = rule("\u{2514}", "\u{2534}", "\u{2518}", "\u{2500}")
  return out
end

-- ---------------------------------------------------------------------------
-- Neovim.

local ns
local attached = {}

local function supported()
  return vim.fn.has("nvim-0.11") == 1
end

function M.enabled()
  local ok, cfg = pcall(function() return require("azure-cli.config").get() end)
  local v = ok and type(cfg) == "table" and (cfg.ui or {}).render_markdown
  return v ~= false and supported()
end

local function define_hl()
  local set = function(name, o) o.default = true; vim.api.nvim_set_hl(0, name, o) end
  set(M.HL.border, { link = "Comment" })
  set(M.HL.head, { link = "Title" })
  set(M.HL.code, { link = "String" })
  set(M.HL.bold, { bold = true })
  set(M.HL.italic, { italic = true })
  set(M.HL.link, { link = "Underlined" })
  local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
  set(M.HL.heading, { fg = title.fg, ctermfg = title.ctermfg, bold = true })
  set(M.HL.heading1, { fg = title.fg, ctermfg = title.ctermfg, bold = true, underline = true })
  set(M.HL.strike, { strikethrough = true })
  set(M.HL.rule, { link = "Comment" })
  set(M.HL.quote, { link = "Comment" })
  set(M.HL.bullet, { link = "Special" })
  set(M.HL.box, { link = "Special" })
  set(M.HL.done, { link = "DiagnosticOk" })
  set(M.HL.row, { link = "CursorLine" })
  set(M.HL.cell, { link = "Visual" })
end

-- The text width of the narrowest window showing `buf`, nil when none does.
local function text_width(buf)
  local w
  for _, info in ipairs(vim.fn.getwininfo()) do
    if info.bufnr == buf then
      local tw = info.width - info.textoff
      w = w and math.min(w, tw) or tw
    end
  end
  return w
end

function M.refresh(buf)
  if not (ns and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local width = text_width(buf)
  if not width then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_buf(cur) == buf and vim.api.nvim_win_get_cursor(cur)[1] or nil
  local dw = vim.fn.strdisplaywidth
  local state = attached[buf]
  if state then state.open = nil end
  local tables = M.find(lines)
  local skip = {}
  for _, t in ipairs(tables) do for l = t.first, t.last do skip[l] = true end end
  -- Markers hidden, or swapped for a character (the cursor's line shows
  -- them all, by Vim's own 'concealcursor'), their text styled.
  for _, m in ipairs(M.marks(lines, skip)) do
    local r = m.line - 1
    if m.conceal_line then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, { conceal_lines = "" })
    elseif m.overlay == "rule" then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, {
        virt_text = { { string.rep("\u{2500}", width), M.HL.rule } }, virt_text_pos = "overlay" })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, m.col, { end_col = m.end_col, conceal = m.conceal,
        hl_group = m.hl and M.HL[m.hl], priority = 220 })
    end
  end
  local mode = vim.api.nvim_get_mode().mode
  local inserting = mode:find("^[iR]") ~= nil
  local visual = mode:find("^[vV\22]") and cursor and { math.min(vim.fn.line("v"), cursor), math.max(vim.fn.line("v"), cursor) }
  for _, t in ipairs(tables) do
    local here = cursor and cursor >= t.first and cursor <= t.last
    if here and inserting then
      -- Typing in it: its text, to edit.
      if state then state.open = t.first end
    else
      -- The cursor (or a visual selection) in it: its row and cell lit.
      local rows, cell
      if visual and visual[1] <= t.last and visual[2] >= t.first then
        rows = {}
        for l = math.max(visual[1], t.first), math.min(visual[2], t.last) do
          local rr = M.cell_at(t, l, lines[l], 0)
          if rr then rows[rr] = true end
        end
      elseif here then
        local rr, cc = M.cell_at(t, cursor, lines[cursor], vim.api.nvim_win_get_cursor(cur)[2])
        if rr then rows, cell = { [rr] = true }, cc end
      end
      local virt = M.layout(t, width, { dw = dw, rows = rows, cell = cell })
      -- The drawing hangs above the line after the table, or below the one
      -- before it: lines it hides can't carry it.
      local row, above = t.last, true
      if t.last >= #lines then row, above = t.first - 2, false end
      if virt and row >= 0 then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, { virt_lines = virt, virt_lines_above = above })
        for l = t.first, t.last do
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, l - 1, 0, { conceal_lines = "" })
        end
      end
    end
  end
end

-- The table the cursor is in changed: draw again.
local function cursor_moved(buf)
  local state = attached[buf]
  if not state then return end
  local pos = vim.api.nvim_win_get_cursor(0)
  local inside
  for _, t in ipairs(state.tables or {}) do
    if pos[1] >= t.first and pos[1] <= t.last then inside = t.first end
  end
  -- In a table the lit row and cell follow the cursor; leaving one unlights it.
  if inside or inside ~= state.was_in or vim.api.nvim_get_mode().mode:find("^[vV\22]") then M.refresh(buf) end
  state.was_in = inside
end

local function draw_now(buf)
  local state = attached[buf]
  if not state then return end
  state.dirty = false
  if vim.api.nvim_buf_is_valid(buf) then
    state.tables = M.find(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end
  M.refresh(buf)
end

-- Drawn again before the screen is: a buffer whose text changed (the chat
-- replaces all of it on every redraw) never shows a frame of raw tables.
local provider
local function on_start()
  for buf, state in pairs(attached) do
    if state.dirty then pcall(draw_now, buf) end
  end
end

local function schedule(buf)
  local state = attached[buf]
  if not state then return end
  state.dirty = true
  if state.pending then return end
  state.pending = true
  vim.schedule(function()
    state.pending = false
    if attached[buf] and attached[buf].dirty then draw_now(buf) end
  end)
end

-- Windows showing an attached buffer hide what conceal_lines marks, and
-- keep it hidden on the cursor's line except while typing there.
local function window_opts(win)
  if vim.wo[win].conceallevel == 0 then vim.wo[win][0].conceallevel = 2 end
  if vim.wo[win].concealcursor ~= "nvc" then vim.wo[win][0].concealcursor = "nvc" end
end

function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if attached[buf] or not vim.api.nvim_buf_is_valid(buf) or not M.enabled() then return end
  ns = ns or vim.api.nvim_create_namespace("azure_cli_mdrender")
  if not provider then
    provider = vim.api.nvim_create_namespace("azure_cli_mdrender_provider")
    vim.api.nvim_set_decoration_provider(provider, { on_start = on_start })
  end
  define_hl()
  attached[buf] = {}
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not attached[buf] then return true end
      attached[buf].dirty = true
    end,
    on_reload = function() schedule(buf) end,
    on_detach = function() attached[buf] = nil end,
  })
  local group = vim.api.nvim_create_augroup("azure_cli_mdrender_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinLeave" }, { group = group, buffer = buf, callback = function()
    schedule(buf)
  end })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, buffer = buf, callback = function()
    window_opts(vim.api.nvim_get_current_win())
  end })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, buffer = buf, callback = function()
    cursor_moved(buf)
  end })
  vim.api.nvim_create_autocmd("ModeChanged", { group = group, buffer = buf, callback = function()
    if attached[buf] and attached[buf].was_in then M.refresh(buf) end
  end })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = group, callback = function()
    if not vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_del_augroup_by_id, group)
      return true
    end
    schedule(buf)
  end })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_hl })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = function()
    attached[buf] = nil
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do window_opts(win) end
  schedule(buf)
end

return M
