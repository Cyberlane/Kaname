using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cyberlane.KanameLink;

internal sealed class CoreClient
{
    private const int MaximumResponseBytes = 262_144;
    private const int MaximumErrorBytes = 16_384;
    private readonly string? executablePath;

    public CoreClient(string? executablePath = null)
    {
        this.executablePath = executablePath ?? ResolveExecutable();
    }

    public async Task<LinkSnapshot> SnapshotAsync(CancellationToken cancellationToken)
    {
        var response = await RequestAsync(
            new CoreRequest(1, Guid.NewGuid().ToString("D"), "snapshot", new Dictionary<string, string>()),
            cancellationToken
        );
        return response.Snapshot ?? throw new CoreClientException("response_missing_snapshot");
    }

    public async Task<LinkSnapshot> EnrollAsync(
        string invitationJson,
        string displayName,
        CancellationToken cancellationToken
    )
    {
        displayName = displayName.Trim();
        if (displayName.Length is < 1 or > 128 || displayName.Any(char.IsControl))
        {
            throw new CoreClientException("display_name_invalid");
        }
        var invitationBytes = System.Text.Encoding.UTF8.GetBytes(invitationJson);
        if (invitationBytes.Length is < 2 or > 65_536)
        {
            throw new CoreClientException("invitation_invalid");
        }
        LinkInvitationArtifact invite;
        try
        {
            invite = JsonSerializer.Deserialize<LinkInvitationArtifact>(invitationBytes, JsonOptions.Default)
                ?? throw new CoreClientException("invitation_invalid");
        }
        catch (JsonException)
        {
            throw new CoreClientException("invitation_invalid");
        }
        var response = await RequestAsync(
            new CoreRequest(
                1,
                Guid.NewGuid().ToString("D"),
                "enroll",
                new EnrollmentPayload(invite, displayName)
            ),
            cancellationToken
        );
        return response.Snapshot ?? throw new CoreClientException("response_missing_snapshot");
    }

    public async Task SendMessageAsync(
        string spaceId,
        string discussionId,
        string body,
        CancellationToken cancellationToken
    )
    {
        if (string.IsNullOrWhiteSpace(body) || System.Text.Encoding.UTF8.GetByteCount(body) > 16_384)
        {
            throw new CoreClientException("message_invalid");
        }
        await RequestAsync(
            new CoreRequest(
                1,
                Guid.NewGuid().ToString("D"),
                "sendMessage",
                new Dictionary<string, string>
                {
                    ["spaceID"] = spaceId,
                    ["discussionID"] = discussionId,
                    ["body"] = body.Trim(),
                }
            ),
            cancellationToken
        );
    }

    private async Task<CoreResponse> RequestAsync(
        CoreRequest request,
        CancellationToken cancellationToken
    )
    {
        if (executablePath is null || !File.Exists(executablePath))
        {
            throw new CoreClientException("signed_core_unavailable");
        }

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = executablePath,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        };
        process.StartInfo.ArgumentList.Add("rpc");
        if (!process.Start())
        {
            throw new CoreClientException("core_launch_failed");
        }

        var input = JsonSerializer.Serialize(request, JsonOptions.Default);
        await process.StandardInput.WriteAsync(input.AsMemory(), cancellationToken);
        process.StandardInput.Close();

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        byte[] output;
        try
        {
            var outputTask = ReadBoundedAsync(
                process.StandardOutput.BaseStream,
                MaximumResponseBytes,
                timeout.Token
            );
            var errorTask = DrainBoundedAsync(
                process.StandardError.BaseStream,
                MaximumErrorBytes,
                timeout.Token
            );
            output = await outputTask;
            await process.WaitForExitAsync(timeout.Token);
            await errorTask;
        }
        catch (CoreClientException)
        {
            TryTerminate(process);
            throw;
        }
        catch (OperationCanceledException)
        {
            TryTerminate(process);
            throw new CoreClientException("core_request_timed_out");
        }
        if (process.ExitCode != 0)
        {
            throw new CoreClientException("core_request_failed");
        }

        var response = JsonSerializer.Deserialize<CoreResponse>(output, JsonOptions.Default)
            ?? throw new CoreClientException("core_response_invalid");
        if (response.SchemaVersion != 1 || response.RequestId != request.RequestId)
        {
            throw new CoreClientException("core_response_mismatch");
        }
        if (!response.Ok)
        {
            throw new CoreClientException(response.ErrorCode ?? "core_request_rejected");
        }
        return response;
    }

    private static async Task<byte[]> ReadBoundedAsync(
        Stream stream,
        int maximumBytes,
        CancellationToken cancellationToken
    )
    {
        using var output = new MemoryStream();
        var buffer = new byte[16_384];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken);
            if (count == 0) break;
            if (output.Length + count > maximumBytes)
            {
                throw new CoreClientException("core_response_too_large");
            }
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }

    private static async Task DrainBoundedAsync(
        Stream stream,
        int retainedByteLimit,
        CancellationToken cancellationToken
    )
    {
        var buffer = new byte[4_096];
        var retained = 0;
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken);
            if (count == 0) break;
            retained = Math.Min(retainedByteLimit, retained + count);
        }
    }

    private static string? ResolveExecutable()
    {
        var configured = Environment.GetEnvironmentVariable("KANAME_LINK_CLIENT_CORE");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return Path.GetFullPath(configured);
        }
        var bundled = Path.Combine(AppContext.BaseDirectory, "kaname-link-client.exe");
        return File.Exists(bundled) ? bundled : null;
    }

    private static void TryTerminate(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) { }
    }
}

internal sealed class CoreClientException(string errorCode) : Exception(errorCode);

internal sealed record CoreRequest(
    int SchemaVersion,
    [property: JsonPropertyName("requestID")]
    string RequestId,
    string Operation,
    object Payload
);

internal sealed record EnrollmentPayload(LinkInvitationArtifact Invite, string DisplayName);

internal sealed record LinkInvitationArtifact(
    int SchemaVersion,
    string InviteId,
    string SpaceId,
    string SpaceName,
    string GatewayUrl,
    string HostStaticPublicKey,
    string InviteSecret,
    long ExpiresAtUnixMillis
);

internal sealed record CoreResponse(
    int SchemaVersion,
    [property: JsonPropertyName("requestID")]
    string RequestId,
    bool Ok,
    JsonElement? Result,
    string? ErrorCode,
    JsonElement? Error,
    LinkSnapshot? Snapshot
);

internal sealed record LinkSnapshot(
    string Connection,
    long? LastSyncUnixMillis,
    IReadOnlyList<LinkSpace> Spaces,
    string? DiagnosticCode,
    string? VerificationCode
);

internal sealed record LinkSpace(
    string Id,
    string Name,
    string HostName,
    bool Verified,
    IReadOnlyList<LinkDiscussion> Discussions
);

internal sealed record LinkDiscussion(
    string Id,
    string Title,
    string Status,
    string ActionLabel,
    IReadOnlyList<LinkMessage> Messages
);

internal sealed record LinkMessage(
    string Id,
    string Author,
    string AuthorName,
    string Body,
    long SentAtUnixMillis,
    string Receipt
);

internal static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };
}
