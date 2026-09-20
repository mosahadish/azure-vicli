using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Humanizer;
using AzureCli.View;

namespace AzureCli.DataSource
{
    /// <summary>
    /// Streams the configured pull requests to a <see cref="TextWriter"/> as
    /// newline-delimited JSON (one PR object per line). This is the headless
    /// data feed consumed by the nvim dashboard; it deliberately produces no
    /// TUI output.
    /// </summary>
    public static class PullRequestListWriter
    {
        /// <summary>
        /// Writes every assigned and created pull request to <paramref name="writer"/>
        /// as NDJSON, one object per line.
        /// </summary>
        /// <param name="source">The data source to read from.</param>
        /// <param name="writer">The destination writer (typically stdout).</param>
        public static async Task WriteAsync(IPullRequestSource source, TextWriter writer)
        {
            if (source == null)
            {
                throw new ArgumentNullException(nameof(source));
            }

            if (writer == null)
            {
                throw new ArgumentNullException(nameof(writer));
            }

            await foreach (PullRequestViewElement element in source.FetchGroupedPullRequests())
            {
                await writer.WriteLineAsync(Serialize(element));
            }

            await writer.FlushAsync();
        }

        /// <summary>
        /// Serializes a single element to a compact JSON object.
        /// </summary>
        private static string Serialize(PullRequestViewElement element)
        {
            var reviewers = new List<object>();
            foreach (ReviewerInfo r in element.Reviewers)
            {
                reviewers.Add(new { name = r.Name, vote = r.Vote });
            }

            var policies = new List<object>();
            foreach (PolicyInfo p in element.Policies)
            {
                policies.Add(new { name = p.Name, status = p.Status });
            }

            var record = new
            {
                id = element.Id,
                title = element.Title,
                repo = element.RepositoryName,
                project = element.Project ?? string.Empty,
                org = element.OrganizationUrl ?? string.Empty,
                source = element.SourceBranch,
                target = element.TargetBranch,
                author = element.AuthorName,
                updatedIso = element.UpdatedTime.ToString("o", CultureInfo.InvariantCulture),
                updatedHuman = element.UpdatedTime.Humanize(),
                isDraft = element.IsDraft,
                state = element.State.ToString(),
                autoComplete = element.AutoComplete,
                autoCompleteSetBy = element.AutoCompleteSetByName,
                voteRatio = element.VoteRatioText,
                reviewerSummary = element.ReviewerSummaryText,
                activeThreads = element.ActiveThreadCount ?? -1,
                closedThreads = (element.ActiveThreadCount.HasValue && element.TotalThreadCount.HasValue
                    && element.ActiveThreadCount >= 0 && element.TotalThreadCount >= 0)
                    ? element.TotalThreadCount.Value - element.ActiveThreadCount.Value
                    : -1,
                totalThreads = element.TotalThreadCount ?? -1,
                myActiveThreads = element.MyActiveThreadCount ?? -1,
                mentionThreads = element.MentionThreadCount ?? -1,
                mentionTotal = element.MentionTotalCount ?? -1,
                description = element.Description ?? string.Empty,
                buildStatus = element.BuildStatus ?? "none",
                queuePosition = element.QueuePosition ?? -1,
                buildUrl = element.BuildUrl ?? string.Empty,
                policies,
                missingReviewers = element.MissingReviewers ?? Array.Empty<string>(),
                mergeConflict = element.HasMergeConflict,
                url = BuildUrl(element),
                cloneUrl = BuildCloneUrl(element),
                clonesDir = element.ClonesDirectory ?? string.Empty,
                myId = element.CurrentUserId?.ToString() ?? string.Empty,
                myName = element.CurrentUserName ?? string.Empty,
                reviewers,
            };

            return JsonSerializer.Serialize(record);
        }

        /// <summary>
        /// Builds the web URL of a pull request, matching the browser handler format.
        /// </summary>
        private static string BuildUrl(PullRequestViewElement element)
        {
            string org = (element.OrganizationUrl ?? string.Empty).TrimEnd('/');
            string proj = Uri.EscapeDataString(element.Project ?? string.Empty);
            string repo = Uri.EscapeDataString(element.RepositoryName ?? string.Empty);
            return $"{org}/{proj}/_git/{repo}/pullrequest/{element.Id}";
        }

        /// <summary>
        /// Builds the git remote URL for cloning this PR's repository (same
        /// as the web URL but without the "/pullrequest/{id}" suffix) — this
        /// is a valid `git clone` target for both Azure DevOps Services and
        /// on-prem Azure DevOps Server / TFS.
        /// </summary>
        private static string BuildCloneUrl(PullRequestViewElement element)
        {
            string org = (element.OrganizationUrl ?? string.Empty).TrimEnd('/');
            string proj = Uri.EscapeDataString(element.Project ?? string.Empty);
            string repo = Uri.EscapeDataString(element.RepositoryName ?? string.Empty);
            if (org.Length == 0 || element.Project == null || element.RepositoryName == null)
            {
                return string.Empty;
            }

            return $"{org}/{proj}/_git/{repo}";
        }
    }
}
