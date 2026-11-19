using System.Globalization;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal static class ClaudeRefreshPolicy
{
    private static readonly string[] RetryDateFormats =
        ["r", "dddd, dd-MMM-yy HH':'mm':'ss 'GMT'", "ddd MMM d HH':'mm':'ss yyyy", "ddd MMM  d HH':'mm':'ss yyyy"];

    public static readonly TimeSpan InitializationTimeout = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan AttemptTimeout = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan NormalInterval = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan Freshness = TimeSpan.FromMinutes(15);

    public static ClaudeRefreshResult ClassifyHttp(int status) => status switch
    {
        200 => ClaudeRefreshResult.Success,
        401 => ClaudeRefreshResult.LoginRequired,
        403 => ClaudeRefreshResult.AccessRequired,
        429 => ClaudeRefreshResult.RateLimited,
        >= 500 and <= 599 => ClaudeRefreshResult.ServerError,
        _ => ClaudeRefreshResult.HttpError
    };

    public static bool IsFormatError(ClaudeRefreshResult result) =>
        result is ClaudeRefreshResult.ResponseFormat or ClaudeRefreshResult.ResponseRange;

    public static bool IsTransient(ClaudeRefreshResult result) => result is
        ClaudeRefreshResult.InitializationFailed or ClaudeRefreshResult.InitializationTimeout or
        ClaudeRefreshResult.NavigationFailed or ClaudeRefreshResult.NetworkFailed or
        ClaudeRefreshResult.ResponseTimeout or ClaudeRefreshResult.ServerError or ClaudeRefreshResult.HttpError or
        ClaudeRefreshResult.StorageRead or ClaudeRefreshResult.StorageWrite;

    public static TimeSpan Backoff(int failures) => failures switch
    {
        <= 1 => TimeSpan.FromSeconds(30),
        2 => TimeSpan.FromMinutes(2),
        _ => TimeSpan.FromMinutes(5)
    };

    public static DateTimeOffset? ParseRetryAfter(string? value, DateTimeOffset now)
    {
        if (value == null)
        {
            return null;
        }

        ReadOnlySpan<char> text = value.AsSpan().Trim();
        if (long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out long seconds) == true)
        {
            long maxSeconds = (DateTimeOffset.MaxValue - now).Ticks / TimeSpan.TicksPerSecond;
            return seconds > maxSeconds ? DateTimeOffset.MaxValue : now.AddTicks(seconds * TimeSpan.TicksPerSecond);
        }

        if (text.IsEmpty == false && text.IndexOfAnyExceptInRange('0', '9') < 0)
        {
            return DateTimeOffset.MaxValue;
        }

        if (DateTimeOffset.TryParseExact(text, RetryDateFormats, CultureInfo.InvariantCulture,
                                        DateTimeStyles.AssumeUniversal, out DateTimeOffset date) == true)
        {
            return date >= now ? date : now;
        }

        return null;
    }

    public static bool IsFresh(UsageSnapshot? snapshot, DateTimeOffset now) =>
        snapshot != null && snapshot.RetrievedAt <= now && now - snapshot.RetrievedAt <= Freshness;
}
