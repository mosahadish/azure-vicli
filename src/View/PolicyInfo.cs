namespace AzureCli.View
{
    /// <summary>
    /// A single non-build branch policy evaluation on a pull request (required
    /// reviewers, minimum reviewer count, work item linking, comment
    /// requirements, ...). Build validation is reported separately via
    /// <see cref="PullRequestViewElement.BuildStatus"/> and is never one of these.
    /// </summary>
    public class PolicyInfo
    {
        /// <summary>The policy type's display name, e.g. "Required reviewers".</summary>
        public string Name { get; set; } = string.Empty;

        /// <summary>
        /// The evaluation status, lowercased: approved, rejected, queued, running,
        /// or broken. ("notApplicable" evaluations are never surfaced as a
        /// PolicyInfo.)
        /// </summary>
        public string Status { get; set; } = string.Empty;
    }
}
