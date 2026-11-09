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

    public static string GetPacingMessage(UsagePacingAdvice advice)
    {
        if (advice.Level == UsagePacingLevel.Unavailable || advice.Limiting == null)
        {
            return "추천 페이스 보류 · " + (advice.Reason ?? "최신 주간 정보 필요");
        }

        string message = GetWeeklyMessage(advice.Limiting);
        return advice.Limiting.BucketName is string name ? name + " · " + message : message;
    }

    public static string GetWeeklyMessage(UsagePacingItem item)
    {
        return item.Level switch
        {
            UsagePacingLevel.Recommended => "추천 페이스: 24시간에 약" +
                                           FormatPacingPercent(item.Average24Hours!.Value),
            UsagePacingLevel.UntilReset => "초기화까지 남은 " +
                                          FormatPercent(item.Window.RemainingPercent) +
                                          (item.Window.RemainingPercent < 0.1 ? "을" : "를") + " 나눠 쓰세요",
            UsagePacingLevel.Exhausted => "주간 한도 소진 · 초기화를 기다려 주세요",
            _ => "추천 페이스 보류 · " + (item.Reason ?? "최신 주간 정보 필요")
        };
    }

    private static string FormatPacingPercent(decimal percent)
    {
        if (percent > 0 && percent < 0.1m)
        {
            return "0.1% 미만";
        }

        int digits = percent < 1 ? 1 : 0;
        return decimal.Round(percent, digits, MidpointRounding.AwayFromZero)
            .ToString("0.#", CultureInfo.InvariantCulture) + "%";
    }

    public static string FormatPacingDetails(UsagePacingAdvice advice)
    {
        List<string> lines = new List<string>();
        if (advice.Reason != null)
        {
            lines.Add(advice.Reason);
        }
        foreach (UsagePacingItem item in (advice.ShortTerm ?? []).Concat(advice.Weekly ?? []))
        {
            string name = (item.BucketName != null ? item.BucketName + " · " : "") +
                          FormatWindow(item.Window.DurationMinutes, "사용 한도");
            string value = double.IsFinite(item.Window.UsedPercent) == true &&
                           item.Window.UsedPercent >= 0 && item.Window.UsedPercent <= 100 ?
                           FormatPercent(item.Window.RemainingPercent) + " 남음" : "잔여량 확인 필요";
            lines.Add(name + " · " + value);
            if (item.Window.DurationMinutes == 10080)
            {
                lines.Add(GetWeeklyMessage(item));
            }
            else if (item.Reason != null)
            {
                lines.Add(item.Reason);
            }
            string warning = FormatShortTermWarning(item);
            if (warning.Length > 0)
            {
                lines.Add(warning);
            }
            lines.Add(item.Window.ResetsAt is DateTimeOffset reset ?
                      $"초기화 {reset.ToLocalTime():MM/dd HH:mm}" : "초기화 시각 미제공");
        }
        return string.Join("\n", lines);
    }

    public static string FormatShortTermWarning(UsagePacingItem item)
    {
        if (item.Window.DurationMinutes != 300 || item.Reason != null || item.Window.RemainingPercent > 10)
        {
            return "";
        }
        return item.Window.RemainingPercent <= 0 ? "5시간 한도 소진 · 초기화를 기다려 주세요" :
               item.Window.RemainingPercent <= 5 ? "5시간 한도 잔여량 매우 적음" : "5시간 한도 잔여량이 적어요";
    }

    public static string FormatPacingBasis(UsagePacingAdvice advice)
    {
        return "남은 주간 한도를 초기화까지 고르게 나눠 쓸 때의 평균이에요. " +
               "연속 24시간당 주간 한도의 비율이며, 사용을 보장하지 않아요." +
               (advice.ShortTerm?.Count > 0 ? " 5시간 한도는 따로 적용돼요." : "");
    }

    public static string FormatPercent(double percent)
    {
        if (percent > 0 && percent < 0.1)
        {
            return "0.1% 미만";
        }

        return Math.Round(percent, 1, MidpointRounding.AwayFromZero).ToString("0.#", CultureInfo.InvariantCulture) + "%";
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
