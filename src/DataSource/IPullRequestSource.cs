using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.TeamFoundation.SourceControl.WebApi;
using AzureCli.View;

namespace AzureCli.DataSource
{
    /// <summary>
    /// Event arguments for callback on statistics updates.
    /// </summary>
    public class StatisticsUpdateEventArgs : EventArgs
    {
        public PullRequestStatistics? Statistics { get; set; }
    }

    public enum PrState
    {
        // Return only actionable pull requests.
        Actionable,

        // Return pull request marked as drafts.
        Drafts,

        // Return pull request we are waiting on.
        Waiting,

        // Return pull request we signed off on.
        SignedOff,

        // Return pull requests we created.
        Created,
    }

    /// <summary>
    /// Interface for interacting with the pull request.
    /// </summary>
    public interface IPullRequestSource
    {
        /// <summary>
        /// Event to list on statistics updates.
        /// </summary>
        event EventHandler<StatisticsUpdateEventArgs> StatisticsUpdate;

        /// <summary>
        /// Retrieves all assigned pull requests, each tagged with its computed
        /// <see cref="PrState"/> so the view can group them, followed by the
        /// pull requests this user created (tagged <see cref="PrState.Created"/>).
        /// </summary>
        /// <returns>A stream of <see cref="PullRequestViewElement"/></returns>
        IAsyncEnumerable<PullRequestViewElement> FetchGroupedPullRequests();

        /// <summary>
        /// Re-queues the build validation branch policies for the given pull
        /// request (used to refresh an expired or failed build).
        /// </summary>
        /// <param name="pullRequestId">The pull request id to re-queue.</param>
        /// <returns>A human-readable summary of the outcome.</returns>
        Task<string> RequeueBuildValidationAsync(int pullRequestId);

        /// <summary>
        /// Resolves the authenticated identity for the account matching the
        /// given organization (and optionally project), so callers can tell
        /// "my" comments/PRs apart from everyone else's.
        /// </summary>
        /// <param name="organizationUrl">The organization URL to match an account by.</param>
        /// <param name="project">The project name to match an account by, or null to match any project in the organization.</param>
        /// <returns>The matching identity, or null if no account matches.</returns>
        Task<UserIdentity?> WhoAmIAsync(string organizationUrl, string? project);
    }

    /// <summary>
    /// The identity of the authenticated user for a given account, used to tell
    /// "my" comments/pull requests apart from everyone else's.
    /// </summary>
    /// <param name="Id">The unique identifier (GUID) of the authenticated user.</param>
    /// <param name="DisplayName">The human-readable display name of the authenticated user.</param>
    public record UserIdentity(Guid Id, string DisplayName);
}
