-- lua/azure-cli/chat/tests_run.lua: running the plan's tests on the agent's
-- change. The command is the one the plan's Test plan section gives
-- (chat/plan.lua's test_command); it runs in the change's worktree, only
-- after you say yes - it's text the agent wrote. The last result is kept
-- per worktree (stdpath("data")/azure-cli-chat/why/<worktree>.tests.json).
-- Your own command for the repository (chat.test_cmd) wins over the plan's
-- and runs without asking
-- with a fingerprint of the change it ran on, so the change viewer can say
-- "passed", "failed" or "passed, before the last change"; commit_and_push_fix
-- shows it in its question; the agent can run them itself (run_tests,
-- which asks too) and read the output.
--
--   M.fingerprint(diff)   what identifies the change a run saw (pure)
--   M.label(result, fp)   the winbar tag for a result (pure)
--   M.tail(lines, n)      the last n non-empty lines of the output (pure)
--   M.load(dir) / M.running(dir)
--   M.run(dir, cmd, fp, cb)   runs it (no asking - callers ask): cb(result)
--   M.ask_and_run(dir, cmd, fp, cb)   asks first; cb(result) or cb(nil)
local M = {}

M.TIMEOUT = 600
M.KEEP_LINES = 400

local running = {}  -- dir -> true while its tests run

-- The repository of a fix / story worktree: start_fix's <repo>-<pr id>,
-- start_story's <repo>-wi<id>. Pure.
function M.repo_of(dir)
  local name = ((dir or ""):gsub("[/\\]+$", "")):match("([^/\\]+)$") or ""
  return name:match("^(.-)%-wi%d+$") or name:match("^(.-)%-%d+$") or name
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

-- "[✓ tests passed]", "[✗ tests failed (exit 2)]", "[✓ tests passed, before
-- the last change]", "[⠋ tests running]" - nil when they never ran. Pure
-- (`now_fp` is the change's fingerprint now).
function M.label(result, now_fp, is_running)
  if is_running then return "[\u{231B} tests running]" end
  if not result then return nil end
  local stale = now_fp and result.fingerprint ~= now_fp
  local base = result.code == 0 and "\u{2713} tests passed"
    or (result.timed_out and "\u{2717} tests timed out" or ("\u{2717} tests failed (exit " .. tostring(result.code) .. ")"))
  return "[" .. base .. (stale and ", before the last change" or "") .. "]"
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
-- fingerprint = fp }.
function M.run(dir, cmd, fp, cb)
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
          seconds = os.time() - started, fingerprint = fp }
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

function M.ask_and_run(dir, cmd, fp, cb)
  require("azure-cli.prompt").confirm({ title = "Run the plan's tests?", prompt = "In "
    .. vim.fn.fnamemodify(dir, ":t") .. ": " .. cmd }, function(yes)
    if not yes then return cb(nil, "declined") end
    M.run(dir, cmd, fp, cb)
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
