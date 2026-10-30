using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace UsageViewer.UI;

internal static class TrayIconFactory
{
    public static Icon Create(Color color)
    {
        using Bitmap bitmap = new Bitmap(32, 32);
        using Graphics graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using SolidBrush background = new SolidBrush(Color.FromArgb(26, 33, 42));
        using Pen ring = new Pen(color, 3);
        using Pen mark = new Pen(Color.FromArgb(239, 243, 249), 2.5f);
        graphics.FillEllipse(background, 1, 1, 30, 30);
        graphics.DrawEllipse(ring, 3, 3, 26, 26);
        graphics.DrawLines(mark, new PointF[] { new PointF(14, 11), new PointF(9, 16), new PointF(14, 21) });
        graphics.DrawLines(mark, new PointF[] { new PointF(18, 11), new PointF(23, 16), new PointF(18, 21) });
        IntPtr handle = bitmap.GetHicon();
        try
        {
            using Icon borrowed = Icon.FromHandle(handle);

            return (Icon)borrowed.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
