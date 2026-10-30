using System.Globalization;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class ClaudeWebUsageParser
{
    public ClaudeUsageCache Parse(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new UsageQueryException("Claude 사용량 응답 형식을 확인할 수 없습니다.");
        }

        UsageWindow? fiveHour = ReadWindow(root, "five_hour", 300);
        UsageWindow? sevenDay = ReadWindow(root, "seven_day", 10080);
        if (fiveHour == null && sevenDay == null)
        {
            throw new UsageQueryException("Claude 페이지가 표시 가능한 5시간·주간 한도를 반환하지 않았습니다.");
        }

        return new ClaudeUsageCache(DateTimeOffset.UtcNow, fiveHour, sevenDay);
    }

    private UsageWindow? ReadWindow(JsonElement root, string property, int minutes)
    {
        if (root.TryGetProperty(property, out JsonElement window) == false || window.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (window.ValueKind != JsonValueKind.Object ||
            window.TryGetProperty("utilization", out JsonElement used) == false ||
            used.ValueKind != JsonValueKind.Number || used.TryGetDouble(out double percent) == false ||
            double.IsFinite(percent) == false || percent < 0 || percent > 100)
        {
            throw new UsageQueryException("Claude 사용 비율 응답이 예상 형식과 다릅니다.");
        }

        DateTimeOffset? resetTime = null;
        if (window.TryGetProperty("resets_at", out JsonElement reset) == true && reset.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(reset.GetString(), CultureInfo.InvariantCulture,
                                    DateTimeStyles.AssumeUniversal, out DateTimeOffset parsed) == true)
        {
            resetTime = parsed;
        }

        return new UsageWindow(percent, minutes, resetTime);
    }
}
