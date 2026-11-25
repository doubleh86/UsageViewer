using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal static class WorkStatusHook
{
    private const int MaxPayloadBytes = 1024 * 1024;

    public static async Task RunAsync(string[] args)
    {
        if (args.Length < 2 || (args[1] != "codex" && args[1] != "claude"))
        {
            return;
        }

        WorkProvider provider = args[1] == "codex" ? WorkProvider.Codex : WorkProvider.Claude;
        DateTimeOffset now = DateTimeOffset.UtcNow;
        using CancellationTokenSource timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(700));
        try
        {
            WorkObservation? observation = null;
            if (args[0] == "--work-status-hook" && args.Length == 2)
            {
                if (provider == WorkProvider.Claude && IsLocalClaude(
                    Environment.GetEnvironmentVariable("USAGEVIEWER_CLAUDE_DESKTOP_LOCAL"),
                    Environment.GetEnvironmentVariable("CLAUDE_CODE_REMOTE")) == false)
                {
                    return;
                }

                using Stream input = Console.OpenStandardInput();
                observation = await ReadAsync(input, provider, now, timeout.Token);
            }
            else if (args[0] == "--work-status-source" && args.Length == 3 &&
                     (args[2] == "waiting" || args[2] == "disconnected"))
            {
                observation = new WorkObservation(provider, args[2] == "waiting" ? WorkSignal.Ready :
                                                    WorkSignal.Disconnected, now);
            }

            if (observation != null)
            {
                await WorkStatusCollector.SendAsync(WorkStatusCollector.DefaultPipeName, observation, timeout.Token);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                          OperationCanceledException or JsonException)
        {
        }
    }

    public static bool IsLocalClaude(string? scope, string? remote) => scope == "1" && remote != "true";

    public static async Task<WorkObservation?> ReadAsync(Stream input, WorkProvider provider, DateTimeOffset now,
                                                         CancellationToken cancellationToken)
    {
        byte[] buffer = new byte[MaxPayloadBytes + 1];
        int length = await input.ReadAtLeastAsync(buffer, buffer.Length, false, cancellationToken);
        if (length == 0 || length > MaxPayloadBytes)
        {
            return null;
        }

        ReadOnlyMemory<byte> payload = buffer.AsMemory(0, length);
        if (payload.Span.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }) == true)
        {
            payload = payload[3..];
        }

        using JsonDocument document = JsonDocument.Parse(payload);
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            (root.TryGetProperty("agent_id", out JsonElement agent) == true && agent.ValueKind != JsonValueKind.Null))
        {
            return null;
        }

        string? session = GetKey(root, "session_id");
        if (session == null)
        {
            return null;
        }

        WorkSignal? signal = GetText(root, "hook_event_name") switch
        {
            "SessionStart" => WorkSignal.Ready,
            "UserPromptSubmit" => WorkSignal.Running,
            "PermissionRequest" when provider == WorkProvider.Codex => WorkSignal.Waiting,
            "PostToolUse" => WorkSignal.Activity,
            "PreModelRequest" when provider == WorkProvider.Codex => WorkSignal.ModelStarted,
            "PostToolBatch" when provider == WorkProvider.Claude => WorkSignal.ModelStarted,
            "Notification" when provider == WorkProvider.Claude &&
                GetText(root, "notification_type") == "permission_prompt" => WorkSignal.Waiting,
            "Stop" => WorkSignal.Stopped,
            "Interrupt" when provider == WorkProvider.Codex => WorkSignal.Cancelled,
            "StopFailure" when provider == WorkProvider.Claude => WorkSignal.Failed,
            "SessionEnd" => WorkSignal.Ended,
            _ => null
        };

        if (signal == null)
        {
            return null;
        }

        if (signal == WorkSignal.Ready)
        {
            return new WorkObservation(provider, signal.Value, now);
        }

        string? turn = provider == WorkProvider.Codex ? GetKey(root, "turn_id") : null;
        if (provider == WorkProvider.Codex && signal != WorkSignal.Ended && turn == null)
        {
            return null;
        }

        return new WorkObservation(provider, signal.Value, now, session, turn);
    }

    private static string? GetText(JsonElement root, string key) =>
        root.TryGetProperty(key, out JsonElement value) == true && value.ValueKind == JsonValueKind.String ?
            value.GetString() : null;

    private static string? GetKey(JsonElement root, string key)
    {
        string? value = GetText(root, key);

        return value is { Length: > 0 and <= 128 } && value.All(character =>
               char.IsAsciiLetterOrDigit(character) == true || character == '-' || character == '_') == true ?
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))) : null;
    }
}
