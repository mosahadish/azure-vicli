-- lua/azure-cli/log.lua: an in-session error log, so a provider failure
-- (a multi-line python traceback on stderr) never has to be shown raw in
-- the UI - every error path that used to dump raw stderr text into a
-- notification or a buffer now shows M.summary()'s one line instead and
-- keeps the full text reachable with :AzureCli log (M.open below, wired in
-- plugin/azure-cli.lua). New module, not new code inside review/init.lua -
-- see that file's own EXT comment and README's "Extending the reviewer"
-- for why: review/init.lua sits close to LuaJIT's 200-active-local ceiling
-- for its main chunk, so every call site reaches this through a plain
-- require("azure-cli.log"), never a new top-level local there.
--
-- M.record(source, text) appends one entry (timestamp, source label, full
-- text) to state.lua's STATE.log_entries, keeping only the most recent 200
-- (oldest dropped first) so a long session's log can't grow without bound.
-- M.summary(text, width) is a pure function (no vim calls - see the module
-- comment on the section boundary below) that reduces `text` to the one
-- line worth showing inline: for a python traceback (recognised by its
-- standard "Traceback (most recent call last):" header line) the LAST
-- non-empty line - which is always the "ExceptionType: message" line -
-- with an HTTP-flavoured exception's class-name prefix (AdoHttpError,
-- *HTTPError, ...) stripped so an "HTTP 400 for <url>" message already in
-- it isn't buried behind "AdoHttpError: "; for anything else, the FIRST
-- non-empty line. Either way, truncated to fit `width` (falls back to 80
-- when omitted/too small) minus a small margin, with a trailing ellipsis
-- when it was cut.
--
-- Every UI error path is expected to call both: M.record(source, raw) to
-- keep the full text, and M.summary(raw, vim.o.columns) for what it
-- actually displays, with " (:AzureCli log)" appended so there's always a
-- way back to the rest of it.

local M = {}

-- ---------------------------------------------------------------------------
-- M.summary - pure, no vim calls, so tests/test-log.lua exercises it
-- directly under plain luajit (mirrors review/range.lua's/
-- review/comments.lua's pure helpers).

-- Strips an HTTP-flavoured exception's "SomeError: " class-name prefix
-- (only when the class name itself contains "http", case-insensitively -
-- AdoHttpError, urllib.error.HTTPError, ... - never a plain ValueError or
-- similar, whose class name IS the useful part) so a message that already
-- reads "HTTP 400 for https://..." isn't buried behind it.
local function strip_error_prefix(line)
  local prefix, rest = line:match("^([%w_.]+Error):%s*(.*)$")
  if prefix and rest and rest ~= "" and prefix:lower():find("http", 1, true) then
    return rest
  end
  return line
end

-- Splits `text` on "\n" into a list of its non-empty (post-trim) lines,
-- preserving order - shared by M.summary's traceback-detection and its
-- first/last-line picks.
local function non_empty_lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then out[#out + 1] = trimmed end
  end
  return out
end

function M.summary(text, width)
  text = tostring(text or "")
  local limit = math.max(20, (type(width) == "number" and width > 10 and width or 80) - 4)
  local lines = non_empty_lines(text)
  if #lines == 0 then return "" end

  local is_traceback = false
  for _, l in ipairs(lines) do
    if l:find("^Traceback %(most recent call last%):") then
      is_traceback = true
      break
    end
  end

  local chosen = is_traceback and strip_error_prefix(lines[#lines]) or lines[1]
  if #chosen > limit then
    chosen = chosen:sub(1, limit - 1) .. "\u{2026}"
  end
  return chosen
end

-- Joins a provider job's buffered stdout and stderr chunks (each a list of
-- lines as jobstart delivers them) into one text blob, stderr first since
-- that's where a diagnostic normally is, dropping empty lines. A failure's
-- message is not always on stderr ("Configuration does not exist" once
-- went to stdout and rendered as a blank error), so both are kept.
function M.join_output(out, err)
  local lines = {}
  for _, list in ipairs({ err or {}, out or {} }) do
    for _, l in ipairs(list) do
      if type(l) == "string" and l:gsub("%s", "") ~= "" then lines[#lines + 1] = l end
    end
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Storage + the :AzureCli log viewer - vim/state.lua from here on.

local STATE = require("azure-cli.state")
local MAX_ENTRIES = 200

local function store()
  STATE.log_entries = STATE.log_entries or {}
  return STATE.log_entries
end

-- Appends one entry - `source` a short label ("PR #123", "PR list", "work
-- item #45", ...), `text` the full raw text (a stderr blob, possibly a
-- multi-line traceback). Oldest entries drop once there are more than
-- MAX_ENTRIES, so a long session's log stays bounded.
function M.record(source, text)
  local entries = store()
  entries[#entries + 1] = { ts = os.time(), source = tostring(source or "?"), text = tostring(text or "") }
  while #entries > MAX_ENTRIES do
    table.remove(entries, 1)
  end
end

-- Every recorded entry, oldest first - :AzureCli log's own source of lines,
-- exposed separately so a caller (or a test with a real STATE table) can
-- inspect it without going through the buffer/window this module also opens.
function M.entries()
  return store()
end

function M.clear()
  STATE.log_entries = {}
end

-- The lines a dashboard shows in place of its table when a load fails:
-- `title` ("Failed to load PRs (exit 1):"), the one-line summary of `raw`,
-- then what to do about it - the config file's path and the commands that
-- get at it. Every first-run failure (no config, a placeholder still in
-- it, a bad PAT) lands here, so this is where the next step has to be.
function M.failure_lines(title, raw)
  local width = vim.o.columns
  local cfg = require("azure-cli.config")
  local lines = { title, "  " .. M.summary(raw, width), "" }
  local hints = {
    "  config file   " .. cfg.config_path(),
    "  gO            open the config file       r   retry",
    "  :AzureCli doctor   check the setup       :AzureCli log   full error text",
  }
  vim.list_extend(lines, hints)
  return lines
end

-- :AzureCli log - a scratch split listing every recorded entry in full
-- (timestamped, oldest first, newest last - the order things actually
-- happened in), not just each one's one-line M.summary, so the detail a
-- notification/buffer left out is always reachable here. "q" closes it.
function M.open()
  local lines = {}
  for _, e in ipairs(store()) do
    lines[#lines + 1] = os.date("%Y-%m-%d %H:%M:%S", e.ts) .. "  " .. e.source
    for _, l in ipairs(vim.split(e.text, "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. l
    end
    lines[#lines + 1] = ""
  end
  if #lines == 0 then
    lines = { "(no errors recorded this session)" }
  end

  vim.cmd("botright split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "azurecli-log"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true, nowait = true })
  pcall(vim.api.nvim_win_set_cursor, 0, { #lines, 0 })
end

return M
