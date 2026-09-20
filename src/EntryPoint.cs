using CommandLine;
using AzureCli.Configuration;
using AzureCli.DataSource;
using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace AzureCli
{
    /// <summary>
    /// The class entry point for the program. This is a headless data provider
    /// (NDJSON list + build re-queue) for the nvim-based dashboard; it has no
    /// interactive UI of its own.
    /// </summary>
    public static class EntryPoint
    {
        /// <summary>
        /// The program entry point for azure-cli.
        /// </summary>
        /// <param name="args">The raw command line arguments.</param>
        /// <returns>The process exit code.</returns>
        public static int Main(string[] args)
        {
            var options = Parser.Default.ParseArguments<CommandLineOptions>(args);

            return options.MapResult(
                options => RunAndReturnExitCode(options),
                _ => 1);
        }

        /// <summary>
        /// The post command line option parsing entry point.
        /// </summary>
        /// <param name="options">The parsed command line options.</param>
        /// <returns>The process exit code.</returns>
        private static int RunAndReturnExitCode(CommandLineOptions options)
        {
            Config.ValidateConfigExists();
            Config config = Config.FromConfigFile(options);

            IPullRequestSource source;
            if (config.DemoModeEnabled)
            {
                source = new DemoPullRequestSource();
            }
            else
            {
                source = new AzureDevOpsPullRequestSource(config);
            }

            // Headless mode: emit the PRs as NDJSON and exit.
            if (options.List)
            {
                try
                {
                    PullRequestListWriter.WriteAsync(source, Console.Out).GetAwaiter().GetResult();
                    return 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("azure-cli --list failed: " + ex.Message);
                    Console.Error.WriteLine(ex);
                    return 1;
                }
            }

            // Headless mode: re-queue build validation for a PR and exit.
            if (options.Requeue.HasValue)
            {
                try
                {
                    string result = source.RequeueBuildValidationAsync(options.Requeue.Value).GetAwaiter().GetResult();
                    Console.Out.WriteLine(result);
                    return 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("azure-cli --requeue failed: " + ex.Message);
                    Console.Error.WriteLine(ex);
                    return 1;
                }
            }

            // Headless mode: print the configured PAT for --org/--project and exit.
            // Lets shell scripts resolve credentials from the config file instead of
            // needing their own copy of the PAT in an environment variable.
            if (options.PrintPat)
            {
                if (string.IsNullOrEmpty(options.Org))
                {
                    Console.Error.WriteLine("azure-cli --print-pat requires --org <organization-url>.");
                    return 1;
                }

                string wantOrg = options.Org.TrimEnd('/');
                foreach (AccountConfig account in config.Accounts)
                {
                    bool orgMatches = string.Equals(
                        account.OrganizationUrl?.ToString().TrimEnd('/'), wantOrg, StringComparison.OrdinalIgnoreCase);
                    bool projectMatches = string.IsNullOrEmpty(options.Project)
                        || string.Equals(account.Project, options.Project, StringComparison.OrdinalIgnoreCase);

                    if (orgMatches && projectMatches)
                    {
                        if (string.IsNullOrEmpty(account.PersonalAccessToken))
                        {
                            Console.Error.WriteLine("azure-cli --print-pat: matching account has no 'pat' configured.");
                            return 1;
                        }

                        Console.Out.Write(account.PersonalAccessToken);
                        return 0;
                    }
                }

                Console.Error.WriteLine($"azure-cli --print-pat: no account matches org '{options.Org}'"
                    + (string.IsNullOrEmpty(options.Project) ? "." : $" and project '{options.Project}'."));
                return 1;
            }

            // Headless mode: print the authenticated identity (id + display name)
            // for --org/--project as JSON and exit. Lets the nvim reviewer tell
            // "my" comments/PRs apart from everyone else's.
            if (options.WhoAmI)
            {
                if (string.IsNullOrEmpty(options.Org))
                {
                    Console.Error.WriteLine("azure-cli --whoami requires --org <organization-url>.");
                    return 1;
                }

                try
                {
                    UserIdentity? identity = source.WhoAmIAsync(options.Org, options.Project).GetAwaiter().GetResult();
                    if (identity == null)
                    {
                        Console.Error.WriteLine($"azure-cli --whoami: no account matches org '{options.Org}'"
                            + (string.IsNullOrEmpty(options.Project) ? "." : $" and project '{options.Project}'."));
                        return 1;
                    }

                    Console.Out.WriteLine(JsonSerializer.Serialize(new { id = identity.Id, displayName = identity.DisplayName }));
                    return 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("azure-cli --whoami failed: " + ex.Message);
                    return 1;
                }
            }

            // No recognized headless flag: launch the nvim dashboard directly,
            // so `azure-cli.exe` alone is enough to run the whole tool.
            return LaunchDashboard(config);
        }

        /// <summary>
        /// Launches the nvim-based dashboard (azure-cli.lua), wiring up the
        /// environment variables it and its helper shell scripts need, reading
        /// machine-specific bits (bash_path, repo_path) from the config file.
        /// </summary>
        /// <param name="config">The loaded configuration.</param>
        /// <returns>nvim's exit code, or 1 if it couldn't be launched.</returns>
        private static int LaunchDashboard(Config config)
        {
            string? exePath = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exePath))
            {
                Console.Error.WriteLine("azure-cli: could not determine my own executable path; "
                    + "use --list, --requeue <id>, or --print-pat instead.");
                return 1;
            }

            string? repoRoot = FindRepoRoot(Path.GetDirectoryName(exePath));
            if (repoRoot == null)
            {
                Console.Error.WriteLine("azure-cli: could not find azure-cli.lua near " + exePath + ". "
                    + "Keep azure-cli.exe under its repo's build output, or use --list/--requeue/--print-pat.");
                return 1;
            }

            string luaEntry = Path.Combine(repoRoot, "azure-cli.lua").Replace('\\', '/');
            string reviewScript = Path.Combine(repoRoot, "review-pr.sh");
            string wiList = Path.Combine(repoRoot, "wi-list.sh");
            string wiDetail = Path.Combine(repoRoot, "wi-detail.sh");

            string? bashPath = ResolveBashPath(config);
            if (bashPath == null)
            {
                Console.Error.WriteLine("azure-cli: could not find a bash.exe for review-pr.sh/wi-*.sh to run under. "
                    + "Add 'bash_path: C:\\Path\\To\\Git\\bin\\bash.exe' to the config file.");
                return 1;
            }

            var psi = new ProcessStartInfo
            {
                FileName = "nvim",
                UseShellExecute = false,
            };
            psi.ArgumentList.Add("-u");
            psi.ArgumentList.Add("NONE");
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add("luafile " + luaEntry);

            // Config is the single source of truth: always use the resolved
            // values below, regardless of anything already exported in the
            // caller's shell (no ambient PRDASH_*/WIDASH_* env var overrides).
            psi.EnvironmentVariables["PRDASH_EXE"] = exePath;
            psi.EnvironmentVariables["PRDASH_SCRIPT"] = reviewScript;
            psi.EnvironmentVariables["PRDASH_BASH"] = bashPath;
            psi.EnvironmentVariables["WIDASH_LIST"] = wiList;
            psi.EnvironmentVariables["WIDASH_DETAIL"] = wiDetail;
            if (!string.IsNullOrEmpty(config.RepoPath))
            {
                psi.EnvironmentVariables["PRDASH_REPO_PATH"] = config.RepoPath;
            }
            else
            {
                // Make sure a stray inherited PRDASH_REPO_PATH from the
                // caller's shell doesn't leak through either.
                psi.EnvironmentVariables.Remove("PRDASH_REPO_PATH");
            }

            try
            {
                using Process? proc = Process.Start(psi);
                if (proc == null)
                {
                    Console.Error.WriteLine("azure-cli: failed to start nvim.");
                    return 1;
                }

                proc.WaitForExit();
                return proc.ExitCode;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("azure-cli: failed to launch nvim (is it on PATH?): " + ex.Message);
                return 1;
            }
        }

        /// <summary>
        /// Walks up from <paramref name="startDir"/> looking for azure-cli.lua,
        /// to find the repo root regardless of Debug/Release/publish output layout.
        /// </summary>
        private static string? FindRepoRoot(string? startDir)
        {
            string? dir = startDir;
            for (int i = 0; i < 8 && dir != null; i++)
            {
                if (File.Exists(Path.Combine(dir, "azure-cli.lua")))
                {
                    return dir;
                }

                dir = Path.GetDirectoryName(dir);
            }

            return null;
        }

        /// <summary>
        /// Resolves a git-bash-compatible bash.exe: the configured bash_path
        /// from the config file, then well-known Git-for-Windows install
        /// locations as a last resort. No env var input - config is the
        /// only source, so an ambient PRDASH_BASH never silently changes
        /// which bash gets used.
        /// </summary>
        private static string? ResolveBashPath(Config config)
        {
            string?[] candidates =
            {
                config.BashPath,
                @"C:\Program Files\Git\bin\bash.exe",
                @"C:\Program Files\Git\usr\bin\bash.exe",
                Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Programs", "Git", "bin", "bash.exe"),
            };

            foreach (string? candidate in candidates)
            {
                if (!string.IsNullOrEmpty(candidate) && File.Exists(candidate))
                {
                    return candidate;
                }
            }

            return null;
        }
    }
}
