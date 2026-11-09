namespace UsageViewer.Models;

internal enum UsageDailyBudgetStatus
{
    Unavailable,
    NotProvided,
    Ready,
    Exhausted
}

internal sealed record UsageDailyBudgetItem(string LimitName, decimal AdditionalPercentPoints,
                                            decimal TargetRemainingPercent, DateTimeOffset EndsAt,
                                            DateTimeOffset ResetsAt, bool EndsAtReset);

internal sealed record UsageDailyBudget(UsageDailyBudgetStatus Status, string? Reason = null,
                                        IReadOnlyList<UsageDailyBudgetItem>? Items = null)
{
    public UsageDailyBudgetItem? Limiting => Items?.MinBy(item => item.AdditionalPercentPoints);
}

// Only the current day's fixed targets and ordering guards are persisted; never snapshots or account data.
internal sealed record UsageDailyBudgetEntry(string Provider, string LimitKey, string ConfigurationKey,
                                             string LocalDate, string TimeZoneKey, DateTimeOffset BaselineAt,
                                             DateTimeOffset LastReceivedAt, DateTimeOffset EndsAt,
                                             DateTimeOffset ResetsAt, decimal TargetRemainingPercent);

internal sealed record UsageDailyBudgetState(int Version, IReadOnlyList<UsageDailyBudgetEntry> Entries);
internal sealed record UsageDailyBudgetLoadResult(UsageDailyBudgetState? State, string? Error = null);
