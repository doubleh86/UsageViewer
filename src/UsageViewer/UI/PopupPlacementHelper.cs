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
}
