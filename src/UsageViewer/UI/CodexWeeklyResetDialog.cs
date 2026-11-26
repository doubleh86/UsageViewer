namespace UsageViewer.UI;

internal sealed class CodexWeeklyResetDialog : Form
{
    private readonly DateTimePicker _date;
    private readonly DateTimePicker _time;
    private readonly Func<DateTimeOffset?, string?> _save;

    public CodexWeeklyResetDialog(DateTimeOffset? serverResetAt, DateTimeOffset? savedResetAt, bool hasSavedReset,
                                  Func<DateTimeOffset?, string?> save)
    {
        _save = save;
        Text = "Codex 주간 초기화 시간 설정";
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(370, 162);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;

        DateTimeOffset now = DateTimeOffset.Now;
        DateTimeOffset initial = savedResetAt > now ? savedResetAt.Value : serverResetAt ?? now;
        _date = new DateTimePicker
        {
            Format = DateTimePickerFormat.Custom,
            CustomFormat = "yyyy-MM-dd",
            Width = 128,
            AccessibleName = "초기화 예정 날짜"
        };
        _time = new DateTimePicker
        {
            Format = DateTimePickerFormat.Custom,
            CustomFormat = "HH:mm",
            ShowUpDown = true,
            Width = 84,
            AccessibleName = "초기화 예정 시간"
        };
        DateTime local = initial.LocalDateTime;
        if (local < _date.MinDate || local > _date.MaxDate)
        {
            local = now.LocalDateTime;
        }
        _date.Value = local;
        _time.Value = local;

        string serverText = serverResetAt is DateTimeOffset reset ? $"서버 초기화 · {reset.ToLocalTime():yyyy-MM-dd HH:mm}" :
                            "최신 Codex 주간 한도를 조회한 뒤 날짜를 설정할 수 있어요.";
        Label server = new Label { Text = serverText, AutoSize = true };
        Label description = new Label { Text = "선택한 시각은 권장량 계산에만 써요.", AutoSize = true };
        FlowLayoutPanel pickers = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        pickers.Controls.AddRange([_date, _time]);

        Button apply = new Button { Text = "적용", AutoSize = true, Enabled = serverResetAt != null };
        Button clear = new Button { Text = "서버 기준 사용", AutoSize = true, Enabled = hasSavedReset };
        Button cancel = new Button { Text = "취소", AutoSize = true, DialogResult = DialogResult.Cancel };
        apply.Click += (_, _) => SaveCustomTime();
        clear.Click += (_, _) => Save(null);
        FlowLayoutPanel buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false
        };
        buttons.Controls.AddRange([cancel, apply, clear]);

        TableLayoutPanel layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 1,
            RowCount = 4
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(server, 0, 0);
        layout.Controls.Add(description, 0, 1);
        layout.Controls.Add(pickers, 0, 2);
        layout.Controls.Add(buttons, 0, 3);
        Controls.Add(layout);
        AcceptButton = apply;
        CancelButton = cancel;
    }

    private void SaveCustomTime()
    {
        DateTime local = _date.Value.Date.AddHours(_time.Value.Hour).AddMinutes(_time.Value.Minute);
        local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        TimeZoneInfo zone = TimeZoneInfo.Local;
        if (zone.IsInvalidTime(local) == true || zone.IsAmbiguousTime(local) == true)
        {
            MessageBox.Show(this, "시간대가 바뀌는 구간이에요. 다른 시각을 선택해 주세요.", Text,
                            MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        Save(new DateTimeOffset(local, zone.GetUtcOffset(local)));
    }

    private void Save(DateTimeOffset? plannedResetAt)
    {
        string? error = _save(plannedResetAt);
        if (error != null)
        {
            MessageBox.Show(this, error, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        DialogResult = DialogResult.OK;
    }
}
