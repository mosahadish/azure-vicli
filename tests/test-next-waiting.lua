-- test-next-waiting.lua: ]w / [w (chat/waiting.lua) with real input, from
-- the Agents screen: a waiting plan's first unanswered open question, its
-- next one, its approval (the plan stays as it is), the next waiting plan;
-- [w back; once nothing waits, a notification.
--
--   nvim -u NONE --headless --cmd "set rtp+=<repo>" -c "luafile tests/test-next-waiting.lua"
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".") .. "/sandbox.lua")()
require("azure-cli.config").setup({ chat = { agent = { label = "fake", cmd = { "true" } } } })
local CHAT = require("azure-cli.chat")
local PLAN = require("azure-cli.chat.plan")
local AV = require("azure-cli.chat.agents_view")
local STORE = require("azure-cli.chat.store")

local function finish(ok, why)
  io.stdout:write((ok and "NEXT-WAITING-OK" or ("NEXT-WAITING-FAIL: " .. why)) .. "\n")
  vim.cmd(ok and "qa!" or "cq!")
end

local notes = {}
require("azure-cli.shell").notify = function(msg) notes[#notes + 1] = msg end

-- wi-9101 (the newer, so first under Needs you) asks two questions;
-- wi-9102 asks none.
local base = "# T\n\n## Goal\nx\n\n## Approach\nx\n\n## Files\n- `a`\n\n## Risks\nx\n\n## Test plan\nx\n\n## Open questions\n"
local mds = { ["wi-9101"] = base .. "- Exempt admins?\n- Error or fallback?", ["wi-9102"] = base .. "None" }
local function save(key, status)
  PLAN.save({ key = key, target = { work_item_id = tonumber(key:match("%d+")) }, title = "Plan " .. key, status = status,
    revisions = { { text = mds[key], by = "agent", at = os.time() } }, threads = {}, created = os.time() })
  vim.fn.writefile(vim.split(mds[key], "\n"), PLAN.path(key))
end
for i, key in ipairs({ "wi-9101", "wi-9102" }) do
  save(key, "draft")
  local id = tonumber(key:match("%d+"))
  local c = CHAT.conversation(key, { target = { work_item_id = id }, label = "#" .. id })
  c.entries = { { role = "you", text = "/plan #" .. id, started = os.time() - i * 10 },
    { role = "agent", text = "PLANNING-" .. id, status = "done" } }
  STORE.save({ id = c.conv_id, created = c.created, entries = c.entries, plan = key })
end
local q = PLAN.open_questions(PLAN.lines(PLAN.load("wi-9101")))
if #q ~= 2 then return finish(false, "the fixture plan has " .. #q .. " open questions, not 2") end

local function plan_at(key, line)
  local v = PLAN.current()
  if not (v and v.key == key and vim.api.nvim_get_current_tabpage() == v.tab) then
    return "not on " .. key .. "'s plan (" .. tostring(v and v.key) .. ")"
  end
  local l = vim.api.nvim_win_get_cursor(v.plan_win)[1]
  if line and l ~= line then return key .. "'s plan is on line " .. l .. ", not " .. line end
end

local steps = {
  { keys = "]w", check = function() return plan_at("wi-9101", q[1].line) end },
  { keys = "]w", check = function() return plan_at("wi-9101", q[2].line) end },
  -- Its approval: the plan as it was.
  { keys = "]w", check = function() return plan_at("wi-9101", q[2].line) end },
  { keys = "]w", check = function() return plan_at("wi-9102") end },
  { keys = "[w", check = function() return plan_at("wi-9101") end },
  { keys = "[w", check = function() return plan_at("wi-9101", q[2].line) end },
  { keys = "[w", check = function() return plan_at("wi-9101", q[1].line) end },
  { before = function()
      save("wi-9101", "approved")
      save("wi-9102", "approved")
    end, keys = "]w", check = function()
      if notes[#notes] ~= "Nothing waits for you." then return "nothing waits, but: " .. tostring(notes[#notes]) end
    end },
}

AV.open()
vim.defer_fn(function()
  if not AV.current() then return finish(false, "the Agents screen didn't open") end
  local i = 0
  local function step()
    i = i + 1
    if i > #steps then return finish(true) end
    if steps[i].before then steps[i].before() end
    vim.defer_fn(function()
      vim.api.nvim_input(steps[i].keys)
      vim.defer_fn(function()
        local err = steps[i].check()
        if err then return finish(false, "step " .. i .. " (" .. steps[i].keys .. "): " .. err) end
        step()
      end, 400)
    end, 200)
  end
  step()
end, 300)
