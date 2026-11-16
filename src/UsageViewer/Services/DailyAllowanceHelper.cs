namespace UsageViewer.Services;

internal static class DailyAllowanceHelper
{
    public static decimal CalculateTarget(decimal remaining, DateTimeOffset startedAt, DateTimeOffset resetsAt,
                                          TimeZoneInfo zone)
    {
        DateTimeOffset end = GetNextDayStart(startedAt, zone);
        if (resetsAt < end)
        {
            end = resetsAt;
        }

        return remaining * (end - startedAt).Ticks / (resetsAt - startedAt).Ticks;
    }

    public static decimal? CalculateTomorrowEstimate(decimal remaining, decimal todayRemaining, DateTimeOffset now,
                                                     DateTimeOffset resetsAt, TimeZoneInfo zone)
    {
        if (remaining <= 0 || resetsAt <= now)
        {
            return null;
        }

        DateTimeOffset tomorrow = GetNextDayStart(now, zone);
        if (resetsAt <= tomorrow)
        {
            return null;
        }

        return CalculateTarget(Math.Max(0, remaining - todayRemaining), tomorrow, resetsAt, zone);
    }

    private static DateTimeOffset GetNextDayStart(DateTimeOffset at, TimeZoneInfo zone)
    {
        DateTime boundary = DateTime.SpecifyKind(TimeZoneInfo.ConvertTime(at, zone).Date.AddDays(1),
                                                DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(boundary) == true)
        {
            boundary = boundary.AddMinutes(1);
        }

        TimeSpan offset = zone.IsAmbiguousTime(boundary) == true ? zone.GetAmbiguousTimeOffsets(boundary).Max() :
                          zone.GetUtcOffset(boundary);
        return new DateTimeOffset(boundary, offset);
    }
}
