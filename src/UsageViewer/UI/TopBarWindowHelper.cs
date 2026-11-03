namespace UsageViewer.UI;

internal static class TopBarWindowHelper
{
    public static bool IsFullScreen(long style, Rectangle window, Rectangle screen)
    {
        const long captionOrResizeFrame = 0x00C00000 | 0x00040000;

        return (style & captionOrResizeFrame) == 0 && window.Width > 0 && window.Height > 0 &&
               window.Left <= screen.Left && window.Top <= screen.Top &&
               window.Right >= screen.Right && window.Bottom >= screen.Bottom;
    }
}
