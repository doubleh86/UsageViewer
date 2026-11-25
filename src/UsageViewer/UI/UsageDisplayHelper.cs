using System.Globalization;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer.UI;

internal sealed record ClaudeUsageDisplay(string? ShortStatus, string? Detail, string? PreviousMark, bool CanConnect,
                                          bool IsCurrent);

internal static class UsageDisplayHelper
{
    public static ClaudeUsageDisplay DescribeClaude(ClaudeRefreshState state, DateTimeOffset now)
    {
        string received = state.Snapshot is UsageSnapshot snapshot ?
                          $" · 마지막 수신 {snapshot.RetrievedAt.ToLocalTime():HH:mm}" : "";
        ClaudeUsageDisplay? blocked = state.Result switch
        {
            ClaudeRefreshResult.LoginRequired => new("로그인 확인", "연결 창에서 로그인 상태를 확인해 주세요.", null, true, false),
            ClaudeRefreshResult.AccessRequired => new("접근 확인", "Claude 페이지에서 접근 상태를 확인해 주세요.", null, true, false),
            ClaudeRefreshResult.RateLimited => new("잠시 대기", "요청 제한 · 잠시 후 다시 확인합니다.", null, false, false),
            ClaudeRefreshResult.ResponseFormat or ClaudeRefreshResult.ResponseRange =>
                new("응답 확인", "사용량 정보를 확인하지 못했어요.", null, true, false),
            ClaudeRefreshResult.StorageRead or ClaudeRefreshResult.StorageWrite =>
                new("저장 확인", "로컬 사용량 파일을 " +
                    (state.Result == ClaudeRefreshResult.StorageRead ? "읽지" : "저장하지") + " 못했어요.", null, false, false),
            _ => null
        };
        if (blocked != null)
        {
            return blocked with { Detail = blocked.Detail + received + (state.IsActive == true ? " · 조회 중" : "") };
        }

        if (state.Snapshot != null && ClaudeRefreshPolicy.IsFresh(state.Snapshot, now) == false)
        {
            return new("갱신 지연", "갱신 지연" + received, null, false, false);
        }

        if (state.IsActive == true)
        {
            return new(state.Snapshot == null ? "조회 중" : null, "사용량 확인 중…" + received, "↻", false, false);
        }

        if (ClaudeRefreshPolicy.IsTransient(state.Result) == true)
        {
            return new(state.Snapshot == null ? "갱신 지연" : null, "일시 오류 · 자동 재시도" + received, "!", false, false);
        }

        return state.Result switch
        {
            ClaudeRefreshResult.Success => new(null, null, null, false, true),
            _ when state.Snapshot != null => new(null, "이전 수신 값" + received, "!", false, false),
            _ => new("조회 대기", "공식 Claude 페이지에서 로그인 후 사용량 화면을 열어 주세요.", null, true, false)
        };
    }

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
        if (item.Daily != null && item.Reason == null && item.Level != UsagePacingLevel.Exhausted)
        {
            if (HasTomorrowGuidance(item) == true)
            {
                if (item.Daily.UsedPercent > item.Daily.TargetPercent)
                {
                    return "내일 몫을 당겨 쓰는 중";
                }

                return item.Daily.RemainingPercent == 0 ? "오늘 몫 소진 · 이후 사용은 내일 몫에서 써요" :
                       "오늘 " + FormatPacingPercent(item.Daily.RemainingPercent) + " 남음 · 초과 시 내일 몫 사용";
            }

            return "오늘 남은 권장량: " + FormatPacingPercent(item.Daily.RemainingPercent) +
                   (item.Daily.UsedPercent > item.Daily.TargetPercent ? " · 초과 사용" : "");
        }

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

    public static string GetTomorrowMessage(UsagePacingItem item)
    {
        return HasTomorrowGuidance(item) == true ?
               "내일 예상 권장량: 약 " + FormatPacingPercent(item.TomorrowEstimatePercent!.Value) + " (참고)" : "";
    }

    private static bool HasTomorrowGuidance(UsagePacingItem item)
    {
        return item.Reason == null && item.Level is (UsagePacingLevel.Recommended or UsagePacingLevel.UntilReset) &&
               item.Daily?.RemainingPercent is >= 0 and < 1 && item.TomorrowEstimatePercent is >= 0 &&
               item.Window.RemainingPercent > 0;
    }

    private static string FormatPacingPercent(decimal percent)
    {
        if (percent > 0 && percent < 0.01m)
        {
            return "0.01% 미만";
        }

        return decimal.Round(percent, 2, MidpointRounding.AwayFromZero)
            .ToString("0.00", CultureInfo.InvariantCulture) + "%";
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
                string tomorrow = GetTomorrowMessage(item);
                if (tomorrow.Length > 0)
                {
                    lines.Add(tomorrow);
                }
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
        return "오늘 첫 조회에서 리셋까지 남은 양을 오늘 자정까지의 시간만큼 나눠요. " +
               "그 권장량에서 한 시간마다 확인한 사용량을 빼요. " +
               "막대의 파란 선은 오늘 첫 조회의 잔여량, 흰 선은 오늘 권장량을 사용한 뒤의 잔여량이에요. " +
               "새 버전의 첫 조회 전 사용량은 포함하지 않아요. 날짜가 바뀌면 남은 주간 한도로 새로 나눠요. " +
               "주간 전체 한도의 비율이며, 사용을 보장하지 않아요." +
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
        return IsExpired(window, DateTimeOffset.UtcNow);
    }

    public static bool IsExpired(UsageWindow window, DateTimeOffset now) => window.ResetsAt <= now;

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
