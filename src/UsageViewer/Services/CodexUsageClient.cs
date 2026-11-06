using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using UsageViewer.Models;

namespace UsageViewer.Services;

internal sealed class CodexUsageClient
{
    private readonly CodexExecutableLocator _locator = new CodexExecutableLocator();
    private readonly UsageResponseParser _parser = new UsageResponseParser();
    private readonly string _profilePath;

    public CodexUsageClient(string? profilePath = null)
    {
        _profilePath = profilePath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                                   "UsageViewer", "CodexProfile");
    }

    public Task<UsageSnapshot> ReadAsync(CancellationToken cancellationToken)
    {
        return RunAsync(null, cancellationToken);
    }

    public Task<UsageSnapshot> ConnectAsync(Action<Uri> openAuthorization, CancellationToken cancellationToken)
    {
        return RunAsync(openAuthorization, cancellationToken);
    }

    private async Task<UsageSnapshot> RunAsync(Action<Uri>? openAuthorization, CancellationToken cancellationToken)
    {
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(openAuthorization == null ? TimeSpan.FromSeconds(30) : TimeSpan.FromMinutes(5));
        CancellationToken queryToken = timeout.Token;
        queryToken.ThrowIfCancellationRequested();
        if (openAuthorization != null)
        {
            Directory.CreateDirectory(_profilePath);
        }

        bool isolated = openAuthorization != null || Directory.Exists(_profilePath) == true;
        try
        {
            UsageSnapshot snapshot;
            try
            {
                snapshot = await RunProcessAsync(isolated, openAuthorization, queryToken);
            }
            catch (UsageQueryException) when (openAuthorization == null && isolated == true &&
                                              queryToken.IsCancellationRequested == false)
            {
                // Retry once after the dedicated process is fully stopped, within the original deadline.
                snapshot = await RunProcessAsync(false, null, queryToken);
            }

            queryToken.ThrowIfCancellationRequested();

            return snapshot;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested == false)
        {
            throw new UsageQueryException(openAuthorization == null ?
                                          "사용량 조회 시간이 초과되었습니다. 네트워크 연결을 확인해 주세요." :
                                          "ChatGPT 연결 대기 시간이 지났습니다. 연결하기를 다시 눌러 주세요.");
        }
    }

    private async Task<UsageSnapshot> RunProcessAsync(bool isolated, Action<Uri>? openAuthorization,
                                                     CancellationToken queryToken)
    {
        queryToken.ThrowIfCancellationRequested();
        ProcessStartInfo startInfo = CreateStartInfo(isolated);
        using CancellationTokenSource stderrCancellation = CancellationTokenSource.CreateLinkedTokenSource(queryToken);

        using Process process = new Process { StartInfo = startInfo };
        Task? stderrDrain = null;
        try
        {
            queryToken.ThrowIfCancellationRequested();
            if (process.Start() == false)
            {
                throw new UsageQueryException("Codex 조회 프로세스를 시작하지 못했습니다.");
            }

            // Drain without recording raw stderr: it can contain paths or account information.
            stderrDrain = DrainErrorsAsync(process.StandardError, stderrCancellation.Token);
            await SendAsync(process, new
            {
                id = 1,
                method = "initialize",
                @params = new { clientInfo = new { name = "usage_viewer", title = "UsageViewer", version = "0.1.0" } }
            }, queryToken);
            await ReadResultAsync(process, 1, queryToken);
            await SendAsync(process, new { method = "initialized", @params = new { } }, queryToken);

            if (openAuthorization != null)
            {
                await SendAsync(process, new { id = 10, method = "account/login/start", @params = new { type = "chatgpt" } },
                                queryToken);
                JsonElement login = await ReadResultAsync(process, 10, queryToken);
                string? loginId = login.TryGetProperty("loginId", out JsonElement identifier) == true ? identifier.GetString() : null;
                string? url = login.TryGetProperty("authUrl", out JsonElement authorization) == true ? authorization.GetString() : null;
                Uri uri = ValidateAuthorizationUrl(url);
                if (string.IsNullOrWhiteSpace(loginId) == true)
                {
                    throw new UsageQueryException("ChatGPT 연결 요청을 시작하지 못했습니다.");
                }

                queryToken.ThrowIfCancellationRequested();
                openAuthorization(uri);
                await WaitForLoginAsync(process, loginId, queryToken);
            }

            await SendAsync(process, new { id = 2, method = "account/read", @params = new { refreshToken = false } }, queryToken);
            JsonElement accountResponse = await ReadResultAsync(process, 2, queryToken);
            string planName = ReadPlanName(accountResponse);

            await SendAsync(process, new { id = 3, method = "account/rateLimits/read", @params = new { } }, queryToken);
            JsonElement limits = await ReadResultAsync(process, 3, queryToken);

            return _parser.Parse(planName, limits);
        }
        catch (Win32Exception)
        {
            throw new UsageQueryException("Codex 실행 파일에 접근하지 못했습니다. 설치 경로와 실행 권한을 확인해 주세요.");
        }
        catch (IOException)
        {
            throw new UsageQueryException("Codex와의 연결이 끊어졌습니다. 잠시 후 새로고침해 주세요.");
        }
        catch (JsonException)
        {
            throw new UsageQueryException("Codex 응답을 읽지 못했습니다. Codex CLI 업데이트가 필요할 수 있습니다.");
        }
        catch (InvalidOperationException)
        {
            throw new UsageQueryException("Codex 응답 형식이 올바르지 않습니다. Codex CLI 업데이트 후 다시 확인해 주세요.");
        }
        finally
        {
            try
            {
                stderrCancellation.Cancel();
                await StopProcessAsync(process);
                if (stderrDrain != null)
                {
                    try
                    {
                        await stderrDrain;
                    }
                    catch (OperationCanceledException)
                    {
                    }
                    catch (IOException)
                    {
                    }
                }
            }
            finally
            {
                // Cancellation takes precedence even if it arrives while an error is being cleaned up.
                queryToken.ThrowIfCancellationRequested();
            }
        }
    }

    private ProcessStartInfo CreateStartInfo(bool isolated)
    {
        ProcessStartInfo startInfo = new ProcessStartInfo(_locator.Find())
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = AppContext.BaseDirectory
        };
        startInfo.ArgumentList.Add("app-server");
        startInfo.ArgumentList.Add("--listen");
        startInfo.ArgumentList.Add("stdio://");
        if (isolated == true)
        {
            startInfo.Environment["CODEX_HOME"] = _profilePath;
            foreach (string name in new[] { "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
                                           "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_FEDERATION_RULE_ID",
                                           "OPENAI_WORKLOAD_IDENTITY_CONTEXT" })
            {
                startInfo.Environment.Remove(name);
            }

            startInfo.ArgumentList.Add("-c");
            startInfo.ArgumentList.Add("cli_auth_credentials_store=\"file\"");
        }

        return startInfo;
    }

    private Uri ValidateAuthorizationUrl(string? url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out Uri? uri) == false || uri.Scheme != Uri.UriSchemeHttps ||
            uri.IsDefaultPort == false || string.IsNullOrEmpty(uri.UserInfo) == false ||
            (uri.Host != "chatgpt.com" && uri.Host != "auth.openai.com"))
        {
            throw new UsageQueryException("공식 ChatGPT 연결 주소를 확인하지 못했습니다.");
        }

        return uri;
    }

    private async Task WaitForLoginAsync(Process process, string loginId, CancellationToken cancellationToken)
    {
        while (true)
        {
            JsonElement message = await ReadMessageAsync(process, cancellationToken);
            if (message.TryGetProperty("id", out JsonElement id) == true &&
                message.TryGetProperty("method", out _) == true)
            {
                await RejectServerRequestAsync(process, id, cancellationToken);
                continue;
            }

            if (message.TryGetProperty("method", out JsonElement method) == false ||
                method.GetString() != "account/login/completed" ||
                message.TryGetProperty("params", out JsonElement result) == false ||
                result.TryGetProperty("loginId", out JsonElement completedId) == false ||
                completedId.GetString() != loginId)
            {
                continue;
            }

            if (result.TryGetProperty("success", out JsonElement success) == false || success.ValueKind != JsonValueKind.True)
            {
                throw new UsageQueryException("ChatGPT 연결이 완료되지 않았습니다. 연결하기를 다시 눌러 주세요.");
            }

            return;
        }
    }

    private async Task SendAsync(Process process, object message, CancellationToken cancellationToken)
    {
        string json = JsonSerializer.Serialize(message);
        await process.StandardInput.WriteLineAsync(json.AsMemory(), cancellationToken);
        await process.StandardInput.FlushAsync(cancellationToken);
    }

    private async Task<JsonElement> ReadResultAsync(Process process, int requestId, CancellationToken cancellationToken)
    {
        while (true)
        {
            JsonElement message = await ReadMessageAsync(process, cancellationToken);
            if (message.ValueKind != JsonValueKind.Object ||
                message.TryGetProperty("id", out JsonElement id) == false)
            {
                continue;
            }

            if (message.TryGetProperty("method", out _) == true)
            {
                await RejectServerRequestAsync(process, id, cancellationToken);
                continue;
            }

            if (id.ValueKind != JsonValueKind.Number || id.TryGetInt32(out int value) == false || value != requestId)
            {
                continue;
            }

            if (message.TryGetProperty("error", out _) == true)
            {
                throw new UsageQueryException("Codex가 조회를 거절했습니다. CLI 로그인 상태와 네트워크를 확인해 주세요.");
            }

            if (message.TryGetProperty("result", out JsonElement result) == false ||
                result.ValueKind != JsonValueKind.Object)
            {
                throw new UsageQueryException("Codex 응답에 조회 결과가 없습니다.");
            }

            return result.Clone();
        }
    }

    private async Task<JsonElement> ReadMessageAsync(Process process, CancellationToken cancellationToken)
    {
        while (true)
        {
            string? line = await process.StandardOutput.ReadLineAsync(cancellationToken);
            if (line == null)
            {
                throw new UsageQueryException("Codex 조회 프로세스가 응답 전에 종료되었습니다.");
            }

            if (string.IsNullOrWhiteSpace(line) == false)
            {
                using JsonDocument document = JsonDocument.Parse(line);
                if (document.RootElement.ValueKind == JsonValueKind.Object)
                {
                    return document.RootElement.Clone();
                }
            }
        }
    }

    private Task RejectServerRequestAsync(Process process, JsonElement id, CancellationToken cancellationToken)
    {
        // Never grant approvals, supply tokens, or start agent work.
        return SendAsync(process, new
        {
            id = id.Clone(),
            error = new { code = -32601, message = "UsageViewer does not handle server-initiated requests." }
        }, cancellationToken);
    }

    private string ReadPlanName(JsonElement response)
    {
        if (response.TryGetProperty("account", out JsonElement account) == false ||
            account.ValueKind != JsonValueKind.Object)
        {
            throw new UsageQueryException("구독 한도를 연결하려면 ChatGPT 연결하기를 눌러 주세요.");
        }

        string? type = account.TryGetProperty("type", out JsonElement authType) == true ? authType.GetString() : null;
        if (type != "chatgpt")
        {
            throw new UsageQueryException(type == "apiKey" ?
                                          "현재 CLI는 API 키 연결입니다. 구독 한도는 ChatGPT 연결하기로 확인하세요." :
                                          "구독 한도를 조회하려면 ChatGPT 연결하기를 눌러 주세요.");
        }

        string? plan = account.TryGetProperty("planType", out JsonElement planType) == true ? planType.GetString() : null;

        return string.IsNullOrWhiteSpace(plan) == true ? "ChatGPT" : plan;
    }

    private async Task DrainErrorsAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        char[] buffer = new char[2048];
        while (await reader.ReadAsync(buffer.AsMemory(), cancellationToken) > 0)
        {
        }
    }

    private async Task StopProcessAsync(Process process)
    {
        try
        {
            if (process.HasExited == true)
            {
                return;
            }

            process.StandardInput.Close();
            using CancellationTokenSource gracePeriod = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            try
            {
                await process.WaitForExitAsync(gracePeriod.Token);
            }
            catch (OperationCanceledException)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
            }
        }
        catch (InvalidOperationException)
        {
            // Process startup failed or it already exited during cleanup.
        }
        catch (Win32Exception)
        {
            // The child may have exited between the state check and termination.
        }
    }
}
