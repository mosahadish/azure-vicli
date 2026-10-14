-- lua/azure-cli/chat/threads.lua: "why did you choose this here?" - a
-- question about one line of the agent's work, asked from that line and
-- answered under it, the way a review thread sits under its line in the
-- reviewer. Shared by the plan window (chat/plan.lua) and the change viewer
-- (chat/changes.lua); each keeps its own threads and says where a thread's
-- line is on screen.
--
-- A thread is { id, line, anchor, file?, section?, question, answer?,
-- status = "asking"|"answered"|"failed", at, agent? } - or, with kind =
-- "request", a change asked for on that line (status "queued"|"sent"): `line` is the line
-- in the plan / the file (new side), `anchor` that line's text, so it can
-- find its line again after the text around it changed (M.reanchor).
--
-- The question goes through the chat like any message (it shows in the
-- conversation, the agent sees the screen and line), and the answer lands
-- both there and under the line.
--
--   pure:   wrap, virt_lines, reanchor, message, at_line, pick_at_line, counts, count_label
--   Neovim: draw, ask, show
local M = {}

M.ns = vim.api.nvim_create_namespace("azure_cli_threads")

M.SPINNER = { "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" }

-- `text` word-wrapped to `width` cells (`dw` measures a string's width,
-- default its length), keeping its own line breaks and blank lines. Pure.
function M.wrap(text, width, dw)
  dw = dw or function(s) return #s end
  width = math.max(10, width or 60)
  local out = {}
  for para in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do
    if para:match("^%s*$") then
      out[#out + 1] = ""
    else
      local indent = para:match("^(%s*)") or ""
      local line = ""
      for word in para:gmatch("%S+") do
        local cand = line == "" and (indent .. word) or (line .. " " .. word)
        if line ~= "" and dw(cand) > width then
          out[#out + 1] = line
          line = indent .. word
        else
          line = cand
        end
      end
      out[#out + 1] = line
    end
  end
  while #out > 0 and out[#out] == "" do table.remove(out) end
  return out
end

-- The virt_lines drawn under a thread's line: the question, then the
-- answer (its first ANSWER_LINES lines unless `opts.expanded`), each behind
-- a bar. opts: width (cells for the text), expanded, frame (spinner
-- frame while asking), dw (width function), indent (cells before the bar),
-- send (the key that sends queued change requests - the plan's gR, the
-- change viewer's gS), drop / edit (the keys that drop / edit a queued
-- one - the plan's dd / cc; left out, they aren't mentioned). Pure.
M.ANSWER_LINES = 4
function M.virt_lines(th, opts)
  opts = opts or {}
  -- The bar and the "? " / "↳ " take 4 cells; a few more spare, so a wide
  -- character or a sign column never pushes the text off the window.
  local width = math.max(20, (opts.width or 80) - 8 - (opts.indent or 0))
  local pad = string.rep(" ", opts.indent or 0)
  local bar = { pad .. "\u{2503} ", "AzureCliThreadBar" }
  local out = {}
  if th.kind == "answer" then
    -- Your answer to one of the plan's open questions (chat/plan.lua's gr).
    for i, l in ipairs(M.wrap(th.question or "", width, opts.dw)) do
      out[#out + 1] = { bar, { (i == 1 and "\u{21AA} you: " or "       ") .. l, "AzureCliStatusOk" } }
    end
    out[#out + 1] = { bar, { th.status == "sent" and "  sent to the agent"
      or ("  not sent yet - " .. (opts.send or "gR") .. " sends it (approving does too)"), "AzureCliThreadMeta" } }
    return out
  end
  if th.kind == "request" then
    -- A change you asked for on this line (the plan's gc, the change
    -- viewer's c): sent with the others by opts.send.
    for i, l in ipairs(M.wrap(th.question or "", width, opts.dw)) do
      out[#out + 1] = { bar, { (i == 1 and "\u{270E} " or "  ") .. l, "AzureCliThreadRequest" } }
    end
    local meta = "  sent with your change request"
    if th.status ~= "sent" then
      meta = "  queued - " .. (opts.send or "gR") .. " sends it, with the others"
      local how = {}
      if opts.drop then how[#how + 1] = opts.drop .. " drops" end
      if opts.edit then how[#how + 1] = opts.edit .. " edits" end
      if #how > 0 then meta = meta .. " \u{00B7} " .. table.concat(how, ", ") end
    end
    out[#out + 1] = { bar, { meta, "AzureCliThreadMeta" } }
    return out
  end
  local q = M.wrap(th.question or "", width, opts.dw)
  for i, l in ipairs(q) do
    out[#out + 1] = { bar, { (i == 1 and "? " or "  ") .. l, "AzureCliThreadQuestion" } }
  end
  if th.status == "asking" then
    out[#out + 1] = { bar, { (opts.frame or "\u{2026}") .. " asking " .. (th.agent or "the agent") .. "\u{2026}",
      "AzureCliThreadMeta" } }
    return out
  end
  local a = M.wrap(th.answer or "", width, opts.dw)
  if #a == 0 then a = { th.status == "failed" and "(no answer)" or "" } end
  local shown = opts.expanded and #a or math.min(#a, M.ANSWER_LINES)
  for i = 1, shown do
    local hl = th.status == "failed" and "AzureCliStatusBad" or "AzureCliThreadAnswer"
    out[#out + 1] = { bar, { (i == 1 and "\u{21B3} " or "  ") .. a[i], hl } }
  end
  if shown < #a then
    out[#out + 1] = { bar, { "  \u{2026} " .. (#a - shown) .. " more line" .. (#a - shown == 1 and "" or "s")
      .. " - <Tab>", "AzureCliThreadMeta" } }
  end
  if th.outdated then
    out[#out + 1] = { bar, { "  (its line changed since - it was: " .. tostring(th.anchor or "") .. ")", "AzureCliThreadMeta" } }
  end
  return out
end

local function norm(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Moves each thread in `threads` onto the line of `lines` (line number ->
-- text; a list, or sparse like a diff's lines of one file) whose text is
-- its anchor, the nearest one to where it was; a thread whose line is gone
-- keeps its place (clamped to the text) and is marked outdated. `skip(th)`
-- leaves a thread alone (another file's). Changes the threads in place.
-- Pure.
function M.reanchor(threads, lines, skip)
  local last = 0
  for i in pairs(lines) do if i > last then last = i end end
  for _, th in ipairs(threads or {}) do
    if not (skip and skip(th)) then
      local want, best = norm(th.anchor), nil
      local at = th.line or 1
      if want ~= "" then
        for i, l in pairs(lines) do
          if norm(l) == want and (not best or math.abs(i - at) < math.abs(best - at)
              or (math.abs(i - at) == math.abs(best - at) and i < best)) then
            best = i
          end
        end
      end
      if best then
        th.line, th.outdated = best, nil
      else
        th.line = math.max(1, math.min(at, math.max(1, last)))
        th.outdated = want ~= "" and true or nil
      end
    end
  end
  return threads
end

-- The message a question sends the agent. `ctx` = { what = "your plan for
-- #3001", where = "section \"Approach\", line 12" }. Pure.
function M.message(ctx, question, quote)
  local parts = { "About " .. tostring(ctx.what) .. (ctx.where and (", " .. ctx.where) or "") .. ":" }
  if quote and norm(quote) ~= "" then
    for l in (quote .. "\n"):gmatch("(.-)\r?\n") do parts[#parts + 1] = "> " .. l end
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = question
  parts[#parts + 1] = ""
  parts[#parts + 1] = "(Answer that question only, briefly - your answer is shown under that line. Don't change "
    .. "anything; if it should change, say how and I'll ask for it.)"
  return table.concat(parts, "\n")
end

-- The thread on line `line` (the first one), or nil. Pure.
function M.at_line(threads, line, match)
  for i, th in ipairs(threads or {}) do
    if th.line == line and (not match or match(th)) then return th, i end
  end
  return nil
end

-- The thread on line `line` that dd / cc act on, its index, and what it is:
-- a change still queued ("queued") first - a question on the same line
-- mustn't hide it - then a question or answer ("thread"), then a change
-- already sent ("sent", which stays as history). nil on a line with none.
-- Pure.
function M.pick_at_line(threads, line)
  local function queued(th) return th.kind == "request" and th.status ~= "sent" end
  local th, i = M.at_line(threads, line, queued)
  if th then return th, i, "queued" end
  th, i = M.at_line(threads, line, function(t) return t.kind ~= "request" end)
  if th then return th, i, "thread" end
  th, i = M.at_line(threads, line)
  if th then return th, i, "sent" end
  return nil
end

-- How many of `threads` are questions (not change requests), and how many
-- requests are still queued. Pure.
function M.counts(threads)
  local q, r = 0, 0
  for _, th in ipairs(threads or {}) do
    if th.kind == "request" then
      if th.status ~= "sent" then r = r + 1 end
    elseif th.kind ~= "answer" then
      q = q + 1
    end
  end
  return q, r
end

-- "2 questions" / "1 question" / "" for a list of threads (or a count) -
-- for a winbar. Pure.
function M.count_label(threads)
  local n = type(threads) == "number" and threads or (M.counts(threads))
  if n == 0 then return "" end
  return n .. " question" .. (n == 1 and "" or "s")
end

-- ---------------------------------------------------------------------------
-- Neovim.

local expanded = {}  -- thread id -> true while <Tab> has it expanded
local spinning = {}  -- buf -> timer, while one of its threads is asking

function M.toggle(th)
  if th then expanded[th.id] = not expanded[th.id] or nil end
end

-- Draws `threads` in `buf`: under buffer row `row_of(th)` (1-based; nil
-- skips the thread) in window `win`'s width. Keeps a spinner turning
-- while one of them is being asked.
function M.draw(buf, win, threads, row_of, keys)
  if not vim.api.nvim_buf_is_valid(buf) then
    if spinning[buf] then
      spinning[buf]:stop()
      spinning[buf]:close()
      spinning[buf] = nil
    end
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local width = 80
  if win and vim.api.nvim_win_is_valid(win) then width = require("azure-cli.ui").text_width(win) end
  local asking = false
  local tick = math.floor((vim.uv or vim.loop).now() / 120)
  local n = vim.api.nvim_buf_line_count(buf)
  for _, th in ipairs(threads or {}) do
    local row = row_of(th)
    if row and row >= 1 and row <= n then
      if th.status == "asking" then asking = true end
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, {
        virt_lines = M.virt_lines(th, { width = width, expanded = expanded[th.id], dw = vim.fn.strdisplaywidth,
          frame = M.SPINNER[tick % #M.SPINNER + 1], send = keys and keys.send, drop = keys and keys.drop,
          edit = keys and keys.edit }),
        sign_text = th.kind == "request" and "\u{270E}" or (th.kind == "answer" and "\u{21AA}" or "?"),
        sign_hl_group = th.kind == "request" and "AzureCliThreadRequest" or "AzureCliThreadBar",
      })
    end
  end
  local timer = spinning[buf]
  if asking and not timer then
    timer = (vim.uv or vim.loop).new_timer()
    spinning[buf] = timer
    timer:start(120, 120, vim.schedule_wrap(function()
      if spinning[buf] ~= timer then return end
      M.draw(buf, win, threads, row_of, keys)
    end))
  elseif not asking and timer then
    spinning[buf] = nil
    timer:stop()
    timer:close()
  end
end

-- `ga`: asks the agent about buffer row `o.row` of window `o.win`. o:
--   line, anchor, file, section   what the thread records (see the top)
--   quote                         the text asked about (default: anchor) -
--                                 several lines for a visual selection
--   ctx                           for M.message: { what, where }
--   label                         the editor's title, e.g. "plan:12"
--   threads                       the list the new thread joins
--   changed()                     saves and redraws (called on every change)
-- The question is typed in the comment editor under the line.
function M.ask(o)
  local CHAT = require("azure-cli.chat")
  if not CHAT.current_agent() then
    return require("azure-cli.shell").notify("No chat agent is configured (docs/chat.md).", vim.log.levels.WARN)
  end
  if CHAT.busy() then
    return require("azure-cli.shell").notify("The agent is still answering - ask once it's done (or <C-c> in the chat).",
      vim.log.levels.WARN)
  end
  require("azure-cli.editor").open({
    title = "Ask " .. CHAT.agent_label() .. " \u{00B7} " .. o.label,
    anchor = { win = o.win, row = o.row },
    context_lines = (o.quote or o.anchor or "") ~= "" and vim.split(o.quote or o.anchor, "\n", { plain = true }) or nil,
    on_submit = function(question)
      local th = { id = tostring(os.time()) .. "-" .. math.random(1000, 9999), line = o.line, anchor = o.anchor,
        file = o.file, section = o.section, question = question, status = "asking", at = os.time(),
        agent = CHAT.agent_label() }
      table.insert(o.threads, th)
      o.changed()
      local entry = CHAT.send(M.message(o.ctx, question, o.quote or o.anchor), {
        view_win = o.win,
        display = question .. "  (" .. o.label .. ")",
        done_note = CHAT.agent_label() .. " answered under " .. o.label .. ".",
        on_done = function(e)
          th.answer = e.text
          th.status = e.status == "done" and "answered" or "failed"
          o.changed()
        end,
      })
      if not entry or entry.status ~= "running" then
        th.status = "failed"
        th.answer = entry and entry.text or "Not sent - the agent was busy."
        o.changed()
      end
    end,
  })
end

-- K: the whole thread in a float. `keys` as for M.draw, plus ask (the key
-- that asks one).
function M.show(th, keys)
  keys = keys or {}
  if not th then
    return require("azure-cli.shell").notify("No question on this line (" .. (keys.ask or "ga") .. " asks one).")
  end
  if th.kind == "request" then
    return require("azure-cli.ui").open_float(vim.list_extend({ "\u{270E} Your change request" .. (th.status == "sent"
      and " (sent)" or (" (queued for " .. (keys.send or "gR") .. ")")), "" }, vim.split(th.question or "", "\n", { plain = true })),
      { title = "Line " .. tostring(th.line) })
  end
  local lines = { "? " .. (th.question or ""), "" }
  for _, l in ipairs(vim.split(th.answer or (th.status == "asking" and "(still asking...)" or ""), "\n", { plain = true })) do
    lines[#lines + 1] = l
  end
  local win, buf = require("azure-cli.ui").open_float(lines, { big = true, title = (th.agent or "Agent") .. " on line "
    .. tostring(th.line) })
  if buf then vim.bo[buf].filetype = "markdown" end
  return win
end

return M
