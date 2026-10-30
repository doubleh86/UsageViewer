using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class CodexExecutableLocator
{
    public string Find()
    {
        string? configuredPath = Environment.GetEnvironmentVariable("USAGEVIEWER_CODEX_PATH");
        if (string.IsNullOrWhiteSpace(configuredPath) == false)
        {
            if (IsExecutable(configuredPath) == false)
            {
                throw new UsageQueryException("USAGEVIEWER_CODEX_PATH에 유효한 codex.exe 경로를 지정해 주세요.");
            }

            return Path.GetFullPath(configuredPath);
        }

        // Desktop bundles are native executables; .cmd/.ps1 launchers are never run through a shell.
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string desktopBin = Path.Combine(localAppData, "OpenAI", "Codex", "bin");
        if (Directory.Exists(desktopBin) == true)
        {
            string directPath = Path.Combine(desktopBin, "codex.exe");
            if (IsExecutable(directPath) == true)
            {
                return directPath;
            }

            try
            {
                string? bundledPath = Directory.EnumerateDirectories(desktopBin)
                    .Select(directory => new FileInfo(Path.Combine(directory, "codex.exe")))
                    .Where(file => file.Exists).OrderByDescending(file => file.LastWriteTimeUtc)
                    .Select(file => file.FullName).FirstOrDefault();
                if (bundledPath != null)
                {
                    return bundledPath;
                }
            }
            catch (UnauthorizedAccessException)
            {
                // Continue with PATH/npm discovery if this installation cannot be inspected.
            }
            catch (IOException)
            {
                // An app update can replace a bundle while it is being enumerated.
            }
        }

        string pathValue = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string directory in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(directory.Trim().Trim('"'), "codex.exe");
            if (IsExecutable(candidate) == true)
            {
                return candidate;
            }
        }

        string roamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string platform = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture ==
                          System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
        string target = platform == "arm64" ? "aarch64-pc-windows-msvc" : "x86_64-pc-windows-msvc";
        string npmRoot = Path.Combine(roamingAppData, "npm", "node_modules", "@openai", "codex");
        string[] npmCandidates =
        {
            Path.Combine(npmRoot, "node_modules", "@openai", $"codex-win32-{platform}", "vendor", target, "codex", "codex.exe"),
            Path.Combine(npmRoot, "vendor", target, "codex", "codex.exe")
        };
        foreach (string candidate in npmCandidates)
        {
            if (IsExecutable(candidate) == true)
            {
                return candidate;
            }
        }

        throw new UsageQueryException("Codex CLI를 찾지 못했습니다. Codex를 설치하거나 실행 파일 경로를 지정해 주세요.");
    }

    private bool IsExecutable(string path)
    {
        return Path.IsPathFullyQualified(path) == true &&
               string.Equals(Path.GetExtension(path), ".exe", StringComparison.OrdinalIgnoreCase) == true &&
               File.Exists(path) == true;
    }
}
