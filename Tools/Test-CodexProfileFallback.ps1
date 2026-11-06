param(
    [string]$DotNetPath = (Join-Path $env:USERPROFILE '.dotnet/dotnet.exe')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $repoRoot 'src/UsageViewer/bin/Release/net10.0-windows'
$assemblyPath = Join-Path $buildPath 'UsageViewer.dll'
if ((Test-Path -LiteralPath $assemblyPath) -eq $false) {
    throw 'Build UsageViewer.csproj in Release before running this check.'
}

# Compile only a protocol fixture/driver against SDK reference assemblies, without a test project or packages.
# The real Release DLL is loaded by reflection; none of the client implementation is copied here.
$probeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

internal static class ProfileFallbackProbe
{
    private static readonly string[] AuthVariables =
    {
        "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_IDENTITY_TOKEN_FILE",
        "OPENAI_FEDERATION_RULE_ID", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"
    };
    private static readonly string PrivateMarker = "SYNTHETIC_PRIVATE_FAILURE";
    private static string _root = "";
    private static string _events = "";
    private static Type _clientType = null!;
    private static int _passed;

    public static async Task<int> Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "app-server")
        {
            return RunFakeCli(args);
        }

        try
        {
            _root = Path.GetFullPath(args[1]);
            _clientType = Assembly.LoadFrom(args[0]).GetType("UsageViewer.Services.CodexUsageClient", true)!;
            await RunChecksAsync();
            Console.WriteLine($"PASS: {_passed} actual-client scenarios; no account or raw RPC output recorded.");
            return 0;
        }
        catch (ProbeAssertionException exception)
        {
            Console.Error.WriteLine("FAIL: " + exception.Message);
            return 1;
        }
        catch (Exception)
        {
            // Never print exception details, private paths, or fixture RPC/stderr content.
            Console.Error.WriteLine("FAIL: actual-client regression check did not complete.");
            return 1;
        }
    }

    private static async Task RunChecksAsync()
    {
        await CheckAsync("dedicated-priority", "ok", "ok", "success", 1);
        await CheckAsync("profile-absent", "ok", "ok", "success", 1, profileExists: false);
        await CheckAsync("default-home-unset", "ok", "ok", "success", 1, profileExists: false, customHome: false);
        await CheckAsync("refresh-fallback", "account-error", "ok", "success", 2);
        await CheckAsync("401-fallback", "limits-error", "ok", "success", 2);
        await CheckAsync("fallback-home-unset", "account-error", "ok", "success", 2, customHome: false);
        await CheckAsync("initialize-fallback", "initialize-error", "ok", "success", 2);
        await CheckAsync("disconnected-fallback", "exit", "ok", "success", 2);
        await CheckAsync("malformed-dedicated", "json-error", "ok", "success", 2);
        await CheckAsync("dedicated-not-logged-in", "no-account", "ok", "success", 2);
        await CheckAsync("dedicated-api-key", "api-key", "ok", "success", 2);
        await CheckAsync("dedicated-invalid-limits", "invalid-limits", "ok", "success", 2);
        await CheckAsync("both-processes-force-stopped", "account-error", "ok", "success", 2, hold: true);

        foreach (string failure in new[] { "account-error", "limits-error", "exit", "no-account", "api-key",
                                          "json-error", "account-shape", "plan-shape", "missing-limits",
                                          "invalid-limits", "invalid-result" })
        {
            await CheckAsync("default-failure-" + failure, "account-error", failure, "error", 2);
        }

        await CheckAsync("direct-default-failure", "ok", "limits-error", "error", 1, profileExists: false);
        await CheckAsync("connect-creates-profile", "ok", "ok", "success", 1, profileExists: false, connect: true);
        await CheckAsync("connect-start-failed", "login-error", "ok", "error", 1, connect: true);
        await CheckAsync("connect-completion-failed", "login-failed", "ok", "error", 1, connect: true);
        await CheckAsync("connect-account-failed", "account-error", "ok", "error", 1, connect: true);
        await CheckAsync("connect-limits-failed", "limits-error", "ok", "error", 1, connect: true);
        await CheckAsync("connect-user-cancel", "ok", "ok", "cancel", 1, connect: true, cancelAt: "authorization");
        await CheckAsync("already-cancelled", "ok", "ok", "cancel", 0, cancelAt: "before");
        await CheckAsync("dedicated-user-cancel", "hang", "ok", "cancel", 1, cancelAt: "dedicated:account/read");
        await CheckAsync("between-attempts-cancel", "account-error", "ok", "cancel", 1,
                         cancelAt: "dedicated:account/read", hold: true);
        await CheckAsync("default-user-cancel", "account-error", "hang", "cancel", 2,
                         cancelAt: "default:account/read", hold: true);
        await CheckAsync("dedicated-timeout-no-fallback", "hang", "ok", "timeout", 1);
        // The first attempt spends 20s, then fails. A separate second 30s budget would fail this assertion.
        await CheckAsync("shared-30-second-timeout", "slow-error", "hang", "timeout", 2, hold: true);
    }

    private static async Task CheckAsync(string name, string dedicated, string fallback, string expected, int starts,
                                        bool profileExists = true, bool connect = false, string? cancelAt = null,
                                        bool hold = false, bool customHome = true)
    {
        string caseRoot = Path.Combine(_root, name);
        Directory.CreateDirectory(caseRoot);
        string profile = Path.Combine(caseRoot, "dedicated");
        string defaultHome = Path.Combine(caseRoot, "default");
        Directory.CreateDirectory(defaultHome);
        if (profileExists == true)
        {
            Directory.CreateDirectory(profile);
        }

        _events = Path.Combine(caseRoot, "events.txt");
        Environment.SetEnvironmentVariable("UV_TEST_EVENTS", _events);
        Environment.SetEnvironmentVariable("UV_TEST_PROFILE", profile);
        Environment.SetEnvironmentVariable("UV_TEST_DEFAULT", customHome == true ? defaultHome : "");
        Environment.SetEnvironmentVariable("UV_TEST_DEDICATED", dedicated);
        Environment.SetEnvironmentVariable("UV_TEST_FALLBACK", fallback);
        Environment.SetEnvironmentVariable("UV_TEST_HOLD", hold == true ? "yes" : "no");
        Environment.SetEnvironmentVariable("CODEX_HOME", customHome == true ? defaultHome : null);
        string cliPath = Path.Combine(_root, "UsageViewer.exe");
        Environment.SetEnvironmentVariable("USAGEVIEWER_CODEX_PATH", cliPath);
        using CancellationTokenSource cancellation = new CancellationTokenSource();
        if (cancelAt == "before")
        {
            cancellation.Cancel();
        }

        object client = Activator.CreateInstance(_clientType, new object?[] { profile })!;
        int authorizationCount = 0;
        Action<Uri> authorize = uri =>
        {
            Require(uri.Host == "auth.openai.com", "unexpected authorization URL");
            authorizationCount++;
            if (cancelAt == "authorization")
            {
                cancellation.Cancel();
            }
        };
        Stopwatch elapsed = Stopwatch.StartNew();
        try
        {
            Task task = (Task)_clientType.GetMethod(connect == true ? "ConnectAsync" : "ReadAsync")!
                .Invoke(client, connect == true ? new object[] { authorize, cancellation.Token } :
                                                  new object[] { cancellation.Token })!;
            if (cancelAt != null && cancelAt.Contains(':') == true)
            {
                await WaitForEventAsync(cancelAt, task);
                cancellation.Cancel();
            }

            string outcome = "success";
            object? snapshot = null;
            try
            {
                await task.WaitAsync(TimeSpan.FromSeconds(38));
                snapshot = task.GetType().GetProperty("Result")!.GetValue(task);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested == true)
            {
                outcome = "cancel";
            }
            catch (Exception exception) when (exception.GetType().FullName == "UsageViewer.Models.UsageQueryException")
            {
                Require(exception.Message.Contains(PrivateMarker) == false && exception.InnerException == null,
                        "provider failure leaked");
                outcome = exception.Message.Contains("시간이 초과") == true ? "timeout" : "error";
            }

            Require(outcome == expected, "unexpected outcome");
            string[] events = ReadEvents();
            string[] launches = events.Where(line => line.StartsWith("start:")).ToArray();
            Require(launches.Length == starts, "unexpected process count");
            Require(events.Any(line => line == "invalid") == false, "environment or RPC contract mismatch");
            Require(events.Any(line => line.Contains("account/login/start")) == (connect == true && starts > 0),
                    "unexpected login request");
            if (starts > 0)
            {
                string first = connect == true || profileExists == true ? "dedicated" : "default";
                Require(launches[0].StartsWith("start:" + first + ":"), "incorrect first profile");
            }
            if (starts == 2)
            {
                Require(launches[1].StartsWith("start:default:"), "incorrect fallback profile");
            }
            if (outcome == "success")
            {
                Require(snapshot != null, "missing snapshot");
                string plan = (string)snapshot!.GetType().GetProperty("PlanName")!.GetValue(snapshot)!;
                string expectedPlan = starts == 2 || (profileExists == false && connect == false) ? "default" : "dedicated";
                Require(plan == expectedPlan, "snapshot came from incorrect context");
                object buckets = snapshot.GetType().GetProperty("Buckets")!.GetValue(snapshot)!;
                object bucket = ((System.Collections.IEnumerable)buckets).Cast<object>().Single();
                object window = bucket.GetType().GetProperty("Primary")!.GetValue(bucket)!;
                Require((double)window.GetType().GetProperty("UsedPercent")!.GetValue(window)! == 37,
                        "real parser returned incorrect percentage");
            }
            if (expected == "timeout")
            {
                Require(elapsed.Elapsed.TotalSeconds >= 29 && elapsed.Elapsed.TotalSeconds < 36,
                        "overall timeout was reset or exceeded");
            }
            if (expected == "cancel")
            {
                Require(elapsed.Elapsed.TotalSeconds < 8, "cancellation did not finish promptly");
            }
            Require(authorizationCount == (connect == true && dedicated != "login-error" ? 1 : 0),
                    "unexpected authorization callback");
            Require(Directory.Exists(profile) == (profileExists == true || connect == true), "profile selection mutated disk");
            Require(Environment.GetEnvironmentVariable("CODEX_HOME") == (customHome == true ? defaultHome : null) &&
                    Environment.GetEnvironmentVariable("USAGEVIEWER_CODEX_PATH") == cliPath &&
                    AuthVariables.All(variable => Environment.GetEnvironmentVariable(variable) == "fixture-only"),
                    "parent process environment changed");
            foreach (string launch in launches)
            {
                Require(IsRunning(int.Parse(launch.Split(':')[2])) == false, "child process left running");
            }
            _passed++;
            Console.WriteLine("PASS: " + name);
        }
        catch (Exception)
        {
            Console.Error.WriteLine("FAIL: " + name);
            throw;
        }
        finally
        {
            cancellation.Cancel();
            // Only fixture processes recorded in this case are eligible for emergency cleanup.
            foreach (string launch in ReadEvents().Where(line => line.StartsWith("start:")))
            {
                int processId = int.Parse(launch.Split(':')[2]);
                if (IsRunning(processId) == true)
                {
                    using Process child = Process.GetProcessById(processId);
                    child.Kill(entireProcessTree: true);
                    await child.WaitForExitAsync();
                }
            }
        }
    }

    private static async Task WaitForEventAsync(string expected, Task query)
    {
        Stopwatch wait = Stopwatch.StartNew();
        while (ReadEvents().Contains(expected) == false)
        {
            Require(query.IsCompleted == false && wait.Elapsed.TotalSeconds < 6, "cancellation trigger missing");
            await Task.Delay(10);
        }
    }

    private static string[] ReadEvents()
    {
        if (File.Exists(_events) == false)
        {
            return Array.Empty<string>();
        }

        using FileStream stream = new FileStream(_events, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using StreamReader reader = new StreamReader(stream);
        return reader.ReadToEnd().Split(new[] { Environment.NewLine }, StringSplitOptions.RemoveEmptyEntries);
    }

    private static bool IsRunning(int processId)
    {
        try
        {
            using Process process = Process.GetProcessById(processId);
            return process.HasExited == false;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static void Require(bool condition, string description)
    {
        if (condition == false)
        {
            throw new ProbeAssertionException(description);
        }
    }

    private static int RunFakeCli(string[] args)
    {
        Console.InputEncoding = Encoding.UTF8;
        Console.OutputEncoding = new UTF8Encoding(false);
        _events = Environment.GetEnvironmentVariable("UV_TEST_EVENTS")!;
        bool isolated = Environment.GetEnvironmentVariable("CODEX_HOME") == Environment.GetEnvironmentVariable("UV_TEST_PROFILE");
        string role = isolated == true ? "dedicated" : "default";
        string scenario = Environment.GetEnvironmentVariable(isolated == true ? "UV_TEST_DEDICATED" : "UV_TEST_FALLBACK")!;
        string? inheritedHome = Environment.GetEnvironmentVariable("UV_TEST_DEFAULT");
        bool valid = isolated == true ?
            AuthVariables.All(variable => Environment.GetEnvironmentVariable(variable) == null) &&
            args.SequenceEqual(new[] { "app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\"" }) :
            AuthVariables.All(variable => Environment.GetEnvironmentVariable(variable) == "fixture-only") &&
            (Environment.GetEnvironmentVariable("CODEX_HOME") ?? "") == (inheritedHome ?? "") &&
            args.SequenceEqual(new[] { "app-server", "--listen", "stdio://" });
        if (role == "default" && ReadEvents().Where(line => line.StartsWith("start:"))
            .Any(line => IsRunning(int.Parse(line.Split(':')[2]))) == true)
        {
            Event("invalid");
        }
        Event("start:" + role + ":" + Environment.ProcessId);
        if (valid == false)
        {
            Event("invalid");
        }
        // Exercise stderr draining without ever recording its content.
        Console.Error.Write(new string('x', 80000) + PrivateMarker);
        string? line;
        while ((line = Console.ReadLine()) != null)
        {
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement request = document.RootElement;
            string method = request.GetProperty("method").GetString()!;
            Event(role + ":" + method);
            if (new[] { "initialize", "initialized", "account/read", "account/rateLimits/read", "account/login/start" }
                .Contains(method) == false)
            {
                Event("invalid");
                return 1;
            }
            if (method == "initialized")
            {
                continue;
            }
            int id = request.GetProperty("id").GetInt32();
            if ((method == "account/read" && (scenario == "account-error" || scenario == "slow-error")) ||
                (method == "account/rateLimits/read" && scenario == "limits-error") ||
                (method == "initialize" && scenario == "initialize-error") ||
                (method == "account/login/start" && scenario == "login-error"))
            {
                if (scenario == "slow-error")
                {
                    Thread.Sleep(20000);
                }
                Reply(new { id, error = new { code = -32000, message = PrivateMarker + " refresh failed HTTP 401" } });
            }
            else if (method == "initialize")
            {
                Reply(new { id, result = new { } });
            }
            else if (method == "account/login/start")
            {
                Reply(new { id, result = new { loginId = "fixture", authUrl = "https://auth.openai.com/fixture" } });
                Reply(new { method = "account/login/completed",
                            @params = new { loginId = "fixture", success = scenario != "login-failed", error = PrivateMarker } });
            }
            else if (method == "account/read")
            {
                if (request.GetProperty("params").GetProperty("refreshToken").GetBoolean() == true)
                {
                    Event("invalid");
                }
                if (scenario == "hang")
                {
                    Thread.Sleep(Timeout.Infinite);
                }
                if (scenario == "exit")
                {
                    return 1;
                }
                if (scenario == "json-error")
                {
                    Console.WriteLine("invalid-json-" + PrivateMarker);
                    continue;
                }
                object? account = scenario switch
                {
                    "no-account" => null,
                    "api-key" => new { type = "apiKey" },
                    "account-shape" => new { type = 123 },
                    "plan-shape" => new { type = "chatgpt", planType = 123 },
                    _ => new { type = "chatgpt", planType = role }
                };
                Reply(new { id, result = new { account } });
            }
            else if (method == "account/rateLimits/read")
            {
                if (scenario == "invalid-result")
                {
                    Reply(new { id, result = (object?)null });
                }
                else if (scenario == "missing-limits")
                {
                    Reply(new { id, result = new { } });
                }
                else
                {
                    Reply(new { id, result = new { rateLimits = new
                    {
                        limitId = "codex", primary = new { usedPercent = scenario == "invalid-limits" ? -1 : 37,
                                                           windowDurationMins = 300, resetsAt = 2000000000 }
                    } } });
                }
            }
        }
        if (Environment.GetEnvironmentVariable("UV_TEST_HOLD") == "yes")
        {
            Thread.Sleep(Timeout.Infinite);
        }
        return 0;
    }

    private static void Reply(object message)
    {
        Console.WriteLine(JsonSerializer.Serialize(message));
    }

    private static void Event(string value)
    {
        File.AppendAllText(_events, value + Environment.NewLine);
    }
}

internal sealed class ProbeAssertionException : Exception
{
    public ProbeAssertionException(string message) : base(message)
    {
    }
}
'@

$artifactRoot = Join-Path $repoRoot '.artifacts'
$tempRoot = Join-Path $artifactRoot ('CodexProfileFallback-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $sdkLines = & $DotNetPath --list-sdks
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate the configured .NET SDK.' }
    $sdkLine = $sdkLines | Where-Object { $_ -match '^10\.\S+ \[' } | Select-Object -Last 1
    if ($sdkLine -notmatch '^(\S+) \[(.+)\]$') { throw '.NET 10 SDK is required.' }
    $sdkPath = Join-Path $Matches[2] $Matches[1]
    $dotNetRoot = Split-Path (Split-Path $sdkPath -Parent) -Parent
    $referencePack = Get-ChildItem -LiteralPath (Join-Path $dotNetRoot 'packs/Microsoft.NETCore.App.Ref') -Directory |
        Where-Object { $_.Name -like '10.*' } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    $sourcePath = Join-Path $tempRoot 'Probe.cs'
    $responsePath = Join-Path $tempRoot 'compile.rsp'
    $probePath = Join-Path $tempRoot 'Probe.dll'
    Set-Content -LiteralPath $sourcePath -Value $probeSource -Encoding utf8
    $compileArguments = @('-nologo', '-target:exe', '-nullable:enable', '-warnaserror+', '-langversion:latest',
                          ('-out:"' + $probePath + '"'))
    $compileArguments += Get-ChildItem -LiteralPath (Join-Path $referencePack.FullName 'ref/net10.0') -Filter '*.dll' |
        ForEach-Object { '-r:"' + $_.FullName + '"' }
    $compileArguments += '"' + $sourcePath + '"'
    Set-Content -LiteralPath $responsePath -Value $compileArguments -Encoding utf8
    $compilerOutput = & $DotNetPath exec (Join-Path $sdkPath 'Roslyn/bincore/csc.dll') ('@' + $responsePath) 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Compiler diagnostics concern only the synthetic driver; replace absolute local paths before printing.
        $compilerOutput | ForEach-Object { $_.ToString().Replace($tempRoot, '<fixture>') }
        throw 'Could not compile the protocol fixture.'
    }

    # Reuse the built native apphost: its embedded filename remains UsageViewer.dll, whose assembly name is Probe.
    Copy-Item -LiteralPath $probePath -Destination (Join-Path $tempRoot 'UsageViewer.dll')
    Copy-Item -LiteralPath (Join-Path $buildPath 'UsageViewer.exe') -Destination $tempRoot
    Copy-Item -LiteralPath (Join-Path $buildPath 'UsageViewer.runtimeconfig.json') -Destination $tempRoot
    $driver = [System.Diagnostics.ProcessStartInfo]::new($DotNetPath)
    $driver.UseShellExecute = $false
    $driver.CreateNoWindow = $true
    $driver.RedirectStandardOutput = $true
    $driver.RedirectStandardError = $true
    foreach ($argument in @('exec', '--runtimeconfig', (Join-Path $buildPath 'UsageViewer.runtimeconfig.json'),
                            $probePath, $assemblyPath, $tempRoot)) {
        $driver.ArgumentList.Add($argument)
    }
    # Set only synthetic credentials in this child. Never read or change the caller's credential variables.
    foreach ($variable in @('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'OPENAI_IDENTITY_TOKEN_FILE',
                            'OPENAI_FEDERATION_RULE_ID', 'OPENAI_WORKLOAD_IDENTITY_CONTEXT')) {
        $driver.Environment[$variable] = 'fixture-only'
    }
    $driver.Environment['DOTNET_ROOT'] = $dotNetRoot
    $process = [System.Diagnostics.Process]::Start($driver)
    try {
        $errorRead = $process.StandardError.ReadToEndAsync()
        while (($line = $process.StandardOutput.ReadLine()) -ne $null) {
            Write-Output $line
        }
        $process.WaitForExit()
        $errorRead.GetAwaiter().GetResult() -split '\r?\n' |
            Where-Object { $_.StartsWith('FAIL: ') } | ForEach-Object { Write-Output $_ }
        if ($process.ExitCode -ne 0) { throw "Actual-client regression checks failed (exit $($process.ExitCode))." }
    }
    finally {
        $process.Dispose()
    }
}
finally {
    # Delete only this invocation's generated fixture directory, after verifying its resolved workspace boundary.
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedArtifacts = [System.IO.Path]::GetFullPath($artifactRoot) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedTemp.StartsWith($resolvedArtifacts, [System.StringComparison]::OrdinalIgnoreCase) -eq $false -or
        (Split-Path $resolvedTemp -Leaf) -notlike 'CodexProfileFallback-*') {
        throw 'Fixture cleanup path is outside the expected workspace artifact directory.'
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
