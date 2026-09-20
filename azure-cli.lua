-- pr-dash Neovim dashboard (Option B).
--
-- The front door of pr-dash: renders the pull-request list entirely in Neovim
-- by shelling out to the headless C# data provider (`pr-dash --list`, NDJSON)
-- and dispatching per-PR actions to review-pr.sh. Opening a PR launches the
-- existing reviewer (pr-review.lua) via review-pr.sh.
--
-- Keys
--   j/k         move
--   <CR>        open the PR under the cursor in the reviewer
--   gv          cast a vote on the PR under the cursor
--   gm          complete (merge) the PR under the cursor
--   ga          toggle auto-complete on the PR under the cursor
--   gr          re-queue build validation for the PR under the cursor
--   r           refresh the list
--   q           quit
--
-- Row badges (left of the id): \u{25CF} unread comment activity, \u{21E3} branches or
-- content being fetched in the background right now, \u{25C6} fully prefetched
-- (opens instantly). The build column to the right of the id keeps its own
-- \u{2713} ok / \u{2717} failed / \u{21BB} expired / \u{25CF} running glyphs.

vim.o.compatible = false
vim.o.number = false
vim.o.signcolumn = "no"
vim.o.hidden = true
vim.o.termguicolors = true
vim.o.laststatus = 2
vim.o.mouse = "a"

-- Resolve this script's directory so the exe/script default next to it.
local function script_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  -- fnamemodify makes it absolute (resolving relative paths against cwd).
  return vim.fn.fnamemodify(path, ":p:h")
end

local DIR    = script_dir()
local env    = vim.env
local EXE    = env.PRDASH_EXE or (DIR .. "/src/bin/Debug/net6.0/azure-cli.exe")
local SCRIPT = env.PRDASH_SCRIPT or (DIR .. "/review-pr.sh")
local BASH   = env.PRDASH_BASH or "bash"
-- Local clone used by the reviewer for diffs (per-repo mapping is a later step).
local REPO_PATH = env.PRDASH_REPO_PATH or ""
-- Normalise to a Windows path both git.exe and vim accept ("/c/x" -> "c:/x").
local REPO_PATH_WIN = REPO_PATH:gsub("^/([a-zA-Z])/", "%1:/")
-- The reviewer UI, opened in-session (a tab of this nvim) rather than a new
-- console. Forward slashes so :luafile accepts it on Windows.
local REVIEW_LUA = (DIR .. "/pr-review.lua"):gsub("\\", "/")
-- The work-items dashboard, swapped into this same window with W.
local WI_DASH_LUA = (DIR .. "/wi-dash.lua"):gsub("\\", "/")
-- Work-items list provider, warmed in the background so the first W swap is instant.
local WI_LIST = env.WIDASH_LIST or (DIR .. "/wi-list.sh")
-- Shared per-PR content caches + prefetch pipeline (files, diffs, commits,
-- threads), filled here in the background and read by the reviewer on open.
local CACHE = dofile((DIR .. "/prdash-cache.lua"):gsub("\\", "/"))

-- Section order and friendly titles.
local SECTIONS = {
  { key = "Actionable", title = "Actionable" },
  { key = "Waiting",    title = "Waiting for author" },
  { key = "SignedOff",  title = "Signed off" },
  { key = "Drafts",     title = "Drafts" },
  { key = "Created",    title = "Created by me" },
}

local prs = {}              -- all parsed PR records
local row_pr = {}           -- buffer line (1-based) -> pr record (nil for headers)
local buf, win

-- List cache shared across dashboard swaps (W/P): {prs, ts}. Lets re-entry
-- render instantly and only refetch from ADO when the cache is stale.
local LIST_TTL = 30

-- Case-insensitive text filter applied in render() (empty = show all).
local filter = ""
local function pr_matches(pr, q)
  local hay = ((pr.title or "") .. " " .. (pr.repo or "") .. " " .. (pr.author or "")):lower()
  return hay:find(q, 1, true) ~= nil
end

local BASE_WINBAR =
  "pull requests   (<CR>: open  gy: copy  o: browser  gd: description  /: filter  gv: vote  gm: complete  ga: auto-complete  gr: re-queue build  gO: config  r: refresh  W: work items  q: quit)"

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

-- Persistent "seen" snapshot per PR (nvim's per-user data dir, so it survives
-- restarts): { totalThreads, myActiveThreads } as of the last time the PR was
-- opened. Drives the "●" unread badge next to a PR's row in the list, and
-- is only advanced when the PR is actually opened (open_pr below) - not on
-- every poll - so the badge persists until you've actually gone and looked.
local SEEN_FILE = vim.fn.stdpath("data") .. "/pr-dash-seen.json"
local function load_seen()
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

-- Records pr's current thread counts as "seen" (called when the PR is opened).
local function mark_pr_seen(pr)
  seen.prs[tostring(pr.id)] = { totalThreads = pr.totalThreads or -1, myActiveThreads = pr.myActiveThreads or -1 }
  save_seen()
end

-- True when pr has comment activity beyond what was recorded the last time it
-- was opened: for a PR I authored, growth in its total comment count; for any
-- other PR, growth in myActiveThreads (threads I've participated in) so a
-- reply to one of my comments on someone else's PR still lights up. A PR with
-- no seen record yet (never opened, and not seeded below) is never unread.
local function pr_is_unread(pr)
  local rec = seen.prs[tostring(pr.id)]
  if not rec then return false end
  if pr.state == "Created" then
    return (pr.totalThreads or -1) >= 0 and pr.totalThreads > (rec.totalThreads or 0)
  end
  return (pr.myActiveThreads or -1) >= 0 and pr.myActiveThreads > (rec.myActiveThreads or 0)
end

-- Seeds a "seen" record at current counts for any PR that doesn't have one
-- yet (first time it's ever appeared in a list fetch on this machine), so the
-- unread badge only ever reacts to activity from this point forward instead
-- of flagging every pre-existing comment the first time this feature runs.
local function seed_unseen(fresh_prs)
  local dirty = false
  for _, pr in ipairs(fresh_prs) do
    if not seen.prs[tostring(pr.id)] then
      seen.prs[tostring(pr.id)] = { totalThreads = pr.totalThreads or -1, myActiveThreads = pr.myActiveThreads or -1 }
      dirty = true
    end
  end
  if dirty then save_seen() end
end

-- Resolve azure-cli.yml's path (matches Config.ConfigPath in the C# source):
-- %APPDATA%\azure-cli.yml on Windows, ~/.azure-cli.yml elsewhere.
local function config_path()
  if vim.fn.has("win32") == 1 then
    return (vim.env.APPDATA or vim.fn.expand("$APPDATA")) .. "\\azure-cli.yml"
  end
  return vim.fn.expand("~/.azure-cli.yml")
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

-- Truncate a string to n display cells, adding an ellipsis when cut.
local function fit(s, n)
  s = s or ""
  if vim.fn.strdisplaywidth(s) <= n then
    return s .. string.rep(" ", n - vim.fn.strdisplaywidth(s))
  end
  local out = s:sub(1, n - 1)
  return out .. "…"
end

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
-- to the configured PRDASH_REPO_PATH when clones_dir isn't set, for backward
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

-- Build the environment table review-pr.sh needs for a given PR record.
local function pr_env(pr)
  local e = {
    PRDASH_ID = tostring(pr.id),
    PRDASH_REPO = pr.repo or "",
    PRDASH_PROJECT = pr.project or "",
    PRDASH_ORG = pr.org or "",
    PRDASH_SOURCE = pr.source or "",
    PRDASH_TARGET = pr.target or "",
    PRDASH_EXE = EXE,
  }
  local cp = clone_for(pr)
  if cp ~= "" then
    e.PRDASH_REPO_PATH = cp
  end
  return e
end

-- Render the parsed PRs into the buffer, grouped by section.

-- Highlight palette (shared visual language with the work-items dashboard).
local ns = vim.api.nvim_create_namespace("prdash")
local function define_hl()
  local function hl(name, o) vim.api.nvim_set_hl(0, name, o) end
  hl("PrdashHeader", { fg = "#89b4fa", bold = true })
  hl("PrdashId", { fg = "#cba6f7" })
  hl("PrdashRepo", { fg = "#94e2d5" })
  hl("PrdashAuthor", { fg = "#bac2de" })
  hl("PrdashVote", { fg = "#89dceb" })
  hl("PrdashThread", { fg = "#f9e2af", bold = true })
  hl("PrdashThreadDone", { fg = "#a6e3a1", bold = true })
  hl("PrdashAged", { fg = "#6c7086" })
  hl("PrdashUpdated", { fg = "#7f849c" })
  hl("PrdashBuildOk", { fg = "#a6e3a1", bold = true })
  hl("PrdashBuildFail", { fg = "#f38ba8", bold = true })
  hl("PrdashBuildRun", { fg = "#f9e2af", bold = true })
  hl("PrdashBuildExpired", { fg = "#fab387", bold = true })
  hl("PrdashConflict", { fg = "#f38ba8", bold = true })
  hl("PrdashAutoComplete", { fg = "#a6e3a1", bold = true })
  hl("PrdashUnread", { fg = "#f38ba8", bold = true })
  hl("PrdashSyncing", { fg = "#89b4fa" })
  hl("PrdashReady", { fg = "#6c7086" })
  hl("PrdashBorder", { fg = "#585b70" })
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
  if status == "succeeded" then return "\u{2713}", "PrdashBuildOk" end
  if status == "failed" then return "\u{2717}", "PrdashBuildFail" end
  if status == "expired" then return "\u{21BB}", "PrdashBuildExpired" end
  if status == "running" then return "\u{25CF}", "PrdashBuildRun" end
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
local function surname(name)
  name = name or ""
  local s = name:match("^([^,]+),")
  if s then return vim.trim(s) end
  return name:match("(%S+)%s*$") or name
end

-- Wrap `lines` in a rounded border box and centre it in `win`, both
-- horizontally and vertically. `spans` are highlight ranges keyed by 0-based
-- line + byte columns *relative to the unwrapped `lines`*; they (and any
-- 1-based line-number maps in `line_maps`, e.g. row->PR) get shifted to match
-- the new, boxed/padded coordinates. Returns the final lines, the shifted
-- spans (with two extra "PrdashBorder" spans for the box edges appended), the
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
  shifted[#shifted + 1] = { line = top_line0, s = 0, e = -1, hl = "PrdashBorder" }
  shifted[#shifted + 1] = { line = bottom_line0, s = 0, e = -1, hl = "PrdashBorder" }

  return final, shifted, row_offset, col_offset
end

-- Sync-state glyph for a row: "\u{21E3}" while this PR's branches or content
-- are being fetched in the background, "\u{25C6}" once everything the
-- reviewer needs is cached (opening it is instant), blank otherwise. Chosen
-- to stay clear of the build column's own \u{2713}/\u{2717}/\u{21BB}/\u{25CF}.
-- Assigned once the warm/prefetch bookkeeping it reads exists (below).
local pr_sync_state

local function render()
  -- Remember which PR the cursor is on (by id, not raw row number) before we
  -- rebuild everything below, since the box's vertical centring means row
  -- numbers shift whenever the window is resized or the row count changes.
  local prev_pr_id
  if win and vim.api.nvim_win_is_valid(win) then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local prev_pr = row_pr[cur[1]]
      prev_pr_id = prev_pr and prev_pr.id
    end
  end

  local lines = {}
  local spans = {}  -- { line = 0-based, s = bytecol, e = bytecol, hl = group }
  row_pr = {}

  local by_state = {}
  local flc = filter:lower()
  for _, pr in ipairs(prs) do
    if flc == "" or pr_matches(pr, flc) then
      by_state[pr.state] = by_state[pr.state] or {}
      table.insert(by_state[pr.state], pr)
    end
  end

  local now = os.time()
  for _, sec in ipairs(SECTIONS) do
    local items = by_state[sec.key]
    if items and #items > 0 then
      -- Most recently updated first.
      table.sort(items, function(a, b) return iso_epoch(a.updatedIso) > iso_epoch(b.updatedIso) end)

      if #lines > 0 then
        lines[#lines + 1] = ""
        row_pr[#lines] = nil
      end
      local hstr = "── " .. sec.title .. " (" .. #items .. ") ──"
      lines[#lines + 1] = hstr
      row_pr[#lines] = nil
      spans[#spans + 1] = { line = #lines - 1, s = 0, e = #hstr, hl = "PrdashHeader" }

      for _, pr in ipairs(items) do
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
        seg(fit(pr_is_unread(pr) and "\u{25CF}" or "", 1), "PrdashUnread")
        seg(" ")
        local sync = pr_sync_state and pr_sync_state(pr)
        seg(fit(sync == "syncing" and "\u{21E3}" or (sync == "ready" and "\u{25C6}" or ""), 1),
          sync == "syncing" and "PrdashSyncing" or "PrdashReady")
        seg(" ")
        seg(fit("#" .. tostring(pr.id), 7), "PrdashId")
        seg(" ")
        local bg, bgrp = build_label(pr)
        seg(fit(bg, 3), bgrp)
        seg(" ")
        seg(fit(pr.mergeConflict and "\u{26A0}" or "", 1), "PrdashConflict")
        seg(" ")
        seg(fit(pr.autoComplete and "A" or "", 1), "PrdashAutoComplete")
        seg(" ")
        seg(fit(pr.title, 36))
        seg(" ")
        seg(fit(pr.repo or "", 14), "PrdashRepo")
        seg(" ")
        seg(fit(surname(pr.author), 10), "PrdashAuthor")
        seg(" ")
        seg(fit(pr.voteRatio or "", 6), "PrdashVote")
        seg(" ")
        local thr, tgrp = "", "PrdashThread"
        if type(pr.totalThreads) == "number" and pr.totalThreads > 0 then
          local total = pr.totalThreads
          local active = (type(pr.activeThreads) == "number" and pr.activeThreads >= 0) and pr.activeThreads or 0
          local closed = (type(pr.closedThreads) == "number" and pr.closedThreads >= 0)
            and pr.closedThreads or math.max(0, total - active)
          thr = closed .. "/" .. total
          tgrp = (closed >= total) and "PrdashThreadDone" or "PrdashThread"
        end
        seg(fit(thr, 6), tgrp)
        seg(" ")
        seg(fit(pr.reviewerSummary or "", 20))
        seg("  ")
        local aged = (now - iso_epoch(pr.updatedIso)) > 14 * 86400
        seg(pr.updatedHuman or "", aged and "PrdashAged" or "PrdashUpdated")

        lines[#lines + 1] = table.concat(parts)
        row_pr[#lines] = pr
      end
    end
  end

  if #lines == 0 then
    lines = { filter ~= "" and ('No PRs match "' .. filter .. '".') or "No pull requests." }
  end

  -- Box the table and centre it in the window (both axes); shift row_pr's
  -- line->PR map by the same row offset so <CR>/gy/etc. still hit the right PR.
  local row_offset, col_offset
  lines, spans, row_offset, col_offset = box_and_center(lines, spans, win)
  local shifted_row_pr = {}
  for ln, pr in pairs(row_pr) do
    shifted_row_pr[ln + row_offset] = pr
  end
  row_pr = shifted_row_pr

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
  -- cursor was on before this render and land there again; fall back to the
  -- first PR row, or just inside the box if the list is empty.
  if win and vim.api.nvim_win_is_valid(win) then
    local target
    if prev_pr_id then
      for ln, pr in pairs(row_pr) do
        if pr.id == prev_pr_id then target = ln; break end
      end
    end
    if not target then
      for ln in pairs(row_pr) do
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

-- Open a scratch floating window at the cursor showing the given text lines.
local function open_float(lines)
  if #lines == 0 then return end
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, 100)
  local height = math.min(#lines, 24)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].buftype = "nofile"
  vim.api.nvim_open_win(fbuf, true, {
    relative = "cursor", row = 1, col = 0,
    width = width, height = height,
    style = "minimal", border = "rounded",
  })
  local fopts = { buffer = fbuf, silent = true, nowait = true }
  vim.keymap.set("n", "q", "<Cmd>close<CR>", fopts)
  vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", fopts)
end

-- Show the title and description of the PR under the cursor in a float.
local function show_description()
  local pr = current_pr()
  if not pr then return end
  local title = pr.title or ""
  local lines = { "PR #" .. tostring(pr.id) .. (title ~= "" and ("  " .. title) or ""), "" }
  local desc = pr.description or ""
  if vim.trim(desc) == "" then
    table.insert(lines, "(no description)")
  else
    desc = desc:gsub("\r\n", "\n"):gsub("\r", "\n")
    for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do
      table.insert(lines, l)
    end
  end
  open_float(lines)
end

-- Prompt for a text filter (title/repo/author) applied on the next render.
local function set_filter()
  vim.ui.input({ prompt = "Filter PRs (title/repo/author): ", default = filter }, function(input)
    if input == nil then return end
    filter = vim.trim(input)
    render()
    pcall(function()
      vim.wo[win].winbar = BASE_WINBAR .. (filter ~= "" and ("    [filter: " .. filter .. "]") or "")
    end)
  end)
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
local warmed = {}    -- id -> updatedIso the branches were last fetched for
local warming = {}   -- id -> true while a branch fetch is in flight
local warm_cbs = {}  -- id -> pending callbacks to run once the fetch completes
local cloning = {}   -- id -> true while an auto-clone is in flight
local clone_cbs = {} -- id -> pending callbacks waiting on the clone to finish
local syncing_clone = {}  -- clone path -> true while warm_all's repo-wide fetch runs

pr_sync_state = function(pr)
  local id = tostring(pr.id or "")
  local key = CACHE.key(pr.id, pr.updatedIso)
  if warming[id] or cloning[id] or CACHE.is_syncing(key)
      or syncing_clone[clone_for(pr)] then
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
    warming[id] = true
    schedule_render()
    vim.fn.jobstart({ BASH, SCRIPT }, {
      env = vim.tbl_extend("force", pr_env(pr), { PRDASH_PREFETCH = "1" }),
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
    -- review-pr.sh's prefetch mode exits 0 even when the repo doesn't exist
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
    bash = BASH, script = SCRIPT, env = pr_env(pr),
  }, function()
    schedule_render()
    if cb then cb() end
  end)
  schedule_render()
end

-- Warm every open PR after a list load, so even the first open after
-- start-up is instant, not just PRs the cursor has rested on. Per clone:
-- one repository-wide `git fetch` (review-pr.sh's "all" prefetch mode),
-- skipped when nothing in that clone has activity we haven't fetched yet,
-- then the content pipeline for each of its PRs one at a time - Actionable
-- first, then my own, then Waiting; signed-off and draft PRs are left to
-- the hover prefetch. Runs one clone at a time at the lowest priority so it
-- never competes with an interactive open for git; if a list load lands
-- while a pass is still going, the next load picks up where it left off.
local WARM_RANK = { Actionable = 1, Created = 2, Waiting = 3 }
local warm_all_running = false
local function warm_all(list)
  if warm_all_running then return end
  local by_clone, clones = {}, {}
  for _, pr in ipairs(list) do
    if WARM_RANK[pr.state] and pr.source and pr.source ~= "" and pr.target and pr.target ~= "" then
      local path = clone_for(pr)
      if is_cloned(path) then
        if not by_clone[path] then
          by_clone[path] = {}
          clones[#clones + 1] = path
        end
        table.insert(by_clone[path], pr)
      end
    end
  end
  if #clones == 0 then return end
  warm_all_running = true

  local ci = 0
  local function next_clone()
    ci = ci + 1
    local path = clones[ci]
    if not path then
      warm_all_running = false
      return
    end
    local prs = by_clone[path]
    table.sort(prs, function(a, b)
      if WARM_RANK[a.state] ~= WARM_RANK[b.state] then return WARM_RANK[a.state] < WARM_RANK[b.state] end
      return tostring(a.id) < tostring(b.id)
    end)
    local function prefetch_each(i)
      local pr = prs[i]
      if not pr then next_clone() return end
      if CACHE.is_complete(CACHE.key(pr.id, pr.updatedIso)) then
        prefetch_each(i + 1)
        return
      end
      prefetch_content(pr, function() prefetch_each(i + 1) end)
    end

    local stale = false
    for _, pr in ipairs(prs) do
      if warmed[tostring(pr.id)] ~= pr.updatedIso then stale = true break end
    end
    if not stale then
      prefetch_each(1)
      return
    end
    syncing_clone[path] = true
    schedule_render()
    vim.fn.jobstart({ BASH, SCRIPT }, {
      env = vim.tbl_extend("force", pr_env(prs[1]), { PRDASH_PREFETCH = "all", PRDASH_REPO_PATH = path }),
      on_exit = function(_, code)
        syncing_clone[path] = nil
        schedule_render()
        if code ~= 0 then
          -- Fetch failed: leave this clone's PRs cold rather than caching
          -- diffs against refs that may be missing or behind.
          next_clone()
          return
        end
        for _, pr in ipairs(prs) do warmed[tostring(pr.id)] = pr.updatedIso end
        prefetch_each(1)
      end,
    })
  end
  next_clone()
end

-- Diffs a freshly fetched PR list against the previous one (by id), looking
-- for growth in thread counts that means "someone commented since last time":
-- for a PR I authored, any growth in its total comment count; for any other
-- PR, growth in myActiveThreads (active threads I've participated in) so a
-- reply to one of my own comments on someone else's PR still notifies. Only
-- called when a previous snapshot exists, so the very first load of the
-- session never spams a notification for every pre-existing comment.
local function notify_new_pr_comments(prev_prs, fresh_prs)
  local prev_by_id = {}
  for _, p in ipairs(prev_prs) do prev_by_id[p.id] = p end

  local mine_events, thread_events = {}, {}
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
    end
  end

  for _, pr in ipairs(mine_events) do
    notify("New comment on your PR #" .. pr.id .. ": " .. (pr.title or ""))
  end
  for _, pr in ipairs(thread_events) do
    notify("New reply on your thread in PR #" .. pr.id .. ": " .. (pr.title or ""))
  end
end

-- Fetch the PR list from the headless provider and render it. Renders the
-- cached list instantly (making swaps instant) and only refetches when the
-- cache is stale or a refresh is forced. Only one --list run is ever in
-- flight: a poll (or an r press) that lands while the previous fetch is
-- still going is skipped rather than stacked on top of it, so a slow server
-- can't pile up concurrent sweeps that fight each other for the connection.
local list_inflight = false
local function load(silent, force)
  local cache = _G.PR_LIST_CACHE
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
  vim.fn.jobstart({ EXE, "--list" }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      list_inflight = false
      if code ~= 0 then
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, err), " ")
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false,
          { "Failed to load PRs (exit " .. code .. "):", msg })
        vim.bo[buf].modifiable = false
        return
      end
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
      _G.PR_LIST_CACHE = { prs = fresh, ts = os.time() }
      render()
      warm_all(fresh)
    end,
  })
end

-- Set the PRDASH_* process env the reviewer (and its review-pr.sh calls) read.
local function set_pr_env(pr)
  vim.env.PRDASH_ID = tostring(pr.id)
  vim.env.PRDASH_REPO = pr.repo or ""
  vim.env.PRDASH_PROJECT = pr.project or ""
  vim.env.PRDASH_ORG = pr.org or ""
  vim.env.PRDASH_SOURCE = pr.source or ""
  vim.env.PRDASH_TARGET = pr.target or ""
  vim.env.PRDASH_SCRIPT = SCRIPT
  vim.env.PRDASH_BASH = BASH
  vim.env.PRDASH_EXE = EXE
  local cp = clone_for(pr)
  if cp ~= "" then
    vim.env.PRDASH_REPO_PATH = cp
  end
end

-- Open the PR under the cursor in the reviewer, in a new tab of this nvim.
local function open_pr()
  local pr = current_pr()
  if not pr then
    return
  end
  set_pr_env(pr)
  vim.env.PRDASH_EMBED = "1"
  _G.PR_CURRENT = pr  -- let the reviewer read metadata (e.g. description) not passed via env
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
    vim.cmd("luafile " .. vim.fn.fnameescape(REVIEW_LUA))
  end, true)
end

-- Run a quick review-pr.sh subcommand (vote/complete) for the PR under cursor.
local function run_action(args, describe)  local pr = current_pr()
  if not pr then
    return
  end
  notify(describe .. " PR #" .. pr.id .. " …")
  local out = {}
  local job_args = { BASH, SCRIPT }
  vim.list_extend(job_args, args)
  vim.fn.jobstart(job_args, {
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
        local msg = table.concat(vim.tbl_filter(function(s) return s ~= "" end, out), " ")
        notify(describe .. " failed (exit " .. code .. "): " .. msg, vim.log.levels.ERROR)
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

local function vote_pr()
  local pr = current_pr()
  if not pr then return end
  local choices = { "Vote on PR #" .. pr.id .. ":" }
  for i, o in ipairs(VOTE_OPTIONS) do
    choices[#choices + 1] = i .. ": " .. o.label
  end
  local idx = tonumber(vim.fn.inputlist(choices))
  if not idx or idx < 1 or idx > #VOTE_OPTIONS then
    notify("Cancelled.")
    return
  end
  run_action({ "--vote", VOTE_OPTIONS[idx].key }, "Voting on")
end

local MERGE_TYPES = {
  { key = "squash",        label = "Squash commit" },
  { key = "noFastForward", label = "Merge (no fast forward)" },
  { key = "rebase",        label = "Rebase and fast-forward" },
  { key = "rebaseMerge",   label = "Semi-linear merge" },
}

local function complete_pr()
  local pr = current_pr()
  if not pr then return end
  local choices = { "Complete PR #" .. pr.id .. " with:" }
  for i, o in ipairs(MERGE_TYPES) do
    choices[#choices + 1] = i .. ": " .. o.label
  end
  local idx = tonumber(vim.fn.inputlist(choices))
  if not idx or idx < 1 or idx > #MERGE_TYPES then
    notify("Cancelled.")
    return
  end
  -- Defaults: delete source branch + transition work items (like the web UI).
  run_action({ "--complete", MERGE_TYPES[idx].key, "true", "true" }, "Completing")
end

-- Toggle "complete automatically when requirements are met" (auto-complete)
-- on the PR under the cursor, mirroring the web UI's completion-dialog
-- checkbox. When already on, offers to cancel it; otherwise prompts for a
-- merge strategy the same way gm/complete_pr does.
local function toggle_auto_complete()
  local pr = current_pr()
  if not pr then return end
  if pr.autoComplete then
    local choices = {
      "PR #" .. pr.id .. " has auto-complete on" ..
        (pr.autoCompleteSetBy ~= "" and (" (by " .. pr.autoCompleteSetBy .. ")") or "") .. ".",
      "1: Cancel auto-complete",
    }
    local idx = tonumber(vim.fn.inputlist(choices))
    if idx ~= 1 then
      notify("Cancelled.")
      return
    end
    run_action({ "--auto-complete", "off" }, "Cancelling auto-complete on")
    return
  end

  local choices = { "Auto-complete PR #" .. pr.id .. " with:" }
  for i, o in ipairs(MERGE_TYPES) do
    choices[#choices + 1] = i .. ": " .. o.label
  end
  local idx = tonumber(vim.fn.inputlist(choices))
  if not idx or idx < 1 or idx > #MERGE_TYPES then
    notify("Cancelled.")
    return
  end
  -- Defaults: delete source branch + transition work items (like the web UI).
  run_action({ "--auto-complete", "on", MERGE_TYPES[idx].key, "true", "true" }, "Setting auto-complete on")
end

-- Re-queue the build validation (e.g. an expired build) for the PR under the cursor.
local function requeue_pr()
  local pr = current_pr()
  if not pr then return end
  notify("Re-queuing build for PR #" .. pr.id .. " \u{2026}")
  local out = {}
  vim.fn.jobstart({ EXE, "--requeue", tostring(pr.id) }, {
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
vim.bo[buf].filetype = "prdash"
vim.api.nvim_set_current_buf(buf)
win = vim.api.nvim_get_current_win()
pcall(function()
  vim.wo[win].winbar = BASE_WINBAR
end)

local opts = { buffer = buf, silent = true, nowait = true }
vim.keymap.set("n", "<CR>", open_pr, opts)
vim.keymap.set("n", "gy", yank_link, opts)
vim.keymap.set("n", "o", open_browser, opts)
vim.keymap.set("n", "gd", show_description, opts)
vim.keymap.set("n", "/", set_filter, opts)
vim.keymap.set("n", "gv", vote_pr, opts)
vim.keymap.set("n", "gm", complete_pr, opts)
vim.keymap.set("n", "ga", toggle_auto_complete, opts)
vim.keymap.set("n", "gr", requeue_pr, opts)
vim.keymap.set("n", "gO", open_config_file, opts)
vim.keymap.set("n", "r", function() load(false, true) end, opts)
vim.keymap.set("n", "W", function()
  vim.cmd("luafile " .. vim.fn.fnameescape(WI_DASH_LUA))
end, opts)
vim.keymap.set("n", "q", "<Cmd>qa!<CR>", opts)

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
if _G.PR_DASH_TIMER then pcall(vim.fn.timer_stop, _G.PR_DASH_TIMER) end
_G.PR_DASH_TIMER = vim.fn.timer_start(60000, function()
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
  if _G.WI_LIST_CACHE and _G.WI_LIST_CACHE.items then return end
  local out = {}
  vim.fn.jobstart({ BASH, WI_LIST }, {
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
      _G.WI_LIST_CACHE = {
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

load(false)
prefetch_work_items()
