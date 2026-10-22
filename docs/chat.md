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
- [Plans, and asking why](#plans-and-asking-why)
- [Several agents at once](#several-agents-at-once)
- [What the agent can do](#what-the-agent-can-do)
- [How it works](#how-it-works)

## Using it

`i` on any azure-vicli screen (or `:AzureCli chat`) takes you to the chat:
it opens the panel, or jumps into it if it's already showing, and puts you
in its input box, typing - keeping whatever you had typed there. The
screens are read-only views, so `i` there has nothing else to do. `q`
inside the panel hides it - in every tab, so it doesn't greet you again in
the next one - and `<BS>` goes back to the screen next to it while leaving
it open. Once shown, the panel appears in every azure-vicli tab you visit
(dashboard, reviewer, work items, issues, Agents, plans) until you hide it,
at the size you last gave it. The conversation is the same in every tab. (`gq` did this before; it's gone -
a `gq` left in your `setup()` is skipped, with a warning when you had
changed it.) `chat.allowed_skills` is gone too: `setup()` stops with an
error until you remove it, and you allow a skill from `/skills` instead
(see [What the agent can do](#what-the-agent-can-do)).

| Key (in the panel) | Action |
|---|---|
| `<CR>` (input box, normal mode or while typing) / `<C-s>` (while typing) | Send the message; with the completion menu open, `<CR>` picks the entry instead |
| `<S-CR>` / `<C-j>` (while typing) | A new line in the message (`<S-CR>` where the terminal reports it, `<C-j>` everywhere) |
| `<Up>` / `<Down>` (input box) | Step through the messages you sent |
| `i` / `a` (conversation) | Go to the input box |
| `<CR>` (conversation) | Open the `!PR` or `#work item` under the cursor; on a queued message, send it |
| `dd` / `cc` (conversation, on a queued message) | Cancel it / edit it in the input box (sending it again puts it back in its place in the queue) |
| `<Tab>` (conversation) | Unfold a long answer, or the list of tool calls folded into one line ("· 6 lookups, 2 changes"); again folds it |
| `ga` (conversation) | Ask the agent why it did the step under the cursor (one of its tool calls, `✎ create_branch (...)`) or wrote that line |
| `gr` (conversation) | Draft the answer under the cursor as a reply to the thread its question was about (or a PR comment), queued for `gS` |
| `gp` | Run a saved prompt |
| `gH` | What the agent changed; `u` on a line undoes it |
| `gd` | The agent's code change (a fix or a story), file by file like the reviewer |
| `gh` | Open an earlier conversation |
| `gn` | Start a new conversation (the current one stays in `gh`) |
| `gM` / `gm` | Choose the agent / the model |
| `<C-c>` | Stop the agent's answer - its session stays for your next message (what you queued is held until you send it) |
| `<` / `>` | Make the panel smaller / bigger (kept for the session, in every tab - so is a size you drag it to or set with `<C-w>`) |
| `<BS>` | Back to the screen next to the panel |
| `q` | Hide the panel, in every tab (`i` on a screen brings it back) |
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

**Sending while it works.** A message you send while the agent is still
answering is queued: it shows under the conversation as `You · queued (1 of
2)` (and `[⌛ 2 queued]` in the title bar), with what you were looking at
when you sent it. When the answer is done, the queued messages go out in
order, each as a turn of its own. On a queued message, `dd` cancels it and
`cc` puts it back in the input box to change; sending it again keeps its
place. Stopping the agent with `<C-c>` holds the queue: nothing more goes
out until you press `<CR>` on a queued message. This is the same in a plan's
agent's conversation and its popup.

**The status strip.** One line says what needs you, from any tab: the
agent working (`⠹ Copilot 42s`), a question waiting for your yes or no
(`⚠ a question waits for you` - a push, a vote), and the plans waiting for
your review (`● plan #3002 waits for you`). The standalone launcher shows
it at the right end of its tab line; in your own Neovim,
`require("azure-cli.chat").strip()` returns it for a statusline (lualine:
`{ function() return require("azure-cli.chat").strip() end }`), or use
azure-vicli's tab line: `vim.o.tabline =
"%!v:lua.require'azure-cli.ui'.tabline()"`.

Once a turn is done, more than three tool calls fold into one line (`· 6
lookups, 2 changes`) - the ones that failed, were declined or were
allowed without asking stay on their own lines - and an answer longer
than 40 lines shows its first 30 and `… N more lines`. `<Tab>` on the
turn unfolds it.

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

**Saved prompts.** `/triage`, `/review`, `/reviewers`, `/explain`, `/build`, `/plan` and `/standup`
come built in; type one in the input box (anything after it is added to
the prompt, e.g. `/review focus on error handling`) or pick one with `gp`.
`/triage` only sorts a PR's open threads (fix, push back, question,
already done) and says why - it drafts no replies; ask for those after.
`/reviewers` looks at who knows the changed code (git log and blame, and
CODEOWNERS) and opens `gR`'s popup with them first, each with why; nobody
is added until you pick them.
They run against what's on screen like any message. (`/skills` isn't a
prompt: it opens a popup of the agent's skills, without asking the agent -
see [Permissions](#github-copilot-cli).) Add your own, replace
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
press `<CR>`: the panel opens and the next message carries the selected text
and, in a diff, which file lines it covers. The winbar shows
`[selection: N lines]` until it's sent. Without a selection, a message from
a diff carries the change (the run of added/removed lines) around the cursor.

## Conversations, agents and models

The agent stays running for the whole conversation: the first message
starts it, and every later one goes to the same process, which already
knows everything said so far - no new process, no waiting for it to start.

Conversations are saved (under Neovim's data directory, the last 50): the
one in the panel is still there after a restart, `gn` starts a new one, and
`gh` brings back an earlier one.

With several agents configured (`chat.agents`, below), `gM` switches
between them. `gm` picks the model for the conversation you're in (the
main chat, or the agent of the plan you're looking at) - see
`planner_model` / `implementer_model` below for a model per stage.
Switching agent or model, going back to an older conversation with `gh`,
or a restart starts a new process, and your next message replays the
conversation to it - except that an ACP agent (Copilot) switches model
within its session.

**Proactive.** When the dashboard sees new comments on one of your PRs, a
note appears in the conversation suggesting `/triage` (no agent runs;
`suggest_on_new_comments = false` turns it off). With `daily_summary =
true`, the first time the dashboard loads each day the chat runs `/standup`
in a fresh conversation and tells you when it's ready.

**The chat's own PRs are watched.** A pull request the chat opened
(`create_pull_request`) or pushed a fix to (`commit_and_push_fix`) is
checked for new comments every `chat.watch_seconds` (default 120) while
azure-vicli runs - the PR dashboard doesn't have to be open. Only other
people's comments count, and ones arriving close together are taken
together: once a poll finds no newer ones, `chat.on_new_comments` says what
happens - `"suggest"` (default) puts a note in the chat (and a desktop
notification), `"plan"` has an agent plan the fix of just those
threads, as `gP` does - the agent that opened the PR, when it was one of
them; its plan waits for you on the Agents screen, and
nothing changes until you approve it. A PR stops being watched once it's
completed or abandoned, and the agents behind it show as finished on the
Agents screen. Comments that arrived while azure-vicli was closed
are picked up at the first check after it starts. The list is kept in
`stdpath("data")/azure-cli-chat/watched.json`.

## Setting it up

The panel's placement, and the agent it talks to, go in `setup()` (or the
standalone launcher's `azure-cli.lua`). The agent has to be a CLI that can
stay running across many messages - azure-vicli doesn't start one per
message. Two kinds work:

- **`acp = true`**: a CLI with an [Agent Client
  Protocol](https://agentclientprotocol.com) mode - GitHub Copilot CLI's
  `copilot --acp`.
- **Anything else**: a CLI reading one JSON request per message on stdin and
  streaming JSON events back, without exiting in between - Claude Code's
  `-p --input-format stream-json --output-format stream-json`.

A plain one-shot CLI (`copilot -p "..."`, answering once and exiting)
doesn't work: its first answer arrives, then the chat reports that it
exited.

### GitHub Copilot CLI

```lua
require("azure-cli").setup({
  chat = {
    position = "right",     -- "right" (default), "left", "bottom" or "top"
    size = 0.35,            -- a fraction of the screen, or a number of columns/lines
    input_height = 3,       -- lines in the input box
    agent = {
      label = "Copilot",
      acp = true,
      models = { "claude-sonnet-5", "gpt-5.5" },   -- examples: use the names your `copilot --help` lists
      cmd = { "copilot", "--acp", "--add-dir", "{fix_root}", "--allow-tool", "azure-vicli" },
      -- Premium requests per message, by model (your plan's multipliers, see
      -- GitHub's "Copilot premium requests" page); `default` for the rest.
      premium_requests = { default = 1, ["claude-sonnet-5"] = 1, ["gpt-5.5"] = 1 },
      -- Optional: a plan's agent plans on one model and implements on another.
      -- planner_model = "gpt-5.5", implementer_model = "claude-sonnet-5",
    },
  },
})
```

azure-vicli (`chat/acp.lua`) does the ACP handshake (`initialize`,
`session/new`) once, then sends one `session/prompt` per message on that
session, with the answer streamed in through `session/update`. The message
goes in `session/prompt` directly, so `stdin` doesn't apply; the model `gm`
picks goes through `session/set_config_option`.

- **azure-vicli's tools.** Copilot's `--acp` (1.0.92) only takes http/sse
  MCP servers - its `initialize` advertises `mcpCapabilities: {http, sse}`,
  and it rejects a stdio one ("Rejecting non-http/sse MCP server
  "azure-vicli" from client"). So for an agent that advertises `http`,
  azure-vicli starts `azure-cli.py --mcp-http` - the same tools as `--mcp`,
  over HTTP on a random 127.0.0.1 port, with the chat's token required on
  every request - once per Neovim, and passes that in `session/new`. An
  agent that doesn't advertise `http` gets the stdio server.
- **Permissions.** A tool call Copilot wants permission for (editing a file,
  running a command) pops up the same yes/no prompt as azure-vicli's own
  tools, with its diff when it has one - or the exact command it would
  run, since Copilot's title is only its own description of it;
  "Allow"/"Deny" picks Copilot's `allow_once`/`reject_once`. Every shell
  command shows in the chat under its step, with what became of it
  (`↳ $ git status  (allowed: only looks)`, `(you denied it)`), and so in
  the run log (`gH`). Reading and searching files never ask -
  they're always allowed, and so is searching or listing through the
  shell: `grep`, `egrep`, `fgrep`, `findstr`, `rg`, `find`, `fd` (not
  `-x` / `-X`), `ls`, `dir`, `tree`, `cat`, `head`, `tail`, `wc`, `sort`
  (not `-o`), `uniq`, `cut`, `echo`, `printf` (not `-v`), `pwd`, `cd`,
  `stat`, `which` / `where`, `basename` / `dirname` / `realpath`, `file`,
  `diff`, `cmp`, `comm`, `nvim --version`, a `sed` or `awk` that only
  prints (no `-i` or `-f`, no `w` / `e` commands, no `system` or pipes),
  `git log` / `diff` / `show` / `status` / `blame` / `grep` / `ls-files` /
  `ls-tree` / `rev-parse` / `describe` / `shortlog` / `cat-file` /
  `merge-base` / `show-ref`, `git remote [-v]` / `show` / `get-url`,
  `git worktree list` (`--porcelain`, `-v`,
  `-z`), plain `git fetch [-q] [--prune] [remote [branch…]]` (no
  `--upload-pack` or other options, no `x:y` refspecs), `gh run list` /
  `view` / `watch`, `gh pr view` / `checks` / `diff` / `list` /
  `status`, `gh issue view` / `list` / `status` (not with `--web`),
  `gh api graphql` queries (no mutation, `@file`, `--input` or other
  method),
  PowerShell's `Get-ChildItem`, `Get-Item`,
  `Get-Content`, `Select-String`, `Where-Object`, `Test-Path`,
  `Resolve-Path`, `Get-Location`, `Select-Object`, `Sort-Object`,
  `Measure-Object`, `Format-Table` / `Format-List`, `Out-String` and
  `Out-Null`, and pipes
  of them, throwing errors away or not (`2>$null`, `2>/dev/null`,
  `2>&1`), and `for` / `while read` loops of them (`while read l; do
  grep -n "$l" src; done < file`). **Skills you allow** don't ask
  either: while an answer uses one of the agent's skills (a `SKILL.md`
  in the repository's `.github/skills`,
  `.claude/skills`, `.agents/skills` or `.copilot/skills`, or yours in your
  home folder) - your message names it (`/triage-pr-comments`, "use the
  triage-pr-comments skill") or the agent reports loading it - its
  prompts get a third button, **Allow all of skill …** (`a`), and once you
  pick it every command and file edit the skill makes is accepted, now and
  next time; each still shows in the chat as `(allowed: skill …)`.
  `/skills` in the chat opens a popup of the skills found (each one's
  description, folder, and ✓ when allowed) without asking the agent:
  `<Space>` allows the skill under the cursor up front, or makes its
  prompts ask again, and `<CR>` starts your message with it
  (`/name `) in the input box. With none found, the chat says where it
  looked.
  `chat.skill_dirs` changes where they're looked for: the default is
  `{ ".github/skills", ".claude/skills", ".agents/skills", ".copilot/skills" }`;
  a relative folder is looked for in the repository and in your home
  folder, `~/…` or an absolute path as it is. To stop the prompts
  altogether, see `chat.permissions`' groups ([below](#what-the-agent-can-do)).
  azure-vicli's own questions - posting, voting, pushing - still ask. A
  command that could
  write or run something else - a redirect, a `$(...)` that writes or runs
  something (one whose commands only look is allowed), a script block,
  `find -exec`, `rg --pre`, any other program - still asks. While a
  `/plan` message runs, editing, deleting or moving a file is refused
  without asking (a plan changes no code). Once you've approved the plan, changing a file it lists under
  Files, inside its change's worktree, doesn't ask either. A file the plan
  doesn't list asks, saying so and giving the agent's reason (the last
  thing it wrote before asking); allow it once and it's part of the plan
  from then on - later edits to it don't ask, and `show_fix`'s check
  against the plan counts it as planned. Building and testing the way an approved
  plan's Test plan says doesn't ask either: `run_tests` with that
  command, or the agent running it (or one of its lines) in its own
  shell - with more arguments too (`dotnet test --no-build --filter …`),
  after a `cd` / `Set-Location` into a directory, with the same tool's
  build and restore steps (`dotnet build`, `npm ci`, `cargo check`, …),
  and piped into a command that only looks (`2>&1 | Select-Object -Last
  50`). A redirect into a file, `$(...)` or any other program asks. `--allow-tool azure-vicli` saves Copilot
  asking before each of azure-vicli's tools - the ones that change
  something visible still ask you on azure-vicli's side.
- **`--add-dir {fix_root}`** is for "fix this comment" and "implement this
  work item": the agent edits files in a worktree under `{fix_root}`, never
  in your checkout. Leave it out if you don't want the agent changing code.
- **Stopping** a message (`<C-c>`, a [timeout](#fields)) first asks Copilot
  to stop the turn (`session/cancel`), and only stops the process if that
  doesn't work within 5s - so the session normally survives it. (Claude
  Code's turns are interrupted the same way: see [Timeouts](#fields).)

Check `--add-dir` and `--allow-tool` against your `copilot --help`; if
Copilot rejects a flag, the error shows in the chat.

### Claude Code

```lua
agent = {
  label = "Claude",
  models = { "sonnet", "opus", "haiku" },   -- gm picks one; the first is the default
  cmd = { "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
          "--model", "{model}", "--mcp-config", "{mcp_config}", "--add-dir", "{fix_root}",
          "--allowedTools", "mcp__azure-vicli,Read,Grep,Glob",
          "--permission-prompt-tool", "mcp__azure-vicli__permission" },
},
```

- Each message goes to its stdin as one line of Claude Code's stream-json
  "user message" (the default `stdin`), and its events stream into the
  panel as they're written.
- **Permissions.** Claude Code can't show a prompt in a headless run, so
  `--permission-prompt-tool mcp__azure-vicli__permission` hands every
  request `--allowedTools` doesn't cover to azure-vicli, which answers it
  exactly as it answers Copilot's (see [GitHub Copilot
  CLI](#github-copilot-cli) above): searching and listing through the shell
  doesn't ask, nor do an approved plan's tests and allowed skills; an edit
  outside the plan's files, and any other command, pops up the yes/no
  prompt with the command or the diff; while `/plan` runs, editing is
  refused. Without that flag a tool `--allowedTools` doesn't list is
  refused silently - the agent says it was denied, and you never see why.
- **Its questions.** When Claude Code asks you something (its
  `AskUserQuestion` tool), each question pops up as itself rather than as
  Allow/Deny: its header as the title, the question, and its options with
  their descriptions. `1`-`9` (or `<CR>` on one) picks an option; with
  `multiSelect` they're tick boxes - `1`-`9`, `<Space>` or `<CR>` tick
  them, and **Done** answers. **Other…** opens the comment editor for an
  answer in your own words (`q` there goes back to the question). Several
  questions come one after another. Your answer goes back as the tool's
  `updatedInput.answers` (each question's text → the label picked, several
  joined with ", ", or your own words), so the agent carries on with it;
  `<Esc>` or **Cancel**, on any of them, declines them all - the agent is
  told you declined to answer. No setting ever answers one for you, and
  like every other question it waits while another is open. (Over ACP
  there's no way to send an answer back, so there it stays Allow/Deny.)
- `--allowedTools "mcp__azure-vicli,Read,Grep,Glob"`: azure-vicli's tools
  and reading never ask. Leave `Edit`/`Write` and `Bash` out of it - listed
  there, they'd skip azure-vicli's checks (the plan's Files, a plan that
  changes no code).
- `--add-dir {fix_root}` is for the fix and story flows, as above.

### Fields

**Several agents.** Instead of `agent`, give `agents = { claude = {...},
copilot = {...} }` and optionally `default_agent = "claude"`; `gM` switches.

| `chat.agent` field | Meaning |
|---|---|
| `cmd` | The command (a list, or a string run through `'shell'` with every value shell-escaped; `acp` needs a list). |
| `acp` | The process speaks the Agent Client Protocol (`copilot --acp`). |
| `premium_requests` | For an agent billed per message (Copilot): what one message counts as, by model name, with `default` for any other (missing: 1). Each message adds that up, shown where costs are. |
| `stdin` | What each message writes to its stdin, as one line (default: Claude Code's stream-json user message, `{"type":"user","message":{"role":"user","content":[{"type":"text","text":{message_json}}]}}`). Unused with `acp`. |
| `models` / `model` | The models `gm` offers (strings, or `{ label, value }`) and the default. Reaches the agent through `{model}` (`acp`: `session/set_config_option`). |
| `planner_model` / `implementer_model` | A plan's own agent (`gP`, `/plan`, `start_agents`) plans on `planner_model`, and once you approve its plan, implements on `implementer_model`; the main chat stays on `model`. Either missing: that stage uses `model`. An ACP agent switches in its session; another starts again on the new model and gets the conversation. `gm` picks a model for the conversation you're in only, over all of these. |
| `label` | The agent's name in the panel. |
| `strip` | Lua patterns: output lines matching any are dropped (a CLI's own log of its tool calls). Unused with `acp`. |
| `env` | Extra environment. |
| `idle_timeout_seconds` | How long the agent may go quiet in a message before it's stopped (default 600). Everything it sends - a chunk of its answer, a tool call, a permission request - starts the count again, and it doesn't run while one of azure-vicli's tools works (`run_tests`, a push) or a popup waits for you. `timeout_seconds`, its old name, still works. |
| `max_turn_seconds` | How long one message may take in all, however busy the agent is (default 7200), less the time popups waited for you. |
| `interrupt_grace_seconds` | How long a stopped message may take to end once the agent is asked to stop it, before its process is killed (default 5). |

**Timeouts.** When either one fires, the message is stopped as `<C-c>`
would, its status says which and how long - `timed out (idle 10m)`,
`timed out (cap 2h)`, also on the Agents screen - and a line under it
names the setting:
`✗ timed out: no output from the agent for 10m (idle_timeout_seconds = 600)`.
Claude Code sends nothing while its own shell runs a command, so keep the
idle timeout above your longest build.

**Stopping keeps the session.** A stopped message (`<C-c>` in the chat or
on the Agents screen, or a timeout) only stops that turn: Claude Code is
sent a stream-json interrupt (`control_request`), Copilot a
`session/cancel`. The process, its session and the worktree it was in stay,
and your next message continues it - `· interrupted`. If the turn hasn't ended
`interrupt_grace_seconds` later (or you press `<C-c>` again meanwhile), the
process is killed instead: the status says so - `timed out (idle 10m,
killed)`, `stopped (killed)` - and so does a line under it, and your next
message starts the agent again and replays the conversation to it. An
agent with its own `stdin` template is a CLI that may not understand the
interrupt, so it's stopped by killing it straight away.

`followup`, `session_pattern` and `persistent` are gone: they were for
starting a process per message and resuming a session each time. A config
that still has them gets an error saying so.

Placeholders: `{message}` (your message, with the view description, the
references and, on the first message, the instructions), `{message_json}`
(the same as a JSON string - quoted and escaped), `{text}` (just what you
typed, prompts expanded), `{view}` (the view description), `{mcp_config}`
(the MCP config file - `acp` passes the server in `session/new` instead),
`{fix_root}` (where fix and story worktrees live), `{model}`.

The process is stopped (and the next message starts a new one, with the
conversation replayed) on `gM`, a model change (`gm`, or a plan's agent
moving from `planner_model` to `implementer_model` - an ACP agent switches
in its session instead), `gh`, a new chat, and quitting Neovim - it's tied
to one conversation with one agent and model.

The rest of `chat`: `position`, `size`, `input_height`, `agent` / `agents` /
`default_agent`, `prompts` (above), `permissions` (below), `daily_summary`
(default false), `skill_dirs` ([above](#github-copilot-cli)), `suggest_on_new_comments` (default true), `on_new_comments`
(`"suggest"` or `"plan"`) and `watch_seconds` ([above](#conversations-agents-and-models)), `plan_first`
(default true), `plan_template` and `plan_revisions` (default 3) ([below](#plans-and-asking-why)), `test_cmd` ([below](#plans-and-asking-why)), `toasts`, `max_agents` (default 3,
[below](#several-agents-at-once)).

The agent runs in the local clone of the PR you're looking at, when there is
one, so a repository's own agent instructions and skills apply. A skill
checked into the repository works from the chat too: "use the
triage-pr-comments skill on this PR".

### Let the agent set itself up

You can hand this section to the agent itself (Copilot, Claude Code, ...)
and it can do the setup for you: open the agent in this repository and tell
it **"follow the agent setup steps in docs/chat.md"**. For the rest of the
config (accounts, keys, permissions, skills) there's a skill an agent picks
up on its own - ask it to "configure azure-vicli" (see
[Configuration](configuration.md)).

**Agent setup steps.** You are configuring yourself as azure-vicli's chat
agent. Do every step, check every flag against the installed CLI instead of
guessing, and finish by telling the user what you wrote and anything you
couldn't confirm.

1. **Find how your CLI stays running across many messages** (`<your-cli>
   --help`, plus your docs) for this installed version. azure-vicli keeps
   one process for the whole conversation, so you need one of:
   - an Agent Client Protocol server mode (`--acp` or similar - check for
     it explicitly). Then the config is `acp = true` and `cmd` is just that
     command (GitHub Copilot: `copilot --acp`);
   - a mode reading one JSON request per line on stdin and streaming JSON
     events back without exiting between them (Claude Code: `-p
     --input-format stream-json --output-format stream-json --verbose`).
     If its request format isn't Claude Code's, set `stdin` to it, with
     `{message_json}` where the message goes.

   If it has neither, say so and stop - a one-shot CLI doesn't work.
2. **Find the rest of its flags:**
   - (not for `acp`, which gets the server in `session/new`) adding an MCP
     server config from a JSON file. azure-vicli writes `{"mcpServers":
     {"azure-vicli": {"command", "args", "env"}}}` and passes its path as
     `{mcp_config}` (Claude Code: `--mcp-config {mcp_config}`);
   - allowing every tool of the MCP server named `azure-vicli` without
     prompting (Claude Code: `--allowedTools mcp__azure-vicli`; Copilot:
     `--allow-tool azure-vicli`). Never allow shell tools for this.
     azure-vicli asks the user itself before pushes, votes and other
     visible changes;
   - choosing a model, and the valid model names (`acp` agents get it over
     ACP - no flag needed);
   - for "fix this comment": letting it edit files in an extra directory,
     `{fix_root}` (Claude Code: `--add-dir {fix_root}` and
     `--permission-prompt-tool mcp__azure-vicli__permission`; Copilot:
     `--add-dir {fix_root}`) - only if the user wants the agent changing
     code.
3. **Find where the user's options live.** If their Neovim config calls
   `require("azure-cli").setup({...})`, edit that call. Otherwise it's the
   standalone launcher's `azure-cli.lua` next to `azure-cli.yml`:
   `%APPDATA%\azure-cli.lua` on Windows, `~/.config/azure-cli.lua`
   elsewhere. Create it with `return { ... }` if it doesn't exist. Keep
   everything already there, but remove `followup`, `session_pattern` and
   `persistent` from an existing agent - they're gone.
4. **Write the `chat` block** (the fields are in the table above), shaped like
   the examples in this file: `chat = { agent = { label, acp, models, cmd } }`.
   Use `{model}` where the model flag goes (not for `acp`), and list the
   model names from step 2 in `models`.
5. **Tell the user** to restart azure-vicli (or re-run `setup()`), press `i`
   on the PR dashboard and ask "what am I looking at?", then something
   else. The first answer should name the PR under the cursor, which shows
   the azure-vicli tools work; the second should come back without the
   startup wait, which shows the process stayed running.

## Plans, and asking why

Before the agent changes any code - fixing a comment (`start_fix`) or
implementing a work item (`start_story`) - it writes a plan, and waits for
you to approve it. Those two tools refuse until there is an approved plan
for that PR or work item. You can also ask for a plan any time: `/plan` -
in the main chat that starts an agent for it (see
[below](#the-main-chat-coordinates)), in an agent's own chat it asks that agent.

![The agent's plan: sections on the left, the plan with questions answered under its lines, the chat on the right](images/chat-plan.png)

A plan never opens by itself: when the agent submits it you're told it's
ready (a notification, and the Agents screen marks it), and `<CR>` on its
row there opens it - as an inner tab of Agents, laid out like the reviewer: its
sections on the left (with a count of the files it touches, and of the
questions you asked in each), the plan on the right as rendered markdown,
the chat alongside. It follows a template: Goal, Approach, Files, Risks,
Test plan, Open questions (`chat.plan_template` replaces it).

Under the sections, the keys that matter for the plan as it is now: approve
and ask for changes while it waits for you, the code a step became and the
run log once it's approved. The change viewer's file list ends the same way
(sending is offered while changes are queued, the tests when there's a test
command), and so does the Agents screen (approve, while a plan waits). `?`
always has all of them.

**Ask why.** Put the cursor on any line of the plan - or select a few -
and press `ga`: an empty editor opens under the line - type your question
and send it with `<C-s>`.
The question goes to the agent through the chat, with the line and its
section, and the answer appears under that line, like a review thread
(also in the chat). `<Tab>` unfolds a long answer, `K` shows it in a
popup, `]t` / `[t` go from question to question. The same `ga` works in
the change viewer (`show_fix`, `gd`) on any line of the agent's change,
with `]C` / `[C` between the questions there.

![A question answered under a line of the agent's change](images/chat-ask-why.png)

**Changes to the agent's change.** In the change viewer, `c` on a line
(or a selection) queues what should change there - drawn under the line,
like a comment in the reviewer's batch queue - and `gS` sends everything
queued in one message ("please change these: auth.py line 13 ..."), with a
note of your own. `dd` forgets one. The agent fixes them in the worktree,
and the change viewer, if it's still open, redraws with the new change in
place.

**Running the plan's tests.** The plan's Test plan section gives the
command that checks the change, in a ` ```sh ` block - or, when the
agent wrote none, the inline code there that starts with a test runner or
build tool (`` `dotnet test` ``, `` `npm test` ``; `submit_plan` tells the
agent when it found no command at all). `gb` in the change
viewer runs it in the change's worktree - after asking, since the agent
wrote it - and the file list's winbar shows the result (`✓ tests passed`,
`✗ tests failed (exit 1)`, or `..., before the last change` once the
change moved on); a failed run opens its output, and `gb` later offers
the last output again. The agent can run them too (`run_tests`, which
asks you the same way), and `commit_and_push_fix`'s question shows how
the tests last went on exactly that change.

Your own test command wins over the agent's: `chat.test_cmd` is one
command for every repository, or one per repository - `test_cmd = {
widgets = ".venv/bin/python -m pytest -q", api = "dotnet test" }`. It runs
in the worktree like the plan's, but without the question (it's yours),
for `gb` and for the agent's `run_tests` alike.

**Letting an approved plan push and open its PR.** `gA` offers two ways
to approve: just approve, or approve *and let it push and open the PR
once the tests pass*. With the second, the agent is told so and carries
on by itself: it makes the change (`show_fix` tells you it's ready),
runs the plan's tests
with `run_tests` (tests it runs in its own shell don't count), fixes the
change until they pass, pushes, and - for a work item - opens its pull
request, a normal one, linking the work item with the plan as its
description. Neither the push nor the PR asks you - the chat says they
were allowed by the plan - as long as the plan is still approved (a new
revision takes it back), the tests passed on exactly the change being
pushed (when the plan has a test command), and the PR is that plan's one
PR, from its story's branch into the branch it started from. Anything
else asks as usual, and the question says why it asks after all ("Asking
because the tests ran on an earlier version of the change").
`chat.permissions = { commit_and_push_fix = "ask" }` (or
`create_pull_request`) always asks.

**Hunk by hunk.** `gy` on a change marks it accepted (a `✓` beside it,
and `✓ 2/5 accepted` in the winbar - press it again to take that back);
`gn` takes that one change out of the worktree (after asking - the
agent's other changes stay), and a note in the chat says what you took
out.

Questions are kept: they're
still there next time you open the plan or the change, and they move with
their line when the text around them changes.

| Key (plan window) | Action |
|---|---|
| `gA` | Approve the plan - the agent is told to go ahead (optionally: and may push and open the PR once the tests pass) |
| `gc` | Queue a change on this line (in visual mode: these lines) - shown under it, sent by `gR` |
| `gR` | Ask for changes or send your answers: what you write, plus every change queued with `gc` and your unsent answers; the agent submits a new revision |
| `gr` | Answer the open question under the cursor (its Open questions section) - `gR` sends your answers, and approving does too |
| `dd` | Drop the change queued under this line (asks first), or forget the question there; a change already sent stays |
| `cc` | Edit the change queued under this line |
| `gD` | Discard this plan and everything its agent left, as `dd` on the Agents screen: the question (Discard / Cancel, Discard first) appears at once, refused while its agent works; the files are deleted and the plan's tab closes, then its worktree and local branch are deleted in the background |
| `gi` | A bar beside the lines this revision changed against the one before (on by default; toggles); on an older revision: back to the current one, marked against that one |
| `gh` | Open an older revision, read-only (on one: back to the current one) |
| `gp` | Its pull request in the reviewer - the one its agent opened, or the one it fixes (looked up on the server when the dashboard doesn't list it); `gp` there comes back to the plan |
| `ga` | Ask about this line (in visual mode: these lines) |
| `<Tab>` / `K` | Unfold the answer under this line / show it in a popup |
| `]t` / `[t` | Next / previous question |
| `gd` | The code this line became (in the change viewer; `gp` there comes back) |
| `gH` | The run log: everything that happened to the plan and its change, as one page |
| `gf` | Edit the plan's file yourself; saving it makes your version the one the agent gets (and it needs approving again) |
| `<CR>` (section list) | Go to the section; moving through the list scrolls the plan (a file under Changes: its diff in the plan pane) |
| `<BS>` | Back to the section list |
| `r` / `i` / `<` `>` / `q` / `?` | Reload / type in the chat / resize / close / keys |

**The change against the plan.** When the agent shows its change
(`show_fix`, `gd`), the change viewer compares it with the plan's Files
section: a changed file the plan doesn't list is marked `✗ not in the plan`,
and the files the plan lists but the change didn't touch are listed under
the changed ones ("In the plan, not changed"); the winbar counts both (`[1 off plan]`, `[2 untouched]`). The
agent gets the same list back from `show_fix`, so it can explain or fix it.
Only the approved revision's Files count, and a file you let the agent
change on top of it counts until the next revision. In a Files entry, every
path before its description is a file (`a.lua, b.lua - ...`); code words
like `M.open(host)`, `B.words` or `#3001` aren't, and a bare or partial
name (`state_dialog.lua`, `chat/agents_view.lua`) matches the changed path
that ends in it. The same files decide when an edit asks because it
isn't in the plan.

**The change inside the plan.** Once the agent has changed files, the
section list ends with `Changes (N files)` and each file under it (`A
b.lua  +3 −0`, `D` for a deleted one, `✗ not in the plan` as above).
Moving onto a file - or `<CR>` on it - shows its diff in the plan pane,
drawn as the change viewer draws it; a plan section puts the plan back,
and `<BS>` goes to the list. On a diff line `ga` asks about it and `gc`
queues a change to the code (both kept with the change viewer's, so `gd`
shows them too); `dd` / `cc` drop or edit one, `]c` / `[c` go from
change to change, and `gR` there sends the queued code changes - the
winbar says `gR sends N code changes`, it isn't a plan revision. The
section follows the agent's edits; after it pushes it shows the pushed
commit (`Changes (2 files, pushed abc1234)`), and it's gone while nothing
changed.

**Asking for changes, line by line.** `gc` on a line (or a selection)
queues what should change there; it shows under the line (`✎ use a
decorator here`), like a review comment waiting in the batch queue. `gR`
then sends them all in one message - with a note of your own - and the
agent answers with a new revision. Until then a queued change can be
taken back: `dd` on its line drops it (after asking) and `cc` edits it,
and the `[✎N queued]` in the winbar follows. Sent ones stay under their
lines, marked as sent, as history - `dd` and `cc` leave them alone.

**Answering its questions.** The agent puts what it needs you to decide
under Open questions. `gr` on one of them opens an editor for your answer,
which shows under the question (`↪ you: no, admins too`); the winbar
and the Open questions row in the section list count the ones still open
(`[1 to answer]`). A lead-in that isn't about questions - a `###` heading,
a bold line or one ending in `:`, like "Follow-ups, out of scope:" - ends
them, so the follow-ups under it don't count. Once you've answered, the
winbar says `[2 answers unsent]` and the section list `2 answers unsent -
gR sends them`: `gR` with no changes queued opens ready to send just your
answers ("See my answers to your questions.", `+2 answers` in its title),
and the agent revises the plan with them. Asking for changes or approving
sends them too, each with its question, so the agent goes ahead knowing
them; sent answers say so under their question. A board agent's plan
sends all of this to that agent's own conversation.

**What changed since the last revision.** When the agent sends a new
revision (or you save your own), the lines it changed get a bar beside
them and the section list marks the sections that changed (`±`); the
winbar says which revision it compares with. The text it took out isn't
shown - `gh` opens the revision before. `gi` turns the marks off and on.

**Older revisions.** `gh` lists the plan's revisions, newest first, with
who wrote each and when (`rev 3 (approved) · by the agent · 10-14 16:39`);
picking an older one shows it in the plan pane, read-only - the winbar
says `rev 3 of 5 · read-only`, with the questions it had under its lines
(as they were when the next revision replaced it); the keys that write
stay with the current one, and `gh` again (or `r`, or a new revision)
goes back. `gi` there goes back too, marking what the current revision
changed since that one rather than since the one before. A plan keeps
its last `chat.plan_revisions` (3) revisions, and always the one last
approved and the one its pull request was opened from - with 5 revisions
and the 2nd approved, it keeps 2, 4 and 5. So once its agent plans fixes
to that PR, the original plan is still a `gh` away. They keep their
numbers. A plan with more from before is cut down the next time it's
saved.

**From the plan to the code and back.** `gd` on a plan line opens the
code it became: the agent ties the parts of its change to the plan lines
they carry out when it shows the change (`show_fix`'s `steps`), and a
Files entry always opens its file. Those lines are marked in both places
(`→ auth.py:13` in the plan, `◂ plan:7` in the change), and `gp` on a line
of the change goes to the plan line it belongs to (the nearest step above
it, else the file's Files entry).

**The run log.** `gH` in the plan opens one page with everything that
happened to it: a timeline of its revisions (the agent's and yours), your
questions and change requests, the approval, the test runs, the hunks you
took out, the agent's tool calls for that PR or work item, and the push;
then every question with its answer, the last test output, and the plan
as it is now. It's a markdown file next to the plan (`<key>.log.md`),
written fresh each time - handy to attach to the PR, or to read later.

**The pull request's description.** When the agent opens the pull
request (`create_pull_request`) without writing a description, it gets
the approved plan's - its Goal, Approach, Risks and Test plan, and a line
saying which plan revision it came from - so reviewers see the reasoning.
With a description of its own and `from_plan`, the plan's sections follow
it. The plan is found through the work items the PR links, or the story
branch it's opened from; the question before it opens shows the
description.

Pushing the change (`commit_and_push_fix`) marks its plan done, so the next
change on that PR or work item needs a plan of its own. A plan the agent
revises needs approving again.

`chat.plan_first` sets the gate: `true` (default) for both fixes and
stories, `"stories"` only for work items (comment fixes go straight
ahead), `false` for neither (`/plan` still works).

Plans live under Neovim's data directory, `azure-cli-chat/plans/<wi-3001 |
pr-101>.md` (the text `gf` edits) and `.json` (status, the revisions
kept, questions).

## Several agents at once

`gP` on the work-items board hands the work item under the cursor - or,
in visual mode, every one in the selected rows - to an agent of its own,
which writes that item's plan in a conversation of its own while you
carry on. At most `chat.max_agents` (default 3) work at the same time
(only plan agents count, not the main chat); the rest wait and start
as the others finish. No agent pulls you into its plan or its change
when it's done - neither opens by itself, from the main chat or from an
agent's own: you're told it's ready, the status strip counts the plans
waiting for you, and `<CR>` (the plan) or `gd` (the change) on the
Agents screen opens it. A plan or change viewer you already have open is
redrawn in place when the agent submits a new revision, runs the tests
or changes the code, without taking the focus.

### The main chat coordinates

The main chat (`i` anywhere outside a plan) hands planning and code
changes to agents rather than doing them itself:

- **`/plan`** there starts an agent - for the work item or PR on screen (on a
  review thread: that thread), or for the ones you name: `/plan #3001 #3002`,
  `/plan !101`. Anything else you write after `/plan` goes to each agent with
  its first message (`/plan #3001 keep the change small`).
- **Ask it in plain words** - "plan #3001 and #3002", "fix the comments on
  !101", "what are the agents doing?", "tell #3001 to use the existing
  cache". It has three tools for that: `start_agents`, `list_agents` and
  `message_agent` (the message shows in that agent's own chat, as coming
  from the main chat, and it answers there; while that agent is mid-turn the
  message is queued, like one you type there, and goes when the turn ends).
  A message about a PR an agent opened for its work item goes to that
  agent, as `gP` does.
  `start_agents` takes `board` like the other work-item tools, and each
  agent reads its item from that board; without it, the board a list showed
  the item on, else the one you're looking at.
- It's a lock, not a default: `submit_plan`, `start_story` and `start_fix`
  refuse the main chat's calls and tell it to `start_agents` instead, even
  when you ask it to do the work itself. To work hands-on, talk to the
  agent in its own conversation (`<CR>` on its row on the Agents screen).
- **A plan with no agent** - one the main chat wrote before this, or whose
  conversation was pruned - gets an idle agent conversation of its own when
  the plans are restored, so the Agents screen lists it. Approve it (`gA`)
  to hand it to that agent, or discard it: `dd` on its row, `gD` in the
  plan itself (both ask first, and delete it), or ask the main chat to
  `discard_plan` it (its files move to `plans/discarded/`).
- **Approving stays yours** - `gA` on the Agents screen or in the plan's
  tab. The main chat can't approve a plan, and an agent can't start or
  message other agents.

**Desktop notifications.** While Neovim isn't the focused window, a
toast tells you when something waits for you: a plan from a background
agent is ready, its change is ready, a question waits for your yes or no,
or a plan's agent answered. `chat.toasts = "always"` sends them even
while you're looking, `false` never (the terminal has to report focus for
the default - tmux needs `set -g focus-events on`; `:AzureCli toasts` and
`AZVICLI_TOASTS=0` turn every toast off).

**After a restart** each plan's conversation comes back - in its plan's
tabs and on the Agents screen - though its agent isn't running any more:
the next message starts it again and replays the conversation to it.

**Questions, one at a time.** A yes/no question from a plan's agent says
whose it is - `[#3001] The agent wants to commit "..." and push it` - and
when two agents ask at once, the second waits until you've answered the
first, so an answer never goes to a question you didn't read. The status
strip counts what's going on: `⠹ 2 agents working · ⌛ 1 queued · ⚠ a
question waits for you · ● 2 plans wait for you`.

![The Agents screen: its agents grouped - needs you, working, in progress, finished](images/chat-agents.png)

**The Agents screen** (`A` on either dashboard, `A` in the chat's conversation,
`:AzureCli agents`) lists every plan's agent, grouped by what needs you
first - Needs you, Working, In progress, Finished - with the most recent
first in each group (finished ones over 7 days old are hidden until `gF`).
For each it shows what it's doing (working, with its latest step; waiting
for an agent; its plan waiting for you; changes asked, not revised yet;
approved; pushed; `PR !123 open` once it opened one; finished - `merged`
or `PR abandoned` - once that PR is closed, which it learns from the
[watched PRs](#conversations-agents-and-models) check; failed or timed
out; idle). A timed-out agent is always under Needs you; a failed one is
there only when its plan isn't already approved or pushed. It also shows how long since it
last did something, and what it has used so far, centred in its window, and the winbar adds it up: its cost when the
agent reports one (Claude Code does, and an ACP agent can, through ACP's
`usage_update`), else its premium requests (`agent.premium_requests`:
each message counts as its model's multiplier). An ACP agent's
`usage_update` also says how full its context is (`ctx 27%`, before the
latest step). The chat's winbar shows the same for the conversation in it
(`[2 req · ctx 25%]`). The screen's keys:

| Key (Agents screen) | Action |
|---|---|
| `<CR>` | The row's agent: its plan, as an inner tab of Agents (`]r` / `[r` / `g1`..`g9` switch, `q` goes back; already open: back to it as you left it), with that agent's conversation in the chat; before it has planned, its conversation in a popup (watch it, or `i` to talk to it), the panel keeping the main chat |
| `gd` | Its change, file by file |
| `gA` | Approve its plan (in visual mode: every selected row's) - one question for all, each approval goes to that plan's own agent |
| `gH` | Its run log |
| `gp` | Its pull request in the reviewer - the one it opened, or the one it fixes (`gp` there comes back to its plan) |
| `<C-c>` | Stop what it's doing |
| `dd` | Discard its plan, any plan (an agent's too), and everything the agent left on this machine. It asks at once - **Discard** or **Cancel**, Discard first - listing what goes and what stays; it refuses while the agent is working (`<C-c>` first). Discard deletes the plan's files and its conversation's, the row goes, and a queued agent for it is taken off the queue; then, in the background, its worktree is deleted (forced: uncommitted and unpushed changes go with it) along with the local branch it was on, and a toast says what went. The branch on the server is never touched. It can't be undone. The main chat's `discard_plan` still only discards a plan no agent worked on |
| `gF` | Show (or hide again) the agents finished over 7 days ago |
| `i` | The main chat (its input box), whatever row you're on |
| `gg` / `G` | First / last row (with a count, that row) |
| `P` / `W` / `I` | The Pull requests / Work items / Issues tab |
| `r` / `q` / `?` | Redraw / close / keys |

**For review comments, too.** `gP` in the reviewer, on a comment
thread, starts an agent that plans the fix of that comment (anywhere
else in the reviewer: of every active one); on the PR dashboard, `gP` on
a row - or on selected rows - starts one agent per PR, each planning the
fix of its open comments. They run side by side like the work items'
(one agent per PR, since a PR's fix happens in one worktree), and the
plan gate applies the same way: no change until you approve. A PR an
agent opened for a work item goes back to that agent instead - the one
that wrote the original plan and knows the change: it plans the fix as a
new revision of that plan (on the Agents screen it's the work item's row
again, waiting for you), and once you approve, it changes its story's
worktree and pushes to the PR's branch. However it comes to plan a fix
to that PR - `gP`, or the main chat passing your question on - its plan
is a new revision of the work item's, never a plan of the PR's own that
no agent's row would show; `gh` in it opens the original. On the PR dashboard, the agent
column shows each PR's agent and what it's doing, and `ga` there opens
its conversation in a popup ([dashboard](dashboard.md)). `gp` on that row,
or anywhere in the PR's reviewer, opens the agent's plan; `gp` in the plan,
or on its Agents row, goes back to its PR.

Every plan you open gets an inner tab of its own under Agents, and so does
every change - opening another doesn't replace the one you were reading,
and `r`, `gA` or `ga` in one always act on that tab's plan or change.

Each plan's tabs (its plan window, its change viewer) show that plan's
agent in the chat panel - its winbar names it (`Chat · Claude · #3001`) -
so asking why, approving or asking for changes there goes to the agent
that wrote the plan; everywhere else the panel is your main conversation.

### Phone dashboard

To watch the agents from a phone, `:AzureCli web start` serves a
read-only web page of the Agents screen from this machine: each row as the
screen shows it (#id, title, status, age, cost, the current step), "Needs
you" first, and the totals line. It updates itself every few seconds -
also while Neovim is unfocused or idle, when the network polls slow down
(`timing.idle_after`, [Configuration](configuration.md)) - fits a phone's
width, and follows its light or dark mode. It shows no plan
text, code, diffs or tokens, and has no buttons - approving and the rest
stay in Neovim.

It's off until you turn it on, and listens only where you say:

```lua
require("azure-cli").setup({
  dashboard_web = { enabled = true, bind = "100.101.102.103" },  -- this machine's Tailscale (or LAN) address
})
```

`start` shows the URL, token included, in a float - open it on the phone
(`status` shows it again). The link serves the page itself, with no
redirect, so it works whether you tap it in another app or paste it. The
page keeps the token in memory, takes it out of the address bar
(`history.replaceState`), and sends it with each update in an
`X-Azvicli-Token` header, never in a URL. The same response sets an
HttpOnly, SameSite=Lax cookie, only so that a reload works. A request
without the token gets 401, and so does one with a wrong header, even if
its cookie is good. `:AzureCli web stop` stops it (so does leaving Neovim).

The token is kept across restarts, so a bookmarked link keeps working:
it's stored in `stdpath("state")/azure-cli/web-token` (e.g.
`~/.local/state/nvim/azure-cli/web-token`), a file created with mode
`0600` - never chmod-ed after the fact - and replaced in one step. The
server reads or makes that file itself: only its path is on the server's
command line, never the token (so `ps` doesn't show it), and the token is
in no log - not `:AzureCli log`, not the `AZVICLI_DEBUG` perf log. If the
file is missing, unreadable or malformed, the next start makes a new
token. If it's a symlink, someone else's, or readable by other users (say
`0644`), it isn't trusted: the start makes a new token, writes a fresh
`0600` file and warns you to send the new URL (on Windows the
permission check is skipped). `dashboard_web.persist_token = false` keeps
the token in memory only, new every start, as before.

`:AzureCli web rotate` makes a new token. While the dashboard runs, the old
link, open pages and their cookies get 401 at once; the new token is
saved, and the float shows the new URL. While it's stopped, rotate deletes
the stored token, so the next `start` makes a new URL. `status` says
whether a token is stored.

Two Neovims share the one file: both serve the same token (with a fixed
`port` only the first can listen; with `port = 0` both do). Rotating in
one swaps its own server's token at once, but the other Neovim's running
server keeps the old token until it restarts. `bind` defaults to `127.0.0.1` (this machine
only), `port` to `8797`; `0.0.0.0` and `::` (every interface) are refused.
The page is plain HTTP, so prefer a VPN such as Tailscale - which encrypts
the traffic - over an open Wi-Fi. The server is `azure-cli.py
--web-dashboard`, a process of its own: GET only, no CORS, a strict
Content-Security-Policy, and no request log.

## What the agent can do

The agent gets an MCP server named `azure-vicli` with these tools:

| Tool | What it does | Asks you first? |
|---|---|---|
| `start_agents`, `list_agents`, `message_agent` | The main chat only: starts an agent per work item (on `board`) or for a PR's review comments; lists the agents and what each is doing; passes a message on to one | - |
| `submit_plan`, `get_plan` | Hands you its plan for a PR or work item - you're told it's ready, nothing opens (a new call is a new revision); reads the plan as it is now (your edits included), its status and your questions. `submit_plan` (like `start_fix` and `start_story`) is a plan agent's only: the main chat's call is refused | - |
| `discard_plan` | The main chat only: discards a plan no agent has worked on (one the main chat wrote itself); its files move to `plans/discarded/` | yes |
| `current_view` | What you're looking at when you sent the message (see above) | - |
| `list_pull_requests`, `get_pull_request` | Your dashboard's PRs; one PR's details - any PR in the project by id, not only your dashboard's (after it, the other PR tools work for that PR too) | - |
| `find_implementations`, `find_definition` | Across a whole repository (the fix/story worktree, a PR's source branch, or a local clone): the types implementing an interface or deriving from a class, and the ones deriving from those; where a type or member is declared. Text-based (`git grep` and declaration patterns for C#, Java, TypeScript, Kotlin, Python, ...), no build needed | - |
| `get_pr_threads`, `get_pr_diff` | A PR's comment threads (fresh) and its diff | - |
| `find_people` | People by name, account, email or login: with a PR, who can review it (no query: everyone on its project's teams, or the repository's assignable people); without, who the board's directory finds, to assign | - |
| `get_build_log` | Why a PR's build failed: the failed steps, their errors, the end of their logs | - |
| `get_test_results` | The tests that failed in a PR's build: each one's name, error message and stack trace | - |
| `list_work_items`, `get_work_item`, `list_sprints` | Your sprint's items (each with its iteration: the path on Azure; on GitHub the name, and `iteration_id` for `move_to_sprint`); one item in full; the team's sprints. These and the other work-item tools also work on GitHub issues (see [Issues on GitHub](#issues-on-github)) | - |
| `open_in_ui` | Shows you a PR in the reviewer (at a file and line) or a work item | - |
| `annotate_code`, `clear_annotations` | Notes on lines of a PR's diff, shown under them in the reviewer (only to you) and kept across restarts until cleared; a note whose line has changed since (a later push) says "may have moved" | - |
| `link_pr_to_work_item` | Links a PR and a work item | no (**yes** on GitHub, where it edits the PR's description) |
| `create_branch` | Creates a branch from another one's tip on the server, links it to a work item (its Development section), optionally checks it out in your clone | no |
| `draft_reply`, `draft_comment` | Drafts a reply or a new comment (line, file or PR). **Not posted**: it goes into that PR's [batch-review](reviewer.md) queue, and `gS` in the reviewer sends it. A reply can carry the status its thread gets once it's sent (`bydesign` for a false positive it explains); `s` in `gQ` changes it | no |
| `create_child_task`, `move_to_sprint` | A task under a work item; a work item into a sprint | no |
| `create_work_item` | A new top-level work item (title, body, type, sprint), assigned to you | **yes** |
| `requeue_build` | Queues the PR's build again | no |
| `start_fix`, `show_fix`, `discard_fix` | A worktree of the PR's branch to change code in; the change so far (you're told it's ready; `gd` on the Agents screen opens it like the reviewer - changed files on the left, `]c`/`[c` through the changes - and an open one is redrawn in place); throwing it away | no |
| `start_story` | Implementing a work item: a new branch on the server (linked to it) and a worktree of it to change code in (before its plan is approved, only a read-only worktree of the branch, to plan in). `show_fix` / `discard_fix` / `commit_and_push_fix` then take the work item's id | no |
| `run_tests` | Runs the plan's test command (or another) in the fix/story worktree; returns the exit code and the end of the output | **yes**, showing the command |
| `delete_fix_file` | Deletes a file in the fix/story worktree (the agent's own file tools can't delete); any path outside the worktree is refused, so it needs no shell permission | no |
| `commit_and_push_fix` | Commits the change and pushes it to the PR's (or the story's) branch | **yes**, showing the diff |
| `set_thread_status` | Resolves (or reopens, ...) a comment thread | **yes** |
| `add_reviewer`, `update_pr_description` | A reviewer by name or email; the description, and the title when one is given | **yes** (the description, and any new title, is shown) |
| `suggest_reviewers` | Opens `gR`'s popup with the people it suggests first, each with why; you pick who's added | - |
| `remove_reviewer` | Takes a reviewer off a PR (on GitHub, only a review request still waiting). Undoable: the undo adds them back | **yes** |
| `create_pull_request`, `complete_pull_request` | Opens a PR (linking work items; its description from the approved plan unless it writes one); merges one | **yes** |
| `vote` | Votes on a PR | **yes** |
| `set_work_item_state`, `assign_work_item`, `comment_on_work_item` | A work item's state, assignee, discussion | **yes** (the comment is shown) |
| `edit_work_item` | A work item's title, priority, tags, description and (Azure) hours: original estimate, remaining and completed work. Undoable, except the description | **yes**, showing the new values |
| `set_work_item_parent` | Moves a work item under another parent, or off its own (`"none"`) - on GitHub, makes the issue a sub-issue of the parent. Undoable: the undo puts the old parent back | **yes** |

When a tool asks, a popup comes up in the middle of the screen ("The agent
wants to vote "Approve" on PR #101."), with the diff or text it would send
in a window above it (`<C-d>` / `<C-u>` and `<C-e>` / `<C-y>` scroll it),
and two buttons: **Allow** and **Deny**. It can come up while you're typing
something else, so Deny is the one focused, and for the first moment keys
don't count - the buttons light up once they do; then `y` / `n`, or
`<Tab>` (or `h` / `j` / `k` / `l`, or the arrows) and `<CR>`. `o` opens the
whole request in a window of its own, where `q` comes back and the popup
keeps asking. `<Esc>` or leaving it is Deny; `q` does nothing here, since
it may be a stray key. A deny is reported back to the agent,
which carries on without it. Approving a plan (`gA`) asks the same way:
Approve, Approve and let it push, or Cancel. `ui.confirm = "select"`
([Configuration](configuration.md)) asks through `vim.ui.select` instead,
for a picker plugin to draw.

**Your own rules.** `chat.permissions` overrides any tool: `"allow"` (no
question), `"ask"`, or `"deny"` (the agent doesn't even see it):

```lua
permissions = { create_branch = "ask", commit_and_push_fix = "deny", set_thread_status = "allow" },
```

It also takes groups, so you don't have to name every tool:

| Key | Covers |
|---|---|
| `"azure-vicli-tools"` | azure-vicli's own tools (posting, voting, pushing, opening PRs, ...) |
| `"agent-commands"` | the agent's own prompts other than file edits: shell commands, fetching, ... |
| `"agent-edits"` | the agent's own file edits |
| `"all"` | everything above that its own group doesn't set |

A tool's own name wins over its group, and a group wins over `"all"`. So
`permissions = { all = "allow" }` is an autopilot where nothing asks, and
`{ all = "allow", vote = "ask", ["agent-edits"] = "ask" }` is the same but
still asks before a vote or a file edit. A group's `"ask"` leaves reads
alone; for the agent's prompts, `"ask"` is the usual behaviour (searches,
the plan's tests, planned edits and allowed skills still don't ask).
`"allow"` / `"deny"` there show in the chat as `(allowed: chat.permissions)`
/ `(refused: chat.permissions)`. Plans still wait for your approval, and
planning still changes no files.

**Undo.** Every change the agent makes is logged; `gH` lists them (newest
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
3. It edits the files there with its own tools, then calls `show_fix`,
   which tells you the change is ready - it doesn't open it (the plan's
   Changes section shows its diff). `gd` on the Agents screen opens the
   change as an inner tab, laid out like the reviewer: the changed files
   on the left (moving through them previews each), the file's diff on the
   right with the reviewer's keys - `]c` / `[c` jump between changes and on
   into the next file, `<BS>` goes back to the files, `gf` opens the file in
   the worktree to edit it yourself, `<` / `>` resize, `q` closes. The chat
   comes along into that tab: `i` goes to it (`<CR>` in visual mode, with
   the selected lines), and it knows the file and line you're on. While
   it's open, the agent's next `show_fix` or `run_tests` redraws it in
   place, without taking the focus; `r` refreshes it by hand, staying on
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
   asking again for the same work item picks up where it left off. When the
   branch already exists on origin (e.g. `from` = `name`), no branch is
   made: the change is pushed straight to it, and no PR is offered. While
   planning (before you approve), `start_story` only makes a read-only
   worktree of that branch, detached, with nothing created on the server:
   the agent reads the code it plans for there, and the same directory
   becomes the story's worktree once you approve.
3. It edits files there, then `show_fix` tells you the change is ready
   (`gd` on the Agents screen opens it).
4. `commit_and_push_fix` asks, with the diff, then pushes to the branch.
5. It offers `create_pull_request` (which asks too), linking the work item.

The repository has to be cloned locally: `<clones_dir>/<repo>`, as for
reviews. `u` in `gH` deletes the branch again as long as nothing was pushed
to it.

**The agent has to be allowed to edit there.** The agent's CLI runs
headless, so it asks you through azure-vicli: Copilot over ACP, Claude Code
through `--permission-prompt-tool mcp__azure-vicli__permission` (see
[Claude Code](#claude-code)). Without that flag, anything Claude Code wasn't
allowed up front is refused, and the agent stops with something like
"permission denied and could not request permission from user". Either
still needs `--add-dir {fix_root}` to reach that directory.

### Issues on GitHub

With a GitHub account's `issues:` block (the [Issues tab](work-items.md#issues-github)),
the same board tools work on its project. Each takes `board` (`azure` or
`github`) and, on GitHub, `repo` (`owner/repo`) when the project spans
several repositories and the number alone is ambiguous. Without `board`,
a tool uses the board you're looking at: `i` on the Issues tab or an
issue's view, a `gP` agent started for an issue, a `#12` only the Issues
tab lists, or the only board your config has. Otherwise it's Azure's.

- `set_work_item_state` takes a Status option, or `Closed` with reason
  `completed` or `not planned`. `create_child_task` makes a sub-issue in its
  parent's iteration; `create_work_item` a new issue in the default
  repository.
- `start_story` and `create_branch` make the branch with GitHub's linked
  branches, so it shows in the issue's Development section.
- `create_pull_request` into a GitHub repository adds a `Closes #12` line
  for each issue in `work_item_ids`.
- `link_pr_to_work_item` adds `Closes #12` to the PR's description, which
  is GitHub's only way to link an existing PR, and asks first there because
  merging that PR into the default branch closes the issue. `u` in `gH`
  removes the line again.

GitHub only honours `Closes` on a PR into the repository's default branch;
for any other, the tool's answer says the line won't link it yet.

## How it works

```
Neovim (chat panel) --stdin/ACP--> agent CLI --MCP--> azure-cli.py --mcp / --mcp-http
       ^                                                          |
       '--------------- 127.0.0.1 bridge (JSON + token) <---------'
```

The agent runs headless, one process for the whole conversation.
`{mcp_config}` (or, for `acp`, `session/new`'s `mcpServers`) points it at
`azure-cli.py --mcp` (or `--mcp-http`), a small relay that answers MCP and forwards
every `tools/list` and `tools/call` to a bridge the panel opens on
127.0.0.1. The bridge checks a random per-session token, which only the
relay knows from its environment. The tools themselves run inside Neovim
(`lua/azure-cli/chat/tools.lua`), through the same provider calls, caches
and batch queue the rest of azure-vicli uses. That's how the agent sees
exactly what you see.
