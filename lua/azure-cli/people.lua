-- lua/azure-cli/people.lua: finding people on a PR's host - gR's "add a
-- reviewer" and the comment editor's <C-t> "tag someone".
--
--   search        the provider's --find-people (Azure: Identities by name,
--                 account or email; GitHub: the repository's people by
--                 login or name, else that login) as a list of { name, id,
--                 account / login }; everyone found is remembered
--                 (hosts.remember), so "@" completion offers them after
--   pick          a popup listing everyone who can review (the project's
--                 teams / the repo's assignable people) that typing
--                 narrows fuzzily (rank), searching the host for more
--   add_reviewer  pick, then (Azure) optional or required, then
--                 --add-reviewer with the person's id
local M = {}

local function notify(msg, level) require("azure-cli.shell").notify(msg, level) end
local function T() return require("azure-cli.chat.tools") end
local function HOSTS() return require("azure-cli.hosts") end

-- cb(list) or cb(nil, err).
function M.search(pr, query, cb)
  T().provider({ "--find-people", query }, T().pr_env(pr), function(ok, out, err)
    if not ok then return cb(nil, (err ~= "" and err) or "the search failed") end
    local okj, list = pcall(vim.json.decode, out)
    if not okj or type(list) ~= "table" then return cb(nil, "the search gave an unexpected answer") end
    for _, p in ipairs(list) do HOSTS().remember(pr, p.id, p.name) end
    cb(list)
  end)
end

-- "Jane Doe  jane@contoso.com" / "Jane Doe  jdoe".
function M.label(p)
  local extra = p.account or p.login
  return tostring(p.name or p.id) .. ((extra and extra ~= "" and extra ~= p.name) and ("  " .. extra) or "")
end

-- How long typing has to pause before the host is searched, and how many
-- characters it takes.
M.DEBOUNCE_MS, M.MIN_CHARS, M.MAX_ROWS = 250, 2, 10

-- Lower-cased id -> true for `pr`'s reviewers: gR doesn't offer them.
local function reviewer_ids(pr)
  local out = {}
  for _, r in ipairs(type(pr.reviewers) == "table" and pr.reviewers or {}) do
    if r.id then out[tostring(r.id):lower()] = true end
  end
  return out
end

-- `pool` narrowed and ordered by `q`, fuzzily ("grgory" finds "Stein,
-- Gregory", "tal gross" finds "Gross, Tal"); the host's own answer to
-- `q` (`hits`) stays in even where the shown text doesn't match - it
-- matched an email or account the label doesn't show.
function M.rank(pool, q, hits)
  q = vim.trim(q or ""):gsub("[,;]", " ")
  if q == "" then return vim.list_slice(pool, 1, #pool) end
  local m = vim.fn.matchfuzzypos(pool, q, { text_cb = function(p) return M.label(p) end })
  -- A typed word that is a whole word of the name ("gross": "Gross, Tal")
  -- beats one that only starts a word ("Grossman, Avi"), which beats a
  -- scattered match - fuzzy scores alone put the shorter name first.
  local words = vim.split(q:lower(), "%s+", { trimempty = true })
  local scored = {}
  for i, p in ipairs(m[1]) do
    local score = m[3][i]
    for name_word in tostring(p.name or ""):lower():gmatch("[^%s,;]+") do
      for _, w in ipairs(words) do
        if name_word == w then score = score + 1000
        elseif name_word:sub(1, #w) == w then score = score + 500 end
      end
    end
    scored[i] = { p = p, score = score, i = i }
  end
  table.sort(scored, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.i < b.i end)
  local out = {}
  for i, s in ipairs(scored) do out[i] = s.p end
  local seen = {}
  for _, p in ipairs(out) do seen[tostring(p.id):lower()] = true end
  for _, p in ipairs(hits or {}) do
    if not seen[tostring(p.id):lower()] then
      seen[tostring(p.id):lower()] = true
      out[#out + 1] = p
    end
  end
  return out
end

-- Everyone who can review on a PR's project (Azure: its teams' members;
-- GitHub: the repository's assignable people), per project, for the
-- session: --find-people with no query, fetched once.
M.everyone = {}
local function everyone_key(pr)
  return table.concat({ HOSTS().host(pr), pr.org or "", pr.project or "", pr.repo or "" }, "|")
end

-- Asks for a person (`title` names what it's for) in a popup that lists
-- everyone who can review on the PR's project (M.everyone) as it opens;
-- typing narrows and orders that list (M.rank), and each pause in typing
-- also searches the host's directory and adds whoever else that finds -
-- only people the host itself returns, nobody from anywhere else.
-- cb(person) once one is picked, nothing on a cancel.
-- opts.skip_reviewers leaves out the PR's reviewers (gR).
function M.pick(pr, title, cb, opts)
  opts = opts or {}
  local UI = require("azure-cli.ui")
  local skip = opts.skip_reviewers and reviewer_ids(pr) or {}
  local pool, by_id, hits = {}, {}, {}
  local shown, sel, status, seq, timer, done = {}, 1, "", 0, nil, false
  local asked = {}

  local width = math.min(70, vim.o.columns - 4)
  local row = math.max(0, math.floor((vim.o.lines - M.MAX_ROWS - 5) / 2))
  local col = math.floor((vim.o.columns - width) / 2)
  local lbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[lbuf].bufhidden = "wipe"
  vim.bo[lbuf].filetype = "azure-cli-people-list"
  local lwin = vim.api.nvim_open_win(lbuf, false, { relative = "editor", row = row + 3, col = col,
    width = width, height = M.MAX_ROWS, style = "minimal", border = UI.border(), focusable = false })
  UI.float_hl(lwin)
  UI.wo(lwin, "winhighlight", UI.FLOAT_HL .. ",CursorLine:PmenuSel")
  UI.wo(lwin, "cursorline", true)
  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].bufhidden = "wipe"
  vim.bo[ibuf].filetype = "azure-cli-people"
  local iwin = vim.api.nvim_open_win(ibuf, true, { relative = "editor", row = row, col = col,
    width = width, height = 1, style = "minimal", border = UI.border(),
    title = " " .. title .. " - name, account or email ", title_pos = "left" })
  UI.float_hl(iwin)

  local function text()
    return vim.api.nvim_buf_is_valid(ibuf) and vim.trim(vim.api.nvim_buf_get_lines(ibuf, 0, 1, false)[1] or "") or ""
  end
  local function render()
    if done or not vim.api.nvim_win_is_valid(lwin) then return end
    local q = text()
    shown = M.rank(pool, q, hits[q])
    sel = math.max(1, math.min(sel, #shown))
    local lines = {}
    for i, p in ipairs(shown) do lines[i] = " " .. M.label(p) end
    if #lines == 0 then
      lines = { status ~= "" and "  " .. status or (q == "" and "  Nobody to list" or "  Nobody matches") }
    end
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
    pcall(vim.api.nvim_win_set_cursor, lwin, { sel, 0 })
    UI.wo(lwin, "cursorline", #shown > 0)
    local foot = (status ~= "" and status or (#shown .. (q == "" and " people" or " found"))) .. " \u{00B7} "
      .. "<CR> pick \u{00B7} <C-n>/<C-p> move \u{00B7} <Esc> cancel"
    pcall(vim.api.nvim_win_set_config, lwin, { footer = " " .. foot .. " ", footer_pos = "right" })
  end
  local function add(q, list)
    hits[q] = {}
    for _, p in ipairs(list or {}) do
      local k = tostring(p.id):lower()
      if not skip[k] then
        if not by_id[k] then
          by_id[k] = p
          pool[#pool + 1] = p
        end
        table.insert(hits[q], by_id[k])
      end
    end
  end
  -- q == "": everyone (M.everyone).
  local function search(q)
    if asked[q:lower()] then return render() end
    asked[q:lower()] = true
    seq = seq + 1
    local mine = seq
    status = q == "" and "loading people\u{2026}" or "searching\u{2026}"
    render()
    M.search(pr, q, function(list, err)
      if q == "" and list then M.everyone[everyone_key(pr)] = list end
      if done then return end
      if mine == seq then status = list and "" or ((q == "" and "couldn't list people: " or "search failed: ") .. tostring(err)) end
      add(q, list)
      render()
    end)
  end
  local function changed()
    if done then return end
    sel = 1
    render()
    local q = text()
    if timer then timer:stop() end
    if #q < M.MIN_CHARS then return end
    timer = timer or (vim.uv or vim.loop).new_timer()
    timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      if not done and text() == q then search(q) end
    end))
  end
  local function finish(p)
    if done then return end
    done = true
    if timer then timer:stop(); timer:close() end
    vim.cmd("stopinsert")
    for _, w in ipairs({ iwin, lwin }) do
      if vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
    if p then vim.schedule(function() cb(p) end) else notify("Cancelled.") end
  end
  local function move(d)
    if #shown == 0 then return end
    sel = (sel - 1 + d) % #shown + 1
    pcall(vim.api.nvim_win_set_cursor, lwin, { sel, 0 })
  end

  vim.api.nvim_buf_attach(ibuf, false, { on_lines = function()
    vim.schedule(changed)
  end })
  local kopts = { buffer = ibuf, silent = true, nowait = true }
  vim.keymap.set({ "i", "n" }, "<CR>", function() finish(shown[sel]) end, kopts)
  for _, k in ipairs({ "<Esc>", "<C-c>" }) do vim.keymap.set({ "i", "n" }, k, function() finish(nil) end, kopts) end
  vim.keymap.set("n", "q", function() finish(nil) end, kopts)
  for _, k in ipairs({ "<C-n>", "<Down>", "<Tab>", "<C-j>" }) do vim.keymap.set({ "i", "n" }, k, function() move(1) end, kopts) end
  for _, k in ipairs({ "<C-p>", "<Up>", "<S-Tab>", "<C-k>" }) do vim.keymap.set({ "i", "n" }, k, function() move(-1) end, kopts) end
  vim.api.nvim_create_autocmd("BufLeave", { buffer = ibuf, once = true, callback = function() finish(nil) end })
  local cached = M.everyone[everyone_key(pr)]
  if cached then
    asked[""] = true
    add("", cached)
    render()
  else
    search("")
  end
  vim.cmd("startinsert")
end

-- gR: adds a reviewer to `pr`, then on_done(person) once the host has
-- them (the record's reviewers list has them too, and the PR dashboard is
-- redrawn and refetched).
function M.add_reviewer(pr, on_done)
  if not pr then return notify("No PR here.", vim.log.levels.WARN) end
  if not HOSTS().caps(pr).add_reviewer then
    return notify("Adding reviewers isn't available for this PR.", vim.log.levels.WARN)
  end
  M.pick(pr, "Add a reviewer to " .. HOSTS().ref(pr), function(p)
    local function go(required)
      notify("Adding " .. p.name .. "\u{2026}")
      T().provider({ "--add-reviewer", tostring(p.id), required and "true" or "false" }, T().pr_env(pr),
        function(ok, out, err)
          if not ok then return notify("Couldn't add " .. p.name .. ": " .. err, vim.log.levels.ERROR) end
          pr.reviewers = pr.reviewers or {}
          local have = false
          for _, r in ipairs(pr.reviewers) do
            if tostring(r.id or ""):lower() == tostring(p.id):lower() then have = true end
          end
          if not have then
            table.insert(pr.reviewers, { name = p.name, id = p.id, vote = 0, isRequired = required or nil })
            require("azure-cli.prs").recompute(pr)
          end
          local okj, d = pcall(vim.json.decode, out)
          local note = okj and type(d) == "table" and d.note
          notify("Added " .. p.name .. " as a " .. (required and "required " or "") .. "reviewer"
            .. (note and (" (" .. note .. ")") or "") .. ".")
          -- The PR dashboard shows them at once (the record is its own),
          -- then as the host has them.
          local STATE = require("azure-cli.state")
          if STATE.PR_DASHBOARD_RENDER then STATE.PR_DASHBOARD_RENDER() end
          if STATE.PR_DASHBOARD_RELOAD then STATE.PR_DASHBOARD_RELOAD() end
          if on_done then on_done(p) end
        end)
    end
    if HOSTS().host(pr) == "azure" then
      require("azure-cli.prompt").select({ prompt = "Add " .. p.name .. " as", items = {
        { key = "optional", label = "Optional reviewer" },
        { key = "required", label = "Required reviewer" },
      } }, function(o) if o then go(o.key == "required") end end)
    else
      go(false)
    end
  end, { skip_reviewers = true })
end

return M
