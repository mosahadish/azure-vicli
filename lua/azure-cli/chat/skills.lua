-- lua/azure-cli/chat/skills.lua: the agent's own skills (SKILL.md folders
-- in the repository it runs in, or the user's), and the ones you've allowed:
-- while an answer uses an allowed skill, the agent's permission prompts
-- (shell commands, file edits) are accepted without asking - azure-vicli's
-- own questions (posting, voting, pushing) still ask.
--
-- Allowed: the ones you allowed from /skills (<Space>) or with "Allow all
-- of skill X" in a permission popup, kept in
-- stdpath("data")/azure-cli-chat/allowed_skills.json.
--
-- Where skills are looked for: chat.skill_dirs, default the usual ones
-- (DIRS). A relative folder is looked for in the agent's repository and in
-- your home; "~/..." or an absolute path is used as it is. /skills in the
-- chat lists what's found (M.report).
--
-- An answer uses skill X when your message names it (/X, "the X skill",
-- `X`) or the agent reports a step that loads it (a tool call mentioning
-- "skill" and X).
--
--   M.dirs()                the folders looked in (config, else DIRS)
--   M.list(cwd)             { name, path, description, allowed } per skill
--   M.available(cwd)        skill names in `cwd` and the user's skill folders
--   M.report(cwd)           the list as text (/skills when none are found)
--   M.popup(cwd, on_use)    /skills: the list in a popup - <Space> allows a
--                           skill or makes it ask again, <CR> calls
--                           on_use(name) to start a message with /name
--   M.named_in(text, names) the first of `names` that `text` asks for (pure)
--   M.in_tool_call(u, names) the one a tool call loads, or nil (pure)
--   M.allowed(name)         whether you've allowed it
--   M.allow(name)           remembers it as allowed
--   M.disallow(name)        forgets that
local M = {}

M.DIRS = { ".github/skills", ".claude/skills", ".agents/skills", ".copilot/skills" }

local function file() return require("azure-cli.chat.store").root() .. "/allowed_skills.json" end

function M.dirs()
  local d = (require("azure-cli.config").get().chat or {}).skill_dirs
  return type(d) == "table" and d or M.DIRS
end

local function absolute(d) return d:find("^~") or d:find("^[/\\]") or d:find("^%a:[/\\]") end

-- The folders to search, in order: each relative one in `cwd`, then in ~.
local function roots(cwd)
  local out, home = {}, vim.fn.expand("~")
  for _, d in ipairs(M.dirs()) do
    if absolute(d) then
      out[#out + 1] = vim.fn.expand(d)
    else
      if cwd and cwd ~= "" then out[#out + 1] = cwd .. "/" .. d end
      out[#out + 1] = home .. "/" .. d
    end
  end
  return out
end

-- SKILL.md's front matter `description:`, else its first text line.
local function description(f)
  local ok, lines = pcall(vim.fn.readfile, f, "", 40)
  if not ok then return "" end
  local first
  for _, l in ipairs(lines) do
    local d = l:match("^description:%s*(.-)%s*$")
    if d and d ~= "" then return (d:gsub("^[\"'](.*)[\"']$", "%1")) end
    if not first and l:match("%S") and not l:match("^%-%-%-") and not l:match("^[%w_]+:") then
      first = l:gsub("^#+%s*", "")
    end
  end
  return first or ""
end

function M.list(cwd)
  local out, seen = {}, {}
  for _, root in ipairs(roots(cwd)) do
    for _, f in ipairs(vim.fn.glob(root .. "/*/SKILL.md", false, true)) do
      local name = vim.fn.fnamemodify(f, ":h:t")
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = { name = name, path = vim.fn.fnamemodify(f, ":h"), description = description(f), allowed = M.allowed(name) }
      end
    end
  end
  return out
end

function M.available(cwd)
  local names = {}
  for _, s in ipairs(M.list(cwd)) do names[#names + 1] = s.name end
  return names
end

function M.report(cwd)
  local list = M.list(cwd)
  local lines = {}
  if #list == 0 then
    lines[1] = "No skills found. Looked for */SKILL.md in " .. table.concat(M.dirs(), ", ")
      .. (cwd and cwd ~= "" and (" (in " .. cwd .. " and ~)") or " (in ~)")
      .. "; chat.skill_dirs changes where."
    return table.concat(lines, "\n")
  end
  lines[1] = "Skills (" .. #list .. ") - start a message with /<name> to use one; \u{2713} = allowed, its prompts don't ask:"
  for _, s in ipairs(list) do
    local d = s.description ~= "" and ("  - " .. (#s.description > 100 and (s.description:sub(1, 97) .. "...") or s.description)) or ""
    lines[#lines + 1] = "  " .. (s.allowed and "\u{2713} " or "  ") .. "/" .. s.name .. d
    lines[#lines + 1] = "      " .. vim.fn.fnamemodify(s.path, ":~")
  end
  return table.concat(lines, "\n")
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
  return vim.tbl_contains(load(), name)
end

function M.allow(name)
  if M.allowed(name) then return end
  table.insert(load(), name)
  vim.fn.mkdir(require("azure-cli.chat.store").root(), "p")
  require("azure-cli.shell").write_json(file(), stored)
end

function M.disallow(name)
  local list = load()
  for i = #list, 1, -1 do
    if list[i] == name then table.remove(list, i) end
  end
  vim.fn.mkdir(require("azure-cli.chat.store").root(), "p")
  require("azure-cli.shell").write_json(file(), stored)
  return true
end

-- The popup's lines: per skill a row with its mark, /name and description,
-- and one with its folder. Returns lines, row -> skill index.
function M.popup_lines(list)
  local lines, at = {}, {}
  for i, s in ipairs(list) do
    local d = s.description ~= "" and ("  " .. s.description) or ""
    lines[#lines + 1] = " " .. (s.allowed and "\u{2713}" or " ") .. " /" .. s.name .. d
    at[#lines] = i
    lines[#lines + 1] = "     " .. vim.fn.fnamemodify(s.path, ":~")
    at[#lines] = i
  end
  return lines, at
end

function M.popup(cwd, on_use)
  local list = M.list(cwd)
  if #list == 0 then return nil end
  local UI = require("azure-cli.ui")
  local lines, at = M.popup_lines(list)
  local win, buf = UI.open_float(lines, {
    title = "Skills (" .. #list .. ") \u{00B7} \u{2713} allowed: its prompts don't ask", center = true, min_width = 60,
    footer = "<CR> use in the chat \u{00B7} <Space> allow / ask",
  })
  if not win then return nil end
  UI.wo(win, "wrap", false)
  UI.wo(win, "cursorline", true)
  local ns = vim.api.nvim_create_namespace("azure_cli_skills_popup")
  local function paint()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for row, l in ipairs(lines) do
      local s = list[at[row]]
      if l:sub(1, 5) == "     " then
        vim.api.nvim_buf_add_highlight(buf, ns, "Comment", row - 1, 0, -1)
      else
        local from, to = l:find("/" .. s.name, 1, true)
        if s.allowed then vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticOk", row - 1, 0, from - 1) end
        vim.api.nvim_buf_add_highlight(buf, ns, "Identifier", row - 1, from - 1, to)
      end
    end
  end
  paint()
  local function current()
    return list[at[vim.api.nvim_win_get_cursor(win)[1]]]
  end
  local kopts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<Space>", function()
    local s = current()
    if not s then return end
    if s.allowed then
      M.disallow(s.name)
      s.allowed = false
    else
      M.allow(s.name)
      s.allowed = true
    end
    local row = vim.api.nvim_win_get_cursor(win)
    lines, at = M.popup_lines(list)
    paint()
    pcall(vim.api.nvim_win_set_cursor, win, row)
  end, kopts)
  vim.keymap.set("n", "<CR>", function()
    local s = current()
    pcall(vim.api.nvim_win_close, win, true)
    if s and on_use then on_use(s.name) end
  end, kopts)
  return win, buf
end

-- Tests: forget what's loaded.
function M._reset() stored = nil end

return M
