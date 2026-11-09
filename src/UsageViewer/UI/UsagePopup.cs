using System.Drawing.Drawing2D;
using System.Globalization;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer.UI;

internal sealed record ProviderUsageState(string Name, UsageSnapshot? Snapshot, string? Error, bool IsStale = false,
                                          UsagePacingAdvice? Advice = null);

internal sealed class UsagePopup : Form
{
    private readonly WebView2 _browser = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(23, 29, 37) };
    private readonly PopupPreferencesStore _preferencesStore;
    private readonly string _profilePath;
    private PopupPreferences _preferences;
    private IReadOnlyList<DetectedAiApp> _detected = Array.Empty<DetectedAiApp>();
    private ProviderUsageState _codex = new ProviderUsageState("Codex", null, null);
    private ProviderUsageState _claude = new ProviderUsageState("Claude", null, "한 번 연결하면 자동으로 갱신됩니다.");
    private bool _allowClose;
    private bool _ready;
    private bool _initializing;
    private bool _disposed;
    private bool _refreshing;
    private string? _preferencesError;
    private int _contentHeight = 240;
    private long _lastDeactivatedAt = -1000;
    private Point? _anchor;
    private Rectangle? _dockBounds;

    public bool JustDeactivated => Environment.TickCount64 - _lastDeactivatedAt < 300;
    public bool IsDocked => _dockBounds.HasValue;
    public PopupPreferences Preferences => _preferences;
    public event EventHandler? RefreshRequested;
    public event EventHandler? ClaudeConnectRequested;
    public event EventHandler? CodexConnectRequested;
    public event EventHandler? WindowPreferencesChanged;

    public UsagePopup(PopupPreferencesStore? preferencesStore = null, string? profilePath = null)
    {
        _preferencesStore = preferencesStore ?? new PopupPreferencesStore();
        _profilePath = profilePath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                                  "UsageViewer", "PopupProfile");
        _preferences = _preferencesStore.Load();
        Text = "AI 사용량 · UsageViewer";
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(_preferences.ShowBoth == true ? 320 : 280, _contentHeight);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = _preferences.AlwaysOnTop;
        BackColor = Color.FromArgb(23, 29, 37);
        Controls.Add(_browser);
        Deactivate += (_, _) =>
        {
            _lastDeactivatedAt = Environment.TickCount64;
            Hide();
        };
    }

    public void SetDetectedApps(IReadOnlyList<DetectedAiApp> apps)
    {
        _detected = apps;
        UpdateDocument();
    }

    public void SetState(UsageSnapshot? snapshot, bool refreshing, string? error, UsageSnapshot? claude = null,
                         string? claudeError = null, bool claudeStale = false,
                         UsagePacingAdvice? codexAdvice = null, UsagePacingAdvice? claudeAdvice = null)
    {
        _codex = new ProviderUsageState("Codex", snapshot, error, Advice: codexAdvice);
        _claude = new ProviderUsageState("Claude", claude, claudeError, claudeStale, claudeAdvice);
        _refreshing = refreshing;
        UpdateDocument();
    }

    public void ShowAt(Point anchor)
    {
        _dockBounds = null;
        _anchor = anchor;
        FitToScreen();
        UpdateWindowRegion();
        UpdateDocument();
        Show();
        FitToScreen();
        Activate();
    }

    public void ShowBelow(Rectangle bar, string? providerId = null)
    {
        if ((providerId == "codex" || providerId == "claude") &&
            (_preferences.ShowBoth == true || _preferences.ActiveProvider != providerId))
        {
            _preferences = _preferences with { ShowBoth = false, ActiveProvider = providerId };
            SavePreferences();
        }

        _dockBounds = bar;
        _anchor = new Point(bar.Left + bar.Width / 2, bar.Top);
        FitToScreen();
        UpdateWindowRegion();
        UpdateDocument();
        Show();
        FitToScreen();
        Activate();
    }

    public void MoveBelow(Rectangle bar)
    {
        if (_dockBounds.HasValue == true)
        {
            _dockBounds = bar;
            _anchor = new Point(bar.Left + bar.Width / 2, bar.Top);
            FitToScreen();
        }
    }

    public void SetWindowOptions(bool showTopBar, bool alwaysOnTop)
    {
        bool changed = _preferences.ShowTopBar != showTopBar || _preferences.AlwaysOnTop != alwaysOnTop;
        _preferences = _preferences with { ShowTopBar = showTopBar, AlwaysOnTop = alwaysOnTop };
        if (TopMost != alwaysOnTop)
        {
            TopMost = alwaysOnTop;
        }

        SavePreferences();
        if (changed == true)
        {
            WindowPreferencesChanged?.Invoke(this, EventArgs.Empty);
        }

        UpdateDocument();
    }

    public void SetTopBarPlacement(string screen, double position)
    {
        double normalized = Math.Clamp(position, 0, 1);
        bool changed = _preferences.TopBarScreen != screen || _preferences.TopBarPosition != normalized;
        _preferences = _preferences with { TopBarScreen = screen, TopBarPosition = normalized };
        SavePreferences();
        if (changed == true)
        {
            WindowPreferencesChanged?.Invoke(this, EventArgs.Empty);
        }

        UpdateDocument();
    }

    public void SetAlertSoundEnabled(bool enabled)
    {
        bool changed = _preferences.AlertSoundEnabled != enabled;
        _preferences = _preferences with { AlertSoundEnabled = enabled };
        SavePreferences();
        if (changed == true)
        {
            WindowPreferencesChanged?.Invoke(this, EventArgs.Empty);
        }

        UpdateDocument();
    }

    public void CloseForExit()
    {
        _allowClose = true;
        Close();
    }

    protected override async void OnShown(EventArgs e)
    {
        base.OnShown(e);
        if (_ready == true || _initializing == true)
        {
            return;
        }

        _initializing = true;
        try
        {
            CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(userDataFolder: _profilePath);
            await _browser.EnsureCoreWebView2Async(environment);
            if (_disposed == true)
            {
                return;
            }

            _browser.CoreWebView2.WebMessageReceived += OnWebMessage;
            _browser.CoreWebView2.NavigationStarting += (_, args) =>
            {
                // Allow NavigateToString's initial internal navigation, then keep the popup on its local document.
                args.Cancel = _ready;
            };
            _browser.CoreWebView2.NavigationCompleted += (_, args) =>
            {
                if (args.IsSuccess == true && _browser.CoreWebView2.Source == "about:blank")
                {
                    _ready = true;
                    UpdateDocument();
                }
            };
            _browser.CoreWebView2.NewWindowRequested += (_, args) => args.Handled = true;
            using Stream stream = typeof(UsagePopup).Assembly.GetManifestResourceStream("UsageViewer.UI.Popup.html")!;
            using StreamReader reader = new StreamReader(stream);
            string html = await reader.ReadToEndAsync();
            _browser.NavigateToString(html);
        }
        catch (Exception)
        {
            if (_disposed == false)
            {
                _browser.Visible = false;
                Controls.Add(new Label
                {
                    Text = "팝업을 표시하려면 Microsoft Edge WebView2 Runtime이 필요합니다.",
                    Dock = DockStyle.Fill,
                    ForeColor = Color.White,
                    Padding = new Padding(16)
                });
            }
        }
        finally
        {
            _initializing = false;
        }
    }

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (_disposed == true || args.Source != "about:blank")
        {
            return;
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(args.WebMessageAsJson);
            JsonElement root = document.RootElement;
            string? type = root.GetProperty("type").GetString();
            switch (type)
            {
                case "ready":
                    _ready = true;
                    UpdateDocument();
                    break;
                case "resize":
                    if (root.TryGetProperty("height", out JsonElement height) == true &&
                        height.TryGetInt32(out int value) == true && value >= 90 && value <= 2000)
                    {
                        _contentHeight = value;
                        FitToScreen();
                    }
                    break;
                case "mode":
                    _preferences = _preferences with { ShowBoth = root.GetProperty("showBoth").GetBoolean() };
                    SavePreferences();
                    FitToScreen();
                    UpdateDocument();
                    break;
                case "provider":
                    string? id = root.GetProperty("id").GetString();
                    if (id != null && (_detected.Any(app => app.Id == id) == true || id == "codex" || id == "claude"))
                    {
                        _preferences = _preferences with { ActiveProvider = id };
                        SavePreferences();
                        UpdateDocument();
                    }
                    break;
                case "refresh":
                    RefreshRequested?.Invoke(this, EventArgs.Empty);
                    break;
                case "connect":
                    if (root.TryGetProperty("id", out JsonElement provider) == true && provider.GetString() == "codex")
                    {
                        CodexConnectRequested?.Invoke(this, EventArgs.Empty);
                    }
                    else if (provider.ValueKind == JsonValueKind.String && provider.GetString() == "claude")
                    {
                        ClaudeConnectRequested?.Invoke(this, EventArgs.Empty);
                    }
                    break;
                case "hide":
                    Hide();
                    break;
            }
        }
        catch (Exception exception) when (exception is JsonException || exception is InvalidOperationException ||
                                          exception is KeyNotFoundException)
        {
        }
    }

    private void SavePreferences()
    {
        _preferencesError = _preferencesStore.Save(_preferences) == true ? null : "보기 설정을 저장하지 못했습니다.";
    }

    private async void UpdateDocument()
    {
        if (_ready == false || _disposed == true || _browser.CoreWebView2?.Source != "about:blank")
        {
            return;
        }

        try
        {
            string json = JsonSerializer.Serialize(BuildDocumentState());
            await _browser.ExecuteScriptAsync("window.usageViewer.update(" + json + ");");
        }
        catch (Exception exception) when (exception is InvalidOperationException || exception is ObjectDisposedException ||
                                          exception is System.Runtime.InteropServices.COMException)
        {
        }
    }

    private object BuildDocumentState()
    {
        List<DetectedAiApp> visible = _detected.ToList();
        if (_codex.Snapshot != null && visible.Any(app => app.Id == "codex") == false)
        {
            visible.Insert(0, new DetectedAiApp("codex", "Codex", true));
        }

        if (_claude.Snapshot != null && visible.Any(app => app.Id == "claude") == false)
        {
            visible.Add(new DetectedAiApp("claude", "Claude", true));
        }

        List<object> providers = new List<object>();
        foreach (DetectedAiApp app in visible)
        {
            ProviderUsageState state = app.Id == "codex" ? _codex : _claude;
            UsageSnapshot? snapshot = app.UsageSupported == true ? state.Snapshot : null;
            UsagePacingAdvice advice = state.Advice ?? new UsagePacingAdvice(UsagePacingLevel.Unavailable);
            List<object> windows = new List<object>();
            if (snapshot != null)
            {
                foreach ((UsageBucket bucket, UsageWindow window) in snapshot.Buckets
                    .SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary }.OfType<UsageWindow>()
                        .Select(window => (Bucket: bucket, Window: window)))
                    .OrderBy(item => item.Window.DurationMinutes ?? int.MaxValue))
                {
                    string name = UsageDisplayHelper.FormatWindow(window.DurationMinutes, "사용 한도");
                    if (snapshot.Buckets.Count > 1)
                    {
                        name = bucket.Name + " · " + name;
                    }

                    bool valid = double.IsFinite(window.UsedPercent) == true &&
                                 window.UsedPercent >= 0 && window.UsedPercent <= 100;
                    UsagePacingItem? pacingItem = (advice.Weekly ?? []).Concat(advice.ShortTerm ?? [])
                        .FirstOrDefault(item => item.BucketId == bucket.Id && ReferenceEquals(item.Window, window));
                    windows.Add(new
                    {
                        name,
                        shortName = name.Replace(" 한도", ""),
                        remaining = valid == true ? (double?)window.RemainingPercent : null,
                        invalid = valid == false,
                        alert = UsageAlertPolicy.IsFresh(snapshot, state.Error, state.IsStale, DateTimeOffset.UtcNow) == true ?
                                UsageAlertPolicy.GetLevel(window, DateTimeOffset.UtcNow).ToString().ToLowerInvariant() : "none",
                        expired = UsageDisplayHelper.IsExpired(window),
                        resetText = UsageDisplayHelper.FormatReset(window),
                        weekly = window.DurationMinutes == 10080,
                        average24Hours = pacingItem?.Average24Hours,
                        pacingReason = pacingItem?.Reason,
                        pacingMessage = window.DurationMinutes == 10080 && pacingItem != null ?
                                        UsageDisplayHelper.GetWeeklyMessage(pacingItem) : null,
                        shortTermWarning = pacingItem != null ? UsageDisplayHelper.FormatShortTermWarning(pacingItem) : ""
                    });
                }
            }

            CreditBalance? credits = snapshot?.Buckets.FirstOrDefault()?.Credits;
            string? balance = app.Id != "codex" || snapshot == null ? null :
                              credits?.Unlimited == true ? "무제한" :
                              credits?.Balance?.ToString("#,0.##", CultureInfo.InvariantCulture) ??
                              (credits?.HasCredits == false ? "잔액 없음" : "미제공");
            providers.Add(new
            {
                id = app.Id,
                name = app.Name,
                supported = app.UsageSupported,
                canConnect = (app.Id == "codex" || app.Id == "claude") && (snapshot == null || state.Error != null),
                plan = app.Id == "codex" ? CultureInfo.InvariantCulture.TextInfo.ToTitleCase(snapshot?.PlanName ??
                       (state.Error == null ? "조회 중" : "연결 확인")) :
                       app.Id == "claude" ? (snapshot == null ? "연결 필요" : "마지막 수신") : "감지됨",
                windows,
                coverage = UsageDisplayHelper.FormatLimitCoverage(snapshot),
                pacing = new
                {
                    level = advice.Level.ToString().ToLowerInvariant(),
                    reason = advice.Reason,
                    message = UsageDisplayHelper.GetPacingMessage(advice),
                    detail = UsageDisplayHelper.FormatPacingDetails(advice),
                    basis = UsageDisplayHelper.FormatPacingBasis(advice)
                },
                credits = balance,
                error = app.UsageSupported == true ? state.Error : "감지됨 · 사용량 연동 미지원",
                stale = app.UsageSupported == true && (state.IsStale == true || state.Error != null ||
                        (snapshot != null && (snapshot.RetrievedAt > DateTimeOffset.UtcNow ||
                         DateTimeOffset.UtcNow - snapshot.RetrievedAt > TimeSpan.FromMinutes(15)))),
                updated = snapshot?.RetrievedAt.ToLocalTime().ToString("HH:mm")
            });
        }

        return new
        {
            showBoth = _preferences.ShowBoth,
            docked = _dockBounds.HasValue,
            activeProvider = _preferences.ActiveProvider,
            providers,
            refreshing = _refreshing,
            preferencesError = _preferencesError
        };
    }

    private void FitToScreen()
    {
        float scale = DeviceDpi / 96f;
        Screen screen = _anchor.HasValue == true ? Screen.FromPoint(_anchor.Value) : Screen.FromControl(this);
        Rectangle work = screen.WorkingArea;
        int width = _dockBounds.HasValue == true ? 264 : _preferences.ShowBoth == true ? 320 : 280;
        ClientSize = new Size(Math.Min((int)(width * scale), work.Width - 24),
                              Math.Min((int)(_contentHeight * scale), work.Height - (int)(24 * scale)));
        if (_anchor.HasValue == true)
        {
            Location = _dockBounds.HasValue == true ? PopupPlacementHelper.CalculateBelow(work, Size, _dockBounds.Value) :
                       PopupPlacementHelper.Calculate(work, Size, (int)(12 * scale));
        }
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        UpdateWindowRegion();
    }

    private void UpdateWindowRegion()
    {
        if (Width <= 0 || Height <= 0)
        {
            return;
        }

        float radius = 12 * DeviceDpi / 96f;
        using GraphicsPath path = new GraphicsPath();
        float diameter = Math.Min(radius * 2, Math.Min(Width, Height));
        if (_dockBounds.HasValue == true)
        {
            path.AddLine(0, 0, Width, 0);
        }
        else
        {
            path.AddArc(0, 0, diameter, diameter, 180, 90);
            path.AddArc(Width - diameter, 0, diameter, diameter, 270, 90);
        }
        path.AddArc(Width - diameter, Height - diameter, diameter, diameter, 0, 90);
        path.AddArc(0, Height - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        Region? previous = Region;
        Region = new Region(path);
        previous?.Dispose();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        FitToScreen();
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
            _browser.Dispose();
        }

        base.Dispose(disposing);
    }
}
