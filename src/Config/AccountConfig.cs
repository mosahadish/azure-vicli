using System;

namespace AzureCli.Configuration
{
    /// <summary>
    /// Represents an account that the dashboard should poll for status.
    /// </summary>
    public sealed class AccountConfig
    {
        /// <summary>
        /// Access token for authenticating to Azure DevOps.
        /// See: https://docs.microsoft.com/azure/devops/integrate/get-started/authentication/pats
        /// </summary>
        /// <remarks>
        /// If PAT token is null, then the client attempts to fall back to Azure AD Authentication.
        /// </remarks>
        public string? PersonalAccessToken { get; set; }

        /// <summary>
        /// Should we hide ancient pull requests or not.
        /// </summary>
        public bool? HideAncientPullRequests { get; set; }

        /// <summary>
        /// Organization Url, for example: https://dev.azure.com/fabrikam
        /// </summary>
        public Uri? OrganizationUrl { get; set; }

        /// <summary>
        /// The project name to query inside the organization.
        /// </summary>
        public string? Project { get; set; }

        /// <summary>
        /// The local directory under which repositories for this account should be
        /// cloned (e.g. "C:\Users\me\source\repos"). Each repo gets its own
        /// subdirectory named after the repo. Optional: when unset, the dashboard
        /// falls back to inferring a sibling directory from wherever the reviewer's
        /// PRDASH_REPO_PATH already points, and won't offer to auto-clone.
        /// </summary>
        public string? ClonesDirectory { get; set; }
    }
}
