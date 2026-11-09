using UsageViewer.Models;

namespace UsageViewer.Services;

internal static class UsagePacingAdvisor
{
    public static UsagePacingAdvice Evaluate(UsageSnapshot? snapshot, string? error, bool stale, DateTimeOffset now)
    {
        string? reason = snapshot == null ? "사용량 미수신" :
                         error != null ? "조회 실패 · 새로고침 필요" :
                         stale == true ? "이전 수신 값 · 새로고침 필요" :
                         snapshot.RetrievedAt > now ? "수신 시각 확인 필요" :
                         now - snapshot.RetrievedAt > TimeSpan.FromMinutes(15) ? "오래된 수신 값 · 새로고침 필요" : null;
        List<UsagePacingItem> weekly = new List<UsagePacingItem>();
        List<UsagePacingItem> shortTerm = new List<UsagePacingItem>();
        foreach (UsageBucket bucket in snapshot?.Buckets ?? [])
        {
            UsageWindow[] windows = new[] { bucket.Primary, bucket.Secondary }.OfType<UsageWindow>().ToArray();
            foreach (UsageWindow window in windows.Where(window => window.DurationMinutes is 10080 or 300))
            {
                bool isWeekly = window.DurationMinutes == 10080;
                string? invalid = reason ?? Validate(window, now, isWeekly);
                if (isWeekly == true && invalid == null &&
                    (string.IsNullOrWhiteSpace(bucket.Id) == true ||
                     snapshot!.Buckets.Count(item => item.Id == bucket.Id) > 1 ||
                     windows.Count(item => item.DurationMinutes == 10080) > 1))
                {
                    invalid = "주간 구간 식별 확인 필요";
                }

                decimal? average = null;
                UsagePacingLevel level = UsagePacingLevel.Unavailable;
                if (invalid == null && isWeekly == true)
                {
                    DateTimeOffset reset = window.ResetsAt!.Value;
                    TimeSpan remainingTime = reset - now;
                    // Subtract in decimal so a received 99.7 does not move the 0.15 rounding boundary.
                    decimal remaining = 100m - (decimal)window.UsedPercent;
                    if (remaining == 0 && window.RemainingPercent > 0)
                    {
                        remaining = (decimal)window.RemainingPercent;
                    }
                    average = remaining * TimeSpan.TicksPerDay / remainingTime.Ticks;
                    level = remaining == 0 ? UsagePacingLevel.Exhausted :
                            remainingTime <= TimeSpan.FromHours(24) ? UsagePacingLevel.UntilReset :
                            UsagePacingLevel.Recommended;
                }

                UsagePacingItem item = new UsagePacingItem(bucket.Id,
                    snapshot!.Buckets.Count > 1 ? bucket.Name : null, window, level, average, invalid);
                (isWeekly == true ? weekly : shortTerm).Add(item);
            }
        }

        UsagePacingAdvice advice = new UsagePacingAdvice(UsagePacingLevel.Unavailable, reason, weekly, shortTerm);
        if (weekly.Count == 0)
        {
            bool unknown = snapshot?.Buckets.Any(bucket =>
                new[] { bucket.Primary, bucket.Secondary }.OfType<UsageWindow>()
                    .Any(window => window.DurationMinutes is not > 0)) == true;
            return advice with { Reason = reason ?? (unknown == true ? "주간 구간 길이 미제공" : "주간 한도 미제공") };
        }

        return advice with
        {
            Level = weekly.Any(item => item.Reason != null) == true ? UsagePacingLevel.Unavailable : advice.Limiting!.Level,
            Reason = reason ?? weekly.FirstOrDefault(item => item.Reason != null)?.Reason
        };
    }

    private static string? Validate(UsageWindow window, DateTimeOffset now, bool weekly)
    {
        if (double.IsFinite(window.UsedPercent) == false || window.UsedPercent < 0 || window.UsedPercent > 100)
        {
            return "잔여량 확인 필요";
        }
        if (window.ResetsAt == null)
        {
            return weekly == true ? "주간 초기화 시각 미제공" : null;
        }
        if (window.ResetsAt <= now)
        {
            return "초기화 시각 경과 · 새 수신 필요";
        }
        if (window.ResetsAt - now > TimeSpan.FromMinutes(window.DurationMinutes!.Value))
        {
            return "초기화 시각이 구간 길이를 초과해요";
        }
        return null;
    }
}
