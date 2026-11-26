namespace UsageViewer.Models;

internal sealed record CodexWeeklyResetOverride(DateTimeOffset ServerResetAt, DateTimeOffset PlannedResetAt,
                                                string? AccountScope);
