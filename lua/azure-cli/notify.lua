-- lua/azure-cli/notify.lua: OS-level ("toast") desktop notifications for new
-- PR comments and mentions, so activity surfaces even when Neovim isn't the
-- focused window. require()'d the same way as lua/azure-cli/cache.lua, so
-- it's independent of the dashboard's own open()/re-open lifecycle.
--
-- M.toast(title, body) never blocks Neovim (vim.fn.jobstart, detached) and
-- never errors: a missing backend, or any other failure along the way, is
-- silently a no-op - a toast is a nicety, not something a failed dashboard
-- action should ever hinge on.
--
-- Backend chosen by OS, no external dependencies:
--   Windows  PowerShell + WinRT (Windows.UI.Notifications.ToastNotificationManager),
--            shown under a well-known AppUserModelId (PowerShell's own) so
--            the toast renders without this script registering an app id -
--            the usual snag with WinRT toasts run ad hoc.
--   Linux    notify-send, when it's on PATH.
--   macOS    osascript's `display notification`.
--
-- Opt-out: AZVICLI_TOASTS=0 in the environment, or STATE.toasts set to
-- false at runtime (flipped by the dashboard's gN key via M.toggle()).
--
-- Rate limit: at most one toast fires per 2 seconds per distinct title. A
-- burst of several toast() calls under the same title within that window is
-- coalesced into a single one, with "(+N more)" appended for the N further
-- calls folded in - a per-title timer started by the first toast() call for
-- that title, firing once 2 seconds later with whatever accumulated.
local M = {}
local STATE = require("azure-cli.state")

-- A well-known AppUserModelId Windows already knows how to render a toast
-- for (PowerShell's own shortcut), so CreateToastNotifier works without
-- registering an app id of our own.
local WIN_APP_ID = [[{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe]]

local RATE_LIMIT_MS = 2000
local MAX_LEN = 200

-- title -> { body = <first body seen in this window>, count = <further
-- toast() calls folded into it> }; cleared once the title's timer fires.
local pending = {}

-- False when the env var AZVICLI_TOASTS is "0" or STATE.toasts was set to
-- false (by M.toggle, or by hand for scripting/tests). True otherwise.
function M.enabled()
  if vim.env.AZVICLI_TOASTS == "0" then return false end
  if STATE.toasts == false then return false end
  return true
end

-- Flips desktop notifications on/off for the rest of this Neovim session
-- (the dashboard's gN key). Returns the new effective state.
function M.toggle()
  if STATE.toasts == false then
    STATE.toasts = true
  else
    STATE.toasts = false
  end
  return M.enabled()
end

local function clamp(s)
  s = tostring(s or "")
  if #s > MAX_LEN then return s:sub(1, MAX_LEN) end
  return s
end

-- Escape text for an XML text node: only &, < and > are unsafe there (' and
-- " only matter inside attribute values, which this doesn't use).
local function xml_escape(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

-- Double any embedded single quote, PowerShell's only escape for one inside
-- a single-quoted '...' string literal.
local function ps_escape(s)
  s = s:gsub("'", "''")
  return s
end

-- Escape for a double-quoted AppleScript string literal.
local function osa_escape(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  return s
end

-- Never let a jobstart failure (missing backend, bad args, a sandboxed
-- environment, ...) raise into the caller - see the module comment.
local function spawn(cmd)
  pcall(function()
    vim.fn.jobstart(cmd, { detach = true })
  end)
end

local function send_windows(title, body)
  if vim.fn.executable("powershell") ~= 1 then return end
  local t = ps_escape(xml_escape(clamp(title)))
  local b = ps_escape(xml_escape(clamp(body)))
  local script =
    "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null; "
    .. "$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); "
    .. "$nodes = $xml.GetElementsByTagName('text'); "
    .. "$nodes.Item(0).AppendChild($xml.CreateTextNode('" .. t .. "')) | Out-Null; "
    .. "$nodes.Item(1).AppendChild($xml.CreateTextNode('" .. b .. "')) | Out-Null; "
    .. "$toast = [Windows.UI.Notifications.ToastNotification]::new($xml); "
    .. "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('" .. WIN_APP_ID .. "').Show($toast)"
  spawn({ "powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script })
end

local function send_linux(title, body)
  if vim.fn.executable("notify-send") ~= 1 then return end
  spawn({ "notify-send", clamp(title), clamp(body) })
end

local function send_macos(title, body)
  if vim.fn.executable("osascript") ~= 1 then return end
  local script = 'display notification "' .. osa_escape(clamp(body)) .. '" with title "' .. osa_escape(clamp(title)) .. '"'
  spawn({ "osascript", "-e", script })
end

-- Dispatches one already-coalesced toast to the OS-appropriate backend.
local function send(title, body)
  if vim.fn.has("win32") == 1 then
    send_windows(title, body)
  elseif vim.fn.has("mac") == 1 then
    send_macos(title, body)
  else
    send_linux(title, body)
  end
end

-- Shows `title`/`body` as an OS notification, subject to the opt-out and the
-- per-title rate limit above. A no-op when disabled or title is empty.
function M.toast(title, body)
  if not M.enabled() then return end
  title = tostring(title or "")
  if title == "" then return end
  body = tostring(body or "")

  local p = pending[title]
  if p then
    p.count = p.count + 1
    return
  end

  pending[title] = { body = body, count = 0 }
  vim.fn.timer_start(RATE_LIMIT_MS, function()
    local entry = pending[title]
    pending[title] = nil
    if not entry then return end
    local out_body = entry.body
    if entry.count > 0 then
      out_body = out_body .. " (+" .. entry.count .. " more)"
    end
    send(title, out_body)
  end)
end

-- M.flash: an in-editor, non-focusable floating notification for transient
-- status text (Opening PR..., Comment posted., Refresh already in
-- progress..., ... - see dashboard.lua's/review/init.lua's/workitems/
-- {dashboard,view}.lua's own `notify()` helpers, which now call this
-- instead of vim.notify directly) - stacked bottom-right, up to MAX_FLASH
-- at once, each auto-dismissing after FLASH_MS (FLASH_ERROR_MS for an
-- error) so nothing ever waits on "Press ENTER" or sits in the command
-- line. A push past MAX_FLASH dismisses the oldest right away to make
-- room, so this never blocks or queues indefinitely.
--
-- An ERROR-level flash ALSO goes through vim.notify(text, ERROR)
-- unconditionally, so :messages always has it even though the float itself
-- disappears after FLASH_ERROR_MS - never true of an INFO/WARN flash,
-- which only ever shows in the float.
--
-- setup({notifications = "notify"}) turns this into a plain vim.notify
-- pass-through (no floats at all) for a setup where vim.notify is already
-- handled by another plugin (e.g. nvim-notify) that should see these
-- messages too - see config.lua's own comment on this option; "float" (the
-- default) is what's described above.
local MAX_FLASH = 4
local FLASH_MS = 3000
local FLASH_ERROR_MS = 6000
local FLASH_WIDTH = 48

local function flashes()
  STATE.flashes = STATE.flashes or {}
  return STATE.flashes
end

-- Removes `entry` from the active stack and closes its window - shared by
-- both a timer firing and the MAX_FLASH eviction below.
local function flash_dismiss(entry)
  if entry.timer then pcall(vim.fn.timer_stop, entry.timer) end
  if entry.win and vim.api.nvim_win_is_valid(entry.win) then
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
  local list = flashes()
  for i, e in ipairs(list) do
    if e == entry then
      table.remove(list, i)
      break
    end
  end
end

-- Repositions every currently-showing flash, newest closest to the corner,
-- each stacked just above the one below it - run after every push/dismiss
-- so the stack never leaves a gap where a dismissed one used to be.
local function flash_reflow()
  local list = flashes()
  local row = vim.o.lines - 2
  for i = #list, 1, -1 do
    local e = list[i]
    if e.win and vim.api.nvim_win_is_valid(e.win) then
      local ok, height = pcall(vim.api.nvim_win_get_height, e.win)
      row = row - (ok and height or 1) - 1
      pcall(vim.api.nvim_win_set_config, e.win, {
        relative = "editor", row = math.max(0, row), col = math.max(0, vim.o.columns - FLASH_WIDTH - 2),
      })
    end
  end
end

-- Flashes are positioned from vim.o.lines/columns at push time; a resized
-- terminal would otherwise leave them stranded off the corner.
local reflow_autocmd_set = false
local function ensure_reflow_autocmd()
  if reflow_autocmd_set then return end
  reflow_autocmd_set = true
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("AzureCliFlashResize", { clear = true }),
    callback = flash_reflow,
  })
end

local function flash_hl(level)
  if level == vim.log.levels.ERROR then return "ErrorMsg" end
  if level == vim.log.levels.WARN then return "WarningMsg" end
  return "Normal"
end

function M.flash(text, level)
  level = level or vim.log.levels.INFO
  text = tostring(text or "")
  if text == "" then return end

  if level == vim.log.levels.ERROR then
    vim.notify(text, level)  -- :messages must keep an error regardless of the float
  end

  local ok, CONFIG = pcall(require, "azure-cli.config")
  local mode = (ok and CONFIG.get().notifications) or "float"
  if mode == "notify" then
    if level ~= vim.log.levels.ERROR then vim.notify(text, level) end
    return
  end

  local list = flashes()
  while #list >= MAX_FLASH do
    flash_dismiss(list[1])
  end

  local lines = vim.split(text, "\n", { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  -- Height from the WRAPPED line count: a one-line HTTP error longer than
  -- the float is wide used to be clipped to its first 48 cells.
  local height = 0
  for _, l in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / FLASH_WIDTH))
  end
  height = math.min(height, 8)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", row = vim.o.lines - 2, col = math.max(0, vim.o.columns - FLASH_WIDTH - 2),
    width = FLASH_WIDTH, height = height, style = "minimal", border = "rounded",
    focusable = false, noautocmd = true,
  })
  local hl = flash_hl(level)
  local UI = require("azure-cli.ui")
  pcall(function() UI.wo(win, "winhighlight", "Normal:" .. hl .. ",FloatBorder:" .. hl) end)
  pcall(function() UI.wo(win, "wrap", true); UI.wo(win, "linebreak", true) end)
  pcall(ensure_reflow_autocmd)

  local entry = { buf = buf, win = win }
  table.insert(flashes(), entry)
  flash_reflow()

  local ms = (level == vim.log.levels.ERROR) and FLASH_ERROR_MS or FLASH_MS
  entry.timer = vim.fn.timer_start(ms, function()
    flash_dismiss(entry)
    flash_reflow()
  end)
end

return M
