namespace UsageViewer.Models;

internal enum ClaudeRefreshPhase { Idle, Initializing, AwaitingUsage, Stopped }

internal enum ClaudeRefreshTrigger { Automatic, Manual, Connection, Page }

internal enum ClaudeRefreshResult
{
    Waiting, Success, LoginRequired, AccessRequired, RateLimited, InitializationFailed, InitializationTimeout,
    NavigationFailed, NetworkFailed, ResponseTimeout, ServerError, HttpError, ResponseFormat, ResponseRange,
    StorageRead, StorageWrite, Cancelled, Stopped
}

internal sealed record ClaudeRefreshAttempt(long Id, ClaudeRefreshTrigger Trigger, CancellationToken Token);

internal sealed record ClaudeRefreshState(ClaudeRefreshPhase Phase, ClaudeRefreshResult Result,
                                          UsageSnapshot? Snapshot, DateTimeOffset? NextAttempt,
                                          DateTimeOffset? ServerNotBefore, int Failures)
{
    public bool IsActive => Phase is ClaudeRefreshPhase.Initializing or ClaudeRefreshPhase.AwaitingUsage;
}
