using UsageViewer.Models;

namespace UsageViewer.Services;

internal enum UsagePacingLevel
{
    Unavailable,
    Comfortable,
    Balanced,
    Caution,
    Low
}

internal sealed record UsagePacingAdvice(UsagePacingLevel Level, UsageWindow? Window = null, string? BucketName = null,
                                          UsageDailyBudget? DailyBudget = null, UsageWindow? ShortTermWindow = null);

internal static class UsagePacingAdvisor
{
    public static UsagePacingAdvice Evaluate(UsageSnapshot? snapshot, string? error, bool stale, DateTimeOffset now,
                                             UsageDailyBudget dailyBudget)
    {
        UsagePacingAdvice advice = EvaluateLimits(snapshot, error, stale, now);
        UsageWindow? shortTerm = snapshot?.Buckets.SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary })
            .OfType<UsageWindow>().Where(window => window.DurationMinutes == 300 && window.ResetsAt > now &&
                                                  double.IsFinite(window.UsedPercent) == true &&
                                                  window.UsedPercent >= 0 && window.UsedPercent <= 100)
            .Where(window => window.RemainingPercent <= 10 ||
                             window.RemainingPercent < Math.Max(10, (window.ResetsAt!.Value - now).TotalMinutes / 3) ||
                             (decimal)window.RemainingPercent < (dailyBudget.Limiting?.AdditionalPercentPoints ?? 0))
            .MinBy(window => window.RemainingPercent);
        UsagePacingLevel level = advice.Level;
        if (dailyBudget.Status == UsageDailyBudgetStatus.Unavailable && level != UsagePacingLevel.Low)
        {
            level = UsagePacingLevel.Unavailable;
        }
        else if (dailyBudget.Limiting != null && level != UsagePacingLevel.Low)
        {
            level = shortTerm != null || dailyBudget.Status == UsageDailyBudgetStatus.Exhausted ?
                    UsagePacingLevel.Caution : UsagePacingLevel.Balanced;
        }

        return advice with { Level = level, DailyBudget = dailyBudget, ShortTermWindow = shortTerm };
    }

    private static UsagePacingAdvice EvaluateLimits(UsageSnapshot? snapshot, string? error, bool stale, DateTimeOffset now)
    {
        if (UsageAlertPolicy.IsFresh(snapshot, error, stale, now) == false)
        {
            return new UsagePacingAdvice(UsagePacingLevel.Unavailable);
        }

        List<(UsageWindow Window, string? BucketName)> windows = snapshot!.Buckets
            .SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary }.OfType<UsageWindow>()
                .Select(window => (window, snapshot.Buckets.Count > 1 ? bucket.Name : null))).ToList();
        if (windows.Count == 0 || windows.Any(item => double.IsFinite(item.Window.UsedPercent) == false ||
                                                     item.Window.UsedPercent < 0 || item.Window.UsedPercent > 100 ||
                                                     (item.Window.ResetsAt != null && item.Window.ResetsAt <= now)) == true)
        {
            return new UsagePacingAdvice(UsagePacingLevel.Unavailable);
        }

        var lowest = windows.MinBy(item => item.Window.RemainingPercent);
        if (lowest.Window.RemainingPercent <= 10)
        {
            return new UsagePacingAdvice(UsagePacingLevel.Low, lowest.Window, lowest.BucketName);
        }

        if (windows.Any(item => item.Window.DurationMinutes is not > 0 || item.Window.ResetsAt == null ||
                                (item.Window.ResetsAt.Value - now).TotalMinutes > item.Window.DurationMinutes) == true)
        {
            return new UsagePacingAdvice(UsagePacingLevel.Unavailable);
        }

        double leastHeadroom = double.PositiveInfinity;
        UsageWindow? limiting = null;
        string? limitingBucket = null;
        foreach (var item in windows)
        {
            double timePercent = (item.Window.ResetsAt!.Value - now).TotalMinutes /
                                 item.Window.DurationMinutes!.Value * 100;
            double headroom = item.Window.RemainingPercent - Math.Max(10, timePercent);
            if (headroom < leastHeadroom)
            {
                leastHeadroom = headroom;
                limiting = item.Window;
                limitingBucket = item.BucketName;
            }
        }

        UsagePacingLevel level = leastHeadroom >= 10 ? UsagePacingLevel.Comfortable :
                                 leastHeadroom >= 0 ? UsagePacingLevel.Balanced : UsagePacingLevel.Caution;

        return new UsagePacingAdvice(level, limiting, limitingBucket);
    }
}
