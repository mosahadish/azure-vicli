# Reviewer

_Part of the [azure-vicli](../README.md) docs._

## Reviewer

Opening a PR adds a tab with the file list on the left and the selected
content on the right. The first row is always the Overview: title,
description, commits, and PR-level comments.

Every winbar in the reviewer follows the same shape as the dashboard's - what
you're looking at, then any active mode tags, then `?: help` instead of a key
legend:

| Surface | Winbar |
|---|---|
| File list | `PR #123 · feature/x → main · 14 files [· src/]   [active-only] [ignore-ws] [batch: 2] [since <sha> · N new iteration(s)]   ?: help` - the trailing `· src/` only appears when every changed file shares a directory prefix (see below) |
| Diff pane | `path (+12 −3)   [tags]   ?: help` - the same tags as the file list |
| Overview | `Overview · PR #123   ?: help` |
| Revision/peek buffers (`gd`/`gr`/`gf`) | `[ref] path   ?: help` |
| Commit views (`gc`) | `commit <sha> · <file/subject>   ?: help`, with `(no comments shown)` on a per-commit diff |

Files are grouped by directory, sorted, each directory shown once as a dim
header row (`src/DataSource/`) followed by its files indented to just their
basename - even a directory with a single file gets its own header, for
consistency. The directory prefix shared by *every* changed file in the PR
(e.g. a PR entirely under `src/backend/`) is trimmed from every header and
shown once in the winbar instead, rather than repeated on every row. Each
file row also carries its status letter from the range (`A` added, `M`
modified, `D` deleted, `R` renamed) and a `(+adds −dels)` tally from the
cached diff - `(?)` until that diff has landed - plus the existing comment
count/🆕 marker. A header row isn't a file, and the cursor never rests on
one: `j`/`k`, `gg`/`G`, a search or a click that lands on a header hops to
the next file row in the direction of travel.

File list:

| Key | Action |
|---|---|
| `j` / `k` | Move; the right pane previews the file as you go |
| `<CR>` | Open and focus the file |
| `C` | Comment on the whole file |
| `gC` | New PR-level comment |
| `]C` / `[C` | Next / previous file with comments |
| `gA` | Show only active (unresolved) comments |
| `gF` | Manage text filters that hide matching threads |
| `gw` | Toggle ignoring whitespace in diffs |
| `gi` | Toggle showing only changes since your last review |
| `gv` / `gm` | Vote / complete |
| `gc` | Open the PR's commit list |
| `gB` | Toggle batch review for this PR |
| `gQ` | Show the queued batch-review items |
| `gS` | Submit the queued batch-review items, with a vote |
| `<` / `>` | Resize the list |
| `<BS>` | Back to the PR list |
| `q` | Close the reviewer |

Press `?` in the file list for a popup with these keys.

Diff pane:

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous change; at the last/first hunk in the file, continues into the next/previous file with any changes |
| `]C` / `[C` | Next / previous comment thread; at the last/first one in the file, continues into the next/previous file that has comments |
| `c` | Comment on the current line |
| `c` (visual mode) | Comment on the selected range of lines |
| `K` | View the comments on the current line in a popup; `R` and `s` work inside it, plus `e`/`dd` to edit/delete a comment of yours |
| `R` | Reply to the thread on the current line |
| `s` | Set the thread's status |
| `]C` / `[C` | Next / previous thread |
| `gd` / `gr` / `gf` | Code navigation, see below |
| `gw` | Toggle ignoring whitespace in diffs |
| `gi` | Toggle showing only changes since your last review |
| `gc` | Open the PR's commit list |
| `<BS>` | Back to the file list |

Press `?` in the diff pane or the Overview page for a popup with its keys.

Where a run of removed lines is immediately followed by a run of added lines,
the part of each line pair that actually changed is highlighted more
strongly than the rest, so a one-word edit on a long line stands out instead
of the whole line reading as uniformly changed.

Comments, replies and status changes appear the instant you submit them,
tagged "(sending…)" until the server confirms. If the call fails the entry is
removed and the prompt reopens with your text, so nothing is lost. Threads
refresh in the background every minute, and new comments on your PR or on
threads you took part in raise a notification (both `vim.notify` and, unless
disabled, a desktop toast).

On a comment you authored yourself, `e` edits it (prefilled with its current
text) and `dd` deletes it, in the K popup or on the Overview page. Both are
optimistic the same way a new comment or reply is - an edit shows at once,
tagged "(sending…)" until confirmed, and reverts with your text preserved
for a retry if the call fails; a delete removes the comment at once and
restores it (and its thread, if it was the thread's only comment) on
failure.

The diff pane's gutter shows the old and new line numbers side by side (an
added line has no old number, a deleted line no new one). Runs of unchanged
context beyond three lines of any change - or of any commented line - are
folded to `· N unchanged lines ·`; `zR` unfolds them all and `zM` folds them
again, and `]c` never lands inside one. Syntax highlighting follows
Neovim's own filetype detection, so a `Dockerfile` or a `.csproj` is
coloured too.

A commented line's marker carries the thread's status (`[active]`,
`[fixed]`, ...) and a line whose threads are all resolved is dimmed;
`<Tab>` expands the thread right under its line, as virtual text, and
collapses it again. `K` still opens the full popup.

Files you open with `<CR>` (or that `]c`/`]C` walk into) are marked viewed:
`✓` and dimmed in the file list, counted in the winbar (`14 files, 3
viewed`), and skipped by `]m` / `[m`, which jump to the next/previous file
not yet viewed. `m` toggles the mark by hand. A new push on the PR clears
every mark, since there's new content to look at. Every winbar in the
reviewer - the Overview and revision buffers included - shows the same mode
tags, plus `[N hidden]` when the active-only or text filters are hiding
threads; `?` repeats them on its first line.

`gm` shows the PR's title, branches, build state, unresolved thread count
and votes before completing, and warns when any of them argue against
merging; on success the reviewer closes. `gv` marks your current vote and
confirms a Reject, and the Overview's Votes line updates at once. `q` asks
before closing when batch-review items are queued or comment drafts are
unsent.

### Comment editor

Every place text gets typed for a comment - `c` (inline or on a visual
selection), `C` (file comment), `gC`/`c` on the Overview (PR comment), `R`
(reply, including from inside the K popup or the Overview, where the popup
stays open behind it), `e` (edit) and the prompt a failed send reopens with -
opens a small floating editor instead of a single-line command-line prompt,
anchored just below the line/thread it's about (or centred for a PR-level
comment/edit). It opens in insert mode, starts 3 lines tall and grows to 8
as you type, with a rounded border and a title naming what it's for (e.g.
"Comment · path:42", "Comment · path:42–48" for a range, "Reply · Jane
Doe", "Edit comment", "PR comment"). The code line(s) being commented on (or
the thread being replied to) show dimmed just above the buffer as reference
text - never part of what gets submitted.

| Key | Action |
|---|---|
| `<C-s>` / `<C-CR>` (insert or normal mode) | Submit |
| `q` (normal mode) | Cancel |
| `<Esc><Esc>` | Cancel (the first `<Esc>` just leaves insert mode, like usual) |

Submitting empty text (or nothing typed at all) cancels instead. Cancelling
keeps whatever you'd typed as a draft, keyed by the PR and exactly what you
were commenting on (the same line, file, PR, or thread) - opening the editor
again for that same target starts from the draft, even after leaving and
re-entering the PR within the same session (drafts are in-memory and don't
survive a Neovim restart). A successful submit clears the draft.

Typing `@` opens completion over the PR's reviewers; picking one inserts
their display name as plain text. Azure DevOps only sends a notification for
an `@<GUID>` mention, never a plain-text one, so the editor translates every
`@Display Name` it recognises to `@<their GUID>` right before submitting -
azure-cli.py's `--list` carries each reviewer's id (an
`IdentityRefWithVote` id) alongside their name for exactly this. A name
that's typed but isn't a recognised reviewer is sent as plain text and
simply won't notify anyone.

### Per-commit diffs

`gc` (file list or diff pane) opens the PR's commit list - the same commits
the Overview's "Commits (who pushed):" block lists, as their own scrollable
buffer. `<CR>` on a commit there, or directly on one in the Overview, shows
that commit's changed files (its status letter and path); `<CR>` on one of
those shows that file's diff for that commit alone, not the PR's overall
diff. `<BS>` walks back a step the same way `gd`/`gr` do, and `q` goes all
the way back to whatever diff or Overview you started from. Comments never
show in a commit diff - they're anchored to the PR's final diff, not any one
commit along the way - and the winbar there says so.

### Range comments

Select a run of lines in visual mode and press `c` to comment on the whole
range instead of a single line - both ends must be commentable and on the
same side of the diff, and a single-line selection is the same as pressing
`c` in normal mode. The comment appears at once against the range's first
line, with the rest of it picked out by a subtle highlight; `K` on that first
line shows the thread with its `lines N–M` span in the header.

### Batched review

By default every comment, reply or file/PR-level note goes out the moment
you submit it - the fast path above. `gB` (file list, diff pane or Overview)
instead turns on batch review for the rest of this PR: from then on, every
new comment, file comment, PR comment and reply is queued instead of sent,
shown at once the same way but tagged "(queued)" rather than "(sending…)",
and the winbar grows a `[batch: N]` tag. `gQ` opens a float listing the
queue (`kind`, location, text); `dd` on a line removes that item, `q`/`<Esc>`
closes. `gS` prompts for a vote - the same choices `gv` offers, plus "No
vote" - then submits every queued item in order, each one flipping from
"(queued)" to "(sending…)" to confirmed in turn; a failed item stays in the
queue (still tagged) and the rest continue, then the vote (if you picked
one) is cast last. Batch mode turns itself back off once everything lands
cleanly; a failed submit leaves it on with just the failures still queued,
so `gS` again retries only those. The queue survives leaving and
re-opening the same PR within one nvim session.

### Changes since my last review

`gi` (file list, diff pane or Overview) toggles showing only what's been
pushed to this PR since your last review activity - your last comment,
reply or vote, whichever was most recent. Turning it on narrows the file
list to just the files that actually changed in that window, and every
diff shown is against the commit your last review left off at instead of
the PR's whole range; the winbar grows a
`[since <short-sha> · N new iteration(s)]` tag, and the Overview gains
a "Since your last review" line with the same count plus how many files
changed. `gi` again turns it back off. Because the source branch may have
been pushed to more than once since you last looked, "since" means since
the iteration (push) current at the time of your last activity, not since
the most recent push before it.

Comments anchored to the target-branch side of the diff ("L", i.e. lines
that were removed or that a comment was left on the base copy of the file)
are hidden while this mode is on: their line numbers are relative to the
target branch's copy of the file, not the commit this mode diffs from, so
there's no correct place to show them against the narrower diff - comments
on added/context lines ("R") are unaffected. If you haven't commented on or
voted on the PR at all yet, there's no "last review" to compare since and
`gi` says so instead of turning on; if every push happened before your last
review activity, everything in the PR already counts as "new" and `gi` says
so too, leaving the normal full-PR view in place; and if the commit your
last review left off at isn't available in this local clone anymore (a
force-push that rewrote history, or a shallow fetch), `gi` falls back to the
normal view with a warning rather than handing git a range it can't resolve.

### Follow up on my comments

`gu` (file list, diff pane or Overview) opens a picker of every thread YOU
started on this PR (any status - the first comment has to be yours, a reply
to someone else's thread doesn't count), answering "did anything land near
what I asked about since I last reviewed?" without re-reading every file by
hand. It reuses `gi`'s own "last review point" (your last comment, reply or
vote) and base commit, so the two features always agree on "since when".

Each row is tagged `✔ changed`, `– unchanged` or `? n/a`, then the file:line,
status and the first 80 characters of your comment, then how many replies
it has:

```
✔ changed    src/Foo.cs:42       [active]   "did we handle the null case here?"  (1 reply)
– unchanged  src/Bar.cs:10       [active]   "typo: recieve -> receive"           (0 replies)
? n/a        src/Baz.cs:5        [fixed]    "this branch looks dead"             (2 replies)
```

A thread on the source side (`R`) is `changed` when a `git diff --unified=0`
of the since-range touches a line within 3 of yours (i.e. something was
actually pushed near your comment - not just anywhere in the file) and
`unchanged` otherwise (including when the file has no changes in that range
at all). A thread on the target side (`L`, e.g. a comment left on a removed
line) is always `n/a` - its line has no meaningful position in the
since-range's diff, the same reason `gi` itself hides `L` comments. A
file-level or PR-level comment of yours (not anchored to a line at all) is
listed at the end under "Unanchored", ungraded.

The list is on the left, a preview of the file (source tip for an `R`/
unanchored row, target tip for an `L` row) on the right, centred on the
comment's line with any nearby since-range change highlighted:

| Key | Action |
|---|---|
| `j` / `k` | Move; the preview follows |
| `<CR>` | Open the file in the diff pane on that line |
| `K` | View the full thread in a popup |
| `R` | Reply to the thread |
| `s` | Set the thread's status |
| `q` / `<Esc>` | Close |

A reply or status change updates that row (replies count / status) in
place without closing the picker. If you haven't commented on this PR at
all, or `gi`'s own "no last review to compare since" conditions apply (see
above), `gu` says so instead of opening.

## Code navigation

The reviewer navigates code across the whole repository at the PR's revision
without a checkout or a language server. `git grep` searches the source
branch (the target branch when the cursor is on a deleted line), and
`git show` reads files at that revision.

| Key | Action |
|---|---|
| `gd` | Go to the definition of the identifier under the cursor |
| `gr` | Find references |
| `gf` | Open the current file at the PR's revision, on the same line |
| `g/` | Search text across the PR's changed files |

`gr` and `gd` open a peek view: hits on the left, and on the right the file
at that revision centred on the selected hit with the line and every
occurrence highlighted. Moving through the list re-previews. `<CR>` opens the
hit, `q` closes the peek. `g/` uses the same peek view for plain text you
type, searched only across the PR's changed files at the source branch,
case-insensitive unless the text has an uppercase letter and prefilled with
your last search.

Opened files and previews show the PR's changes: added lines in green, and
the lines the PR removed in red as virtual lines where they used to be. In a
revision buffer `gd` and `gr` keep working, `<BS>` walks back one jump, and
`q` returns to the diff. Press `?` there for a popup with these keys.

The definition lookup is a heuristic that ranks grep hits by declaring
keywords, modifiers, and shapes such as a type followed by `Name(`. When one
line clearly wins it opens directly; ties show the candidates; no plausible
definition falls back to the references list.
