using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer.UI;

internal sealed record TopBarMetric(string Provider, string Period, string Value, bool NeedsAttention);

internal sealed class TopBarDetailsEventArgs(string? providerId) : EventArgs
{
    public string? ProviderId { get; } = providerId;
}

internal sealed class TopUsageBar : Form
{
    private readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer { Interval = 150 };
    private readonly Font _textFont = new Font("Segoe UI", 9.75f);
    private readonly List<TopBarMetric> _metrics = new List<TopBarMetric>();
    private readonly Dictionary<string, UsageAlertLevel> _alertLevels = new Dictionary<string, UsageAlertLevel>();
    private bool _enabled;
    private bool _alwaysOnTop;
    private IntPtr _lastTopMostForeground;
    private bool _detailsOpen;
    private bool _pressed;
    private bool _dragging;
    private bool _allowClose;
    private bool _disposed;
    private bool _layingOut;
    private Point _pressPoint;
    private int _grabOffset;
    private string? _screenName;
    private double _position = 0.5;
    private long _lastFullScreenCheck;
    private bool _fullScreen;

    public string DockScreen => GetDockScreen().DeviceName;
    public double DockPosition => _position;
    public bool IsFullScreen => _fullScreen;
    public event EventHandler<TopBarDetailsEventArgs>? DetailsRequested;
    public event EventHandler? PlacementChanged;

    protected override bool ShowWithoutActivation => true;

    public TopUsageBar()
    {
        Text = "UsageViewer · 상단 사용량";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ShowInTaskbar = false;
        BackColor = Color.FromArgb(23, 29, 37);
        ForeColor = Color.FromArgb(232, 237, 245);
        DoubleBuffered = true;
        SetStyle(ControlStyles.ResizeRedraw, true);
        _timer.Tick += (_, _) => CheckVisibility();
        _timer.Start();
    }

    public void ApplyPreferences(PopupPreferences preferences)
    {
        _enabled = preferences.ShowTopBar;
        _alwaysOnTop = preferences.AlwaysOnTop;
        if (_alwaysOnTop == false)
        {
            _lastTopMostForeground = IntPtr.Zero;
        }
        if (TopMost != preferences.AlwaysOnTop)
        {
            TopMost = preferences.AlwaysOnTop;
        }
        _screenName = preferences.TopBarScreen;
        _position = preferences.TopBarPosition;
        LayoutDock();
        CheckVisibility();
    }

    public void SetUsage(IReadOnlyList<DetectedAiApp> installed, UsageSnapshot? codex, string? codexError,
                         UsageSnapshot? claude, string? claudeError, bool claudeStale)
    {
        _metrics.Clear();
        _alertLevels.Clear();
        SetAlertLevel("Codex", codex, codexError, false);
        SetAlertLevel("Claude", claude, claudeError, claudeStale);
        if (codex != null || installed.Any(app => app.Id == "codex") == true)
        {
            _metrics.Add(CreateMetric("Codex", codex, codexError, false));
        }

        if (claude != null || installed.Any(app => app.Id == "claude") == true)
        {
            _metrics.Add(CreateMetric("Claude", claude, claudeError, claudeStale));
        }

        AccessibleName = _metrics.Count == 0 ? "사용량 조회 대기" :
                         string.Join(" / ", _metrics.Select(metric =>
                             $"{metric.Provider} {metric.Period} {metric.Value}"));
        Invalidate();
    }

    private void SetAlertLevel(string provider, UsageSnapshot? snapshot, string? error, bool stale)
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        if (UsageAlertPolicy.IsFresh(snapshot, error, stale, now) == false)
        {
            return;
        }

        _alertLevels[provider] = snapshot!.Buckets.SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary })
            .OfType<UsageWindow>().Select(window => UsageAlertPolicy.GetLevel(window, now))
            .DefaultIfEmpty(UsageAlertLevel.None).Max();
    }

    public void SetDetailsOpen(bool open)
    {
        _detailsOpen = open;
        UpdateRegion();
        Invalidate();
    }

    public void CloseForExit()
    {
        _enabled = false;
        _timer.Stop();
        _allowClose = true;
        Close();
    }

    private TopBarMetric CreateMetric(string provider, UsageSnapshot? snapshot, string? error, bool stale)
    {
        if (snapshot == null)
        {
            string missing = provider == "Claude" ? "연결 필요" : error == null ? "조회 대기" : "조회 실패";

            return new TopBarMetric(provider, "", missing, true);
        }

        if (stale == true || error != null || snapshot.RetrievedAt > DateTimeOffset.UtcNow ||
            DateTimeOffset.UtcNow - snapshot.RetrievedAt > TimeSpan.FromMinutes(15))
        {
            return new TopBarMetric(provider, "", "갱신 필요", true);
        }

        List<UsageWindow> windows = snapshot.Buckets.SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary })
            .OfType<UsageWindow>().OrderBy(window => window.DurationMinutes ?? int.MaxValue).ToList();
        if (windows.Any(item => double.IsFinite(item.UsedPercent) == false ||
                                item.UsedPercent < 0 || item.UsedPercent > 100) == true)
        {
            return new TopBarMetric(provider, "", "확인 필요", true);
        }
        UsageWindow? window = windows.FirstOrDefault(item => UsageDisplayHelper.IsExpired(item) == false);
        if (_alertLevels.TryGetValue(provider, out UsageAlertLevel level) == true && level != UsageAlertLevel.None)
        {
            window = windows.Where(item => UsageAlertPolicy.GetLevel(item, DateTimeOffset.UtcNow) != UsageAlertLevel.None)
                .OrderBy(item => item.RemainingPercent).FirstOrDefault() ?? window;
        }
        if (window == null)
        {
            return new TopBarMetric(provider, "", windows.Count == 0 ? "한도 미제공" : "갱신 필요", true);
        }

        string period = window.DurationMinutes == 10080 ? "주간" :
                        window.DurationMinutes is int minutes && minutes % 60 == 0 ? $"{minutes / 60}h" : "한도";

        return new TopBarMetric(provider, period, UsageDisplayHelper.FormatPercent(window.RemainingPercent), false);
    }

    private Screen GetDockScreen()
    {
        return Screen.AllScreens.FirstOrDefault(screen => screen.DeviceName == _screenName) ??
               Screen.PrimaryScreen ?? Screen.AllScreens[0];
    }

    private void LayoutDock()
    {
        if (_disposed == true || _layingOut == true)
        {
            return;
        }

        _layingOut = true;
        try
        {
            Screen screen = GetDockScreen();
            float scale = DeviceDpi / 96f;
            Size size = new Size(Math.Min((int)(264 * scale), screen.WorkingArea.Width), (int)(32 * scale));
            Point location = PopupPlacementHelper.CalculateTop(screen.WorkingArea, size, _position);
            Bounds = new Rectangle(location, size);
            UpdateRegion();
        }
        finally
        {
            _layingOut = false;
        }
    }

    private void UpdateRegion()
    {
        using GraphicsPath path = CreateShape(0);
        Region? previous = Region;
        Region = new Region(path);
        previous?.Dispose();
    }

    private GraphicsPath CreateShape(float inset)
    {
        GraphicsPath path = new GraphicsPath();
        if (_detailsOpen == true)
        {
            path.AddRectangle(new RectangleF(inset, inset, Width - 2 * inset, Height - 2 * inset));
            return path;
        }

        float radius = Math.Min(8 * DeviceDpi / 96f, Height / 2f);
        float diameter = radius * 2;
        path.AddLine(inset, inset, Width - inset, inset);
        path.AddArc(Width - diameter - inset, Height - diameter - inset, diameter, diameter, 0, 90);
        path.AddArc(inset, Height - diameter - inset, diameter, diameter, 90, 90);
        path.CloseFigure();

        return path;
    }

    private void CheckVisibility()
    {
        if (_disposed == true)
        {
            return;
        }

        if (Environment.TickCount64 - _lastFullScreenCheck >= 600)
        {
            _lastFullScreenCheck = Environment.TickCount64;
            _fullScreen = IsFullScreenForeground();
        }

        bool visible = _enabled == true && (_fullScreen == false || _dragging == true);
        if (visible != Visible)
        {
            if (visible == true)
            {
                LayoutDock();
                Show();
            }
            else
            {
                Hide();
            }
        }

        if (visible == false)
        {
            _lastTopMostForeground = IntPtr.Zero;
            return;
        }

        Rectangle work = GetDockScreen().WorkingArea;
        if (_dragging == false && (Top != work.Top || Left < work.Left || Right > work.Right))
        {
            LayoutDock();
        }

        EnsureTopMost(GetForegroundWindow());
    }

    private void EnsureTopMost(IntPtr foreground)
    {
        if (_alwaysOnTop == false || _enabled == false || Visible == false || IsHandleCreated == false ||
            _fullScreen == true || _detailsOpen == true || ContextMenuStrip?.Visible == true ||
            foreground == IntPtr.Zero)
        {
            return;
        }

        GetWindowThreadProcessId(foreground, out uint processId);
        if (processId == Environment.ProcessId)
        {
            return;
        }

        bool nativeTopMost = (GetWindowLongPtr(Handle, -20).ToInt64() & 0x00000008) != 0;
        if (nativeTopMost == true && foreground == _lastTopMostForeground)
        {
            return;
        }

        const uint keepPlacementAndFocus = 0x0001 | 0x0002 | 0x0010 | 0x0200;
        if (SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, keepPlacementAndFocus) == true)
        {
            _lastTopMostForeground = foreground;
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left)
        {
            return;
        }

        _pressed = true;
        _dragging = false;
        _pressPoint = Cursor.Position;
        _grabOffset = _pressPoint.X - Left;
        Capture = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        MoveDock(Cursor.Position);
    }

    private void MoveDock(Point cursor)
    {
        if (_pressed == false)
        {
            return;
        }

        if (_dragging == false && Math.Abs(cursor.X - _pressPoint.X) < SystemInformation.DragSize.Width / 2 &&
            Math.Abs(cursor.Y - _pressPoint.Y) < SystemInformation.DragSize.Height / 2)
        {
            return;
        }

        _dragging = true;
        Screen screen = Screen.FromPoint(cursor);
        _screenName = screen.DeviceName;
        Rectangle work = screen.WorkingArea;
        int available = Math.Max(0, work.Width - Width);
        int x = Math.Clamp(cursor.X - _grabOffset, work.Left, work.Left + available);
        _position = work.Width <= 0 ? 0.5 : (x - work.Left + Width / 2d) / work.Width;
        LayoutDock();
        Cursor = Cursors.SizeWE;
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left || _pressed == false)
        {
            return;
        }

        bool moved = _dragging;
        _pressed = false;
        _dragging = false;
        Capture = false;
        Cursor = Cursors.Default;
        if (moved == true)
        {
            PlacementChanged?.Invoke(this, EventArgs.Empty);
        }
        else if (ClientRectangle.Contains(e.Location) == true)
        {
            string? providerId = GetProviderAt(e.Location);
            DetailsRequested?.Invoke(this, new TopBarDetailsEventArgs(providerId));
        }
    }

    private Rectangle GetMetricBounds(int index)
    {
        float scale = DeviceDpi / 96f;
        int left = (int)(26 * scale);
        int right = Width - (int)(22 * scale);
        int width = Math.Max(0, right - left);
        int x = left + width * index / _metrics.Count;
        int end = left + width * (index + 1) / _metrics.Count;

        return new Rectangle(x, 0, end - x, Height);
    }

    private string? GetProviderAt(Point point)
    {
        for (int index = 0; index < _metrics.Count; index++)
        {
            if (GetMetricBounds(index).Contains(point) == true)
            {
                return _metrics[index].Provider == "Codex" ? "codex" : "claude";
            }
        }

        return null;
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        base.OnMouseCaptureChanged(e);
        if (Capture == false && _pressed == true)
        {
            bool moved = _dragging;
            _pressed = false;
            _dragging = false;
            Cursor = Cursors.Default;
            if (moved == true)
            {
                PlacementChanged?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        float scale = DeviceDpi / 96f;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        bool lowUsage = _alertLevels.Values.Any(level => level != UsageAlertLevel.None);
        using Pen border = new Pen(lowUsage == true ? Color.FromArgb(214, 92, 106) : Color.FromArgb(59, 70, 85));
        using GraphicsPath outline = CreateShape(0.5f);
        e.Graphics.DrawPath(border, outline);
        DrawGrip(e.Graphics, 10 * scale, scale);
        int left = (int)(26 * scale);
        int right = Width - (int)(22 * scale);
        if (_metrics.Count == 0)
        {
            DrawText(e.Graphics, "Usage · 조회 대기", new Rectangle(left, 0, right - left, Height), ForeColor);
        }
        else
        {
            for (int index = 0; index < _metrics.Count; index++)
            {
                TopBarMetric metric = _metrics[index];
                Rectangle cell = GetMetricBounds(index);
                int cellWidth = cell.Width;
                int x = cell.Left;
                _alertLevels.TryGetValue(metric.Provider, out UsageAlertLevel level);
                if (level != UsageAlertLevel.None)
                {
                    using SolidBrush warning = new SolidBrush(level == UsageAlertLevel.Critical ?
                                                              Color.FromArgb(92, 36, 48) : Color.FromArgb(61, 32, 42));
                    e.Graphics.FillRectangle(warning, cell.X, 1, cell.Width, Height - 2);
                }

                Color brand = metric.Provider == "Codex" ? Color.FromArgb(104, 223, 195) : Color.FromArgb(223, 170, 138);
                if (metric.Provider == "Codex")
                {
                    DrawText(e.Graphics, "C", new Rectangle(x, 0, (int)(19 * scale), Height), brand);
                }
                else
                {
                    using Pen rays = new Pen(brand, 1.3f * scale);
                    PointF center = new PointF(x + 7 * scale, Height / 2f);
                    for (int ray = 0; ray < 8; ray++)
                    {
                        double angle = ray * Math.PI / 4;
                        e.Graphics.DrawLine(rays, center,
                                            new PointF(center.X + (float)Math.Cos(angle) * 5 * scale,
                                                       center.Y + (float)Math.Sin(angle) * 5 * scale));
                    }
                }
                string text = (level != UsageAlertLevel.None ? "! " : "") +
                              (metric.Period.Length > 0 ? metric.Period + " " : "") + metric.Value;
                DrawText(e.Graphics, text,
                         new Rectangle(x + (int)(19 * scale), 0, cellWidth - (int)(21 * scale), Height),
                         level != UsageAlertLevel.None ? Color.FromArgb(255, 185, 193) :
                         metric.NeedsAttention == true ? Color.FromArgb(175, 187, 204) : ForeColor);
                if (index > 0)
                {
                    e.Graphics.DrawLine(border, x - 5 * scale, 9 * scale, x - 5 * scale, Height - 9 * scale);
                }
            }
        }

        DrawChevron(e.Graphics, Width - 14 * scale, scale);
    }

    private void DrawGrip(Graphics graphics, float x, float scale)
    {
        using SolidBrush dots = new SolidBrush(Color.FromArgb(115, 130, 149));
        for (int row = 0; row < 3; row++)
        {
            for (int column = 0; column < 2; column++)
            {
                graphics.FillEllipse(dots, x + column * 3 * scale, Height / 2f + (row - 1) * 3 * scale,
                                     1.2f * scale, 1.2f * scale);
            }
        }
    }

    private void DrawChevron(Graphics graphics, float x, float scale)
    {
        using Pen arrow = new Pen(Color.FromArgb(156, 170, 189), scale);
        float y = Height / 2f;
        float direction = _detailsOpen == true ? -1 : 1;
        graphics.DrawLines(arrow, new[] { new PointF(x - 3 * scale, y - direction * scale),
                                         new PointF(x, y + direction * 2 * scale),
                                         new PointF(x + 3 * scale, y - direction * scale) });
    }

    private void DrawText(Graphics graphics, string text, Rectangle bounds, Color color)
    {
        TextRenderer.DrawText(graphics, text, _textFont, bounds, color,
                              TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        if (_layingOut == true && IsHandleCreated == true)
        {
            BeginInvoke(new Action(LayoutDock));
        }
        else
        {
            LayoutDock();
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x0021) // WM_MOUSEACTIVATE: hover and dragging must not steal editor focus.
        {
            message.Result = new IntPtr(3); // MA_NOACTIVATE
            return;
        }

        base.WndProc(ref message);
    }

    private bool IsFullScreenForeground()
    {
        IntPtr foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero)
        {
            return false;
        }

        GetWindowThreadProcessId(foreground, out uint processId);
        if (processId == Environment.ProcessId || GetWindowRect(foreground, out NativeWindowRectangle rect) == false)
        {
            return false;
        }

        StringBuilder className = new StringBuilder(128);
        GetClassName(foreground, className, className.Capacity);
        if (className.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd")
        {
            return false;
        }

        if (DwmGetWindowAttribute(foreground, 9, out NativeWindowRectangle frame,
                                  Marshal.SizeOf<NativeWindowRectangle>()) == 0 &&
            frame.Right > frame.Left && frame.Bottom > frame.Top)
        {
            rect = frame;
        }

        long style = GetWindowLongPtr(foreground, -16).ToInt64();

        return TopBarWindowHelper.IsFullScreen(style, Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom),
                                                GetDockScreen().Bounds);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_allowClose == false && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
        }

        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        _disposed = true;
        if (disposing == true)
        {
            _timer.Dispose();
            _textFont.Dispose();
        }

        base.Dispose(disposing);
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr window, out NativeWindowRectangle rectangle);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder className, int maximumCount);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height,
                                            uint flags);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out NativeWindowRectangle value,
                                                    int size);
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeWindowRectangle
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}
