using UsageViewer.Services;

namespace UsageViewer.UI;

internal sealed class UsageAlertToast : Form
{
    private readonly Label _title;
    private readonly Label _message;
    private readonly System.Windows.Forms.Timer _dismiss = new System.Windows.Forms.Timer { Interval = 6000 };
    private readonly Font _headingFont = new Font("Segoe UI", 10, FontStyle.Bold);
    private readonly Font _bodyFont = new Font("Segoe UI", 9);

    protected override bool ShowWithoutActivation => true;

    public UsageAlertToast()
    {
        Text = "UsageViewer · 잔여량 경고";
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(300, 102);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.FromArgb(46, 25, 32);
        ForeColor = Color.FromArgb(255, 222, 224);
        _title = new Label { Location = new Point(14, 12), Size = new Size(240, 24), Font = _headingFont };
        _message = new Label
        {
            Location = new Point(14, 40), Size = new Size(272, 52), Font = _bodyFont,
            AutoEllipsis = true, UseMnemonic = false
        };
        Button close = new Button
        {
            Text = "×", AccessibleName = "알림 닫기", Location = new Point(264, 8), Size = new Size(28, 28),
            FlatStyle = FlatStyle.Flat, ForeColor = ForeColor, BackColor = BackColor
        };
        close.FlatAppearance.BorderSize = 0;
        close.Click += (_, _) => Dismiss();
        Controls.AddRange(new Control[] { _title, _message, close });
        _dismiss.Tick += (_, _) => Dismiss();
    }

    public void ShowAlerts(IReadOnlyList<UsageAlert> alerts, Point anchor)
    {
        bool critical = alerts.Any(alert => alert.Level == UsageAlertLevel.Critical);
        _title.Text = critical == true ? "레드 얼럿 · 사용 한도 임박" : "사용량 주의 · 잔여 10% 이하";
        _message.Text = string.Join("\n", alerts.OrderByDescending(alert => alert.Level)
            .ThenBy(alert => alert.Window.RemainingPercent).Take(2).Select(alert =>
            $"{alert.ProviderName} · {UsageDisplayHelper.FormatWindow(alert.Window.DurationMinutes, "사용 한도")} " +
            $"{UsageDisplayHelper.FormatPercent(alert.Window.RemainingPercent)} 남음"));
        float scale = DeviceDpi / 96f;
        Rectangle work = Screen.FromPoint(anchor).WorkingArea;
        Location = PopupPlacementHelper.Calculate(work, Size, (int)(12 * scale));
        Show();
        _dismiss.Stop();
        _dismiss.Start();
    }

    private void Dismiss()
    {
        _dismiss.Stop();
        Hide();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing == true)
        {
            _dismiss.Dispose();
            _headingFont.Dispose();
            _bodyFont.Dispose();
        }

        base.Dispose(disposing);
    }
}
