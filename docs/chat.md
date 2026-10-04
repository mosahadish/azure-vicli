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

azure-vicli ships no agent configuration; you choose the agent and model
(see [Setting it up](#setting-it-up)).

- [Using it](#using-it)
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
| `i` / `a` (conversation) | Go to the input box |
| `gm` | Choose the model for the next messages |
| `<C-c>` | Stop the agent |
| `gn` | Start a new conversation |
| `<BS>` | Back to the screen next to the panel |
| `q` / `gq` | Hide the panel (`gq` on a screen brings you back to it) |
| `?` | These keys |

Every message is sent together with a description of what you're looking at:
the screen, plus the PR, work item, file, line, code and comment thread under
the cursor in the window you were last in. Your message's heading in the
conversation shows it, e.g. `on PR #101 · auth.py:12 · thread 5000`. Move the
cursor, then ask; "this" always means what's under it now.

While the agent works, its tool calls appear under its heading as they
happen (`· get_pr_threads (pr_id=101)`, `✎ draft_reply (...)`), then its
answer.

Each turn has a coloured bar down its left side: one colour for you, another
for the agent. The agent's markdown is rendered (headings, **bold**, `code`,
lists, with the markers hidden except on the cursor line). Tool calls are dim
for lookups, warning-coloured for changes (`✎`) and error-coloured when
something failed or you declined it (`✗`). The colours are highlight groups
linked to your colorscheme's, so `:hi` can restyle them: `AzureCliChatYou`,
`AzureCliChatAgent`, `AzureCliChatMeta`, `AzureCliChatToolRead`,
`AzureCliChatToolWrite`, `AzureCliChatToolErr`, `AzureCliChatNote`.

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
      cmd = { "claude", "-p", "--output-format", "json", "--model", "{model}",
              "--mcp-config", "{mcp_config}", "--allowedTools", "mcp__azure-vicli" },
      stdin = "{message}",
      followup = {          -- later messages continue the same session
        cmd = { "claude", "-p", "--output-format", "json", "--model", "{model}",
                "--mcp-config", "{mcp_config}", "--allowedTools", "mcp__azure-vicli",
                "--resume", "{session_id}" },
        stdin = "{message}",
      },
    },
  },
})
```

`--allowedTools "mcp__azure-vicli"` lets Claude Code use azure-vicli's tools
without its own prompts (it can't show them in a headless run). Which writes
still ask you is up to azure-vicli, see [below](#what-the-agent-can-do).

| `chat.agent` field | Meaning |
|---|---|
| `cmd` | The command (a list, or a string run through `'shell'` with every value shell-escaped). |
| `stdin` | Written to its stdin, then closed (default `"{message}"`). |
| `followup` | `{ cmd, stdin, env }` for every message after the first. With `{session_id}` in it, it's used once a session id is known; without a `followup`, each message replays the conversation so far instead. |
| `session_pattern` | A Lua pattern with one capture that finds the session id in the agent's output, for an agent that prints it rather than returning Claude Code's JSON. |
| `models` / `model` | The models `gm` offers (strings, or `{ label, value }`) and the default. Reaches the agent through `{model}`. |
| `label` | The agent's name in the panel. |
| `env`, `timeout_seconds` | Extra environment; how long a message may take (default 900). |

Placeholders: `{message}` (your message, with the view description and, on
the first message, a short preamble), `{text}` (just what you typed),
`{view}` (the view description), `{mcp_config}` (the MCP config file),
`{session_id}`, `{model}`.

The agent runs in the local clone of the PR you're looking at, when there is
one, so a repository's own agent instructions and skills apply. A skill
checked into the repository works from the chat too: "use the
triage-pr-comments skill on this PR".

### GitHub Copilot CLI

Recent Copilot CLI versions take an extra MCP config with
`--additional-mcp-config @<file>` and continue a session with
`copilot --resume <id>`. Check `copilot --help` for your version's flags
(including how to allow tools without prompting), and point
`session_pattern` at wherever it prints the session id. This example's
pattern is a guess to adapt:

```lua
agent = {
  label = "Copilot",
  models = { "gpt-5", "claude-sonnet-4.5" },   -- examples: use what `copilot --help` lists
  cmd = { "copilot", "-p", "{message}", "--model", "{model}", "--additional-mcp-config", "@{mcp_config}" },
  session_pattern = "[Ss]ession[ %-_]?[Ii][Dd]:?%s*([%w%-]+)",
  followup = { cmd = { "copilot", "--resume", "{session_id}", "-p", "{message}", "--model", "{model}",
                       "--additional-mcp-config", "@{mcp_config}" } },
},
```

Without a session id it still works; each message replays the conversation.

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
     allowing all tools, and never allow shell or file-writing tools for
     this. azure-vicli asks the user itself before votes and state changes;
   - choosing a model, and the valid model names;
   - whether a non-interactive run reports a session id (stdout, stderr, or
     a JSON field), and how to resume that session (e.g. `--resume <id>`).
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
   `chat = { agent = { label, models, cmd, stdin, followup, session_pattern } }`.
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
| `current_view` | What you're looking at (see above) | - |
| `list_pull_requests`, `get_pull_request` | Your dashboard's PRs; one PR's details | - |
| `get_pr_threads`, `get_pr_diff` | A PR's comment threads (fresh) and its diff | - |
| `list_work_items`, `get_work_item` | Your sprint's items; one item in full | - |
| `link_pr_to_work_item` | Links a PR and a work item | no |
| `create_branch` | Creates a branch from another one's tip on the server, links it to a work item (its Development section), optionally checks it out in your clone | no |
| `draft_reply`, `draft_comment` | Drafts a reply or a new comment (line, file or PR). **Not posted**: it goes into that PR's [batch-review](reviewer.md) queue, and `gS` in the reviewer sends it | no |
| `vote` | Votes on a PR | **yes** |
| `set_work_item_state` | Changes a work item's state | **yes** |

When a tool asks, a prompt pops up in Neovim ("The agent wants to vote
"Approve" on PR #101. Allow?"). "Deny" is reported back to the agent, which
carries on without it.

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
