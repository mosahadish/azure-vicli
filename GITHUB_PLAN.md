# GitHub as a second host

Goal: an account in `azure-cli.yml` can be a GitHub account. Its PRs show on
the same dashboard, open in the same reviewer, and the chat agent works on
them. Azure accounts keep working exactly as today. Each account picks its
host.

Out of scope for now: GitHub Issues as work items (the work-items screen
stays Azure-only; see Phase 6), renaming the plugin, and pushing to a
fork PR's head branch.

## How it fits today's design

What already works on any host:

- **Diffs, file lists, commits, file content, push:** these are local `git`
  against `origin` (`cache.lua`, `review/nav.lua`, `review/commits.lua`,
  `chat/tools_fix.lua`). They work unchanged as long as the PR's branches are
  under `refs/remotes/origin/*`.
- **URLs:** Lua builds no host URLs. It opens `pr.url`, `pr.buildUrl` and
  `pr.cloneUrl` as the provider gives them.
- **Transport:** `azure-cli.py` is a CLI of flags, also run as a daemon. Lua
  passes the PR's context as `AZVICLI_*` env vars.

What is Azure-shaped:

1. The provider has no host abstraction. URLs, payloads and parsing are
   hard-coded in `AzureDevOpsPullRequestSource`, `PrActions` and
   `WorkItemActions`. Dispatch is if-chains in `cmd_pr_action` and
   `cmd_list`.
2. `--threads` and `--iterations` return **raw ADO JSON**, and six places in
   Lua parse it (`review/init.lua:445`, `chat/tools.lua:157`,
   `chat/watch.lua:49`, `review/since.lua:150`, `chat/tools_pr.lua:100`,
   `review/init.lua:3417`).
3. Fixed vocabularies are hard-coded in Lua:
   - votes 10/5/0/-5/-10 (three option tables, two glyph tables)
   - thread statuses active/fixed/closed/wontfix/bydesign/pending
   - merge strategies squash/noFastForward/rebase/rebaseMerge
   - auto-complete, policies, required reviewers
   - build queue position, requeue, build log, test runs
4. **State is keyed by the bare PR id** (`STATE.batch[id]`, `PR_THREADS_CACHE`,
   chat `pr-101`, the seen-file, and so on; about 35 sites). ADO ids are
   unique per project. GitHub numbers are only unique per repo.
5. Mentions are rewritten to `@<GUID>` (`editor.lua`). "Me" is matched by
   display name (`prs.lua:18`).
6. The `!101` PR sigil is used in about 46 places (`chat/refs.lua` reads `!`
   as a PR and `#` as a work item).

## Approach

**Normalize at the provider, not in Lua.** Add a GitHub backend to the
Python provider that answers the *same* flags with the *same* output
shapes. Where a shape is ADO JSON (threads, iterations), the GitHub backend
emits that shape, which becomes the de facto internal schema. Lua then
learns only two new things:

- `pr.host` (`"azure"` | `"github"`) and `pr.key`, an opaque PR key from
  the provider, used everywhere state is keyed.
- `pr.caps`: what the PR's host can do, driving every menu, enum and
  column that today is a hard-coded Azure table. Each host's table lives
  in Lua (`lua/azure-cli/hosts.lua`); the provider only sends per-repo
  overrides in the record's `caps` (the merge methods a repo allows, say).

This keeps Lua churn to swapping constant tables for capability lookups
plus re-keying. The six thread parsers can collapse into one later. That
cleanup is worth doing, but it isn't needed for GitHub.

### Config

```yaml
accounts:
  - host: github                  # new; default "azure"
    owner: my-org                 # org or user whose PRs to show (optional: all you can see)
    api_url: https://api.github.com   # optional; a GHES URL for Enterprise Server
    pat_file: ~/.config/azure-cli/gh-token   # optional: falls back to `gh auth token`
    clones_dir: ~/src
```

- Add `host` and `owner` to `ACCOUNT_FIELDS` (`config.lua:438`) and to
  `AccountConfig`/`Config.from_dict`/`problems()` in `azure-cli.py`.
- Required fields depend on the host. Azure needs `org_url` and
  `project_name` as today. GitHub needs nothing beyond `host`. The yml
  template and the configure skill get a GitHub example.
- Token order is `pat`, then `pat_file`, then `gh auth token`. Doctor
  checks that it signs in and has the `repo` scope.
- `work_items:` on a GitHub account is an error for now.

### Env contract

Same variables, with GitHub meanings:

| Variable | Meaning on GitHub |
|---|---|
| `AZVICLI_HOST` | `github` (new; absent means azure) |
| `AZVICLI_ORG` | `api_url` |
| `AZVICLI_PROJECT` | the repo owner |
| `AZVICLI_REPO` | the repo name |
| `AZVICLI_PR` | the PR number |

`resolve_account_pat` matches on (host, api_url, owner).

### PR key

- Azure: `pr.key = tostring(id)`, so every persisted key (chat `pr-101`,
  plans, the seen-file) stays valid and nothing needs migrating.
- GitHub: `pr.key = "owner/repo#12"`.
- Lua state switches from `pr.id` to `pr.key`, roughly 35 sites. `pr.id`
  stays the number shown and passed as `AZVICLI_PR`.

### Display ref

A `ref_label(pr)` helper gives `!101` on Azure and `repo#12` on GitHub.
`chat/refs.lua` keeps reading `!` as an Azure PR and also reads
`owner/repo#n`.

### Capabilities (`hosts.lua`, plus `caps` overrides from `--list` / `--get-pr`)

| Cap | Azure | GitHub |
|---|---|---|
| `votes` | 10, 5, 0, -5, -10 with today's labels | approve, request_changes, comment |
| `thread_statuses` | active, fixed, closed, wontfix, bydesign, pending | active, resolved |
| `merge_methods` | squash, noFastForward, rebase, rebaseMerge | squash, merge, rebase (only those the repo allows) |
| `auto_complete` | true | true if the repo allows auto-merge |
| `complete_work_items` | true | false |
| `required_reviewer` | true | false |
| `requeue` / `build_log` | true | true (re-run failed jobs, job logs) |
| `test_results` | true | false |
| `native_review` | false | true |
| `mention` | `guid` | `login` |

Lua reads these in a handful of places:

- `VOTE_OPTIONS` (reviewer, dashboard, gS)
- `STATUS_OPTIONS`
- `merge.lua`
- the dashboard columns
- the agent tools' enums and descriptions, built at `describe()` time in
  `chat/tools.lua:593`
- `editor.lua`'s mention rewrite

A tool whose cap is false is left out of the agent's tool list for that PR.

## GitHub backend (`github_host.py`, beside `azure-cli.py`)

It uses the same injectable `fetch` pattern as `PrActions`, so tests run
on recorded responses. GraphQL is used where it saves calls; REST where it
is simpler.

**`--list`**
- One GraphQL `search` per account and role (`review-requested:@me`,
  `reviewed-by:@me`, `author:@me`, plus `is:pr is:open`, plus
  `org:`/`user:` from `owner`).
- Each node brings `reviewThreads(isResolved)`, `latestReviews`,
  `reviewRequests`, `statusCheckRollup`, `mergeable`, `autoMergeRequest`,
  `isDraft`, `headRepository`, and comment authors.
- The provider computes the same record fields:
  - `state` sections, from my latest review: changes requested by me →
    Waiting, approved → SignedOff
  - `voteRatio` and `reviewerSummary` from reviews
  - `activeThreads`/`closedThreads`/`myActiveThreads`, `mentionThreads`
    (`@login`) and `othersComments`
  - `buildStatus`/`buildUrl` from the check rollup
  - `policies` from the required checks plus `reviewDecision`
  - `missingReviewers` from pending review requests
  - `mergeConflict` from `mergeable == CONFLICTING`
  - `myId`/`myName` from `viewer`
- Rate limits: about 3 queries per account every 30 s, a few hundred
  GraphQL points an hour, well under the 5,000 limit.

**`--get-pr`, `--whoami`**
- These are straight GraphQL reads. "Me" is the login. Reviewer `id` is
  the login, so `@Name` → `@login` falls out of the existing mention code
  once `mention = login`.

**`--threads`** (emits ADO-shaped JSON)

| ADO shape | Comes from |
|---|---|
| Review thread | GraphQL `reviewThreads` |
| `id` | the root comment's `databaseId` (numeric, so Lua's id checks hold) |
| `status` | `isResolved` → `fixed`, else `active` |
| `threadContext.filePath` | `path` |
| `right/leftFileStart/End` | `line`/`startLine` and `diffSide` |
| File-level comment | `subjectType == FILE` |
| Outdated comment | `line == null`: kept as file-level, marked outdated |
| General thread `0` | every issue comment, as one flat conversation, like GitHub's own tab |
| Comment fields `id`, `content`, `author{id=login, displayName}`, `publishedDate` | the comment's `databaseId`, `body`, author, `createdAt` |

**`--iterations`**
- Today the reviewer uses only the count, the newest head SHA and dates.
- Synthesize one iteration per push: the PR's commits in order, plus a
  break at every `HeadRefForcePushedEvent`.
- "Since my last review" becomes more exact on GitHub: emit
  `myLastReviewSha` (my latest review's `commit.oid`). `since.lua` prefers
  it when present, otherwise it keeps today's timestamp rule.

**Writes**

| Flag | GitHub call |
|---|---|
| `--post` / `--file-comment` | `POST /pulls/{n}/comments` (`line`, `side`, `start_line`, `subject_type=file`) |
| `--pr-comment` | `POST /issues/{n}/comments` |
| `--reply <t>` | `POST /pulls/{n}/comments/{t}/replies` (`t` is the root comment id); `t == 0` posts an issue comment |
| `--edit-comment` / `--delete-comment` | PATCH/DELETE on pull or issue comments (thread 0 → issue) |
| `--status <t> active\|resolved` | GraphQL `resolveReviewThread`/`unresolveReviewThread`; the thread node is looked up from the root comment id |
| `--vote approve\|request_changes\|comment` | `POST /pulls/{n}/reviews` with `event` (request changes needs a body: prompt for one); `0`/reset dismisses my review where allowed, otherwise reports it can't |
| `--add-reviewer <login>` | `POST /pulls/{n}/requested_reviewers` |
| `--set-description` | `PATCH /pulls/{n}` |
| `--create-pr` | `POST /pulls` (draft supported; work-item ids ignored) |
| `--complete <method> [del]` | `PUT /pulls/{n}/merge` with `sha` = head (like ADO's `lastMergeSourceCommit` guard), then delete the head ref if asked |
| `--auto-complete on\|off` | GraphQL `enablePullRequestAutoMerge`/`disablePullRequestAutoMerge` |
| `--requeue` | re-run failed jobs of the PR head's failed workflow runs |
| `--build-log` | failed jobs' logs (`/actions/jobs/{id}/logs`), cut to the tail |

**New flag `--submit-review <json>`**
- Used by batch review (gB/gQ/gS); see Phase 3.
- Azure fans it out exactly as `review/batch.lua` does now.
- GitHub uses one pending review in GraphQL: `addPullRequestReview`, then
  `addPullRequestReviewThread` for each new comment and
  `addPullRequestReviewThreadReply` for each reply, then
  `submitPullRequestReview(event)`. The batch lands as one review with one
  notification, and nothing half-posts.

**Clone and prefetch (forks)**
- Fetch `refs/pull/{n}/head` into `refs/remotes/origin/<source>` as well as
  the target branch, so fork PRs diff like any other.
- The chat's push-a-fix is refused on fork PRs (capability
  `push_to_head`) unless the PR allows maintainer edits.

## Fake provider

- `tests/fake-provider.py` gains a GitHub account with one repo and PRs in
  every section, a fork PR, and threads in GitHub's model.
- Records and caps are GitHub-shaped; threads use the same ADO-shaped output
  as the real backend.
- The smoke test then drives both hosts in one dashboard:
  - same PR number in two repos, to prove the `pr.key` re-keying
  - vote menu shows three options
  - `s` offers Active/Resolved
  - merge dialog lists the repo's methods
  - gS sends one `--submit-review`

## Phases (one commit each, tests green after every one)

0. **Groundwork, no behaviour change.**
   - `hosts.lua`: Azure's votes, thread statuses, merge methods and
     mention form, replacing the hard-coded tables (reviewer, dashboard,
     gS, merge dialog, the agent's vote tool).
   - `HOSTS.key`/`HOSTS.ref` helpers (the key is the id on Azure).
   - One `is_open()` rule for threads. This also fixes today's
     inconsistency where `file_thread_count` counts `pending` as closed.
1. **GitHub, read-only.**
   - Config (`host`, `owner`, `api_url` in Lua and Python), token, doctor.
   - `pr.key` everywhere state is keyed, proven by a fake GitHub account
     with the same PR number in two repos (moved here from Phase 0 so the
     re-keying lands together with the test that exercises it).
   - `--list`, `--get-pr`, `--whoami`, `--threads`, `--iterations`.
   - Fork-aware prefetch.
   - The dashboard lists GitHub PRs and the reviewer browses them, with
     threads.
2. **Comments and reviews.** Post, file and PR comments, reply, edit and
   delete, resolve and unresolve, and the review verdicts.
3. **Batch as a native review.** `--submit-review` on both hosts;
   `review/batch.lua` sends one call and reads one result list.
4. **Merge and CI.**
   - Merging (done, #17): `--complete <squash|merge|rebase> [del]` and
     `--auto-complete on <method>|off` on GitHub, into any base (not only
     the default branch). `--get-pr` carries `mergeability` - the merge
     state, the required checks (`isRequired`), what blocks a merge in
     words - read fresh, since the list's goes stale. `gm` shows it,
     refuses `<CR>` while blocked (auto-merge waits it out, except a
     conflict), hides the work-items row, and says auto-merge deletes the
     branch only by the repo's own setting. The agent's
     `complete_pull_request` takes only the repo's methods.
   - The agent's create PR, add reviewer and set description (done, #110:
     `--create-pr`, `--add-reviewer`, `--set-description` on GitHub).
   - Still to do: requeue (re-run failed jobs), build log, test results;
     "update branch" for a PR behind its base, and an admin bypass, if
     wanted.
   - Agent tools built from caps (enums, descriptions, tools that are
     absent).
   - The chat keys conversations and plans by PR key (`pr-<key>`), not
     `pr-<number>`. Until then the dashboard's agent column and `ga` match
     Azure PRs only, since two GitHub #7s would share one agent.
   - Since-my-last-review prefers `myLastReviewSha` (already in GitHub's
     `--iterations`).
5. **Docs.**
   - README, configuration.md (a GitHub account), reviewer.md and
     dashboard.md (what differs per host), the configure skill.
   - A GitHub screenshot.
6. **GitHub Issues and Projects** (wanted, decided 2026-10-13).
   - **Its own Issues tab** (`I`), shown only when a GitHub account has an
     `issues:` block; `W` stays Azure work items. An Azure-only setup never
     sees it.
   - Config on the GitHub account: `issues: { project: <number or title> }`
     (a Projects v2 project). Needs the token's `project` scope
     (`gh auth refresh -s project`). Optional `repo:` (where new issues
     go; defaults to the project's one linked repository, and `create`
     refuses when there are several) and `scope: mine | all` (whose items
     a sprint shows; mine, as on Azure, by default).
   - Built on the work-items screens, with GitHub's words:

     | Work-items screen | GitHub |
     |---|---|
     | Sprint tabs | The project's Iteration field (milestones without one) |
     | State column, `gs` | The project's Status field options; closing an issue (completed / not planned) |
     | Type, priority | Issue type or labels; a Priority field if the project has one |
     | Detail view | Body, comments, sub-issues, linked PRs |
     | Create, assign, comment, move to sprint | New issue (added to the project), assignees, comments, Iteration |
     | Branch / linked PR | A branch linked to the issue; `Closes #n`, the PR's linked issues |

   - A project for azure-vicli itself (Status + Iteration fields, issues for
     the remaining phases) to build and dogfood against.
   - In three stages, each landing on its own:
     1. **Provider** (`github_issues.py`). `--wi-list`/`--wi-detail`/
        `--wi-state`/`--wi-edit` answer from the project when the call
        carries `AZVICLI_WI_HOST=github` (`AZVICLI_WI_ACCOUNT=<owner>` picks
        among GitHub accounts); without it nothing changes for Azure.
        - Same output shapes; records add `repo` and `key` (`owner~repo~n`).
        - Sprints: Iteration field (path = iteration id), else open
          milestones (`milestone/<n>`), else one whole-project tab (`*`).
        - States: the Status options plus `Closed` (completed / not
          planned). A closed issue reads `Closed`, an open one without a
          Status `No Status`. Status "Done" doesn't close the issue: that's
          the project's own workflow.
        - Ids: the issue number; every `<id>` also takes `owner/repo#n`,
          and a number two of the project's issues share is refused.
        - `link-pr`/`unlink-pr`/`create-branch`/`delete-branch`: stage 3
          (done there).
     2. **The `I` tab** (done): the work-items screens with the env above,
        GitHub's words, `key`-based ids and a Markdown body; the fake
        provider gains a GitHub project.
        - `workitems/board.lua` describes a board (filetypes, caches,
          provider calls, words, what it can do); the dashboard and detail
          view take one. `W` keeps `STATE`'s caches; `I` has
          `STATE.ISSUES`. `AZVICLI_WI_HOST=github` rides only in the
          Issues tab's own calls, never in `vim.env`.
        - `--boards` reads the config alone and says whether a GitHub
          account has `issues:`; `I` (and the launcher's Issues tab) exist
          only then. With several such accounts, the first one's.
        - `gl`/`gL`, `gq` and `gP` came to the Issues tab in stage 3.
     3. **The agent's board tools on GitHub** (done): `get_work_item`,
        `list_work_items`, `start_story` (and branches linked to issues),
        `#n` in chat, `Closes #n` from `create_pull_request`.
        - One set of tools for both boards: each takes `board: azure |
          github` (and `repo`, an issue's owner/repo). Left out, the board
          is the view's (the Issues tab, an issue's view, a gP agent's
          issue), else the only board the config has, else Azure's.
        - `create-branch` is GraphQL `createLinkedBranch` (the issue's
          Development section); `delete-branch`, the undo, deletes the
          ref only while its tip is where it was made.
        - Linking: GitHub can link an existing PR to an issue only by a
          closing keyword in its body, so `link-pr` adds `Closes #n` (and
          asks first, from the chat) and `unlink-pr` removes it. GitHub
          honours them only on PRs into the default branch; the answer
          says so for any other.
        - From phase 4: `--create-pr` (a `Closes #n` line per work item)
          and `--work-items` (a PR's `closingIssuesReferences`) on GitHub.
          The rest of phase 4 stays there.
        - The PR dashboard caches a GitHub PR's issues by its key, so the
          two repositories' #7 don't share a badge.
        - Follow-ups: plans are still keyed `wi-<n>` on both boards, so an
          Azure #n and a GitHub #n share one (with #38, a plan on a named
          branch); #31, AskUserQuestion shown as raw JSON.

Rough size: Phase 0 touches about 15 Lua files with mostly mechanical
changes. Phases 1–4 are mostly new Python (about 1,000–1,500 lines with
tests), plus small Lua branches where caps say no.

## Decisions (confirmed 2026-10-13)

1. **Token:** `pat`, then `pat_file`, then `gh auth token`.
2. **GitHub Enterprise Server:** supported from the start through `api_url`.
3. **General PR comments:** one flat conversation (thread `0`).
4. **Batch on GitHub:** one native review (pending review, then submit).
