-- lua/azure-cli/editor.lua: a small floating comment editor, replacing every
-- single-line vim.fn.input()/vim.ui.input() call that writes comment text -
-- inline/range/file/PR comments, replies, edits, the post-failure retry
-- prompt, and the work-item discussion comment (see README's Reviewer
-- section for the full list of call sites). A new module, not new code
-- inside review/init.lua, for the same reason every reviewer-feature module
-- is (see that file's own EXT comment and README's "Extending the
-- reviewer"): review/init.lua sits close to LuaJIT's 200-active-local
-- ceiling for its main chunk, so this stays a leaf module every call site
-- reaches through a plain require("azure-cli.editor"), never a new
-- top-level local there.
--
-- M.open(opts):
--   opts.title          window title, e.g. "Comment \u{00B7} path:42" - see
--                       M.format_title for the exact shape every call site
--                       builds ("line"/"range", "file", "pr", "reply",
--                       "edit", "workitem").
--   opts.context_lines   optional list of strings shown dimmed above the
--                       buffer (the code line(s), or the thread being
--                       replied to) via virt_lines - never part of the
--                       editable buffer content, so nothing has to be
--                       stripped back out at submit time.
--   opts.initial         starting text - an edit's current content, a
--                       failed send's text (retry), or "" for a brand new
--                       one. Ignored in favour of a stored draft (see
--                       opts.draft_key) when it's nil/"".
--   opts.anchor          { win = <winid>, row = <1-based line> } to open
--                       just below that line in that window (e.g. right
--                       under the diff line being commented on, or below
--                       an already-open K popup so it stays visible - see
--                       README's Reviewer section), or the string
--                       "center" (or nil) to centre it like a PR-level
--                       comment.
--   opts.on_submit(text)  called with the trimmed, mention-translated text
--                       once <C-s>/<C-CR> submits non-empty content.
--   opts.on_cancel(draft)  called on q/<Esc><Esc>/an empty submit, with the
--                       trimmed text that was kept as a draft (nil if
--                       there was nothing worth keeping).
--   opts.mentions          optional list of { name = <display name>,
--                       id = <GUID> } reviewer entries (azure-cli.py's
--                       --list now carries an `id` alongside each
--                       reviewer's `name` - see reviewer_info_list) for
--                       "@" completion; selecting one inserts
--                       "@Display Name" as plain text, translated to
--                       "@<guid>" at submit time (see M.translate_mentions)
--                       since Azure DevOps only sends a notification for
--                       the GUID form, never a plain-text @mention.
--   opts.draft_key          a stable string identifying this comment's
--                       target - PR id + kind + location, see
--                       M.draft_key - built by the caller (it's the one
--                       that knows the PR id/kind/location, not this
--                       module). When given, a cancelled comment's text is
--                       kept under this key in state.lua's
--                       STATE.editor_drafts (so it survives leaving and
--                       re-entering the PR within one session, not a
--                       restart - state.lua is an in-memory table) and
--                       offered back the next time this exact target is
--                       opened; a successful submit clears it.
--
-- Keys: <C-s> and <C-CR>, in insert AND normal mode, submit. q (normal
-- mode) and <Esc><Esc> (the first Esc is vim's own "leave insert mode";
-- the second is this module's normal-mode cancel binding) cancel. Opens in
-- insert mode, cursor at the end of the starting text. The window starts 3
-- lines tall and grows (never shrinks below 3) to a maximum of 8 as the
-- content grows, with a rounded border.

local M = {}
local STATE = require("azure-cli.state")

-- ---------------------------------------------------------------------------
-- Pure helpers - no vim calls, so tests/test-editor.lua exercises them
-- directly under plain luajit, the same way review/range.lua's/
-- review/comments.lua's pure helpers are tested.

-- Builds the key a draft is stored/looked up under: PR id + kind + location,
-- so leaving and re-entering the same PR resumes exactly the in-progress
-- comment that was there before (see the module comment above). `location`
-- is whatever uniquely identifies the target within `kind` - a
-- "path\tside\tlineno" for an inline/range comment, a path for a file
-- comment, a thread id for a reply/edit, "" for a PR-level comment - callers
-- build it the same way pr-review.lua's own bucket keys already do, so this
-- doesn't invent a second scheme.
function M.draft_key(pr_id, kind, location)
  return tostring(pr_id or "") .. "\0" .. tostring(kind or "") .. "\0" .. tostring(location or "")
end

-- Reads a draft out of `store` (a plain key -> text table - normally
-- STATE.editor_drafts, but injected here so this stays pure/testable), or
-- nil when there isn't one / no key was given.
function M.get_draft(store, key)
  if not (store and key) then return nil end
  return store[key]
end

-- Stores `text` under `key`, or clears the entry when `text` is empty/blank
-- (so a draft table never accumulates empty-string entries forever).
function M.set_draft(store, key, text)
  if not (store and key) then return end
  if text and text:gsub("%s", "") ~= "" then
    store[key] = text
  else
    store[key] = nil
  end
end

function M.clear_draft(store, key)
  if store and key then store[key] = nil end
end

-- Azure DevOps only sends a notification for an "@<GUID>" mention, never a
-- plain-text one - see the module comment above and azure-cli.py's
-- reviewer_info_list, which now carries each reviewer's `id` alongside
-- their `name` for exactly this. Translates every "@Display Name"
-- occurrence in `text` to "@<their GUID>", once, for each entry in
-- `mentions` ({ { name = ..., id = ... }, ... }) that actually has an id -
-- longest names first, so "Doe, Jane" isn't shadowed by a shorter "Doe"
-- also on the reviewer list matching first. A name with no known id is left
-- as plain "@Name" text; it just won't notify anyone.
function M.translate_mentions(text, mentions)
  if not text or not mentions or #mentions == 0 then return text end
  local sorted = {}
  for _, m in ipairs(mentions) do
    if m.name and m.name ~= "" and m.id and m.id ~= "" then
      sorted[#sorted + 1] = m
    end
  end
  table.sort(sorted, function(a, b) return #a.name > #b.name end)
  for _, m in ipairs(sorted) do
    local needle = "@" .. m.name
    local out, i = {}, 1
    local start = text:find(needle, 1, true)
    while start do
      out[#out + 1] = text:sub(i, start - 1)
      out[#out + 1] = "@<" .. m.id .. ">"
      i = start + #needle
      start = text:find(needle, i, true)
    end
    out[#out + 1] = text:sub(i)
    text = table.concat(out)
  end
  return text
end

-- "Comment \u{00B7} path:42" / "Comment \u{00B7} path:42\u{2013}48" /
-- "Reply \u{00B7} Jane Doe" / "Edit comment" / "PR comment" / "File comment
-- \u{00B7} path" / "Comment \u{00B7} #123" (work item) - see the module
-- comment above for `kind`'s values; `info` carries whatever that kind
-- needs (path/lineno/end_lineno, author, id).
function M.format_title(kind, info)
  info = info or {}
  if kind == "line" or kind == "range" then
    local loc = tostring(info.path) .. ":" .. tostring(info.lineno)
    if info.end_lineno and info.lineno and info.end_lineno > info.lineno then
      loc = loc .. "\u{2013}" .. tostring(info.end_lineno)
    end
    return "Comment \u{00B7} " .. loc
  elseif kind == "file" then
    return "File comment \u{00B7} " .. tostring(info.path)
  elseif kind == "pr" then
    return "PR comment"
  elseif kind == "reply" then
    return "Reply \u{00B7} " .. tostring(info.author or "?")
  elseif kind == "edit" then
    return "Edit comment"
  elseif kind == "workitem" then
    return "Comment \u{00B7} #" .. tostring(info.id)
  end
  return "Comment"
end

-- Window height, in buffer lines: starts at 3, grows one row per content
-- line beyond the first, capped at 8 - never below 3, never above 8,
-- regardless of how much text there is (a comment worth more than 8 lines
-- just scrolls inside the window, same as before).
function M.compute_height(line_count)
  return math.max(3, math.min(8, (line_count or 1) + 1))
end

-- ---------------------------------------------------------------------------
-- The floating editor itself - everything below touches vim.api/vim.fn, so
-- none of it runs under tests/test-editor.lua's plain luajit; only the pure
-- helpers above are asserted there (see that file's own header comment).

local function drafts_store()
  STATE.editor_drafts = STATE.editor_drafts or {}
  return STATE.editor_drafts
end

-- Renders `lines` (opts.context_lines) as dimmed virt_lines above the
-- buffer's first line, with a separator rule under them - never part of the
-- buffer's real (editable, submitted) content, so nothing has to be parsed
-- back out of it at submit time. A no-op when there's nothing to show.
local function set_context(buf, ns, lines)
  if not lines or #lines == 0 then return end
  local virt = {}
  for _, l in ipairs(lines) do
    virt[#virt + 1] = { { l, "Comment" } }
  end
  virt[#virt + 1] = { { string.rep("\u{2500}", 40), "Comment" } }
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, { virt_lines = virt, virt_lines_above = true })
end

local function resize_to_content(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local n = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_height, win, M.compute_height(n))
end

-- "@" mention completion: on every "@" typed in insert mode, offers every
-- known reviewer's display name via vim.fn.complete() (native ins-completion
-- pum - accepting one is <C-n>/<C-p> then <C-y>/Enter, no extra keymap
-- needed). Inserted as plain "@Display Name" text; M.translate_mentions
-- turns it into "@<guid>" at submit time (see the module comment above).
local function setup_mentions(buf, mentions)
  if not mentions or #mentions == 0 then return end
  local words = {}
  for _, m in ipairs(mentions) do
    if m.name and m.name ~= "" then
      words[#words + 1] = { word = "@" .. m.name, abbr = m.name, menu = "mention" }
    end
  end
  if #words == 0 then return end
  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = buf,
    callback = function()
      if vim.v.char ~= "@" then return end
      -- Only at a word boundary: an "@" inside an email address, a C#
      -- attribute or a quoted "@param" isn't a mention.
      local cur = vim.api.nvim_win_get_cursor(0)
      local before = vim.api.nvim_get_current_line():sub(1, cur[2])
      if before:match("[%w%._%-]$") then return end
      -- InsertCharPre fires just BEFORE the "@" lands in the buffer, so the
      -- completion is scheduled for right after it actually has (nvim_win_
      -- get_cursor's column only accounts for the "@" once it's really
      -- there); vim.fn.complete's startcol then points at the "@" itself,
      -- so the accepted match's "@Name" replaces it whole rather than
      -- doubling it.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local col = vim.api.nvim_win_get_cursor(0)[2]
        pcall(vim.fn.complete, col, words)
      end)
    end,
  })
end

local editor_ns = nil
local function context_ns()
  editor_ns = editor_ns or vim.api.nvim_create_namespace("azure_cli_editor_context")
  return editor_ns
end

function M.open(opts)
  opts = opts or {}
  local store = drafts_store()
  local key = opts.draft_key
  local initial = opts.initial
  if not initial or initial == "" then
    initial = (key and M.get_draft(store, key)) or ""
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  local lines = vim.split(initial, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = 60
  for _, l in ipairs(lines) do
    width = math.max(width, math.min(100, vim.fn.strdisplaywidth(l) + 4))
  end
  local height = M.compute_height(#lines)

  local win_opts = {
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
  }
  local restored = (not opts.initial or opts.initial == "") and initial ~= "" and key ~= nil
  win_opts.title = " " .. (opts.title or "Comment") .. (restored and "  (draft restored)" or "") .. " "
  win_opts.title_pos = "left"
  -- The keys, on the border, so a first-time user isn't guessing.
  win_opts.footer = " <C-s> send \u{00B7} q / <Esc><Esc> cancel (keeps a draft) "
  win_opts.footer_pos = "right"
  local anchor = opts.anchor
  if anchor == "center" or not anchor then
    win_opts.relative = "editor"
    win_opts.row = math.floor((vim.o.lines - height) / 2)
    win_opts.col = math.floor((vim.o.columns - width) / 2)
  elseif anchor.win and vim.api.nvim_win_is_valid(anchor.win) then
    -- "bufpos" anchors to a position inside that window's buffer, so this
    -- lands just under the anchor line regardless of scroll - the same
    -- idea as pr-review.lua's own cursor-relative open_float, just able to
    -- target a specific line rather than only the cursor's.
    win_opts.relative = "win"
    win_opts.win = anchor.win
    win_opts.bufpos = { math.max(0, (anchor.row or 1) - 1), 0 }
    win_opts.row = 1
    win_opts.col = 0
  else
    win_opts.relative = "cursor"
    win_opts.row = 1
    win_opts.col = 0
  end

  local ok_open, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok_open then
    -- Older Neovim without border title/footer.
    win_opts.title, win_opts.title_pos, win_opts.footer, win_opts.footer_pos = nil, nil, nil, nil
    win = vim.api.nvim_open_win(buf, true, win_opts)
  end
  require("azure-cli.ui").wo(win, "wrap", true)
  require("azure-cli.ui").wo(win, "linebreak", true)
  set_context(buf, context_ns(), opts.context_lines)
  setup_mentions(buf, opts.mentions)

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  local function current_text()
    local ls = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return (table.concat(ls, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
  end

  local function do_cancel()
    local text = current_text()
    close()
    if key then
      if text ~= "" then M.set_draft(store, key, text) else M.clear_draft(store, key) end
    end
    if opts.on_cancel then opts.on_cancel(text ~= "" and text or nil) end
  end

  local function do_submit()
    local text = current_text()
    if text == "" then
      do_cancel()
      return
    end
    text = M.translate_mentions(text, opts.mentions)
    close()
    if key then M.clear_draft(store, key) end
    if opts.on_submit then opts.on_submit(text) end
  end

  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", do_submit, kopts)
  vim.keymap.set({ "n", "i" }, "<C-CR>", do_submit, kopts)
  -- <C-s> freezes some terminals (XON/XOFF) and <C-CR> is unreliable in
  -- most; ZZ is vim's own "write and close".
  vim.keymap.set("n", "ZZ", do_submit, kopts)
  vim.keymap.set("n", "q", do_cancel, kopts)
  vim.keymap.set("n", "<Esc>", do_cancel, kopts)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function() resize_to_content(win, buf) end,
  })
  -- Keep a centred editor centred when the terminal is resized (the
  -- position was computed once from vim.o.lines/columns at open).
  if win_opts.relative == "editor" then
    vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        if not vim.api.nvim_win_is_valid(win) then return true end
        local h = vim.api.nvim_win_get_height(win)
        pcall(vim.api.nvim_win_set_config, win, {
          relative = "editor",
          row = math.max(0, math.floor((vim.o.lines - h) / 2)),
          col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        })
      end,
    })
  end

  vim.cmd("startinsert")
  local last = lines[#lines] or ""
  pcall(vim.api.nvim_win_set_cursor, win, { #lines, #last })

  return win, buf
end

return M
