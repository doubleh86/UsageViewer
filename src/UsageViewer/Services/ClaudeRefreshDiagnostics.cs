using System.Text.Json;
using System.Text.Json.Serialization;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed record ClaudeRefreshDiagnostic(DateTimeOffset At,
                                               [property: JsonConverter(typeof(JsonStringEnumConverter<ClaudeRefreshPhase>))]
                                               ClaudeRefreshPhase Phase,
                                               [property: JsonConverter(typeof(JsonStringEnumConverter<ClaudeRefreshResult>))]
                                               ClaudeRefreshResult Result,
                                               int? HttpStatus, long ElapsedMs, int Failures);

internal sealed class ClaudeRefreshDiagnostics
{
    private const int MaxEntries = 100;
    private const int MaxBytes = 64 * 1024;
    private readonly string _path;
    private readonly TimeProvider _clock;
    private Task _pending = Task.CompletedTask;
    private DateTimeOffset _nextSweep;

    public ClaudeRefreshDiagnostics(string? path = null, TimeProvider? clock = null)
    {
        _path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                     "UsageViewer", "claude-refresh-diagnostics.json");
        _clock = clock ?? TimeProvider.System;
    }

    public void Record(ClaudeRefreshDiagnostic entry) => Enqueue(entry);

    public void Maintain()
    {
        DateTimeOffset now = _clock.GetUtcNow();
        if (now >= _nextSweep)
        {
            _nextSweep = now.AddMinutes(1);
            Enqueue(null);
        }
    }

    public Task FlushAsync() => _pending;

    private void Enqueue(ClaudeRefreshDiagnostic? entry)
    {
        Task previous = _pending;
        _pending = Task.Run(async () =>
        {
            await previous;
            Persist(entry);
        });
    }

    private void Persist(ClaudeRefreshDiagnostic? entry)
    {
        string temporary = _path + ".tmp";
        try
        {
            List<ClaudeRefreshDiagnostic> entries = [];
            bool rewrite = false;
            if (File.Exists(_path) == true)
            {
                rewrite = true;
                if (new FileInfo(_path).Length <= MaxBytes)
                {
                    try
                    {
                        entries = JsonSerializer.Deserialize<List<ClaudeRefreshDiagnostic>>(File.ReadAllBytes(_path)) ?? [];
                        rewrite = false;
                    }
                    catch (JsonException)
                    {
                    }
                }
            }

            DateTimeOffset now = _clock.GetUtcNow();
            int removed = entries.RemoveAll(item => item == null || item.At <= now.AddHours(-24) || item.At > now);
            if (entry != null)
            {
                entries.Add(entry);
            }

            if (entry == null && removed == 0 && rewrite == false && entries.Count <= MaxEntries)
            {
                return;
            }

            if (entries.Count > MaxEntries)
            {
                entries.RemoveRange(0, entries.Count - MaxEntries);
            }

            byte[] payload = JsonSerializer.SerializeToUtf8Bytes(entries);
            if (payload.Length > MaxBytes)
            {
                return;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
            File.WriteAllBytes(temporary, payload);
            File.Move(temporary, _path, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
        finally
        {
            ClaudeUsageStore.DeleteTemporary(temporary);
        }
    }
}
