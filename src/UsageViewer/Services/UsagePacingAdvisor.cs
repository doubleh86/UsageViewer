using UsageViewer.Models;

namespace UsageViewer.Services;

internal static class UsagePacingAdvisor
{
    public static UsagePacingAdvice Evaluate(UsageSnapshot? snapshot, string? error, bool stale, DateTimeOffset now,
                                             TimeZoneInfo zone)
    {
        string? reason = snapshot == null ? "사용량 미수신" :
                         error != null ? "조회 실패 · 새로고침 필요" :
                         stale == true ? "이전 수신 값 · 새로고침 필요" :
                         snapshot.RetrievedAt > now ? "수신 시각 확인 필요" :
                         now - snapshot.RetrievedAt > TimeSpan.FromMinutes(15) ? "오래된 수신 값 · 새로고침 필요" : null;
        List<UsagePacingItem> weekly = new List<UsagePacingItem>();
        List<UsagePacingItem> shortTerm = new List<UsagePacingItem>();
        DateTimeOffset midnight = NextMidnight(now, zone);
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

                int? baseline = null;
                bool endsAtReset = false;
                UsagePacingLevel level = UsagePacingLevel.Unavailable;
                if (invalid == null && isWeekly == true)
                {
                    DateTimeOffset reset = window.ResetsAt!.Value;
                    endsAtReset = reset <= midnight;
                    DateTimeOffset end = endsAtReset == true ? reset : midnight;
                    decimal ticks = (reset - end).Ticks;
                    baseline = (int)decimal.Ceiling(Math.Clamp(ticks / TimeSpan.FromMinutes(10080).Ticks * 100, 0, 100));
                    double remaining = Math.Round(window.RemainingPercent, 1, MidpointRounding.AwayFromZero);
                    level = remaining > baseline ? UsagePacingLevel.Comfortable :
                            remaining == baseline ? UsagePacingLevel.Balanced : UsagePacingLevel.Caution;
                }

                UsagePacingItem item = new UsagePacingItem(bucket.Id,
                    snapshot!.Buckets.Count > 1 ? bucket.Name : null, window, level, baseline, endsAtReset, invalid);
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

    private static DateTimeOffset NextMidnight(DateTimeOffset now, TimeZoneInfo zone)
    {
        DateTime midnight = DateTime.SpecifyKind(TimeZoneInfo.ConvertTime(now, zone).Date.AddDays(1),
                                                DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(midnight) == true)
        {
            midnight = midnight.AddMinutes(1);
        }
        TimeSpan offset = zone.IsAmbiguousTime(midnight) == true ? zone.GetAmbiguousTimeOffsets(midnight).Max() :
                          zone.GetUtcOffset(midnight);
        return new DateTimeOffset(midnight, offset);
    }
}
