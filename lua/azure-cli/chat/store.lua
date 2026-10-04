-- lua/azure-cli/chat/store.lua: what the chat keeps across restarts, under
-- stdpath("data")/azure-cli-chat/:
--
--   conversations/<id>.json  each conversation - its turns, the agent's
--                            session id, agent and model - so gh can bring
--                            an old one back and the last one is still
--                            there after a restart (the last 50 are kept)
--   current                  the id of the conversation in the panel
--   audit.json               every change the agent made through a tool
--                            (newest last, 200 kept), with what undoing it
--                            needs - gL lists them, u undoes one
local M = {}

M.KEEP = 50
M.AUDIT_KEEP = 200

local function SHELL() return require("azure-cli.shell") end
function M.root() return vim.fn.stdpath("data") .. "/azure-cli-chat" end
local function conv_dir() return M.root() .. "/conversations" end

-- A conversation id: sortable by time.
function M.new_id()
  return os.date("%Y%m%d-%H%M%S") .. "-" .. string.format("%04x", math.random(0, 0xffff))
end

-- The parts of a turn worth keeping (never window ids or job handles).
local KEEP_FIELDS = { "role", "text", "where", "status", "tools", "mode", "label", "started", "view" }
local function clean(entry)
  local out = {}
  for _, k in ipairs(KEEP_FIELDS) do out[k] = entry[k] end
  if out.status == "running" then out.status = "stopped" end
  return out
end

-- Saves conversation `conv` ({ id, entries, session_id, agent, model,
-- created }) and makes it the current one.
function M.save(conv)
  if not conv or not conv.id or #(conv.entries or {}) == 0 then return end
  vim.fn.mkdir(conv_dir(), "p")
  local entries = {}
  for _, e in ipairs(conv.entries) do entries[#entries + 1] = clean(e) end
  SHELL().write_json(conv_dir() .. "/" .. conv.id .. ".json", {
    id = conv.id, created = conv.created, updated = os.time(), entries = entries,
    session_id = conv.session_id, agent = conv.agent, model = conv.model,
    title = require("azure-cli.chat.core").title(entries),
  })
  pcall(vim.fn.writefile, { conv.id }, M.root() .. "/current")
  M.prune()
end

function M.load(id)
  local rec = SHELL().read_json(conv_dir() .. "/" .. id .. ".json", nil)
  if type(rec) ~= "table" or type(rec.entries) ~= "table" then return nil end
  return rec
end

-- The conversation that was in the panel last time, or nil.
function M.load_current()
  local ok, lines = pcall(vim.fn.readfile, M.root() .. "/current")
  if not ok or not lines[1] or lines[1] == "" then return nil end
  return M.load(lines[1])
end

function M.forget_current()
  pcall(vim.fn.delete, M.root() .. "/current")
end

-- Every saved conversation's summary, newest first.
function M.list()
  local out = {}
  for _, path in ipairs(vim.fn.glob(conv_dir() .. "/*.json", false, true)) do
    local rec = SHELL().read_json(path, nil)
    if type(rec) == "table" and rec.id then
      out[#out + 1] = { id = rec.id, title = rec.title or "?", updated = rec.updated or 0,
        turns = #(rec.entries or {}), agent = rec.agent }
    end
  end
  table.sort(out, function(a, b) return a.updated > b.updated end)
  return out
end

function M.prune()
  local list = M.list()
  for i = M.KEEP + 1, #list do pcall(vim.fn.delete, conv_dir() .. "/" .. list[i].id .. ".json") end
end

-- ---------------------------------------------------------------------------
-- The audit log.

local function audit_path() return M.root() .. "/audit.json" end

function M.audit()
  local rec = SHELL().read_json(audit_path(), { items = {} })
  if type(rec.items) ~= "table" then rec.items = {} end
  return rec.items
end

-- Records a change: { tool, args, summary, undo = { tool, args } or nil }.
function M.audit_add(item)
  local items = M.audit()
  item.at = os.time()
  -- A queued draft's live tables (its thread, the reviewer's synthetic
  -- entry) stay in memory; the log keeps what finding it again needs.
  if item.undo and type(item.undo.item) == "table" then
    local it = item.undo.item
    item.undo = vim.deepcopy(vim.tbl_extend("force", item.undo, { item = {
      kind = it.kind, text = it.text, thread_id = it.thread_id, label = it.label } }))
  end
  items[#items + 1] = item
  while #items > M.AUDIT_KEEP do table.remove(items, 1) end
  vim.fn.mkdir(M.root(), "p")
  SHELL().write_json(audit_path(), { items = items })
end

-- Marks item `index` (into M.audit()) undone.
function M.audit_mark_undone(index)
  local items = M.audit()
  if items[index] then
    items[index].undone = os.time()
    SHELL().write_json(audit_path(), { items = items })
  end
end

return M
