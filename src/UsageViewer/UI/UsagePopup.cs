using UsageViewer.Models;

namespace UsageViewer.UI;

internal sealed class UsagePopup : Form
{
    private readonly Label _planLabel;
    private readonly Label _statusLabel;
    private readonly Label _noticeLabel;
    private readonly FlowLayoutPanel _cards;
    private readonly Button _refreshButton;
    private readonly Color _muted = Color.FromArgb(151, 164, 181);
    private bool _allowClose;
    private long _lastDeactivatedAt = -1000;
    private Point? _anchor;

    public bool JustDeactivated => Environment.TickCount64 - _lastDeactivatedAt < 300;

    public event EventHandler? RefreshRequested;

    public UsagePopup()
    {
        Text = "Codex 사용량 · UsageViewer";
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(392, 580);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        BackColor = Color.FromArgb(20, 25, 32);
        ForeColor = Color.FromArgb(239, 243, 249);
        Padding = new Padding(1);

        Panel header = new Panel { Dock = DockStyle.Top, Size = new Size(392, 104) };
        Label logo = CreateLabel("C", 22, 20, 42, 43, 22, FontStyle.Bold);
        logo.ForeColor = Color.FromArgb(111, 226, 192);
        Label title = CreateLabel("Codex", 73, 16, 210, 33, 20, FontStyle.Bold);
        Label subtitle = CreateLabel("USAGE MONITOR", 75, 53, 220, 20, 8, FontStyle.Bold);
        subtitle.ForeColor = _muted;
        _planLabel = CreateLabel("계정 확인 중", 24, 80, 300, 20, 9);
        _planLabel.ForeColor = _muted;
        Button hideButton = CreateButton("×", 42, 36);
        hideButton.Location = new Point(328, 17);
        hideButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        hideButton.AccessibleName = "팝업 닫기";
        hideButton.Click += (_, _) => Hide();
        header.Controls.AddRange(new Control[] { logo, title, subtitle, _planLabel, hideButton });

        Panel footer = new Panel { Dock = DockStyle.Bottom, Height = 94 };
        TableLayoutPanel footerLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(22, 6, 22, 16),
            ColumnCount = 1,
            RowCount = 2
        };
        footerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        footerLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        footerLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        _statusLabel = CreateLabel("연결 준비 중", 24, 8, 344, 20, 8.5f);
        _statusLabel.ForeColor = _muted;
        _refreshButton = CreateButton("새로고침", 344, 38);
        _statusLabel.Dock = DockStyle.Fill;
        _statusLabel.Margin = Padding.Empty;
        _refreshButton.Dock = DockStyle.Fill;
        _refreshButton.Margin = Padding.Empty;
        _refreshButton.TextAlign = ContentAlignment.MiddleCenter;
        _refreshButton.Click += (_, _) => RefreshRequested?.Invoke(this, EventArgs.Empty);
        footerLayout.Controls.Add(_statusLabel, 0, 0);
        footerLayout.Controls.Add(_refreshButton, 0, 1);
        footer.Controls.Add(footerLayout);

        _noticeLabel = new Label
        {
            Dock = DockStyle.Bottom,
            Height = 70,
            Padding = new Padding(24, 4, 24, 0),
            ForeColor = Color.FromArgb(241, 195, 111),
            Font = new Font("Segoe UI", 9),
            Visible = false
        };
        _cards = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(22, 14, 22, 0)
        };
        _cards.SizeChanged += (_, _) => ResizeCards();
        Controls.Add(_cards);
        Controls.Add(_noticeLabel);
        Controls.Add(footer);
        Controls.Add(header);
        Deactivate += (_, _) =>
        {
            _lastDeactivatedAt = Environment.TickCount64;
            Hide();
        };
        KeyDown += (_, args) =>
        {
            if (args.KeyCode == Keys.Escape)
            {
                Hide();
            }
        };
    }

    public void SetState(UsageSnapshot? snapshot, bool refreshing, string? error)
    {
        SuspendLayout();
        _cards.SuspendLayout();
        foreach (Control control in _cards.Controls.Cast<Control>().ToArray())
        {
            _cards.Controls.Remove(control);
            control.Dispose();
        }

        _refreshButton.Enabled = refreshing == false;
        _refreshButton.Text = refreshing == true ? "조회 중…" : "새로고침";
        _noticeLabel.Visible = snapshot != null && error != null;
        _noticeLabel.Text = error;
        if (snapshot == null)
        {
            _planLabel.Text = "ChatGPT 계정 사용 한도";
            AddEmptyState(refreshing, error);
            _statusLabel.Text = refreshing == true ? "Codex에 연결하고 있습니다" : "연결 상태를 확인해 주세요";
        }
        else
        {
            _planLabel.Text = $"{snapshot.PlanName} 플랜 · 사용 한도";
            foreach (UsageBucket bucket in snapshot.Buckets)
            {
                if (bucket.Primary != null)
                {
                    AddCard(bucket.Name, "기본 한도", bucket.Primary, error != null);
                }

                if (bucket.Secondary != null)
                {
                    AddCard(bucket.Name, "추가 한도", bucket.Secondary, error != null);
                }

                CreditCard creditCard = new CreditCard(bucket.Name, bucket.Credits, error != null)
                {
                    Height = (int)(122 * DeviceDpi / 96f),
                    Margin = new Padding(0, 0, 0, (int)(12 * DeviceDpi / 96f))
                };
                _cards.Controls.Add(creditCard);
            }

            string updatedAt = snapshot.RetrievedAt.ToLocalTime().ToString("HH:mm:ss");
            _statusLabel.Text = refreshing == true ? "최신 사용량 조회 중…" : $"{updatedAt} 확인 · 60초마다 자동 갱신";
            if (error != null)
            {
                _statusLabel.Text = $"조회 실패 · 마지막 성공 {updatedAt}";
            }
        }

        _statusLabel.ForeColor = error == null ? _muted : Color.FromArgb(241, 195, 111);
        _cards.ResumeLayout(true);
        ResumeLayout(true);
        ResizeCards();
        FitToScreen();
    }

    public void ShowAt(Point anchor)
    {
        _anchor = anchor;
        FitToScreen();
        Show();
        // Showing on a different monitor can change DPI and therefore the final popup dimensions.
        FitToScreen();
        Activate();
    }

    public void CloseForExit()
    {
        _allowClose = true;
        Close();
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

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using Pen border = new Pen(Color.FromArgb(57, 66, 79));
        e.Graphics.DrawRectangle(border, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        FitToScreen();
        ResizeCards();
    }

    private Label CreateLabel(string text, int x, int y, int width, int height, float fontSize,
                               FontStyle fontStyle = FontStyle.Regular)
    {
        return new Label
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(width, height),
            Font = new Font("Segoe UI", fontSize, fontStyle),
            AutoEllipsis = true,
            UseMnemonic = false
        };
    }

    private Button CreateButton(string text, int width, int height)
    {
        Button button = new Button
        {
            Text = text,
            Size = new Size(width, height),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(37, 45, 56),
            ForeColor = ForeColor,
            Font = new Font("Segoe UI", 10),
            Cursor = Cursors.Hand,
            UseVisualStyleBackColor = false
        };
        button.FlatAppearance.BorderSize = 0;
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(49, 61, 75);

        return button;
    }

    private void AddCard(string bucketName, string fallback, UsageWindow window, bool isStale)
    {
        string name = UsageDisplayHelper.FormatWindow(window.DurationMinutes, fallback);
        UsageCard card = new UsageCard(bucketName, name, window, isStale)
        {
            Height = (int)(184 * DeviceDpi / 96f),
            Margin = new Padding(0, 0, 0, (int)(12 * DeviceDpi / 96f))
        };
        _cards.Controls.Add(card);
    }

    private void AddEmptyState(bool refreshing, string? error)
    {
        float scale = DeviceDpi / 96f;
        Label title = new Label
        {
            Text = refreshing == true ? "사용량을 가져오는 중" : "연결을 확인해 주세요",
            Font = new Font("Segoe UI", 15, FontStyle.Bold),
            Height = (int)(52 * scale),
            Padding = new Padding(0, (int)(12 * scale), 0, 0),
            UseMnemonic = false
        };
        Label message = new Label
        {
            Text = error ?? "이 PC에 로그인된 Codex 계정의\n사용량과 초기화 시각을 확인합니다.",
            Font = new Font("Segoe UI", 10),
            ForeColor = _muted,
            Height = (int)(110 * scale),
            UseMnemonic = false
        };
        _cards.Controls.Add(title);
        _cards.Controls.Add(message);
    }

    private void ResizeCards()
    {
        int width = Math.Max(1, _cards.ClientSize.Width - _cards.Padding.Horizontal);
        foreach (Control card in _cards.Controls)
        {
            card.Width = width;
        }
    }

    private void FitToScreen(Screen? screen = null)
    {
        float scale = DeviceDpi / 96f;
        Screen targetScreen = screen ?? (_anchor.HasValue == true ? Screen.FromPoint(_anchor.Value) : Screen.FromControl(this));
        Rectangle area = targetScreen.WorkingArea;
        int cardHeight = _cards.Controls.Count == 0 ? (int)(240 * scale) :
                         _cards.Controls.Cast<Control>().Sum(control => control.Height + control.Margin.Vertical);
        int desiredHeight = (int)(222 * scale) + cardHeight + (_noticeLabel.Visible == true ? _noticeLabel.Height : 0);
        Height = Math.Min(Math.Max((int)(410 * scale), desiredHeight), area.Height - (int)(24 * scale));
        if (_anchor.HasValue == true)
        {
            Location = PopupPlacementHelper.Calculate(area, Size, (int)(12 * scale));
        }
    }
}
