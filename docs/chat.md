# Chat

_Part of the [azure-vicli](../README.md) docs._

The chat panel puts an AI agent (Claude Code, the GitHub Copilot CLI, or any
command that can use MCP tools) next to whatever you're looking at in
azure-vicli: the PR dashboard, the reviewer, the work items. The agent knows
what's under your cursor and can act on it. You can say things like:

- *"Triage this PR's comments"* (from the reviewer): it reads every thread
  and the diff, tells you what to do about each, and drafts replies.
- *"What do you think about this comment?"* (cursor on a thread): it knows
  which thread, file and line you mean.
- *"Create a branch from develop for this work item"* (on the work items
  screen): it creates the branch on the server, links it to the work item,
  and can check it out locally.
- *"Fix this comment"*: it changes the code in a separate worktree, shows
  you the diff, and commits and pushes it once you allow it, then drafts the
  reply.
- *"Why did the build fail?"*, *"show me where that is"*, *"split this
  story into tasks and move it to next sprint"*, `/standup` ...

azure-vicli ships no agent configuration; you choose the agent and model
(see [Setting it up](#setting-it-up)).

- [Using it](#using-it)
- [Saved prompts, references and selections](#saved-prompts-references-and-selections)
- [Conversations, agents and models](#conversations-agents-and-models)
- [Setting it up](#setting-it-up)
- [Let the agent set itself up](#let-the-agent-set-itself-up)
- [What the agent can do](#what-the-agent-can-do)
- [How it works](#how-it-works)

## Using it

`gq` on any azure-vicli screen (or `:AzureCli chat`) takes you to the chat:
it opens the panel, or jumps into it if it's already showing, and puts you
in its input box. `gq` (or `q`) inside the panel hides it, and `<BS>` goes
back to the screen next to it while leaving it open. Once shown, the panel
appears in every azure-vicli tab you visit (dashboard, reviewer, work items)
until you hide it. The conversation is the same in every tab.

| Key (in the panel) | Action |
|---|---|
| `<CR>` (input box, normal mode) / `<C-s>` (while typing) | Send the message |
| `<Up>` / `<Down>` (input box) | Step through the messages you sent |
| `i` / `a` (conversation) | Go to the input box |
| `<CR>` (conversation) | Open the `!PR` or `#work item` under the cursor |
| `gr` (conversation) | Draft the answer under the cursor as a reply to the thread its question was about (or a PR comment), queued for `gS` |
| `gp` | Run a saved prompt |
| `gL` | What the agent changed; `u` on a line undoes it |
| `gd` | The agent's code change (a fix or a story), file by file like the reviewer |
| `gh` | Open an earlier conversation |
| `gn` | Start a new conversation (the current one stays in `gh`) |
| `ga` / `gm` | Choose the agent / the model |
| `<C-c>` | Stop the agent |
| `<` / `>` | Make the panel smaller / bigger (kept for the session, in every tab) |
| `<BS>` | Back to the screen next to the panel |
| `q` / `gq` | Hide the panel (`gq` on a screen brings you back to it) |
| `?` | These keys |

Every message is sent together with a description of what you're looking at:
the screen, plus the PR, work item, file, line, code and comment thread under
the cursor in the window you were last in. Your message's heading in the
conversation shows it, e.g. `on PR #101 · auth.py:12 · thread 5000`. Move the
cursor, then ask; "this" always means what's under it now.

While the agent works, its answer appears as it's written (with Claude
Code's `stream-json` output, see below; other agents show their output as it
arrives), along with its tool calls as they happen: azure-vicli's own
(`· get_pr_threads (pr_id=101)`, `✎ draft_reply (...)`) and the agent's
(`· Read src/auth.py`). A spinner turns in the panel's title bar
(`[⠹ working]`) until it's done, and the answer's heading counts the
seconds. With the panel hidden, put it in your statusline:
`require("azure-cli.chat").status()` is `⠹ Copilot 42s` while the agent
works and `""` otherwise (lualine: `{ function() return
require("azure-cli.chat").status() end }`).

Each turn has a coloured bar down its left side: one colour for you, another
for the agent. The agent's markdown is rendered (headings, **bold**, `code`,
lists, with the markers hidden except on the cursor line). Tool calls are dim
for lookups, warning-coloured for changes (`✎`) and error-coloured when
something failed or you declined it (`✗`). The colours are highlight groups
linked to your colorscheme's, so `:hi` can restyle them: `AzureCliChatYou`,
`AzureCliChatAgent`, `AzureCliChatMeta`, `AzureCliChatToolRead`,
`AzureCliChatToolWrite`, `AzureCliChatToolErr`, `AzureCliChatNote` (keep them
foreground-only, or they paint bands across the panel). The standalone
launcher sets them in its own palette.

## Saved prompts, references and selections

**Saved prompts.** `/triage`, `/review`, `/explain`, `/build` and `/standup`
come built in; type one in the input box (anything after it is added to
the prompt, e.g. `/review focus on error handling`) or pick one with `gp`.
They run against what's on screen like any message. Add your own, replace
or remove the built-in ones with `chat.prompts`:

```lua
prompts = {
  security = "Look for injection, auth and secrets problems in this PR's change.",
  standup = false,   -- remove a built-in one
},
```

**References.** Write `!101` for a pull request and `#3001` for a work item
(type `!` or `#` and a completion menu lists your PRs and work items). The
agent gets a line about each one you name with your message, and writes them
back the same way. In the conversation, `<CR>` on one opens the PR in the
reviewer or the work item in its view.

**Selections.** Select lines (in a diff, the Overview, a work item), then
press `gq`: the panel opens and the next message carries the selected text
and, in a diff, which file lines it covers. The winbar shows
`[selection: N lines]` until it's sent. Without a selection, a message from
a diff carries the change (the run of added/removed lines) around the cursor.

## Conversations, agents and models

Conversations are saved (under Neovim's data directory, the last 50): the
one in the panel is still there after a restart, `gn` starts a new one, and
`gh` brings back an earlier one, its session included.

With several agents configured (`chat.agents`, below), `ga` switches
between them; the new one can't resume the other's session, so your next
message replays the conversation to it. `gm` picks the model for the current
agent.

**Proactive.** When the dashboard sees new comments on one of your PRs, a
note appears in the conversation suggesting `/triage` (no agent runs;
`suggest_on_new_comments = false` turns it off). With `daily_summary =
true`, the first time the dashboard loads each day the chat runs `/standup`
in a fresh conversation and tells you when it's ready.

## Setting it up

The panel's placement, and the agent it talks to, go in `setup()` (or the
standalone launcher's `azure-cli.lua`):

```lua
require("azure-cli").setup({
  chat = {
    position = "right",     -- "right" (default), "left", "bottom" or "top"
    size = 0.35,            -- a fraction of the screen, or a number of columns/lines
    input_height = 3,       -- lines in the input box
    agent = {
      label = "Claude",
      models = { "sonnet", "opus", "haiku" },   -- gm picks one; the first is the default
      cmd = { "claude", "-p", "--output-format", "stream-json", "--verbose", "--model", "{model}",
              "--mcp-config", "{mcp_config}", "--add-dir", "{fix_root}",
              "--allowedTools", "mcp__azure-vicli,Read,Grep,Glob,Edit,Write" },
      stdin = "{message}",
      followup = {          -- later messages continue the same session
        cmd = { "claude", "-p", "--output-format", "stream-json", "--verbose", "--model", "{model}",
                "--mcp-config", "{mcp_config}", "--add-dir", "{fix_root}",
                "--allowedTools", "mcp__azure-vicli,Read,Grep,Glob,Edit,Write",
                "--resume", "{session_id}" },
        stdin = "{message}",
      },
    },
  },
})
```

- `--output-format stream-json --verbose` streams the answer into the panel
  as it's written (`--output-format json` works too, all at once).
- `--allowedTools "mcp__azure-vicli"` lets Claude Code use azure-vicli's
  tools without its own prompts (it can't show them in a headless run);
  which changes still ask you is azure-vicli's business, see
  [below](#what-the-agent-can-do).
- `Edit,Write` and `--add-dir {fix_root}` are for "fix this comment" and
  "implement this work item": the
  agent edits files in a worktree under `{fix_root}`, never in your checkout
  (the instructions it's given say so). Leave them out if you don't want the
  agent changing code at all.

**Several agents.** Instead of `agent`, give `agents = { claude = {...},
copilot = {...} }` and optionally `default_agent = "claude"`; `ga` switches.

| `chat.agent` field | Meaning |
|---|---|
| `cmd` | The command (a list, or a string run through `'shell'` with every value shell-escaped). |
| `stdin` | Written to its stdin (default `"{message}"`); closed right after, unless `persistent` is set. Unused when `acp` is set - the message goes in `session/prompt` instead. |
| `followup` | `{ cmd, stdin, env }` for every message after the first. With `{session_id}` in it, it's used once a session id is known; without a `followup`, each message replays the conversation so far instead. Ignored when `persistent` or `acp` is set. |
| `persistent` | Keep this agent's process running between messages instead of starting a fresh one each time: see [Keeping the agent warm](#keeping-the-agent-warm) below. |
| `acp` | The process speaks the [Agent Client Protocol](https://agentclientprotocol.com) (`copilot --acp`): a warm, bidirectional session instead of `persistent`'s one-way stream. See below. |
| `session_pattern` | A Lua pattern with one capture that finds the session id in the agent's output, for an agent that prints it rather than returning Claude Code's JSON. Unused when `acp` is set (the agent returns a session id directly). |
| `models` / `model` | The models `gm` offers (strings, or `{ label, value }`) and the default. Reaches the agent through `{model}` (`acp`: `session/set_config_option` instead). |
| `label` | The agent's name in the panel. |
| `strip` | Lua patterns: output lines matching any are dropped (a CLI's own log of its tool calls, e.g. `{ "^\u{25CF} ", "^%s+\u{2514}" }` for Copilot's `● tool` / `└ result` lines). Unused when `acp` is set. |
| `env`, `timeout_seconds` | Extra environment; how long a message may take (default 900). For `persistent`, a timeout stops the whole process; for `acp` it asks the agent to stop the turn first (`session/cancel`), then stops the process if that doesn't work within 5s. |

Placeholders: `{message}` (your message, with the view description, the
references and, on the first message, the instructions), `{message_json}`
(the same, as a JSON string - quoted and escaped - for building a JSON line
by hand), `{text}` (just what you typed, prompts expanded), `{view}` (the
view description), `{mcp_config}` (the MCP config file - unused when `acp`
is set, which passes the same server directly in `session/new`), `{fix_root}`
(where fix and story worktrees live), `{session_id}`, `{model}`.

### Keeping the agent warm

By default every message starts a fresh process: simple, and fine for most
CLIs, but it pays that process's startup cost (and, without a `followup`
with a session id, resends the whole conversation) on every message. Two
ways to avoid that, for a CLI built for one of them - most aren't, so this
isn't the default:

**`persistent = true`** keeps one process running for the life of the
conversation: the first message starts it as usual (`cmd`/`stdin`, not
closed), and every later message is written straight to its stdin - no new
process, and no need for `followup` since the same one remembers
everything. It's only worth setting for a CLI that reads a stream of
per-turn requests from stdin without exiting between them, and writes a
stream of per-turn events back - a plain `-p "prompt"` CLI has nothing to
loop on and will just exit (or hang) after the first message. Claude
Code's `--input-format stream-json --output-format stream-json` is the one
this has been checked against:

```lua
agent = {
  label = "Claude",
  persistent = true,
  models = { "sonnet", "opus", "haiku" },
  cmd = { "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
          "--model", "{model}", "--mcp-config", "{mcp_config}", "--add-dir", "{fix_root}",
          "--allowedTools", "mcp__azure-vicli,Read,Grep,Glob,Edit,Write" },
  -- Every turn, first one included, is one JSON line of Claude's own
  -- "user message" shape - {message_json} does the quoting/escaping.
  stdin = '{"type":"user","message":{"role":"user","content":[{"type":"text","text":{message_json}}]}}',
},
```

**`acp = true`** is for a CLI with an [Agent Client
Protocol](https://agentclientprotocol.com) server mode instead - GitHub
Copilot CLI's `--acp`, checked against a real, logged-in `copilot --acp`.
ACP is JSON-RPC, not a plain stream: azure-vicli (`chat/acp.lua`) does the
handshake (`initialize`, `session/new` - passing the azure-vicli MCP server
straight in its `mcpServers`, no `{mcp_config}` file needed) once, then one
`session/prompt` per message on the same session, with the answer streamed
in through `session/update`. There's no `cmd` templating - the prompt text
goes in `session/prompt` directly - so `stdin`, `followup` and
`session_pattern` don't apply:

```lua
agent = {
  label = "Copilot",
  acp = true,
  models = { "claude-sonnet-5", "gpt-5.4" },   -- `copilot --help` / the Model config option lists them
  cmd = { "copilot", "--acp" },
},
```

**MCP tools don't currently reach the agent this way.** Confirmed against a
real `copilot --acp` (1.0.92): its `initialize` response only advertises
`mcpCapabilities: {http, sse}` - no stdio - and its own log says why a
passed-in server doesn't show up: `[rust:acp::mcp_servers] Rejecting
non-http/sse MCP server "azure-vicli" from client`. azure-vicli's MCP
server (`azure-cli.py --mcp`) is stdio-only, so under `acp = true` Copilot
gets none of azure-vicli's tools - no `current_view`, `draft_reply`,
`start_fix`, and so on - just general coding help with no idea what PR or
work item you're looking at. That's most of what this chat panel is for,
so `acp` isn't a straight upgrade over the headless setup in [GitHub
Copilot CLI](#github-copilot-cli) below until Copilot's ACP takes a stdio
server (or azure-vicli grows an http/sse transport for one - it doesn't
have one today). Claude Code's `persistent` path above doesn't have this
problem: `--mcp-config` is a stdio server the same way the non-persistent
setup already uses it.

A tool call Copilot wants permission for (editing a file, running a
command) pops up the same yes/no prompt as azure-vicli's own tools, with
its diff shown when it has one; "Allow"/"Deny" there picks Copilot's
`allow_once`/`reject_once` option. Unlike `persistent`, stopping a turn
(`<C-c>`, a timeout) first asks the agent to stop it (`session/cancel`)
instead of killing the process outright, so the session survives a
cancelled message when the agent cooperates.

Either way, the warm process/session is stopped (and the next message
starts a new one) on `ga` (a different agent can't continue it), `gh` (a
different conversation), starting a new chat, and quitting Neovim - it's
tied to one conversation with one agent, not kept around indefinitely.

The rest of `chat`: `position`, `size`, `input_height`, `agent` / `agents` /
`default_agent`, `prompts` (above), `permissions` (below), `daily_summary`
(default false), `suggest_on_new_comments` (default true).

The agent runs in the local clone of the PR you're looking at, when there is
one, so a repository's own agent instructions and skills apply. A skill
checked into the repository works from the chat too: "use the
triage-pr-comments skill on this PR".

### GitHub Copilot CLI

Recent Copilot CLI versions take an extra MCP config with
`--additional-mcp-config @<file>`, continue a session with
`copilot --resume <id>`, allow tools without prompting with
`--allow-tool` (`'azure-vicli'` for all of a server's tools, `'write'` for
file edits, `'shell(git)'` for one command) and extra directories with
`--add-dir`. Without them a headless run refuses every edit. Check
`copilot --help` for your version's flags, and point `session_pattern` at
wherever it prints the session id. This example's flags and pattern are
unverified; adapt them:

```lua
agent = {
  label = "Copilot",
  models = { "gpt-5", "claude-sonnet-4.5" },   -- examples: use what `copilot --help` lists
  cmd = { "copilot", "-p", "{message}", "--model", "{model}", "--additional-mcp-config", "@{mcp_config}",
          "--allow-tool", "azure-vicli", "--allow-tool", "write", "--add-dir", "{fix_root}" },
  session_pattern = "[Ss]ession[ %-_]?[Ii][Dd]:?%s*([%w%-]+)",
  strip = { "^\u{25CF} ", "^%s+\u{2514}" },   -- drop Copilot's own "● tool / └ result" log lines
  followup = { cmd = { "copilot", "--resume", "{session_id}", "-p", "{message}", "--model", "{model}",
                       "--additional-mcp-config", "@{mcp_config}",
                       "--allow-tool", "azure-vicli", "--allow-tool", "write", "--add-dir", "{fix_root}" } },
},
```

Without a session id it still works; each message replays the conversation.
`persistent` doesn't apply here - `-p` exits after one message regardless.
`acp = true` (see [Keeping the agent warm](#keeping-the-agent-warm)) gives
a warm session instead, but - as of Copilot CLI 1.0.92 - at the cost of
azure-vicli's own tools, which its ACP implementation can't connect to
yet; this headless setup is the one with full tool access.

### Let the agent set itself up

You can hand this section to the agent itself (Copilot, Claude Code, ...)
and it can do the setup for you: open the agent in this repository and tell
it **"follow the agent setup steps in docs/chat.md"**.

**Agent setup steps.** You are configuring yourself as azure-vicli's chat
agent. Do every step, check every flag against the installed CLI instead of
guessing, and finish by telling the user what you wrote and anything you
couldn't confirm.

1. **Find your own CLI flags** (`<your-cli> --help`, plus your docs) for this
   installed version:
   - a one-shot, non-interactive prompt (e.g. `-p`), and whether the prompt
     can come from stdin instead of an argument;
   - adding an MCP server config from a JSON file for one run. azure-vicli
     writes `{"mcpServers": {"azure-vicli": {"command", "args", "env"}}}`
     and passes its path as `{mcp_config}`. Claude Code uses
     `--mcp-config {mcp_config}`; Copilot's equivalent is likely
     `--additional-mcp-config @{mcp_config}`;
   - allowing every tool of the MCP server named `azure-vicli` without
     prompting. A headless run can't prompt, so this is required. Prefer a
     per-server allow (Claude Code: `--allowedTools mcp__azure-vicli`) over
     allowing all tools, and never allow shell tools for this. azure-vicli
     asks the user itself before pushes, votes and other visible changes;
   - if the CLI prints its own log of tool calls into its answer, the
     patterns that match those lines (for `strip`);
   - choosing a model, and the valid model names;
   - streaming output, if it has any (Claude Code: `--output-format
     stream-json --verbose`); azure-vicli shows plain text as it arrives
     either way;
   - for "fix this comment": letting it edit files in an extra directory,
     `{fix_root}` (Claude Code: `--add-dir {fix_root}` and `Edit,Write` in
     `--allowedTools`) - only if the user wants the agent changing code;
   - whether a non-interactive run reports a session id (stdout, stderr, or
     a JSON field), and how to resume that session (e.g. `--resume <id>`);
   - whether it has a mode built to stay running across many turns on one
     stdin/stdout stream (not just "resume by id" - actually reading more
     requests after answering one, without exiting), or an Agent Client
     Protocol server mode (`--acp` or similar - check for it explicitly,
     it won't show up as an ordinary flag doing the same thing as `-p`).
     Either can skip starting a fresh process each message: `persistent`
     for the former, `acp` for the latter - see [Keeping the agent
     warm](#keeping-the-agent-warm). Most CLIs have neither; don't force it.
2. **Decide how the prompt is passed.** azure-vicli's message has several
   lines. On Windows, an npm-installed CLI is a `.cmd` shim that cuts
   arguments at the first newline, so pass the prompt on stdin
   (`stdin = "{message}"`) whenever the CLI can read it from there.
   Otherwise put `"{message}"` in `cmd`.
3. **Find where the user's options live.** If their Neovim config calls
   `require("azure-cli").setup({...})`, edit that call. Otherwise it's the
   standalone launcher's `azure-cli.lua` next to `azure-cli.yml`:
   `%APPDATA%\azure-cli.lua` on Windows, `~/.config/azure-cli.lua`
   elsewhere. Create it with `return { ... }` if it doesn't exist. Keep
   everything already there.
4. **Write the `chat` block** (the fields are in the table above), shaped like
   the examples in this file:
   `chat = { agent = { label, models, cmd, stdin, followup, persistent, session_pattern, strip } }`.
   Use `{model}` where the model flag goes, and list the model names from
   step 1 in `models`. Add `followup` (the same command plus the resume flag
   with `{session_id}`) only if step 1 found a session id. If the CLI prints
   it rather than returning JSON, also add a `session_pattern`: a Lua
   pattern whose one capture is the id. Without a session id, leave
   `followup` out; every message then replays the conversation, which
   works.
5. **Test the command by hand**: run it once with a short prompt and the
   flags you chose (no MCP config needed for this), to see that it answers
   and, if it should, prints a session id where you expect it.
6. **Tell the user** to restart azure-vicli (or re-run `setup()`), press `gq`
   on the PR dashboard and ask "what am I looking at?". The answer should
   name the PR under the cursor, which shows the azure-vicli tools work.

## What the agent can do

The agent gets an MCP server named `azure-vicli` with these tools:

| Tool | What it does | Asks you first? |
|---|---|---|
| `current_view` | What you're looking at when you sent the message (see above) | - |
| `list_pull_requests`, `get_pull_request` | Your dashboard's PRs; one PR's details - any PR in the project by id, not only your dashboard's (after it, the other PR tools work for that PR too) | - |
| `find_implementations`, `find_definition` | Across a whole repository (the fix/story worktree, a PR's source branch, or a local clone): the types implementing an interface or deriving from a class, and the ones deriving from those; where a type or member is declared. Text-based (`git grep` and declaration patterns for C#, Java, TypeScript, Kotlin, Python, ...), no build needed | - |
| `get_pr_threads`, `get_pr_diff` | A PR's comment threads (fresh) and its diff | - |
| `get_build_log` | Why a PR's build failed: the failed steps, their errors, the end of their logs | - |
| `list_work_items`, `get_work_item`, `list_sprints` | Your sprint's items; one item in full; the team's sprints | - |
| `open_in_ui` | Shows you a PR in the reviewer (at a file and line) or a work item | - |
| `annotate_code`, `clear_annotations` | Notes on lines of a PR's diff, shown under them in the reviewer (only to you) | - |
| `link_pr_to_work_item` | Links a PR and a work item | no |
| `create_branch` | Creates a branch from another one's tip on the server, links it to a work item (its Development section), optionally checks it out in your clone | no |
| `draft_reply`, `draft_comment` | Drafts a reply or a new comment (line, file or PR). **Not posted**: it goes into that PR's [batch-review](reviewer.md) queue, and `gS` in the reviewer sends it | no |
| `create_child_task`, `move_to_sprint` | A task under a work item; a work item into a sprint | no |
| `requeue_build` | Queues the PR's build again | no |
| `start_fix`, `show_fix`, `discard_fix` | A worktree of the PR's branch to change code in; the change so far (shown to you in a tab like the reviewer: changed files on the left, `]c`/`[c` through the changes); throwing it away | no |
| `start_story` | Implementing a work item: a new branch on the server (linked to it) and a worktree of it to change code in. `show_fix` / `discard_fix` / `commit_and_push_fix` then take the work item's id | no |
| `delete_fix_file` | Deletes a file in the fix/story worktree (the agent's own file tools can't delete); any path outside the worktree is refused, so it needs no shell permission | no |
| `commit_and_push_fix` | Commits the change and pushes it to the PR's (or the story's) branch | **yes**, showing the diff |
| `set_thread_status` | Resolves (or reopens, ...) a comment thread | **yes** |
| `add_reviewer`, `update_pr_description` | A reviewer by name or email; the description | **yes** (the description is shown) |
| `create_pull_request`, `complete_pull_request` | Opens a PR (linking work items); merges one | **yes** |
| `vote` | Votes on a PR | **yes** |
| `set_work_item_state`, `assign_work_item`, `comment_on_work_item` | A work item's state, assignee, discussion | **yes** (the comment is shown) |

When a tool asks, a prompt pops up in Neovim ("The agent wants to vote
"Approve" on PR #101. Allow?"), with the diff or text it would send next to
it. "Deny" is reported back to the agent, which carries on without it.

**Your own rules.** `chat.permissions` overrides any tool: `"allow"` (no
question), `"ask"`, or `"deny"` (the agent doesn't even see it):

```lua
permissions = { create_branch = "ask", commit_and_push_fix = "deny", set_thread_status = "allow" },
```

**Undo.** Every change the agent makes is logged; `gL` lists them (newest
first) and `u` on one undoes it where that's possible: unlinking, deleting a
branch it created (only if nobody pushed to it since), taking a draft back
out of the queue, and putting back a vote, a state, an assignee, a sprint, a
thread's status or a description. Opening or completing a PR, comments,
tasks and pushes can't be undone from here; the list says so.

### Fix this comment

1. You ask (from the thread, ideally): "fix this comment".
2. The agent calls `start_fix`: a git worktree of the PR's source branch at
   its latest commit, under `{fix_root}` (Neovim's cache directory), never
   your own checkout.
3. It edits the files there with its own tools, then `show_fix` opens the
   change in a tab of its own, laid out like the reviewer: the changed files
   on the left (moving through them previews each), the file's diff on the
   right with the reviewer's keys - `]c` / `[c` jump between changes and on
   into the next file, `<BS>` goes back to the files, `gf` opens the file in
   the worktree to edit it yourself, `<` / `>` resize, `q` closes. The chat
   comes along into that tab: `gq` goes to it (in visual mode, with the
   selected lines), and it knows the file and line you're on. The view
   doesn't follow the agent's edits by itself - `r` refreshes it, staying on
   the same file and line.
4. `commit_and_push_fix` asks you, with the diff next to the question, then
   commits (with your git identity) and pushes to the PR's branch. If
   someone pushed in the meantime the push fails and nothing is lost; ask it
   to try again from the new tip.
5. It drafts a reply ("Fixed in abc123: ...") into the batch queue.

### Implement a work item

1. On the work item (or naming it: "implement #3001"), ask for it. Say
   which repository and base branch if it can't tell; it asks otherwise.
2. The agent calls `start_story`: it creates the branch on the server from
   the base branch (e.g. `feature/3001-login-throttle` from `develop`),
   linked to the work item like `create_branch`, and a worktree of it under
   `{fix_root}`. An existing branch of that name is used as it is, and
   asking again for the same work item picks up where it left off.
3. It edits files there, then `show_fix` shows you the change.
4. `commit_and_push_fix` asks, with the diff, then pushes to the branch.
5. It offers `create_pull_request` (which asks too), linking the work item.

The repository has to be cloned locally: `<clones_dir>/<repo>`, as for
reviews. `u` in `gL` deletes the branch again as long as nothing was pushed
to it.

**The agent has to be allowed to edit there.** It runs headless, so it can't
ask you for its own permissions: anything you didn't allow up front is
refused, and the agent stops with something like "permission denied and
could not request permission from user". Allow file edits in `{fix_root}`
(Claude Code: `--add-dir {fix_root}` and `Edit,Write`; Copilot: see
[below](#github-copilot-cli)). Allowing a shell as well (to build and run
tests) is your call; azure-vicli never needs it.

## How it works

```
Neovim (chat panel) --stdin--> agent CLI --stdio MCP--> azure-cli.py --mcp
       ^                                                       |
       '------------- 127.0.0.1 bridge (JSON + token) <--------'
```

Each message runs the agent headless. `{mcp_config}` points it at
`azure-cli.py --mcp`, a small relay that answers MCP over stdio and forwards
every `tools/list` and `tools/call` to a bridge the panel opens on
127.0.0.1. The bridge checks a random per-session token, which only the
relay knows from its environment. The tools themselves run inside Neovim
(`lua/azure-cli/chat/tools.lua`), through the same provider calls, caches
and batch queue the rest of azure-vicli uses. That's how the agent sees
exactly what you see.
