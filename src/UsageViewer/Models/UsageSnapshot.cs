namespace UsageViewer.Models;

internal sealed record UsageWindow(double UsedPercent, int? DurationMinutes, DateTimeOffset? ResetsAt)
{
    public double RemainingPercent => 100 - UsedPercent;
}

internal sealed record CreditBalance(decimal? Balance, bool? HasCredits, bool Unlimited);

internal sealed record UsageBucket(string Id, string Name, UsageWindow? Primary, UsageWindow? Secondary,
                                  CreditBalance? Credits = null);

internal sealed record UsageSnapshot(string PlanName, IReadOnlyList<UsageBucket> Buckets, DateTimeOffset RetrievedAt);

internal sealed class UsageQueryException : Exception
{
    public UsageQueryException(string message) : base(message)
    {
    }
}
