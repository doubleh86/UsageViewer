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

    public async Task<UsageSnapshot> ReadAsync(CancellationToken cancellationToken)
    {
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        CancellationToken queryToken = timeout.Token;
        string executable = _locator.Find();
        ProcessStartInfo startInfo = new ProcessStartInfo(executable)
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

        using Process process = new Process { StartInfo = startInfo };
        Task? stderrDrain = null;
        try
        {
            if (process.Start() == false)
            {
                throw new UsageQueryException("Codex 조회 프로세스를 시작하지 못했습니다.");
            }

            // Drain without recording raw stderr: it can contain paths or account information.
            stderrDrain = DrainErrorsAsync(process.StandardError, queryToken);
            await SendAsync(process, new
            {
                id = 1,
                method = "initialize",
                @params = new { clientInfo = new { name = "usage_viewer", title = "UsageViewer", version = "0.1.0" } }
            }, queryToken);
            await ReadResultAsync(process, 1, queryToken);
            await SendAsync(process, new { method = "initialized", @params = new { } }, queryToken);

            await SendAsync(process, new { id = 2, method = "account/read", @params = new { refreshToken = false } }, queryToken);
            JsonElement accountResponse = await ReadResultAsync(process, 2, queryToken);
            string planName = ReadPlanName(accountResponse);

            await SendAsync(process, new { id = 3, method = "account/rateLimits/read", @params = new { } }, queryToken);
            JsonElement limits = await ReadResultAsync(process, 3, queryToken);

            return _parser.Parse(planName, limits);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested == false)
        {
            throw new UsageQueryException("사용량 조회 시간이 초과되었습니다. 네트워크 연결을 확인해 주세요.");
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
        finally
        {
            timeout.Cancel();
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
            string? line = await process.StandardOutput.ReadLineAsync(cancellationToken);
            if (line == null)
            {
                throw new UsageQueryException("Codex 조회 프로세스가 응답 전에 종료되었습니다.");
            }

            if (string.IsNullOrWhiteSpace(line) == true)
            {
                continue;
            }

            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement message = document.RootElement;
            if (message.ValueKind != JsonValueKind.Object ||
                message.TryGetProperty("id", out JsonElement id) == false)
            {
                continue;
            }

            if (message.TryGetProperty("method", out _) == true)
            {
                // This client never grants approvals, supplies tokens, or starts agent work.
                await SendAsync(process, new
                {
                    id = id.Clone(),
                    error = new { code = -32601, message = "UsageViewer supports read-only account queries only." }
                }, cancellationToken);
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

    private string ReadPlanName(JsonElement response)
    {
        if (response.TryGetProperty("account", out JsonElement account) == false ||
            account.ValueKind != JsonValueKind.Object)
        {
            throw new UsageQueryException("Codex에 로그인해 주세요. 터미널에서 codex login을 실행한 뒤 새로고침하세요.");
        }

        string? type = account.TryGetProperty("type", out JsonElement authType) == true ? authType.GetString() : null;
        if (type != "chatgpt")
        {
            throw new UsageQueryException("ChatGPT 계정 로그인이 필요합니다. API 키·Bedrock 사용량은 이 앱의 조회 대상이 아닙니다.");
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
