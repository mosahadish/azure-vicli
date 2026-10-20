-- lua/azure-cli/review/thread_text.lua: how a comment reads in the K popup,
-- the reply editor's thread and the inline thread (<Tab>) - review/init.lua's
-- threads_to_lines builds every comment's lines here.
--
--   links        [text](url) shows as "text [1]", the address on a line of
--                its own under the comment ("[1] url"), never broken so gx
--                opens it
--   mentions     Azure DevOps' "@<GUID>" shows as "@Name" - names come from
--                the comments' authors (M.names) and the signed-in user
--   references   "[KEY]: value" lines (a bot's metadata, which Azure DevOps
--                and GitHub don't show either) are left out
--   wrapping     given a width, each line breaks at spaces under the
--                "│   " gutter, so wrapped text stays inside the thread
--   paint        the K popup's colours: the thread header muted, authors in
--                the accent colour, link addresses muted
local M = {}

-- Lower-cased identity id -> display name, filled as threads are parsed
-- (review/init.lua) - every comment author on any PR seen this session.
M.names = {}

-- The name for identity `id`, or nil.
local function name_of(id)
  id = id:lower()
  if M.names[id] then return M.names[id] end
  for _, w in pairs(require("azure-cli.state").whoami or {}) do
    if type(w) == "table" and tostring(w.id or ""):lower() == id and (w.displayName or "") ~= "" then
      return w.displayName
    end
  end
end

-- `line` with every "@<GUID>" as "@Name" ("@someone" when nobody seen has
-- that id). Pure but for the names.
function M.mentions(line)
  return (line:gsub("@<([%x%-]+)>", function(id) return "@" .. (name_of(id) or "someone") end))
end

-- The K popup's text width: up to 100 columns, less on a narrow screen.
function M.popup_width()
  return math.min(100, math.max(40, vim.o.columns - 10))
end

-- Comment text `content` as display lines (no gutter), and the addresses
-- of the links it had, in order. Runs of blank lines become one, and none
-- trail. Pure.
function M.clean(content)
  local urls, out = {}, {}
  for _, line in ipairs(vim.split(content or "", "\n", { plain = true })) do
    line = line:gsub("\r$", "")
    if not line:match("^%s*%[[^%]]+%]:%s") then
      line = M.mentions(line)
      line = line:gsub("%[([^%]]*)%]%((%S-)%)", function(text, url)
        urls[#urls + 1] = url
        return (text ~= "" and text or url) .. " [" .. #urls .. "]"
      end)
      local blank = line:match("^%s*$") ~= nil
      if not (blank and (#out == 0 or out[#out]:match("^%s*$"))) then out[#out + 1] = line end
    end
  end
  while #out > 0 and out[#out]:match("^%s*$") do out[#out] = nil end
  return out, urls
end

-- `text` broken at spaces into pieces at most `width` cells wide, each
-- keeping the line's own indent; a word longer than that (an address)
-- stays whole. nil `width`: unbroken. Pure.
function M.wrap(text, width)
  if not width or width < 10 or vim.fn.strdisplaywidth(text) <= width then return { text } end
  local indent = text:match("^%s*")
  local out, cur = {}, indent
  for word in text:gmatch("%S+") do
    local try = cur == indent and (cur .. word) or (cur .. " " .. word)
    if cur == indent or vim.fn.strdisplaywidth(try) <= width then
      cur = try
    else
      out[#out + 1] = cur
      cur = indent .. word
    end
  end
  out[#out + 1] = cur
  return out
end

-- Comment text `content` as lines under the gutter `prefix`, wrapped to
-- `width` cells in all (nil: unwrapped), then its link addresses. Pure.
function M.comment_lines(content, prefix, width)
  local text, urls = M.clean(content)
  -- One cell short of `width`, so text never touches the popup's border.
  local w = width and (width - 1 - vim.fn.strdisplaywidth(prefix)) or nil
  local out = {}
  for _, l in ipairs(text) do
    for _, piece in ipairs(M.wrap(l, w)) do out[#out + 1] = prefix .. piece end
  end
  for i, u in ipairs(urls) do out[#out + 1] = prefix .. "[" .. i .. "] " .. u end
  if #out == 0 then out[1] = prefix end
  return out
end

local ns = vim.api.nvim_create_namespace("azure_cli_thread_popup")

-- Colours buffer `buf`, which shows threads_to_lines' lines.
function M.paint(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local hl, from
    if l:find("^\226\148\140\226\148\128") then
      hl, from = "AzureCliMuted", 0
    elseif l:match("^\226\148\130 %S") then
      hl, from = "AzureCliAccent", #"\226\148\130 "
    elseif l:match("^\226\148\130   %[%d+%] %a[%w+.-]*://") then
      hl, from = "AzureCliMuted", #"\226\148\130   "
    end
    if hl then pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, from, { end_col = #l, hl_group = hl }) end
  end
end

return M
