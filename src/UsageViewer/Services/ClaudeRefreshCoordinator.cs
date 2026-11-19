using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class ClaudeRefreshCoordinator
{
    private readonly TimeProvider _clock;
    private readonly Action<ClaudeRefreshDiagnostic>? _record;
    private CancellationTokenSource? _cancellation;
    private ClaudeRefreshAttempt? _active;
    private long _sequence;
    private long _started;
    private long _phaseStarted;
    private int _transientFailures;
    private int _formatFailures;

    public ClaudeRefreshCoordinator(TimeProvider? clock = null, Action<ClaudeRefreshDiagnostic>? record = null)
    {
        _clock = clock ?? TimeProvider.System;
        _record = record;
        State = new ClaudeRefreshState(ClaudeRefreshPhase.Idle, ClaudeRefreshResult.Waiting, null, Now, null, 0);
    }

    public event EventHandler? Changed;
    public ClaudeRefreshState State { get; private set; }
    public ClaudeRefreshAttempt? Active => _active;
    public DateTimeOffset Now => _clock.GetUtcNow();

    public ClaudeRefreshAttempt? TryBegin(ClaudeRefreshTrigger trigger, bool initialized, bool interactive)
    {
        Expire();
        if (State.Phase == ClaudeRefreshPhase.Stopped || _active != null || State.ServerNotBefore > Now ||
            ((trigger is ClaudeRefreshTrigger.Automatic or ClaudeRefreshTrigger.Manual) && interactive == true) ||
            (trigger == ClaudeRefreshTrigger.Automatic && (State.NextAttempt == null || State.NextAttempt > Now)) ||
            (trigger == ClaudeRefreshTrigger.Manual &&
             ((State.Result is ClaudeRefreshResult.LoginRequired or ClaudeRefreshResult.AccessRequired) ||
              ClaudeRefreshPolicy.IsFormatError(State.Result) == true)))
        {
            return null;
        }

        CancellationTokenSource cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        ClaudeRefreshAttempt attempt = new ClaudeRefreshAttempt(++_sequence, trigger, cancellation.Token);
        _active = attempt;
        _started = _phaseStarted = _clock.GetTimestamp();
        State = State with { Phase = initialized == true ? ClaudeRefreshPhase.AwaitingUsage : ClaudeRefreshPhase.Initializing };
        Changed?.Invoke(this, EventArgs.Empty);

        return attempt;
    }

    public bool Initialized(ClaudeRefreshAttempt attempt)
    {
        if (Accepts(attempt) == false || State.Phase != ClaudeRefreshPhase.Initializing)
        {
            return false;
        }

        _phaseStarted = _clock.GetTimestamp();
        State = State with { Phase = ClaudeRefreshPhase.AwaitingUsage };
        Changed?.Invoke(this, EventArgs.Empty);

        return true;
    }

    public bool Accepts(ClaudeRefreshAttempt attempt)
    {
        if (_active?.Id != attempt.Id)
        {
            return false;
        }

        Expire();
        return _active?.Id == attempt.Id;
    }

    public void Expire()
    {
        if (_active == null)
        {
            return;
        }

        bool initializing = State.Phase == ClaudeRefreshPhase.Initializing;
        if (_clock.GetElapsedTime(_phaseStarted) >= (initializing == true ?
            ClaudeRefreshPolicy.InitializationTimeout : ClaudeRefreshPolicy.AttemptTimeout))
        {
            Finish(initializing == true ? ClaudeRefreshResult.InitializationTimeout : ClaudeRefreshResult.ResponseTimeout);
        }
    }

    public void Fail(ClaudeRefreshAttempt attempt, ClaudeRefreshResult result, int? status = null,
                     DateTimeOffset? retryAfter = null)
    {
        if (Accepts(attempt) == true)
        {
            Finish(result, status, retryAfter);
        }
    }

    public void Commit(ClaudeRefreshAttempt attempt, ClaudeUsageCache cache, Action replaceFile)
    {
        if (Accepts(attempt) == true && State.Phase == ClaudeRefreshPhase.AwaitingUsage)
        {
            replaceFile();
            Finish(ClaudeRefreshResult.Success, 200, snapshot: cache.ToSnapshot("Claude Web"));
        }
    }

    public void RestoreCache(UsageSnapshot? snapshot, bool failed)
    {
        if (State.Phase == ClaudeRefreshPhase.Stopped || State.Snapshot != null)
        {
            return;
        }

        State = State with { Snapshot = snapshot };
        if (failed == true)
        {
            if (State.Result == ClaudeRefreshResult.Waiting)
            {
                State = State with { Result = ClaudeRefreshResult.StorageRead };
            }

            Record(State.Phase, ClaudeRefreshResult.StorageRead, null, 0);
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Cancel(ClaudeRefreshAttempt attempt)
    {
        if (_active?.Id == attempt.Id)
        {
            End(ClaudeRefreshResult.Cancelled, ClaudeRefreshPhase.Idle);
        }
    }

    public void Stop()
    {
        if (State.Phase != ClaudeRefreshPhase.Stopped)
        {
            End(ClaudeRefreshResult.Stopped, ClaudeRefreshPhase.Stopped);
        }
    }

    private void Finish(ClaudeRefreshResult result, int? status = null, DateTimeOffset? retryAfter = null,
                        UsageSnapshot? snapshot = null)
    {
        ClaudeRefreshState previous = State;
        DateTimeOffset now = Now;
        bool success = result == ClaudeRefreshResult.Success;
        bool format = ClaudeRefreshPolicy.IsFormatError(result);
        bool transient = ClaudeRefreshPolicy.IsTransient(result) || result == ClaudeRefreshResult.RateLimited;
        _transientFailures = transient == true ? Math.Min(3, _transientFailures + 1) : 0;
        _formatFailures = format == true ? Math.Min(2, _formatFailures + 1) : 0;
        DateTimeOffset? next = success == true ? now + ClaudeRefreshPolicy.NormalInterval :
                               transient == true ? now + ClaudeRefreshPolicy.Backoff(_transientFailures) :
                               _formatFailures == 1 ? now.AddMinutes(2) : null;
        if (retryAfter != null)
        {
            next = retryAfter;
        }

        State = new ClaudeRefreshState(ClaudeRefreshPhase.Idle, result, snapshot ?? previous.Snapshot,
                                       next, retryAfter, success == true ? 0 : previous.Failures + 1);
        if (result != previous.Result || next.HasValue != previous.NextAttempt.HasValue)
        {
            Record(previous.Phase, result, status, (long)_clock.GetElapsedTime(_started).TotalMilliseconds);
        }

        ReleaseAttempt();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void End(ClaudeRefreshResult result, ClaudeRefreshPhase phase)
    {
        Record(State.Phase, result, null, _active != null ? (long)_clock.GetElapsedTime(_started).TotalMilliseconds : 0);
        State = State with { Phase = phase };
        ReleaseAttempt();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void ReleaseAttempt()
    {
        _active = null;
        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = null;
    }

    private void Record(ClaudeRefreshPhase phase, ClaudeRefreshResult result, int? status, long elapsedMs)
    {
        _record?.Invoke(new ClaudeRefreshDiagnostic(Now, phase, result, status, elapsedMs, State.Failures));
    }
}
