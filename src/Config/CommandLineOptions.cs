using CommandLine;

namespace AzureCli.Configuration
{
    /// <summary>
    /// Represents the command line configuration for the dashboard.
    /// </summary>
    public class CommandLineOptions
    {
        /// <summary>
        /// The verbose command line option.
        /// </summary>
        [Option("verbose", HelpText = "Sets output to verbose mode")]
        public bool Verbose { get; set; }

        /// <summary>
        /// Hidden demo mode option.
        /// </summary>
        [Option('d', "demo-mode", HelpText = "Run in demo mode", Hidden = true)]
        public bool DemoMode { get; set; }

        [Option('x', "hide-ancient", HelpText = "Hide Ancient PRs from View")]
        public bool HideAnchientPrs { get; set; }

        /// <summary>
        /// Headless mode: print pull requests as NDJSON to stdout and exit,
        /// instead of launching the interactive TUI. Used by the nvim dashboard.
        /// </summary>
        [Option("list", HelpText = "Print pull requests as NDJSON and exit (no TUI)")]
        public bool List { get; set; }

        /// <summary>
        /// Headless mode: re-queue the build validation policies for the given
        /// pull request id, then exit. Used by the nvim dashboard.
        /// </summary>
        [Option("requeue", HelpText = "Re-queue build validation for the given pull request id and exit (no TUI)")]
        public int? Requeue { get; set; }

        /// <summary>
        /// Headless mode: print the configured PAT for the account matching
        /// --org (and --project, if given) and exit. Lets shell scripts
        /// (review-pr.sh) resolve credentials straight from pr-dash.yml
        /// instead of needing their own copy of the PAT in an env var.
        /// </summary>
        [Option("print-pat", HelpText = "Print the configured PAT for --org/--project and exit (no TUI)")]
        public bool PrintPat { get; set; }

        /// <summary>
        /// Organization URL to match an account by, used with --print-pat.
        /// </summary>
        [Option("org", HelpText = "Organization URL to match when resolving --print-pat")]
        public string? Org { get; set; }

        /// <summary>
        /// Project name to match an account by, used with --print-pat.
        /// </summary>
        [Option("project", HelpText = "Project name to match when resolving --print-pat")]
        public string? Project { get; set; }

        /// <summary>
        /// Headless mode: print the authenticated identity (id + display name)
        /// for the account matching --org (and --project, if given) as JSON,
        /// then exit. Lets the nvim reviewer tell "my" comments/PRs apart from
        /// everyone else's without hard-coding a name.
        /// </summary>
        [Option("whoami", HelpText = "Print the authenticated identity for --org/--project as JSON and exit (no TUI)")]
        public bool WhoAmI { get; set; }
    }
}