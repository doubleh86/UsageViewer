using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed record AllowanceCheckpoint(decimal BaselineRemaining, decimal Target, decimal CheckedRemaining,
                                            DateTimeOffset StartedAt, DateTimeOffset CheckedAt,
                                            DateTimeOffset LastReceipt, DateTimeOffset ResetsAt);

internal sealed class DailyUsageAllowanceTracker
{
    private readonly string _path;
    private readonly object _gate = new object();
    private Dictionary<string, AllowanceCheckpoint> _entries = new Dictionary<string, AllowanceCheckpoint>();
    private string? _loadError;
    private bool _saveFailed;
    private int _revision;
    private int _savedRevision;
    private Task _saving = Task.CompletedTask;
    private DateTimeOffset _lastSaveAttempt;

    public DailyUsageAllowanceTracker(string? path = null)
    {
        _path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                     "UsageViewer", "hourly-allowance.json");
        try
        {
            if (File.Exists(_path) == false)
            {
                return;
            }

            if (new FileInfo(_path).Length > 65536)
            {
                throw new JsonException();
            }

            Dictionary<string, AllowanceCheckpoint>? entries =
                JsonSerializer.Deserialize<Dictionary<string, AllowanceCheckpoint>>(File.ReadAllText(_path));
            if (entries == null || entries.Count > 128 || entries.Any(pair => pair.Key.Length != 64 ||
                pair.Key.All(Uri.IsHexDigit) == false || ValidCheckpoint(pair.Value) == false) == true)
            {
                throw new JsonException();
            }

            _entries = entries;
        }
        catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException ||
                                          exception is JsonException)
        {
            _loadError = "오늘 기준 기록을 읽지 못했어요";
        }
    }

    public UsagePacingAdvice Apply(string provider, UsageSnapshot? snapshot, UsagePacingAdvice advice,
                                   DateTimeOffset now, TimeZoneInfo zone)
    {
        lock (_gate)
        {
            return ApplyCore(provider, snapshot, advice, now, zone);
        }
    }

    private UsagePacingAdvice ApplyCore(string provider, UsageSnapshot? snapshot, UsagePacingAdvice advice,
                                        DateTimeOffset now, TimeZoneInfo zone)
    {
        if (snapshot == null || advice.Weekly == null)
        {
            return advice;
        }

        string date = TimeZoneInfo.ConvertTime(now, zone).ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        string receivedDate = TimeZoneInfo.ConvertTime(snapshot.RetrievedAt, zone)
            .ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        List<UsagePacingItem> weekly = new List<UsagePacingItem>();
        foreach (UsagePacingItem item in advice.Weekly)
        {
            string? reason = item.Reason ?? _loadError ?? (_saveFailed == true ? "오늘 기준 기록 저장 실패" : null);
            if (reason == null && item.Average24Hours != null)
            {
                string keyText = string.Join("|", "hourly-v1", provider, item.BucketId, date, zone.ToSerializedString(),
                    item.Window.ResetsAt!.Value.UtcTicks.ToString(CultureInfo.InvariantCulture));
                string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(keyText)));
                decimal remaining = 100m - (decimal)item.Window.UsedPercent;
                if (remaining == 0 && item.Window.RemainingPercent > 0)
                {
                    remaining = (decimal)item.Window.RemainingPercent;
                }

                _entries.TryGetValue(key, out AllowanceCheckpoint? entry);
                if (entry != null && (now < entry.CheckedAt || snapshot.RetrievedAt < entry.LastReceipt))
                {
                    reason = "오늘 기준보다 이전 수신이에요 · 새 수신 필요";
                }
                else if (entry == null && receivedDate != date)
                {
                    reason = "오늘 새로 수신된 한도가 필요해요";
                }
                else
                {
                    bool changed = false;
                    if (entry == null)
                    {
                        decimal target = DailyAllowanceHelper.CalculateTarget(remaining, snapshot.RetrievedAt,
                            item.Window.ResetsAt!.Value, zone);
                        entry = new AllowanceCheckpoint(remaining, target,
                            remaining, snapshot.RetrievedAt, snapshot.RetrievedAt, snapshot.RetrievedAt,
                            item.Window.ResetsAt.Value);
                        changed = true;
                    }
                    else
                    {
                        decimal target = DailyAllowanceHelper.CalculateTarget(entry.BaselineRemaining,
                            entry.StartedAt, entry.ResetsAt, zone);
                        if (entry.Target != target)
                        {
                            entry = entry with { Target = target };
                            changed = true;
                        }
                        if (now - entry.CheckedAt >= TimeSpan.FromHours(1) &&
                            snapshot.RetrievedAt - entry.CheckedAt >= TimeSpan.FromHours(1))
                        {
                            entry = entry with
                            {
                                CheckedRemaining = Math.Min(entry.CheckedRemaining, remaining),
                                CheckedAt = snapshot.RetrievedAt,
                                LastReceipt = snapshot.RetrievedAt
                            };
                            changed = true;
                        }
                    }

                    if (changed == true)
                    {
                        _entries[key] = entry;
                        _entries = _entries.Where(pair => pair.Value.ResetsAt > now)
                            .OrderByDescending(pair => pair.Value.CheckedAt).Take(128)
                            .ToDictionary(pair => pair.Key, pair => pair.Value);
                        _revision++;
                        if (_entries.ContainsKey(key) == false)
                        {
                            weekly.Add(item with { Reason = "오늘 기준 기록 개수 초과", Daily = null,
                                                    Level = UsagePacingLevel.Unavailable });
                            continue;
                        }
                    }

                    decimal used = Math.Max(0, entry.BaselineRemaining - entry.CheckedRemaining);
                    weekly.Add(item with
                    {
                        Daily = new DailyUsageAllowance(entry.Target, used,
                            Math.Min(remaining, Math.Max(0, entry.Target - used)), entry.StartedAt, entry.CheckedAt)
                    });
                    continue;
                }
            }

            weekly.Add(item with { Reason = reason ?? "오늘 기준을 확인하지 못했어요", Daily = null,
                                    Level = UsagePacingLevel.Unavailable });
        }

        UsagePacingAdvice result = advice with { Weekly = weekly };
        string? invalid = weekly.FirstOrDefault(item => item.Reason != null)?.Reason;
        return result with { Level = invalid == null ? result.Limiting?.Level ?? UsagePacingLevel.Unavailable :
                                                      UsagePacingLevel.Unavailable,
                             Reason = advice.Reason ?? invalid };
    }

    public Task SaveAsync()
    {
        lock (_gate)
        {
            if (_loadError == null && _revision != _savedRevision && _saving.IsCompleted == true &&
                (_saveFailed == false || DateTimeOffset.UtcNow - _lastSaveAttempt >= TimeSpan.FromMinutes(1)))
            {
                _saving = SaveCoreAsync();
            }

            return _saving;
        }
    }

    private async Task SaveCoreAsync()
    {
        _lastSaveAttempt = DateTimeOffset.UtcNow;
        string temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
            while (true)
            {
                int revision;
                string json;
                lock (_gate)
                {
                    if (_savedRevision == _revision)
                    {
                        _saveFailed = false;
                        break;
                    }

                    revision = _revision;
                    json = JsonSerializer.Serialize(_entries);
                }
                if (Encoding.UTF8.GetByteCount(json) > 65536)
                {
                    throw new IOException();
                }

                await File.WriteAllTextAsync(temporary, json);
                File.Move(temporary, _path, overwrite: true);
                lock (_gate)
                {
                    _savedRevision = revision;
                }
            }
        }
        catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException)
        {
            lock (_gate)
            {
                _saveFailed = true;
            }
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

    private bool ValidCheckpoint(AllowanceCheckpoint? entry)
    {
        return entry != null && entry.BaselineRemaining is >= 0 and <= 100 && entry.Target >= 0 &&
               entry.Target <= entry.BaselineRemaining && entry.CheckedRemaining >= 0 &&
               entry.CheckedRemaining <= entry.BaselineRemaining && entry.StartedAt != default &&
               entry.CheckedAt >= entry.StartedAt && entry.LastReceipt == entry.CheckedAt &&
               entry.ResetsAt > entry.CheckedAt;
    }
}
