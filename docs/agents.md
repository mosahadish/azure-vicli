# Agent actions

_Part of the [azure-vicli](../README.md) docs._

An agent action runs a command of your choice against a pull request in the
background. The command can be Claude Code, the GitHub Copilot CLI, codex,
or any script. When it finishes, its answer appears inside the plugin: a
badge on the dashboard row, a result page in the reviewer, and, if the agent
asks for it, suggested replies and comments anchored to the threads and
lines they're about. Accepting a suggestion turns it into a draft in the
[batch review](reviewer.md) queue. Nothing reaches Azure DevOps until you
submit that queue with `gS`.

azure-vicli ships **no actions of its own**. You add them in `setup()`; the
examples below are starting points.

- [Quick start](#quick-start)
- [Where results show up](#where-results-show-up)
- [Defining an action](#defining-an-action)
- [Placeholders and environment](#placeholders-and-environment)
- [The context bundle](#the-context-bundle)
- [Output and suggestions](#output-and-suggestions)
- [Talking to the agent](#talking-to-the-agent)
- [Examples](#examples)
- [Workspaces](#workspaces)
- [Windows notes](#windows-notes)

## Quick start

```lua
require("azure-cli").setup({
  agent_actions = {
    triage = {
      label = "Triage review comments",
      description = "suggest how to handle every open thread",
      when = "author",                         -- only on my own PRs
      cmd = { "claude", "-p", "--output-format", "json",
              "--allowedTools", "Read,Grep,Glob" },
      stdin = "Use the triage-pr-comments skill. The pull request is described in {context_dir}/README.md.",
      -- R on the Agent page continues this same Claude session:
      followup = { cmd = { "claude", "-p", "--output-format", "json", "--resume", "{session_id}",
                           "--allowedTools", "Read,Grep,Glob" },
                   stdin = "{message}" },
    },
  },
})
```

(Standalone launcher users put the same `agent_actions` table in
`azure-cli.lua` - see [setup() options](configuration.md#setup-options).)

Press `gX` on a PR in the dashboard or anywhere in the reviewer, pick
"Triage review comments", and keep working. A toast and a flash tell you
when it's done.

## Where results show up

| Where | What |
|---|---|
| PR dashboard row | `◐` while an action runs, `✦` when there's a result you haven't looked at. |
| Dashboard `gz` | The result in a large float (choose one when there are several). `<CR>` there opens the PR on the reviewer's Agent page. |
| Reviewer `gz` | The **Agent page**, in the diff pane like the Overview: the agent's markdown, then its suggestions. `<CR>` goes to the thread or line a suggestion is about, `ga` drafts it, `]a`/`[a` step through suggestions, `R` asks the agent a [follow-up](#talking-to-the-agent), `gz` picks an older result, `gX` runs another action. |
| Reviewer diff pane and Overview | Each suggestion as virtual lines under its thread or line, e.g. `✦ Triage · fix (ga drafts the reply)`. `ga` on that line drafts it, `]a`/`[a` jump between them. |
| Winbars | `[agent: running]` / `[agent: new result · gz]`. |

`gX` also lists a running action as "Cancel …", and offers "Show results"
once a PR has some.

**Drafting** (`ga`) turns batch review on for the PR and opens the usual
comment editor, prefilled: a reply for a thread suggestion, or a new
line/file/PR comment. Edit it, then submit with `<C-s>`. The comment is
queued, not sent. `gQ` lists the queue and `gS` posts it, optionally with a
vote. A drafted suggestion is marked `✓ drafted`.

Results are kept under Neovim's data directory
(`stdpath("data")/azure-cli-agent/<pr>/`), the last 10 per PR, together with
the context bundle each run was given, so they survive a restart.

## Defining an action

`agent_actions` maps an action name to a table:

| Field | Required | Meaning |
|---|---|---|
| `cmd` | yes | What to run. A **list** (`{ "claude", "-p", "{prompt}" }`) runs directly, with each element [expanded](#placeholders-and-environment) on its own; `{prompt}` as a whole element passes the prompt as one argument however many lines it has. A **string** runs through your `'shell'`, with every substituted value shell-escaped. |
| `prompt` | no | A template, expanded first and then available to `cmd`, `stdin` and `env` as `{prompt}`. |
| `stdin` | no | A template written to the command's stdin, which is then closed. Without it, stdin is closed right away, so a CLI that reads a piped prompt never waits. |
| `label` | no | The name shown in menus and on the result (default: the action's key). |
| `description` | no | Shown next to the label in the `gX` menu. |
| `when` | no | `"always"` (default), `"author"` (PRs you created), `"reviewer"` (everyone else's), or `function(info) return bool end` with `info = { pr, is_author, surface, file, line, side, thread_id }`. |
| `workspace` | no | Where the command runs: `"worktree"` (default; see [Workspaces](#workspaces)), `"repo"` (your clone itself, as it is; read-only use only), or `"none"` (the context directory). |
| `timeout_seconds` | no | Killed after this long (default 1800). |
| `env` | no | Extra environment variables; values are templates. |
| `followup` | no | How to continue the agent's own session for a [follow-up question](#talking-to-the-agent): `{ cmd = ..., stdin = ..., prompt = ..., env = ... }`, the same kinds of templates, plus `{message}` (what you typed) and `{session_id}`. Without it, follow-ups replay the conversation instead. |
| `session_pattern` | no | A Lua pattern with one capture that finds the session id in the agent's output (stdout, then stderr), for an agent that prints it instead of returning it in a JSON envelope - e.g. `"session: (%S+)"`. |

An unknown field or a wrong type is an error at `setup()` time.

## Placeholders and environment

`cmd`, `prompt`, `stdin` and `env` values can use:

| Placeholder | Value |
|---|---|
| `{pr_id}` `{title}` `{url}` `{author}` | the pull request |
| `{org}` `{project}` `{repo}` `{source}` `{target}` | where it lives, and its branches |
| `{repo_path}` | your local clone |
| `{workspace}` | the directory the command runs in |
| `{context_dir}` | the [context bundle](#the-context-bundle) for this run |
| `{pr_file}` `{threads_file}` `{diff_file}` `{readme_file}` | its files |
| `{file}` `{line}` `{side}` | the diff-pane cursor's file and line when `gX` was pressed there (empty elsewhere) |
| `{thread_id}` | the thread under the cursor, if any (diff pane or Overview) |
| `{prompt}` | the expanded `prompt` |
| `{message}` `{session_id}` | in a follow-up: what you asked, and the agent's session (see [Talking to the agent](#talking-to-the-agent)) |
| `{conversation_file}` | in a replayed follow-up: the conversation so far, as sent to the agent |
| `{action}` | the action's name |

An unknown `{name}` is left as written. The command also gets
`AZVICLI_AGENT_CONTEXT`, `AZVICLI_AGENT_PR_FILE`, `AZVICLI_AGENT_THREADS_FILE`,
`AZVICLI_AGENT_DIFF_FILE`, `AZVICLI_AGENT_WORKSPACE`, `AZVICLI_AGENT_FILE`,
`AZVICLI_AGENT_LINE`, `AZVICLI_AGENT_SIDE`, `AZVICLI_AGENT_THREAD` and
`AZVICLI_AGENT_SESSION`, plus
the PR's `AZVICLI_PR`/`AZVICLI_ORG`/... variables. Those let a script call
`azure-cli.py` itself, if you choose to give it that power.

## The context bundle

Every run gets a fresh directory with:

- `README.md`: what these files are and the
  [suggestions format](#output-and-suggestions). A prompt can simply point
  the agent at it.
- `pr.json`: id, title, description, url, branches, author, reviewers and
  their votes, build status, merge conflict, commits (newest first), and
  `my_name` (you).
- `threads.json`: every comment thread with `id`, `status`, `file`/`side`/
  `line`/`end_line` when anchored to code (`side` `"R"` is the source branch,
  `"L"` the target), and `comments` (`author`, `date`, `content`). Votes and
  other system comments are left out.
- `diff.patch`: `git diff origin/<target>...origin/<source>`.

The threads are fetched fresh when the action starts, not taken from what's
on screen.

## Output and suggestions

Whatever the command prints to stdout is shown as markdown. If it exits
non-zero, or prints nothing, its stderr is shown too.

To get suggestions you can accept with one key, end the output with a fenced
`json` block:

````markdown
Two of the three open threads need a code change.

```json
{
  "summary": "2 to fix, 1 to push back on",
  "items": [
    { "thread_id": 4711, "verdict": "fix", "note": "Valid - the null check is missing.",
      "reply": "Good catch, fixing it in the next push." },
    { "thread_id": 4712, "verdict": "push back", "note": "Out of scope for this PR.",
      "reply": "Tracking this in #889 instead." },
    { "file": "src/Foo.cs", "line": 42, "comment": "This leaks the stream." },
    { "file": "src/Foo.cs", "comment": "Consider splitting this file." },
    { "comment": "Please add a changelog entry." }
  ]
}
```
````

| Item field | Meaning |
|---|---|
| `thread_id` | a reply to that thread (from `threads.json`); `reply` is the draft |
| `file` + `line` | a new comment on that line of the source branch; `"side": "L"` for the target branch, `end_line` for a range; `comment` is the draft |
| `file` alone | a new comment on the whole file |
| neither | a new comment on the pull request |
| `verdict`, `note` | free text shown with the suggestion; an item with only these is a plain note |

The block is taken out of the markdown that's shown. If there are several
blocks, the last one holding `items` wins. A bare JSON document (just the
object or just the list) works too, and so does Claude Code's
`--output-format json` envelope.

## Talking to the agent

On the Agent page, `R` asks the agent behind the result you're looking at a
follow-up question ("why does thread 4711 need a fix?", "make that reply
less blunt"). Type it in the editor and send it with `<C-s>`. The agent runs
again in the background, in the same workspace with the same context
directory, and its answer is appended to the same page under your question:

```
## You · 14:02
why does thread 4711 need a fix?

## Triage review comments · done · took 12s
(its answer - and any new suggestions, which ga drafts like the first ones)
```

You can keep asking; each answer is another turn on the page, and it's
stored with the result. There are two ways the agent remembers the
conversation:

- **Resume its own session**, when the action has a `followup`. The plugin
  keeps the agent's session id from each answer - from Claude Code's
  `--output-format json` envelope (`session_id`), or through the action's
  `session_pattern` - and runs `followup.cmd` with `{session_id}` and
  `{message}` filled in. The agent continues exactly where it stopped, with
  everything it had already read.
- **Replay**, for any other action (or when no session id was found). The
  action's own `cmd` runs again, with its prompt/stdin followed by the
  conversation so far and your new question. It works with any command,
  but the agent starts fresh each time, so it re-reads what it needs. The
  answer says "replayed the conversation".

The editor's title says which one a question will use.

## Examples

### Claude Code: triage the comments on my PR, with a skill

The action from [Quick start](#quick-start), plus a skill such as this one,
saved as `.claude/skills/triage-pr-comments/SKILL.md` in the repository (or
under `~/.claude/skills/` for every repository):

````markdown
---
name: triage-pr-comments
description: Triage the open review comments on an Azure DevOps pull request prepared by azure-vicli, and suggest how to handle each one.
---

Read README.md, pr.json, threads.json and diff.patch in the context directory
you were given. The current directory is a checkout of the PR's source branch.

For every thread with status "active":
1. Read the code it is anchored to, and the conversation so far.
2. Decide: "fix" (the reviewer is right), "push back" (explain why not),
   "question" (ask for clarification) or "done" (already addressed).
3. Draft a short, friendly reply in the author's voice.

Print a markdown summary grouped by verdict, then the json block described
in README.md, with one item per thread: thread_id, verdict, note, reply.
Do not edit files and do not push.
````

Because the skill lives in the repository, everyone on the team who adds the
same `agent_actions` entry gets the same triage.

### Claude Code: review the PR (or just the line under the cursor)

```lua
review = {
  label = "Review this PR",
  when = "reviewer",
  cmd = { "claude", "-p", "--output-format", "text", "--allowedTools", "Read,Grep,Glob" },
  stdin = [[Review the pull request described in {context_dir}/README.md.
Focus on correctness bugs; skip style nits. {file}:{line} is where I am looking, if that's set.
Report each finding as a "file"/"line"/"comment" item in the json block.]],
},
```

### GitHub Copilot CLI

```lua
explain_thread = {
  label = "Explain this thread (Copilot)",
  when = function(info) return info.thread_id ~= nil end,  -- only on a commented line
  cmd = { "copilot", "-p", "{prompt}" },
  prompt = "Read {context_dir}/README.md. Explain thread {thread_id} in {threads_file} "
    .. "and what change would resolve it. Do not edit files.",
  -- Follow-ups: `copilot --resume <id>` continues a session. Point
  -- session_pattern at wherever your version prints the session id (this
  -- pattern is an example - check your output); with no id found,
  -- follow-ups replay the conversation instead.
  session_pattern = "[Ss]ession[ %-_]?[Ii][Dd]:?%s*([%w%-]+)",
  followup = { cmd = { "copilot", "--resume", "{session_id}", "-p", "{message}" } },
},
```

Check `copilot --help` for the flags your version uses to allow tools in
non-interactive mode.

### codex

```lua
describe = {
  label = "Draft a PR description",
  when = "author",
  cmd = { "codex", "exec", "{prompt}" },
  prompt = "Using {pr_file} and {diff_file}, write a pull request description. "
    .. "Put it in a { \"comment\": ... } item of the json block described in {readme_file}.",
},
```

### Any script

```lua
lint = {
  label = "Lint the changed files",
  workspace = "worktree",
  cmd = "git diff --name-only origin/{target}...HEAD | xargs my-linter --format=markdown",
},
```

## Workspaces

`workspace = "worktree"` (the default) runs the command in a git worktree of
the PR's source branch, created on first use under Neovim's cache directory
(`stdpath("cache")/azure-cli/agent-worktrees/<repo>-<pr>`). Your own
checkout and the clone azure-vicli diffs against are never touched. Each
later run moves the worktree to the branch's current tip. If an earlier run
left local changes there, it is left as it was and the result page says so.
Remove a worktree you no longer need with `git worktree remove <path>` in
the clone.

The PR's repository has to be cloned locally (an account's `clones_dir`
handles that, see [Configuration](configuration.md#configuration)). From the
dashboard, `gX` fetches the branches first, the same way opening the PR does.

The agent runs with your permissions. Use the CLI's own tool restrictions
(`--allowedTools` above) for actions that should only read.

## Windows notes

- A list `cmd` is resolved with `exepath()`, so an npm-installed CLI's
  `.cmd` shim is found by name. Windows runs such a shim through `cmd.exe`,
  which cuts arguments at a newline. Pass multi-line prompts through
  `stdin` rather than as a `{prompt}` argument (`claude -p` reads the prompt
  from stdin).
- A string `cmd` runs through your `'shell'`, which is `cmd.exe` by default.
