-- lua/azure-cli/dashboard.lua: PR dashboard.
--
-- The front door of azure-vicli: renders the pull-request list entirely in
-- Neovim, gathering it via the python data provider (`azure-cli.py --list`,
-- NDJSON) and dispatching every per-PR action to that same provider.
-- Opening a PR launches the existing reviewer (review/init.lua) in-session.
--
-- Keys
--   j/k         move
--   <CR>        open the PR under the cursor in the reviewer
--   gv          cast a vote on the PR under the cursor
--   gm          complete (merge) the PR under the cursor
--   ga          toggle auto-complete on the PR under the cursor
--   gr          re-queue build validation for the PR under the cursor
--   gN          toggle desktop notifications for this session
--   r           refresh the list
--   q           quit
--   ?           show this help
--
-- Row badges (left of the id): \u{25CF} unread comment activity, \u{21E3} branches or
-- content being fetched in the background right now, \u{25C6} fully prefetched
-- (opens instantly), @ an active thread mentions me. The build column to the
-- right of the id keeps its own \u{2713} ok / \u{2717} failed / \u{21BB} expired /
-- \u{25CF} running glyphs.
--
-- A "Mentions" section at the top of the list lists every PR with an active
-- thread mentioning me, in addition to its normal state section - ADO has no
-- "mentioned" search, so this only ever covers PRs already in the list
-- (assigned to me or created by me).
--
-- M.open() (re)builds this dashboard's buffer/window/keymaps - called by
-- lua/azure-cli/init.lua's open_dashboard() and, to swap back from the
-- work-items dashboard, by workitems/dashboard.lua's "P" key directly.
-- Every module-level `local` the old dofile()/:luafile script had now lives
-- inside this function instead, so re-entering the dashboard resets them
-- exactly as a re-source used to (see init.lua's own header comment).
local M = {}

local CONFIG = require("azure-cli.config")
local STATE = require("azure-cli.state")
local CACHE = require("azure-cli.cache")
local NOTIFY = require("azure-cli.notify")
local RPC = require("azure-cli.rpc")
local KEYS = require("azure-cli.keys")
local UI = require("azure-cli.ui")
local PROMPT = require("azure-cli.prompt")
local PRS = require("azure-cli.prs")

function M.open()

local env    = vim.env
local EXE    = env.AZVICLI_EXE or (CONFIG.plugin_root() .. "/azure-cli")
-- Data-provider argv (python azure-cli.py) every PR-action/prefetch job in
-- this dashboard runs, replacing review-pr.sh/$BASH entirely.
local PROVIDER_CMD = CONFIG.provider_cmd()
-- Local clone used by the reviewer for diffs (per-repo mapping is a later step).
local REPO_PATH = env.AZVICLI_REPO_PATH or ""
-- Normalise to a Windows path both git.exe and vim accept ("/c/x" -> "c:/x").
local REPO_PATH_WIN = REPO_PATH:gsub("^/([a-zA-Z])/", "%1:/")

-- Section order and friendly titles. "Mentions" isn't one of these - it's a
-- virtual section built in render() from every PR with mentionThreads > 0,
-- rendered in addition to (not instead of) that PR's normal state section.
local SECTIONS = {
  { key = "Actionable", title = "Actionable" },
  { key = "Waiting",    title = "Waiting for author" },
  { key = "SignedOff",  title = "Signed off" },
  { key = "Drafts",     title = "Drafts" },
  { key = "Created",    title = "Created by me" },
}

-- Every section key that can be collapsed, in display order - the five
-- SECTIONS above plus the virtual "Mentions" section. Shared by
-- collapse_all and the setup({collapsed_sections=...}) seed below.
local ALL_SECTION_KEYS = { "Mentions" }
for _, sec in ipairs(SECTIONS) do ALL_SECTION_KEYS[#ALL_SECTION_KEYS + 1] = sec.key end

local prs = {}              -- all parsed PR records
local row_pr = {}           -- buffer line (1-based) -> pr record (nil for headers)
-- Which section (a key from ALL_SECTION_KEYS above) a PR/header row belongs
-- to - row_pr_key for a PR row, row_header_key for that section's own
-- header row - so toggle_section (za, below) knows what to flip from a
-- cursor on either kind of row, and render()'s cursor-restore can land on a
-- section's header when the PR that had the cursor is now hidden under a
-- collapsed one.
local row_pr_key = {}
local row_header_key = {}
local buf, win
local set_winbar  -- rebuilds the winbar; assigned once the fetching-state bookkeeping it reads exists (below). render() calls it on every rebuild.

-- List cache shared across dashboard swaps (W/P): {prs, ts}. Lets re-entry
-- render instantly and only refetch from ADO when the cache is stale.
local LIST_TTL = 30

-- True while a list fetch is in flight (drives the [refreshing…] winbar tag).
local list_inflight = false

-- Case-insensitive text filter applied in render() (empty = show all).
-- Kept in STATE so it survives a W/P dashboard swap like the collapsed
-- sections do.
local filter = STATE.dashboard_filter or ""

-- Which sections are collapsed right now: key (from ALL_SECTION_KEYS) ->
-- true. Shared across W/P dashboard swaps the same way STATE.warm is (see
-- below) - re-entering the dashboard keeps whatever the user toggled with
-- za/zR/zM instead of resetting to setup({collapsed_sections=...})'s
-- default every time; that default only seeds the very first render of the
-- session (or the first after this table was ever created).
STATE.dashboard_collapsed = STATE.dashboard_collapsed or (function()
  local set = {}
  for _, key in ipairs(CONFIG.get().collapsed_sections or {}) do set[key] = true end
  return set
end)()
local collapsed = STATE.dashboard_collapsed

-- The two headline counts render() maintains for set_winbar's context
-- segment ("N actionable", "M mentions") - post-filter, so they always
-- match what's actually on screen right now rather than the full list.
local actionable_count, mention_count = 0, 0
-- True when render()'s last UI.layout call had to drop a column to fit the
-- window - drives the "[narrow]" winbar tag (see set_winbar).
local layout_narrow = false

-- Column spec for UI.layout (lua/azure-cli/ui.lua): the id/badge/build
-- columns stay genuinely fixed-width (never scale, never drop - see
-- add_pr_row), these five scale with the window. min/ideal mirror this
-- table's old hard-coded widths (title 36, repo 14, author 10, reviewer
-- summary 20); title and reviewer summary are `grow` columns so a wide
-- terminal doesn't leave a blank margin, and the drop order when even the
-- minimums don't fit is reviewer summary, then updated-human, then author -
-- repo and title are never dropped, just shrunk to their min.
local SCALING_COLUMNS = {
  { key = "title", min = 20, ideal = 36, weight = 3, grow = true },
  { key = "repo", min = 8, ideal = 14, weight = 1 },
  { key = "author", min = 6, ideal = 10, weight = 1, priority = 3 },
  { key = "reviewer", min = 0, ideal = 20, weight = 2, grow = true, priority = 1 },
  { key = "updated", min = 8, ideal = 12, weight = 1, priority = 2 },
}
-- Display cells every fixed segment of a row costs, outside the five
-- scaling columns above: "  " + unread(1) + " " + sync(1) + " " + mention(1)
-- + " " + id(7) + " " + build(4) + " " + conflict(1) + " " + autocomplete(1)
-- + " " (=25, before the title column) + the " " gap after title + the " "
-- gap after repo + (" " + vote(7) + " " + threads(7) + " " = 17, between
-- author and reviewer summary) + the "  " gap before updated-human (=2).
-- Recompute this if add_pr_row's fixed segments ever change.
local ROW_FIXED_WIDTH = 25 + 1 + 1 + 17 + 2
local function pr_matches(pr, q)
  if tostring(pr.id or ""):find(q, 1, true) then return true end
  local hay = ((pr.title or "") .. " " .. (pr.repo or "") .. " " .. (pr.author or "")):lower()
  return hay:find(q, 1, true) ~= nil
end

-- Ordered { action, hint } pairs for the `?` popup's key lines below - real
-- keys resolved through KEYS (lua/azure-cli/keys.lua) every time, never
-- hard-coded, so a configured override or an unbound (false) action is
-- reflected here too instead of just at the vim.keymap.set call sites. No
-- longer used to build the winbar itself (see set_winbar below, and
-- lua/azure-cli/ui.lua's UI.winbar) - the winbar shows context instead of a
-- key legend now, since `?` already has every key.
-- Strings between the pairs name the group that follows in the `?` popup
-- (see keys.lua's M.help_lines).
local DASHBOARD_ACTIONS = {
  "Navigate",
  { "open", "open" }, { "first_pr", "first PR" }, { "last_pr", "last PR" }, { "filter", "filter" },
  { "toggle_section", "toggle section" }, { "expand_all", "expand all" }, { "collapse_all", "collapse all" },
  "This PR",
  { "description", "description" }, { "copy_link", "copy" }, { "browser", "browser" }, { "open_build", "build" },
  { "vote", "vote" }, { "complete", "complete" }, { "auto_complete", "auto-complete" },
  { "requeue_build", "re-queue build" },
  "Session",
  { "refresh", "refresh" }, { "workitems", "work items" }, { "toasts", "notifications" }, { "config", "config" },
  { "quit", "quit" }, { "help", "help" },
}

local function notify(msg, level)
  require("azure-cli.notify").flash(msg, level or vim.log.levels.INFO)
end

-- Persistent "seen" snapshot per PR (nvim's per-user data dir, so it survives
-- restarts): { totalThreads, myActiveThreads, mentionTotal } as of the last
-- time the PR was opened. Drives the "●" unread badge next to a PR's row
-- in the list, and is only advanced when the PR is actually opened (open_pr
-- below) - not on every poll - so the badge persists until you've actually
-- gone and looked. mentionTotal is nil-safe throughout: a record saved before
-- this field existed just treats it as -1 (never unread from mentions alone).
local SEEN_FILE = vim.fn.stdpath("data") .. "/azure-cli-seen.json"
-- Pre-rename data file (this plugin was once called pr-dash); migrated into
-- SEEN_FILE below (migrate.lua's M.ensure) the first time it's needed, then
-- left alone untouched.
local OLD_SEEN_FILE = vim.fn.stdpath("data") .. "/pr-dash-seen.json"
local function load_seen()
  require("azure-cli.migrate").ensure(OLD_SEEN_FILE, SEEN_FILE)
  if vim.fn.filereadable(SEEN_FILE) ~= 1 then return { prs = {} } end
  local ok, lines = pcall(vim.fn.readfile, SEEN_FILE)
  if not ok then return { prs = {} } end
  local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok2 and type(decoded) == "table" and type(decoded.prs) == "table" then return decoded end
  return { prs = {} }
end
local seen = load_seen()
local function save_seen()
  pcall(vim.fn.writefile, { vim.json.encode(seen) }, SEEN_FILE)
end

-- Snapshot of pr's counts as of "now", in the shape stored in seen.prs.
local function pr_snapshot(pr)
  return {
    totalThreads = pr.totalThreads or -1,
    myActiveThreads = pr.myActiveThreads or -1,
    mentionTotal = pr.mentionTotal or -1,
  }
end

-- Records pr's current thread/mention counts as "seen" (called when the PR is opened).
local function mark_pr_seen(pr)
  seen.prs[tostring(pr.id)] = pr_snapshot(pr)
  save_seen()
end

-- True when pr has comment or mention activity beyond what was recorded the
-- last time it was opened: for a PR I authored, growth in its total comment
-- count; for any other PR, growth in myActiveThreads (threads I've
-- participated in) so a reply to one of my comments on someone else's PR
-- still lights up; either way, growth in mentionTotal (someone @-mentioned me
-- since I last opened it) also counts, since that can happen on a PR I've
-- neither authored nor replied on. A PR with no seen record yet (never
-- opened, and not seeded below) is never unread.
local function pr_is_unread(pr)
  local rec = seen.prs[tostring(pr.id)]
  if not rec then return false end
  local threads_grew
  if pr.state == "Created" then
    threads_grew = (pr.totalThreads or -1) >= 0 and pr.totalThreads > (rec.totalThreads or 0)
  else
    threads_grew = (pr.myActiveThreads or -1) >= 0 and pr.myActiveThreads > (rec.myActiveThreads or 0)
  end
  local mentions_grew = (pr.mentionTotal or -1) >= 0 and pr.mentionTotal > (rec.mentionTotal or 0)
  return threads_grew or mentions_grew
end

-- Seeds a "seen" record at current counts for any PR that doesn't have one
-- yet (first time it's ever appeared in a list fetch on this machine), so the
-- unread badge only ever reacts to activity from this point forward instead
-- of flagging every pre-existing comment the first time this feature runs.
local function seed_unseen(fresh_prs)
  local dirty = false
  for _, pr in ipairs(fresh_prs) do
    if not seen.prs[tostring(pr.id)] then
      seen.prs[tostring(pr.id)] = pr_snapshot(pr)
      dirty = true
    end
  end
  if dirty then save_seen() end
end

-- Resolve azure-cli.yml's path - delegates to config.lua's M.config_path()
-- (AZVICLI_CONFIG override, else the platform default) so gO always opens
-- exactly what the provider itself would read.
local function config_path()
  return CONFIG.config_path()
end

-- Open azure-cli.yml (accounts/PAT/clones_dir config) in a new tab for quick
-- editing, so you don't have to go dig it up manually to add an account or
-- tweak hide_ancient/clones_dir.
local function open_config_file()
  local path = config_path()
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "yaml"
  if vim.fn.filereadable(path) == 0 then
    notify("azure-cli.yml doesn't exist yet — save this buffer (:w) to create it at " .. path, vim.log.levels.WARN)
  end
end

-- Truncate a string to n display cells, adding an ellipsis when cut. n <= 0
-- (reachable now that a scaled column, e.g. reviewer summary, can land at
-- width 0 - see UI.layout/SCALING_COLUMNS above) always renders as "",
-- rather than s:sub(1, n - 1) misbehaving at n == 0 (Lua's sub(1, -1) means
-- "to the end", not "nothing").
local fit = UI.fit

-- Normalise a Windows-ish clones_dir from the config ("C:\Users\..\repos" or
-- "/c/Users/.../repos") to the same "C:/Users/..." form REPO_PATH_WIN uses.
local function to_win_path(p)
  p = (p or ""):gsub("\\", "/")
  return p:gsub("^/([a-zA-Z])/", "%1:/")
end

-- True when `path` looks like an existing git clone.
local function is_cloned(path)
  return path ~= "" and vim.fn.isdirectory(path .. "/.git") == 1
end

-- Resolve the local clone path for a PR. Prefers the account's configured
-- clones_dir (pr.clonesDir, from azure-cli.yml) — <clones_dir>/<repo> — which
-- works even when that repo hasn't been cloned yet (ensure_cloned below will
-- offer to clone it there). Falls back to inferring a sibling directory next
-- to the configured AZVICLI_REPO_PATH when clones_dir isn't set, for backward
-- compatibility; that heuristic only ever returns existing clones.
local function clone_for(pr)
  local clones_dir = to_win_path(pr.clonesDir)
  if clones_dir ~= "" and pr.repo and pr.repo ~= "" then
    return clones_dir .. "/" .. pr.repo
  end

  if REPO_PATH_WIN == "" then
    return ""
  end
  local repo = pr.repo or ""
  if repo ~= "" then
    local base = REPO_PATH_WIN:gsub("[/\\][^/\\]+[/\\]?$", "")
    local candidate = base .. "/" .. repo
    if is_cloned(candidate) then
      return candidate
    end
  end
  return REPO_PATH_WIN
end

-- Clone `pr`'s repo to `path` if it isn't already there (requires clones_dir
-- to be configured in azure-cli.yml so we know where to put it, and cloneUrl
-- from the PR record). Calls cb(true) once `path` is a usable clone, or
-- cb(false) if cloning wasn't possible/failed (caller should fall back to
-- notifying the user rather than trying to open a nonexistent repo).
local function ensure_cloned(pr, path, cb)
  if is_cloned(path) then
    cb(true)
    return
  end
  if to_win_path(pr.clonesDir) == "" then
    notify("PR #" .. tostring(pr.id) .. "'s repo isn't cloned, and no clones_dir is set in azure-cli.yml "
      .. "to auto-clone it. Add e.g. `clones_dir: C:\\Users\\you\\source\\repos` to your account in "
      .. "%APPDATA%\\azure-cli.yml, or clone " .. (pr.repo or "the repo") .. " manually.", vim.log.levels.ERROR)
    cb(false)
    return
  end
  if path == "" or not pr.cloneUrl or pr.cloneUrl == "" then
    notify("PR #" .. tostring(pr.id) .. "'s repo can't be auto-cloned (missing clone URL from the data source).",
      vim.log.levels.ERROR)
    cb(false)
    return
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  notify("Cloning " .. (pr.repo or "repo") .. " to " .. path .. " … this may take a while.")
  vim.fn.jobstart({ "git", "clone", pr.cloneUrl, path }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = function(_, code)
      if code == 0 and is_cloned(path) then
        notify("Cloned " .. (pr.repo or "repo") .. " to " .. path .. ".")
        cb(true)
      else
        notify("Clone failed for " .. (pr.repo or "repo") .. " (exit " .. code .. "). "
          .. "Check the URL/credentials, or clone it manually to " .. path .. ".", vim.log.levels.ERROR)
        cb(false)
      end
    end,
  })
end

-- Build the environment table the data provider needs for a given PR record.
local function pr_env(pr)
  local e = {
    AZVICLI_PR = tostring(pr.id),
    AZVICLI_REPO = pr.repo or "",
    AZVICLI_PROJECT = pr.project or "",
    AZVICLI_ORG = pr.org or "",
    AZVICLI_SOURCE = pr.source or "",
    AZVICLI_TARGET = pr.target or "",
    AZVICLI_EXE = EXE,
  }
  local cp = clone_for(pr)
  if cp ~= "" then
    e.AZVICLI_REPO_PATH = cp
  end
  return e
end

-- Render the parsed PRs into the buffer, grouped by section.

-- Highlight palette (shared visual language with the work-items dashboard).
-- Every group links to a standard highlight group with `default = true`, so
-- a real colorscheme (plugin mode) colours the dashboard automatically and
-- consistently with the rest of the editor; `default = true` means any of
-- these can still be overridden (by the user's own :hi, or - the case this
-- tool actually uses - standalone/init.lua's non-default catppuccin-mocha
-- palette, applied after this, which then always wins).
local ns = vim.api.nvim_create_namespace("azure_cli_dashboard")
local function define_hl()
  local function hl(name, o) vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, o)) end
  hl("AzureCliHeader", { link = "Title" })
  hl("AzureCliId", { link = "Identifier" })
  hl("AzureCliRepo", { link = "Directory" })
  hl("AzureCliAuthor", { link = "Comment" })
  hl("AzureCliVote", { link = "Special" })
  hl("AzureCliThread", { link = "WarningMsg" })
  hl("AzureCliThreadDone", { link = "String" })
  hl("AzureCliAged", { link = "Comment" })
  hl("AzureCliUpdated", { link = "Comment" })
  hl("AzureCliBuildOk", { link = "String" })
  hl("AzureCliBuildFail", { link = "ErrorMsg" })
  hl("AzureCliBuildRun", { link = "WarningMsg" })
  hl("AzureCliBuildExpired", { link = "WarningMsg" })
  hl("AzureCliConflict", { link = "ErrorMsg" })
  hl("AzureCliAutoComplete", { link = "String" })
  hl("AzureCliUnread", { link = "ErrorMsg" })
  hl("AzureCliMention", { link = "Special" })
  hl("AzureCliSyncing", { link = "Title" })
  hl("AzureCliReady", { link = "Comment" })
  hl("AzureCliBorder", { link = "FloatBorder" })
  hl("AzureCliColHeader", { link = "Comment" })
  hl("AzureCliMe", { link = "Title" })
end
define_hl()

-- Parse a "o"-format ISO timestamp to an epoch for sorting/age checks.
local function iso_epoch(iso)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return 0 end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

-- Build-validation result as a compact glyph + highlight group (blank when none).
local function build_glyph(status)
  if status == "succeeded" then return "\u{2713}", "AzureCliBuildOk" end
  if status == "failed" then return "\u{2717}", "AzureCliBuildFail" end
  if status == "expired" then return "\u{21BB}", "AzureCliBuildExpired" end
  if status == "running" then return "\u{25CF}", "AzureCliBuildRun" end
  return "", nil
end

-- Build-validation label for the PR list: the glyph, plus the build's
-- position in the agent queue (e.g. "●3") when it's still waiting for an
-- agent rather than actually running yet.
local function build_label(pr)
  local glyph, group = build_glyph(pr.buildStatus)
  if pr.buildStatus == "running" and type(pr.queuePosition) == "number" and pr.queuePosition > 0 then
    return glyph .. tostring(pr.queuePosition), group
  end
  return glyph, group
end

-- Short author label: surname from "Surname, Given" or the last word.
local surname = PRS.surname

-- Wrap `lines` in a rounded border box and centre it in `win`, both
-- horizontally and vertically. `spans` are highlight ranges keyed by 0-based
-- line + byte columns *relative to the unwrapped `lines`*; they (and any
-- 1-based line-number maps in `line_maps`, e.g. row->PR) get shifted to match
-- the new, boxed/padded coordinates. Returns the final lines, the shifted
-- spans (with two extra "AzureCliBorder" spans for the box edges appended), the
-- row offset applied, and the column (byte offset) where real content
-- starts on each row — callers need that instead of 0 when placing the
-- cursor, since column 0 now sits in the blank margin left of the border.
local function box_and_center(lines, spans, win)
  local content_width = 0
  for _, l in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  content_width = math.max(content_width, 1)
  local box_width = content_width + 4
  local win_width = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)) or vim.o.columns
  local win_height = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_height(win)) or vim.o.lines
  local pad_h = math.max(0, math.floor((win_width - box_width) / 2))
  local hprefix = string.rep(" ", pad_h)
  local col_offset = pad_h + #"│ "  -- hprefix + "│ " (│ is a 3-byte UTF-8 char, not 1)

  local boxed = {}
  boxed[#boxed + 1] = hprefix .. "╭" .. string.rep("─", box_width - 2) .. "╮"
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    boxed[#boxed + 1] = hprefix .. "│ " .. l .. string.rep(" ", content_width - w) .. " │"
  end
  boxed[#boxed + 1] = hprefix .. "╰" .. string.rep("─", box_width - 2) .. "╯"

  local pad_v = math.max(0, math.floor((win_height - #boxed) / 2))
  local final = {}
  for _ = 1, pad_v do final[#final + 1] = "" end
  local top_line0 = #final       -- 0-based line of the top border
  for _, l in ipairs(boxed) do final[#final + 1] = l end
  local bottom_line0 = #final - 1  -- 0-based line of the bottom border
  local row_offset = pad_v + 1     -- add to an old 1-based `lines` index to get the new one

  local shifted = {}
  for _, sp in ipairs(spans) do
    shifted[#shifted + 1] = { line = sp.line + row_offset, s = sp.s + col_offset, e = sp.e + col_offset, hl = sp.hl }
  end
  shifted[#shifted + 1] = { line = top_line0, s = 0, e = -1, hl = "AzureCliBorder" }
  shifted[#shifted + 1] = { line = bottom_line0, s = 0, e = -1, hl = "AzureCliBorder" }

  return final, shifted, row_offset, col_offset
end

-- Sync-state glyph for a row: "\u{21E3}" while this PR's branches or content
-- are being fetched in the background, "\u{25C6}" once everything the
-- reviewer needs is cached (opening it is instant), blank otherwise. Chosen
-- to stay clear of the build column's own \u{2713}/\u{2717}/\u{21BB}/\u{25CF}.
-- Assigned once the warm/prefetch bookkeeping it reads exists (below).
local pr_sync_state

-- Appends one PR's row to `lines`/`spans`/`row_pr`. Used for both a PR's
-- normal state section and the Mentions section below - the same record can
-- end up on two rows, which is fine since row_pr just maps line->record and
-- every consumer (current_pr, cursor-restore, mark_pr_seen) keys off the
-- record/its id rather than the row.
-- `widths` (from UI.layout, computed once per render() - see COLUMN_SPEC/
-- ROW_FIXED_WIDTH below) gives this row's title/repo/author/reviewer/updated
-- column widths; a column UI.layout dropped for a narrow window has no entry
-- in `widths` and its segment (plus the single gap in front of it) is
-- skipped entirely rather than rendered at width 0 - repo and title are
-- never dropped (id/badges are the only columns kept truly fixed, per the
-- column spec), so `widths.title`/`widths.repo` always exist.
local function add_pr_row(lines, spans, row_pr, pr, now, widths)
  local parts, col = {}, 0
  local lnum = #lines  -- 0-based index this row will occupy once appended
  local function seg(text, group)
    local start = col
    parts[#parts + 1] = text
    col = col + #text
    if group and text:gsub("%s", "") ~= "" then
      spans[#spans + 1] = { line = lnum, s = start, e = col, hl = group }
    end
  end

  seg("  ")
  seg(fit(pr_is_unread(pr) and "\u{25CF}" or "", 1), "AzureCliUnread")
  seg(" ")
  local sync = pr_sync_state and pr_sync_state(pr)
  seg(fit(sync == "syncing" and "\u{21E3}" or (sync == "ready" and "\u{25C6}" or ""), 1),
    sync == "syncing" and "AzureCliSyncing" or "AzureCliReady")
  seg(" ")
  seg(fit((pr.mentionThreads or 0) > 0 and "@" or "", 1), "AzureCliMention")
  seg(" ")
  seg(fit("#" .. tostring(pr.id), 7), "AzureCliId")
  seg(" ")
  local bg, bgrp = build_label(pr)
  seg(fit(bg, 4), bgrp)
  seg(" ")
  seg(fit(pr.mergeConflict and "\u{26A0}" or "", 1), "AzureCliConflict")
  seg(" ")
  seg(fit(pr.autoComplete and "A" or "", 1), "AzureCliAutoComplete")
  seg(" ")
  seg(fit(pr.title, widths.title))
  seg(" ")
  seg(fit(pr.repo or "", widths.repo), "AzureCliRepo")
  if widths.author then
    seg(" ")
    seg(fit(surname(pr.author), widths.author), "AzureCliAuthor")
  end
  seg(" ")
  seg(fit(pr.voteRatio or "", 7), "AzureCliVote")
  seg(" ")
  local thr, tgrp = "", "AzureCliThread"
  if type(pr.totalThreads) == "number" and pr.totalThreads > 0 then
    local total = pr.totalThreads
    local active = (type(pr.activeThreads) == "number" and pr.activeThreads >= 0) and pr.activeThreads or 0
    local closed = (type(pr.closedThreads) == "number" and pr.closedThreads >= 0)
      and pr.closedThreads or math.max(0, total - active)
    thr = closed .. "/" .. total
    tgrp = (closed >= total) and "AzureCliThreadDone" or "AzureCliThread"
  end
  seg(fit(thr, 7), tgrp)
  if widths.reviewer then
    seg(" ")
    local summary = pr.reviewerSummary or ""
    local start = col
    seg(fit(summary, widths.reviewer))
    -- Pick myself out of the reviewer summary ("✓Doe ·Roe"): the answer to
    -- "have I voted on this one?" shouldn't need knowing my own surname.
    local me = surname(pr.myName or "")
    if me ~= "" then
      local at = summary:find(me, 1, true)
      if at and at + #me - 1 <= #fit(summary, widths.reviewer) then
        local s, e = at, at + #me - 1
        -- Take the vote glyph just before the name along (one UTF-8 char:
        -- step back over continuation bytes to its lead byte).
        local gs = at - 1
        while gs > 1 and summary:byte(gs) >= 0x80 and summary:byte(gs) < 0xC0 do gs = gs - 1 end
        if gs >= 1 and summary:byte(gs) ~= 0x20 then s = gs end
        spans[#spans + 1] = { line = lnum, s = start + s - 1, e = start + e, hl = "AzureCliMe" }
      end
    end
  end
  if widths.updated then
    seg("  ")
    local aged = (now - iso_epoch(pr.updatedIso)) > CONFIG.get().timing.aged_days * 86400
    seg(fit(pr.updatedHuman or "", widths.updated), aged and "AzureCliAged" or "AzureCliUpdated")
  end

  lines[#lines + 1] = table.concat(parts)
  row_pr[#lines] = pr
end

-- Appends a section header ("── title (n) ──", or "── title (n) ──
-- (collapsed)" with no rows below it when `key` is in `collapsed`) plus one
-- row per item, most recently updated first, unless collapsed. Shared by
-- the Mentions virtual section and the normal per-state sections in
-- render(). `key` is one of ALL_SECTION_KEYS - what toggle_section (za)
-- flips and row_header_key/row_pr_key (see their own declarations above)
-- record per row.
-- The column header row above the first section, laid out with the same
-- fixed/scaling widths add_pr_row uses so it lines up with every row.
local function add_header_row(lines, spans, widths)
  local parts = { "        ", fit("id", 7), " ", fit("ci", 4), " ", " ", " ", " ", " ", fit("title", widths.title),
    " ", fit("repo", widths.repo) }
  if widths.author then parts[#parts + 1] = " " .. fit("author", widths.author) end
  parts[#parts + 1] = " " .. fit("votes", 7) .. " " .. fit("threads", 7)
  if widths.reviewer then parts[#parts + 1] = " " .. fit("reviewers", widths.reviewer) end
  if widths.updated then parts[#parts + 1] = "  " .. fit("updated", widths.updated) end
  local text = table.concat(parts)
  lines[#lines + 1] = text
  row_pr[#lines] = nil
  spans[#spans + 1] = { line = #lines - 1, s = 0, e = #text, hl = "AzureCliColHeader" }
end

local function add_section(lines, spans, row_pr, key, title, items, now, widths)
  table.sort(items, function(a, b) return iso_epoch(a.updatedIso) > iso_epoch(b.updatedIso) end)

  if #lines > 0 then
    lines[#lines + 1] = ""
    row_pr[#lines] = nil
  end
  local is_collapsed = collapsed[key]
  local hstr = "── " .. title .. " (" .. #items .. ") ──" .. (is_collapsed and " (collapsed)" or "")
  lines[#lines + 1] = hstr
  row_pr[#lines] = nil
  row_header_key[#lines] = key
  spans[#spans + 1] = { line = #lines - 1, s = 0, e = #hstr, hl = "AzureCliHeader" }

  if is_collapsed then return end
  for _, pr in ipairs(items) do
    add_pr_row(lines, spans, row_pr, pr, now, widths)
    row_pr_key[#lines] = key
  end
end

local function render()
  -- Remember which PR the cursor is on (by id, not raw row number) before we
  -- rebuild everything below, since the box's vertical centring means row
  -- numbers shift whenever the window is resized or the row count changes.
  -- Also remember its section (or, if the cursor was already on a header,
  -- that header's own section) so the fallback below can land back on the
  -- section header when a section collapses out from under the cursor
  -- (its own toggle via za, or collapse_all/zM) instead of jumping
  -- somewhere else in the list.
  local prev_pr_id, prev_key
  if win and vim.api.nvim_win_is_valid(win) then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local prev_pr = row_pr[cur[1]]
      if prev_pr then
        prev_pr_id = prev_pr.id
        prev_key = row_pr_key[cur[1]]
      else
        prev_key = row_header_key[cur[1]]
      end
    end
  end

  local lines = {}
  local spans = {}  -- { line = 0-based, s = bytecol, e = bytecol, hl = group }
  row_pr = {}
  row_pr_key = {}
  row_header_key = {}

  local by_state = {}
  local flc = filter:lower()
  for _, pr in ipairs(prs) do
    if flc == "" or pr_matches(pr, flc) then
      by_state[pr.state] = by_state[pr.state] or {}
      table.insert(by_state[pr.state], pr)
    end
  end

  local now = os.time()

  -- Solve the scaling columns' widths against the window once per render
  -- (see SCALING_COLUMNS/ROW_FIXED_WIDTH above and lua/azure-cli/ui.lua's
  -- UI.layout) and hand the result to every row this render builds.
  local win_width = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)) or vim.o.columns
  local layout = UI.layout(SCALING_COLUMNS, math.max(0, win_width - 8 - ROW_FIXED_WIDTH))
  layout_narrow = layout.narrow
  local widths = layout.widths

  -- Mentions: a virtual section, not one of the SECTIONS/by_state groups -
  -- every PR (after the text filter) with an active thread mentioning me,
  -- most recently updated first, in addition to its normal state section
  -- below (add_pr_row/row_pr tolerate the same record rendering twice).
  local mention_items = {}
  for _, pr in ipairs(prs) do
    if (flc == "" or pr_matches(pr, flc)) and (pr.mentionThreads or 0) > 0 then
      mention_items[#mention_items + 1] = pr
    end
  end
  if #prs > 0 then add_header_row(lines, spans, widths) end
  if #mention_items > 0 then
    add_section(lines, spans, row_pr, "Mentions", "Mentions", mention_items, now, widths)
  end

  for _, sec in ipairs(SECTIONS) do
    local items = by_state[sec.key]
    if items and #items > 0 then
      add_section(lines, spans, row_pr, sec.key, sec.title, items, now, widths)
    end
  end

  -- Feeds the winbar's "N actionable · M mentions" context segment (see
  -- set_winbar) - updated on every render so it always matches the
  -- post-filter list actually on screen.
  actionable_count = by_state["Actionable"] and #by_state["Actionable"] or 0
  mention_count = #mention_items
  set_winbar()

  if #lines == 0 then
    lines = { filter ~= "" and ('No PRs match "' .. filter .. '".') or "No pull requests." }
  end

  -- Box the table and centre it in the window (both axes); shift row_pr's
  -- (and row_pr_key's/row_header_key's) line->value maps by the same row
  -- offset so <CR>/gy/za/etc. still hit the right row.
  local row_offset, col_offset
  lines, spans, row_offset, col_offset = box_and_center(lines, spans, win)
  local shifted_row_pr, shifted_row_pr_key, shifted_row_header_key = {}, {}, {}
  for ln, pr in pairs(row_pr) do
    shifted_row_pr[ln + row_offset] = pr
  end
  for ln, key in pairs(row_pr_key) do
    shifted_row_pr_key[ln + row_offset] = key
  end
  for ln, key in pairs(row_header_key) do
    shifted_row_header_key[ln + row_offset] = key
  end
  row_pr = shifted_row_pr
  row_pr_key = shifted_row_pr_key
  row_header_key = shifted_row_header_key

  -- Change-aware: skip the buffer write when nothing changed, so background
  -- refreshes never flicker or move the cursor.
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, sp in ipairs(spans) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, sp.hl, sp.line, sp.s, sp.e)
  end

  -- The box's vertical/horizontal centring means row numbers move around
  -- whenever the window is resized or the row count changes (blank-padding
  -- rows above/below shift everything). Re-find the same PR (by id) the
  -- cursor was on before this render and land there again; fall back to its
  -- section's header when that PR's row is gone because the section just
  -- collapsed (za/zM) rather than because it dropped out of the list some
  -- other way, then to the first PR row, then to the first header row (every
  -- section collapsed), or just inside the box if the list is empty. A PR
  -- with an active mention can now occupy two rows (its Mentions row and its
  -- normal state row); either match is a fine place to land, so the first
  -- one found wins.
  if win and vim.api.nvim_win_is_valid(win) then
    local target
    if prev_pr_id then
      for ln, pr in pairs(row_pr) do
        if pr.id == prev_pr_id then target = ln; break end
      end
    end
    if not target and prev_key then
      for ln, key in pairs(row_header_key) do
        if key == prev_key then target = ln; break end
      end
    end
    if not target then
      for ln in pairs(row_pr) do
        if not target or ln < target then target = ln end
      end
    end
    if not target then
      for ln in pairs(row_header_key) do
        if not target or ln < target then target = ln end
      end
    end
    pcall(vim.api.nvim_win_set_cursor, win, { target or (row_offset + 1), col_offset })
  end
end

-- The PR on the current cursor line, or nil on a header/blank line.
local function current_pr()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return row_pr[line]
end

-- Copy the web link of the PR under the cursor to the system clipboard.
local function yank_link()
  local pr = current_pr()
  if not pr or not pr.url or pr.url == "" then return end
  vim.fn.setreg('"', pr.url)
  pcall(vim.fn.setreg, "+", pr.url)
  notify("Copied link to #" .. tostring(pr.id) .. ": " .. pr.url)
end

-- Open the PR under the cursor in the default web browser.
local function open_browser()
  local pr = current_pr()
  if not pr or not pr.url or pr.url == "" then return end
  local ok = pcall(function() vim.ui.open(pr.url) end)
  if not ok then
    vim.fn.jobstart({ "cmd", "/c", "start", "", pr.url })
  end
  notify("Opening #" .. tostring(pr.id) .. " in browser…")
end

-- Open the build backing the PR's reported build status (see gd's "Build:"
-- line) in the default web browser. Nil-safe: older cached records from
-- before this field existed just report "no build".
local function open_build()
  local pr = current_pr()
  if not pr then return end
  if not pr.buildUrl or pr.buildUrl == "" then
    notify("No build for #" .. tostring(pr.id) .. ".")
    return
  end
  local ok = pcall(function() vim.ui.open(pr.buildUrl) end)
  if not ok then
    vim.fn.jobstart({ "cmd", "/c", "start", "", pr.buildUrl })
  end
  notify("Opening build for #" .. tostring(pr.id) .. " in browser…")
end

-- Open a scratch floating window at the cursor showing the given text lines.
local function open_float(lines, opts)
  return UI.open_float(lines, opts)
end

-- Show the title and description of the PR under the cursor in a float,
-- plus its build status and non-build branch policies when known. Nil-safe
-- throughout: older cached records from before these fields existed just
-- omit the sections.
local function show_description()
  local pr = current_pr()
  if not pr then return end
  local title = pr.title or ""
  local lines = { "PR #" .. tostring(pr.id) .. (title ~= "" and ("  " .. title) or ""), "" }
  if pr.source or pr.target then
    lines[#lines + 1] = "  " .. (pr.source or "?") .. " \u{2192} " .. (pr.target or "?") .. "   " .. (pr.repo or "")
  end
  lines[#lines + 1] = "  by " .. (pr.author or "?") .. "   updated " .. (pr.updatedHuman or "?")
    .. ((pr.updatedIso and pr.updatedIso ~= "") and ("  (" .. pr.updatedIso:sub(1, 16):gsub("T", " ") .. ")") or "")
  if pr.isDraft then lines[#lines + 1] = "  draft" end
  if pr.mergeConflict then lines[#lines + 1] = "  \u{26A0} merge conflict" end
  if type(pr.reviewers) == "table" and #pr.reviewers > 0 then
    local parts = {}
    for _, r in ipairs(pr.reviewers) do
      local v = tonumber(r.vote) or 0
      local g = v == 10 and "\u{2713}" or v == 5 and "\u{2713}~" or v == -5 and "~" or v == -10 and "\u{2717}" or "\u{00B7}"
      parts[#parts + 1] = g .. " " .. (r.name or "?") .. ((r.name == pr.myName) and " (me)" or "")
    end
    lines[#lines + 1] = "  Reviewers: " .. table.concat(parts, "   ")
  end
  if pr.url and pr.url ~= "" then lines[#lines + 1] = "  " .. pr.url end
  lines[#lines + 1] = ""
  local desc = pr.description or ""
  if vim.trim(desc) == "" then
    table.insert(lines, "(no description)")
  else
    desc = desc:gsub("\r\n", "\n"):gsub("\r", "\n")
    for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do
      table.insert(lines, l)
    end
  end

  if pr.buildStatus and pr.buildStatus ~= "" and pr.buildStatus ~= "none" then
    table.insert(lines, "")
    local build_line = "Build: " .. pr.buildStatus
    if pr.buildUrl and pr.buildUrl ~= "" then
      build_line = build_line .. "  " .. pr.buildUrl
    end
    table.insert(lines, build_line)
  end

  if type(pr.policies) == "table" and #pr.policies > 0 then
    table.insert(lines, "")
    table.insert(lines, "Policies:")
    for _, p in ipairs(pr.policies) do
      local mark = "\u{2026}"
      if p.status == "approved" then
        mark = "\u{2713}"
      elseif p.status == "rejected" or p.status == "broken" then
        mark = "\u{2717}"
      end
      table.insert(lines, "  " .. mark .. " " .. (p.name or ""))
    end
    if type(pr.missingReviewers) == "table" and #pr.missingReviewers > 0 then
      table.insert(lines, "  Waiting on: " .. table.concat(pr.missingReviewers, ", "))
    end
  end

  open_float(lines)
end

-- Show this dashboard's keys and the row/build badge legend in a float,
-- Rendered from KEYS (lua/azure-cli/keys.lua) plus DASHBOARD_ACTIONS' own
-- description text below, so it never drifts from the keys actually bound
-- above - see keys.lua's M.line.
local DASHBOARD_HELP_DESCS = {
  open = "open the PR under the cursor in the reviewer",
  description = "show the description (build status and policies too)",
  copy_link = "copy the PR link",
  browser = "open in the browser",
  open_build = "open the PR's build in the browser",
  filter = "filter as you type by id, title, repo or author (Esc clears)",
  vote = "vote",
  complete = "complete (merge)",
  auto_complete = "toggle auto-complete",
  requeue_build = "re-queue build validation",
  toggle_section = "toggle collapse on the section header under the cursor",
  expand_all = "expand every section",
  collapse_all = "collapse every section",
  first_pr = "jump to the first PR",
  last_pr = "jump to the last PR",
  toasts = "toggle desktop notifications for this session",
  config = "open the config file",
  refresh = "refresh",
  workitems = "switch to the work-items dashboard",
  quit = "quit",
  help = "this help",
}
local function show_help()
  local table_ = {}
  for _, a in ipairs(DASHBOARD_ACTIONS) do
    if type(a) == "string" then
      table_[#table_ + 1] = a
    else
      table_[#table_ + 1] = { a[1], DASHBOARD_HELP_DESCS[a[1]] or a[2] }
    end
  end
  local now = {}
  if filter ~= "" then now[#now + 1] = "[filter: " .. filter .. "]" end
  local closed = {}
  for _, key in ipairs(ALL_SECTION_KEYS) do if collapsed[key] then closed[#closed + 1] = key end end
  if #closed > 0 then now[#now + 1] = "[collapsed: " .. table.concat(closed, ", ") .. "]" end
  local lines = KEYS.help_lines("dashboard", "PR dashboard keys", table_,
    { now = now, fixed = { "  j / k       move" } })
  vim.list_extend(lines, {
    "",
    "Row badges (left of the id):",
    "  \u{25CF}           unread comment activity since you last opened the PR",
    "  \u{21E3}           branches or content being fetched in the background right now",
    "  \u{25C6}           fully prefetched, opens instantly",
    "  @           an active thread mentions me; the PR also appears in Mentions",
    "",
    "Sections:",
    "  Mentions    every PR (from any section below) with an active thread",
    "              mentioning me. Only covers PRs already in the list (assigned",
    "              to me or created by me) - ADO has no \"mentioned\" search.",
    "  Signed off and Drafts start collapsed (za on a header toggles it, zR/zM",
    "  expand/collapse every section) - configurable via setup({collapsed_sections=...}).",
    "",
    "Build column (right of the id):",
    "  \u{2713}           succeeded     \u{2717}  failed",
    "  \u{21BB}           expired       \u{25CF}  running (queue position when known)",
    "",
    "  \u{26A0}           merge conflict     A  auto-complete is on",
  })
  open_float(lines)
end

-- Prompt for a text filter (title/repo/author) applied on the next render.
-- Clone path -> true while warm_all's repository-wide fetch for it runs.
-- Declared here (ahead of the warm/prefetch bookkeeping it belongs with)
-- because set_winbar below reads it.
-- All warm/prefetch bookkeeping lives in the shared session state, not in
-- this M.open() invocation: switching to the work-items view and back
-- re-runs M.open(), and per-instance tables would make the new instance
-- believe nothing is warm - starting a second repository-wide fetch per
-- clone while the previous pass's jobs are still running, and making the
-- next open wait behind it. Shared tables let an in-flight pass's
-- callbacks and the new instance see one truth.
STATE.warm = STATE.warm or {
  warmed = {},          -- id -> updatedIso the branches were last fetched for
  warming = {},         -- id -> true while a branch fetch is in flight
  warm_cbs = {},        -- id -> pending callbacks to run once the fetch completes
  cloning = {},         -- id -> true while an auto-clone is in flight
  clone_cbs = {},       -- id -> pending callbacks waiting on the clone to finish
  syncing_clone = {},   -- clone path -> true while warm_all's repo-wide fetch runs
  clone_waiters = {},   -- clone path -> callbacks to run once that fetch has finished
  running = false,      -- true while a warm_all pass is in progress
}
local syncing_clone = STATE.warm.syncing_clone
local clone_waiters = STATE.warm.clone_waiters

-- Winbar: "Pull requests · N actionable · M mentions", the active filter
-- and which clones a repository-wide fetch is running for right now
-- (warm_all, one per clone) as tags, then "?: help" (see
-- lua/azure-cli/ui.lua's UI.winbar - every key used to be spelled out here
-- too, but `?` already lists them all and the chip list overflowed a normal
-- terminal width once this dashboard grew past a dozen actions).
set_winbar = function()
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local fetching = {}
  for path in pairs(syncing_clone) do
    fetching[#fetching + 1] = vim.fn.fnamemodify(path, ":t")
  end
  table.sort(fetching)

  local parts = { "Pull requests" }
  if actionable_count > 0 then parts[#parts + 1] = actionable_count .. " actionable" end
  if mention_count > 0 then parts[#parts + 1] = mention_count .. " mentions" end

  local cache = STATE.PR_LIST_CACHE
  if cache and cache.ts then
    local age = os.time() - cache.ts
    parts[#parts + 1] = "updated " .. (age < 60 and "just now" or (math.floor(age / 60) .. "m ago"))
  end

  local tags = {}
  if list_inflight then tags[#tags + 1] = "[refreshing\u{2026}]" end
  if filter ~= "" then tags[#tags + 1] = "[filter: " .. filter .. "]" end
  if #fetching > 0 then tags[#tags + 1] = "[fetching " .. table.concat(fetching, ", ") .. "\u{2026}]" end
  -- Set by render()'s last UI.layout call: a column (reviewer summary,
  -- updated-human or author, in that order) had to be dropped to fit this
  -- window - see SCALING_COLUMNS/ROW_FIXED_WIDTH above.
  if layout_narrow then tags[#tags + 1] = "[narrow]" end

  pcall(function()
    UI.wo(win, "winbar", UI.winbar(parts, tags))
  end)
end

local function set_filter()
  local function apply(text)
    filter = vim.trim(text or "")
    STATE.dashboard_filter = filter
    render()
    set_winbar()
  end
  UI.filter_prompt({
    win = win, prompt = "Filter PRs (id, title, repo, author)", default = filter,
    on_change = apply, on_submit = apply,
    on_cancel = function() apply("") end,
  })
end

-- za: toggle collapse on the section whose header the cursor is on. Only
-- fires from a header row (see row_header_key above) - collapsing "the
-- section this PR is in" from an arbitrary row is a coarser gesture than a
-- fold command usually is, so this stays deliberate rather than guessing.
local function toggle_section()
  local key = row_header_key[vim.api.nvim_win_get_cursor(0)[1]]
  if not key then
    notify("Place the cursor on a section header to toggle it (za).", vim.log.levels.WARN)
    return
  end
  if collapsed[key] then collapsed[key] = nil else collapsed[key] = true end
  render()
end

-- zR / zM: expand/collapse every section at once.
local function expand_all()
  for key in pairs(collapsed) do collapsed[key] = nil end
  render()
  notify("All sections expanded.")
end
local function collapse_all()
  for _, key in ipairs(ALL_SECTION_KEYS) do collapsed[key] = true end
  render()
  notify("All sections collapsed.")
end

-- Warm the PR's branches so opening the reviewer is instant. Keyed by the PR's
-- updatedIso so a warm PR is only re-fetched when it actually changed ("refresh
-- only when updated"). Concurrent requests (hover prefetch + pressing <CR>) are
-- coalesced so we never launch a duplicate/conflicting git fetch for the same PR.
-- Pass allow_clone=true (only done from the explicit <CR> open, not hover
-- prefetch) to offer cloning the repo first when it isn't on disk yet. Cloning
-- has its own in-flight tracking (cloning/clone_cbs), kept separate from the
-- warm/fetch tracking (warming/warm_cbs): hover prefetch can't clone, so if it
-- kicks off a doomed fetch against a not-yet-cloned repo first, an immediately
-- following <CR> must still be able to clone rather than just queuing behind
-- that fetch's guaranteed failure.
local warmed = STATE.warm.warmed
local warming = STATE.warm.warming
local warm_cbs = STATE.warm.warm_cbs
local cloning = STATE.warm.cloning
local clone_cbs = STATE.warm.clone_cbs

-- Only this PR's own work counts as "syncing": its branch warm, its clone,
-- or its content prefetch. The repository-wide fetch warm_all runs first
-- (one per clone) is deliberately NOT reflected per row - it used to be,
-- which made every PR of a clone light up at start-up even though the
-- content prefetch behind the badge is limited to WARM_CONCURRENCY at a
-- time. That fetch shows once, in the winbar (see set_winbar).
pr_sync_state = function(pr)
  local id = tostring(pr.id or "")
  local key = CACHE.key(pr.id, pr.updatedIso)
  if warming[id] or cloning[id] or CACHE.is_syncing(key) then
    return "syncing"
  end
  if warmed[id] == pr.updatedIso and CACHE.is_complete(key) then
    return "ready"
  end
  return nil
end

-- Redraw the list shortly after a sync-state change (start/finish of a
-- fetch or prefetch), coalescing bursts into one render. render() is
-- change-aware and keeps the cursor on its PR, so this never flickers.
local render_timer
local function schedule_render()
  if render_timer then vim.fn.timer_stop(render_timer) end
  render_timer = vim.fn.timer_start(50, function()
    render_timer = nil
    if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
      render()
    end
  end)
end

local function ensure_warm(pr, cb, allow_clone)
  if not pr then return end
  local id = tostring(pr.id or "")
  if id == "" then if cb then cb(true) end return end

  local function continue_warm()
    if warmed[id] == pr.updatedIso then
      if cb then cb(true) end
      return
    end
    if cb then
      warm_cbs[id] = warm_cbs[id] or {}
      warm_cbs[id][#warm_cbs[id] + 1] = cb
    end
    if warming[id] then return end
    -- warm_all's repository-wide fetch for this clone is in flight: a second
    -- git fetch in the same repository would only queue behind it inside
    -- git (a long wait on a big repo, with nothing on screen to say why).
    -- Wait for that one instead; it marks every PR of the clone warm when
    -- it succeeds, so this callback then completes at once.
    local path = clone_for(pr)
    if syncing_clone[path] then
      clone_waiters[path] = clone_waiters[path] or {}
      clone_waiters[path][#clone_waiters[path] + 1] = continue_warm
      -- Only an explicit open (allow_clone is set by open_pr alone; the
      -- hover prefetch never passes it) gets told - the hover warm waits
      -- silently, or this message would appear just from resting the cursor.
      if allow_clone then
        notify("Waiting for the fetch of " .. vim.fn.fnamemodify(path, ":t") .. " to finish before opening PR #" .. id .. "\u{2026}")
      end
      return
    end
    warming[id] = true
    schedule_render()
    -- Say something if the fetch takes a while (a large repository, or a
    -- slow link) so a wait never looks like a hang.
    if allow_clone then
      vim.defer_fn(function()
        if warming[id] then
          notify("Still fetching branches for PR #" .. id .. " (" .. (pr.repo or "repo") .. ")\u{2026}")
        end
      end, 5000)
    end
    RPC.run(PROVIDER_CMD, {
      env = vim.tbl_extend("force", pr_env(pr), { AZVICLI_PREFETCH = "1" }),
      on_exit = function(_, code)
        warming[id] = nil
        if code == 0 then warmed[id] = pr.updatedIso end  -- only cache a successful fetch
        schedule_render()
        local cbs = warm_cbs[id] or {}
        warm_cbs[id] = nil
        for _, f in ipairs(cbs) do vim.schedule(function() f(code == 0) end) end
      end,
    })
  end

  if not allow_clone then
    continue_warm()
    return
  end

  local path = clone_for(pr)
  if is_cloned(path) then
    continue_warm()
    return
  end

  -- Repo isn't cloned yet: coalesce concurrent openers of the same PR onto
  -- one clone attempt, then let each proceed to the normal warm/fetch path.
  if cb then
    clone_cbs[id] = clone_cbs[id] or {}
    clone_cbs[id][#clone_cbs[id] + 1] = cb
  end
  if cloning[id] then return end
  cloning[id] = true
  schedule_render()
  ensure_cloned(pr, path, function(ok)
    cloning[id] = nil
    schedule_render()
    local cbs = clone_cbs[id] or {}
    clone_cbs[id] = nil
    if not ok then
      for _, f in ipairs(cbs) do vim.schedule(function() f(false) end) end
      return
    end
    -- The provider's prefetch mode exits 0 even when the repo doesn't exist
    -- yet (a harmless no-op), so any earlier hover-prefetch against this PR
    -- may have already (bogusly) marked it "warmed". Clear that so the branch
    -- fetch actually runs now that the repo is real.
    warmed[id] = nil
    for _, f in ipairs(cbs) do
      warm_cbs[id] = warm_cbs[id] or {}
      warm_cbs[id][#warm_cbs[id] + 1] = f
    end
    continue_warm()
  end)
end

-- Fill the shared content cache for `pr` (file list, every file's diff, the
-- commit list, the comment threads) so opening it has nothing left to fetch.
-- Requires the branches to be warm already (see ensure_warm); no-op for a
-- PR whose repo isn't cloned. cb (optional) runs once the pipeline is done.
local function prefetch_content(pr, cb)
  local path = clone_for(pr)
  if not pr or not is_cloned(path) or not pr.source or pr.source == ""
      or not pr.target or pr.target == "" then
    if cb then cb() end
    return
  end
  CACHE.prefetch({
    id = pr.id, updatedIso = pr.updatedIso,
    source = pr.source, target = pr.target, repo = path,
    totalThreads = pr.totalThreads,
    cmd = PROVIDER_CMD, env = pr_env(pr),
  }, function()
    schedule_render()
    if cb then cb() end
  end)
  schedule_render()
end

-- Warm every open PR after a list load, so even the first open after
-- start-up is instant, not just PRs the cursor has rested on. PRs are
-- processed one at a time in priority order across all clones - Actionable,
-- then created by me, then Drafts, then Signed off, then Waiting - so the
-- PRs most likely to be opened next are always ready first, regardless of
-- which repo they live in. A clone's repository-wide `git fetch`
-- (the provider's "all" prefetch mode) runs lazily the first time one of
-- its PRs comes up, and is skipped when nothing in that clone has activity
-- we haven't fetched yet. WARM_CONCURRENCY PRs are in flight at once (their
-- git work touches different files and the thread fetches are independent
-- network calls), still in queue order; if a list load lands while a pass
-- is still going, the next load picks up where it left off.
local WARM_RANK = { Actionable = 1, Created = 2, Drafts = 3, SignedOff = 4, Waiting = 5 }
local WARM_CONCURRENCY = CONFIG.get().timing.warm_concurrency
-- (the "pass in progress" flag is STATE.warm.running - see above)
local function warm_all(list)
  if STATE.warm.running then return end
  local queue = {}
  for _, pr in ipairs(list) do
    if WARM_RANK[pr.state] and pr.source and pr.source ~= "" and pr.target and pr.target ~= ""
        and is_cloned(clone_for(pr)) then
      queue[#queue + 1] = pr
    end
  end
  if #queue == 0 then return end
  table.sort(queue, function(a, b)
    if WARM_RANK[a.state] ~= WARM_RANK[b.state] then return WARM_RANK[a.state] < WARM_RANK[b.state] end
    return iso_epoch(a.updatedIso) > iso_epoch(b.updatedIso)  -- most recent first within a section
  end)
  STATE.warm.running = true

  -- Per clone within this pass: "ok" once its fetch succeeded (or wasn't
  -- needed), "failed" to leave its PRs cold rather than cache diffs against
  -- refs that may be missing or behind, or a list of callbacks while the
  -- fetch is in flight so concurrent workers on the same clone wait for the
  -- one fetch instead of starting a second (two fetches in one clone fight
  -- over ref locks).
  local clone_state = {}
  local function clone_needs_fetch(path)
    for _, pr in ipairs(queue) do
      if clone_for(pr) == path and warmed[tostring(pr.id)] ~= pr.updatedIso then return true end
    end
    return false
  end
  local function ensure_clone_fetched(pr, path, cb)
    local st = clone_state[path]
    if type(st) == "table" then
      st[#st + 1] = cb
      return
    end
    if st then
      cb(st == "ok")
      return
    end
    if not clone_needs_fetch(path) then
      clone_state[path] = "ok"
      cb(true)
      return
    end
    clone_state[path] = { cb }
    syncing_clone[path] = true
    set_winbar()
    schedule_render()
    RPC.run(PROVIDER_CMD, {
      env = vim.tbl_extend("force", pr_env(pr), { AZVICLI_PREFETCH = "all", AZVICLI_REPO_PATH = path }),
      on_exit = function(_, code)
        syncing_clone[path] = nil
        set_winbar()
        schedule_render()
        local waiting = clone_state[path]
        clone_state[path] = code == 0 and "ok" or "failed"
        if code == 0 then
          for _, q in ipairs(queue) do
            if clone_for(q) == path then warmed[tostring(q.id)] = q.updatedIso end
          end
        end
        for _, f in ipairs(waiting) do f(code == 0) end
        -- Opens that chose to wait for this fetch (see ensure_warm): re-run
        -- their warm step, which now completes at once on success or
        -- falls back to a per-PR fetch on failure.
        local opens = clone_waiters[path] or {}
        clone_waiters[path] = nil
        for _, f in ipairs(opens) do vim.schedule(f) end
      end,
    })
  end

  -- WARM_CONCURRENCY workers each pull the next PR off the shared queue
  -- (so the front of the queue is always what's being worked on) and the
  -- pass ends once every worker has run out of PRs.
  local next_index, active = 0, 0
  local function worker()
    next_index = next_index + 1
    local pr = queue[next_index]
    if not pr then
      active = active - 1
      if active == 0 then STATE.warm.running = false end
      return
    end
    if CACHE.is_complete(CACHE.key(pr.id, pr.updatedIso)) then
      worker()
      return
    end
    local path = clone_for(pr)
    ensure_clone_fetched(pr, path, function(ok)
      if not ok then worker() return end
      prefetch_content(pr, worker)
    end)
  end
  for _ = 1, math.min(WARM_CONCURRENCY, #queue) do
    active = active + 1
    worker()
  end
end

-- Diffs a freshly fetched PR list against the previous one (by id), looking
-- for growth in thread/mention counts that means "something happened since
-- last time": for a PR I authored, any growth in its total comment count; for
-- any other PR, growth in myActiveThreads (active threads I've participated
-- in) so a reply to one of my own comments on someone else's PR still
-- notifies; on any PR, growth in mentionTotal notifies about a new @-mention
-- regardless of whether I've participated. Only called when a previous
-- snapshot exists, so the very first load of the session never spams a
-- notification for every pre-existing comment or mention.
local function notify_new_pr_comments(prev_prs, fresh_prs)
  local prev_by_id = {}
  for _, p in ipairs(prev_prs) do prev_by_id[p.id] = p end

  local mine_events, thread_events, mention_events = {}, {}, {}
  for _, pr in ipairs(fresh_prs) do
    local old = prev_by_id[pr.id]
    if old then
      local is_mine = pr.state == "Created"
      if is_mine then
        if (pr.totalThreads or -1) >= 0 and pr.totalThreads > (old.totalThreads or -1) then
          mine_events[#mine_events + 1] = pr
        end
      else
        if (pr.myActiveThreads or -1) >= 0 and pr.myActiveThreads > (old.myActiveThreads or -1) then
          thread_events[#thread_events + 1] = pr
        end
      end
      if (pr.mentionTotal or -1) >= 0 and pr.mentionTotal > (old.mentionTotal or -1) then
        mention_events[#mention_events + 1] = pr
      end
    end
  end

  for _, pr in ipairs(mine_events) do
    notify("New comment on your PR #" .. pr.id .. ": " .. (pr.title or ""))
    NOTIFY.toast("PR #" .. pr.id, "New comment on your PR: " .. (pr.title or ""))
  end
  for _, pr in ipairs(thread_events) do
    notify("New reply on your thread in PR #" .. pr.id .. ": " .. (pr.title or ""))
    NOTIFY.toast("PR #" .. pr.id, "New reply on your thread")
  end
  for _, pr in ipairs(mention_events) do
    notify("New mention in PR #" .. pr.id .. ": " .. (pr.title or ""))
    NOTIFY.toast("PR #" .. pr.id, "New mention")
  end
end

-- Fetch the PR list from the headless provider and render it. Renders the
-- cached list instantly (making swaps instant) and only refetches when the
-- cache is stale or a refresh is forced. Only one --list run is ever in
-- flight: a poll (or an r press) that lands while the previous fetch is
-- still going is skipped rather than stacked on top of it, so a slow server
-- can't pile up concurrent sweeps that fight each other for the connection.
local function load(silent, force)
  local cache = STATE.PR_LIST_CACHE
  local prev_prs = cache and cache.prs
  if cache and cache.prs then
    prs = cache.prs
    render()
  elseif not silent then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading pull requests…" })
    vim.bo[buf].modifiable = false
  end

  -- Cache still fresh: the instant render above is enough, skip the ADO round-trip.
  if cache and cache.prs and not force and (os.time() - cache.ts) < LIST_TTL then
    return
  end

  if list_inflight then
    if not silent then notify("Refresh already in progress…") end
    return
  end
  list_inflight = true

  local fresh = {}
  local out = {}
  local err = {}
  -- Same data --list would print via the EXE launcher, run through the
  -- provider argv directly (python azure-cli.py --list) so it's routed
  -- through the daemon like every other provider call.
  local list_args = vim.list_extend({}, PROVIDER_CMD)
  list_args[#list_args + 1] = "--list"
  RPC.run(list_args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      list_inflight = false
      if code ~= 0 then
        -- Both streams: the provider's "Configuration does not exist"
        -- used to go to stdout and rendered here as a blank error.
        local LOG = require("azure-cli.log")
        local raw = LOG.join_output(out, err)
        LOG.record("PR list", raw)
        if silent and prev_prs then
          -- A background poll failed but the table on screen is still a
          -- good list - keep it and just say so, rather than replacing it
          -- with an error the user then can't act on.
          notify("Refresh failed: " .. LOG.summary(raw, 60) .. "  (r to retry, :AzureCli log)", vim.log.levels.WARN)
          return
        end
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, LOG.failure_lines("Failed to load PRs (exit " .. code .. "):", raw))
        vim.bo[buf].modifiable = false
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then return end
      for _, line in ipairs(out) do
        if line:gsub("%s", "") ~= "" then
          local ok, rec = pcall(vim.json.decode, line)
          if ok and type(rec) == "table" then
            fresh[#fresh + 1] = rec
          end
        end
      end
      if prev_prs then
        notify_new_pr_comments(prev_prs, fresh)
      end
      seed_unseen(fresh)
      prs = fresh
      STATE.PR_LIST_CACHE = { prs = fresh, ts = os.time() }
      render()
      warm_all(fresh)
    end,
  })
end

-- Set the AZVICLI_* process env the reviewer (and its provider calls) read.
local function set_pr_env(pr)
  vim.env.AZVICLI_PR = tostring(pr.id)
  vim.env.AZVICLI_REPO = pr.repo or ""
  vim.env.AZVICLI_PROJECT = pr.project or ""
  vim.env.AZVICLI_ORG = pr.org or ""
  vim.env.AZVICLI_SOURCE = pr.source or ""
  vim.env.AZVICLI_TARGET = pr.target or ""
  vim.env.AZVICLI_PY = PROVIDER_CMD[1]
  vim.env.AZVICLI_PROVIDER = PROVIDER_CMD[2]
  vim.env.AZVICLI_EXE = EXE
  local cp = clone_for(pr)
  if cp ~= "" then
    vim.env.AZVICLI_REPO_PATH = cp
  end
end

-- Open `pr` in the reviewer, in a new tab of this nvim. M.open_pr_by_record
-- (assigned below) is this same function, exposed for :AzureCli review <id>
-- (lua/azure-cli/init.lua's open_review) to call directly with a record
-- looked up from the list cache instead of the row under the cursor.
local function open_pr_record(pr)
  if not pr then
    return
  end
  -- Already open in a reviewer tab: go there rather than opening a twin.
  if UI.goto_tab(function(b)
    return vim.bo[b].filetype == "azurecli-files" and vim.b[b].azure_cli_pr == tostring(pr.id)
  end) then
    return
  end
  set_pr_env(pr)
  vim.env.AZVICLI_EMBED = "1"
  STATE.PR_CURRENT = pr  -- let the reviewer read metadata (e.g. description) not passed via env
  -- Opening the PR is the "I've seen this" signal for the unread badge -
  -- record its current counts so the dot clears (redraws on the next render,
  -- e.g. when this dashboard tab is revisited).
  mark_pr_seen(pr)
  render()
  notify("Opening PR #" .. pr.id .. " …")
  -- Ensure the repo is cloned (offering to clone it under the configured
  -- clones_dir if it isn't) and the branches are warm for this PR version,
  -- then open the reviewer in-session. When already warm (e.g. prefetched on
  -- hover, unchanged since) this opens instantly with no git fetch; a new
  -- push re-warms first. Bail out without opening a broken tab if cloning
  -- or fetching failed.
  ensure_warm(pr, function(ok)
    if not ok then
      notify("Could not open PR #" .. pr.id .. ": repo isn't available.", vim.log.levels.ERROR)
      return
    end
    vim.cmd("tabnew")
    require("azure-cli.review").open()
  end, true)
end
M.open_pr_by_record = open_pr_record

-- Open the PR under the cursor in the reviewer (<CR>).
local function open_pr()
  local pr = current_pr()
  if not pr then
    -- <CR> on a section header folds/unfolds it, like any tree view.
    if row_header_key[vim.api.nvim_win_get_cursor(0)[1]] then toggle_section() end
    return
  end
  open_pr_record(pr)
end

-- Run a quick provider subcommand (vote/complete/auto-complete) for the
-- PR under the cursor. Optimistic: `apply(pr)` (optional) changes the row's
-- record right away and returns a function that undoes it; on failure that
-- undo runs and the error is shown, on success the list is reloaded so the
-- server's view wins either way.
local function run_action(args, describe, apply)
  local pr = current_pr()
  if not pr then
    return
  end
  notify(describe .. " PR #" .. pr.id .. " …")
  local undo = apply and apply(pr)
  if undo then render() end
  local out = {}
  local job_args = vim.list_extend({}, PROVIDER_CMD)
  vim.list_extend(job_args, args)
  RPC.run(job_args, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    env = pr_env(pr),
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code == 0 then
        notify(describe .. " PR #" .. pr.id .. ": done.")
        load(false, true)
      else
        if undo then
          undo()
          render()
        end
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), " ")
        notify(describe .. " failed (exit " .. code .. "): " .. msg
          .. (undo and " - change reverted." or ""), vim.log.levels.ERROR)
      end
    end,
  })
end

local VOTE_OPTIONS = {
  { key = "10",  label = "Approve" },
  { key = "5",   label = "Approve with suggestions" },
  { key = "-5",  label = "Wait for author" },
  { key = "-10", label = "Reject" },
  { key = "0",   label = "Reset (no vote)" },
}

-- Record my vote on the row's record and recompute the derived vote ratio
-- and reviewer summary the way the data provider does, so the row updates
-- before the server has answered. Returns an undo function.
local set_my_vote = PRS.apply_my_vote

-- My current vote on `pr` (a reviewer entry whose name is mine), as the
-- VOTE_OPTIONS key string, or nil when I haven't voted / am not a reviewer.
local my_vote_key = PRS.my_vote_key

local function vote_pr()
  local pr = current_pr()
  if not pr then return end
  local cur = my_vote_key(pr)
  PROMPT.select({ prompt = "Vote on PR #" .. pr.id .. "  " .. (pr.title or ""), items = VOTE_OPTIONS,
    current = function(o) return cur ~= nil and tostring(o.key) == cur end }, function(opt)
    if not opt then return end
    run_action({ "--vote", opt.key }, "Voting on", function(p)
      return set_my_vote(p, tonumber(opt.key) or 0)
    end)
  end)
end

local MERGE = require("azure-cli.merge")
local MERGE_TYPES = MERGE.MERGE_TYPES

-- Complete (merge) the PR under the cursor: the same dialog the reviewer's
-- gm opens (lua/azure-cli/merge.lua) - merge type, work-item/branch toggles,
-- build/threads/votes with a warning when they argue against merging - fed
-- from the row's own --list record.
local function complete_pr()
  local pr = current_pr()
  if not pr then return end
  MERGE.dialog({
    id = pr.id,
    title = pr.title,
    source = pr.source,
    target = pr.target,
    build_label = MERGE.build_label(pr),
    conflict = pr.mergeConflict and true or false,
    unresolved = (type(pr.activeThreads) == "number" and pr.activeThreads >= 0) and pr.activeThreads or nil,
    vote_ratio = pr.voteRatio,
  }, function(mt, delete_branch, work_items)
    -- Optimistically drop the row: a completed PR leaves the active list.
    run_action({ "--complete", mt.key, tostring(delete_branch), tostring(work_items) }, "Completing", function(p)
      local at
      for i, x in ipairs(prs) do
        if x == p then at = i break end
      end
      if not at then return nil end
      table.remove(prs, at)
      return function() table.insert(prs, math.min(at, #prs + 1), p) end
    end)
  end)
end

-- Toggle "complete automatically when requirements are met" (auto-complete)
-- on the PR under the cursor, mirroring the web UI's completion-dialog
-- checkbox. When already on, offers to cancel it; otherwise prompts for a
-- merge strategy the same way gm/complete_pr does.
local function toggle_auto_complete()
  local pr = current_pr()
  if not pr then return end
  local function set_on(mt)
    -- Defaults: delete source branch + transition work items (like the web UI).
    run_action({ "--auto-complete", "on", mt.key, "true", "true" }, "Setting auto-complete on", function(p)
      local was, by = p.autoComplete, p.autoCompleteSetBy
      p.autoComplete, p.autoCompleteSetBy = true, p.myName or ""
      return function() p.autoComplete, p.autoCompleteSetBy = was, by end
    end)
  end
  if pr.autoComplete then
    -- Already on: offer to turn it off, or to change the merge strategy in
    -- one step (used to take a cancel and a re-set).
    local items = { { label = "Cancel auto-complete", off = true } }
    for _, o in ipairs(MERGE_TYPES) do items[#items + 1] = { label = "Change strategy: " .. o.label, mt = o } end
    PROMPT.select({
      prompt = "PR #" .. pr.id .. " has auto-complete on" ..
        (pr.autoCompleteSetBy ~= "" and (" (by " .. pr.autoCompleteSetBy .. ")") or ""),
      items = items,
    }, function(choice)
      if not choice then return end
      if choice.off then
        run_action({ "--auto-complete", "off" }, "Cancelling auto-complete on", function(p)
          local was, by = p.autoComplete, p.autoCompleteSetBy
          p.autoComplete, p.autoCompleteSetBy = false, ""
          return function() p.autoComplete, p.autoCompleteSetBy = was, by end
        end)
      else
        set_on(choice.mt)
      end
    end)
    return
  end

  PROMPT.select({ prompt = "Auto-complete PR #" .. pr.id .. " with", items = MERGE_TYPES }, function(mt)
    if mt then set_on(mt) end
  end)
end

-- Re-queue the build validation (e.g. an expired build) for the PR under the cursor.
local function requeue_pr()
  local pr = current_pr()
  if not pr then return end
  notify("Re-queuing build for PR #" .. pr.id .. " \u{2026}")
  local out = {}
  local requeue_args = vim.list_extend({}, PROVIDER_CMD)
  vim.list_extend(requeue_args, { "--requeue", tostring(pr.id) })
  RPC.run(requeue_args, {
    detach = true,  -- finish the ADO write even if the user quits before it returns
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), " ")
      if code == 0 then
        notify("Re-queue PR #" .. pr.id .. ": " .. (msg ~= "" and msg or "done."))
        load(false, true)
      else
        notify("Re-queue PR #" .. pr.id .. " failed (exit " .. code .. "): " .. msg, vim.log.levels.ERROR)
      end
    end,
  })
end

-- Set up the dashboard buffer, window, and keymaps.
buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = "azurecli-dashboard"
vim.api.nvim_set_current_buf(buf)
win = vim.api.nvim_get_current_win()
-- Window-local only: a plugin-mode user's own 'number'/'signcolumn' must
-- survive a visit here (these used to be set on vim.o and never restored).
UI.plain_window(win, { cursorline = true })
set_winbar()

-- Every binding below goes through KEYS.bind (lua/azure-cli/keys.lua)
-- instead of a literal vim.keymap.set, so setup({ keys = { dashboard = {
-- ... } } }) controls every one of these - see README's Configuration
-- section for the full action table.
KEYS.bind(buf, "dashboard", "open", open_pr, { desc = "open the PR under the cursor in the reviewer" })
KEYS.bind(buf, "dashboard", "copy_link", yank_link, { desc = "copy the PR link" })
KEYS.bind(buf, "dashboard", "browser", open_browser, { desc = "open in the browser" })
KEYS.bind(buf, "dashboard", "description", show_description, { desc = "show the description (build status and policies too)" })
KEYS.bind(buf, "dashboard", "open_build", open_build, { desc = "open the PR's build in the browser" })
KEYS.bind(buf, "dashboard", "filter", set_filter, { desc = "filter by title, repo or author" })
KEYS.bind(buf, "dashboard", "vote", vote_pr, { desc = "vote" })
KEYS.bind(buf, "dashboard", "complete", complete_pr, { desc = "complete (merge)" })
KEYS.bind(buf, "dashboard", "auto_complete", toggle_auto_complete, { desc = "toggle auto-complete" })
KEYS.bind(buf, "dashboard", "requeue_build", requeue_pr, { desc = "re-queue build validation" })
KEYS.bind(buf, "dashboard", "toggle_section", toggle_section, { desc = "toggle collapse on the section header under the cursor" })
KEYS.bind(buf, "dashboard", "expand_all", expand_all, { desc = "expand every section" })
KEYS.bind(buf, "dashboard", "collapse_all", collapse_all, { desc = "collapse every section" })
KEYS.bind(buf, "dashboard", "toasts", function()
  local on = NOTIFY.toggle()
  notify("Desktop notifications " .. (on and "enabled" or "disabled") .. " for this session.")
end, { desc = "toggle desktop notifications for this session" })
KEYS.bind(buf, "dashboard", "config", open_config_file, { desc = "open the config file" })
KEYS.bind(buf, "dashboard", "refresh", function() load(false, true) end, { desc = "refresh" })
-- gg/G land on the first/last PR row rather than the box's blank padding
-- (the table is centred vertically, so plain gg/G would otherwise stop on
-- an empty line above or below it).
local function jump_edge_pr(last)
  local target
  for ln in pairs(row_pr) do
    if not target or (last and ln > target) or (not last and ln < target) then target = ln end
  end
  if not target then return end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  vim.api.nvim_win_set_cursor(0, { target, col })
end
KEYS.bind(buf, "dashboard", "first_pr", function() jump_edge_pr(false) end, { desc = "jump to the first PR" })
KEYS.bind(buf, "dashboard", "last_pr", function() jump_edge_pr(true) end, { desc = "jump to the last PR" })
KEYS.bind(buf, "dashboard", "workitems", function()
  require("azure-cli.workitems.dashboard").open()
end, { desc = "switch to the work-items dashboard" })
KEYS.bind(buf, "dashboard", "help", show_help, { desc = "show this help" })
-- Standalone quits Neovim entirely (today's behaviour, `qa!`) - it's the
-- launcher's whole nvim session, nothing else to go back to. Plugin mode
-- just closes this dashboard's own tab (opened by init.lua's
-- open_dashboard); if it's the only tab (e.g. :AzureCli was the first thing
-- run this session), :tabclose would refuse to close the last one, so this
-- wipes the buffer instead and leaves Neovim itself open.
KEYS.bind(buf, "dashboard", "quit", function()
  if STATE.PR_REFRESH_TIMER then pcall(vim.fn.timer_stop, STATE.PR_REFRESH_TIMER); STATE.PR_REFRESH_TIMER = nil end
  if require("azure-cli").is_standalone() then
    vim.cmd("qa!")
    return
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  else
    pcall(vim.cmd, "enew")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end, { desc = "quit" })

-- Prefetch the PR under the cursor once movement settles (debounced), so the
-- reviewer opens with branches already warmed. Half a second of stillness
-- rather than a fifth: each prefetch is a bash + git fetch spawn, and at
-- 200ms a leisurely scroll through the list fired one per row passed over.
local prefetch_timer
vim.api.nvim_create_autocmd("CursorMoved", {
  buffer = buf,
  callback = function()
    if prefetch_timer then vim.fn.timer_stop(prefetch_timer) end
    prefetch_timer = vim.fn.timer_start(500, function()
      local pr = current_pr()
      ensure_warm(pr, function(ok)
        if ok then prefetch_content(pr) end
      end)
    end)
  end,
})

-- Re-centre the table when the terminal is resized. Uses a named augroup
-- (cleared each time this file is sourced) so W/P swaps don't stack duplicate
-- autocmds across re-luafile's of this script.
vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("AzureCliResize", { clear = true }),
  callback = function()
    if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
      render()
    end
  end,
})

-- Periodic auto-refresh (silent + change-aware). Stop any timer from a previous
-- swap into this dashboard so timers don't stack across W/P swaps. Once a
-- minute: each poll is a full ADO sweep, and at 30s the machine was busy
-- with background sweeps more often than not.
if STATE.PR_REFRESH_TIMER then pcall(vim.fn.timer_stop, STATE.PR_REFRESH_TIMER) end
STATE.PR_REFRESH_TIMER = vim.fn.timer_start(CONFIG.get().timing.poll_seconds * 1000, function()
  -- Keep polling while the list is shown in any tab, so build/PR status stays
  -- fresh even while a PR is open in an embedded reviewer tab; stop once the
  -- dashboard buffer has been swapped away (e.g. to the work-items dashboard).
  if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
    load(true, true)
  end
end, { ["repeat"] = -1 })

-- Warm the work-items list in the background at startup so the first swap to
-- the work-items dashboard (W) is instant. No-op when already cached.
local function prefetch_work_items()
  if STATE.WI_LIST_CACHE and STATE.WI_LIST_CACHE.items then return end
  local out = {}
  local job_args = vim.list_extend({}, PROVIDER_CMD)
  job_args[#job_args + 1] = "--wi-list"
  RPC.run(job_args, {
    stdout_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_exit = function(_, code)
      if code ~= 0 then return end
      local items = {}
      local meta
      for _, line in ipairs(out) do
        if line:gsub("%s", "") ~= "" then
          local ok, rec = pcall(vim.json.decode, line)
          if ok and type(rec) == "table" then
            if rec._meta then meta = rec else items[#items + 1] = rec end
          end
        end
      end
      STATE.WI_LIST_CACHE = {
        items = items, ts = os.time(),
        name = meta and meta.sprintName,
        start = meta and meta.sprintStart,
        finish = meta and meta.sprintFinish,
        nextName = meta and meta.nextSprintName,
        nextPath = meta and meta.nextSprintPath,
        nextStart = meta and meta.nextStart,
        nextFinish = meta and meta.nextFinish,
      }
    end,
  })
end

-- Warm the provider daemon in the background right away (a cheap --ping) so
-- the very first real request below doesn't also pay its start-up cost.
RPC.run(vim.list_extend(vim.list_extend({}, PROVIDER_CMD), { "--ping" }), {})

load(false)
prefetch_work_items()

end  -- M.open()

return M
