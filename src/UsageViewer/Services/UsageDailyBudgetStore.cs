using System.Globalization;
using System.Text;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class UsageDailyBudgetStore
{
    private readonly string _path;

    public UsageDailyBudgetStore(string? path = null)
    {
        _path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                     "UsageViewer", "daily-budget.json");
    }

    public UsageDailyBudgetLoadResult Load()
    {
        try
        {
            // File.Exists also returns false on access errors. Opening explicitly keeps those errors visible.
            using FileStream stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length > 65536)
            {
                return new UsageDailyBudgetLoadResult(null, "일일 기준 상태 크기 오류");
            }

            UsageDailyBudgetState? state = JsonSerializer.Deserialize<UsageDailyBudgetState>(stream);
            if (state?.Version != 1 || state.Entries == null || state.Entries.Count > 128 ||
                state.Entries.All(IsValidEntry) == false ||
                state.Entries.Select(entry => (entry.Provider, entry.LimitKey)).Distinct().Count() != state.Entries.Count)
            {
                return new UsageDailyBudgetLoadResult(null, "일일 기준 상태 손상");
            }

            return new UsageDailyBudgetLoadResult(state);
        }
        catch (FileNotFoundException)
        {
            return new UsageDailyBudgetLoadResult(new UsageDailyBudgetState(1, []));
        }
        catch (DirectoryNotFoundException)
        {
            return new UsageDailyBudgetLoadResult(new UsageDailyBudgetState(1, []));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or
                                          ArgumentException or NotSupportedException)
        {
            return new UsageDailyBudgetLoadResult(null, "일일 기준 상태 읽기 실패 또는 손상");
        }
    }

    public bool Save(IReadOnlyList<UsageDailyBudgetEntry> entries)
    {
        string temporary = _path + ".tmp";
        try
        {
            if (entries.Count > 128 || entries.All(IsValidEntry) == false)
            {
                return false;
            }
            string json = JsonSerializer.Serialize(new UsageDailyBudgetState(1, entries));
            if (Encoding.UTF8.GetByteCount(json) > 65536)
            {
                return false;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
            using (FileStream stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                using StreamWriter writer = new StreamWriter(stream, leaveOpen: true);
                writer.Write(json);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, _path, overwrite: true);

            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                          ArgumentException or NotSupportedException)
        {
            return false;
        }
        finally
        {
            try
            {
                File.Delete(temporary);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                              ArgumentException or NotSupportedException)
            {
                // Do not log local paths or replace the original failure with cleanup errors.
            }
        }
    }

    private bool IsValidEntry(UsageDailyBudgetEntry entry)
    {
        return entry != null && entry.Provider is "codex" or "claude" &&
               IsHash(entry.LimitKey) == true && IsHash(entry.ConfigurationKey) == true &&
               IsHash(entry.TimeZoneKey) == true &&
               DateOnly.TryParseExact(entry.LocalDate, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                      DateTimeStyles.None, out _) == true &&
               entry.BaselineAt <= entry.LastReceivedAt && entry.LastReceivedAt < entry.EndsAt &&
               entry.EndsAt <= entry.ResetsAt && entry.ResetsAt - entry.BaselineAt <= TimeSpan.FromDays(7) &&
               entry.TargetRemainingPercent >= 0 && entry.TargetRemainingPercent <= 100 &&
               decimal.Round(entry.TargetRemainingPercent, 2) == entry.TargetRemainingPercent;
    }

    private bool IsHash(string? value)
    {
        return value?.Length == 64 && value.All(Uri.IsHexDigit) == true;
    }
}
