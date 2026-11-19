using System.Globalization;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class ClaudeWebResponseException(ClaudeRefreshResult result) : Exception
{
    public ClaudeRefreshResult Result { get; } = result;
}

internal sealed class ClaudeWebUsageParser
{
    public ClaudeUsageCache Parse(JsonElement root, DateTimeOffset receivedAt)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new ClaudeWebResponseException(ClaudeRefreshResult.ResponseFormat);
        }

        UsageWindow? fiveHour = ReadWindow(root, "five_hour", 300);
        UsageWindow? sevenDay = ReadWindow(root, "seven_day", 10080);
        if (fiveHour == null && sevenDay == null)
        {
            throw new ClaudeWebResponseException(ClaudeRefreshResult.ResponseFormat);
        }

        return new ClaudeUsageCache(receivedAt, fiveHour, sevenDay);
    }

    private UsageWindow? ReadWindow(JsonElement root, string property, int minutes)
    {
        if (root.TryGetProperty(property, out JsonElement window) == false || window.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (window.ValueKind != JsonValueKind.Object ||
            window.TryGetProperty("utilization", out JsonElement used) == false ||
            used.ValueKind != JsonValueKind.Number)
        {
            throw new ClaudeWebResponseException(ClaudeRefreshResult.ResponseFormat);
        }

        if (used.TryGetDouble(out double percent) == false || double.IsFinite(percent) == false || percent < 0 || percent > 100)
        {
            throw new ClaudeWebResponseException(ClaudeRefreshResult.ResponseRange);
        }

        DateTimeOffset? resetTime = null;
        if (window.TryGetProperty("resets_at", out JsonElement reset) == true && reset.ValueKind != JsonValueKind.Null)
        {
            if (reset.ValueKind != JsonValueKind.String ||
                DateTimeOffset.TryParse(reset.GetString(), CultureInfo.InvariantCulture,
                                        DateTimeStyles.AssumeUniversal, out DateTimeOffset parsed) == false)
            {
                throw new ClaudeWebResponseException(ClaudeRefreshResult.ResponseFormat);
            }

            resetTime = parsed;
        }

        return new UsageWindow(percent, minutes, resetTime);
    }
}
