-- lua/azure-cli/health.lua: the setup checks behind `:AzureCli doctor`
-- (a float, async through the provider daemon) and `:checkhealth
-- azure-cli` (Neovim's own health UI, synchronous). Both answer the same
-- first-run question - "why is nothing loading?" - with one line per
-- thing that can be wrong and what to do about it, instead of the user
-- reverse-engineering that from a failed request's stderr.
--
-- Local checks (Neovim version, python, git, the config file's existence)
-- run here; everything that needs the config parsed or the network (fields,
-- sign-in per organization, the work_items block) comes from azure-cli.py's
-- `--doctor --json` (doctor_checks there), one JSON object per check.
local M = {}

local MIN_NVIM = "0.9"

-- The checks Lua can make on its own, each { check, ok, detail }.
function M.local_checks()
  local CONFIG = require("azure-cli.config")
  local out = {}
  local ver = vim.version and vim.version() or {}
  local vstr = string.format("%s.%s.%s", ver.major or "?", ver.minor or "?", ver.patch or "?")
  out[#out + 1] = {
    check = "Neovim " .. MIN_NVIM .. " or newer", ok = vim.fn.has("nvim-" .. MIN_NVIM) == 1,
    detail = vim.fn.has("nvim-" .. MIN_NVIM) == 1 and vstr or (vstr .. " - upgrade Neovim"),
  }
  local cmd = CONFIG.provider_cmd()
  local py = cmd[1] or "python"
  local py_ok = vim.fn.executable(py) == 1
  out[#out + 1] = {
    check = "python", ok = py_ok,
    detail = py_ok and py or (py .. " is not executable/on PATH - install Python 3, or setup({python = \"/path/to/python3\"})"),
  }
  local provider = cmd[2] or "azure-cli.py"
  local prov_ok = vim.fn.filereadable(provider) == 1
  out[#out + 1] = { check = "provider script", ok = prov_ok,
    detail = prov_ok and provider or (provider .. " is missing") }
  local git_ok = vim.fn.executable("git") == 1
  out[#out + 1] = { check = "git", ok = git_ok, detail = git_ok and "on PATH" or "not on PATH - the reviewer needs it" }
  local path = CONFIG.config_path()
  local cfg_ok = vim.fn.filereadable(path) == 1
  out[#out + 1] = { check = "config file", ok = cfg_ok,
    detail = cfg_ok and path or (path .. " does not exist - bash install.sh writes a template, or :AzureCli options / gO") }
  return out, cfg_ok and py_ok
end

-- Parses `--doctor --json` output (a list of stdout lines) into checks.
function M.parse_provider(lines)
  local out = {}
  for _, l in ipairs(lines or {}) do
    if l:gsub("%s", "") ~= "" then
      local ok, rec = pcall(vim.json.decode, l)
      if ok and type(rec) == "table" and rec.check then out[#out + 1] = rec end
    end
  end
  return out
end

-- Runs every check (local, then the provider's when it can run) and
-- calls cb(checks).
function M.run(cb)
  local checks, can_run_provider = M.local_checks()
  if not can_run_provider then
    cb(checks)
    return
  end
  local CONFIG = require("azure-cli.config")
  local argv = CONFIG.provider_cmd()
  argv[#argv + 1] = "--doctor"
  argv[#argv + 1] = "--json"
  local out, err = {}, {}
  require("azure-cli.rpc").run(argv, {
    stdout_buffered = true, stderr_buffered = true,
    on_stdout = function(_, d) if d then vim.list_extend(out, d) end end,
    on_stderr = function(_, d) if d then vim.list_extend(err, d) end end,
    on_exit = function(_, code)
      local more = M.parse_provider(out)
      if #more == 0 then
        local LOG = require("azure-cli.log")
        more = { { check = "provider", ok = false,
          detail = "azure-cli.py --doctor failed (exit " .. tostring(code) .. "): " .. LOG.summary(LOG.join_output(out, err), 200) } }
      end
      vim.list_extend(checks, more)
      vim.schedule(function() cb(checks) end)
    end,
  })
end

-- The lines the :AzureCli doctor float shows for `checks`.
function M.format(checks)
  local lines = { "azure-cli doctor", "" }
  local all_ok = true
  for _, c in ipairs(checks) do
    if not c.ok then all_ok = false end
    lines[#lines + 1] = (c.ok and "\u{2713} " or "\u{2717} ") .. c.check .. ": " .. tostring(c.detail or "")
  end
  lines[#lines + 1] = ""
  if all_ok then
    lines[#lines + 1] = "Everything checks out."
  else
    lines[#lines + 1] = "Fix the \u{2717} line(s), then run :AzureCli doctor again."
    lines[#lines + 1] = "gO in a dashboard (or :AzureCli options) opens the config; :AzureCli log has full error text."
  end
  return lines
end

-- :AzureCli doctor - collects everything, then shows it in a float.
function M.open()
  require("azure-cli.notify").flash("Checking the setup\u{2026}")
  M.run(function(checks)
    require("azure-cli.ui").open_float(M.format(checks), { title = "doctor", min_width = 60 })
  end)
end

-- :checkhealth azure-cli - the same checks through vim.health, run
-- synchronously (checkhealth expects its report at once).
function M.check()
  local health = vim.health
  if not health then return end
  local start = health.start or health.report_start
  local ok_fn = health.ok or health.report_ok
  local err_fn = health.error or health.report_error
  start("azure-cli")
  local checks, can_run_provider = M.local_checks()
  if can_run_provider then
    local CONFIG = require("azure-cli.config")
    local argv = CONFIG.provider_cmd()
    argv[#argv + 1] = "--doctor"
    argv[#argv + 1] = "--json"
    local output = vim.fn.system(argv)
    vim.list_extend(checks, M.parse_provider(vim.split(output or "", "\n", { plain = true })))
  end
  for _, c in ipairs(checks) do
    local line = c.check .. ": " .. tostring(c.detail or "")
    if c.ok then ok_fn(line) else err_fn(line) end
  end
end

return M
