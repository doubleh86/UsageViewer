using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer.UI;

internal sealed class ClaudeConnectionWindow : Form
{
    private const string UsageUrl = "https://claude.ai/settings/usage";
    private readonly WebView2 _browser = new WebView2 { Dock = DockStyle.Fill };
    private readonly Label _status;
    private readonly ClaudeWebUsageParser _parser = new ClaudeWebUsageParser();
    private readonly ClaudeUsageStore _store;
    private Task? _initialization;
    private bool _initializing;
    private bool _disposed;

    public event EventHandler? UsageReceived;
    public event EventHandler<string>? ConnectionError;

    public ClaudeConnectionWindow(ClaudeUsageStore store)
    {
        _store = store;
        Text = "Claude 연결 · claude.ai";
        ClientSize = new Size(920, 720);
        MinimumSize = new Size(640, 480);
        StartPosition = FormStartPosition.CenterScreen;
        _status = new Label
        {
            Text = "공식 Claude 페이지에 직접 로그인한 뒤 사용량 화면을 열어 주세요. 기존 앱의 인증 파일은 읽지 않습니다.",
            Dock = DockStyle.Top,
            Height = 46,
            Padding = new Padding(12, 8, 12, 0),
            BackColor = Color.FromArgb(235, 240, 245),
            ForeColor = Color.FromArgb(25, 35, 48)
        };
        Button reload = new Button { Text = "Claude 사용량 페이지 열기 / 새로고침", Dock = DockStyle.Bottom, Height = 34 };
        reload.Click += async (_, _) => await NavigateAsync();
        Controls.Add(_browser);
        Controls.Add(_status);
        Controls.Add(reload);
    }

    public async Task ConnectAsync()
    {
        Show();
        Activate();
        await NavigateAsync();
    }

    public async Task RefreshInBackgroundAsync()
    {
        // Never refresh a visible login form or initialize a new login without the user's connect action.
        if (_browser.CoreWebView2 != null && Visible == false && _initializing == false && _disposed == false)
        {
            await NavigateAsync();
        }
    }

    public async Task ResumeInBackgroundAsync()
    {
        _ = Handle;
        await NavigateAsync();
    }

    private async Task NavigateAsync()
    {
        try
        {
            _initialization ??= InitializeAsync();
            await _initialization;
            if (_disposed == false)
            {
                _browser.CoreWebView2.Navigate(UsageUrl);
            }
        }
        catch (Exception)
        {
            _initialization = null;
            ReportError("Claude 연결 창을 열지 못했습니다. Edge WebView2 Runtime 설치와 네트워크를 확인해 주세요.");
        }
    }

    private async Task InitializeAsync()
    {
        _initializing = true;
        try
        {
            string profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                           "UsageViewer", "ClaudeWebProfile");
            CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(userDataFolder: profile);
            await _browser.EnsureCoreWebView2Async(environment);
            _browser.CoreWebView2.WebResourceResponseReceived += OnResponseReceived;
        }
        finally
        {
            _initializing = false;
        }
    }

    private async void OnResponseReceived(object? sender, CoreWebView2WebResourceResponseReceivedEventArgs args)
    {
        if (_disposed == true || args.Request.Method != "GET" ||
            Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out Uri? uri) == false ||
            uri.Scheme != "https" || uri.Host != "claude.ai" ||
            uri.AbsolutePath.StartsWith("/api/organizations/", StringComparison.Ordinal) == false ||
            uri.AbsolutePath.EndsWith("/usage", StringComparison.Ordinal) == false)
        {
            return;
        }

        try
        {
            if (args.Response.StatusCode != 200)
            {
                ReportError("Claude 사용량 페이지의 조회가 거절됐습니다. 연결 창에서 로그인 상태를 확인해 주세요.");
                return;
            }

            using Stream stream = await args.Response.GetContentAsync();
            using StreamReader reader = new StreamReader(stream);
            StringBuilder content = new StringBuilder();
            char[] buffer = new char[4096];
            int length;
            while ((length = await reader.ReadAsync(buffer)) > 0)
            {
                if (content.Length + length > 65536)
                {
                    throw new UsageQueryException("Claude 사용량 응답 크기가 예상 범위를 벗어났습니다.");
                }

                content.Append(buffer, 0, length);
            }

            using JsonDocument document = JsonDocument.Parse(content.ToString());
            ClaudeUsageCache cache = _parser.Parse(document.RootElement);
            // Persist quotas only; raw web responses, organization identifiers, and cookies are never saved by this code.
            string normalized = JsonSerializer.Serialize(new
            {
                rate_limits = new
                {
                    five_hour = ToStatusWindow(cache.FiveHour),
                    seven_day = ToStatusWindow(cache.SevenDay)
                }
            });
            await _store.CaptureAsync(new StringReader(normalized), CancellationToken.None);
            if (_disposed == false)
            {
                _status.Text = "Claude 사용량 수신 완료. 이 창을 닫아도 트레이에서 주기적으로 갱신합니다.";
                UsageReceived?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (UsageQueryException exception)
        {
            ReportError(exception.Message);
        }
        catch (Exception)
        {
            ReportError("Claude 웹 사용량 응답을 처리하지 못했습니다. 연결 창의 사용량 페이지를 확인해 주세요.");
        }
    }

    private object? ToStatusWindow(UsageWindow? window)
    {
        return window == null ? null : new { used_percentage = window.UsedPercent, resets_at = window.ResetsAt?.ToUnixTimeSeconds() };
    }

    private void ReportError(string message)
    {
        if (_disposed == false)
        {
            _status.Text = message;
            ConnectionError?.Invoke(this, message);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
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
