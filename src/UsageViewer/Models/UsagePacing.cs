namespace UsageViewer.Models;

internal enum UsagePacingLevel
{
    Unavailable,
    Recommended,
    UntilReset,
    Exhausted
}

internal sealed record UsagePacingItem(string BucketId, string? BucketName, UsageWindow Window,
                                       UsagePacingLevel Level, decimal? Average24Hours = null,
                                       string? Reason = null);

internal sealed record UsagePacingAdvice(UsagePacingLevel Level, string? Reason = null,
                                         IReadOnlyList<UsagePacingItem>? Weekly = null,
                                         IReadOnlyList<UsagePacingItem>? ShortTerm = null)
{
    public UsagePacingItem? Limiting => Weekly?.Where(item => item.Average24Hours != null)
        .MinBy(item => item.Average24Hours);
}
