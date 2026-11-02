using UsageViewer.Models;
using UsageViewer.Services;
using UsageViewer.UI;

namespace UsageViewer;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly CodexUsageClient _client = new CodexUsageClient();
    private readonly AiInstallationDetector _installationDetector = new AiInstallationDetector();
    private readonly ClaudeUsageStore _claudeStore = new ClaudeUsageStore();
    private readonly string _claudeWebCachePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "UsageViewer", "claude-web-usage.json");
    private readonly CancellationTokenSource _shutdown = new CancellationTokenSource();
    private readonly UsagePopup _popup = new UsagePopup();
    private readonly TopUsageBar _topBar = new TopUsageBar();
    private readonly UsageAlertMonitor _alerts = new UsageAlertMonitor();
    private readonly UsageAlertSound _alertSound = new UsageAlertSound();
    private readonly UsageAlertToast _alertToast = new UsageAlertToast();
    private readonly NotifyIcon _tray;
    private readonly ContextMenuStrip _menu = new ContextMenuStrip();
    private readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer { Interval = 5_000 };
    private readonly ToolStripItem _refreshMenuItem;
    private readonly ToolStripMenuItem _topBarMenuItem;
    private readonly ToolStripMenuItem _alwaysOnTopMenuItem;
    private readonly ToolStripMenuItem _alertSoundMenuItem;
    private readonly RegisteredWaitHandle _showRegistration;
    private Icon _icon;
    private UsageSnapshot? _snapshot;
    private Task? _activeRefresh;
    private string? _error;
    private bool _refreshing;
    private bool _exiting;
    private Point? _lastTrayAnchor;
    private UsageSnapshot? _claudeSnapshot;
    private string? _claudeError = "한 번 연결하면 자동으로 갱신됩니다.";
    private bool _claudeStale;
    private bool _claudeReading;
    private DateTimeOffset _lastCodexAttempt;
    private DateTimeOffset _lastClaudeWebRefresh;
    private ClaudeConnectionWindow? _claudeConnection;
    private CodexConnectionWindow? _codexConnection;
    private string? _claudeWebError;
    private IReadOnlyList<DetectedAiApp> _installed = Array.Empty<DetectedAiApp>();

    public TrayApplicationContext(bool showOnStart, EventWaitHandle showSignal)
    {
        _icon = TrayIconFactory.Create(Color.FromArgb(151, 164, 181));
        _installed = _installationDetector.Detect();
        _popup.SetDetectedApps(_installed);
        _menu.Items.Add("사용량 보기", null, (_, _) => ShowPopup(_lastTrayAnchor ?? Cursor.Position));
        _refreshMenuItem = _menu.Items.Add("새로고침", null, async (_, _) => await RefreshAsync());
        _menu.Items.Add("Codex 구독 연결 / 계정 확인", null, async (_, _) => await ConnectCodexAsync());
        _menu.Items.Add("Claude 구독 연결 / 계정 확인", null, async (_, _) => await GetClaudeConnection().ConnectAsync());
        _menu.Items.Add(new ToolStripSeparator());
        _topBarMenuItem = new ToolStripMenuItem("모니터 상단에 표시") { CheckOnClick = true };
        _alwaysOnTopMenuItem = new ToolStripMenuItem("항상 가장 앞에 표시") { CheckOnClick = true };
        _menu.Items.Add(_topBarMenuItem);
        _menu.Items.Add(_alwaysOnTopMenuItem);
        _alertSoundMenuItem = new ToolStripMenuItem("잔여량 경고음") { CheckOnClick = true };
        _menu.Items.Add(_alertSoundMenuItem);
        _alertSoundMenuItem.Click += (_, _) => _popup.SetAlertSoundEnabled(_alertSoundMenuItem.Checked);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("종료", null, async (_, _) => await ExitAsync());
        _topBarMenuItem.Click += (_, _) =>
            _popup.SetWindowOptions(_topBarMenuItem.Checked, _alwaysOnTopMenuItem.Checked);
        _alwaysOnTopMenuItem.Click += (_, _) =>
            _popup.SetWindowOptions(_topBarMenuItem.Checked, _alwaysOnTopMenuItem.Checked);
        _popup.WindowPreferencesChanged += (_, _) => ApplyWindowPreferences();
        _popup.VisibleChanged += (_, _) => _topBar.SetDetailsOpen(_popup.Visible == true && _popup.IsDocked == true);
        _topBar.ContextMenuStrip = _menu;
        _topBar.PlacementChanged += (_, _) => _popup.SetTopBarPlacement(_topBar.DockScreen, _topBar.DockPosition);
        _topBar.LocationChanged += (_, _) => _popup.MoveBelow(_topBar.Bounds);
        _topBar.SizeChanged += (_, _) => _popup.MoveBelow(_topBar.Bounds);
        _topBar.DetailsRequested += (_, args) =>
        {
            if (args.ProviderId != null)
            {
                ShowPopup(new Point(_topBar.Left, _topBar.Top), true, args.ProviderId);
            }
            else if (_popup.IsDocked == true && (_popup.Visible == true || _popup.JustDeactivated == true))
            {
                _popup.Hide();
            }
            else
            {
                ShowPopup(new Point(_topBar.Left, _topBar.Top), true);
            }
        };
        _tray = new NotifyIcon
        {
            Icon = _icon,
            Text = "UsageViewer · Codex / Claude",
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
        _popup.CodexConnectRequested += async (_, _) => await ConnectCodexAsync();
        _popup.ClaudeConnectRequested += async (_, _) =>
        {
            _popup.Hide();
            await GetClaudeConnection().ConnectAsync();
        };
        _timer.Tick += async (_, _) =>
        {
            if (DateTimeOffset.UtcNow - _lastCodexAttempt >= TimeSpan.FromSeconds(60))
            {
                _ = RefreshAsync();
            }

            if (_claudeConnection != null && DateTimeOffset.UtcNow - _lastClaudeWebRefresh >= TimeSpan.FromSeconds(60))
            {
                _lastClaudeWebRefresh = DateTimeOffset.UtcNow;
                _ = _claudeConnection.RefreshInBackgroundAsync();
            }

            await ReadClaudeAsync();
        };
        UpdatePopup();

        // Ensure an invokable UI handle exists before scheduling the first asynchronous read.
        _ = _popup.Handle;
        ApplyWindowPreferences();
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
            _timer.Start();
            Task codexRefresh = RefreshAsync();
            string profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                           "UsageViewer", "ClaudeWebProfile");
            if (Directory.Exists(profile) == true)
            {
                _ = GetClaudeConnection().ResumeInBackgroundAsync();
            }

            if (showOnStart == true)
            {
                Rectangle area = Screen.PrimaryScreen?.WorkingArea ?? Screen.FromControl(_popup).WorkingArea;
                ShowPopup(new Point(area.Right - 16, area.Bottom));
            }

            await codexRefresh;
        }));
    }

    private Task RefreshAsync()
    {
        if (_refreshing == true || _exiting == true || _codexConnection?.IsConnecting == true)
        {
            return _activeRefresh ?? Task.CompletedTask;
        }

        _activeRefresh = RefreshCoreAsync();

        return _activeRefresh;
    }

    private async Task RefreshCoreAsync()
    {
        _refreshing = true;
        _installed = _installationDetector.Detect();
        _popup.SetDetectedApps(_installed);
        _lastCodexAttempt = DateTimeOffset.UtcNow;
        _refreshMenuItem.Enabled = false;
        UpdatePopup();
        try
        {
            if (_claudeConnection != null)
            {
                _lastClaudeWebRefresh = DateTimeOffset.UtcNow;
                _ = _claudeConnection.RefreshInBackgroundAsync();
            }

            _ = ReadClaudeAsync();
            if (_installed.Any(app => app.Id == "codex") == true)
            {
                _snapshot = await _client.ReadAsync(_shutdown.Token);
                _error = null;
            }
            else
            {
                _snapshot = null;
                _error = "Codex 설치를 찾지 못했습니다.";
            }
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
                UpdatePopup();
                UpdateTray();
            }
        }
    }

    private void ApplyWindowPreferences()
    {
        PopupPreferences preferences = _popup.Preferences;
        _topBarMenuItem.Checked = preferences.ShowTopBar;
        _alwaysOnTopMenuItem.Checked = preferences.AlwaysOnTop;
        _alertSoundMenuItem.Checked = preferences.AlertSoundEnabled;
        if (preferences.AlertSoundEnabled == false)
        {
            _alertSound.Stop();
        }

        _topBar.ApplyPreferences(preferences);
        if (preferences.ShowTopBar == false && _popup.IsDocked == true)
        {
            _popup.Hide();
        }
    }

    private void ShowPopup(Point anchor, bool fromTopBar = false, string? providerId = null)
    {
        if (_exiting == true)
        {
            return;
        }

        UpdatePopup();
        if (fromTopBar == true)
        {
            _popup.ShowBelow(_topBar.Bounds, providerId);
        }
        else
        {
            _popup.ShowAt(anchor);
        }

        _topBar.SetDetailsOpen(fromTopBar);
        _ = ReadClaudeAsync();
        bool oldSnapshot = _snapshot == null || DateTimeOffset.UtcNow - _snapshot.RetrievedAt >= TimeSpan.FromSeconds(60);
        bool expiredWindow = _snapshot?.Buckets.Any(bucket =>
            (bucket.Primary != null && UsageDisplayHelper.IsExpired(bucket.Primary) == true) ||
            (bucket.Secondary != null && UsageDisplayHelper.IsExpired(bucket.Secondary) == true)) == true;
        if (oldSnapshot == true || expiredWindow == true)
        {
            _ = RefreshAsync();
        }
    }

    private async Task ReadClaudeAsync()
    {
        if (_claudeReading == true || _exiting == true)
        {
            return;
        }

        _claudeReading = true;
        try
        {
            bool webSource = File.Exists(_claudeWebCachePath);
            ClaudeUsageStore source = webSource == true ? new ClaudeUsageStore(_claudeWebCachePath) : _claudeStore;
            ClaudeUsageReadResult result = await source.ReadAsync(_shutdown.Token);
            _claudeSnapshot = webSource == true ? result.Snapshot with { PlanName = "Claude Web" } : result.Snapshot;
            _claudeStale = result.IsStale;
            _claudeError = _claudeWebError;
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested == true)
        {
            return;
        }
        catch (UsageQueryException exception)
        {
            _claudeSnapshot = null;
            _claudeError = File.Exists(_claudeWebCachePath) == true ? exception.Message :
                           "한 번 연결하면 자동으로 갱신됩니다.";
        }
        catch (Exception)
        {
            _claudeError = "Claude 사용량 수신 파일을 읽지 못했습니다. 다음 수신을 기다려 주세요.";
            _claudeStale = true;
        }
        finally
        {
            _claudeReading = false;
            if (_exiting == false)
            {
                UpdatePopup();
                UpdateTray();
            }
        }
    }

    private void UpdatePopup()
    {
        _popup.SetState(_snapshot, _refreshing, _error, _claudeSnapshot, _claudeError, _claudeStale);
        _topBar.SetUsage(_installed, _snapshot, _error, _claudeSnapshot, _claudeError, _claudeStale);
        if (_exiting == false)
        {
            IReadOnlyList<UsageAlert> alerts = _alerts.Evaluate(_snapshot, _error, _claudeSnapshot, _claudeError,
                                                               _claudeStale, DateTimeOffset.UtcNow, _topBar.IsFullScreen);
            if (alerts.Count > 0)
            {
                _alertToast.ShowAlerts(alerts, _topBar.Location);
                if (_popup.Preferences.AlertSoundEnabled == true &&
                    alerts.Any(alert => alert.Level == UsageAlertLevel.Critical) == true)
                {
                    _alertSound.Play();
                }
            }
        }
    }

    private ClaudeConnectionWindow GetClaudeConnection()
    {
        if (_claudeConnection == null)
        {
            _claudeConnection = new ClaudeConnectionWindow(new ClaudeUsageStore(_claudeWebCachePath));
            _claudeConnection.UsageReceived += async (_, _) =>
            {
                _claudeWebError = null;
                await ReadClaudeAsync();
            };
            _claudeConnection.ConnectionError += (_, message) =>
            {
                _claudeWebError = message;
                _claudeError = message;
                if (_exiting == false)
                {
                    UpdatePopup();
                }
            };
        }

        return _claudeConnection;
    }

    private async Task ConnectCodexAsync()
    {
        _popup.Hide();
        if (_activeRefresh != null)
        {
            await _activeRefresh;
        }

        if (_exiting == true)
        {
            return;
        }

        if (_codexConnection == null)
        {
            _codexConnection = new CodexConnectionWindow(_client);
            _codexConnection.UsageReceived += (_, snapshot) =>
            {
                if (_exiting == true)
                {
                    return;
                }

                _snapshot = snapshot;
                _error = null;
                _lastCodexAttempt = DateTimeOffset.UtcNow;
                UpdatePopup();
                UpdateTray();
            };
            _codexConnection.ConnectionError += (_, error) =>
            {
                if (_exiting == true)
                {
                    return;
                }

                _error = error;
                UpdatePopup();
                UpdateTray();
            };
        }

        await _codexConnection.ConnectAsync(_shutdown.Token);
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
        if (_claudeSnapshot != null && _claudeError == null && _claudeStale == false)
        {
            List<UsageWindow> claudeWindows = _claudeSnapshot.Buckets
                .SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary }).OfType<UsageWindow>()
                .Where(window => UsageDisplayHelper.IsExpired(window) == false).ToList();
            if (claudeWindows.Count > 0)
            {
                double highestClaude = claudeWindows.Max(window => window.UsedPercent);
                tooltip += $" | Claude {UsageDisplayHelper.FormatPercent(100 - highestClaude)} 남음";
                if (_snapshot == null || _error != null)
                {
                    color = UsageDisplayHelper.GetUsageColor(highestClaude);
                }
            }
        }

        _icon = TrayIconFactory.Create(color);
        _tray.Icon = _icon;
        _tray.Text = tooltip.Length > 127 ? tooltip.Substring(0, 127) : tooltip;
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
        _topBar.CloseForExit();
        _alertSound.Stop();
        _alertToast.Hide();
        if (_activeRefresh != null)
        {
            await _activeRefresh;
        }

        if (_codexConnection?.ActiveConnection != null)
        {
            await _codexConnection.ActiveConnection;
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
            _topBar.Dispose();
            _alertSound.Dispose();
            _alertToast.Dispose();
            _claudeConnection?.Dispose();
            _codexConnection?.Dispose();
            _shutdown.Dispose();
        }

        base.Dispose(disposing);
    }
}
