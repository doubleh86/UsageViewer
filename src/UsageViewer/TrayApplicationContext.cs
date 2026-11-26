using UsageViewer.Models;
using UsageViewer.Services;
using UsageViewer.UI;

namespace UsageViewer;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly CodexUsageClient _client = new CodexUsageClient();
    private readonly AiInstallationDetector _installationDetector = new AiInstallationDetector();
    private readonly ClaudeUsageStore _claudeStore = new ClaudeUsageStore();
    private readonly ClaudeUsageStore _claudeWebStore = new ClaudeUsageStore(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "UsageViewer", "claude-web-usage.json"));
    private readonly ClaudeRefreshDiagnostics _claudeDiagnostics = new ClaudeRefreshDiagnostics();
    private readonly ClaudeRefreshCoordinator _claudeRefresh;
    private readonly CancellationTokenSource _shutdown = new CancellationTokenSource();
    private readonly UsagePopup _popup = new UsagePopup();
    private readonly TopUsageBar _topBar = new TopUsageBar();
    private readonly UsageAlertMonitor _alerts = new UsageAlertMonitor();
    private readonly WorkStatusStore _workStore = new WorkStatusStore();
    private readonly System.Windows.Forms.Timer _workTimer = new System.Windows.Forms.Timer { Interval = 1000 };
    private readonly DailyUsageAllowanceTracker _dailyAllowances = new DailyUsageAllowanceTracker();
    private readonly UsageAlertSound _alertSound = new UsageAlertSound();
    private readonly UsageAlertToast _alertToast = new UsageAlertToast();
    private readonly NotifyIcon _tray;
    private readonly ContextMenuStrip _menu = new ContextMenuStrip();
    private readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer { Interval = 5_000 };
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
    private UsageSnapshot? _claudeCodeSnapshot;
    private string? _claudeCodeError = "한 번 연결하면 자동으로 갱신됩니다.";
    private bool _claudeWebSelected;
    private bool _claudeCacheLoaded;
    private bool _claudeReading;
    private DateTimeOffset _lastCodexAttempt;
    private ClaudeConnectionWindow? _claudeConnection;
    private CodexConnectionWindow? _codexConnection;
    private IReadOnlyList<DetectedAiApp> _installed = Array.Empty<DetectedAiApp>();

    public TrayApplicationContext(bool showOnStart, EventWaitHandle showSignal)
    {
        _claudeRefresh = new ClaudeRefreshCoordinator(record: _claudeDiagnostics.Record);
        _icon = TrayIconFactory.Create(Color.FromArgb(151, 164, 181));
        _installed = _installationDetector.Detect();
        _popup.SetDetectedApps(_installed);
        _menu.Items.Add("사용량 보기", null, (_, _) => ShowPopup(_lastTrayAnchor ?? Cursor.Position));
        _menu.Items.Add("새로고침", null, async (_, _) => await RequestRefreshAsync());
        _menu.Items.Add("Codex 주간 초기화 시간 설정…", null, (_, _) => EditCodexWeeklyReset());
        _menu.Items.Add("Codex 구독 연결 / 계정 확인", null, async (_, _) => await ConnectCodexAsync());
        _menu.Items.Add("Claude 구독 연결 / 계정 확인", null, async (_, _) => await ConnectClaudeAsync());
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
        _topBar.VisibleChanged += (_, _) =>
        {
            if (_topBar.Visible == false && _popup.IsDocked == true && _popup.Visible == true)
            {
                _popup.Hide();
            }
        };
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
        _popup.RefreshRequested += async (_, _) => await RequestRefreshAsync();
        _popup.CodexConnectRequested += async (_, _) => await ConnectCodexAsync();
        _popup.ClaudeConnectRequested += async (_, _) =>
        {
            _popup.Hide();
            await ConnectClaudeAsync();
        };
        _claudeRefresh.Changed += (_, _) =>
        {
            if (_exiting == false)
            {
                UpdatePopup();
                UpdateTray();
            }
        };
        _timer.Tick += (_, _) =>
        {
            if (DateTimeOffset.UtcNow - _lastCodexAttempt >= TimeSpan.FromSeconds(60))
            {
                _ = RefreshCodexAsync();
            }

            _claudeRefresh.Expire();
            _claudeDiagnostics.Maintain();
            _ = _claudeConnection?.RefreshAsync(ClaudeRefreshTrigger.Automatic);
            _ = ReadClaudeCodeAsync();
            UpdatePopup();
            UpdateTray();
        };
        CancellationToken workShutdown = _shutdown.Token;
        WorkStatusCollector workCollector = new WorkStatusCollector(_workStore, WorkStatusCollector.DefaultPipeName);
        _ = Task.Run(() => workCollector.ListenAsync(workShutdown));
        _workTimer.Tick += (_, _) => UpdateWorkStatus();
        _workTimer.Start();
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
            Task codexRefresh = RefreshCodexAsync();
            _claudeDiagnostics.Maintain();
            string profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                           "UsageViewer", "ClaudeWebProfile");
            if (Directory.Exists(profile) == true)
            {
                _claudeWebSelected = true;
                _ = GetClaudeConnection().RefreshAsync(ClaudeRefreshTrigger.Automatic);
            }

            _ = LoadClaudeWebCacheAsync();
            if (showOnStart == true)
            {
                Rectangle area = Screen.PrimaryScreen?.WorkingArea ?? Screen.FromControl(_popup).WorkingArea;
                ShowPopup(new Point(area.Right - 16, area.Bottom));
            }

            await codexRefresh;
        }));
    }

    private Task RequestRefreshAsync()
    {
        Task codex = RefreshCodexAsync();
        _ = _claudeConnection?.RefreshAsync(ClaudeRefreshTrigger.Manual);
        _ = ReadClaudeCodeAsync();
        return codex;
    }

    private Task RefreshCodexAsync()
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
        UpdatePopup();
        try
        {
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
        _topBar.SetWorkStatus(_workStore.Snapshot(DateTimeOffset.UtcNow), preferences.ShowTotalWorkCount);
        if (preferences.ShowTopBar == false && _popup.IsDocked == true)
        {
            _popup.Hide();
        }
    }

    private void UpdateWorkStatus()
    {
        WorkStatus work = _workStore.Snapshot(DateTimeOffset.UtcNow);
        _popup.SetWorkStatus(work);
        _topBar.SetWorkStatus(work, _popup.Preferences.ShowTotalWorkCount);
    }

    private void ShowPopup(Point anchor, bool fromTopBar = false, string? providerId = null)
    {
        if (_exiting == true)
        {
            return;
        }

        UpdateWorkStatus();
        if (providerId != "work")
        {
            UpdatePopup();
        }
        if (fromTopBar == true)
        {
            _popup.ShowBelow(_topBar.Bounds, providerId);
        }
        else
        {
            _popup.ShowAt(anchor);
        }

        _topBar.SetDetailsOpen(fromTopBar);
        if (providerId == "work")
        {
            return;
        }

        _ = ReadClaudeCodeAsync();
        bool oldSnapshot = _snapshot == null || DateTimeOffset.UtcNow - _snapshot.RetrievedAt >= TimeSpan.FromSeconds(60);
        bool expiredWindow = _snapshot?.Buckets.Any(bucket =>
            (bucket.Primary != null && UsageDisplayHelper.IsExpired(bucket.Primary) == true) ||
            (bucket.Secondary != null && UsageDisplayHelper.IsExpired(bucket.Secondary) == true)) == true;
        if (oldSnapshot == true || expiredWindow == true)
        {
            _ = RefreshCodexAsync();
        }
    }

    private async Task LoadClaudeWebCacheAsync()
    {
        try
        {
            UsageSnapshot? snapshot = await _claudeWebStore.ReadWebAsync(_shutdown.Token);
            if (_exiting == false && snapshot != null)
            {
                _claudeWebSelected = true;
                _claudeRefresh.RestoreCache(snapshot, failed: false);
            }
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested == true)
        {
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                          System.Text.Json.JsonException or UsageQueryException)
        {
            if (_exiting == false)
            {
                _claudeWebSelected = true;
                _claudeRefresh.RestoreCache(null, failed: true);
            }
        }
        finally
        {
            _claudeCacheLoaded = true;
        }

        await ReadClaudeCodeAsync();
    }

    private async Task ReadClaudeCodeAsync()
    {
        if (_claudeReading == true || _exiting == true || _claudeCacheLoaded == false || _claudeWebSelected == true)
        {
            return;
        }

        _claudeReading = true;
        try
        {
            UsageSnapshot? snapshot = await _claudeStore.ReadAsync(_shutdown.Token);
            if (_exiting == false && _claudeWebSelected == false)
            {
                _claudeCodeSnapshot = snapshot;
                _claudeCodeError = snapshot == null ? "한 번 연결하면 자동으로 갱신됩니다." : null;
            }
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested == true)
        {
            return;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                          System.Text.Json.JsonException or UsageQueryException)
        {
            if (_exiting == false && _claudeWebSelected == false)
            {
                _claudeCodeError = "Claude 사용량 수신 파일을 읽지 못했습니다. 다음 수신을 기다려 주세요.";
            }
        }
        finally
        {
            _claudeReading = false;
            if (_exiting == false && _claudeWebSelected == false)
            {
                UpdatePopup();
                UpdateTray();
            }
        }
    }

    private void EditCodexWeeklyReset()
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        DateTimeOffset? serverReset = GetCodexWeeklyReset(now);
        string? accountScope = _snapshot?.CreditAccountScope;
        CodexWeeklyResetOverride? saved = _popup.Preferences.CodexWeeklyReset;
        DateTimeOffset? planned = saved?.ServerResetAt == serverReset && saved?.AccountScope == accountScope ?
                                  saved?.PlannedResetAt : null;
        using CodexWeeklyResetDialog dialog = new CodexWeeklyResetDialog(serverReset, planned, saved != null, Save);
        dialog.ShowDialog();

        string? Save(DateTimeOffset? date)
        {
            CodexWeeklyResetOverride? setting = null;
            if (date is DateTimeOffset plannedResetAt)
            {
                DateTimeOffset currentTime = DateTimeOffset.UtcNow;
                if (plannedResetAt <= currentTime)
                {
                    return "현재보다 뒤의 날짜와 시간을 선택해 주세요.";
                }
                if (serverReset is not DateTimeOffset expected || GetCodexWeeklyReset(currentTime) != expected ||
                    _snapshot?.CreditAccountScope != accountScope)
                {
                    return "주간 한도 정보가 바뀌었어요. 창을 닫고 다시 열어 주세요.";
                }
                setting = new CodexWeeklyResetOverride(expected, plannedResetAt, accountScope);
            }

            if (_popup.TrySetCodexWeeklyReset(setting) == false)
            {
                return "초기화 시간 설정을 저장하지 못했어요.";
            }
            UpdatePopup();
            return null;
        }
    }

    private DateTimeOffset? GetCodexWeeklyReset(DateTimeOffset now)
    {
        UsagePacingAdvice advice = UsagePacingAdvisor.Evaluate(_snapshot, _error, false, now);
        return advice.Weekly?.FirstOrDefault(item => item.BucketId == "codex" && item.Reason == null)?.Window.ResetsAt;
    }

    private void UpdatePopup()
    {
        if (_exiting == true)
        {
            return;
        }

        DateTimeOffset now = DateTimeOffset.UtcNow;
        UsageSnapshot? claudeSnapshot = GetClaudeSnapshot();
        ClaudeUsageDisplay? claudeWeb = GetClaudeDisplay(now);
        string? claudeError = _claudeWebSelected == true ? null : _claudeCodeError;
        bool claudeStale = IsClaudeStale(claudeSnapshot, claudeWeb, now);
        UsagePacingAdvice codex = UsagePacingAdvisor.Evaluate(_snapshot, _error, false, now,
                                                             _popup.Preferences.CodexWeeklyReset);
        UsagePacingAdvice claude = UsagePacingAdvisor.Evaluate(claudeSnapshot, claudeError, claudeStale, now);
        TimeZoneInfo zone = TimeZoneInfo.Local;
        codex = _dailyAllowances.Apply("codex", _snapshot, codex, now, zone);
        if (claudeStale == false && claudeError == null)
        {
            claude = _dailyAllowances.Apply("claude", claudeSnapshot, claude, now, zone);
        }

        _ = _dailyAllowances.SaveAsync();
        _popup.SetState(_snapshot, _refreshing, _error, claudeSnapshot, claudeError, claudeStale, codex, claude, claudeWeb);
        _topBar.SetUsage(_installed, _snapshot, _error, claudeSnapshot, claudeError, claudeStale, claudeWeb);
        UpdateUsageAlerts(claudeSnapshot, claudeError, claudeStale, now);
    }

    private void UpdateUsageAlerts(UsageSnapshot? claude, string? claudeError, bool claudeStale, DateTimeOffset now)
    {
        if (_exiting == false)
        {
            IReadOnlyList<UsageAlert> alerts = _alerts.Evaluate(_snapshot, _error, claude, claudeError,
                                                               claudeStale, now, _topBar.IsFullScreen);
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

    private UsageSnapshot? GetClaudeSnapshot() =>
        _claudeWebSelected == true ? _claudeRefresh.State.Snapshot : _claudeCodeSnapshot;

    private ClaudeUsageDisplay? GetClaudeDisplay(DateTimeOffset now)
    {
        if (_claudeWebSelected == false)
        {
            return null;
        }

        ClaudeUsageDisplay display = UsageDisplayHelper.DescribeClaude(_claudeRefresh.State, now);
        return _claudeConnection == null ? display with { CanConnect = true } : display;
    }

    private bool IsClaudeStale(UsageSnapshot? snapshot, ClaudeUsageDisplay? view, DateTimeOffset now) =>
        view?.IsCurrent == false || ClaudeRefreshPolicy.IsFresh(snapshot, now) == false;

    private Task ConnectClaudeAsync()
    {
        if (_exiting == true)
        {
            return Task.CompletedTask;
        }

        _claudeWebSelected = true;
        Task connection = GetClaudeConnection().ConnectAsync();
        UpdatePopup();
        UpdateTray();
        return connection;
    }

    private ClaudeConnectionWindow GetClaudeConnection() =>
        _claudeConnection ??= new ClaudeConnectionWindow(_claudeWebStore, _claudeRefresh);

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
        DateTimeOffset now = DateTimeOffset.UtcNow;
        UsageSnapshot? claude = GetClaudeSnapshot();
        ClaudeUsageDisplay? claudeWeb = GetClaudeDisplay(now);
        if (claude != null && (_claudeWebSelected == true || _claudeCodeError == null) &&
            IsClaudeStale(claude, claudeWeb, now) == false)
        {
            List<UsageWindow> claudeWindows = claude.Buckets
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
        _workTimer.Stop();
        _claudeRefresh.Stop();
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

        await _dailyAllowances.SaveAsync();
        await _claudeDiagnostics.FlushAsync();
        _tray.Visible = false;
        _popup.CloseForExit();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing == true)
        {
            _exiting = true;
            _claudeRefresh.Stop();
            _shutdown.Cancel();
            _showRegistration.Unregister(null);
            _timer.Dispose();
            _workTimer.Dispose();
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
