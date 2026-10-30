using System.Text.Json;
using System.Globalization;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class UsageResponseParser
{
    public UsageSnapshot Parse(string planName, JsonElement response)
    {
        List<UsageBucket> buckets = new List<UsageBucket>();
        if (response.TryGetProperty("rateLimitsByLimitId", out JsonElement byId) == true &&
            byId.ValueKind == JsonValueKind.Object)
        {
            foreach (JsonProperty property in byId.EnumerateObject())
            {
                AddBucket(buckets, property.Value, property.Name);
            }
        }

        if (buckets.Count == 0 && response.TryGetProperty("rateLimits", out JsonElement legacy) == true)
        {
            AddBucket(buckets, legacy, "codex");
        }

        // Older servers can return credit details only in the single-bucket view.
        if (response.TryGetProperty("rateLimits", out JsonElement single) == true &&
            single.ValueKind == JsonValueKind.Object)
        {
            string singleId = ReadString(single, "limitId") ?? "codex";
            int index = buckets.FindIndex(bucket => bucket.Id == singleId);
            if (index >= 0 && buckets[index].Credits == null)
            {
                buckets[index] = buckets[index] with { Credits = ReadCredits(single) };
            }
        }

        if (buckets.Count == 0)
        {
            throw new UsageQueryException("계정에서 표시할 사용량 구간을 반환하지 않았습니다. 잠시 후 다시 확인해 주세요.");
        }

        List<UsageBucket> ordered = buckets.OrderBy(bucket => bucket.Id == "codex" ? 0 : 1)
            .ThenBy(bucket => bucket.Name, StringComparer.OrdinalIgnoreCase).ToList();

        return new UsageSnapshot(planName, ordered, DateTimeOffset.UtcNow);
    }

    private void AddBucket(List<UsageBucket> buckets, JsonElement element, string fallbackId)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        UsageWindow? primary = ReadWindow(element, "primary");
        UsageWindow? secondary = ReadWindow(element, "secondary");
        CreditBalance? credits = ReadCredits(element);
        if (primary == null && secondary == null && credits == null)
        {
            return;
        }

        string id = ReadString(element, "limitId") ?? fallbackId;
        string name = ReadString(element, "limitName") ?? (id == "codex" ? "Codex" : id);
        buckets.Add(new UsageBucket(id, name, primary, secondary, credits));
    }

    private CreditBalance? ReadCredits(JsonElement bucket)
    {
        if (bucket.TryGetProperty("credits", out JsonElement credits) == false ||
            credits.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        bool unlimited = credits.TryGetProperty("unlimited", out JsonElement unlimitedValue) == true &&
                         unlimitedValue.ValueKind == JsonValueKind.True;
        bool? hasCredits = null;
        if (credits.TryGetProperty("hasCredits", out JsonElement hasValue) == true &&
            (hasValue.ValueKind == JsonValueKind.True || hasValue.ValueKind == JsonValueKind.False))
        {
            hasCredits = hasValue.GetBoolean();
        }

        decimal? balance = null;
        if (credits.TryGetProperty("balance", out JsonElement value) == true)
        {
            string? text = value.ValueKind == JsonValueKind.String ? value.GetString() :
                           value.ValueKind == JsonValueKind.Number ? value.GetRawText() : null;
            if (decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal parsed) == true &&
                parsed >= 0)
            {
                balance = parsed;
            }
        }

        return new CreditBalance(balance, hasCredits, unlimited);
    }

    private UsageWindow? ReadWindow(JsonElement bucket, string propertyName)
    {
        if (bucket.TryGetProperty(propertyName, out JsonElement window) == false ||
            window.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (window.ValueKind != JsonValueKind.Object ||
            window.TryGetProperty("usedPercent", out JsonElement used) == false ||
            used.ValueKind != JsonValueKind.Number || used.TryGetDouble(out double percent) == false ||
            double.IsFinite(percent) == false || percent < 0 || percent > 100)
        {
            throw new UsageQueryException("사용량 응답 형식이 올바르지 않습니다. Codex 업데이트 후 다시 확인해 주세요.");
        }

        int? durationMinutes = null;
        if (window.TryGetProperty("windowDurationMins", out JsonElement duration) == true &&
            duration.ValueKind == JsonValueKind.Number && duration.TryGetInt32(out int minutes) == true && minutes > 0)
        {
            durationMinutes = minutes;
        }

        DateTimeOffset? resetsAt = null;
        if (window.TryGetProperty("resetsAt", out JsonElement reset) == true &&
            reset.ValueKind == JsonValueKind.Number && reset.TryGetInt64(out long seconds) == true &&
            seconds >= -62135596800 && seconds <= 253402300799)
        {
            resetsAt = DateTimeOffset.FromUnixTimeSeconds(seconds);
        }

        return new UsageWindow(percent, durationMinutes, resetsAt);
    }

    private string? ReadString(JsonElement element, string propertyName)
    {
        if (element.TryGetProperty(propertyName, out JsonElement property) == true &&
            property.ValueKind == JsonValueKind.String)
        {
            string? value = property.GetString();

            return string.IsNullOrWhiteSpace(value) == true ? null : value;
        }

        return null;
    }
}
