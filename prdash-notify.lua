-- prdash-notify.lua: OS-level ("toast") desktop notifications for new PR
-- comments and mentions, so activity surfaces even when Neovim isn't the
-- focused window. Loaded with dofile() the same way as prdash-cache.lua, so
-- it's independent of the dashboard's own re-luafile lifecycle.
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
-- Opt-out: PRDASH_TOASTS=0 in the environment, or _G.PRDASH_TOASTS set to
-- false at runtime (flipped by the dashboard's gN key via M.toggle()).
--
-- Rate limit: at most one toast fires per 2 seconds per distinct title. A
-- burst of several toast() calls under the same title within that window is
-- coalesced into a single one, with "(+N more)" appended for the N further
-- calls folded in - a per-title timer started by the first toast() call for
-- that title, firing once 2 seconds later with whatever accumulated.
local M = {}

-- A well-known AppUserModelId Windows already knows how to render a toast
-- for (PowerShell's own shortcut), so CreateToastNotifier works without
-- registering an app id of our own.
local WIN_APP_ID = [[{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe]]

local RATE_LIMIT_MS = 2000
local MAX_LEN = 200

-- title -> { body = <first body seen in this window>, count = <further
-- toast() calls folded into it> }; cleared once the title's timer fires.
local pending = {}

-- False when the env var PRDASH_TOASTS is "0" or _G.PRDASH_TOASTS was set to
-- false (by M.toggle, or by hand for scripting/tests). True otherwise.
function M.enabled()
  if vim.env.PRDASH_TOASTS == "0" then return false end
  if _G.PRDASH_TOASTS == false then return false end
  return true
end

-- Flips desktop notifications on/off for the rest of this Neovim session
-- (the dashboard's gN key). Returns the new effective state.
function M.toggle()
  if _G.PRDASH_TOASTS == false then
    _G.PRDASH_TOASTS = true
  else
    _G.PRDASH_TOASTS = false
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

return M
