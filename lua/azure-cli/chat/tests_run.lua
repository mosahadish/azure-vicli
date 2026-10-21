-- lua/azure-cli/chat/tests_run.lua: running the plan's tests on the agent's
-- change. The command is the one the plan's Test plan section gives
-- (chat/plan.lua's test_command); it runs in the change's worktree, only
-- after you say yes - it's text the agent wrote. The last result is kept
-- per worktree (stdpath("data")/azure-cli-chat/why/<worktree>.tests.json).
-- Your own command for the repository (chat.test_cmd) wins over the plan's
-- and runs without asking.
-- A result keeps the fingerprint of the change it ran on and who started it
-- (you from the change viewer's gb, or the agent's run_tests), so the change
-- viewer can say "passed", "failed" or "stale" (it ran on an older change),
-- and commit_and_push_fix's question says which run it means. A run you
-- declined, or one that never started, leaves no result.
--
--   M.fingerprint(diff)   what identifies the change a run saw (pure)
--   M.label(result, fp)   the winbar tag for a result (pure)
--   M.describe(result, fp, opts)   the commit question's line for it (pure)
--   M.tail(lines, n)      the last n non-empty lines of the output (pure)
--   M.load(dir) / M.running(dir)
--   M.run(dir, cmd, fp, cb, opts)   runs it (no asking - callers ask): cb(result)
--   M.ask_and_run(dir, cmd, fp, cb, opts)   asks first; cb(result) or cb(nil)
local M = {}

M.TIMEOUT = 600
M.KEEP_LINES = 400

local running = {}  -- dir -> true while its tests run

-- The repository of a fix / story worktree: start_fix's <repo>-<pr id>,
-- start_story's <repo>-wi<id>, a GitHub PR's or issue's pr-github- /
-- wi-github-<owner~repo~n>. Pure.
function M.repo_of(dir)
  local name = ((dir or ""):gsub("[/\\]+$", "")):match("([^/\\]+)$") or ""
  return name:match("^%a+%-github%-[^~]*~(.-)~%d+$") or name:match("^(.-)%-wi%d+$") or name:match("^(.-)%-%d+$")
    or name
end

-- Your own test command for `repo` (setup({ chat = { test_cmd = "..." or {
-- [repo] = "..." } } })), or nil. `cfg` = that setting. Pure.
function M.configured(cfg, repo)
  if type(cfg) == "string" and cfg ~= "" then return cfg end
  if type(cfg) == "table" and type(cfg[repo]) == "string" and cfg[repo] ~= "" then return cfg[repo] end
  return nil
end

-- The command to run on worktree `dir`'s change: yours from chat.test_cmd
-- first ("config" - runs without asking, it's yours), else the one in its
-- plan's Test plan ("plan" - asks: the agent wrote it). cmd, source.
function M.command(dir, plan_rec)
  local cfg = (require("azure-cli.config").get().chat or {}).test_cmd
  local mine = M.configured(cfg, M.repo_of(dir))
  if mine then return mine, "config" end
  if plan_rec then
    local PLAN = require("azure-cli.chat.plan")
    local cmd = PLAN.test_command(PLAN.lines(plan_rec))
    if cmd then return cmd, "plan" end
  end
  return nil, nil
end

function M.fingerprint(diff)
  return vim.fn.sha256(diff or "")
end

function M.tail(lines, n)
  local out = {}
  for i = #lines, 1, -1 do
    if vim.trim(lines[i]) ~= "" then table.insert(out, 1, lines[i]) end
    if #out >= n then break end
  end
  return out
end

-- How a run ended: "passed", "timed out", "failed (exit 2)". Pure.
function M.outcome(result)
  if result.code == 0 then return "passed" end
  return result.timed_out and "timed out" or ("failed (exit " .. tostring(result.code) .. ")")
end

-- "[✓ tests passed]", "[✗ tests failed (exit 2)]", "[↻ tests stale - last
-- run passed, on an older change]", "[⌛ tests running]" - nil when they
-- never ran. A run on an older change is stale whatever it said: that's
-- what it is now. Pure (`now_fp` is the change's fingerprint now).
function M.label(result, now_fp, is_running)
  if is_running then return "[\u{231B} tests running]" end
  if not result then return nil end
  if now_fp and result.fingerprint ~= now_fp then
    return "[\u{21BB} tests stale - last run " .. M.outcome(result) .. ", on an older change]"
  end
  return "[" .. (result.code == 0 and "\u{2713}" or "\u{2717}") .. " tests " .. M.outcome(result) .. "]"
end

-- Who started a run (result.by); results from before it was kept say so.
local function started_by(result, key)
  if result.by == "user" then return "you (" .. key .. ")" end
  if result.by == "agent" then return "the agent (run_tests)" end
  return "unknown"
end

-- The line commit_and_push_fix's question shows for `result` against the
-- change as it is now (`now_fp`): which run - its command, when, who
-- started it - and whether it ran on this change. opts: key (the change
-- viewer's run_tests key, "gb"), fmt (a time -> text, os.date's by
-- default), running. Pure but for the default fmt.
function M.describe(result, now_fp, opts)
  opts = opts or {}
  local key = opts.key or "gb"
  local fmt = opts.fmt or function(ts) return os.date("%m-%d %H:%M", ts) end
  if opts.running then return "Tests: running." end
  if not result then return "Tests: not run on this change yet (" .. key .. " in the change viewer)." end
  local which = "`" .. tostring(result.cmd) .. "`, started by " .. started_by(result, key)
    .. (result.at and (" at " .. fmt(result.at)) or "")
  if now_fp and result.fingerprint ~= now_fp then
    return "Tests: stale - the last run (" .. which .. ", " .. M.outcome(result)
      .. ") was on an older version of the change; run them again (" .. key .. ")."
  end
  return "Tests: " .. M.outcome(result) .. " - " .. which .. ", on this change."
end

local function path(dir)
  return require("azure-cli.chat.store").root() .. "/why/"
    .. vim.fn.fnamemodify((dir or ""):gsub("[/\\]+$", ""), ":t"):gsub("[^%w%._%-]", "_") .. ".tests.json"
end

function M.load(dir)
  local ok, lines = pcall(vim.fn.readfile, path(dir))
  local okd, r = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return okd and type(r) == "table" and r or nil
end

function M.running(dir) return running[dir] == true end

local function save(dir, r)
  local p = path(dir)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(r) }, p)
end

-- Runs `cmd` through 'shell' in `dir`; cb(result) once it's done, result =
-- { cmd, code, timed_out, output (the last KEEP_LINES lines), at, seconds,
-- fingerprint = fp, by }. opts.by: who started it, "user" (gb) or "agent"
-- (run_tests).
function M.run(dir, cmd, fp, cb, opts)
  local by = (opts or {}).by
  if running[dir] then return cb(nil, "the tests are already running") end
  running[dir] = true
  local out, started = {}, os.time()
  local function add(_, d) if d then for _, l in ipairs(d) do out[#out + 1] = (l:gsub("\r$", "")) end end end
  local timed_out = false
  local ok, job = pcall(vim.fn.jobstart, { vim.o.shell, vim.o.shellcmdflag, cmd }, {
    cwd = dir, on_stdout = add, on_stderr = add,
    on_exit = function(_, code)
      vim.schedule(function()
        running[dir] = nil
        local keep = #out > M.KEEP_LINES and vim.list_slice(out, #out - M.KEEP_LINES + 1) or out
        local r = { cmd = cmd, code = code, timed_out = timed_out or nil, output = keep, at = os.time(),
          seconds = os.time() - started, fingerprint = fp, by = by }
        save(dir, r)
        pcall(require("azure-cli.chat.plan").event_for_worktree, dir, "tests",
          "Tests (" .. cmd .. "): " .. (M.label(r) or ""):gsub("^%[", ""):gsub("%]$", ""))
        cb(r)
      end)
    end,
  })
  if not ok or job <= 0 then
    running[dir] = nil
    return cb(nil, "couldn't start it: " .. tostring(job))
  end
  vim.defer_fn(function()
    if running[dir] then
      timed_out = true
      pcall(vim.fn.jobstop, job)
    end
  end, M.TIMEOUT * 1000)
end

-- Declined: cb(nil, "declined"), and the last result stays as it was.
function M.ask_and_run(dir, cmd, fp, cb, opts)
  require("azure-cli.prompt").confirm({ title = "Run the plan's tests?", prompt = "In "
    .. vim.fn.fnamemodify(dir, ":t") .. ": " .. cmd }, function(yes)
    if not yes then return cb(nil, "declined") end
    M.run(dir, cmd, fp, cb, opts)
  end)
end

-- The output of a run in a float.
function M.show(r)
  if not r then return require("azure-cli.shell").notify("The tests haven't run on this change yet.") end
  local lines = { "$ " .. r.cmd, "" }
  vim.list_extend(lines, r.output or {})
  lines[#lines + 1] = ""
  lines[#lines + 1] = (M.label(r) or "") .. " in " .. tostring(r.seconds or "?") .. "s"
  local win = require("azure-cli.ui").open_float(lines, { big = true, title = "Tests", focus = true })
  if win then pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 }) end
  return win
end

return M
