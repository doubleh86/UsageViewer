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

internal sealed record UsagePacingAdvice(UsagePacingLevel Level, UsageWindow? Window = null, string? BucketName = null);

internal static class UsagePacingAdvisor
{
    public static UsagePacingAdvice Evaluate(UsageSnapshot? snapshot, string? error, bool stale, DateTimeOffset now)
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
