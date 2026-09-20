using System;
using System.Collections.Generic;
using System.Configuration;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Runtime.InteropServices;
using YamlDotNet.RepresentationModel;

namespace AzureCli.Configuration
{
    /// <summary>
    /// Represents the complete configuration for the dashboard.
    /// </summary>
    public sealed class Config
    {
        /// <summary>
        /// The default configuration file name.
        /// </summary>
        private static string ConfigName = "azure-cli.yml";

        /// <summary>
        /// The legacy configuration file name (still honored if azure-cli.yml
        /// doesn't exist), from back when this project was named pr-dash.
        /// </summary>
        private static string LegacyConfigName = "pr-dash.yml";

        /// <summary>
        /// The name of the root account node.
        /// </summary>
        private static string YamlRootAccountsToken = "accounts";

        /// <summary>
        /// The name of the PAT token field.
        /// </summary>
        private static string YamlFieldPatToken = "pat";

        /// <summary>
        /// The name of the Organization Url token field.
        /// </summary>
        private static string YamlFieldOrgUrlToken = "org_url";

        /// <summary>
        /// The name of the project name token field.
        /// </summary>
        private static string YamlFieldProjectToken = "project_name";

        /// <summary>
        /// The name of the hide ancient pull request token field.
        /// </summary>
        private static string YamlFieldHideAncientPullRequestsToken = "hide_ancient";

        /// <summary>
        /// The name of the clones directory token field.
        /// </summary>
        private static string YamlFieldClonesDirectoryToken = "clones_dir";

        /// <summary>
        /// The name of the (top-level, machine-wide) bash executable path token field.
        /// </summary>
        private static string YamlFieldBashPathToken = "bash_path";

        /// <summary>
        /// The name of the (top-level, machine-wide) fallback repo path token field.
        /// </summary>
        private static string YamlFieldRepoPathToken = "repo_path";

        /// <summary>
        /// The fully qualified configuration file path. Prefers azure-cli.yml;
        /// falls back to the legacy pr-dash.yml name if that's the only one present.
        /// </summary>
        public static string ConfigPath
        {
            get
            {
                string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                string preferred = Path.Combine(appData, ConfigName);
                if (File.Exists(preferred))
                {
                    return preferred;
                }

                string legacy = Path.Combine(appData, LegacyConfigName);
                if (File.Exists(legacy))
                {
                    return legacy;
                }

                // Neither exists yet: report the preferred (new) name so
                // ValidateConfigExists' error message points at the right file.
                return preferred;
            }
        }

        /// <summary>
        /// Individual configured accounts.
        /// </summary>
        private readonly List<AccountConfig> m_accounts = new List<AccountConfig>();

        /// <summary>
        /// Gets the individual configured accounts.
        /// </summary>
        public IList<AccountConfig> Accounts
        {
            get { return m_accounts; }
        }

        /// <summary>
        /// Gets the accounts grouped by organization Uri.
        /// </summary>
        public IDictionary<Uri, IList<AccountConfig>> AccountsByUri
        {
            get
            {
                IDictionary<Uri, IList<AccountConfig>> dict = new Dictionary<Uri, IList<AccountConfig>>();

                foreach (var account in m_accounts)
                {
                    if (dict.TryGetValue(account.OrganizationUrl!, out IList<AccountConfig>? config))
                    {
                        config.Add(account);
                    }
                    else
                    {
                        config = new List<AccountConfig> { account };
                        dict.Add(account.OrganizationUrl!, config);
                    }
                }

                return dict;
            }
        }

        /// <summary>
        /// Configure if the results should be sorted by recent commit.
        /// </summary>
        /// <remarks>
        /// Has performance impact when fetching lots of PRs.
        /// </remarks>
        public bool SortByRecentCommit { get; }

        /// <summary>
        /// The option to control demo mode.
        /// </summary>
        public bool DemoModeEnabled { get; }

        /// <summary>
        /// Configure if the we want to hide ancient pull requests.
        /// </summary>
        public bool HideAncientPullRequests { get; }

        /// <summary>
        /// Path to a git-bash-compatible bash.exe, used when pr-dash.exe itself
        /// launches the nvim dashboard (so review-pr.sh/wi-*.sh have a bash to
        /// run under, even though pr-dash.exe isn't started from inside one).
        /// Optional: when unset, well-known Git-for-Windows install locations
        /// are probed instead.
        /// </summary>
        public string? BashPath { get; private set; }

        /// <summary>
        /// Legacy top-level fallback local clone path (PRDASH_REPO_PATH),
        /// used by the reviewer before any PR has been opened and per-account
        /// clones_dir isn't configured. Prefer clones_dir on the account instead.
        /// </summary>
        public string? RepoPath { get; private set; }

        /// <summary>
        /// Initializes a new instance of the <see cref="Config"/> class.
        /// </summary>
        /// <param name="options">Command line options which override configuration.</param>
        [SuppressMessage("Usage", "CA1801:Review unused parameters", Justification = "Useful extension point for the future.")]
        public Config(CommandLineOptions? options = null)
        {
            // Sort by recent commits should always be disabled for now.
            //
            SortByRecentCommit = false;

            // Demo mode should always be disabled.
            //
            DemoModeEnabled = false;

            if (options != null)
            {
                DemoModeEnabled = options.DemoMode;
            }
        }

        /// <summary>
        /// Validates that the required configuration file exists, terminates otherwise.
        /// </summary>
        public static void ValidateConfigExists()
        {
            if (!File.Exists(ConfigPath))
            {
                Console.WriteLine("Configuration does not exist: {0}", ConfigPath);
                Environment.Exit(1);
            }
        }

        /// <summary>
        /// Factory function to initializes a new instance of the
        /// <see cref="Config"/> from a Yaml configuration file.
        /// </summary>
        public static Config FromConfigFile(CommandLineOptions? options = null)
        {
            string configFile = ConfigPath;

            // Write to stderr so --list keeps stdout as pure NDJSON.
            Console.Error.WriteLine("Loading configuration from: {0}", configFile);

            return FromFile(configFile, options);
        }

        /// <summary>
        /// Factory function to initializes a new instance of the <see cref="Config"/>
        /// from a Yaml configuration file.
        /// </summary>
        /// <param name="filePath">The file system path to the configuration file.</param>
        public static Config FromFile(string filePath, CommandLineOptions? options = null)
        {
            using (StreamReader reader = new StreamReader(filePath))
            {
                return FromTextReader(reader, options);
            }
        }

        /// <summary>
        /// Factory function to initializes a new instance of the <see cref="Config"/>
        /// from a string with Yaml contents.
        /// </summary>
        /// <param name="yamlPayload">The string with Yaml contents.</param>
        public static Config FromString(string yamlPayload, CommandLineOptions? options = null)
        {
            using (StringReader reader = new StringReader(yamlPayload))
            {
                return FromTextReader(reader, options);
            }
        }

        /// <summary>
        /// Loads the Yaml configuration stream from the specified input.
        /// </summary>
        /// <param name="yamlReader">The input <see cref="TextReader"/>.</param>
        /// <returns>
        /// The populated config object.
        /// </returns>
        private static Config FromTextReader(TextReader yamlReader, CommandLineOptions? options = null)
        {
            Config configuration = new Config(options);
            configuration.LoadYaml(yamlReader);
            return configuration;
        }

        /// <summary>
        /// Loads the Yaml configuration stream from the specified input.
        /// </summary>
        /// <param name="yamlReader">The input.</param>
        private void LoadYaml(TextReader yamlReader)
        {
            // Load the stream from the text reader.
            //
            YamlStream yaml = new YamlStream();
            yaml.Load(yamlReader);

            // Fetch the root of the document.
            //
            var root = (YamlMappingNode)yaml.Documents[0].RootNode;

            // Top-level, machine-wide settings (not per-account).
            //
            if (root.Children.ContainsKey(new YamlScalarNode(YamlFieldBashPathToken)))
            {
                BashPath = root.GetString(YamlFieldBashPathToken);
            }

            if (root.Children.ContainsKey(new YamlScalarNode(YamlFieldRepoPathToken)))
            {
                RepoPath = root.GetString(YamlFieldRepoPathToken);
            }

            // Fetch the root of the accounts list.
            //
            var accountNodes = (YamlSequenceNode)root.Children[new YamlScalarNode(YamlRootAccountsToken)];

            foreach (YamlMappingNode accountNode in accountNodes)
            {
                AccountConfig newAccount = new AccountConfig
                {
                    OrganizationUrl = accountNode.GetUri(YamlFieldOrgUrlToken),
                    Project = accountNode.GetString(YamlFieldProjectToken),
                };

                if (accountNode.Children.ContainsKey(YamlFieldPatToken))
                {
                    newAccount.PersonalAccessToken = accountNode.GetString(YamlFieldPatToken);
                }
                else if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                {
                    throw new ConfigurationErrorsException($"Configuration for project \"{newAccount.Project}\" is missing a PAT token, it is required when running on windows.");
                }

                // Allow commandline to override the config file.
                //
                if (HideAncientPullRequests)
                {
                    newAccount.HideAncientPullRequests = HideAncientPullRequests;
                }
                else
                {
                    if (accountNode.Children.ContainsKey(YamlFieldHideAncientPullRequestsToken))
                    {
                        newAccount.HideAncientPullRequests = accountNode.GetBool(YamlFieldHideAncientPullRequestsToken);
                    }
                }

                if (accountNode.Children.ContainsKey(YamlFieldClonesDirectoryToken))
                {
                    newAccount.ClonesDirectory = accountNode.GetString(YamlFieldClonesDirectoryToken);
                }

                m_accounts.Add(newAccount);
            }
        }
    }
}
