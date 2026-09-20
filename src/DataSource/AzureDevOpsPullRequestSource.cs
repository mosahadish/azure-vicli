using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.DirectoryServices.AccountManagement;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.TeamFoundation.Build.WebApi;
using Microsoft.TeamFoundation.Policy.WebApi;
using Microsoft.TeamFoundation.SourceControl.WebApi;
using Newtonsoft.Json.Linq;
using Microsoft.VisualStudio.Services.Client;
using Microsoft.VisualStudio.Services.Common;
using Microsoft.VisualStudio.Services.WebApi;
using AzureCli.Configuration;
using AzureCli.View;

namespace AzureCli.DataSource
{
    /// <summary>
    /// An implementation of <see cref="IPullRequestSource"/> which retrieves the active
    /// pull requests for a user, from the Azure DevOps server.
    /// </summary>
    public class AzureDevOpsPullRequestSource : IPullRequestSource
    {
        /// <summary>
        /// The configuration that we should use to connect to the backing store.
        /// </summary>
        private readonly Config m_config;

        /// <summary>
        /// The running statistics of pull requests that we are tracking.
        /// </summary>
        private PullRequestStatistics m_statistics = new PullRequestStatistics();

        /// <summary>
        /// Cache of existing branch ref names ("refs/heads/...") per repository,
        /// populated once per refresh so PRs whose source branch has been deleted
        /// can be filtered out without an API call per pull request. A <c>null</c>
        /// result means the lookup failed and filtering is skipped for that repo.
        /// Entries are lazy tasks so that concurrent PRs of the same repo share a
        /// single refs request instead of each firing their own.
        /// </summary>
        private readonly ConcurrentDictionary<Guid, Lazy<Task<HashSet<string>?>>> m_repoBranches =
            new ConcurrentDictionary<Guid, Lazy<Task<HashSet<string>?>>>();

        /// <summary>
        /// Bounds how many pull requests have their per-request details (comment
        /// threads, build policy status) in flight at once, so a long list is
        /// processed in parallel without flooding the server.
        /// </summary>
        private readonly SemaphoreSlim m_gate = new SemaphoreSlim(MaxConcurrentPullRequests);

        /// <summary>
        /// The upper bound on concurrently processed pull requests.
        /// </summary>
        private const int MaxConcurrentPullRequests = 8;

        /// <summary>
        /// Constructs a new request source.
        /// </summary>
        /// <param name="config">The configuration to driver the system.</param>
        public AzureDevOpsPullRequestSource(Config config)
        {
            m_config = config;
        }

        /// <summary>
        /// Event handler for receiving updates to the pull request statistics.
        /// </summary>
        public event EventHandler<StatisticsUpdateEventArgs>? StatisticsUpdate;

        /// <summary>
        /// Retrieves every relevant pull request (assigned to me, tagged with its
        /// computed state, plus the ones I created) in a single pass.
        /// </summary>
        /// <remarks>
        /// Per organization there is exactly one connection, and per account the
        /// "assigned to me" and "created by me" listings are requested together.
        /// Each pull request's follow-up lookups (comment threads, build policy
        /// status) then run concurrently, bounded by <see cref="m_gate"/>, and
        /// the results are consumed in listing order so the output is stable from
        /// one refresh to the next regardless of which request finishes first.
        /// </remarks>
        /// <returns>An async stream of <see cref="PullRequestViewElement"/></returns>
        public async IAsyncEnumerable<PullRequestViewElement> FetchGroupedPullRequests()
        {
            m_statistics.Reset();
            m_repoBranches.Clear();

            foreach (var accountGroup in m_config.AccountsByUri)
            {
                Uri organizationUri = accountGroup.Key;

                using VssConnection connection = await GetConnectionAsync(organizationUri, accountGroup.Value).ConfigureAwait(false);
                using GitHttpClient client = await connection.GetClientAsync<GitHttpClient>().ConfigureAwait(false);
                using PolicyHttpClient policyClient = await connection.GetClientAsync<PolicyHttpClient>().ConfigureAwait(false);
                using BuildHttpClient buildClient = await connection.GetClientAsync<BuildHttpClient>().ConfigureAwait(false);

                Guid userId = connection.AuthorizedIdentity.Id;
                string userName = connection.AuthorizedIdentity.DisplayName ?? string.Empty;

                foreach (AccountConfig account in accountGroup.Value)
                {
                    // The two listings are independent: issue both at once.
                    //
                    Task<List<GitPullRequest>> assignedTask = ListActivePullRequests(client, account, new GitPullRequestSearchCriteria
                    {
                        ReviewerId = userId,
                        Status = PullRequestStatus.Active,
                        IncludeLinks = false,
                    });
                    Task<List<GitPullRequest>> createdTask = ListActivePullRequests(client, account, new GitPullRequestSearchCriteria
                    {
                        CreatorId = userId,
                        Status = PullRequestStatus.Active,
                        IncludeLinks = false,
                    });
                    await Task.WhenAll(assignedTask, createdTask).ConfigureAwait(false);

                    // Start every PR's detail work now (the gate throttles it),
                    // then drain in listing order: assigned first, created last,
                    // matching the order the dashboard has always received.
                    //
                    var work = new List<Task<(PrState? State, PullRequestViewElement? Element)>>();
                    foreach (GitPullRequest pr in assignedTask.Result)
                    {
                        work.Add(ProcessAssignedPullRequest(client, policyClient, buildClient, pr, userId, userName, account));
                    }

                    foreach (GitPullRequest pr in createdTask.Result)
                    {
                        work.Add(ProcessCreatedPullRequest(client, policyClient, buildClient, pr, userId, userName, account));
                    }

                    foreach (var task in work)
                    {
                        (PrState? state, PullRequestViewElement? element) = await task.ConfigureAwait(false);
                        if (state != PrState.Created)
                        {
                            // Statistics only ever tracked the assigned buckets.
                            //
                            m_statistics.Accumulate(state);
                        }

                        if (element != null)
                        {
                            yield return element;
                        }
                    }
                }
            }

            OnStatisticsUpdate();
        }

        /// <summary>
        /// Lists the active pull requests of a project matching the given criteria.
        /// </summary>
        private static Task<List<GitPullRequest>> ListActivePullRequests(GitHttpClient client, AccountConfig account, GitPullRequestSearchCriteria criteria)
        {
            return client.GetPullRequestsByProjectAsync(account.Project, criteria);
        }

        /// <summary>
        /// Classifies one pull request I'm a reviewer on and, when it is to be
        /// shown, gathers its thread counts and build status - the latter two
        /// concurrently, with the thread list fetched at most once and shared
        /// between classification and counting.
        /// </summary>
        /// <returns>The state and element, or (null, null) when the PR is hidden.</returns>
        private async Task<(PrState? State, PullRequestViewElement? Element)> ProcessAssignedPullRequest(
            GitHttpClient client, PolicyHttpClient policyClient, BuildHttpClient buildClient,
            GitPullRequest pr, Guid userId, string userName, AccountConfig account)
        {
            await m_gate.WaitAsync().ConfigureAwait(false);
            try
            {
                Task<List<GitPullRequestCommentThread>>? threadsTask = null;
                Task<List<GitPullRequestCommentThread>> LoadThreads()
                {
                    return threadsTask ??= client.GetThreadsAsync(pr.Repository.Id, pr.PullRequestId);
                }

                PrState? state = await ComputeState(client, pr, userId, account, LoadThreads).ConfigureAwait(false);
                if (!state.HasValue)
                {
                    return (null, null);
                }

                return (state, await BuildElement(policyClient, buildClient, pr, userId, userName, account, state.Value, LoadThreads()).ConfigureAwait(false));
            }
            finally
            {
                m_gate.Release();
            }
        }

        /// <summary>
        /// Gathers the thread counts and build status of a pull request I created.
        /// </summary>
        private async Task<(PrState? State, PullRequestViewElement? Element)> ProcessCreatedPullRequest(
            GitHttpClient client, PolicyHttpClient policyClient, BuildHttpClient buildClient,
            GitPullRequest pr, Guid userId, string userName, AccountConfig account)
        {
            await m_gate.WaitAsync().ConfigureAwait(false);
            try
            {
                Task<List<GitPullRequestCommentThread>> threads = client.GetThreadsAsync(pr.Repository.Id, pr.PullRequestId);
                return (PrState.Created, await BuildElement(policyClient, buildClient, pr, userId, userName, account, PrState.Created, threads).ConfigureAwait(false));
            }
            finally
            {
                m_gate.Release();
            }
        }

        /// <summary>
        /// Builds the view element for a pull request, awaiting its (already
        /// in-flight) thread list while the build policy status is fetched.
        /// </summary>
        private static async Task<PullRequestViewElement> BuildElement(
            PolicyHttpClient policyClient, BuildHttpClient buildClient, GitPullRequest pr,
            Guid userId, string userName, AccountConfig account, PrState state,
            Task<List<GitPullRequestCommentThread>> threadsTask)
        {
            Task<(string Status, int? QueuePosition, string BuildUrl, List<PolicyInfo> Policies, List<string> MissingReviewers)> buildTask =
                GetBuildStatus(policyClient, buildClient, pr, account);
            (int active, int total, int myActive, int mentionThreads, int mentionTotal) =
                await CountThreads(threadsTask, userId).ConfigureAwait(false);
            (string buildStatus, int? queuePosition, string buildUrl, List<PolicyInfo> policies, List<string> missingReviewers) =
                await buildTask.ConfigureAwait(false);

            return new PullRequestViewElement(pr)
            {
                State = state,
                OrganizationUrl = account.OrganizationUrl?.ToString(),
                Project = account.Project,
                ClonesDirectory = account.ClonesDirectory,
                ActiveThreadCount = active,
                TotalThreadCount = total,
                MyActiveThreadCount = myActive,
                MentionThreadCount = mentionThreads,
                MentionTotalCount = mentionTotal,
                BuildStatus = buildStatus,
                QueuePosition = queuePosition,
                BuildUrl = buildUrl,
                Policies = policies,
                MissingReviewers = missingReviewers,
                CurrentUserId = userId,
                CurrentUserName = userName,
            };
        }

        /// <summary>
        /// Computes the "processed" state of a pull request, or <c>null</c> if it
        /// should not be shown to this user.
        /// </summary>
        /// <param name="loadThreads">
        /// Lazily fetches the PR's comment threads; only invoked when the state
        /// actually depends on them (a "waiting for author" vote), and shared with
        /// the caller so the same request also serves the thread counts.
        /// </param>
        private async Task<PrState?> ComputeState(GitHttpClient client, GitPullRequest pr, Guid userId, AccountConfig accountConfig, Func<Task<List<GitPullRequestCommentThread>>> loadThreads)
        {
            DateTime oneMonthAgo = DateTime.UtcNow - TimeSpan.FromDays(30);

            // Don't show PRs created by ourselves.
            //
            if (Guid.Parse(pr.CreatedBy.Id) == userId)
            {
                return null;
            }

            // Hide PRs whose source branch no longer exists on the server: their
            // diff can't be computed (the branch was deleted after the PR opened).
            //
            if (!await SourceBranchExists(client, pr).ConfigureAwait(false))
            {
                return null;
            }

            if (accountConfig.HideAncientPullRequests.HasValue &&
                accountConfig.HideAncientPullRequests.Value &&
                pr.LatestCommitDate() < oneMonthAgo)
            {
                return null;
            }

            // If the PR is in draft, it's a draft.
            //
            if (pr.IsDraft == true)
            {
                return PrState.Drafts;
            }

            // Try to find our selves in the reviewer list.
            //
            if (!TryGetReviewer(pr, userId, out IdentityRefWithVote reviewer))
            {
                //  Skip this review if we aren't assigned.
                //
                return null;
            }

            // Skip declined reviews.
            //
            if (reviewer.HasDeclined.HasValue && reviewer.HasDeclined.Value)
            {
                return null;
            }

            // If we have already casted a "final" vote, then skip it.
            //
            if (reviewer.HasFinalVoteBeenCast())
            {
                return PrState.SignedOff;
            }

            if (reviewer.IsWaiting())
            {
                // If we are waiting on the PR, inspect the active threads in the PR.
                // If we have left a comment in a thread that is still active, the PR is not actionable to us.
                // If we there are no active threads where we have participated, the PR is actionable to us.
                //
                List<GitPullRequestCommentThread> threads = await loadThreads().ConfigureAwait(false);
                return threads.Any(t => t.Status == CommentThreadStatus.Active && t.InvolvesUser(userId)) ? PrState.Waiting : PrState.Actionable;
            }

            // If these criteria haven't been met, then the PR is actionable.
            //
            return PrState.Actionable;
        }

        /// <summary>
        /// Aggregates the build-validation branch policy results for a pull request
        /// into a single status: "succeeded", "failed", "expired" (stale build that
        /// needs re-queueing), "running", or "none" (no build policy / lookup failed).
        /// Also resolves the queue position of the build backing that status, when it
        /// is still waiting for an agent (i.e. not yet actually running), the web link
        /// to that build, the non-build branch policies (required reviewers, minimum
        /// reviewer count, work item linking, comment requirements, ...), and - for
        /// any "Required reviewers" policy - the display names of required reviewers
        /// who have not yet approved. All of this comes from the single evaluations
        /// request below; no extra API calls are made for it.
        /// </summary>
        private static async Task<(string Status, int? QueuePosition, string BuildUrl, List<PolicyInfo> Policies, List<string> MissingReviewers)> GetBuildStatus(
            PolicyHttpClient policyClient, BuildHttpClient buildClient, GitPullRequest pr, AccountConfig? account)
        {
            List<PolicyInfo> policies = new List<PolicyInfo>();
            List<string> missingReviewers = new List<string>();

            try
            {
                if (policyClient == null || account == null || string.IsNullOrEmpty(account.Project) || pr?.Repository?.ProjectReference == null)
                {
                    return ("none", null, string.Empty, policies, missingReviewers);
                }

                string project = account.Project!;
                Guid projectId = pr.Repository.ProjectReference.Id;
                string artifactId = string.Format(
                    CultureInfo.InvariantCulture,
                    "vstfs:///CodeReview/CodeReviewId/{0}/{1}",
                    projectId,
                    pr.PullRequestId);

                List<PolicyEvaluationRecord> evaluations =
                    await policyClient.GetPolicyEvaluationsAsync(project, artifactId).ConfigureAwait(false);

                bool anyBuild = false;
                bool anyFailed = false;
                bool anyExpired = false;
                bool anyRunning = false;
                bool anyPending = false;
                int? failedBuildId = null;
                int? expiredBuildId = null;
                int? runningBuildId = null;
                int? succeededBuildId = null;
                HashSet<string> missingReviewerNames = new HashSet<string>(StringComparer.Ordinal);
                HashSet<string> unresolvedRequiredReviewerIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                foreach (PolicyEvaluationRecord record in evaluations)
                {
                    if (IsBuildPolicy(record))
                    {
                        anyBuild = true;
                        switch (record.Status)
                        {
                            case PolicyEvaluationStatus.Rejected:
                            case PolicyEvaluationStatus.Broken:
                                anyFailed = true;
                                failedBuildId ??= GetBuildId(record);
                                break;
                            case PolicyEvaluationStatus.Running:
                            case PolicyEvaluationStatus.Queued:
                                // A stale build reports as Queued but carries isExpired in its
                                // context; Azure DevOps surfaces that as a failed required check.
                                if (IsExpiredBuild(record))
                                {
                                    anyExpired = true;
                                    expiredBuildId ??= GetBuildId(record);
                                }
                                else
                                {
                                    anyRunning = true;
                                    runningBuildId ??= GetBuildId(record);
                                }

                                break;
                            case PolicyEvaluationStatus.Approved:
                                succeededBuildId ??= GetBuildId(record);
                                break;
                            default:
                                anyPending = true;
                                break;
                        }

                        continue;
                    }

                    // Everything else is a non-build branch policy: surface it (unless
                    // it doesn't apply to this PR) and, for required reviewers, work
                    // out who on that list still hasn't approved.
                    //
                    AddPolicyInfo(record, policies);
                    CollectMissingReviewers(record, pr, missingReviewerNames, unresolvedRequiredReviewerIds);
                }

                foreach (string name in missingReviewerNames)
                {
                    missingReviewers.Add(name);
                }

                if (unresolvedRequiredReviewerIds.Count > 0)
                {
                    // Required reviewer ids that aren't themselves a reviewer on the PR
                    // are (almost always) groups: we can't resolve a name or tell
                    // whether the group's requirement has been satisfied, so they're
                    // reported as a count instead of silently dropped or guessed at.
                    missingReviewers.Add(string.Format(CultureInfo.InvariantCulture, "{0} more", unresolvedRequiredReviewerIds.Count));
                }

                if (!anyBuild)
                {
                    return ("none", null, string.Empty, policies, missingReviewers);
                }

                string org = (account.OrganizationUrl?.ToString() ?? string.Empty).TrimEnd('/');
                string encodedProject = Uri.EscapeDataString(project);
                string BuildUrlFor(int? id) => id.HasValue && org.Length > 0
                    ? string.Format(CultureInfo.InvariantCulture, "{0}/{1}/_build/results?buildId={2}", org, encodedProject, id.Value)
                    : string.Empty;

                if (anyFailed)
                {
                    return ("failed", null, BuildUrlFor(failedBuildId), policies, missingReviewers);
                }

                if (anyExpired)
                {
                    return ("expired", null, BuildUrlFor(expiredBuildId), policies, missingReviewers);
                }

                if (anyRunning || anyPending)
                {
                    int? queuePosition = runningBuildId.HasValue
                        ? await GetQueuePosition(buildClient, project, runningBuildId.Value).ConfigureAwait(false)
                        : null;
                    return ("running", queuePosition, BuildUrlFor(runningBuildId), policies, missingReviewers);
                }

                return ("succeeded", null, BuildUrlFor(succeededBuildId), policies, missingReviewers);
            }
            catch (Exception)
            {
                return ("none", null, string.Empty, policies, missingReviewers);
            }
        }

        /// <summary>
        /// Adds a non-build policy evaluation to <paramref name="policies"/> as its
        /// type's display name and lowercased status, skipping evaluations that don't
        /// apply to this PR (no status, or "not applicable") or whose policy type
        /// can't be identified.
        /// </summary>
        private static void AddPolicyInfo(PolicyEvaluationRecord record, List<PolicyInfo> policies)
        {
            if (record?.Status == null || record.Status == PolicyEvaluationStatus.NotApplicable)
            {
                return;
            }

            string name = record.Configuration?.Type?.DisplayName ?? string.Empty;
            if (name.Length == 0)
            {
                return;
            }

            policies.Add(new PolicyInfo
            {
                Name = name,
                Status = record.Status.Value.ToString().ToLowerInvariant(),
            });
        }

        /// <summary>
        /// For a "Required reviewers" policy evaluation, resolves each configured
        /// reviewer id against the pull request's reviewer list: a match with a vote
        /// of 5 ("approved with suggestions") or higher counts as done, anything else
        /// is added (by display name) to <paramref name="missingNames"/>. An id with
        /// no matching reviewer on the PR - almost always a group, since groups
        /// aren't listed as individual PR reviewers - can't be resolved to a name or
        /// an approval state, so it's added to <paramref name="unresolvedIds"/>
        /// instead and reported by the caller as a plain count. Never throws: a
        /// missing or malformed configuration degrades to no missing reviewers for
        /// that policy.
        /// </summary>
        private static void CollectMissingReviewers(PolicyEvaluationRecord record, GitPullRequest pr, HashSet<string> missingNames, HashSet<string> unresolvedIds)
        {
            try
            {
                string? typeName = record?.Configuration?.Type?.DisplayName;
                if (!string.Equals(typeName, "Required reviewers", StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                if (record?.Status == null || record.Status == PolicyEvaluationStatus.NotApplicable)
                {
                    return;
                }

                JToken? idsToken = record.Configuration?.Settings?["requiredReviewerIds"];
                if (idsToken == null || idsToken.Type != JTokenType.Array)
                {
                    return;
                }

                foreach (JToken idToken in (JArray)idsToken)
                {
                    string? id = idToken.Value<string>();
                    if (string.IsNullOrEmpty(id))
                    {
                        continue;
                    }

                    IdentityRefWithVote? reviewer = pr.Reviewers?.FirstOrDefault(
                        r => r != null && string.Equals(r.Id, id, StringComparison.OrdinalIgnoreCase));

                    if (reviewer == null)
                    {
                        unresolvedIds.Add(id);
                    }
                    else if (reviewer.Vote < 5)
                    {
                        missingNames.Add(string.IsNullOrEmpty(reviewer.DisplayName) ? id : reviewer.DisplayName);
                    }
                }
            }
            catch (Exception)
            {
                // Degrade to "no missing reviewers reported" for this policy.
            }
        }

        /// <summary>
        /// Extracts the build ID that a build-validation policy evaluation's context
        /// refers to, or null when it isn't present/parseable.
        /// </summary>
        private static int? GetBuildId(PolicyEvaluationRecord record)
        {
            if (record?.Context is JObject context)
            {
                JToken? token = context["buildId"];
                if (token != null && token.Type == JTokenType.Integer)
                {
                    return token.Value<int>();
                }
            }

            return null;
        }

        /// <summary>
        /// Looks up a build's current position in the agent queue. Returns null when the
        /// build has already started running (it no longer has a meaningful queue
        /// position) or the lookup fails.
        /// </summary>
        /// <remarks>
        /// This relies on Azure DevOps reporting the position directly via
        /// <see cref="Build.QueuePosition"/>. That field is reliably populated by
        /// Azure DevOps Services (cloud), but at least some on-premises Azure DevOps
        /// Server/TFS versions leave it null for every queued build (confirmed via
        /// direct REST calls across API versions 2.0-7.1) — in that case this
        /// intentionally returns null (no number shown, just the running/queued
        /// glyph) rather than guessing. A naive "count of earlier-queued builds in
        /// the same agent pool" heuristic was tried and rejected: it can be wildly
        /// off (e.g. counted 26 vs. an actual reported position of 9) because it
        /// can't account for per-build agent demands/capabilities or stale queued
        /// items that the server's own queue view silently discounts.
        /// </remarks>
        private static async Task<int?> GetQueuePosition(BuildHttpClient buildClient, string project, int buildId)
        {
            if (buildClient == null)
            {
                return null;
            }

            try
            {
                Build build = await buildClient.GetBuildAsync(project, buildId).ConfigureAwait(false);
                if (build != null && build.Status == BuildStatus.NotStarted && build.QueuePosition.HasValue)
                {
                    return build.QueuePosition.Value;
                }

                return null;
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>
        /// Returns <c>true</c> when a build-validation evaluation's result has expired
        /// (stale build against an older commit), as reported by its context.
        /// </summary>
        private static bool IsExpiredBuild(PolicyEvaluationRecord record)
        {
            if (record?.Context is JObject context)
            {
                JToken? token = context["isExpired"];
                return token != null
                    && token.Type == JTokenType.Boolean
                    && token.Value<bool>();
            }

            return false;
        }

        /// <inheritdoc/>
        public async Task<UserIdentity?> WhoAmIAsync(string organizationUrl, string? project)
        {
            string wantOrg = organizationUrl.TrimEnd('/');

            foreach (var accountGroup in m_config.AccountsByUri)
            {
                bool orgMatches = string.Equals(accountGroup.Key.ToString().TrimEnd('/'), wantOrg, StringComparison.OrdinalIgnoreCase);
                if (!orgMatches)
                {
                    continue;
                }

                bool anyProjectMatches = string.IsNullOrEmpty(project)
                    || accountGroup.Value.Any(a => string.Equals(a.Project, project, StringComparison.OrdinalIgnoreCase));
                if (!anyProjectMatches)
                {
                    continue;
                }

                using VssConnection connection = await GetConnectionAsync(accountGroup.Key, accountGroup.Value).ConfigureAwait(false);
                return new UserIdentity(connection.AuthorizedIdentity.Id, connection.AuthorizedIdentity.DisplayName);
            }

            return null;
        }

        /// <inheritdoc/>
        public async Task<string> RequeueBuildValidationAsync(int pullRequestId)
        {
            foreach (var accountGroup in m_config.AccountsByUri)
            {
                Uri organizationUri = accountGroup.Key;

                using VssConnection connection = await GetConnectionAsync(organizationUri, accountGroup.Value).ConfigureAwait(false);
                using GitHttpClient client = await connection.GetClientAsync<GitHttpClient>().ConfigureAwait(false);
                using PolicyHttpClient policyClient = await connection.GetClientAsync<PolicyHttpClient>().ConfigureAwait(false);

                GitPullRequest? pr;
                try
                {
                    pr = await client.GetPullRequestByIdAsync(pullRequestId).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // Not found in this organization; try the next one.
                    continue;
                }

                if (pr?.Repository?.ProjectReference == null)
                {
                    continue;
                }

                Guid projectId = pr.Repository.ProjectReference.Id;
                string project = projectId.ToString();
                string artifactId = string.Format(
                    CultureInfo.InvariantCulture,
                    "vstfs:///CodeReview/CodeReviewId/{0}/{1}",
                    projectId,
                    pullRequestId);

                List<PolicyEvaluationRecord> evaluations =
                    await policyClient.GetPolicyEvaluationsAsync(project, artifactId).ConfigureAwait(false);

                int requeued = 0;
                foreach (PolicyEvaluationRecord record in evaluations)
                {
                    if (!IsBuildPolicy(record) || record.EvaluationId == Guid.Empty)
                    {
                        continue;
                    }

                    // Only re-queue builds that need it: expired (stale) or failed.
                    bool failed = record.Status == PolicyEvaluationStatus.Rejected
                        || record.Status == PolicyEvaluationStatus.Broken;
                    if (!failed && !IsExpiredBuild(record))
                    {
                        continue;
                    }

                    await policyClient.RequeuePolicyEvaluationAsync(project, record.EvaluationId).ConfigureAwait(false);
                    requeued++;
                }

                return requeued == 0
                    ? $"No expired or failed build validation to re-queue for PR {pullRequestId}."
                    : $"Re-queued {requeued} build validation(s) for PR {pullRequestId}.";
            }

            return $"PR {pullRequestId} was not found in any configured account.";
        }

        /// <summary>
        /// The well-known Azure DevOps policy type id for the "Build" (build validation) policy.
        /// </summary>
        private static readonly Guid s_buildPolicyTypeId = new Guid("0609b952-1397-4640-95ec-e00a01b2c241");

        /// <summary>
        /// Returns <c>true</c> when the policy evaluation record is a build-validation policy.
        /// </summary>
        private static bool IsBuildPolicy(PolicyEvaluationRecord record)
        {
            PolicyTypeRef? type = record?.Configuration?.Type;
            if (type == null)
            {
                return false;
            }

            return type.Id == s_buildPolicyTypeId
                || string.Equals(type.DisplayName, "Build", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>
        /// Counts the comment threads on a pull request that contain at least one
        /// non-deleted, human-authored comment, split into active (unresolved) vs.
        /// everything else (fixed/won't fix/closed - i.e. "not active"), plus how
        /// many of the active ones the given user has participated in (used to
        /// notify on replies to "my" comments regardless of who owns the pull
        /// request), and how many @-mention the current user (see
        /// <see cref="CountMentions"/>). Returns (-1, -1, -1, -1, -1) when the
        /// lookup fails.
        /// </summary>
        /// <remarks>
        /// Azure DevOps also returns "system" comment threads for PR lifecycle
        /// events (reviewer added, source branch updated, vote changed, etc.) -
        /// these aren't comments a person wrote and the web UI's comment badge
        /// doesn't count them, so they're excluded here too (via
        /// <see cref="CommentType.Text"/>) to avoid inflating the count with
        /// threads that have nothing left to read once their real replies are
        /// deleted.
        /// </remarks>
        private static async Task<(int Active, int Total, int MyActive, int MentionThreads, int MentionTotal)> CountThreads(Task<List<GitPullRequestCommentThread>> threadsTask, Guid userId)
        {
            try
            {
                List<GitPullRequestCommentThread> threads = await threadsTask.ConfigureAwait(false);
                List<GitPullRequestCommentThread> real = threads
                    .Where(t => t.Comments != null && t.Comments.Any(c => !c.IsDeleted && c.CommentType == CommentType.Text))
                    .ToList();
                int active = real.Count(t => t.Status == CommentThreadStatus.Active);
                int myActive = real.Count(t => t.Status == CommentThreadStatus.Active && t.InvolvesUser(userId));
                (int mentionThreads, int mentionTotal) = CountMentions(threads, userId);
                return (active, real.Count, myActive, mentionThreads, mentionTotal);
            }
            catch (Exception)
            {
                return (-1, -1, -1, -1, -1);
            }
        }

        /// <summary>
        /// Counts @-mentions of <paramref name="userId"/> across a pull request's
        /// comment threads, over the same thread list <see cref="CountThreads"/>
        /// already fetched (no extra API calls). Azure DevOps stores a mention in
        /// a comment's content as the literal token "@&lt;GUID&gt;" (the mentioned
        /// user's id), matched here case-insensitively since ADO doesn't normalize
        /// the casing of the GUID it renders. Only non-deleted <see cref="CommentType.Text"/>
        /// comments count, matching <see cref="CountThreads"/>'s own filtering.
        /// </summary>
        /// <returns>
        /// <c>MentionThreads</c>: the number of <see cref="CommentThreadStatus.Active"/>
        /// threads containing at least one mention - this is what the dashboard
        /// uses to decide whether to surface the pull request under "Mentions".
        /// <c>MentionTotal</c>: the total number of matching comments across every
        /// thread regardless of status - a count that only ever grows, so the
        /// dashboard can diff it between polls to detect a new mention even after
        /// the thread it landed in was resolved.
        /// </returns>
        private static (int MentionThreads, int MentionTotal) CountMentions(List<GitPullRequestCommentThread> threads, Guid userId)
        {
            string mentionToken = "@<" + userId.ToString() + ">";
            int mentionThreads = 0;
            int mentionTotal = 0;

            foreach (GitPullRequestCommentThread thread in threads)
            {
                if (thread.Comments == null)
                {
                    continue;
                }

                bool threadHasMention = false;
                foreach (Comment comment in thread.Comments)
                {
                    if (comment == null || comment.IsDeleted || comment.CommentType != CommentType.Text
                        || string.IsNullOrEmpty(comment.Content))
                    {
                        continue;
                    }

                    if (comment.Content.Contains(mentionToken, StringComparison.OrdinalIgnoreCase))
                    {
                        mentionTotal++;
                        threadHasMention = true;
                    }
                }

                if (threadHasMention && thread.Status == CommentThreadStatus.Active)
                {
                    mentionThreads++;
                }
            }

            return (mentionThreads, mentionTotal);
        }

        /// <summary>
        /// Determines whether a pull request's source branch still exists on the
        /// server, using a per-repository branch cache populated on demand.
        /// </summary>
        /// <returns><c>true</c> if the branch exists, or if the lookup could not
        /// be performed (so PRs are never hidden on uncertainty).</returns>
        private async Task<bool> SourceBranchExists(GitHttpClient client, GitPullRequest pr)
        {
            Guid repoId = pr.Repository.Id;
            Lazy<Task<HashSet<string>?>> lazyBranches = m_repoBranches.GetOrAdd(
                repoId,
                id => new Lazy<Task<HashSet<string>?>>(() => LoadRepoBranches(client, id)));
            HashSet<string>? branches = await lazyBranches.Value.ConfigureAwait(false);

            // Null means the branch lookup failed; don't hide PRs on uncertainty.
            //
            if (branches == null)
            {
                return true;
            }

            return !string.IsNullOrEmpty(pr.SourceRefName) && branches.Contains(pr.SourceRefName);
        }

        /// <summary>
        /// Loads the set of existing branch ref names ("refs/heads/...") for a
        /// repository, or <c>null</c> if the refs could not be retrieved.
        /// </summary>
        private static async Task<HashSet<string>?> LoadRepoBranches(GitHttpClient client, Guid repoId)
        {
            try
            {
                List<GitRef> refs = await client.GetRefsAsync(repoId, filter: "heads/").ConfigureAwait(false);
                HashSet<string> branches = new HashSet<string>(StringComparer.Ordinal);
                foreach (GitRef gitRef in refs)
                {
                    if (!string.IsNullOrEmpty(gitRef.Name))
                    {
                        branches.Add(gitRef.Name);
                    }
                }

                return branches;
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>
        /// Tries to get the current users reviewer object from a pull request.
        /// </summary>
        /// <param name="pullRequest">The pull request we want to look our selves up in.</param>
        /// <param name="currentUserId">The <see cref="Guid"/> of our current user.</param>
        /// <param name="reviewer">Output  parameter that points to our own reviewer object.</param>
        /// <returns>Returns <c>true</c> if the reviewer was found, <c>false</c> otherwise.</returns>
        private static bool TryGetReviewer(GitPullRequest pullRequest, Guid currentUserId, out IdentityRefWithVote reviewer)
        {
            foreach (IdentityRefWithVote r in pullRequest.Reviewers)
            {
                if (currentUserId.Equals(Guid.Parse(r.Id)))
                {
                    reviewer = r;
                    return true;
                }
            }

            reviewer = new IdentityRefWithVote();
            return false;
        }

        /// <summary>
        /// Factory method for creating the connection.
        /// </summary>
        /// <param name="account">Account details to create the connection for.</param>
        /// <returns>A valid <see cref="VssConnection"/> for the given account.</returns>
        private static async Task<VssConnection> GetConnectionAsync(Uri organizationUri, IList<AccountConfig> accounts)
        {
            VssCredentials credential;

            // If the org has more than one pat token, just pick one, it doesn't matter.
            //
            AccountConfig? patTokenAccount = accounts.FirstOrDefault(a => a.PersonalAccessToken != null);

            // If the user didn't configure a PAT token, try to login via AAD.
            //
            if (patTokenAccount == null)
            {
                // Note: The UserPrincipal API is only available on windows.
                //
                if (OperatingSystem.IsWindows())
                {
                    credential = new VssAadCredential(UserPrincipal.Current.EmailAddress);
                }
                else
                {
                    throw new InvalidOperationException($"The configured orginization ({organizationUri}) has no configured PAT");
                }
            }
            else
            {
                credential = new VssBasicCredential(string.Empty, patTokenAccount.PersonalAccessToken);
            }

            VssConnection connection = new VssConnection(organizationUri, credential);
            await connection.ConnectAsync();
            return connection;
        }

        /// <summary>
        /// Invokes event update when statistics are updated.
        /// </summary>
        private void OnStatisticsUpdate()
        {
            StatisticsUpdateEventArgs eventArgs = new StatisticsUpdateEventArgs()
            {
                Statistics = m_statistics
            };

            StatisticsUpdate?.Invoke(this, eventArgs);
        }
    }
}
