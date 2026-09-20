using System;
using System.Collections.Generic;
using System.DirectoryServices.AccountManagement;
using System.Globalization;
using System.Linq;
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
        /// value means the lookup failed and filtering is skipped for that repo.
        /// </summary>
        private readonly Dictionary<Guid, HashSet<string>?> m_repoBranches = new Dictionary<Guid, HashSet<string>?>();

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
        /// Retrieves pull requests from the configured data source.
        /// </summary>
        /// <returns>An async stream of <see cref="PullRequestViewElement"/></returns>
        public IAsyncEnumerable<PullRequestViewElement> FetchAssignedPullRequests(PrState state)
        {
            m_statistics.Reset();
            m_repoBranches.Clear();

            return FetchPullRequstsInternal(state);
        }

        /// <summary>
        /// Retrieves all active pull requests this user has created.
        /// </summary>
        /// <returns>An async stream of <see cref="PullRequestViewElement"/></returns>
        public async IAsyncEnumerable<PullRequestViewElement> FetchCreatedPullRequests()
        {
            foreach (var accountGroup in m_config.AccountsByUri)
            {
                Uri organizationUri = accountGroup.Key;

                using VssConnection connection = await GetConnectionAsync(organizationUri, accountGroup.Value);
                using GitHttpClient client = await connection.GetClientAsync<GitHttpClient>();
                using PolicyHttpClient policyClient = await connection.GetClientAsync<PolicyHttpClient>();
                using BuildHttpClient buildClient = await connection.GetClientAsync<BuildHttpClient>();
                {
                    // Capture the currentUserId so it can be used to filter PR's later.
                    //
                    Guid userId = connection.AuthorizedIdentity.Id;

                    // Only fetch pull requests which are active, and assigned to this user.
                    //
                    GitPullRequestSearchCriteria criteria = new GitPullRequestSearchCriteria
                    {
                        CreatorId = userId,
                        Status = PullRequestStatus.Active,
                        IncludeLinks = false,
                    };

                    foreach (AccountConfig account in accountGroup.Value)
                    {
                        List<GitPullRequest> requests = await client.GetPullRequestsByProjectAsync(account.Project, criteria);
                        foreach (var request in requests)
                        {
                            (int active, int total, int myActive) = await CountThreads(client, request, userId).ConfigureAwait(false);
                            (string buildStatus, int? queuePosition) = await GetBuildStatus(policyClient, buildClient, request, account.Project).ConfigureAwait(false);
                            yield return new PullRequestViewElement(request) { State = PrState.Created, OrganizationUrl = account.OrganizationUrl?.ToString(), Project = account.Project, ClonesDirectory = account.ClonesDirectory, ActiveThreadCount = active, TotalThreadCount = total, MyActiveThreadCount = myActive, BuildStatus = buildStatus, QueuePosition = queuePosition };
                        }
                    }
                }
            }
        }

        /// <summary>
        /// Helper function to make async code line up, since interface methods cannot be marked
        /// as async.
        /// </summary>
        /// <returns>An async stream of <see cref="PullRequestViewElement"/></returns>
        private async IAsyncEnumerable<PullRequestViewElement> FetchPullRequstsInternal(PrState state)
        {
            foreach (var accountGroup in m_config.AccountsByUri)
            {
                Uri organizationUri = accountGroup.Key;

                // Create a shared connection to the AzureDevOps Git API for all accounts sharing the same organization uri.
                //
                using VssConnection connection = await GetConnectionAsync(organizationUri, accountGroup.Value);
                using GitHttpClient client = await connection.GetClientAsync<GitHttpClient>();

                // Capture the currentUserId so it can be used to filter PR's later.
                //
                Guid userId = connection.AuthorizedIdentity.Id;

                foreach (AccountConfig account in accountGroup.Value)
                {
                    await foreach (var pr in FetchPullRequests(client, userId, account, state))
                    {
                        // We only want to fetch the commit data if the config is enabled.
                        //
                        if (m_config.SortByRecentCommit)
                        {
                            var commits = await client.GetPullRequestCommitsAsync(pr.Repository.Id, pr.PullRequestId);
                            pr.Commits = commits.ToArray();
                        }

                        yield return new PullRequestViewElement(pr) { OrganizationUrl = account.OrganizationUrl?.ToString(), Project = account.Project, ClonesDirectory = account.ClonesDirectory };
                    }
                }
            }
        }

        /// <summary>
        /// Retrieves all active & actionable pull requests to the configured data source.
        /// </summary>
        /// <param name="accountConfig">The account to retrieve the pull requests for.</param>
        /// <returns>A stream of <see cref="GitPullRequest"/></returns>
        private async IAsyncEnumerable<GitPullRequest> FetchPullRequests(GitHttpClient client, Guid userId, AccountConfig accountConfig, PrState state)
        {
            await foreach (var pr in FetchAccountActivePullRequsts(client, userId, accountConfig))
            {
                PrState? processedState = await ComputeState(client, pr, userId, accountConfig);

                m_statistics.Accumulate(processedState);
                if (state == processedState)
                {
                    yield return pr;
                }
            }

            // Post event on stats update.
            //
            OnStatisticsUpdate();
        }

        /// <summary>
        /// Retrieves every assigned pull request in a single pass, each tagged
        /// with its computed state so the view can render grouped sections.
        /// </summary>
        /// <returns>An async stream of <see cref="PullRequestViewElement"/></returns>
        public async IAsyncEnumerable<PullRequestViewElement> FetchGroupedPullRequests()
        {
            m_statistics.Reset();
            m_repoBranches.Clear();

            foreach (var accountGroup in m_config.AccountsByUri)
            {
                Uri organizationUri = accountGroup.Key;

                using VssConnection connection = await GetConnectionAsync(organizationUri, accountGroup.Value);
                using GitHttpClient client = await connection.GetClientAsync<GitHttpClient>();
                using PolicyHttpClient policyClient = await connection.GetClientAsync<PolicyHttpClient>();
                using BuildHttpClient buildClient = await connection.GetClientAsync<BuildHttpClient>();

                Guid userId = connection.AuthorizedIdentity.Id;

                foreach (AccountConfig account in accountGroup.Value)
                {
                    await foreach (var pr in FetchAccountActivePullRequsts(client, userId, account))
                    {
                        PrState? processedState = await ComputeState(client, pr, userId, account);
                        m_statistics.Accumulate(processedState);

                        if (processedState.HasValue)
                        {
                            if (m_config.SortByRecentCommit)
                            {
                                var commits = await client.GetPullRequestCommitsAsync(pr.Repository.Id, pr.PullRequestId);
                                pr.Commits = commits.ToArray();
                            }

                            (int active, int total, int myActive) = await CountThreads(client, pr, userId).ConfigureAwait(false);
                            (string buildStatus, int? queuePosition) = await GetBuildStatus(policyClient, buildClient, pr, account.Project).ConfigureAwait(false);
                            yield return new PullRequestViewElement(pr) { State = processedState.Value, OrganizationUrl = account.OrganizationUrl?.ToString(), Project = account.Project, ClonesDirectory = account.ClonesDirectory, ActiveThreadCount = active, TotalThreadCount = total, MyActiveThreadCount = myActive, BuildStatus = buildStatus, QueuePosition = queuePosition };
                        }
                    }
                }
            }

            OnStatisticsUpdate();
        }

        /// <summary>
        /// Computes the "processed" state of a pull request, or <c>null</c> if it
        /// should not be shown to this user.
        /// </summary>
        private async Task<PrState?> ComputeState(GitHttpClient client, GitPullRequest pr, Guid userId, AccountConfig accountConfig)
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
                List<GitPullRequestCommentThread> threads = await client.GetThreadsAsync(pr.Repository.Id, pr.PullRequestId).ConfigureAwait(false);
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
        /// is still waiting for an agent (i.e. not yet actually running).
        /// </summary>
        private static async Task<(string Status, int? QueuePosition)> GetBuildStatus(PolicyHttpClient policyClient, BuildHttpClient buildClient, GitPullRequest pr, string? project)
        {
            try
            {
                if (policyClient == null || string.IsNullOrEmpty(project) || pr?.Repository?.ProjectReference == null)
                {
                    return ("none", null);
                }

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
                int? runningBuildId = null;

                foreach (PolicyEvaluationRecord record in evaluations)
                {
                    if (!IsBuildPolicy(record))
                    {
                        continue;
                    }

                    anyBuild = true;
                    switch (record.Status)
                    {
                        case PolicyEvaluationStatus.Rejected:
                        case PolicyEvaluationStatus.Broken:
                            anyFailed = true;
                            break;
                        case PolicyEvaluationStatus.Running:
                        case PolicyEvaluationStatus.Queued:
                            // A stale build reports as Queued but carries isExpired in its
                            // context; Azure DevOps surfaces that as a failed required check.
                            if (IsExpiredBuild(record))
                            {
                                anyExpired = true;
                            }
                            else
                            {
                                anyRunning = true;
                                runningBuildId ??= GetBuildId(record);
                            }

                            break;
                        case PolicyEvaluationStatus.Approved:
                            break;
                        default:
                            anyPending = true;
                            break;
                    }
                }

                if (!anyBuild)
                {
                    return ("none", null);
                }

                if (anyFailed)
                {
                    return ("failed", null);
                }

                if (anyExpired)
                {
                    return ("expired", null);
                }

                if (anyRunning || anyPending)
                {
                    int? queuePosition = runningBuildId.HasValue
                        ? await GetQueuePosition(buildClient, project, runningBuildId.Value).ConfigureAwait(false)
                        : null;
                    return ("running", queuePosition);
                }

                return ("succeeded", null);
            }
            catch (Exception)
            {
                return ("none", null);
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
        /// request). Returns (-1, -1, -1) when the lookup fails.
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
        private static async Task<(int Active, int Total, int MyActive)> CountThreads(GitHttpClient client, GitPullRequest pr, Guid userId)
        {
            try
            {
                List<GitPullRequestCommentThread> threads = await client.GetThreadsAsync(pr.Repository.Id, pr.PullRequestId).ConfigureAwait(false);
                List<GitPullRequestCommentThread> real = threads
                    .Where(t => t.Comments != null && t.Comments.Any(c => !c.IsDeleted && c.CommentType == CommentType.Text))
                    .ToList();
                int active = real.Count(t => t.Status == CommentThreadStatus.Active);
                int myActive = real.Count(t => t.Status == CommentThreadStatus.Active && t.InvolvesUser(userId));
                return (active, real.Count, myActive);
            }
            catch (Exception)
            {
                return (-1, -1, -1);
            }
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
            if (!m_repoBranches.TryGetValue(repoId, out HashSet<string>? branches))
            {
                branches = await LoadRepoBranches(client, repoId).ConfigureAwait(false);
                m_repoBranches[repoId] = branches;
            }

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
        /// Retrieves all active & actionable pull requests for a specific account.
        /// </summary>
        /// <param name="accountConfig">The account to get the pull requests for.</param>
        /// <returns>A stream of <see cref="GitPullRequest"/></returns>
        private static async IAsyncEnumerable<GitPullRequest> FetchAccountActivePullRequsts(GitHttpClient client, Guid userId, AccountConfig accountConfig)
        {
            // Only fetch pull requests which are active, and assigned to this user.
            //
            GitPullRequestSearchCriteria criteria = new GitPullRequestSearchCriteria
            {
                ReviewerId = userId,
                Status = PullRequestStatus.Active,
                IncludeLinks = false,
            };

            List<GitPullRequest> requests = await client.GetPullRequestsByProjectAsync(accountConfig.Project, criteria);
            foreach (var request in requests)
            {
                yield return request;
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
