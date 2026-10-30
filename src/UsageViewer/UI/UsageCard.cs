using System.Drawing.Drawing2D;
using UsageViewer.Models;

namespace UsageViewer.UI;

internal sealed class UsageCard : Control
{
    private readonly string _bucketName;
    private readonly string _windowName;
    private readonly UsageWindow _window;
    private readonly bool _isStale;

    public UsageCard(string bucketName, string windowName, UsageWindow window, bool isStale)
    {
        _bucketName = bucketName;
        _windowName = windowName;
        _window = window;
        _isStale = isStale;
        DoubleBuffered = true;
        BackColor = Color.FromArgb(30, 35, 43);
        AccessibleRole = AccessibleRole.StaticText;
        AccessibleName = $"{bucketName}, {windowName}, {UsageDisplayHelper.FormatPercent(window.UsedPercent)} 사용, " +
                         $"{UsageDisplayHelper.FormatReset(window)}";
        if (isStale == true)
        {
            AccessibleName += ", 이전 조회 값";
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        float scale = DeviceDpi / 96f;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using Pen border = new Pen(Color.FromArgb(48, 55, 65));
        e.Graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1);

        bool expired = UsageDisplayHelper.IsExpired(_window);
        Color muted = Color.FromArgb(151, 164, 181);
        Color main = Color.FromArgb(239, 243, 249);
        Color accent = expired == true || _isStale == true ? muted : UsageDisplayHelper.GetUsageColor(_window.UsedPercent);
        using Font titleFont = new Font("Segoe UI", 10, FontStyle.Bold);
        using Font detailFont = new Font("Segoe UI", 8.5f);
        using Font numberFont = new Font("Segoe UI", 26, FontStyle.Bold);

        DrawText(e.Graphics, _windowName, titleFont, main, 18, 14, 180, 24, scale);
        DrawText(e.Graphics, _bucketName, detailFont, muted, 18, 39, 230, 20, scale);
        string number = expired == true ? "—" : UsageDisplayHelper.FormatPercent(_window.RemainingPercent);
        DrawText(e.Graphics, number, numberFont, accent, 16, 59, 210, 48, scale);
        string used = _isStale == true || expired == true ? "이전 조회 값" : "남음";
        DrawText(e.Graphics, used, detailFont, muted, 230, 77, 100, 24, scale, TextFormatFlags.Right);

        int barX = (int)(18 * scale);
        int barY = (int)(116 * scale);
        int barWidth = Width - (int)(36 * scale);
        int barHeight = Math.Max(4, (int)(5 * scale));
        using SolidBrush trackBrush = new SolidBrush(Color.FromArgb(50, 59, 71));
        using SolidBrush valueBrush = new SolidBrush(accent);
        e.Graphics.FillRectangle(trackBrush, barX, barY, barWidth, barHeight);
        if (expired == false)
        {
            e.Graphics.FillRectangle(valueBrush, barX, barY, (float)(barWidth * _window.UsedPercent / 100), barHeight);
        }

        DrawText(e.Graphics, $"{UsageDisplayHelper.FormatPercent(_window.UsedPercent)} 사용", detailFont, muted,
                 18, 126, 300, 20, scale);
        DrawText(e.Graphics, UsageDisplayHelper.FormatReset(_window), detailFont, muted, 18, 148, 320, 22, scale);
    }

    private void DrawText(Graphics graphics, string text, Font font, Color color, int x, int y, int width,
                          int height, float scale, TextFormatFlags alignment = TextFormatFlags.Left)
    {
        Rectangle bounds = new Rectangle((int)(x * scale), (int)(y * scale), (int)(width * scale), (int)(height * scale));
        TextRenderer.DrawText(graphics, text, font, bounds, color,
                              alignment | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
    }
}
