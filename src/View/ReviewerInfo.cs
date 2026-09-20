namespace AzureCli.View
{
    /// <summary>
    /// A single reviewer on a pull request and the vote they cast.
    /// </summary>
    public class ReviewerInfo
    {
        /// <summary>The reviewer's display name.</summary>
        public string Name { get; set; } = string.Empty;

        /// <summary>
        /// The ADO vote: 10 approved, 5 approved with suggestions, 0 none,
        /// -5 waiting for author, -10 rejected.
        /// </summary>
        public short Vote { get; set; }
    }
}
