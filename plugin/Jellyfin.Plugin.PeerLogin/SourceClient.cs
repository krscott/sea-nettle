using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using MediaBrowser.Common.Net;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.PeerLogin;

/// <summary>
/// Outcome of forwarding a sign-in to the source server.
/// </summary>
internal abstract record SourceResult
{
    private SourceResult()
    {
    }

    /// <summary>The source accepted the credentials.</summary>
    /// <param name="Username">The source's canonical username.</param>
    /// <param name="AccessToken">The source session token, which the caller must log out.</param>
    public sealed record Accepted(string Username, string AccessToken) : SourceResult;

    /// <summary>The source refused the credentials, or answered in a way that cannot be trusted.</summary>
    public sealed record Rejected : SourceResult;

    /// <summary>The source could not answer: a network error, a timeout, or a server error.</summary>
    public sealed record Unavailable : SourceResult;
}

/// <summary>
/// Calls the source server's sign-in and sign-out endpoints.
/// </summary>
internal sealed partial class SourceClient
{
    private const string Authorization =
        "MediaBrowser Client=\"Jellyfin Peer Login\", Device=\"Jellyfin Peer Login\", DeviceId=\"jellyfin-peer-login\", Version=\"1\"";

    private static readonly TimeSpan _timeout = TimeSpan.FromSeconds(10);

    // Jellyfin's request DTOs use PascalCase names.
    private static readonly JsonSerializerOptions _requestOptions = new();

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger _logger;

    public SourceClient(IHttpClientFactory httpClientFactory, ILogger logger)
    {
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    /// <summary>
    /// Parses a configured source URL. Returns null unless it uses HTTPS or a loopback host (R-LOGIN-7).
    /// </summary>
    public static Uri? ParseSourceUrl(string? value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return null;
        }

        var secure = uri.Scheme == Uri.UriSchemeHttps || (uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback);
        return secure ? uri : null;
    }

    public async Task<SourceResult> AuthenticateAsync(Uri source, string username, string password)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(source, "Users/AuthenticateByName"))
        {
            Content = JsonContent.Create(new AuthenticateRequest(username, password), options: _requestOptions),
        };
        request.Headers.TryAddWithoutValidation("Authorization", Authorization);

        using var timeout = new CancellationTokenSource(_timeout);
        try
        {
            using var response = await _httpClientFactory.CreateClient(NamedClient.Default)
                .SendAsync(request, timeout.Token)
                .ConfigureAwait(false);

            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                return new SourceResult.Rejected();
            }

            if ((int)response.StatusCode >= 500)
            {
                LogSourceUnavailable(response.StatusCode.ToString());
                return new SourceResult.Unavailable();
            }

            if (!response.IsSuccessStatusCode)
            {
                LogUnexpectedResponse(response.StatusCode.ToString());
                return new SourceResult.Rejected();
            }

            var body = await response.Content
                .ReadFromJsonAsync<AuthenticateResponse>(timeout.Token)
                .ConfigureAwait(false);
            if (string.IsNullOrEmpty(body?.User?.Name) || string.IsNullOrEmpty(body.AccessToken))
            {
                LogUnexpectedResponse("missing user or token");
                return new SourceResult.Rejected();
            }

            return new SourceResult.Accepted(body.User.Name, body.AccessToken);
        }
        catch (JsonException)
        {
            LogUnexpectedResponse("invalid JSON");
            return new SourceResult.Rejected();
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException)
        {
            LogSourceUnavailable(ex.Message);
            return new SourceResult.Unavailable();
        }
    }

    /// <summary>
    /// Ends the source session for <paramref name="accessToken"/>. Failures are logged, not thrown (R-LOGIN-8).
    /// </summary>
    public async Task LogoutAsync(Uri source, string accessToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(source, "Sessions/Logout"));
        request.Headers.TryAddWithoutValidation("Authorization", $"{Authorization}, Token=\"{accessToken}\"");

        using var timeout = new CancellationTokenSource(_timeout);
        try
        {
            using var response = await _httpClientFactory.CreateClient(NamedClient.Default)
                .SendAsync(request, timeout.Token)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                LogLogoutFailed(response.StatusCode.ToString());
            }
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException)
        {
            LogLogoutFailed(ex.Message);
        }
    }

    private static Uri Endpoint(Uri source, string path) => new($"{source.AbsoluteUri.TrimEnd('/')}/{path}");

    [LoggerMessage(Level = LogLevel.Warning, Message = "Source server is unavailable: {Reason}")]
    private partial void LogSourceUnavailable(string reason);

    [LoggerMessage(Level = LogLevel.Error, Message = "Source server sent an unexpected sign-in response: {Reason}")]
    private partial void LogUnexpectedResponse(string reason);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Could not end the source session: {Reason}")]
    private partial void LogLogoutFailed(string reason);

    private sealed record AuthenticateRequest(string Username, string Pw);

    private sealed record AuthenticateResponse(SourceUser? User, string? AccessToken);

    private sealed record SourceUser(string? Name);
}
