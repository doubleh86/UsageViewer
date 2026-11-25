using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class WorkStatusCollector(WorkStatusStore store, string pipeName)
{
    private const int MaxFrameBytes = 512;
    private static readonly TimeSpan MaxDeliveryAge = TimeSpan.FromSeconds(2);

    public static string DefaultPipeName { get; } = $"UsageViewer.WorkStatus.v1.{Process.GetCurrentProcess().SessionId}";

    public async Task ListenAsync(CancellationToken shutdown)
    {
        while (shutdown.IsCancellationRequested == false)
        {
            try
            {
                using NamedPipeServerStream pipe = new NamedPipeServerStream(pipeName, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(shutdown);
                using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown);
                timeout.CancelAfter(TimeSpan.FromMilliseconds(700));
                try
                {
                    byte[] frame = new byte[MaxFrameBytes + 1];
                    int length = await pipe.ReadAtLeastAsync(frame, frame.Length, false, timeout.Token);
                    if (length > 0 && length <= MaxFrameBytes)
                    {
                        WorkObservation? observation = JsonSerializer.Deserialize<WorkObservation>(frame.AsSpan(0, length));
                        if (IsValid(observation, DateTimeOffset.UtcNow) == true)
                        {
                            store.Observe(observation!);
                        }
                    }
                }
                catch (Exception exception) when (exception is IOException or JsonException or OperationCanceledException)
                {
                }
            }
            catch (OperationCanceledException) when (shutdown.IsCancellationRequested == true)
            {
                return;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                DateTimeOffset now = DateTimeOffset.UtcNow;
                store.Observe(new WorkObservation(WorkProvider.Codex, WorkSignal.Disconnected, now));
                store.Observe(new WorkObservation(WorkProvider.Claude, WorkSignal.Disconnected, now));
                try
                {
                    await Task.Delay(1000, shutdown);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    public static async Task SendAsync(string pipeName, WorkObservation observation, CancellationToken cancellationToken)
    {
        using NamedPipeClientStream pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.Out,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(cancellationToken);
        byte[] frame = JsonSerializer.SerializeToUtf8Bytes(observation);
        await pipe.WriteAsync(frame, cancellationToken);
    }

    private bool IsValid(WorkObservation? observation, DateTimeOffset now)
    {
        if (observation == null || Enum.IsDefined(observation.Provider) == false ||
            Enum.IsDefined(observation.Signal) == false || observation.At > now || now - observation.At > MaxDeliveryAge)
        {
            return false;
        }

        if (observation.Signal == WorkSignal.Ready || observation.Signal == WorkSignal.Disconnected)
        {
            return observation.SessionKey == null && observation.TurnKey == null;
        }

        return IsKey(observation.SessionKey) == true && (observation.TurnKey == null || IsKey(observation.TurnKey));
    }

    private bool IsKey(string? key) => key is { Length: 64 } && key.All(Uri.IsHexDigit);
}
