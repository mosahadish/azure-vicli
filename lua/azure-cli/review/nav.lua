-- lua/azure-cli/review/nav.lua: code navigation for the reviewer - gd (go
-- to definition), gr (find references), gf (open this file at the PR's
-- revision), g/ (search the changed files), the peek view those open and
-- the revision buffers you keep navigating from.
--
-- Works on any ref without checking it out: `git grep` finds every use of a
-- word across the whole repo at the PR's revision, def_score ranks the
-- definition-looking hits for gd, and `git show` opens a file at that
-- revision read-only for gf and for every jump. Available in diff buffers
-- and in the revision buffers they open, so you can keep following code;
-- <BS> walks back one jump at a time, q drops back to the diff.
--
-- This was ~640 lines inside review/init.lua, holding 30 of that file's
-- top-level locals while it sat five short of LuaJIT's 200-active-local
-- ceiling (see README's "Extending the reviewer"). It reads a lot from the
-- reviewer and writes none of it back - every name it needs from there is a
-- plain read, which is why it could move out as one piece.
--
-- Loaded FIRST by review/init.lua's closing block, before the other
-- review/* modules: several of them (commits, followup, since) reach the
-- peek and the revision buffers through ctx.show_hits/ctx.open_revision/
-- ctx.nav_show/..., and those ctx fields are filled in from this module's
-- return value once it has loaded.
--
-- def_score and the keyword tables it ranks with are pure and exported, so
-- tests/test-nav.lua exercises the heuristic directly under plain luajit.
local CACHE = require("azure-cli.cache")
local KEYS = require("azure-cli.keys")
local STATE = require("azure-cli.state")
local UI = require("azure-cli.ui")
local SHELL = require("azure-cli.shell")

local M = {}

-- A table with a __call metamethod rather than a plain function, the same
-- shape review/comments.lua uses: review/init.lua calls it to build the
-- feature, while tests/test-nav.lua reads def_score and its keyword tables
-- straight out of this file's source instead of needing a live reviewer.
return setmetatable(M, { __call = function(_, ctx)

-- Reviewer state this module reads. All of it is read-only here: nav never
-- assigns any of them back, which is what made the move a straight lift.
local notify = SHELL.notify
local open_config_file = SHELL.open_config_file
local open_float = ctx.open_float
local git_args = ctx.git_args
local ft_for_path = ctx.ft_for_path
local ensure_diff_content = ctx.ensure_diff_content
local maps_by_buf, paths_by_buf = ctx.maps_by_buf, ctx.paths_by_buf
local mark_current_file = ctx.mark_current_file
local set_diff_winbar, set_overview_winbar = ctx.set_diff_winbar, ctx.set_overview_winbar
local resize_list = ctx.resize_list
local cache_key = ctx.cache_key  -- a getter: re-keyed on a push, see for_modules
local diff_ns = ctx.diff_ns
local OVERVIEW_MARK = ctx.OVERVIEW_MARK
local HELP_NOTE_NAV = ctx.HELP_NOTE_NAV
local SOURCE, TARGET, REPO_PATH = ctx.SOURCE, ctx.TARGET, ctx.REPO_PATH
-- EXT is review/init.lua's one extension table: nav reads EXT.keys.nav /
-- EXT.help.nav (what ctx.add_key registered), EXT.mode_tags for the winbar
-- and EXT.commits.nav_restore when a commit view is what q returns to.
local EXT = ctx.ext

-- The four entry points review/init.lua forward-declares and binds on the
-- diff and nav surfaces; assigned below, returned at the end.
local nav_goto_definition, nav_find_references, nav_open_file, nav_search_files

-- Code navigation (no LSP needed) ------------------------------------------
-- Works on any ref without checking it out: `git grep` finds every use of
-- a word across the whole repo at the PR's revision, a small heuristic
-- ranks the definition-looking hits for gd, and `git show` opens a file at
-- that revision read-only for gf and for every jump. Available in diff
-- buffers and in the revision buffers they open, so you can keep following
-- code; <BS> walks back one jump at a time, q drops back to the diff.
local NAV_REF = { R = "origin/" .. SOURCE, L = "origin/" .. TARGET }
local nav_meta = {}   -- revision bufnr -> { ref, path }
local nav_bufs = {}   -- "ref\tpath" -> bufnr, reused across jumps
local nav_stack = {}  -- { buf, cursor } to return to on <BS>
local NAV_MAX_HITS = 2000

local function set_nav_winbar(buf)
  if not (ctx.diff_win() and vim.api.nvim_win_is_valid(ctx.diff_win())) then return end
  local meta = nav_meta[buf]
  UI.wo(ctx.diff_win(), "winbar", UI.winbar({ "[" .. meta.ref .. "] " .. meta.path }, EXT.mode_tags and EXT.mode_tags() or {}))
end

-- Winbar + file-list highlight for whatever buffer the diff window shows now.
local function nav_restore_chrome(buf)
  if nav_meta[buf] then
    set_nav_winbar(buf)
  elseif buf == ctx.overview_buf() then
    set_overview_winbar()
    if mark_current_file then mark_current_file(OVERVIEW_MARK) end
  elseif paths_by_buf[buf] then
    set_diff_winbar(paths_by_buf[buf])
    if mark_current_file then mark_current_file(paths_by_buf[buf]) end
  elseif EXT.commits and EXT.commits.nav_restore then
    -- A buffer none of the three kinds above recognise: give
    -- review/commits.lua (if loaded) a chance to own it (its
    -- commit-list/ctx.files()/diff buffers share this same nav_stack via
    -- ctx.nav_show/ctx.nav_back, so <BS>/nav_back can land back on one).
    EXT.commits.nav_restore(buf)
  end
end

-- What's under the cursor in `buf` as (ref, path, lineno-or-nil): a
-- revision buffer maps 1:1; a diff buffer maps through its side/lineno
-- table (deleted lines belong to the target branch, all else to source).
local function nav_context(buf)
  local meta = nav_meta[buf]
  if meta then
    return meta.ref, meta.path, vim.api.nvim_win_get_cursor(0)[1]
  end
  local path = paths_by_buf[buf]
  if not path then return nil end
  local m = (maps_by_buf[buf] or {})[vim.api.nvim_win_get_cursor(0)[1]]
  local side = (m and m.side) or "R"
  return NAV_REF[side], path, m and m.lineno or nil
end

-- Show `buf` in the diff window, remembering where we came from.
local function nav_show(buf, lnum)
  if not (ctx.diff_win() and vim.api.nvim_win_is_valid(ctx.diff_win())) then return end
  local cur = vim.api.nvim_win_get_buf(ctx.diff_win())
  if cur ~= buf then
    nav_stack[#nav_stack + 1] = { buf = cur, cursor = vim.api.nvim_win_get_cursor(ctx.diff_win()) }
    vim.api.nvim_win_set_buf(ctx.diff_win(), buf)
  end
  vim.api.nvim_set_current_win(ctx.diff_win())
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, ctx.diff_win(), { math.max(1, lnum), 0 })
    vim.cmd("normal! zz")
  end
end

local function nav_back()
  local top = table.remove(nav_stack)
  while top and not vim.api.nvim_buf_is_valid(top.buf) do top = table.remove(nav_stack) end
  if not top then
    notify("Nothing to go back to.")
    return
  end
  vim.api.nvim_win_set_buf(ctx.diff_win(), top.buf)
  pcall(vim.api.nvim_win_set_cursor, ctx.diff_win(), top.cursor)
  nav_restore_chrome(top.buf)
end

-- Pop every revision buffer, landing on the diff/Overview we started from.
local function nav_back_to_diff()
  repeat nav_back() until #nav_stack == 0 or not nav_meta[vim.api.nvim_win_get_buf(ctx.diff_win())]
end

local setup_nav_keymaps  -- below (needs the nav functions)

-- Colour a revision buffer the way the diff pane is coloured, so a preview
-- or a gd/gr/gf jump still shows what the PR changed: in the source-branch
-- copy of a file the PR touches, added lines get the green background and
-- the lines the PR removed appear in red as virtual lines where they used
-- to be; in the target-branch copy it's the reverse. Files the PR doesn't
-- touch are left plain. Uses the same parsed diff the diff pane uses (from
-- the shared cache, fetched on demand for a miss).
local function decorate_revision(buf)
  local meta = nav_meta[buf]
  if not meta or not meta.loaded then return end
  local pr_files = CACHE.files(cache_key())
  if not pr_files or not vim.tbl_contains(pr_files, meta.path) then return end
  ensure_diff_content(meta.path, function(lines, map)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    local own_side = (meta.ref == NAV_REF.L) and "L" or "R"
    local own_kind = own_side == "R" and "add" or "del"
    local own_bg = own_side == "R" and "AzureCliDiffAddBg" or "AzureCliDiffDelBg"
    local own_sign = own_side == "R" and "AzureCliDiffAddSign" or "AzureCliDiffDelSign"
    local other_bg = own_side == "R" and "AzureCliDiffDelBg" or "AzureCliDiffAddBg"
    local n = vim.api.nvim_buf_line_count(buf)

    -- Walk the diff in order keeping both sides' line counters, so every
    -- entry has a position in this buffer's numbering: own-side changes
    -- highlight that line, the other side's changes stack up as virtual
    -- lines above the next own-side line (or below the last one).
    local old, new = 0, 0
    local pending = {}
    local function flush(anchor)
      if #pending == 0 then return end
      local virt = {}
      for _, t in ipairs(pending) do virt[#virt + 1] = { { t, other_bg } } end
      local above = anchor <= n
      pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, math.max(0, math.min(anchor, n) - 1), 0,
        { virt_lines = virt, virt_lines_above = above })
      pending = {}
    end
    for i, m in ipairs(map) do
      if m.kind == "add" then
        new = new + 1
      elseif m.kind == "del" then
        old = old + 1
      elseif m.kind == "ctx" then
        new, old = new + 1, old + 1
      end
      local own_line = own_side == "R" and new or old
      if m.kind == own_kind then
        flush(own_line)
        pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, own_line - 1, 0, {
          sign_text = own_side == "R" and "+" or "-",
          sign_hl_group = own_sign,
          line_hl_group = own_bg,
        })
      elseif m.kind == "ctx" then
        flush(own_line)
      elseif m.kind then
        pending[#pending + 1] = lines[i]
      end
    end
    flush(n + 1)

    -- Word-level highlights on real lines only: the other side above is
    -- shown as virtual text (virt_lines can't carry extmarks), so only the
    -- own-side half of a CACHE.word_diff pair ever applies here. Walks the
    -- map a second time for its own line-position counters rather than
    -- reusing the walk above, which only leaves `old`/`new` at their final
    -- totals once it's done.
    local word_marks = CACHE.word_diff(lines, map)
    if #word_marks > 0 then
      local by_line = {}
      for _, w in ipairs(word_marks) do
        if w.kind == own_kind then by_line[w.line] = w end
      end
      local wold, wnew = 0, 0
      for i, m in ipairs(map) do
        if m.kind == "add" then
          wnew = wnew + 1
        elseif m.kind == "del" then
          wold = wold + 1
        elseif m.kind == "ctx" then
          wnew, wold = wnew + 1, wold + 1
        end
        local w = by_line[i]
        if w then
          local own_line = own_side == "R" and wnew or wold
          pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, own_line - 1, w.s, {
            end_col = w.e,
            hl_group = w.kind == "add" and "AzureCliDiffAddWord" or "AzureCliDiffDelWord",
          })
        end
      end
    end
  end)
end

-- Load (or reuse) the read-only buffer holding `path` as it is at `ref`,
-- without showing it. Contents arrive asynchronously; see when_loaded.
local function ensure_revision_buf(ref, path)
  local key = ref .. "\t" .. path
  local buf = nav_bufs[key]
  if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = ft_for_path(path) or "text"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "(loading " .. path .. " @ " .. ref .. "\u{2026})" })
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "[" .. ref .. "] " .. path)
  nav_meta[buf] = { ref = ref, path = path, loaded = false, waiters = {} }
  nav_bufs[key] = buf
  setup_nav_keymaps(buf)

  local out = {}
  vim.fn.jobstart(git_args("show", ref .. ":" .. path), {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        if code ~= 0 then
          nav_bufs[key] = nil
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "(could not read " .. path .. " at " .. ref .. ")" })
        else
          if out[#out] == "" then out[#out] = nil end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
        end
        vim.bo[buf].modifiable = false
        local meta = nav_meta[buf]
        meta.loaded = true
        if code == 0 then decorate_revision(buf) end
        local waiters = meta.waiters
        meta.waiters = {}
        for _, f in ipairs(waiters) do f(buf) end
      end)
    end,
  })
  return buf
end

-- cb(buf) once the revision buffer's contents are in (at once if they are).
local function when_loaded(buf, cb)
  local meta = nav_meta[buf]
  if not meta or meta.loaded then cb(buf) return end
  table.insert(meta.waiters, cb)
end

-- Open `path` as it is at `ref` in the diff window, read-only, on line
-- `lnum` (when given).
local function open_revision(ref, path, lnum)
  local buf = ensure_revision_buf(ref, path)
  nav_show(buf, nil)
  set_nav_winbar(buf)
  if not lnum then return end
  when_loaded(buf, function(b)
    if ctx.diff_win() and vim.api.nvim_win_is_valid(ctx.diff_win()) and vim.api.nvim_win_get_buf(ctx.diff_win()) == b then
      pcall(vim.api.nvim_win_set_cursor, ctx.diff_win(), { math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(b))), 0 })
      vim.api.nvim_win_call(ctx.diff_win(), function() vim.cmd("normal! zz") end)
    end
  end)
end

-- `git grep` for `text` at `ref`: cb(hits, truncated) with
-- hits = { {path, lnum, text}, ... }. Fixed-string throughout (-F) so
-- identifiers/search text with regex characters are safe; -I skips
-- binaries. `opts` (all optional):
--   whole_word  false for a plain substring search (the g/ command);
--               defaults to true (-w), matching whole identifiers only.
--   extra       extra flags spliced in before `-e`, e.g. {"-i"} for a
--               case-insensitive search.
--   pathspecs   file list appended after `--`, restricting the search to
--               those ctx.files(); when omitted greps the whole tree at `ref`.
local function git_grep(text, ref, cb, opts)
  opts = opts or {}
  -- Built inline (rather than through git_args, which only takes varargs)
  -- since the flag/pathspec count varies per caller.
  local argv = { "git" }
  if REPO_PATH ~= "" then
    argv[#argv + 1] = "-C"
    argv[#argv + 1] = REPO_PATH
  end
  argv[#argv + 1] = "grep"
  argv[#argv + 1] = "-n"
  argv[#argv + 1] = "-I"
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "--no-color"
  if opts.whole_word ~= false then argv[#argv + 1] = "-w" end
  for _, flag in ipairs(opts.extra or {}) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = text
  argv[#argv + 1] = ref
  argv[#argv + 1] = "--"
  for _, p in ipairs(opts.pathspecs or {}) do argv[#argv + 1] = p end
  local out = {}
  vim.fn.jobstart(argv, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function()
      vim.schedule(function()
        local hits, truncated = {}, false
        local prefix = ref .. ":"
        for _, l in ipairs(out) do
          if l:sub(1, #prefix) == prefix then
            local path, lnum, line_text = l:sub(#prefix + 1):match("^(.-):(%d+):(.*)$")
            if path then
              if #hits >= NAV_MAX_HITS then truncated = true break end
              hits[#hits + 1] = { path = path, lnum = tonumber(lnum), text = line_text }
            end
          end
        end
        cb(hits, truncated)
      end)
    end,
  })
end

-- Rank a grep hit by how much it looks like `word`'s definition rather than
-- a use. Language-agnostic and deliberately simple: a declaring keyword
-- before the word, or a type-like token before it with a signature /
-- property / assignment shape after it. Comments score below zero.
local DEF_KEYWORDS = {
  "class", "struct", "interface", "enum", "record", "delegate", "def", "function",
  "func", "fn", "type", "trait", "impl", "module", "namespace", "typedef", "event",
}
local DECL_MODIFIERS = {
  "public", "private", "protected", "internal", "static", "const", "let", "var",
  "local", "val", "readonly", "override", "virtual", "abstract", "export", "final",
}
local NOT_A_TYPE = {
  "await", "return", "new", "throw", "yield", "case", "in", "not", "and", "or",
  "if", "elseif", "else", "while", "for", "do", "then", "using", "goto", "echo",
  "is", "as", "typeof", "sizeof", "nameof", "delete", "print", "assert",
}
local function def_score(word, text)
  local esc = vim.pesc(word)
  local before = text:match("^(.-)%f[%w_]" .. esc .. "%f[^%w_]")
  if not before then return 0 end
  local after = text:sub(#before + #word + 1)
  if before:match("^%s*//") or before:match("^%s*#") or before:match("^%s*%-%-")
      or before:match("^%s*%*") or before:match("^%s*/%*") then
    return -1
  end
  local score = 0
  for _, kw in ipairs(DEF_KEYWORDS) do
    if before:match("%f[%w_]" .. kw .. "%f[^%w_]") then score = score + 6 break end
  end
  for _, kw in ipairs(DECL_MODIFIERS) do
    if before:match("%f[%w_]" .. kw .. "%f[^%w_]") then score = score + 2 break end
  end
  -- "Type Name(" / "Type Name {" / "Type Name =" / "name:" shapes, where
  -- something type-like sits right before the word - not "." / "=" / "("
  -- and not a keyword that merely precedes a use (await, return, new, ...).
  local typed = before:match("[%w_>%]%*&%?]%s+$") ~= nil
  if typed then
    for _, kw in ipairs(NOT_A_TYPE) do
      if before:match("%f[%w_]" .. kw .. "%s+$") then typed = false break end
    end
  end
  if typed then
    if after:match("^%s*%(") then score = score + 4
    elseif after:match("^%s*{") or after:match("^%s*=[^=]") or after:match("^%s*:") then score = score + 3 end
  end
  return score
end

-- Peek picker, like an IDE's "peek references": the hits on the left, and
-- on the right the file at that revision centred on the hit under the
-- cursor, with the line and every occurrence highlighted - whole-word for
-- gd/gr, any substring (case-insensitively when smart case says so) for the
-- g/ search. Moving through the list re-previews (debounced); <CR> opens the
-- hit in the diff window, q/<Esc> (or leaving the list) closes both panes.
-- Hits are ordered same file first, then same extension, then by path.
pcall(vim.api.nvim_set_hl, 0, "AzureCliPeekLine", { default = true, link = "Visual" })
pcall(vim.api.nvim_set_hl, 0, "AzureCliPeekWord", { default = true, link = "Search" })
local peek_ns = vim.api.nvim_create_namespace("azure_cli_peek")

-- nvim_open_win with a border title where supported (0.9+), plain otherwise.
local function open_peek_win(buf, focus, cfg, title)
  local with_title = vim.tbl_extend("force", cfg, { title = " " .. title .. " ", title_pos = "left" })
  local ok, win = pcall(vim.api.nvim_open_win, buf, focus, with_title)
  if ok then return win end
  return vim.api.nvim_open_win(buf, focus, cfg)
end

local function show_hits(title, hits, ref, current_path, truncated, word, search_opts)
  local ext = (current_path or ""):match("%.([%w_]+)$")
  local function rank(h)
    if h.path == current_path then return 0 end
    if ext and h.path:sub(-(#ext + 1)) == "." .. ext then return 1 end
    return 2
  end
  table.sort(hits, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    if a.path ~= b.path then return a.path < b.path end
    return a.lnum < b.lnum
  end)

  -- Geometry: one wide box, list taking ~40% (capped), preview the rest.
  local total_w = math.min(vim.o.columns - 4, math.max(80, math.floor(vim.o.columns * 0.92)))
  local height = math.min(vim.o.lines - 6, math.max(16, math.floor(vim.o.lines * 0.72)))
  local list_w = math.min(64, math.floor(total_w * 0.4))
  local prev_w = math.max(20, total_w - list_w - 2)
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_w) / 2))

  local lines = {}
  for _, h in ipairs(hits) do
    lines[#lines + 1] = string.format("%s:%d  %s", h.path, h.lnum, vim.trim(h.text))
  end
  local lbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
  vim.bo[lbuf].modifiable = false
  vim.bo[lbuf].buftype = "nofile"
  local lwin = open_peek_win(lbuf, true, {
    relative = "editor", row = row, col = col, width = list_w, height = height,
    style = "minimal", border = "rounded",
  }, title .. (truncated and ("  (first " .. #hits .. ")") or ""))
  UI.wo(lwin, "cursorline", true)
  UI.wo(lwin, "wrap", false)

  local pwin = open_peek_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor", row = row, col = col + list_w + 2, width = prev_w, height = height,
    style = "minimal", border = "rounded", focusable = false,
  }, "preview")
  UI.wo(pwin, "number", true)
  UI.wo(pwin, "wrap", false)
  UI.wo(pwin, "cursorline", false)

  local function clear_marks()
    for _, b in pairs(nav_bufs) do
      if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_clear_namespace(b, peek_ns, 0, -1) end
    end
  end

  local function highlight(buf, h)
    clear_marks()
    local line = vim.api.nvim_buf_get_lines(buf, h.lnum - 1, h.lnum, false)[1]
    if not line then return end
    pcall(vim.api.nvim_buf_set_extmark, buf, peek_ns, h.lnum - 1, 0, { line_hl_group = "AzureCliPeekLine", priority = 300 })
    if not word then return end
    if search_opts and search_opts.plain then
      -- g/: highlight every substring occurrence (not just whole words),
      -- case-insensitively when the search itself was (smart case).
      local hay = search_opts.case_insensitive and line:lower() or line
      local needle = search_opts.case_insensitive and word:lower() or word
      local from = 1
      while true do
        local s, e = hay:find(needle, from, true)
        if not s then break end
        pcall(vim.api.nvim_buf_set_extmark, buf, peek_ns, h.lnum - 1, s - 1,
          { end_col = e, hl_group = "AzureCliPeekWord", priority = 200 })
        from = e + 1
      end
      return
    end
    local from = 1
    while true do
      local s, e = line:find(word, from, true)
      if not s then break end
      if not line:sub(s - 1, s - 1):match("[%w_]") and not line:sub(e + 1, e + 1):match("[%w_]") then
        pcall(vim.api.nvim_buf_set_extmark, buf, peek_ns, h.lnum - 1, s - 1,
          { end_col = e, hl_group = "AzureCliPeekWord", priority = 200 })
      end
      from = e + 1
    end
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    clear_marks()
    if vim.api.nvim_win_is_valid(pwin) then pcall(vim.api.nvim_win_close, pwin, true) end
    if vim.api.nvim_win_is_valid(lwin) then pcall(vim.api.nvim_win_close, lwin, true) end
  end

  local function selected()
    if not vim.api.nvim_win_is_valid(lwin) then return nil end
    return hits[vim.api.nvim_win_get_cursor(lwin)[1]]
  end

  local function preview()
    local h = selected()
    if not h or not vim.api.nvim_win_is_valid(pwin) then return end
    local buf = ensure_revision_buf(ref, h.path)
    if vim.api.nvim_win_get_buf(pwin) ~= buf then vim.api.nvim_win_set_buf(pwin, buf) end
    pcall(vim.api.nvim_win_set_config, pwin, { title = " " .. h.path .. ":" .. h.lnum .. " ", title_pos = "left" })
    when_loaded(buf, function(b)
      if closed or selected() ~= h or not vim.api.nvim_win_is_valid(pwin)
          or vim.api.nvim_win_get_buf(pwin) ~= b then
        return
      end
      pcall(vim.api.nvim_win_set_cursor, pwin, { math.max(1, math.min(h.lnum, vim.api.nvim_buf_line_count(b))), 0 })
      vim.api.nvim_win_call(pwin, function() vim.cmd("normal! zz") end)
      highlight(b, h)
    end)
  end

  local preview_timer
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = lbuf,
    callback = function()
      if preview_timer then vim.fn.timer_stop(preview_timer) end
      preview_timer = vim.fn.timer_start(40, function() preview() end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, { buffer = lbuf, once = true, callback = close })
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(lwin), once = true, callback = close })

  local kopts = { buffer = lbuf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local h = selected()
    if not h then return end
    close()
    open_revision(ref, h.path, h.lnum)
  end, kopts)
  vim.keymap.set("n", "q", close, kopts)
  vim.keymap.set("n", "<Esc>", close, kopts)

  preview()
end

local function nav_word()
  local word = vim.fn.expand("<cword>")
  if not word or not word:match("^[%w_]+$") then
    notify("No identifier under the cursor.", vim.log.levels.WARN)
    return nil
  end
  return word
end

nav_find_references = function()
  local word = nav_word()
  if not word then return end
  local ref, path = nav_context(vim.api.nvim_get_current_buf())
  if not ref then return end
  notify("Searching references to '" .. word .. "' at " .. ref .. "\u{2026}")
  git_grep(word, ref, function(hits, truncated)
    if #hits == 0 then
      notify("No references to '" .. word .. "' at " .. ref .. ".")
      return
    end
    show_hits("References to '" .. word .. "' @ " .. ref .. " (" .. #hits .. ")", hits, ref, path, truncated, word)
  end)
end

nav_goto_definition = function()
  local word = nav_word()
  if not word then return end
  local ref, path = nav_context(vim.api.nvim_get_current_buf())
  if not ref then return end
  notify("Looking for the definition of '" .. word .. "' at " .. ref .. "\u{2026}")
  git_grep(word, ref, function(hits, truncated)
    if #hits == 0 then
      notify("No occurrences of '" .. word .. "' at " .. ref .. ".")
      return
    end
    local best, candidates = 0, {}
    for _, h in ipairs(hits) do
      h.score = def_score(word, h.text)
      if h.score > best then best = h.score end
    end
    if best >= 4 then
      for _, h in ipairs(hits) do
        if h.score == best then candidates[#candidates + 1] = h end
      end
    end
    if #candidates == 1 then
      open_revision(ref, candidates[1].path, candidates[1].lnum)
    elseif #candidates > 1 then
      show_hits("Definition candidates for '" .. word .. "' @ " .. ref .. " (" .. #candidates .. ")",
        candidates, ref, path, false, word)
    else
      notify("No definition-looking line for '" .. word .. "'; showing all " .. #hits .. " references.")
      show_hits("References to '" .. word .. "' @ " .. ref .. " (" .. #hits .. ")", hits, ref, path, truncated, word)
    end
  end)
end

nav_open_file = function()
  local buf = vim.api.nvim_get_current_buf()
  if nav_meta[buf] then return end  -- already a revision buffer
  local ref, path, lnum = nav_context(buf)
  if not ref then
    notify("Not a diff buffer.", vim.log.levels.WARN)
    return
  end
  open_revision(ref, path, lnum)
end

-- Revision-buffer keys, shown by `?` there.
local NAV_HELP = {
  "Navigate",
  { "goto_definition", "definition from here" }, { "find_references", "references from here" },
  { "search", "search text across the PR's changed ctx.files()" },
  { "back", "walk back one jump" },
  { "back_to_diff", "back to the diff" },
  "Session",
  { "config", "open the config file" },
  { "resize_less", "shrink the file list" }, { "resize_more", "grow the file list" },
  { "help", "this help" },
}

local function show_nav_help()
  open_float(KEYS.help_lines("nav", "Revision buffer keys", NAV_HELP, {
    fixed = { "  j / k       move" },
    extra = EXT.help.nav, extra_title = "Features", notes = { HELP_NOTE_NAV },
  }), true, { min_width = 60 })
end

setup_nav_keymaps = function(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  KEYS.bind(buf, "nav", "goto_definition", function() nav_goto_definition() end, { desc = "go to definition" })
  KEYS.bind(buf, "nav", "find_references", function() nav_find_references() end, { desc = "find references" })
  KEYS.bind(buf, "nav", "search", function() nav_search_files() end, { desc = "search text across the PR's changed ctx.files()" })
  KEYS.bind(buf, "nav", "back", nav_back, { desc = "walk back one jump" })
  KEYS.bind(buf, "nav", "back_to_diff", nav_back_to_diff, { desc = "back to the diff" })
  KEYS.bind(buf, "nav", "config", open_config_file, { desc = "open the config file" })
  KEYS.bind(buf, "nav", "resize_less", function() resize_list(-5) end, { desc = "shrink the file list" })
  KEYS.bind(buf, "nav", "resize_more", function() resize_list(5) end, { desc = "grow the file list" })
  KEYS.bind(buf, "nav", "help", show_nav_help, { desc = "this help" })
  -- Reviewer-feature keys registered via ctx.add_key("nav", ...) - see EXT
  -- near the top of this file.
  for _, e in ipairs(EXT.keys.nav) do
    vim.keymap.set(e.mode or "n", e.key, e.fn, vim.tbl_extend("force", opts, { desc = e.desc }))
  end
end


-- g/: search plain text across the PR's changed ctx.files() at the source branch
-- (unlike gd/gr, which search the whole repo for a single identifier). The
-- last search is kept in _G, like the ignore-whitespace toggle, rather than
-- a local, so it prefills the prompt across PRs opened in the same nvim
-- session without adding another top-level local (this file's already near
-- LuaJIT's 200-local-per-function ceiling for its main chunk).
nav_search_files = function()
  if not ctx.files_loaded() or #ctx.files() == 0 then
    notify("No changed ctx.files() to search yet.", vim.log.levels.WARN)
    return
  end
  require("azure-cli.prompt").input({ prompt = "Search PR ctx.files():", default = STATE.last_search or "" }, function(text)
  if not text then return end
  STATE.last_search = text
  -- Smart case: an uppercase letter in the query makes the search
  -- case-sensitive; otherwise it's case-insensitive.
  local case_insensitive = not text:find("%u")
  notify("Searching \"" .. text .. "\" in " .. #ctx.files() .. " changed ctx.files()\u{2026}")
  git_grep(text, NAV_REF.R, function(hits, truncated)
    if #hits == 0 then
      notify("No hits for \"" .. text .. "\" in the changed ctx.files().")
      return
    end
    show_hits('Search "' .. text .. '" in ' .. #ctx.files() .. ' changed ctx.files() (' .. #hits .. ")",
      hits, NAV_REF.R, nil, truncated, text, { plain = true, case_insensitive = case_insensitive })
  end, { whole_word = false, pathspecs = ctx.files(), extra = case_insensitive and { "-i" } or nil })
  end)
end

M.NAV_REF = NAV_REF
M.bufs = nav_bufs
M.show = nav_show
M.back = nav_back
M.context = nav_context
M.decorate_revision = decorate_revision
M.ensure_revision_buf = ensure_revision_buf
M.when_loaded = when_loaded
M.open_revision = open_revision
M.show_hits = show_hits
M.git_grep = git_grep
M.goto_definition = nav_goto_definition
M.find_references = nav_find_references
M.open_file = nav_open_file
M.search_files = nav_search_files
return M

end })
