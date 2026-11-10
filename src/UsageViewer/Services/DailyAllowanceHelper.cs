namespace UsageViewer.Services;

internal static class DailyAllowanceHelper
{
    public static decimal CalculateTarget(decimal remaining, DateTimeOffset startedAt, DateTimeOffset resetsAt,
                                          TimeZoneInfo zone)
    {
        DateTime boundary = DateTime.SpecifyKind(TimeZoneInfo.ConvertTime(startedAt, zone).Date.AddDays(1),
                                                DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(boundary) == true)
        {
            boundary = boundary.AddMinutes(1);
        }

        TimeSpan offset = zone.IsAmbiguousTime(boundary) == true ? zone.GetAmbiguousTimeOffsets(boundary).Max() :
                          zone.GetUtcOffset(boundary);
        DateTimeOffset end = new DateTimeOffset(boundary, offset);
        if (resetsAt < end)
        {
            end = resetsAt;
        }

        return remaining * (end - startedAt).Ticks / (resetsAt - startedAt).Ticks;
    }
}
