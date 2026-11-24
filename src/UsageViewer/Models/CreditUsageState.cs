namespace UsageViewer.Models;

internal sealed record CreditUsageState(string Label, bool HasBalance = false, bool DeductionConfirmed = false,
                                        string? Detail = null, string? BucketId = null);
