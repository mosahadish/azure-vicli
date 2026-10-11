-- lua/azure-cli/chat/notes.lua: the agent's notes on a PR's lines
-- (annotate_code), kept per PR in stdpath("data")/azure-cli-chat/notes/
-- <id>.json so they're still there after a restart; STATE.chat_notes[id]
-- is the loaded copy the reviewer draws. Each note also keeps the text of
-- its line from the first time the reviewer draws it (`code`): once the
-- line reads differently (a later push), the note says it may have moved.
--
--   M.get(id)              the PR's notes, a list (read from disk once)
--   M.add(id, note)        appends one and saves; returns the count
--   M.clear(id)            forgets them, file and all
--   M.save(id)             writes the PR's notes back (after `code` is filled in)
--   M.moved(note, text)    whether the note's line now reads `text` instead - pure
local M = {}

local function STATE() return require("azure-cli.state") end
local function SHELL() return require("azure-cli.shell") end

local function dir() return require("azure-cli.chat.store").root() .. "/notes" end
local function path(id) return dir() .. "/" .. (tostring(id):gsub("[^%w_-]", "_")) .. ".json" end

local function squash(s) return (s or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") end

function M.moved(note, text)
  return note.code ~= nil and squash(note.code) ~= squash(text)
end

function M.get(id)
  id = tostring(id)
  local all = STATE().chat_notes or {}
  STATE().chat_notes = all
  if all[id] == nil then
    local saved = SHELL().read_json(path(id), {}, { validate = vim.islist or vim.tbl_islist })
    all[id] = {}
    for _, n in ipairs(saved) do
      if type(n) == "table" and type(n.file) == "string" and tonumber(n.line) and type(n.text) == "string" then
        all[id][#all[id] + 1] = n
      end
    end
  end
  return all[id]
end

function M.save(id)
  id = tostring(id)
  local list = (STATE().chat_notes or {})[id]
  if not list or #list == 0 then return pcall(vim.fn.delete, path(id)) end
  vim.fn.mkdir(dir(), "p")
  SHELL().write_json(path(id), list)
end

function M.add(id, note)
  local list = M.get(id)
  list[#list + 1] = note
  M.save(id)
  return #list
end

function M.clear(id)
  id = tostring(id)
  STATE().chat_notes = STATE().chat_notes or {}
  STATE().chat_notes[id] = {}
  M.save(id)
end

return M
