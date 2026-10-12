-- lua/azure-cli/chat/skills.lua: the agent's own skills (SKILL.md folders
-- in the repository it runs in, or the user's), and the ones you've allowed:
-- while an answer uses an allowed skill, the agent's permission prompts
-- (shell commands, file edits) are accepted without asking - azure-vicli's
-- own questions (posting, voting, pushing) still ask.
--
-- Allowed: chat.allowed_skills = { "triage-pr-comments" } in setup(), plus
-- the ones "Allow all of skill X" in a permission popup remembered, kept in
-- stdpath("data")/azure-cli-chat/allowed_skills.json.
--
-- An answer uses skill X when your message names it (/X, "the X skill",
-- `X`) or the agent reports a step that loads it (a tool call mentioning
-- "skill" and X).
--
--   M.available(cwd)        skill names in `cwd` and the user's skill folders
--   M.named_in(text, names) the first of `names` that `text` asks for (pure)
--   M.in_tool_call(u, names) the one a tool call loads, or nil (pure)
--   M.allowed(name)         whether you've allowed it
--   M.allow(name)           remembers it as allowed
local M = {}

local DIRS = { ".github/skills", ".claude/skills", ".agents/skills", ".copilot/skills" }

local function file() return require("azure-cli.chat.store").root() .. "/allowed_skills.json" end

function M.available(cwd)
  local names, seen = {}, {}
  local roots = {}
  for _, d in ipairs(DIRS) do
    if cwd and cwd ~= "" then roots[#roots + 1] = cwd .. "/" .. d end
    roots[#roots + 1] = vim.fn.expand("~") .. "/" .. d
  end
  for _, root in ipairs(roots) do
    for _, f in ipairs(vim.fn.glob(root .. "/*/SKILL.md", false, true)) do
      local name = vim.fn.fnamemodify(f, ":h:t")
      if not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
  end
  return names
end

local function esc(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

function M.named_in(text, names)
  text = (text or ""):lower()
  for _, name in ipairs(names or {}) do
    local n = esc(name:lower())
    if text:find("%f[%w/]/" .. n .. "%f[^%w%-_]") or text:find("%f[%w%-_]" .. n .. "%f[^%w%-_]%s+skill")
        or text:find("skill[%s:`\"']+" .. n .. "%f[^%w%-_]") or text:find("`" .. n .. "`", 1) then
      return name
    end
  end
  return nil
end

function M.in_tool_call(u, names)
  local ok, raw = pcall(vim.json.encode, type(u.rawInput) == "table" and u.rawInput or {})
  local hay = (tostring(u.title or "") .. " " .. tostring(u.name or "") .. " " .. (ok and raw or "")):lower()
  if not hay:find("skill", 1, true) then return nil end
  for _, name in ipairs(names or {}) do
    if hay:find("%f[%w%-_]" .. esc(name:lower()) .. "%f[^%w%-_]") then return name end
  end
  return nil
end

local stored
local function load()
  if not stored then
    stored = require("azure-cli.shell").read_json(file(), {}, { validate = function(t) return type(t) == "table" end })
  end
  return stored
end

function M.allowed(name)
  if not name then return false end
  for _, n in ipairs((require("azure-cli.config").get().chat or {}).allowed_skills or {}) do
    if n == name then return true end
  end
  return vim.tbl_contains(load(), name)
end

function M.allow(name)
  if M.allowed(name) then return end
  table.insert(load(), name)
  vim.fn.mkdir(require("azure-cli.chat.store").root(), "p")
  require("azure-cli.shell").write_json(file(), stored)
end

-- Tests: forget what's loaded.
function M._reset() stored = nil end

return M
