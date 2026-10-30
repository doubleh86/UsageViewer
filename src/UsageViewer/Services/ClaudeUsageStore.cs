using System.Text;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed record ClaudeUsageCache(DateTimeOffset CapturedAt, UsageWindow? FiveHour, UsageWindow? SevenDay);

internal sealed record ClaudeUsageReadResult(UsageSnapshot Snapshot, bool IsStale);

internal sealed class ClaudeUsageStore
{
    private readonly string _path;

    public ClaudeUsageStore(string? path = null)
    {
        _path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                     "UsageViewer", "claude-usage.json");
    }

    public async Task<string> CaptureAsync(TextReader input, CancellationToken cancellationToken)
    {
        // The full status-line input also includes session IDs and transcript paths. Never persist it.
        StringBuilder text = new StringBuilder();
        char[] buffer = new char[4096];
        int count;
        while ((count = await input.ReadAsync(buffer.AsMemory(), cancellationToken)) > 0)
        {
            if (text.Length + count > 1_048_576)
            {
                throw new UsageQueryException("Claude 상태 입력이 너무 큽니다.");
            }

            text.Append(buffer, 0, count);
        }

        using JsonDocument document = JsonDocument.Parse(text.ToString());
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new UsageQueryException("Claude 상태 입력 형식이 올바르지 않습니다.");
        }

        UsageWindow? fiveHour = null;
        UsageWindow? sevenDay = null;
        if (root.TryGetProperty("rate_limits", out JsonElement rateLimits) == true &&
            rateLimits.ValueKind == JsonValueKind.Object)
        {
            fiveHour = ReadWindow(rateLimits, "five_hour", 300);
            sevenDay = ReadWindow(rateLimits, "seven_day", 10080);
        }

        ClaudeUsageCache cache = new ClaudeUsageCache(DateTimeOffset.UtcNow, fiveHour, sevenDay);
        string fullPath = Path.GetFullPath(_path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        string temporaryPath = fullPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            string normalized = JsonSerializer.Serialize(cache);
            await File.WriteAllTextAsync(temporaryPath, normalized, cancellationToken);
            File.Move(temporaryPath, fullPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath) == true)
            {
                File.Delete(temporaryPath);
            }
        }

        List<string> parts = new List<string>();
        if (fiveHour != null)
        {
            parts.Add($"5h {fiveHour.RemainingPercent:0.#}% left");
        }

        if (sevenDay != null)
        {
            parts.Add($"7d {sevenDay.RemainingPercent:0.#}% left");
        }

        return parts.Count == 0 ? "Claude usage pending" : string.Join(" | ", parts);
    }

    public async Task<ClaudeUsageReadResult> ReadAsync(CancellationToken cancellationToken)
    {
        if (File.Exists(_path) == false)
        {
            throw new UsageQueryException("Claude Code 터미널에서 응답을 받아 주세요. 데스크톱만 사용하면 사용량이 수신되지 않습니다.");
        }

        if (new FileInfo(_path).Length > 65536)
        {
            throw new UsageQueryException("Claude 사용량 파일 형식이 올바르지 않습니다.");
        }

        using FileStream stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        ClaudeUsageCache? cache = await JsonSerializer.DeserializeAsync<ClaudeUsageCache>(stream,
                                                                                         cancellationToken: cancellationToken);
        if (cache == null || cache.CapturedAt == default || cache.CapturedAt > DateTimeOffset.UtcNow.AddMinutes(1))
        {
            throw new UsageQueryException("Claude 사용량 수신 시각을 확인할 수 없습니다.");
        }

        ValidateWindow(cache.FiveHour, 300);
        ValidateWindow(cache.SevenDay, 10080);
        if (cache.FiveHour == null && cache.SevenDay == null)
        {
            throw new UsageQueryException("Claude가 사용 한도를 아직 제공하지 않았습니다. Claude의 다음 응답 후 갱신됩니다.");
        }

        UsageBucket bucket = new UsageBucket("claude", "Claude", cache.FiveHour, cache.SevenDay);
        UsageSnapshot snapshot = new UsageSnapshot("Claude Code", new[] { bucket }, cache.CapturedAt);

        return new ClaudeUsageReadResult(snapshot, DateTimeOffset.UtcNow - cache.CapturedAt > TimeSpan.FromMinutes(15));
    }

    private UsageWindow? ReadWindow(JsonElement limits, string name, int durationMinutes)
    {
        if (limits.TryGetProperty(name, out JsonElement window) == false || window.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (window.ValueKind != JsonValueKind.Object ||
            window.TryGetProperty("used_percentage", out JsonElement used) == false ||
            used.ValueKind != JsonValueKind.Number || used.TryGetDouble(out double percent) == false ||
            double.IsFinite(percent) == false || percent < 0 || percent > 100)
        {
            throw new UsageQueryException("Claude 사용 비율이 올바르지 않습니다.");
        }

        DateTimeOffset? resetsAt = null;
        if (window.TryGetProperty("resets_at", out JsonElement reset) == true &&
            reset.ValueKind == JsonValueKind.Number && reset.TryGetInt64(out long seconds) == true &&
            seconds >= -62135596800 && seconds <= 253402300799)
        {
            resetsAt = DateTimeOffset.FromUnixTimeSeconds(seconds);
        }

        return new UsageWindow(percent, durationMinutes, resetsAt);
    }

    private void ValidateWindow(UsageWindow? window, int durationMinutes)
    {
        if (window != null && (double.IsFinite(window.UsedPercent) == false || window.UsedPercent < 0 ||
                               window.UsedPercent > 100 || window.DurationMinutes != durationMinutes))
        {
            throw new UsageQueryException("Claude 사용량 파일의 구간 정보가 올바르지 않습니다.");
        }
    }
}
