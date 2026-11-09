namespace UsageViewer.Models;

internal enum UsagePacingLevel
{
    Unavailable,
    Comfortable,
    Balanced,
    Caution
}

internal sealed record UsagePacingItem(string BucketId, string? BucketName, UsageWindow Window,
                                       UsagePacingLevel Level, int? Baseline = null,
                                       bool EndsAtReset = false, string? Reason = null);

internal sealed record UsagePacingAdvice(UsagePacingLevel Level, string? Reason = null,
                                         IReadOnlyList<UsagePacingItem>? Weekly = null,
                                         IReadOnlyList<UsagePacingItem>? ShortTerm = null)
{
    public UsagePacingItem? Limiting => Weekly?.Where(item => item.Baseline != null)
        .MinBy(item => item.Window.RemainingPercent - item.Baseline!.Value);
}
