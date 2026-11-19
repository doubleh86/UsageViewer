using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer.UI;

internal sealed class ClaudePageRequest(string id, string loader, string frame, string url)
{
    public string Id { get; } = id;
    public string Loader { get; } = loader;
    public string Frame { get; } = frame;
    public string Url { get; } = url;
    public int? Status { get; set; }
    public DateTimeOffset? RetryAfter { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public bool Finished { get; set; }
    public bool Failed { get; set; }
    public bool Cached { get; set; }
}

internal sealed class ClaudePageAttempt(ClaudeRefreshAttempt attempt)
{
    public ClaudeRefreshAttempt Attempt { get; } = attempt;
    public string? Loader { get; set; }
    public string? Frame { get; set; }
    public List<ClaudePageRequest> Requests { get; } = [];
    public List<ClaudeDocumentFailure> DocumentFailures { get; } = [];
    public bool Reading { get; set; }

    public ClaudePageRequest? SelectRequest() => Loader == null ? null :
        Requests.Find(item => item.Loader == Loader && item.Frame == Frame);
}

internal sealed record ClaudeDocumentFailure(string Loader, string Frame, int Status, DateTimeOffset? RetryAfter);

internal enum ClaudeRefreshRoute { Other, SettingsBootstrap, Usage }

internal sealed class ClaudeConnectionWindow : Form
{
    private const string UsageUrl = "https://claude.ai/settings/usage";
    private readonly WebView2 _browser = new WebView2 { Dock = DockStyle.Fill };
    private readonly Label _status;
    private readonly ClaudeWebUsageParser _parser = new ClaudeWebUsageParser();
    private readonly ClaudeUsageStore _store;
    private readonly ClaudeRefreshCoordinator _refresh;
    private readonly List<CoreWebView2DevToolsProtocolEventReceiver> _receivers = [];
    private readonly Queue<string> _expiredLoaders = new Queue<string>();
    private Task? _initialization;
    private bool _initialized;
    private bool _subscribed;
    private ClaudePageAttempt? _pageAttempt;
    private int _pendingNavigations;
    private string? _documentFrame;
    private string? _documentLoader;
    private string? _documentUrl;
    private ClaudeRefreshRoute _refreshRoute;
    private double _passiveAfter;
    private bool _disposed;

    public ClaudeConnectionWindow(ClaudeUsageStore store, ClaudeRefreshCoordinator refresh)
    {
        _store = store;
        _refresh = refresh;
        Text = "Claude 연결 · claude.ai";
        ClientSize = new Size(920, 720);
        MinimumSize = new Size(640, 480);
        StartPosition = FormStartPosition.CenterScreen;
        _status = new Label
        {
            Dock = DockStyle.Top,
            Height = 46,
            Padding = new Padding(12, 8, 12, 0),
            BackColor = Color.FromArgb(235, 240, 245),
            ForeColor = Color.FromArgb(25, 35, 48)
        };
        Button reload = new Button { Text = "Claude 사용량 페이지 열기 / 새로고침", Dock = DockStyle.Bottom, Height = 34 };
        reload.Click += async (_, _) => await RefreshAsync(ClaudeRefreshTrigger.Connection);
        Controls.Add(_browser);
        Controls.Add(_status);
        Controls.Add(reload);
        _refresh.Changed += OnRefreshChanged;
        OnRefreshChanged(this, EventArgs.Empty);
    }

    public Task ConnectAsync()
    {
        bool wasVisible = Visible;
        Show();
        Activate();

        return wasVisible == true || _refresh.State.Result == ClaudeRefreshResult.AccessRequired ?
               Task.CompletedTask : RefreshAsync(ClaudeRefreshTrigger.Connection);
    }

    public async Task RefreshAsync(ClaudeRefreshTrigger trigger)
    {
        if (_disposed == true || IsLoginPage(_documentUrl) == true)
        {
            return;
        }

        ClaudeRefreshAttempt? attempt = _refresh.TryBegin(trigger, _initialized, Visible);
        if (attempt == null)
        {
            return;
        }

        _ = WatchDeadlineAsync(attempt, _initialized == true ? ClaudeRefreshPolicy.AttemptTimeout :
                                  ClaudeRefreshPolicy.InitializationTimeout);
        if (_initialized == false)
        {
            try
            {
                _ = Handle;
                _initialization ??= InitializeAsync();
                await _initialization.WaitAsync(attempt.Token);
            }
            catch (OperationCanceledException) when (attempt.Token.IsCancellationRequested == true)
            {
                return;
            }
            catch (Exception)
            {
                _initialization = null;
                _refresh.Fail(attempt, ClaudeRefreshResult.InitializationFailed);
                return;
            }

            if (_refresh.Initialized(attempt) == false)
            {
                return;
            }

            _ = WatchDeadlineAsync(attempt, ClaudeRefreshPolicy.AttemptTimeout);
        }

        ClaudePageAttempt pageAttempt = new ClaudePageAttempt(attempt);
        _pageAttempt = pageAttempt;
        _pendingNavigations++;
        try
        {
            string result = await _browser.CoreWebView2.CallDevToolsProtocolMethodAsync("Page.navigate",
                JsonSerializer.Serialize(new { url = UsageUrl }));
            using JsonDocument json = JsonDocument.Parse(result);
            JsonElement navigation = json.RootElement;
            string? loader = ReadString(navigation, "loaderId");
            if (_refresh.Accepts(attempt) == false)
            {
                RetireLoader(loader);
                return;
            }

            string? frame = ReadString(navigation, "frameId");
            string? error = ReadString(navigation, "errorText");
            ClaudeDocumentFailure? failure = pageAttempt.DocumentFailures.Find(item => item.Loader == loader && item.Frame == frame);
            if (failure != null)
            {
                FailHttp(attempt, failure.Status, failure.RetryAfter);
            }
            else if (error == "net::ERR_ABORTED" && Visible == true)
            {
                RetireLoader(loader);
                _refresh.Cancel(attempt);
            }
            else if (loader == null || frame == null || string.IsNullOrEmpty(error) == false)
            {
                _refresh.Fail(attempt, ClaudeRefreshResult.NavigationFailed);
            }
            else
            {
                pageAttempt.Loader = loader;
                pageAttempt.Frame = frame;
                InspectDocument(previousLoader: null);
            }
        }
        catch (Exception)
        {
            _refresh.Fail(attempt, ClaudeRefreshResult.NavigationFailed);
        }
        finally
        {
            _pendingNavigations--;
        }
    }

    private async Task WatchDeadlineAsync(ClaudeRefreshAttempt attempt, TimeSpan timeout)
    {
        try
        {
            await Task.Delay(timeout, attempt.Token);
            if (_refresh.Active?.Id == attempt.Id)
            {
                _refresh.Expire();
            }
        }
        catch (OperationCanceledException) when (attempt.Token.IsCancellationRequested == true)
        {
        }
    }

    private async Task InitializeAsync()
    {
        string profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                      "UsageViewer", "ClaudeWebProfile");
        CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(userDataFolder: profile);
        if (_disposed == true || _refresh.State.Phase == ClaudeRefreshPhase.Stopped)
        {
            return;
        }

        await _browser.EnsureCoreWebView2Async(environment);
        await ObserveNavigationAsync();
    }

    private async Task ObserveNavigationAsync()
    {
        if (_disposed == true || _refresh.State.Phase == ClaudeRefreshPhase.Stopped)
        {
            return;
        }

        CoreWebView2 core = _browser.CoreWebView2;
        if (_subscribed == false)
        {
            Observe(core, "Page.frameNavigated", OnFrameNavigated);
            Observe(core, "Page.navigatedWithinDocument", OnWithinDocument);
            Observe(core, "Network.requestWillBeSent", OnRequest);
            Observe(core, "Network.responseReceived", OnResponse);
            Observe(core, "Network.loadingFailed", item => OnLoading(item, failed: true));
            Observe(core, "Network.loadingFinished", item => OnLoading(item, failed: false));
            Observe(core, "Network.requestServedFromCache", item =>
            {
                ClaudePageRequest? request = FindRequest(item);
                if (request != null)
                {
                    request.Cached = true;
                }
            });
            _subscribed = true;
        }

        await core.CallDevToolsProtocolMethodAsync("Page.enable", "{}");
        if (_disposed == false && _refresh.State.Phase != ClaudeRefreshPhase.Stopped)
        {
            await core.CallDevToolsProtocolMethodAsync("Network.enable",
                "{\"maxTotalBufferSize\":1048576,\"maxResourceBufferSize\":262144,\"maxPostDataSize\":0}");
            _initialized = _disposed == false && _refresh.State.Phase != ClaudeRefreshPhase.Stopped;
        }
    }

    private void Observe(CoreWebView2 core, string name, Action<JsonElement> observe)
    {
        CoreWebView2DevToolsProtocolEventReceiver receiver = core.GetDevToolsProtocolEventReceiver(name);
        _receivers.Add(receiver);
        receiver.DevToolsProtocolEventReceived += (_, args) =>
        {
            if (_disposed == true || _refresh.State.Phase == ClaudeRefreshPhase.Stopped)
            {
                return;
            }

            try
            {
                using JsonDocument json = JsonDocument.Parse(args.ParameterObjectAsJson);
                observe(json.RootElement);
            }
            catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException or FormatException)
            {
            }
        };
    }

    private void OnFrameNavigated(JsonElement item)
    {
        JsonElement frame = item.GetProperty("frame");
        if (frame.TryGetProperty("parentId", out _) == true)
        {
            return;
        }

        string? previousLoader = _documentLoader;
        _documentFrame = ReadString(frame, "id");
        _documentLoader = ReadString(frame, "loaderId");
        _documentUrl = ReadString(frame, "url");
        _refreshRoute = GetRefreshRoute(_documentUrl);
        InspectDocument(previousLoader);
    }

    private void OnWithinDocument(JsonElement item)
    {
        if (_documentFrame != null && ReadString(item, "frameId") == _documentFrame)
        {
            _documentUrl = ReadString(item, "url");
            ClaudeRefreshRoute route = GetRefreshRoute(_documentUrl);
            _refreshRoute = _refreshRoute switch
            {
                ClaudeRefreshRoute.SettingsBootstrap => route,
                ClaudeRefreshRoute.Usage when route == ClaudeRefreshRoute.Usage => route,
                _ => ClaudeRefreshRoute.Other
            };
            InspectDocument(_documentLoader);
        }
    }

    private void InspectDocument(string? previousLoader)
    {
        ClaudePageAttempt? pageAttempt = _pageAttempt;
        if (pageAttempt?.Loader != null)
        {
            bool matches = pageAttempt.Loader == _documentLoader && pageAttempt.Frame == _documentFrame;
            if (matches == false && pageAttempt.Loader != previousLoader)
            {
                return;
            }

            if (IsLoginPage(_documentUrl) == true)
            {
                _refresh.Fail(pageAttempt.Attempt, ClaudeRefreshResult.LoginRequired);
            }
            else if (matches == true && CanUseDocument(pageAttempt) == true)
            {
                Dispatch(pageAttempt);
            }
            else if (matches == false || _refreshRoute != ClaudeRefreshRoute.SettingsBootstrap ||
                     pageAttempt.Attempt.Trigger == ClaudeRefreshTrigger.Page)
            {
                RetireLoader(pageAttempt.Loader);
                if (Visible == true)
                {
                    _refresh.Cancel(pageAttempt.Attempt);
                }
                else
                {
                    _refresh.Fail(pageAttempt.Attempt, ClaudeRefreshResult.NavigationFailed);
                }
            }
        }
        else if (pageAttempt == null && Visible == true && _pendingNavigations == 0 &&
                 _refresh.State.Result != ClaudeRefreshResult.LoginRequired && IsLoginPage(_documentUrl) == true)
        {
            ClaudeRefreshAttempt? login = _refresh.TryBegin(ClaudeRefreshTrigger.Page, initialized: true, interactive: true);
            if (login != null)
            {
                _refresh.Fail(login, ClaudeRefreshResult.LoginRequired);
            }
        }
    }

    private void OnRequest(JsonElement item)
    {
        string? id = ReadString(item, "requestId");
        ClaudePageRequest? existing = FindRequest(item);
        if (existing != null)
        {
            existing.Failed = true;
            Dispatch(_pageAttempt!);
            return;
        }

        JsonElement request = item.GetProperty("request");
        string? url = ReadString(request, "url");
        string? loader = ReadString(item, "loaderId");
        string? frame = ReadString(item, "frameId");
        if (id == null || string.IsNullOrEmpty(loader) == true || frame == null || IsUsageEndpoint(url) == false ||
            ReadString(request, "method") != "GET" || IsUsagePage(ReadString(item, "documentURL")) == false ||
            item.TryGetProperty("redirectResponse", out _) == true)
        {
            return;
        }

        if (_pageAttempt == null && Visible == true && _pendingNavigations == 0 &&
            loader == _documentLoader && frame == _documentFrame && IsUsagePage(_documentUrl) == true &&
            _expiredLoaders.Contains(loader) == false && item.TryGetProperty("wallTime", out JsonElement sentAt) == true &&
            sentAt.TryGetDouble(out double seconds) == true && seconds >= _passiveAfter)
        {
            ClaudeRefreshAttempt? passive = _refresh.TryBegin(ClaudeRefreshTrigger.Page, initialized: true, interactive: true);
            if (passive != null)
            {
                _pageAttempt = new ClaudePageAttempt(passive) { Loader = loader, Frame = frame };
                _ = WatchDeadlineAsync(passive, ClaudeRefreshPolicy.AttemptTimeout);
            }
        }

        if (_pageAttempt is ClaudePageAttempt pageAttempt && pageAttempt.Reading == false &&
            _refresh.Accepts(pageAttempt.Attempt) == true && pageAttempt.Requests.Count < 16 &&
            (pageAttempt.Loader == null || (pageAttempt.Loader == loader && pageAttempt.Frame == frame)))
        {
            pageAttempt.Requests.Add(new ClaudePageRequest(id, loader, frame, url!));
        }
    }

    private void OnResponse(JsonElement item)
    {
        if (ReadString(item, "type") == "Document")
        {
            InspectDocumentResponse(item);
            return;
        }

        ClaudePageRequest? request = FindRequest(item);
        if (request == null || request.Status != null)
        {
            return;
        }

        JsonElement response = item.GetProperty("response");
        if (ReadString(response, "url") != request.Url || ReadString(item, "loaderId") != request.Loader ||
            (ReadString(item, "frameId") is string frame && frame != request.Frame))
        {
            request.Failed = true;
        }
        else
        {
            int status = response.GetProperty("status").GetInt32();
            request.Status = status;
            request.ReceivedAt = _refresh.Now;
            request.Cached |= IsTrue(response, "fromDiskCache") || IsTrue(response, "fromServiceWorker") ||
                              IsTrue(response, "fromPrefetchCache");
            request.RetryAfter = ReadRetryAfter(response, status, request.ReceivedAt);
        }

        Dispatch(_pageAttempt!);
    }

    private void InspectDocumentResponse(JsonElement item)
    {
        if (_pageAttempt is not ClaudePageAttempt pageAttempt || pageAttempt.Attempt.Trigger == ClaudeRefreshTrigger.Page ||
            ReadString(item, "loaderId") is not string loader || ReadString(item, "frameId") is not string frame)
        {
            return;
        }

        JsonElement response = item.GetProperty("response");
        int status = response.GetProperty("status").GetInt32();
        if (status < 400 || GetRefreshRoute(ReadString(response, "url")) == ClaudeRefreshRoute.Other)
        {
            return;
        }

        DateTimeOffset? retryAfter = ReadRetryAfter(response, status, _refresh.Now);
        if (pageAttempt.Loader == loader && pageAttempt.Frame == frame)
        {
            FailHttp(pageAttempt.Attempt, status, retryAfter);
        }
        else if (pageAttempt.Loader == null && pageAttempt.DocumentFailures.Count < 16)
        {
            pageAttempt.DocumentFailures.Add(new ClaudeDocumentFailure(loader, frame, status, retryAfter));
        }
    }

    private static DateTimeOffset? ReadRetryAfter(JsonElement response, int status, DateTimeOffset receivedAt)
    {
        if ((status == 429 || status is >= 500 and <= 599) &&
            response.TryGetProperty("headers", out JsonElement headers) == true && headers.ValueKind == JsonValueKind.Object)
        {
            foreach (JsonProperty header in headers.EnumerateObject())
            {
                if (header.Name.Equals("Retry-After", StringComparison.OrdinalIgnoreCase) == true &&
                    header.Value.ValueKind == JsonValueKind.String)
                {
                    return ClaudeRefreshPolicy.ParseRetryAfter(header.Value.GetString(), receivedAt);
                }
            }
        }

        return null;
    }

    private void FailHttp(ClaudeRefreshAttempt attempt, int status, DateTimeOffset? retryAfter) =>
        _refresh.Fail(attempt, ClaudeRefreshPolicy.ClassifyHttp(status), status, retryAfter);

    private void OnLoading(JsonElement item, bool failed)
    {
        ClaudePageRequest? request = FindRequest(item);
        if (request != null)
        {
            request.Failed |= failed;
            request.Finished = true;
            Dispatch(_pageAttempt!);
        }
    }

    private ClaudePageRequest? FindRequest(JsonElement item)
    {
        string? id = ReadString(item, "requestId");
        return _pageAttempt?.Requests.Find(request => request.Id == id);
    }

    private void Dispatch(ClaudePageAttempt pageAttempt)
    {
        if (pageAttempt.Loader == null || pageAttempt.Loader != _documentLoader || pageAttempt.Frame != _documentFrame ||
            CanUseDocument(pageAttempt) == false ||
            pageAttempt.Reading == true || _refresh.Accepts(pageAttempt.Attempt) == false)
        {
            return;
        }

        ClaudePageRequest? request = pageAttempt.SelectRequest();
        if (request == null)
        {
            return;
        }

        if (request.Failed == true || request.Cached == true)
        {
            _refresh.Fail(pageAttempt.Attempt, ClaudeRefreshResult.NetworkFailed, request.Status);
        }
        else if (request.Status is int status && status != 200)
        {
            FailHttp(pageAttempt.Attempt, status, request.RetryAfter);
        }
        else if (request.Status == 200 && request.Finished == true)
        {
            pageAttempt.Reading = true;
            _ = ReadAndSaveAsync(pageAttempt.Attempt, request);
        }
    }

    private async Task ReadAndSaveAsync(ClaudeRefreshAttempt attempt, ClaudePageRequest request)
    {
        ClaudeUsageCache cache;
        try
        {
            Task<string> pending = _browser.CoreWebView2.CallDevToolsProtocolMethodAsync("Network.getResponseBody",
                JsonSerializer.Serialize(new { requestId = request.Id }));
            string result = await pending;
            if (_refresh.Accepts(attempt) == false)
            {
                return;
            }

            using JsonDocument envelope = JsonDocument.Parse(result);
            string? body = ReadString(envelope.RootElement, "body");
            if (body == null || body.Length > 88_000)
            {
                throw new ClaudeWebResponseException(body == null ? ClaudeRefreshResult.ResponseFormat :
                                                     ClaudeRefreshResult.ResponseRange);
            }

            byte[] payload = IsTrue(envelope.RootElement, "base64Encoded") == true ?
                             Convert.FromBase64String(body) : Encoding.UTF8.GetBytes(body);
            if (payload.Length > 65536)
            {
                throw new ClaudeWebResponseException(ClaudeRefreshResult.ResponseRange);
            }

            using JsonDocument json = JsonDocument.Parse(payload);
            cache = _parser.Parse(json.RootElement, request.ReceivedAt);
        }
        catch (ClaudeWebResponseException exception)
        {
            _refresh.Fail(attempt, exception.Result, 200);
            return;
        }
        catch (Exception exception) when (exception is JsonException or FormatException)
        {
            _refresh.Fail(attempt, ClaudeRefreshResult.ResponseFormat, 200);
            return;
        }
        catch (Exception)
        {
            _refresh.Fail(attempt, ClaudeRefreshResult.NetworkFailed, 200);
            return;
        }

        try
        {
            await _store.SaveAsync(cache, replace => _refresh.Commit(attempt, cache, replace), attempt.Token);
        }
        catch (OperationCanceledException) when (attempt.Token.IsCancellationRequested == true)
        {
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _refresh.Fail(attempt, ClaudeRefreshResult.StorageWrite, 200);
        }
    }

    private static bool IsOfficial(string? value, out Uri uri)
    {
        if (Uri.TryCreate(value, UriKind.Absolute, out Uri? parsed) == true && parsed.Scheme == "https" &&
            parsed.Host == "claude.ai" && parsed.IsDefaultPort == true && parsed.UserInfo.Length == 0)
        {
            uri = parsed;
            return true;
        }

        uri = null!;
        return false;
    }

    private static bool IsLoginPage(string? url) => IsOfficial(url, out Uri uri) == true &&
        (uri.AbsolutePath.TrimEnd('/') is "/login" or "/signup");

    private static bool IsUsagePage(string? url) => IsOfficial(url, out Uri uri) == true &&
        uri.AbsolutePath.TrimEnd('/') == "/settings/usage";

    private static ClaudeRefreshRoute GetRefreshRoute(string? url)
    {
        if (IsUsagePage(url) == true)
        {
            return ClaudeRefreshRoute.Usage;
        }

        return IsOfficial(url, out Uri uri) == true && (uri.AbsolutePath is "/settings" or "/settings/") &&
               uri.Query.Length == 0 ? ClaudeRefreshRoute.SettingsBootstrap : ClaudeRefreshRoute.Other;
    }

    private bool CanUseDocument(ClaudePageAttempt pageAttempt) => pageAttempt.Attempt.Trigger == ClaudeRefreshTrigger.Page ?
        IsUsagePage(_documentUrl) : _refreshRoute == ClaudeRefreshRoute.Usage;

    private static bool IsUsageEndpoint(string? url) => IsOfficial(url, out Uri uri) == true &&
        uri.Segments is ["/", "api/", "organizations/", { Length: > 1 }, "usage"];

    private static string? ReadString(JsonElement item, string name) =>
        item.TryGetProperty(name, out JsonElement value) == true && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool IsTrue(JsonElement item, string name) =>
        item.TryGetProperty(name, out JsonElement value) == true && value.ValueKind == JsonValueKind.True;

    private void OnRefreshChanged(object? sender, EventArgs args)
    {
        if (_refresh.State.IsActive == false && _pageAttempt != null)
        {
            if (_refresh.State.Result == ClaudeRefreshResult.ResponseTimeout)
            {
                RetireLoader(_pageAttempt.Loader);
            }

            _passiveAfter = (_refresh.Now - DateTimeOffset.UnixEpoch).TotalSeconds;
            _pageAttempt = null;
        }

        if (_disposed == false && _refresh.State.Phase != ClaudeRefreshPhase.Stopped)
        {
            _status.Text = UsageDisplayHelper.DescribeClaude(_refresh.State, _refresh.Now).Detail ??
                "Claude 사용량 수신 완료. 이 창을 닫아도 트레이에서 주기적으로 갱신합니다.";
        }
    }

    private void RetireLoader(string? loader)
    {
        if (loader != null)
        {
            _expiredLoaders.Enqueue(loader);
            if (_expiredLoaders.Count > 32)
            {
                _expiredLoaders.Dequeue();
            }
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            if (_refresh.Active is { Trigger: ClaudeRefreshTrigger.Page } passive)
            {
                RetireLoader(_pageAttempt?.Loader);
                _refresh.Cancel(passive);
            }

            Hide();
        }

        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        _disposed = true;
        if (disposing == true)
        {
            _refresh.Changed -= OnRefreshChanged;
            _browser.Dispose();
        }

        base.Dispose(disposing);
    }
}
