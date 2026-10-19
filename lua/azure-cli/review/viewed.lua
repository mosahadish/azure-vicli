-- lua/azure-cli/review/viewed.lua: which files of a PR you've already
-- looked at - GitHub's "viewed" checkbox. Persisted under stdpath("data")
-- like the seen-thread counts, keyed by PR id + path and stamped with the
-- PR's last-update time, so a new push clears every file's mark (there's
-- new content to look at) without any extra bookkeeping.
--
-- A file is marked automatically when it's opened with focus (<CR> in the
-- list, or ]c/]C walking into it) and toggled by hand with the
-- toggle_viewed key; next/prev_unviewed jump between the rest. Pure
-- except for the load/save pair, so tests/test-review-viewed.lua drives
-- it with an in-memory store.
--
-- The same file keeps the diff folds you opened (review/folds.lua), under
-- the one key FOLDS below: a viewed mark's key always starts with a
-- non-empty PR key, so the two can't collide, and a file written before
-- folds were remembered simply has no such key.
local M = {}

local FOLDS = "\tfolds"

local FILE = nil
local store = nil

-- "" when there's no Neovim around (tests drive this module with an
-- injected store - see M.use_store); shell.lua's read_json/write_json are
-- no-ops in that case too, so nothing here has to guard again.
local function path()
  if FILE then return FILE end
  if not (vim and vim.fn) then return "" end
  FILE = vim.fn.stdpath("data") .. "/azure-cli-viewed.json"
  return FILE
end

function M.load()
  if store then return store end
  store = require("azure-cli.shell").read_json(path(), {})
  return store
end

local function save()
  if not store then return end
  require("azure-cli.shell").write_json(path(), store)
end

-- Injects an in-memory store (tests).
function M.use_store(t)
  store = t
end

function M.key(pr_id, file)
  return tostring(pr_id) .. "\t" .. tostring(file)
end

-- `stamp` is the PR's updatedIso (or "" when unknown): a mark made under
-- an older stamp no longer counts.
function M.is_viewed(pr_id, file, stamp)
  local s = M.load()
  local v = s[M.key(pr_id, file)]
  return v ~= nil and v == (stamp or "")
end

function M.set(pr_id, file, stamp, on)
  local s = M.load()
  local k = M.key(pr_id, file)
  if on then s[k] = stamp or "" else s[k] = nil end
  save()
end

function M.toggle(pr_id, file, stamp)
  local now = not M.is_viewed(pr_id, file, stamp)
  M.set(pr_id, file, stamp, now)
  return now
end

-- How many of `files` are viewed.
function M.count(pr_id, files, stamp)
  local n = 0
  for _, f in ipairs(files or {}) do
    if M.is_viewed(pr_id, f, stamp) then n = n + 1 end
  end
  return n
end

-- The next (dir=1) / previous (dir=-1) index in `ordered` after `from`
-- whose file isn't viewed, wrapping around; nil when every file is.
function M.next_unviewed(pr_id, ordered, stamp, from, dir)
  local n = #ordered
  if n == 0 then return nil end
  local i = from or 0
  for _ = 1, n do
    i = i + dir
    if i > n then i = 1 elseif i < 1 then i = n end
    if not M.is_viewed(pr_id, ordered[i], stamp) then return i end
  end
  return nil
end

-- Remembered folds: { stamp, open = { {s, e}, ... } } per PR key, file and
-- diff variant ("" for the plain diff, else gw's / since-mode's - they
-- fold differently). `stamp` identifies the diff the folds were made on
-- (review/folds.lua's M.stamp); `open` the new-side line ranges of the
-- folds that were open.
local function fold_key(pr_id, file, variant)
  return M.key(pr_id, file) .. "\t" .. tostring(variant or "")
end

function M.folds_get(pr_id, file, variant)
  local t = M.load()[FOLDS]
  return type(t) == "table" and t[fold_key(pr_id, file, variant)] or nil
end

function M.folds_drop(pr_id, file, variant)
  local s = M.load()
  local t = s[FOLDS]
  local k = fold_key(pr_id, file, variant)
  if type(t) ~= "table" or t[k] == nil then return end
  t[k] = nil
  if next(t) == nil then s[FOLDS] = nil end
  save()
end

local function same_ranges(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return false end
  end
  return true
end

-- Nothing open is the default (everything folded), so it's stored as no
-- record at all.
function M.folds_set(pr_id, file, variant, stamp, open)
  if not open or #open == 0 then return M.folds_drop(pr_id, file, variant) end
  local s = M.load()
  if type(s[FOLDS]) ~= "table" then s[FOLDS] = {} end
  local k = fold_key(pr_id, file, variant)
  local old = s[FOLDS][k]
  if old and old.stamp == (stamp or "") and type(old.open) == "table" and same_ranges(old.open, open) then return end
  s[FOLDS][k] = { stamp = stamp or "", open = open }
  save()
end

return M
