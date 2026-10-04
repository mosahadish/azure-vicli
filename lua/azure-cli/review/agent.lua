-- lua/azure-cli/review/agent.lua: agent actions in the reviewer - a
-- reviewer-feature module (see docs/development.md, "Extending the
-- reviewer") on top of lua/azure-cli/agent.lua, which runs the actions and
-- stores their results.
--
--   gX  (file list / diff / Overview)  pick an agent action to run on this
--       PR in the background. From the diff pane the action also gets the
--       cursor's {file}/{line}/{side}, and {thread_id} on a commented line.
--   gz  the Agent page: the newest result for this PR (the running one
--       while it runs), in the diff pane like the Overview - the agent's
--       markdown, then its suggestions. <CR> goes to what a suggestion is
--       about, ga drafts it, ]a/[a step through them, gz there picks an
--       older result.
--   Inline: the suggestions of the newest result that has any (or the one
--       the Agent page shows) appear as virtual lines under the thread or
--       line they name, in the diff pane and on the Overview; ga on that
--       line drafts it, ]a/[a jump between them.
--
-- "Drafting" never posts: it turns batch review on for this PR (gB's mode -
-- review/batch.lua) and opens the usual comment editor prefilled with the
-- suggested reply/comment. Submitting the editor queues it; gQ lists the
-- queue and gS posts it. A reply prefill goes through the editor's draft
-- store (editor.lua's draft_key), so reply_to_thread's own editor finds it
-- - unless you already have a draft there, which wins.
--
-- review/init.lua calls M.decorate(buf) at the end of decorate_comments
-- and render_overview, M.tag() from EXT.mode_tags, and M.cleanup() from
-- STATE.review_cleanup. The dashboard reaches the Agent page through
-- STATE.agent_open_page (set before opening the PR) or, when this PR is
-- already open, STATE.agent_page_openers[id].
local M = {}

-- Suggestion virtual lines: what each kind of item drafts.
local DRAFT_LABEL = {
  thread = "reply", line = "new comment", file = "new file comment", pr = "new PR comment",
}

-- The virtual lines one suggestion renders as under its line: a heading,
-- then up to four lines of note and of draft text. Pure - (item, label)
-- in, a list of {{text, hl}} chunks out.
function M.virt_lines(it, label)
  local out = {}
  local head = "    \u{2726} " .. (label or "agent")
  if it.verdict then head = head .. " \u{00B7} " .. it.verdict end
  if it.accepted then
    head = head .. "  \u{2713} drafted"
  elseif it.text then
    head = head .. "  (ga drafts the " .. (DRAFT_LABEL[it.kind] or "comment") .. ")"
  end
  out[#out + 1] = { { head, "AzureCliSuggestHead" } }
  local function block(text, prefix)
    local n = 0
    for l in (text .. "\n"):gmatch("(.-)\n") do
      n = n + 1
      if n > 4 then
        out[#out + 1] = { { "      " .. prefix .. "\u{2026}", "AzureCliSuggest" } }
        return
      end
      out[#out + 1] = { { "      " .. prefix .. l, "AzureCliSuggest" } }
    end
  end
  if it.note then block(it.note, "") end
  if it.text then block(it.text, "> ") end
  return out
end

local function setup(ctx)
  local AG = require("azure-cli.agent")
  local STATE = require("azure-cli.state")
  local KEYS = require("azure-cli.keys")
  local UI = require("azure-cli.ui")
  local ID = tostring(ctx.ID)
  local ns = vim.api.nvim_create_namespace("azure_cli_agent_suggest")
  UI.link_hl({ AzureCliSuggest = "DiagnosticHint", AzureCliSuggestHead = "DiagnosticInfo" })

  local page_buf, page_run, page_item_at = nil, nil, {}
  local marks_by_buf = {}  -- buf -> { [bufline] = { item, ... } }
  local listener_key = "review:" .. ID

  -- This PR's record (the list's, when there is one), else what the
  -- reviewer was opened with.
  local function pr_record()
    local rec = ctx.current_pr_record()
    if rec and tostring(rec.id) == ID then return rec end
    return { id = ID, org = ctx.ORG, project = ctx.PROJECT, repo = vim.env.AZVICLI_REPO or "" }
  end

  local function shown_in_diff_win(buf)
    local dw = ctx.diff_win()
    return buf and dw and vim.api.nvim_win_is_valid(dw) and vim.api.nvim_win_get_buf(dw) == buf
  end

  -- The run whose suggestions are anchored inline: the one the Agent page
  -- shows when it has any, else the newest that has any.
  local function inline_run()
    if page_run and page_run.items and #page_run.items > 0 then return page_run end
    return AG.latest_with_items(ID)
  end

  -- -------------------------------------------------------------------
  -- Inline suggestions.

  local function decorate(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    marks_by_buf[buf] = nil
    local run = inline_run()
    if not run then return end
    local by_thread, by_loc, by_file, general = {}, {}, {}, {}
    local function push(tbl, key, it)
      tbl[key] = tbl[key] or {}
      table.insert(tbl[key], it)
    end
    for _, it in ipairs(run.items) do
      if it.kind == "thread" then
        push(by_thread, tostring(it.thread_id), it)
      elseif it.file and it.line then
        push(by_loc, it.file .. "\t" .. it.side .. "\t" .. it.line, it)
      elseif it.file then
        push(by_file, it.file, it)
      else
        general[#general + 1] = it
      end
    end
    local marks = {}
    local function add(bl, it)
      marks[bl] = marks[bl] or {}
      for _, x in ipairs(marks[bl]) do if x == it then return end end
      table.insert(marks[bl], it)
    end
    for bl, threads in pairs(ctx.comments_by_buf[buf] or {}) do
      for _, t in ipairs(threads) do
        for _, it in ipairs(by_thread[tostring(t.id)] or {}) do add(bl, it) end
      end
    end
    local path, map = ctx.paths_by_buf[buf], ctx.maps_by_buf[buf]
    if path and map then
      for bl, m in ipairs(map) do
        if m.side and m.lineno then
          for _, it in ipairs(by_loc[path .. "\t" .. m.side .. "\t" .. m.lineno] or {}) do add(bl, it) end
        end
      end
      if #map >= 1 then
        for _, it in ipairs(by_file[path] or {}) do add(1, it) end
      end
    elseif buf == ctx.overview_buf() then
      for _, it in ipairs(general) do add(1, it) end
    end
    if next(marks) == nil then return end
    for bl, items in pairs(marks) do
      local virt = {}
      for _, it in ipairs(items) do vim.list_extend(virt, M.virt_lines(it, run.label)) end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, bl - 1, 0, { virt_lines = virt })
    end
    marks_by_buf[buf] = marks
    -- A suggestion on an unchanged line must not fold away (review/pane.lua
    -- keeps commented lines; add these to its set).
    local PANE = require("azure-cli.review.pane")
    local entry = PANE.entry(buf)
    if entry then
      local keep = {}
      for k, v in pairs(entry.keep or {}) do keep[k] = v end
      for bl in pairs(marks) do keep[bl] = keep[bl] or true end
      PANE.set_keep(buf, keep)
      if shown_in_diff_win(buf) then PANE.refresh(ctx.diff_win(), buf) end
    end
  end

  local function redecorate()
    for buf in pairs(ctx.paths_by_buf) do
      if vim.api.nvim_buf_is_valid(buf) then decorate(buf) end
    end
    local ob = ctx.overview_buf()
    if ob then decorate(ob) end
  end

  -- -------------------------------------------------------------------
  -- Drafting a suggestion.

  local function mentions()
    local out = {}
    for _, r in ipairs((pr_record() or {}).reviewers or {}) do
      if r.name and r.name ~= "" then out[#out + 1] = { name = r.name, id = r.id } end
    end
    return out
  end

  local function ensure_batch()
    STATE.batch = STATE.batch or {}
    local s = STATE.batch[ID]
    if not s then
      s = { on = false, items = {} }
      STATE.batch[ID] = s
    end
    if not s.on then
      s.on = true
      ctx.notify("Batch review is on for this PR: drafted suggestions are queued, not sent (gQ lists them, gS submits).")
    end
  end

  local render_page  -- assigned below

  local function accept(run, it)
    if not it then return end
    if it.kind == "note" or not it.text then
      ctx.notify("That suggestion is a note - there's nothing to draft.", vim.log.levels.WARN)
      return
    end
    local EDITOR = require("azure-cli.editor")
    local function drafted()
      if not it.accepted then
        it.accepted = true
        AG.save(run)
      end
      redecorate()
      if render_page then render_page() end
    end
    ensure_batch()
    if it.kind == "thread" then
      local t = ctx.find_thread(it.thread_id)
      if not t then
        ctx.notify("Thread #" .. tostring(it.thread_id) .. " isn't on this PR (any more).", vim.log.levels.WARN)
        return
      end
      STATE.editor_drafts = STATE.editor_drafts or {}
      local key = EDITOR.draft_key(ID, "reply", tostring(t.id))
      if not EDITOR.get_draft(STATE.editor_drafts, key) then EDITOR.set_draft(STATE.editor_drafts, key, it.text) end
      ctx.reply_to_thread(t, function()
        drafted()
        ctx.redraw()
      end)
      return
    end
    local function open_editor(kind, info, draft_key, post)
      EDITOR.open({
        title = EDITOR.format_title(kind, info), initial = it.text, anchor = "center",
        mentions = mentions(), draft_key = draft_key,
        on_submit = function(text)
          post(text)
          drafted()
        end,
      })
    end
    if it.kind == "line" then
      local where = it.file .. "\t" .. it.side .. "\t" .. it.line
      local loc = it.file .. " " .. it.side .. ":" .. it.line .. (it.end_line and ("-" .. it.end_line) or "")
      open_editor(it.end_line and "range" or "line", { path = it.file, lineno = it.line, end_lineno = it.end_line },
        EDITOR.draft_key(ID, "line", where), function(text)
          local args = { "--post", it.file, it.side, tostring(it.line), text }
          if it.end_line then args[#args + 1] = tostring(it.end_line) end
          ctx.post_new_thread(args, "line", where, it.file, it.side, it.line, text,
            "Comment on " .. loc, "comment (" .. loc .. ")", it.end_line)
        end)
    elseif it.kind == "file" then
      open_editor("file", { path = it.file }, EDITOR.draft_key(ID, "file", it.file), function(text)
        ctx.post_new_thread({ "--file-comment", it.file, text }, "file", it.file, it.file, nil, nil, text,
          "File comment on " .. it.file, "file comment (" .. it.file .. ")")
      end)
    else
      open_editor("pr", {}, EDITOR.draft_key(ID, "pr", ""), function(text)
        ctx.post_new_thread({ "--pr-comment", text }, "general", nil, nil, nil, nil, text,
          "PR comment", "PR comment (#" .. ID .. ")")
      end)
    end
  end

  -- Picks among several suggestions on one line, cb(item).
  local function pick_item(items, cb)
    if #items == 1 then cb(items[1]) return end
    local list = {}
    for _, it in ipairs(items) do
      list[#list + 1] = { label = AG.item_location(it) .. (it.verdict and ("  [" .. it.verdict .. "]") or ""), it = it }
    end
    require("azure-cli.prompt").select({ prompt = "Which suggestion?", items = list }, function(c)
      if c then cb(c.it) end
    end)
  end

  local function accept_here()
    local buf = vim.api.nvim_get_current_buf()
    local items = (marks_by_buf[buf] or {})[vim.api.nvim_win_get_cursor(0)[1]]
    local run = inline_run()
    if not (items and run) then
      ctx.notify("No agent suggestion on this line (]a jumps to the next one, gz shows them all).")
      return
    end
    pick_item(items, function(it) accept(run, it) end)
  end

  local function jump_lines(lines_set, dir)
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local best
    for l in pairs(lines_set) do
      if (dir > 0 and l > cur and (not best or l < best)) or (dir < 0 and l < cur and (not best or l > best)) then
        best = l
      end
    end
    if not best then
      ctx.notify(dir > 0 and "No further suggestions here." or "No previous suggestions here.")
      return
    end
    vim.api.nvim_win_set_cursor(0, { best, 0 })
    vim.cmd("normal! zz")
  end

  local function jump_inline(dir)
    local marks = marks_by_buf[vim.api.nvim_get_current_buf()]
    if not marks then
      ctx.notify("No agent suggestions in this view (gz shows them all).")
      return
    end
    jump_lines(marks, dir)
  end

  -- -------------------------------------------------------------------
  -- Going to what a suggestion is about.

  local function open_at_line(path, side, lineno)
    ctx.open_file(path, true)
    if not (side and lineno) then return end
    ctx.ensure_diff_content(path, function()
      vim.schedule(function()
        local dw = ctx.diff_win()
        if not (dw and vim.api.nvim_win_is_valid(dw)) then return end
        local buf = vim.api.nvim_win_get_buf(dw)
        if ctx.paths_by_buf[buf] ~= path then return end
        for i, m in ipairs(ctx.maps_by_buf[buf] or {}) do
          if m.side == side and m.lineno == lineno then
            pcall(vim.api.nvim_win_set_cursor, dw, { i, 0 })
            vim.api.nvim_win_call(dw, function() vim.cmd("normal! zz") end)
            return
          end
        end
      end)
    end)
  end

  local function go_to(it)
    if it.kind == "thread" then
      local t = ctx.find_thread(it.thread_id)
      if not t then
        ctx.notify("Thread #" .. tostring(it.thread_id) .. " isn't on this PR (any more).", vim.log.levels.WARN)
        return
      end
      if t.path then
        open_at_line(t.path, t.side, t.lineno)
        return
      end
      ctx.open_overview(true)
      local ob = ctx.overview_buf()
      for bl, threads in pairs(ctx.comments_by_buf[ob] or {}) do
        for _, x in ipairs(threads) do
          if x == t then pcall(vim.api.nvim_win_set_cursor, ctx.diff_win(), { bl, 0 }) return end
        end
      end
    elseif it.file then
      open_at_line(it.file, it.line and it.side or nil, it.line)
    else
      ctx.open_overview(true)
    end
  end

  -- -------------------------------------------------------------------
  -- The Agent page.

  local function set_page_winbar()
    local dw = ctx.diff_win()
    if not (dw and vim.api.nvim_win_is_valid(dw) and shown_in_diff_win(page_buf)) then return end
    local parts = { "Agent" }
    if page_run then parts[#parts + 1] = page_run.label end
    parts[#parts + 1] = "PR #" .. ID
    UI.wo(dw, "winbar", UI.winbar(parts, ctx.ext.mode_tags and ctx.ext.mode_tags() or {}))
  end

  -- "R ask a follow-up · ga draft a suggestion · ..." from the configured
  -- keys, so the page says how to use it.
  local function page_footer()
    local parts = {}
    for _, p in ipairs({ { "reply", "ask a follow-up" }, { "accept", "draft a suggestion" },
        { "open", "go to it" }, { "help", "all keys" } }) do
      local k = KEYS.resolve("agent", p[1])
      if type(k) == "table" then k = k[1] end
      if k then parts[#parts + 1] = k .. " " .. p[2] end
    end
    return "_" .. table.concat(parts, " \u{00B7} ") .. "_"
  end

  render_page = function()
    if not (page_buf and vim.api.nvim_buf_is_valid(page_buf)) then return end
    local lines, item_at
    if page_run then
      lines, item_at = AG.render_lines(page_run, os.time(), page_footer())
    else
      lines, item_at = { "# Agent", "", "No agent results for this PR yet.", "",
        "gX runs one of the agent actions configured in setup({ agent_actions = ... }) - see docs/agents.md." }, {}
    end
    vim.bo[page_buf].modifiable = true
    vim.api.nvim_buf_set_lines(page_buf, 0, -1, false, lines)
    vim.bo[page_buf].modifiable = false
    page_item_at = item_at
    AG.highlight(page_buf, lines, item_at)
    if shown_in_diff_win(page_buf) and page_run then AG.mark_read(page_run) end
    set_page_winbar()
  end

  local function item_under_cursor()
    local idx = page_item_at[vim.api.nvim_win_get_cursor(0)[1]]
    return idx and page_run and page_run.items[idx] or nil
  end

  local function page_headings()
    local set = {}
    local lines = vim.api.nvim_buf_get_lines(page_buf, 0, -1, false)
    for ln, idx in pairs(page_item_at) do
      if idx and (lines[ln] or ""):match("^\u{25B8}") then set[ln] = true end
    end
    return set
  end

  local open_page  -- forward: the page's own keys reopen it with another run

  local PAGE_HELP = {
    "Navigate",
    { "open", "go to the thread / line the suggestion under the cursor is about" },
    { "next_suggestion", "next suggestion" }, { "prev_suggestion", "previous suggestion" },
    { "back", "back to the file list" },
    "Act",
    { "accept", "draft the suggestion (batch review: gQ lists the queue, gS submits it)" },
    { "reply", "ask the agent a follow-up question - it answers on this page" },
    { "runs", "show another result of this PR" },
    { "run", "run an agent action (or cancel a running one)" },
    "Session",
    { "help", "this help" }, { "quit", "close the reviewer" },
  }

  local function ensure_page_buf()
    if page_buf and vim.api.nvim_buf_is_valid(page_buf) then return end
    page_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[page_buf].buftype = "nofile"
    vim.bo[page_buf].filetype = "markdown"
    vim.bo[page_buf].modifiable = false
    local b = page_buf
    KEYS.bind(b, "agent", "open", function()
      local it = item_under_cursor()
      if it then go_to(it) else ctx.notify("Not on a suggestion.") end
    end, { desc = "go to what the suggestion is about" })
    KEYS.bind(b, "agent", "accept", function()
      local it = item_under_cursor()
      if it then accept(page_run, it) else ctx.notify("Not on a suggestion.") end
    end, { desc = "draft the suggestion" })
    KEYS.bind(b, "agent", "next_suggestion", function() jump_lines(page_headings(), 1) end, { desc = "next suggestion" })
    KEYS.bind(b, "agent", "prev_suggestion", function() jump_lines(page_headings(), -1) end, { desc = "previous suggestion" })
    KEYS.bind(b, "agent", "reply", function() M.ask() end, { desc = "ask the agent a follow-up question" })
    KEYS.bind(b, "agent", "runs", function()
      AG.choose_run(ID, function(r) open_page(r, true) end)
    end, { desc = "show another result" })
    KEYS.bind(b, "agent", "run", function() M.run_action() end, { desc = "run an agent action" })
    KEYS.bind(b, "agent", "back", function()
      local lw = ctx.list_win()
      if lw and vim.api.nvim_win_is_valid(lw) then vim.api.nvim_set_current_win(lw) end
    end, { desc = "back to the file list" })
    KEYS.bind(b, "agent", "help", function()
      ctx.open_float(KEYS.help_lines("agent", "Agent page keys", PAGE_HELP, {
        now = ctx.ext.mode_tags and ctx.ext.mode_tags() or {}, fixed = { "  j / k       move" },
      }), true, { min_width = 60 })
    end, { desc = "this help" })
    KEYS.bind(b, "agent", "quit", function() ctx.leave() end, { desc = "close the reviewer" })
  end

  -- Shows `run` (default: this PR's newest) on the Agent page in the diff
  -- pane; focus moves the cursor there.
  open_page = function(run, focus)
    page_run = run or AG.runs(ID)[1]
    ensure_page_buf()
    local dw = ctx.diff_win()
    if not (dw and vim.api.nvim_win_is_valid(dw)) then return end
    vim.api.nvim_win_set_buf(dw, page_buf)
    UI.plain_window(dw, {})
    UI.wo(dw, "wrap", true)
    UI.wo(dw, "linebreak", true)
    if ctx.mark_current_file then ctx.mark_current_file(nil) end
    render_page()
    if focus then
      vim.api.nvim_set_current_win(dw)
      pcall(vim.api.nvim_win_set_cursor, dw, { 1, 0 })
    end
    -- The run shown here is the one anchored inline now.
    redecorate()
  end

  -- -------------------------------------------------------------------
  -- Running.

  -- What agent.lua needs to run something for this PR (M.start/M.followup).
  local function base_info()
    local pr = pr_record()
    return {
      pr = pr, repo_path = ctx.REPO_PATH, source = ctx.SOURCE, target = ctx.TARGET,
      is_author = AG.is_author(pr), result_hint = "gz shows it",
      -- Explicit rather than inherited: the process env names whichever PR
      -- the dashboard opened last, which needn't be this one.
      env = {
        AZVICLI_PR = ID, AZVICLI_ORG = ctx.ORG, AZVICLI_PROJECT = ctx.PROJECT,
        AZVICLI_REPO = pr.repo or vim.env.AZVICLI_REPO or "", AZVICLI_SOURCE = ctx.SOURCE,
        AZVICLI_TARGET = ctx.TARGET, AZVICLI_REPO_PATH = ctx.REPO_PATH,
      },
      open_results = function() open_page(nil, true) end,
    }
  end

  function M.run_action()
    local buf = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local info = base_info()
    local path = ctx.paths_by_buf[buf]
    info.surface = path and "diff" or (buf == ctx.overview_buf() and "overview" or (buf == page_buf and "agent" or "list"))
    if path then
      info.file = path
      local m = (ctx.maps_by_buf[buf] or {})[lnum]
      if m and m.side then info.side, info.line = m.side, m.lineno end
    end
    local threads = (ctx.comments_by_buf[buf] or {})[lnum]
    if threads and threads[1] and type(threads[1].id) == "number" then info.thread_id = threads[1].id end
    AG.pick(info)
  end

  -- R on the Agent page: ask the agent behind the shown result a follow-up
  -- question. Its answer is appended to the same page (agent.lua's
  -- M.followup resumes the agent's session when the action says how, or
  -- replays the conversation to it otherwise).
  function M.ask()
    local run = page_run
    if not run then
      ctx.notify("No agent result to ask about yet (gX runs an action).")
      return
    end
    if run.status == "running" then
      ctx.notify(run.label .. " is still working on its first answer.", vim.log.levels.WARN)
      return
    end
    local spec = AG.configured()[run.action]
    if not spec then
      ctx.notify("The action \"" .. tostring(run.action) .. "\" isn't configured any more.", vim.log.levels.WARN)
      return
    end
    local EDITOR = require("azure-cli.editor")
    EDITOR.open({
      title = "Ask " .. run.label .. (AG.can_resume(spec, run) and "" or " (replays the conversation)"),
      anchor = "center",
      draft_key = EDITOR.draft_key(ID, "agent", run.id),
      on_submit = function(text)
        AG.followup(run, text, base_info())
        if page_run == run and shown_in_diff_win(page_buf) then
          render_page()
          local dw = ctx.diff_win()
          pcall(vim.api.nvim_win_set_cursor, dw, { vim.api.nvim_buf_line_count(page_buf), 0 })
        end
      end,
    })
  end

  for _, kind in ipairs({ "list", "diff", "overview" }) do
    ctx.add_key(kind, "agent", M.run_action, "run an agent action on this PR (headless; or cancel one, or see results)")
    ctx.add_key(kind, "agent_results", function() open_page(nil, true) end, "show the agent results (the Agent page)")
  end
  for _, kind in ipairs({ "diff", "overview" }) do
    ctx.add_key(kind, "agent_accept", accept_here, "draft the agent's suggestion on this line (queued for gS)")
    ctx.add_key(kind, "next_suggestion", function() jump_inline(1) end, "next agent suggestion")
    ctx.add_key(kind, "prev_suggestion", function() jump_inline(-1) end, "previous agent suggestion")
  end

  -- A run of this PR started, finished or was read: follow it on the page
  -- when that's showing, and redraw the inline suggestions and the winbar
  -- tag. Drops itself once the reviewer is gone.
  AG.subscribe(listener_key, function(pr_id, run)
    local lw = ctx.list_win()
    if not (lw and vim.api.nvim_win_is_valid(lw)) then
      AG.unsubscribe(listener_key)
      return
    end
    if pr_id ~= ID then return end
    if shown_in_diff_win(page_buf) then
      if run and (not page_run or page_run.status ~= "running" or page_run == run) then page_run = run end
      render_page()
    end
    ctx.redraw()
  end)

  STATE.agent_page_openers = STATE.agent_page_openers or {}
  local function opener()
    local lw = ctx.list_win()
    if not (lw and vim.api.nvim_win_is_valid(lw)) then return false end
    open_page(nil, true)
    return true
  end
  STATE.agent_page_openers[ID] = opener
  if STATE.agent_open_page == ID then
    STATE.agent_open_page = nil
    vim.defer_fn(function() opener() end, 100)
  end

  M.decorate = decorate
  M.tag = function()
    local s = AG.state(ID)
    if s == "running" then return "[agent: running]" end
    if s == "unread" then return "[agent: new result \u{00B7} gz]" end
    return ""
  end
  -- Called from STATE.review_cleanup: forget this reviewer and hand back
  -- the page buffer for it to wipe.
  M.cleanup = function()
    AG.unsubscribe(listener_key)
    if STATE.agent_page_openers and STATE.agent_page_openers[ID] == opener then
      STATE.agent_page_openers[ID] = nil
    end
    return page_buf
  end
  M.open_page = open_page
  M.accept = accept
  return M
end

return setmetatable(M, { __call = function(_, ctx) return setup(ctx) end })
