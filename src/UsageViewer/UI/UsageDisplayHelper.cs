using System.Globalization;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer.UI;

internal static class UsageDisplayHelper
{
    public static string FormatLimitCoverage(UsageSnapshot? snapshot)
    {
        if (snapshot == null)
        {
            return "한도 확인 대기";
        }

        List<UsageWindow> windows = snapshot.Buckets.SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary })
            .OfType<UsageWindow>().ToList();
        if (windows.Count == 0)
        {
            return "한도 정보 미제공";
        }

        List<string> parts = windows.Where(window => window.DurationMinutes is > 0)
            .Select(window => window.DurationMinutes!.Value).Distinct().Order()
            .Select(minutes => FormatWindow(minutes, "사용 한도").Replace(" 한도", "")).ToList();
        if (windows.Any(window => window.DurationMinutes is not > 0) == true)
        {
            parts.Add("구간 정보 미제공");
        }
        else if (windows.Any(window => window.DurationMinutes == 300) == false)
        {
            parts.Add("5시간 미제공");
        }

        return "수신 한도 · " + string.Join(" · ", parts);
    }

    public static string GetPacingMessage(UsagePacingLevel level)
    {
        return level switch
        {
            UsagePacingLevel.Comfortable => "사용량을 더 써도 됩니다!",
            UsagePacingLevel.Balanced => "리셋까지 사용 여유가 있어요",
            UsagePacingLevel.Caution => "리셋까지 조금 아껴 쓰세요",
            UsagePacingLevel.Low => "잔여량이 적어요 · 리셋까지 아껴 쓰세요",
            _ => "최신 한도·리셋 정보가 필요해요"
        };
    }

    public static string FormatPacingDetails(UsagePacingAdvice advice)
    {
        if (advice.Window == null)
        {
            return "새로고침하거나 연결 상태를 확인해 주세요.";
        }

        string name = FormatWindow(advice.Window.DurationMinutes, "사용 한도");
        if (string.IsNullOrEmpty(advice.BucketName) == false)
        {
            name = advice.BucketName + " · " + name;
        }

        return $"{name} {FormatPercent(advice.Window.RemainingPercent)} 남음\n{FormatReset(advice.Window)}";
    }

    public static string FormatPercent(double percent)
    {
        return percent.ToString("0.#", CultureInfo.InvariantCulture) + "%";
    }

    public static string FormatWindow(int? minutes, string fallback)
    {
        if (minutes == null)
        {
            return fallback;
        }

        if (minutes == 10080)
        {
            return "주간 한도";
        }

        if (minutes % 1440 == 0)
        {
            return $"{minutes / 1440}일 한도";
        }

        if (minutes % 60 == 0)
        {
            return $"{minutes / 60}시간 한도";
        }

        return $"{minutes}분 한도";
    }

    public static bool IsExpired(UsageWindow window)
    {
        return window.ResetsAt != null && window.ResetsAt <= DateTimeOffset.UtcNow;
    }

    public static string FormatReset(UsageWindow window)
    {
        if (window.ResetsAt == null)
        {
            return "초기화 시각 미제공";
        }

        if (IsExpired(window) == true)
        {
            return "초기화 시각 경과 · 새로고침 필요";
        }

        DateTimeOffset localReset = window.ResetsAt.Value.ToLocalTime();
        TimeSpan remaining = window.ResetsAt.Value - DateTimeOffset.UtcNow;
        string timeLeft;
        if (remaining.TotalDays >= 1)
        {
            timeLeft = $"{(int)remaining.TotalDays}일 {remaining.Hours}시간 후";
        }
        else if (remaining.TotalHours >= 1)
        {
            timeLeft = $"{(int)remaining.TotalHours}시간 {remaining.Minutes}분 후";
        }
        else
        {
            timeLeft = $"{Math.Max(1, (int)Math.Ceiling(remaining.TotalMinutes))}분 후";
        }

        return $"{timeLeft} 초기화 · {localReset:MM/dd HH:mm}";
    }

    public static Color GetUsageColor(double usedPercent)
    {
        if (usedPercent >= 90)
        {
            return Color.FromArgb(248, 126, 131);
        }

        if (usedPercent >= 70)
        {
            return Color.FromArgb(241, 195, 111);
        }

        return Color.FromArgb(111, 226, 192);
    }
}
