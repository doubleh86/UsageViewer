namespace UsageViewer.Models;

internal enum WorkProvider
{
    Codex,
    Claude
}

internal enum WorkSignal
{
    Ready,
    Disconnected,
    Running,
    Waiting,
    Activity,
    ModelStarted,
    Stopped,
    Cancelled,
    Failed,
    Ended
}

internal enum WorkCoverage
{
    NotConnected,
    AwaitingSignal,
    Stale,
    Disconnected,
    Current,
    Partial
}

internal sealed record WorkObservation(WorkProvider Provider, WorkSignal Signal, DateTimeOffset At,
                                       string? SessionKey = null, string? TurnKey = null);

internal sealed record ProviderWorkStatus(WorkCoverage Coverage, int? Running = null, int? Waiting = null)
{
    public string Status => Coverage switch
    {
        WorkCoverage.NotConnected => "미연동",
        WorkCoverage.AwaitingSignal => "수신 대기",
        WorkCoverage.Stale => "신호 오래됨",
        WorkCoverage.Disconnected => "연결 끊김",
        WorkCoverage.Partial => "일부 신호 오래됨",
        _ => "최근 훅 관측"
    };

    public bool IsCurrent => Coverage == WorkCoverage.Current;
}

internal sealed record WorkStatus(ProviderWorkStatus Codex, ProviderWorkStatus Claude)
{
    public static WorkStatus Empty { get; } = new WorkStatus(new ProviderWorkStatus(WorkCoverage.NotConnected),
                                                             new ProviderWorkStatus(WorkCoverage.NotConnected));
    public int? Running => Sum(Codex.Running, Claude.Running);
    public int? Waiting => Sum(Codex.Waiting, Claude.Waiting);
    public bool IsPartial => Codex.IsCurrent == false || Claude.IsCurrent == false;

    public string Status => Codex.Coverage == Claude.Coverage ? Codex.Status : "작업 상태 확인 필요";

    private int? Sum(int? codex, int? claude)
    {
        int total = codex.GetValueOrDefault() + claude.GetValueOrDefault();

        return total > 0 || IsPartial == false ? total : null;
    }
}
