using System.Text.Json;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--diagnose")
        {
            return RunDiagnosticAsync(args[1]).GetAwaiter().GetResult();
        }

        ApplicationConfiguration.Initialize();
        using EventWaitHandle showSignal = new EventWaitHandle(false, EventResetMode.AutoReset,
                                                               @"Local\UsageViewer.Show.8BE614F9");
        using Mutex mutex = new Mutex(true, @"Local\UsageViewer.Tray.8BE614F9", out bool firstInstance);
        if (firstInstance == false)
        {
            showSignal.Set();

            return 0;
        }

        using TrayApplicationContext context = new TrayApplicationContext(args.Contains("--show"), showSignal);
        Application.Run(context);
        mutex.ReleaseMutex();

        return 0;
    }

    private static async Task<int> RunDiagnosticAsync(string outputPath)
    {
        object report;
        int exitCode;
        try
        {
            CodexUsageClient client = new CodexUsageClient();
            UsageSnapshot snapshot = await client.ReadAsync(CancellationToken.None);
            report = new
            {
                success = true,
                retrievedAt = snapshot.RetrievedAt,
                bucketCount = snapshot.Buckets.Count,
                creditsProvided = snapshot.Buckets.Any(bucket => bucket.Credits != null),
                creditBalanceProvided = snapshot.Buckets.Any(bucket => bucket.Credits?.Balance != null),
                windows = snapshot.Buckets.SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary })
                    .Where(window => window != null)
                    .Select(window => new { window!.DurationMinutes, window.ResetsAt, validPercent = true }).ToArray()
            };
            exitCode = 0;
        }
        catch (Exception exception)
        {
            report = new
            {
                success = false,
                error = exception is UsageQueryException ? exception.Message : "진단에 실패했습니다. 실행 환경을 확인해 주세요."
            };
            exitCode = 1;
        }

        string fullPath = Path.GetFullPath(outputPath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        string json = JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true });
        await File.WriteAllTextAsync(fullPath, json);

        return exitCode;
    }
}
