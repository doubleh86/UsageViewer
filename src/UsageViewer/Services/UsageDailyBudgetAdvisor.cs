using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class UsageDailyBudgetAdvisor
{
    private readonly UsageDailyBudgetStore _store;
    private readonly List<UsageDailyBudgetEntry> _entries;
    private readonly string? _loadError;
    private DateTimeOffset? _lastNow;
    private bool _dirty;

    public UsageDailyBudgetAdvisor(UsageDailyBudgetStore store)
    {
        _store = store;
        UsageDailyBudgetLoadResult loaded = store.Load();
        _entries = loaded.State?.Entries.ToList() ?? [];
        _loadError = loaded.Error;
    }

    public UsageDailyBudget Evaluate(string provider, UsageSnapshot? snapshot, string? error, bool stale,
                                     DateTimeOffset now, TimeZoneInfo zone)
    {
        if (error != null)
        {
            return Unavailable("사용량 조회 실패");
        }
        if (snapshot == null)
        {
            return Unavailable("사용량 미수신");
        }
        if (stale == true || now - snapshot.RetrievedAt > TimeSpan.FromMinutes(15))
        {
            return Unavailable("15분 초과 또는 오래된 수신");
        }
        if (snapshot.RetrievedAt > now)
        {
            return Unavailable("미래 수신 시각");
        }
        if ((_lastNow != null && now < _lastNow) ||
            _entries.Any(entry => entry.Provider == provider && entry.LastReceivedAt > snapshot.RetrievedAt) == true)
        {
            return Unavailable("시각 또는 수신 순서 역행");
        }

        _lastNow = now;
        var windows = snapshot.Buckets.SelectMany(bucket =>
            new[] { bucket.Primary, bucket.Secondary }.OfType<UsageWindow>()
                .Select(window => (Bucket: bucket, Window: window))).ToList();
        if (windows.Count == 0)
        {
            return Unavailable("한도 미수신");
        }
        if (windows.Any(item => double.IsFinite(item.Window.UsedPercent) == false ||
                                item.Window.UsedPercent < 0 || item.Window.UsedPercent > 100) == true)
        {
            return Unavailable("잘못된 잔여량");
        }
        if (windows.Any(item => item.Window.DurationMinutes is not > 0 || item.Window.ResetsAt == null) == true)
        {
            return Unavailable("구간 길이 또는 초기화 시각 미제공");
        }
        if (windows.Any(item => item.Window.ResetsAt <= now) == true)
        {
            return Unavailable("만료된 한도 · 새 수신 필요");
        }
        if (windows.Any(item => (item.Window.ResetsAt!.Value - snapshot.RetrievedAt).TotalMinutes >
                                item.Window.DurationMinutes) == true)
        {
            return Unavailable("초기화 시각이 구간 길이 초과");
        }
        if (provider is not ("codex" or "claude") || snapshot.Buckets.Count > 64 ||
            snapshot.Buckets.Any(bucket => string.IsNullOrWhiteSpace(bucket.Id)) == true ||
            snapshot.Buckets.Select(bucket => bucket.Id).Distinct(StringComparer.Ordinal).Count() != snapshot.Buckets.Count ||
            windows.GroupBy(item => (item.Bucket.Id, item.Window.DurationMinutes)).Any(group => group.Count() > 1) == true)
        {
            return Unavailable("한도 식별 모호함");
        }
        if (_loadError != null)
        {
            return Unavailable(_loadError);
        }

        string day = TimeZoneInfo.ConvertTime(now, zone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        string zoneKey = Hash(zone.ToSerializedString());
        if (_entries.Any(entry => entry.Provider == provider && entry.TimeZoneKey != zoneKey &&
                                 entry.LastReceivedAt >= snapshot.RetrievedAt) == true)
        {
            return Unavailable("시간대 변경 이후 새 수신 대기");
        }
        string configuration = Hash(JsonSerializer.Serialize(windows
            .Select(item => (item.Bucket.Id, Duration: item.Window.DurationMinutes!.Value))
            .OrderBy(item => item.Id, StringComparer.Ordinal).ThenBy(item => item.Duration)
            .Select(item => new { item.Id, item.Duration })));
        var weekly = windows.Where(item => item.Window.DurationMinutes == 10080).ToList();
        if (weekly.Count == 0)
        {
            _dirty |= _entries.RemoveAll(entry => entry.Provider == provider) > 0;
            if (Persist() == false)
            {
                return Unavailable("일일 기준 저장 실패 · 재시작 시 목표 유지 불가");
            }
            return new UsageDailyBudget(UsageDailyBudgetStatus.NotProvided, "주간 한도 미제공");
        }
        if (TimeZoneInfo.ConvertTime(snapshot.RetrievedAt, zone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) != day)
        {
            return Unavailable("자정 이후 새 수신 대기");
        }

        DateTimeOffset midnight = NextMidnight(snapshot.RetrievedAt, zone);
        _dirty |= _entries.RemoveAll(entry => entry.Provider == provider &&
                                             (entry.LocalDate != day || entry.EndsAt <= now ||
                                              entry.TimeZoneKey != zoneKey || entry.ConfigurationKey != configuration)) > 0;
        List<UsageDailyBudgetItem> items = new List<UsageDailyBudgetItem>();
        foreach (var item in weekly)
        {
            string key = Hash(item.Bucket.Id);
            DateTimeOffset reset = item.Window.ResetsAt!.Value;
            UsageDailyBudgetEntry? entry = _entries.Find(entry => entry.Provider == provider && entry.LimitKey == key);
            if (entry != null && entry.ResetsAt != reset)
            {
                _entries.Remove(entry);
                entry = null;
                _dirty = true;
            }
            if (entry == null)
            {
                DateTimeOffset end = reset < midnight ? reset : midnight;
                decimal remaining = (decimal)item.Window.RemainingPercent;
                decimal fraction = Math.Clamp((decimal)(end - snapshot.RetrievedAt).Ticks /
                                               (reset - snapshot.RetrievedAt).Ticks, 0, 1);
                decimal budget = Math.Max(0, remaining - 10) * fraction;
                decimal target = decimal.Ceiling((remaining - budget) * 100) / 100;
                entry = new UsageDailyBudgetEntry(provider, key, configuration, day, zoneKey, snapshot.RetrievedAt,
                                                   snapshot.RetrievedAt, end, reset, target);
                _entries.Add(entry);
                _dirty = true;
            }
            else if (entry.LastReceivedAt != snapshot.RetrievedAt)
            {
                _entries.Remove(entry);
                entry = entry with { LastReceivedAt = snapshot.RetrievedAt };
                _entries.Add(entry);
                _dirty = true;
            }

            decimal additional = decimal.Floor(Math.Max(0, (decimal)item.Window.RemainingPercent -
                                                           entry.TargetRemainingPercent) * 100) / 100;
            string name = snapshot.Buckets.Count > 1 ? item.Bucket.Name + " · 주간 한도" : "주간 한도";
            items.Add(new UsageDailyBudgetItem(name, additional, entry.TargetRemainingPercent,
                                               entry.EndsAt, reset, entry.EndsAt == reset));
        }

        if (Persist() == false)
        {
            return Unavailable("일일 기준 저장 실패 · 재시작 시 목표 유지 불가");
        }

        UsageDailyBudgetStatus status = items.Min(item => item.AdditionalPercentPoints) > 0 ?
                                         UsageDailyBudgetStatus.Ready : UsageDailyBudgetStatus.Exhausted;
        return new UsageDailyBudget(status, Items: items);
    }

    private bool Persist()
    {
        if (_dirty == true)
        {
            _dirty = _store.Save(_entries) == false;
        }
        return _dirty == false;
    }

    private UsageDailyBudget Unavailable(string reason)
    {
        return new UsageDailyBudget(UsageDailyBudgetStatus.Unavailable, reason);
    }

    private string Hash(string value)
    {
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }

    private DateTimeOffset NextMidnight(DateTimeOffset receivedAt, TimeZoneInfo zone)
    {
        DateTime midnight = DateTime.SpecifyKind(TimeZoneInfo.ConvertTime(receivedAt, zone).Date.AddDays(1),
                                                DateTimeKind.Unspecified);
        // Some zones advance at midnight. Choose the first real instant of the new date.
        while (zone.IsInvalidTime(midnight) == true)
        {
            midnight = midnight.AddMinutes(1);
        }
        TimeSpan offset = zone.IsAmbiguousTime(midnight) == true ? zone.GetAmbiguousTimeOffsets(midnight).Max() :
                          zone.GetUtcOffset(midnight);
        return new DateTimeOffset(midnight, offset);
    }
}
