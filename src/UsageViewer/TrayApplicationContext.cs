using UsageViewer.Models;
using UsageViewer.Services;
using UsageViewer.UI;

namespace UsageViewer;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly CodexUsageClient _client = new CodexUsageClient();
    private readonly CancellationTokenSource _shutdown = new CancellationTokenSource();
    private readonly UsagePopup _popup = new UsagePopup();
    private readonly NotifyIcon _tray;
    private readonly ContextMenuStrip _menu = new ContextMenuStrip();
    private readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer { Interval = 60_000 };
    private readonly ToolStripItem _refreshMenuItem;
    private readonly RegisteredWaitHandle _showRegistration;
    private Icon _icon;
    private UsageSnapshot? _snapshot;
    private Task? _activeRefresh;
    private string? _error;
    private bool _refreshing;
    private bool _exiting;
    private Point? _lastTrayAnchor;

    public TrayApplicationContext(bool showOnStart, EventWaitHandle showSignal)
    {
        _icon = TrayIconFactory.Create(Color.FromArgb(151, 164, 181));
        _menu.Items.Add("사용량 보기", null, (_, _) => ShowPopup(_lastTrayAnchor ?? Cursor.Position));
        _refreshMenuItem = _menu.Items.Add("새로고침", null, async (_, _) => await RefreshAsync());
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("종료", null, async (_, _) => await ExitAsync());
        _tray = new NotifyIcon
        {
            Icon = _icon,
            Text = "Codex 사용량 · 연결 준비 중",
            ContextMenuStrip = _menu,
            Visible = true
        };
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == MouseButtons.Left)
            {
                if (_popup.Visible == true || _popup.JustDeactivated == true)
                {
                    _popup.Hide();
                }
                else
                {
                    ShowPopup(_lastTrayAnchor ?? Cursor.Position);
                }
            }
        };
        _tray.MouseDown += (_, _) => _lastTrayAnchor = Cursor.Position;
        _popup.RefreshRequested += async (_, _) => await RefreshAsync();
        _timer.Tick += async (_, _) => await RefreshAsync();
        _popup.SetState(null, true, null);

        // Ensure an invokable UI handle exists before scheduling the first asynchronous read.
        _ = _popup.Handle;
        _showRegistration = ThreadPool.RegisterWaitForSingleObject(showSignal, (_, _) =>
        {
            try
            {
                _popup.BeginInvoke(new Action(() =>
                {
                    Rectangle area = Screen.PrimaryScreen?.WorkingArea ?? Screen.FromControl(_popup).WorkingArea;
                    ShowPopup(_lastTrayAnchor ?? new Point(area.Right - 16, area.Bottom));
                }));
            }
            catch (InvalidOperationException)
            {
                // A duplicate launch can race with application shutdown.
            }
        }, null, Timeout.Infinite, false);
        _popup.BeginInvoke(new Action(async () =>
        {
            if (showOnStart == true)
            {
                Rectangle area = Screen.PrimaryScreen?.WorkingArea ?? Screen.FromControl(_popup).WorkingArea;
                ShowPopup(new Point(area.Right - 16, area.Bottom));
            }

            await RefreshAsync();
            if (_exiting == false)
            {
                _timer.Start();
            }
        }));
    }

    private Task RefreshAsync()
    {
        if (_refreshing == true || _exiting == true)
        {
            return _activeRefresh ?? Task.CompletedTask;
        }

        _activeRefresh = RefreshCoreAsync();

        return _activeRefresh;
    }

    private async Task RefreshCoreAsync()
    {
        _refreshing = true;
        _refreshMenuItem.Enabled = false;
        _popup.SetState(_snapshot, true, _error);
        try
        {
            _snapshot = await _client.ReadAsync(_shutdown.Token);
            _error = null;
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested == true)
        {
            return;
        }
        catch (UsageQueryException exception)
        {
            _error = exception.Message;
        }
        catch (Exception)
        {
            // Never surface raw provider/process exceptions, which can include private details.
            _error = "사용량 조회 중 오류가 발생했습니다. Codex 로그인 상태를 확인한 뒤 다시 시도해 주세요.";
        }
        finally
        {
            _refreshing = false;
            if (_exiting == false)
            {
                _refreshMenuItem.Enabled = true;
                _popup.SetState(_snapshot, false, _error);
                UpdateTray();
            }
        }
    }

    private void ShowPopup(Point anchor)
    {
        if (_exiting == true)
        {
            return;
        }

        _popup.SetState(_snapshot, _refreshing, _error);
        _popup.ShowAt(anchor);
        bool oldSnapshot = _snapshot == null || DateTimeOffset.UtcNow - _snapshot.RetrievedAt >= TimeSpan.FromSeconds(60);
        bool expiredWindow = _snapshot?.Buckets.Any(bucket =>
            (bucket.Primary != null && UsageDisplayHelper.IsExpired(bucket.Primary) == true) ||
            (bucket.Secondary != null && UsageDisplayHelper.IsExpired(bucket.Secondary) == true)) == true;
        if (oldSnapshot == true || expiredWindow == true)
        {
            _ = RefreshAsync();
        }
    }

    private void UpdateTray()
    {
        Color color = Color.FromArgb(151, 164, 181);
        string tooltip = _error == null ? "Codex 사용량 · 조회 대기" : "Codex 사용량 · 조회 실패 (클릭하여 확인)";
        if (_snapshot != null && _error == null)
        {
            List<UsageWindow> windows = _snapshot.Buckets.SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary })
                .Where(window => window != null && UsageDisplayHelper.IsExpired(window) == false)
                .Select(window => window!).ToList();
            if (windows.Count > 0)
            {
                double highestUsage = windows.Max(window => window.UsedPercent);
                color = UsageDisplayHelper.GetUsageColor(highestUsage);
                tooltip = $"Codex · 최소 {UsageDisplayHelper.FormatPercent(100 - highestUsage)} 남음 · 클릭하여 보기";
            }
            else
            {
                tooltip = "Codex 사용량 · 초기화 후 갱신 필요";
            }
        }

        Icon previousIcon = _icon;
        _icon = TrayIconFactory.Create(color);
        _tray.Icon = _icon;
        _tray.Text = tooltip;
        previousIcon.Dispose();
    }

    private async Task ExitAsync()
    {
        if (_exiting == true)
        {
            return;
        }

        _exiting = true;
        _timer.Stop();
        _shutdown.Cancel();
        _popup.Hide();
        if (_activeRefresh != null)
        {
            await _activeRefresh;
        }

        _tray.Visible = false;
        _popup.CloseForExit();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing == true)
        {
            _shutdown.Cancel();
            _showRegistration.Unregister(null);
            _timer.Dispose();
            _tray.Dispose();
            _menu.Dispose();
            _icon.Dispose();
            _popup.Dispose();
            _shutdown.Dispose();
        }

        base.Dispose(disposing);
    }
}
