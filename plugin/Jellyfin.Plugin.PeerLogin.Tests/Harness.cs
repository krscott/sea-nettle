using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Database.Implementations.Entities;
using MediaBrowser.Controller.Authentication;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Cryptography;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Jellyfin.Plugin.PeerLogin.Tests;

/// <summary>
/// A provider wired to an in-memory user store and a scripted source server.
/// </summary>
internal sealed class Harness
{
    public const string DefaultProviderId = "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider";
    private const string DefaultResetProviderId = "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider";

    private readonly Dictionary<string, User> _users = new(StringComparer.OrdinalIgnoreCase);

    public Harness()
    {
        UserManager = Substitute.For<IUserManager>();
        UserManager.GetUserByName(Arg.Any<string>())
            .Returns(call => _users.GetValueOrDefault(call.Arg<string>()));
        UserManager.CreateUserAsync(Arg.Any<string>()).Returns(call =>
        {
            var user = new User(call.Arg<string>(), DefaultProviderId, DefaultResetProviderId);
            _users.Add(user.Username, user);
            return user;
        });
        UserManager.UpdateUserAsync(Arg.Any<User>()).Returns(call =>
        {
            Updates.Add(call.Arg<User>().Username);
            return Task.CompletedTask;
        });
    }

    public FakeSource Source { get; } = new();

    public IUserManager UserManager { get; }

    public FakeCrypto Crypto { get; } = new();

    public List<string> Updates { get; } = [];

    public string? SourceUrl { get; set; } = "https://source.example/jellyfin";

    public PeerAuthenticationProvider Provider => new(
        () => SourceUrl,
        () => UserManager,
        Crypto,
        new FakeHttpClientFactory(Source),
        NullLogger<PeerAuthenticationProvider>.Instance);

    public User? Find(string username) => _users.GetValueOrDefault(username);

    public User AddUser(string username, string providerId, string? password)
    {
        var user = new User(username, providerId, DefaultResetProviderId)
        {
            Password = password is null ? null : Crypto.CreatePasswordHash(password).ToString(),
        };
        _users.Add(username, user);
        return user;
    }

    public Task<ProviderAuthenticationResult> SignIn(string username, string password)
    {
        return Provider.Authenticate(username, password, Find(username));
    }
}

/// <summary>
/// Stores passwords reversibly so tests can inspect them; the format round-trips through <see cref="PasswordHash"/>.
/// </summary>
internal sealed class FakeCrypto : ICryptoProvider
{
    public string DefaultHashMethod => "FAKE";

    public PasswordHash CreatePasswordHash(ReadOnlySpan<char> password) =>
        new(DefaultHashMethod, Encoding.UTF8.GetBytes(password.ToArray()));

    public bool Verify(PasswordHash hash, ReadOnlySpan<char> password) =>
        hash.Id == DefaultHashMethod && hash.Hash.SequenceEqual(Encoding.UTF8.GetBytes(password.ToArray()));

    public byte[] GenerateSalt() => [];

    public byte[] GenerateSalt(int length) => new byte[length];
}

internal sealed class FakeHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory
{
    public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
}

/// <summary>
/// A scripted source server that records every request it receives.
/// </summary>
public sealed class FakeSource : HttpMessageHandler
{
    public const string Token = "source-token";

    private Func<HttpResponseMessage> _signIn = () => new HttpResponseMessage(HttpStatusCode.Unauthorized);

    public List<RecordedRequest> Requests { get; } = [];

    public IEnumerable<RecordedRequest> Logouts => Requests.Where(r => r.Uri.AbsolutePath.EndsWith("/Sessions/Logout", StringComparison.Ordinal));

    /// <summary>Accepts any password for <paramref name="username"/>, answering with the source's canonical name.</summary>
    public void Accept(string username, bool isAdministrator = false)
    {
        var body = JsonSerializer.Serialize(new
        {
            User = new { Name = username, Policy = new { IsAdministrator = isAdministrator } },
            AccessToken = Token,
        });
        _signIn = () => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
    }

    public void Respond(HttpStatusCode status) => _signIn = () => new HttpResponseMessage(status);

    public void Fail(Exception exception) => _signIn = () => throw exception;

    public static string[] Outages { get; } = ["connection refused", "timeout", "500", "502", "503"];

    public void Outage(string outage)
    {
        switch (outage)
        {
            case "connection refused":
                Fail(new HttpRequestException("connection refused"));
                break;
            case "timeout":
                Fail(new TaskCanceledException("timed out"));
                break;
            default:
                Respond((HttpStatusCode)int.Parse(outage, System.Globalization.CultureInfo.InvariantCulture));
                break;
        }
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        var authorization = request.Headers.TryGetValues("Authorization", out var values) ? values.Single() : null;
        Requests.Add(new RecordedRequest(request.Method, request.RequestUri!, authorization, body));

        return request.RequestUri!.AbsolutePath.EndsWith("/Sessions/Logout", StringComparison.Ordinal)
            ? new HttpResponseMessage(HttpStatusCode.NoContent)
            : _signIn();
    }
}

public sealed record RecordedRequest(HttpMethod Method, Uri Uri, string? Authorization, string? Body);
