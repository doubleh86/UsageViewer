using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal enum UsageAlertLevel
{
    None,
    Warning,
    Critical
}

internal sealed record UsageAlert(string ProviderId, string ProviderName, UsageWindow Window, UsageAlertLevel Level);
internal sealed record UsageAlertEntry(UsageAlertLevel Level, DateTimeOffset UpdatedAt);
internal sealed record UsageAlertHistory(Dictionary<string, UsageAlertEntry> Entries, DateTimeOffset? LastAlertAt = null);

internal static class UsageAlertPolicy
{
    public static bool IsFresh(UsageSnapshot? snapshot, string? error, bool stale, DateTimeOffset now)
    {
        return snapshot != null && error == null && stale == false && snapshot.RetrievedAt <= now.AddMinutes(1) &&
               now - snapshot.RetrievedAt <= TimeSpan.FromMinutes(15);
    }

    public static UsageAlertLevel GetLevel(UsageWindow window, DateTimeOffset now)
    {
        if (double.IsFinite(window.UsedPercent) == false || window.UsedPercent < 0 || window.UsedPercent > 100 ||
            (window.ResetsAt != null && window.ResetsAt <= now))
        {
            return UsageAlertLevel.None;
        }

        return window.RemainingPercent <= 5 ? UsageAlertLevel.Critical :
               window.RemainingPercent <= 10 ? UsageAlertLevel.Warning : UsageAlertLevel.None;
    }
}

internal sealed class UsageAlertMonitor
{
    private readonly string _path;
    private UsageAlertHistory _history;

    public UsageAlertMonitor(string? path = null)
    {
        _path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                     "UsageViewer", "alerts.json");
        _history = Load();
    }

    public IReadOnlyList<UsageAlert> Evaluate(UsageSnapshot? codex, string? codexError,
                                            UsageSnapshot? claude, string? claudeError, bool claudeStale,
                                            DateTimeOffset now, bool suppressed = false)
    {
        List<UsageAlert> alerts = new List<UsageAlert>();
        bool changed = false;
        bool cooldown = _history.LastAlertAt != null && now >= _history.LastAlertAt &&
                        now - _history.LastAlertAt < TimeSpan.FromMinutes(1);
        changed |= EvaluateProvider("codex", "Codex", codex, codexError, false, now, suppressed || cooldown, alerts);
        changed |= EvaluateProvider("claude", "Claude", claude, claudeError, claudeStale, now, suppressed || cooldown, alerts);
        if (alerts.Count > 0)
        {
            _history = _history with { LastAlertAt = now };
        }

        if (changed == true)
        {
            Save(now);
        }

        return alerts;
    }

    private bool EvaluateProvider(string id, string name, UsageSnapshot? snapshot, string? error, bool stale,
                                  DateTimeOffset now, bool suppressed, List<UsageAlert> alerts)
    {
        if (UsageAlertPolicy.IsFresh(snapshot, error, stale, now) == false)
        {
            return false;
        }

        bool changed = false;
        foreach (UsageBucket bucket in snapshot!.Buckets)
        {
            for (int index = 0; index < 2; index++)
            {
                UsageWindow? window = index == 0 ? bucket.Primary : bucket.Secondary;
                if (window == null)
                {
                    continue;
                }

                string keyText = string.Join("|", id, bucket.Id, index.ToString(CultureInfo.InvariantCulture),
                                             window.DurationMinutes?.ToString(CultureInfo.InvariantCulture),
                                             window.ResetsAt?.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));
                string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(keyText)));
                _history.Entries.TryGetValue(key, out UsageAlertEntry? previous);
                UsageAlertLevel level = UsageAlertPolicy.GetLevel(window, now);
                if (level == UsageAlertLevel.None)
                {
                    if (window.UsedPercent >= 0 && window.UsedPercent <= 85 && previous != null)
                    {
                        changed |= _history.Entries.Remove(key);
                    }

                    continue;
                }

                if (suppressed == true || (previous != null && previous.Level >= level))
                {
                    continue;
                }

                _history.Entries[key] = new UsageAlertEntry(level, now);
                alerts.Add(new UsageAlert(id, name, window, level));
                changed = true;
            }
        }

        return changed;
    }

    private UsageAlertHistory Load()
    {
        try
        {
            if (File.Exists(_path) == true && new FileInfo(_path).Length <= 65536)
            {
                UsageAlertHistory? history = JsonSerializer.Deserialize<UsageAlertHistory>(File.ReadAllText(_path));
                if (history?.Entries != null && history.Entries.Count <= 128 &&
                    history.Entries.All(pair => pair.Key.Length == 64 && pair.Key.All(Uri.IsHexDigit) == true &&
                                               pair.Value != null && pair.Value.Level is UsageAlertLevel.Warning or
                                               UsageAlertLevel.Critical) == true)
                {
                    return history;
                }
            }
        }
        catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException ||
                                          exception is JsonException)
        {
        }

        return new UsageAlertHistory(new Dictionary<string, UsageAlertEntry>());
    }

    private void Save(DateTimeOffset now)
    {
        _history = _history with
        {
            Entries = _history.Entries.Where(pair => now - pair.Value.UpdatedAt <= TimeSpan.FromDays(14))
                .OrderByDescending(pair => pair.Value.UpdatedAt).Take(128).ToDictionary(pair => pair.Key, pair => pair.Value)
        };
        string temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
            File.WriteAllText(temporary, JsonSerializer.Serialize(_history));
            File.Move(temporary, _path, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException)
        {
            // Keep the in-memory latch even if persistence is unavailable; never repeatedly sound on refresh.
        }
        finally
        {
            try
            {
                File.Delete(temporary);
            }
            catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException)
            {
            }
        }
    }
}
