using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Win32;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed record DetectedAiApp(string Id, string Name, bool UsageSupported);

internal sealed class AiInstallationDetector
{
    public IReadOnlyList<DetectedAiApp> Detect()
    {
        List<DetectedAiApp> installed = new List<DetectedAiApp>();
        List<string> registered = ReadRegisteredNames();
        bool codex = false;
        try
        {
            codex = File.Exists(new CodexExecutableLocator().Find());
        }
        catch (Exception exception) when (exception is UsageQueryException || exception is IOException ||
                                          exception is UnauthorizedAccessException)
        {
        }

        if (codex == true || registered.Any(name => Matches(name, "Codex")) == true)
        {
            installed.Add(new DetectedAiApp("codex", "Codex", true));
        }

        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (OnPath("claude") == true || File.Exists(Path.Combine(home, ".local", "bin", "claude.exe")) == true ||
            registered.Any(name => Matches(name, "Claude")) == true || IsClaudeDesktopRunning() == true)
        {
            installed.Add(new DetectedAiApp("claude", "Claude", true));
        }

        if (OnPath("gemini") == true || registered.Any(name => Matches(name, "Google Gemini") || Matches(name, "Gemini CLI")) == true)
        {
            installed.Add(new DetectedAiApp("gemini", "Gemini", false));
        }

        if (OnPath("cursor") == true || File.Exists(Path.Combine(local, "Programs", "cursor", "Cursor.exe")) == true ||
            registered.Any(name => Matches(name, "Cursor")) == true)
        {
            installed.Add(new DetectedAiApp("cursor", "Cursor", false));
        }

        if (OnPath("copilot") == true || registered.Any(name => Matches(name, "GitHub Copilot")) == true)
        {
            installed.Add(new DetectedAiApp("copilot", "Copilot", false));
        }

        return installed;
    }

    private bool OnPath(string command)
    {
        string paths = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string entry in paths.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (string extension in new[] { ".exe", ".cmd", ".ps1" })
            {
                if (File.Exists(Path.Combine(entry.Trim().Trim('"'), command + extension)) == true)
                {
                    return true;
                }
            }
        }

        return false;
    }

    private bool Matches(string displayName, string product)
    {
        return displayName.Equals(product, StringComparison.OrdinalIgnoreCase) == true ||
               displayName.StartsWith(product + " ", StringComparison.OrdinalIgnoreCase) == true;
    }

    private List<string> ReadRegisteredNames()
    {
        List<string> names = new List<string>();
        foreach (RegistryKey root in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            foreach (string path in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                                            @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
            {
                try
                {
                    using RegistryKey? uninstall = root.OpenSubKey(path);
                    if (uninstall == null)
                    {
                        continue;
                    }

                    foreach (string keyName in uninstall.GetSubKeyNames())
                    {
                        using RegistryKey? item = uninstall.OpenSubKey(keyName);
                        if (item?.GetValue("DisplayName") is string name)
                        {
                            names.Add(name);
                        }
                    }
                }
                catch (Exception exception) when (exception is UnauthorizedAccessException ||
                                                  exception is System.Security.SecurityException || exception is IOException)
                {
                }
            }
        }

        return names;
    }

    private bool IsClaudeDesktopRunning()
    {
        foreach (Process process in Process.GetProcessesByName("claude"))
        {
            using (process)
            {
                try
                {
                    string path = process.MainModule?.FileName ?? "";
                    if (path.Contains(@"\WindowsApps\Claude_", StringComparison.OrdinalIgnoreCase) == true ||
                        path.Contains(@"\Programs\Claude\", StringComparison.OrdinalIgnoreCase) == true)
                    {
                        return true;
                    }
                }
                catch (Exception exception) when (exception is Win32Exception || exception is InvalidOperationException)
                {
                }
            }
        }

        return false;
    }
}
