using System.Diagnostics;
using UsageViewer.Models;
using UsageViewer.Services;

namespace UsageViewer.UI;

internal sealed class CodexConnectionWindow : Form
{
    private readonly CodexUsageClient _client;
    private readonly Label _status;
    private readonly Font _headingFont = new Font("Segoe UI", 13, FontStyle.Bold);
    private readonly Font _bodyFont = new Font("Segoe UI", 9);
    private CancellationTokenSource? _cancellation;
    private Task? _activeConnection;
    private bool _disposed;

    public bool IsConnecting => _activeConnection?.IsCompleted == false;
    public Task? ActiveConnection => _activeConnection;
    public event EventHandler<UsageSnapshot>? UsageReceived;
    public event EventHandler<string>? ConnectionError;

    public CodexConnectionWindow(CodexUsageClient client)
    {
        _client = client;
        Text = "Codex 구독 연결 · UsageViewer";
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(410, 210);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(23, 29, 37);
        ForeColor = Color.FromArgb(237, 242, 248);
        Label title = new Label
        {
            Text = "ChatGPT 구독 연결",
            AutoSize = true,
            Location = new Point(20, 18),
            Font = _headingFont
        };
        Label description = new Label
        {
            Text = "브라우저에서 Codex 앱과 같은 ChatGPT 계정으로 로그인해 주세요.\n이 표시기만 연결하며 다른 앱의 API 로그인은 유지됩니다.",
            Location = new Point(20, 57),
            Size = new Size(370, 52),
            Font = _bodyFont
        };
        _status = new Label
        {
            Location = new Point(20, 116),
            Size = new Size(370, 42),
            ForeColor = Color.FromArgb(168, 181, 198),
            Font = _bodyFont
        };
        Button close = new Button
        {
            Text = "닫기",
            Location = new Point(306, 168),
            Size = new Size(84, 28),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(43, 52, 65),
            ForeColor = ForeColor
        };
        close.Click += (_, _) => Close();
        Controls.AddRange(new Control[] { title, description, _status, close });
    }

    public Task ConnectAsync(CancellationToken cancellationToken)
    {
        Show();
        Activate();
        if (IsConnecting == true)
        {
            return _activeConnection!;
        }

        _cancellation?.Dispose();
        _cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _activeConnection = ConnectCoreAsync(_cancellation.Token);

        return _activeConnection;
    }

    private async Task ConnectCoreAsync(CancellationToken cancellationToken)
    {
        _status.Text = "안전한 연결을 준비하고 있습니다…";
        try
        {
            UsageSnapshot snapshot = await _client.ConnectAsync(uri =>
            {
                _status.Text = "브라우저에서 로그인을 마치면 사용량이 자동으로 표시됩니다.";
                Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
            }, cancellationToken);
            if (_disposed == false)
            {
                _status.Text = "연결 완료 · 구독 사용량을 가져왔습니다.";
                UsageReceived?.Invoke(this, snapshot);
                Hide();
            }
        }
        catch (OperationCanceledException)
        {
            if (_disposed == false)
            {
                _status.Text = "연결을 취소했습니다. 연결하기를 눌러 다시 시도할 수 있습니다.";
            }
        }
        catch (Exception exception)
        {
            if (_disposed == false)
            {
                string error = exception is UsageQueryException ? exception.Message : "ChatGPT 연결을 완료하지 못했습니다.";
                _status.Text = error;
                ConnectionError?.Invoke(this, error);
            }
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            _cancellation?.Cancel();
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
            _cancellation?.Cancel();
            _cancellation?.Dispose();
            _headingFont.Dispose();
            _bodyFont.Dispose();
        }

        base.Dispose(disposing);
    }
}
