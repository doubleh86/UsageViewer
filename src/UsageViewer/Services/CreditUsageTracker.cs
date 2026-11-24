using System.Globalization;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class CreditUsageTracker
{
    private static readonly TimeSpan Freshness = TimeSpan.FromMinutes(15);
    private string? _scope;
    private string? _bucket;
    private decimal _balance;
    private DateTimeOffset _receipt;
    private DateTimeOffset? _decreasedAt;
    private decimal _decrease;

    public static UsageBucket? SelectBucket(UsageSnapshot? snapshot)
    {
        return snapshot?.Buckets.FirstOrDefault(bucket => bucket.Id == "codex") ??
               (snapshot?.Buckets.Count == 1 ? snapshot.Buckets[0] : null);
    }

    public CreditUsageState Evaluate(UsageSnapshot? snapshot, string? error, DateTimeOffset now)
    {
        if (snapshot == null || error != null || snapshot.RetrievedAt > now ||
            now - snapshot.RetrievedAt > Freshness || snapshot.Buckets
                .SelectMany(bucket => new[] { bucket.Primary, bucket.Secondary }).OfType<UsageWindow>()
                .Any(window => double.IsFinite(window.UsedPercent) == false || window.UsedPercent < 0 ||
                               window.UsedPercent > 100))
        {
            Reset();
            return new CreditUsageState(snapshot == null ? "크레딧 정보 미제공" : "이전 크레딧 잔액");
        }

        UsageBucket? bucket = SelectBucket(snapshot);
        CreditBalance? credits = bucket?.Credits;
        if (bucket == null || credits == null)
        {
            Reset();
            return new CreditUsageState("크레딧 정보 미제공");
        }
        if (credits.Unlimited == true || credits.Balance is not >= 0)
        {
            Reset();
            return credits.Unlimited == true ? new CreditUsageState("크레딧 무제한", true, BucketId: bucket.Id) :
                   new CreditUsageState(credits.HasCredits == false ? "크레딧 잔액 없음" : "크레딧 잔액 확인 필요");
        }

        decimal balance = credits.Balance.Value;
        string? scope = snapshot.CreditAccountScope;
        if (scope?.Length != 64 || scope.All(Uri.IsHexDigit) == false)
        {
            Reset();
            return Describe(balance, bucket.Id, now);
        }

        if (_scope != scope || _bucket != bucket.Id || snapshot.RetrievedAt - _receipt > Freshness)
        {
            Reset();
            _scope = scope;
            _bucket = bucket.Id;
            _receipt = snapshot.RetrievedAt;
            _balance = balance;
        }
        else if (snapshot.RetrievedAt < _receipt || (snapshot.RetrievedAt == _receipt && balance != _balance))
        {
            return new CreditUsageState("크레딧 수신 확인 필요");
        }
        else if (snapshot.RetrievedAt > _receipt)
        {
            if (balance < _balance)
            {
                _decrease = _balance - balance;
                _decreasedAt = snapshot.RetrievedAt;
            }
            else if (balance > _balance)
            {
                _decreasedAt = null;
                _decrease = 0;
            }

            _receipt = snapshot.RetrievedAt;
            _balance = balance;
        }

        return Describe(balance, bucket.Id, now);
    }

    private CreditUsageState Describe(decimal balance, string bucketId, DateTimeOffset now)
    {
        if (balance == 0)
        {
            return new CreditUsageState("크레딧 잔액 없음", BucketId: bucketId);
        }

        bool confirmed = _decreasedAt != null && now >= _decreasedAt && now - _decreasedAt <= Freshness;
        string amount = _decrease is > 0 and < 0.01m ? "0.01 미만" :
                        _decrease.ToString("#,0.##", CultureInfo.InvariantCulture);
        return new CreditUsageState(confirmed == true ? "크레딧 차감 확인" : "크레딧 잔액 보유", true, confirmed,
            confirmed == true ? "최근 조회보다 " + amount + " 감소" : null, bucketId);
    }

    private void Reset()
    {
        _scope = null;
        _bucket = null;
        _balance = 0;
        _receipt = default;
        _decreasedAt = null;
        _decrease = 0;
    }
}
