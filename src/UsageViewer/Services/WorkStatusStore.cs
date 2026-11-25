using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class WorkStatusStore
{
    internal static readonly TimeSpan SignalLifetime = TimeSpan.FromMinutes(10);
    private const int SessionLimit = 4096;
    private readonly object _gate = new object();
    private readonly WorkSourceState _codex = new WorkSourceState();
    private readonly WorkSourceState _claude = new WorkSourceState();

    public void Observe(WorkObservation observation)
    {
        lock (_gate)
        {
            WorkSourceState source = observation.Provider == WorkProvider.Codex ? _codex : _claude;
            if (observation.At <= source.DisconnectedAt)
            {
                return;
            }

            if (observation.Signal == WorkSignal.Disconnected)
            {
                if (observation.At >= source.LastSignal)
                {
                    source.DisconnectedAt = observation.At;
                    source.LastSignal = observation.At;
                    source.Sessions.Clear();
                    source.HasGap = false;
                }

                return;
            }

            if (observation.At > source.LastSignal)
            {
                source.LastSignal = observation.At;
            }

            if (observation.SessionKey is not string key)
            {
                return;
            }

            source.Sessions.TryGetValue(key, out WorkObservation? previous);
            if (previous != null && observation.At <= previous.At)
            {
                return;
            }

            if (observation.Signal == WorkSignal.Activity || observation.Signal == WorkSignal.ModelStarted)
            {
                bool beforeModel = observation.Signal == WorkSignal.ModelStarted;
                bool canResume = beforeModel == true && (previous?.Signal == WorkSignal.Waiting ||
                    (observation.Provider == WorkProvider.Codex && previous?.Signal == WorkSignal.Stopped));
                if (previous == null || previous.TurnKey != observation.TurnKey ||
                    (previous.Signal != WorkSignal.Running && canResume == false))
                {
                    return;
                }

                observation = observation with { Signal = WorkSignal.Running };
            }
            else if (observation.TurnKey != null && previous != null)
            {
                bool sameTurn = previous.TurnKey == observation.TurnKey;
                if ((sameTurn == false && observation.Signal != WorkSignal.Running) ||
                    (sameTurn == true && IsBusy(observation.Signal) == true && IsBusy(previous.Signal) == false) ||
                    (sameTurn == true && previous.Signal == WorkSignal.Waiting && observation.Signal == WorkSignal.Running) ||
                    (sameTurn == true && previous.Signal == WorkSignal.Cancelled && observation.Signal == WorkSignal.Stopped))
                {
                    return;
                }
            }

            if (previous == null && source.Sessions.Count >= SessionLimit)
            {
                source.HasGap = true;

                return;
            }

            source.Sessions[key] = observation;
        }
    }

    public WorkStatus Snapshot(DateTimeOffset now)
    {
        lock (_gate)
        {
            return new WorkStatus(Summarize(_codex, now), Summarize(_claude, now));
        }
    }

    private ProviderWorkStatus Summarize(WorkSourceState source, DateTimeOffset now)
    {
        if (source.LastSignal == DateTimeOffset.MinValue)
        {
            return new ProviderWorkStatus(WorkCoverage.NotConnected);
        }

        if (source.LastSignal == source.DisconnectedAt)
        {
            return new ProviderWorkStatus(WorkCoverage.Disconnected);
        }

        int running = 0;
        int waiting = 0;
        bool observed = false;
        bool incomplete = source.HasGap;
        foreach ((string key, WorkObservation observation) in source.Sessions)
        {
            if (observation.At > now || now - observation.At >= SignalLifetime)
            {
                if (IsBusy(observation.Signal) == true || observation.At > now)
                {
                    incomplete = true;
                }
                else
                {
                    source.Sessions.Remove(key);
                }

                continue;
            }

            observed = true;
            running += observation.Signal == WorkSignal.Running ? 1 : 0;
            waiting += observation.Signal == WorkSignal.Waiting ? 1 : 0;
        }

        if (incomplete == true)
        {
            return running > 0 || waiting > 0 ?
                new ProviderWorkStatus(WorkCoverage.Partial, running > 0 ? running : null, waiting > 0 ? waiting : null) :
                new ProviderWorkStatus(WorkCoverage.Stale);
        }

        if (observed == true)
        {
            return new ProviderWorkStatus(WorkCoverage.Current, running, waiting);
        }

        return new ProviderWorkStatus(now >= source.LastSignal && now - source.LastSignal < SignalLifetime ?
                                      WorkCoverage.AwaitingSignal : WorkCoverage.Stale);
    }

    private bool IsBusy(WorkSignal signal) => signal == WorkSignal.Running || signal == WorkSignal.Waiting;
}

internal sealed class WorkSourceState
{
    public Dictionary<string, WorkObservation> Sessions { get; } = new Dictionary<string, WorkObservation>();
    public DateTimeOffset LastSignal { get; set; }
    public DateTimeOffset DisconnectedAt { get; set; }
    public bool HasGap { get; set; }
}
