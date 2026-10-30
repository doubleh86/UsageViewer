namespace UsageViewer.UI;

internal static class PopupPlacementHelper
{
    public static Point Calculate(Rectangle work, Size popup, int gap)
    {
        int x = work.Right - popup.Width - gap;
        int y = work.Bottom - popup.Height - gap;

        int minX = work.Left + gap;
        int minY = work.Top + gap;

        return new Point(Math.Clamp(x, minX, Math.Max(minX, work.Right - popup.Width - gap)),
                         Math.Clamp(y, minY, Math.Max(minY, work.Bottom - popup.Height - gap)));
    }

    public static Point CalculateTop(Rectangle work, Size bar, double position)
    {
        double fraction = double.IsFinite(position) == true ? Math.Clamp(position, 0, 1) : 0.5;
        int desired = work.Left + (int)Math.Round(work.Width * fraction - bar.Width / 2d);

        return new Point(Math.Clamp(desired, work.Left, Math.Max(work.Left, work.Right - bar.Width)), work.Top);
    }

    public static Point CalculateBelow(Rectangle work, Size popup, Rectangle bar)
    {
        int x = Math.Clamp(bar.Left + (bar.Width - popup.Width) / 2,
                           work.Left, Math.Max(work.Left, work.Right - popup.Width));
        int y = Math.Clamp(bar.Bottom, work.Top, Math.Max(work.Top, work.Bottom - popup.Height));

        return new Point(x, y);
    }
}
