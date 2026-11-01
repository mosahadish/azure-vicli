# Current View Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The chat and its agents know much better what the user is looking at: plain code files, the reviewer's Overview and Commits views, the work-item detail sections, PR agents on the Agents screen, what's on screen and where the user just was, and the user sees what will be sent before sending.

**Architecture:** Everything flows through `lua/azure-cli/chat/view.lua`: each screen registers a describer returning a plain snapshot table, `M.snapshot(win, sel)` picks one, `M.text(snap)` renders the "## Current view" block sent with each message, and the `current_view` tool returns the table. This plan adds a fallback describer for ordinary file buffers, enriches four existing describers, adds two cross-cutting fields (visible range, recent trail), and moves the existing "on PR !101 · a.lua:12" label (`where_label` in `chat/run.lua`) into `view.lua` so the chat input bar can show it live.

**Tech Stack:** Lua (Neovim plugin), Neovim API (`vim.treesitter`, `vim.diagnostic`), bash test runner.

**Spec:** the six findings agreed in chat on 2026-11-01:
1. Plain code buffers describe only `screen = "other"` + filetype.
2. Reviewer Overview and Commits views say only their screen name.
3. Work-item detail sends only the header, not the section under the cursor.
4. Agents screen never sets `pr` for a PR agent.
5. Single cursor snapshot: no visible range, no trail of recent places.
6. The user can't see what will be sent.

## Global Constraints

- Neovim 0.9.5 must keep working (CI and README floor): `vim.uv or vim.loop`, no `vim.fs.root`, no `vim.system`; `vim.treesitter.get_node` and `vim.diagnostic.get(buf, { lnum = n })` are fine.
- CRLF files must stay CRLF, edited byte-preserving: `review/chat.lua`, `review/commits.lua`, `workitems/view.lua` (and any other `review/*.lua`, `workitems/{dashboard,states,view}.lua`). Check with `file <path>` before and after.
- Never add top-level locals to `review/init.lua` (200-local / 60-upvalue ceilings); everything needed there is already on `ctx` (`ctx.build_overview`, `ctx.overview_buf`, `ctx.comments_by_buf`, `ctx.maps_by_buf`, `ctx.paths_by_buf`).
- No filler UI text: the input-bar label is the label and nothing else.
- Match the surrounding style: comment density, `snap.*` field names, `check(name, ok, detail)` tests.
- Each task ends with one commit on branch `current-view`; message: a plain sentence, no `feat:` prefix, ending with the session attribution lines.
- Quick test: `PATH=/home/linuxbrew/.linuxbrew/bin:$PATH nvim -u NONE --headless --cmd "set rtp+=$PWD" -l tests/test-chat-view.lua` (prints `all chat view tests passed`). Full suite before each commit: `PATH=/home/linuxbrew/.linuxbrew/bin:$PATH bash tests/run.sh` (~3 min, run in background).

## Review Focus

- A scratch/plugin buffer with `buftype ~= ""` or no name must still come out as `screen = "other"`, never as a code file (test in Task 1).
- A file outside any git repository: `file` is the absolute path, no `repo`/`branch`, no error (test in Task 1).
- A buffer with no treesitter parser for its filetype: no `symbol`, no error (test in Task 1).
- The live label must never throw into the winbar redraw: a describer error yields no label, not an error message (test in Task 6).
- The trail must not list the place you're on now, nor the chat panel, nor floating windows (test in Task 5).

---

### Task 1: Plain code buffers

**Files:**
- Modify: `lua/azure-cli/chat/view.lua` (fallback in `M.snapshot`, new `M.code`, new lines in `M.text`)
- Create: `tests/test-chat-view.lua`
- Modify: `tests/run.sh` (register next to the `test-chat.lua` block, ~line 531)

**Interfaces:**
- Produces: `M.code(win, sel) -> snap|nil` — nil unless the window's buffer has `buftype == ""` and a non-empty name. Snapshot fields: `screen = "code"`, `file` (path relative to the git root, else absolute), `repo` (absolute git root or nil), `branch` (or nil), `line`, `code_line`, `symbol` (`{ kind, name }` or nil), `diagnostics` (list of `{ severity, line, message }` on the cursor line), `diagnostic_counts` (`{ errors, warnings }`), `modified` (bool), `selection_lines` (`"from-to"` when `sel` is in this buffer).
- `M.snapshot` falls back to `M.code` before returning `screen = "other"`.
- `M.text` new lines (exact): `Repository: <repo> (branch <branch>)` (branch part omitted if nil); `Inside: <name> (<kind>)`; `Diagnostic on this line (<SEVERITY>): <message>` one per entry; `Diagnostics in the file: <n> errors, <m> warnings` only when either is >0; `Unsaved changes in this buffer` when `modified`. File line keeps the existing `File: ... line N` form; a code snapshot has no `side`, so the `(source side)` suffix must be omitted when `side` is nil.

- [ ] **Step 1: Write the failing tests** in `tests/test-chat-view.lua` (sandbox header as first statement, same `check` helper as `test-chat.lua`, ends with `print("all chat view tests passed")` or `os.exit(1)`):
  - `code: file in a repo` — make a temp dir, `git init -q`, `git checkout -q -b topic`, write `a.lua` containing `local function foo()\n  return 1\nend\n`, `:edit` it in a window, cursor on line 2. Assert `snap.screen == "code"`, `snap.file == "a.lua"`, `snap.repo` equals the temp dir (resolved), `snap.branch == "topic"`, `snap.line == 2`, `snap.code_line == "  return 1"`, `snap.symbol.name == "foo"`.
  - `code: diagnostics` — `vim.diagnostic.set(ns, buf, { {lnum=1,col=0,severity=vim.diagnostic.severity.ERROR,message="bad"}, {lnum=0,col=0,severity=vim.diagnostic.severity.WARN,message="meh"} })`; assert one entry on line 2 with message `"bad"`, counts `{ errors = 1, warnings = 1 }`, and `VIEW.text(snap)` contains `Diagnostic on this line (ERROR): bad` and `Diagnostics in the file: 1 errors, 1 warnings`.
  - `code: modified` — change a line without writing; `snap.modified == true`; text has `Unsaved changes in this buffer`.
  - `code: outside a repo` — a file in a non-git temp dir: `snap.file` is absolute, `snap.repo == nil`, `snap.branch == nil`.
  - `code: no parser` — a `.txt` file: `snap.symbol == nil`, no error.
  - `code: scratch stays other` — `nvim_create_buf(false, true)` shown in a window: `VIEW.snapshot(win).screen == "other"`.
  - `code: selection` — `VIEW.snapshot(win, { buf = buf, from = 1, to = 2, text = "x" }).selection_lines == "1-2"`.
- [ ] **Step 2: Run the quick test; expect FAIL** (`screen` is `"other"`).
- [ ] **Step 3: Implement** `M.code` and the `M.text` lines. Git root: walk up with `vim.fs.find(".git", { upward = true, path = dir })`; branch: `git -C <root> rev-parse --abbrev-ref HEAD` via `vim.fn.systemlist`, cached per root for 5 seconds (the label in Task 6 calls this often). Symbol: `pcall(vim.treesitter.get_node, { bufnr = buf, pos = { line-1, col } })`, walk `:parent()` to the first node whose type matches `function`, `method`, `class`, `struct`, `impl`, `interface`, `module` (substring), name from its `name` field (`node:field("name")[1]`) via `vim.treesitter.get_node_text`; for a Lua `local function` with no name field fall back to the first `identifier`/`dot_index_expression` child. Severity names via `vim.diagnostic.severity[n]`.
- [ ] **Step 4: Register the new test in `tests/run.sh`** with a block copied from the `test-chat.lua` one, grep marker `all chat view tests passed`; add `test-chat-view.lua` to the sentinel loop at ~line 730.
- [ ] **Step 5: Run the quick test; expect PASS.** Then the full suite in the background; expect no new failures.
- [ ] **Step 6: Commit** `git add lua/azure-cli/chat/view.lua tests/test-chat-view.lua tests/run.sh` — "Chat sees ordinary code files: path, branch, function, diagnostics".

### Task 2: Reviewer Overview and Commits views

**Files:**
- Modify: `lua/azure-cli/review/chat.lua` (CRLF) — new pure `M.overview_at`, use it in the `review:<id>` describer; Commits buffers branch
- Modify: `lua/azure-cli/review/commits.lua` (CRLF) — new `M.describe_buf(buf, lnum)`
- Modify: `lua/azure-cli/chat/view.lua` — `M.text` lines for `section`, `commit`
- Test: `tests/test-chat-view.lua`

**Interfaces:**
- Produces: `RCHAT.overview_at(lines, thread_map, lnum) -> { section = string|nil, commit = sha|nil, thread = thread|nil }` (pure). `section` is the nearest heading line above (or at) `lnum` among `"Description:"`, `"Commits (who pushed):"`, `"Comments (N):"`, `"Since your last review …"`, returned without the trailing colon/count: `"Description"`, `"Commits"`, `"Comments"`, `"Since your last review"`. `commit` uses `COMMITS.overview_commit_at(lines, lnum)`. `thread` is the thread whose `thread_map` start row is the nearest at or above `lnum` within the Comments section.
- Produces: `COMMITS.describe_buf(buf, lnum) -> { commit = sha|nil, file = path|nil, kind = "list"|"files" } | nil` (nil for a buffer not in `buf_meta`). On the list buffer, `commit` = `M.commit_line_sha(line)`; on a files buffer, `commit` = its `sha` and `file` = the path on that row (use `M.parse_name_status` on the row).
- Snapshot additions: `snap.section`, `snap.commit`; Overview screen keeps its existing name; Commits views use `screen = "reviewer: commit list"` / `"reviewer: a commit's files"`. Text lines (exact): `Section: <section>`, `Commit: <sha>`.

- [ ] **Step 1: Failing tests** — `overview_at` on a hand-built `lines`/`thread_map` (Description, Commits with one commit row in the shape `commit_line_sha` accepts — copy one from `tests/test-review-commits.lua`, Comments with two threads): cursor on a description line → `section == "Description"`, no commit; on the commit row → `commit == "<sha>"`; on the second comment body line of thread 2 → `thread.id == 2`, `section == "Comments"`. `VIEW.text({ section = "Comments", commit = "abc1234" })` contains `Section: Comments` and `Commit: abc1234`.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.** In the describer: on `ctx.overview_buf()`, `local lines, thread_map = ctx.build_overview()` and merge `overview_at`'s fields (thread → `M.thread(t)` as today). For any buffer with filetype `azurecli-commits`, call `require("azure-cli.review.commits").describe_buf(buf, lnum)`. `ctx` already exposes `build_overview`; don't touch `review/init.lua`.
- [ ] **Step 4: Run quick test + full suite; expect PASS.** Confirm `file` still says CRLF for both review files.
- [ ] **Step 5: Commit** — "Chat sees the reviewer's Overview section, commit and comment, and the Commits views".

### Task 3: Work-item detail sections

**Files:**
- Modify: `lua/azure-cli/chat/view.lua` — pure `M.section_at(lines, lnum)`
- Modify: `lua/azure-cli/workitems/view.lua` (CRLF) — the `S.WI_VIEW_SNAP[buf]` closure (~line 838)
- Test: `tests/test-chat-view.lua`

**Interfaces:**
- Produces: `VIEW.section_at(lines, lnum) -> string|nil` — the title of the nearest section at or above `lnum`, a section being a line followed by a rule line (all `─`); the title with a trailing ` (N)` count stripped. nil above the first section (the header fields).
- Snapshot additions in the work-item describer: `section` (e.g. `"Description"`, `"Discussion"`, `"Pull Requests"`), `pr` when the row is a linked PR (`row_pr[lnum]` → `{ id = p.id, title = p.title, repo = p.repo }`), and `comment_author` when in the discussion on/under a comment heading row (the `author  date` line). Text line (exact): `Comment by <author>` — `Section:` is from Task 2.

- [ ] **Step 1: Failing tests** for `section_at`: lines `{ "#1 Story", "Title", "", "Description", "───────────", "  text", "", "Discussion (2)", "─────────────", "Bob  1d", "  hi" }` → lnum 2 → nil; lnum 6 → `"Description"`; lnum 11 → `"Discussion"`.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** `section_at`, and in the detail view closure read the cursor row of the window being described (the closure gets no win today: pass `win` through from the registered describer at line 826) and the buffer's lines. For `comment_author`, keep a `row_comment[lnum] = author` map when rendering the discussion (next to `row_pr`), covering the heading row and its body rows.
- [ ] **Step 4: Run quick test + full suite; expect PASS.** `file lua/azure-cli/workitems/view.lua` still CRLF.
- [ ] **Step 5: Commit** — "Chat sees which part of a work item you're reading".

### Task 4: PR agents on the Agents screen

**Files:**
- Modify: `lua/azure-cli/chat/agents_view.lua` (describer at ~line 620)
- Test: `tests/test-chat-view.lua`

**Interfaces:**
- Consumes: rows carry `r.pr_key`, `r.pr_id` (see ~line 112).
- Produces: the describer sets `snap.pr = TOOLS.pr_record(r.pr_key or r.pr_id) or { id = r.pr_id }` when either is set, independently of `work_item`.

- [ ] **Step 1: Failing test** — stub `require("azure-cli.chat.agents_view")`'s `view` via its `M.current()`-backed state: if the row table is not reachable from outside, add a tiny test seam `M._set_view(v)` (matching `chat/init.lua`'s `M._set_focused` style); a row `{ label = "PR !7", state = "working", pr_id = 7, pr_key = "7", target = {} }` in a buffer of filetype `azurecli-agents` → `VIEW.snapshot(win).pr.id == 7`.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run quick test + full suite; expect PASS.**
- [ ] **Step 5: Commit** — "Chat knows the PR of the agent under the cursor".

### Task 5: Visible range and recent places

**Files:**
- Modify: `lua/azure-cli/chat/view.lua` — `label` (moved here from `run.lua`; the trail needs it, Task 6 reuses it), `visible`, trail
- Modify: `lua/azure-cli/chat/run.lua` — use `VIEW.label` instead of its local `where_label` (~line 96)
- Modify: `lua/azure-cli/review/chat.lua` (CRLF) — `snap.visible` for a diff
- Test: `tests/test-chat-view.lua`

**Interfaces:**
- Produces: `VIEW.label(snap) -> string|nil` — exactly `run.lua`'s `where_label` today, plus a `commit <first 7 of sha>` bit after the thread bit when `snap.commit`. `run.lua` calls it; its local function goes.
- Produces: `snap.visible = "<first>-<last>"` — for `M.code`: `line("w0")`–`line("w$")` of that window; for the reviewer diff: the first and last mapped `lineno` on the cursor's side among the rows `w0..w$`. Text line (exact): `Visible: lines <first>-<last>`.
- Produces: `VIEW.remember(win)` and `VIEW.recent() -> { label, ... }` (most recent first, max 5, consecutive duplicates collapsed). `remember` is called from a `BufLeave`/`WinLeave` autocmd (augroup `AzureCliChatView`) for non-floating windows whose buffer isn't the chat's (`require("azure-cli.chat").is_chat_buf`) and records `VIEW.label(VIEW.snapshot(win))`. `M.snapshot` sets `snap.recent` to `recent()` minus the current snapshot's label. Text line (exact): `Recently: <a>; <b>` with each label's leading `on ` stripped.

- [ ] **Step 1: Failing tests** — `label` keeps `where_label`'s outputs: `{ pr = { id = 101 }, file = "src/auth.py", line = 12, thread = { id = 5000 } }` → `"on PR !101 · auth.py:12 · thread 5000"`; `{ screen = "PR dashboard" }` → `"on the PR dashboard"`; `{ screen = "other" }` → nil; plus `{ commit = "abcdef1234" }` → `"on commit abcdef1"`. Visible: a code window on a 100-line file scrolled so lines 40–60 show → `snap.visible == "40-60"` (set height 21, `winrestview({ topline = 40 })`). Trail: remember three code windows' snapshots, then snapshot the second again → `snap.recent` lacks the second's label, has the others most recent first; a float and a scratch chat buffer are never remembered; `VIEW.text({ recent = { "on a.lua:3", "on PR !1" } })` contains `Recently: a.lua:3; PR !1`.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run quick test + full suite; expect PASS** (the existing heading tests in `test-chat.lua` must stay green).
- [ ] **Step 5: Commit** — "Chat knows what's on screen and where you just were".

### Task 6: Live label in the chat input bar + docs

**Files:**
- Modify: `lua/azure-cli/chat/init.lua` — `M.set_winbars` (~line 478), popup footer (~line 851), a debounced refresh
- Modify: `docs/chat.md` (~line 75 paragraph)
- Test: `tests/test-chat-view.lua`

**Interfaces:**
- Consumes: `VIEW.label`, `VIEW.snapshot`, `M.main_win()`, `st.selection`.
- Produces: `M.view_label() -> string` — `VIEW.label(VIEW.snapshot(M.main_win(), sel))` under `pcall`, `""` on error or nil, where `sel` is the panel's pending selection when it belongs to that window. The panel input's winbar starts with it (`%#AzureCliWinbarTitle# <label> ` then the existing help text; escape `%` in the label as `%%`); the popup input's footer starts with it the same way. A `CursorMoved`/`BufEnter`/`WinEnter` autocmd on non-chat, non-float windows refreshes via a 200 ms debounced `M.set_winbars()` only while the panel is visible in the tab.

- [ ] **Step 1: Failing tests** — with a code buffer in one window and the panel open (`CHAT.show(false)`), `CHAT.view_label()` == `VIEW.label(VIEW.snapshot(win))` and the input window's `winbar` contains it; move the cursor, fire `CursorMoved` with `nvim_exec_autocmds`, wait 300 ms (`vim.wait`), the winbar shows the new line; register a describer that errors for a test filetype → `view_label() == ""` and no error.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.** Check `AzureCliWinbarTitle` (or whichever title group `UI.winbar` uses) exists; reuse it, don't add a highlight.
- [ ] **Step 4: Update `docs/chat.md`'s "Every message is sent together with…" paragraph**: plain code files (path, branch, function, diagnostics), Overview/Commits/work-item sections, visible lines and recent places, and that the input bar shows the label before you send. Keep it short.
- [ ] **Step 5: Run quick test + full suite; expect PASS.**
- [ ] **Step 6: Commit** — "Chat input shows what will be sent with the message".
