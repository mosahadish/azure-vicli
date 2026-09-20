using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using Microsoft.CodeAnalysis;
using Microsoft.TeamFoundation.SourceControl.WebApi;
using AzureCli.DataSource;

namespace AzureCli.View
{
    /// <summary>
    /// Represents a pull request element, wrapping the raw ADO client type
    /// with the fields/formatting the headless NDJSON writer needs.
    /// </summary>
    [SuppressMessage("Design", "CA1036:Override methods on comparable types", Justification = "We just want to sort.")]
    public class PullRequestViewElement : IComparable<PullRequestViewElement>, IEqualityComparer<PullRequestViewElement>
    {
        /// <summary>
        /// The pull request we are wrapping.
        /// </summary>
        private readonly GitPullRequest m_pullRequest;

        private readonly DateTime m_updatedTime;

        /// <summary>
        /// Expose Pull Request description
        /// </summary>
        public string Description => m_pullRequest.Description;

        /// <summary>
        /// The section/state this element belongs to.
        /// </summary>
        public PrState State { get; set; }

        /// <summary>
        /// The organization URL of the account this PR came from (multi-account aware).
        /// </summary>
        public string? OrganizationUrl { get; set; }

        /// <summary>
        /// The project name of the account this PR came from (multi-account aware).
        /// </summary>
        public string? Project { get; set; }

        /// <summary>
        /// The configured local directory this account's repos should be cloned
        /// under (see AccountConfig.ClonesDirectory), or null when not configured.
        /// </summary>
        public string? ClonesDirectory { get; set; }

        /// <summary>
        /// The id (GUID) of the authenticated user this PR was fetched as, so the
        /// reviewer can tell "my" comments apart without a separate identity call.
        /// </summary>
        public Guid? CurrentUserId { get; set; }

        /// <summary>
        /// The display name of the authenticated user this PR was fetched as.
        /// </summary>
        public string? CurrentUserName { get; set; }

        /// <summary>
        /// The number of active (unresolved) comment threads, or null/-1 when unknown.
        /// </summary>
        public int? ActiveThreadCount { get; set; }

        /// <summary>
        /// The total number of comment threads (active + fixed/won't-fix/closed),
        /// or null/-1 when unknown.
        /// </summary>
        public int? TotalThreadCount { get; set; }

        /// <summary>
        /// The number of active (unresolved) comment threads the current user has
        /// participated in, or null/-1 when unknown. Used to notify on replies to
        /// "my" comments regardless of who owns the pull request.
        /// </summary>
        public int? MyActiveThreadCount { get; set; }

        /// <summary>
        /// The aggregated build-validation policy result:
        /// "succeeded", "failed", "running", "none", or "unknown".
        /// </summary>
        public string BuildStatus { get; set; } = "none";

        /// <summary>
        /// The build's 1-based position in the agent queue when <see cref="BuildStatus"/>
        /// is "running" and the build has not started running yet (still waiting for an
        /// agent), or null when unknown/not applicable (e.g. the build is already running
        /// or there is no build).
        /// </summary>
        public int? QueuePosition { get; set; }

        /// <summary>Whether the PR currently has merge conflicts against its target branch.</summary>
        public bool HasMergeConflict => m_pullRequest.MergeStatus == PullRequestAsyncStatus.Conflicts;

        /// <summary>The pull request id.</summary>
        public int Id => m_pullRequest.PullRequestId;

        /// <summary>The pull request title.</summary>
        public string Title => m_pullRequest.Title;

        /// <summary>The repository name.</summary>
        public string RepositoryName => m_pullRequest.Repository.Name;

        /// <summary>The source branch, without the refs/heads/ prefix.</summary>
        public string SourceBranch => StripRefsHeads(m_pullRequest.SourceRefName);

        /// <summary>The target branch, without the refs/heads/ prefix.</summary>
        public string TargetBranch => StripRefsHeads(m_pullRequest.TargetRefName);

        /// <summary>The author display name.</summary>
        public string AuthorName => m_pullRequest.CreatedBy?.DisplayName ?? string.Empty;

        /// <summary>
        /// Whether "complete automatically when requirements are met" (auto-complete)
        /// is set on this PR, mirroring the web UI's flag.
        /// </summary>
        public bool AutoComplete => m_pullRequest.AutoCompleteSetBy != null;

        /// <summary>The display name of whoever set auto-complete, or empty when not set.</summary>
        public string AutoCompleteSetByName => m_pullRequest.AutoCompleteSetBy?.DisplayName ?? string.Empty;

        /// <summary>The last-activity time used for ordering.</summary>
        public DateTime UpdatedTime => m_updatedTime;

        /// <summary>Whether the PR is a draft.</summary>
        public bool IsDraft => m_pullRequest.IsDraft ?? false;

        /// <summary>The "signedOff / total" vote ratio text.</summary>
        public string VoteRatioText => m_pullRequest.VoteRatio();

        /// <summary>The compact per-reviewer status summary (glyph + surname).</summary>
        public string ReviewerSummaryText => m_pullRequest.ReviewerStatusSummary();

        /// <summary>The individual reviewers and their votes.</summary>
        public IReadOnlyList<ReviewerInfo> Reviewers
        {
            get
            {
                var list = new List<ReviewerInfo>();
                if (m_pullRequest.Reviewers != null)
                {
                    foreach (var r in m_pullRequest.Reviewers)
                    {
                        if (r != null && !r.IsContainer)
                        {
                            list.Add(new ReviewerInfo { Name = r.DisplayName, Vote = r.Vote });
                        }
                    }
                }

                return list;
            }
        }

        /// <summary>
        /// Removes the "refs/heads/" prefix from a git ref name.
        /// </summary>
        private static string StripRefsHeads(string refName)
        {
            const string Prefix = "refs/heads/";
            if (!string.IsNullOrEmpty(refName) && refName.StartsWith(Prefix, StringComparison.Ordinal))
            {
                return refName.Substring(Prefix.Length);
            }

            return refName ?? string.Empty;
        }

        /// <summary>
        /// Constructs a new element which wraps a <see cref="GitPullRequest"/> object.
        /// </summary>
        /// <param name="request">The pull request this element represents.</param>
        public PullRequestViewElement(GitPullRequest request)
        {
            m_pullRequest = request;
            m_updatedTime = request.LatestCommitDate();
        }

        /// <summary>
        /// Implements IComparable<![CDATA[T]]> so we can sort elements correctly.
        /// </summary>
        /// <param name="other">The other element to compare to.</param>
        /// <returns>
        /// Less than zero, this instance precedes other in the sort order.
        /// Zero, this instance occurs in the same position in the sort order as other.
        /// Greater than zero, this instance follows other in the sort order.
        /// </returns>
        public int CompareTo([AllowNull] PullRequestViewElement other)
        {
            // If other is null, than we must be greater.
            //
            if (other == null)
            {
                return 1;
            }

            // Force sort order descending by negating the default sort order.
            //
            return -m_updatedTime.CompareTo(other.m_updatedTime);
        }

        /// <summary>
        /// Compares two pull requests for equality.
        /// </summary>
        /// <param name="x">Pull request to compare.</param>
        /// <param name="y">Pull request to compare</param>
        /// <returns>True if equal, false otherwise.</returns>
        public bool Equals([AllowNull] PullRequestViewElement x, [AllowNull] PullRequestViewElement y)
        {
            if (x == null && y == null)
            {
                return true;
            }

            if (x == null || y == null)
            {
                return false;
            }

            return x.m_pullRequest.ArtifactId == y.m_pullRequest.ArtifactId;
        }

        /// <summary>
        /// Computes hash code for the pull request value.
        /// </summary>
        /// <param name="obj">Pull request to compare</param>
        public int GetHashCode([DisallowNull] PullRequestViewElement obj)
        {
            if (obj == null)
            {
                return 0;
            }
            return SymbolEqualityComparer.Default.GetHashCode(obj.m_pullRequest as ISymbol);
        }
    }
}
