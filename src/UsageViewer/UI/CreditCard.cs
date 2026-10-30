using System.Globalization;
using UsageViewer.Models;

namespace UsageViewer.UI;

internal sealed class CreditCard : Panel
{
    public CreditCard(string bucketName, CreditBalance? credits, bool isStale)
    {
        BackColor = Color.FromArgb(30, 35, 43);
        ForeColor = Color.FromArgb(239, 243, 249);
        Padding = new Padding(18, 10, 18, 10);
        string balance = "미제공";
        if (credits?.Unlimited == true)
        {
            balance = "무제한";
        }
        else if (credits?.Balance != null)
        {
            balance = credits.Balance.Value.ToString("#,0.##", CultureInfo.InvariantCulture) + " 크레딧";
        }
        else if (credits?.HasCredits == false)
        {
            balance = "잔액 없음";
        }

        TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 27));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 46));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 27));
        layout.Controls.Add(CreateLabel("크레딧 잔액", 10, FontStyle.Bold, ForeColor), 0, 0);
        layout.Controls.Add(CreateLabel(balance, 19, FontStyle.Bold, Color.FromArgb(111, 226, 192)), 0, 1);
        string detail = isStale == true ? $"{bucketName} · 이전 조회 값" :
                        credits == null ? $"{bucketName} · 서버에서 잔액 정보를 제공하지 않았습니다" : bucketName;
        layout.Controls.Add(CreateLabel(detail, 8.5f, FontStyle.Regular, Color.FromArgb(151, 164, 181)), 0, 2);
        Controls.Add(layout);
        AccessibleName = $"{bucketName}, 크레딧 잔액 {balance}";
        if (isStale == true)
        {
            AccessibleName += ", 이전 조회 값";
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using Pen border = new Pen(Color.FromArgb(48, 55, 65));
        e.Graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
    }

    private Label CreateLabel(string text, float size, FontStyle style, Color color)
    {
        return new Label
        {
            Text = text,
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI", size, style),
            ForeColor = color,
            TextAlign = ContentAlignment.MiddleLeft,
            AutoEllipsis = true,
            UseMnemonic = false,
            Margin = Padding.Empty
        };
    }
}
