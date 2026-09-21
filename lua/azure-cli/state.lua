-- lua/azure-cli/state.lua: the one shared, in-memory table every surface
-- (dashboard, reviewer, work-items dashboard/view) reads and writes to stay
-- in sync within a single Neovim session - the list cache, per-PR content
-- caches, the daemon client's own bookkeeping, toast/batch/whoami state,
-- and so on.
--
-- Before this plugin restructure, each UI file was `dofile()`d (or
-- `:luafile`'d) independently, so plain `local`s couldn't be shared between
-- e.g. the dashboard and the reviewer - everything that needed to survive a
-- swap or be visible to another surface lived in a `_G.PR_*`/`_G.WI_*`
-- global instead (see the old azure-cli.lua/pr-review.lua header comments).
-- `require()` caches modules, so every requirer of THIS module gets the
-- same table - the fields keep the same nil-init pattern those globals had
-- so the semantics (caches shared between dashboard/reviewer, state
-- surviving a re-open within one session) are exactly what they were
-- before, just reached as `STATE.PR_LIST_CACHE` instead of
-- `_G.PR_LIST_CACHE`.
--
-- Not persisted to disk - the "seen" snapshot (unread badge), thread read
-- counts and persistent comment filters still live in files under
-- `stdpath("data")`, written directly by the modules that own them.
local M = {}

-- PR dashboard / reviewer
M.PR_LIST_CACHE = nil               -- { prs, ts }
M.PR_CURRENT = nil                  -- metadata for the PR currently being opened
M.PR_REFRESH_TIMER = nil                -- dashboard's periodic-refresh timer id
M.whoami = nil                       -- "org|project" -> { id, displayName }
M.ignore_ws = nil                    -- reviewer's gw toggle, sticky within a session
M.last_search = nil                  -- reviewer's g/ last search text
M.review_badge_timer = nil
M.review_threads_timer = nil
M.toasts = nil                       -- desktop-notification session opt-out (gN)
M.batch = nil                        -- reviewer batch-review queue, per PR id
M.editor_drafts = nil                -- lua/azure-cli/editor.lua's cancelled-comment drafts, by draft key
M.log_entries = nil                  -- lua/azure-cli/log.lua's last-200 error log, oldest first
M.flashes = nil                      -- lua/azure-cli/notify.lua's currently-showing flash floats

-- Shared content cache (lua/azure-cli/cache.lua)
M.PR_DIFF_CACHE = {}
M.PR_FILES_CACHE = {}
M.PR_COMMITS_CACHE = {}
M.PR_CACHE_ORDER = {}
M.PR_THREADS_CACHE = {}
M.PR_DIFF_CACHE_EXTRA = {}

-- Provider daemon client (lua/azure-cli/rpc.lua)
M.rpc = nil

-- Work items dashboard / detail view
M.WI_LIST_CACHE = nil
M.WI_SPRINT_ITEMS = {}
M.WI_SPRINTS_CACHE = nil
M.WI_DETAIL_CACHE = {}
M.WI_TRANS_CACHE = {}
M.WI_REASON_CACHE = {}
M.WI_ITEM_CHANGED = nil
M.WI_STATE_CHANGED = nil
M.WI_ITEM_MOVED = nil
M.WI_VIEW_RELOAD = nil
M.WI_REFRESH = nil
M.WI_REFRESH_TIMER = nil

return M
