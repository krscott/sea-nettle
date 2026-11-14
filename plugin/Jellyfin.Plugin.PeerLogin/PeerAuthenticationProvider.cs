using System;
using System.Net.Http;
using System.Threading.Tasks;
using Jellyfin.Data;
using Jellyfin.Database.Implementations.Entities;
using Jellyfin.Database.Implementations.Enums;
using MediaBrowser.Controller.Authentication;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.Net;
using MediaBrowser.Model.Cryptography;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.PeerLogin;

/// <summary>
/// Authenticates users against the source server, with a cached password hash for source outages.
/// </summary>
public sealed partial class PeerAuthenticationProvider : IAuthenticationProvider, IRequiresResolvedUser
{
    private readonly Func<string?> _sourceUrl;
    private readonly Func<IUserManager> _userManager;
    private readonly ICryptoProvider _crypto;
    private readonly SourceClient _source;
    private readonly ILogger _logger;

    /// <summary>
    /// Initializes a new instance of the <see cref="PeerAuthenticationProvider"/> class.
    /// </summary>
    /// <param name="sourceUrl">Reads the configured source URL.</param>
    /// <param name="userManager">Resolves the user manager, which itself depends on authentication providers.</param>
    /// <param name="crypto">Creates and verifies password hashes.</param>
    /// <param name="httpClientFactory">Creates source HTTP clients.</param>
    /// <param name="logger">Logger.</param>
    public PeerAuthenticationProvider(
        Func<string?> sourceUrl,
        Func<IUserManager> userManager,
        ICryptoProvider crypto,
        IHttpClientFactory httpClientFactory,
        ILogger<PeerAuthenticationProvider> logger)
    {
        _sourceUrl = sourceUrl;
        _userManager = userManager;
        _crypto = crypto;
        _logger = logger;
        _source = new SourceClient(httpClientFactory, logger);
    }

    /// <summary>
    /// Gets the identifier Jellyfin stores in <see cref="User.AuthenticationProviderId"/>.
    /// </summary>
    public static string ProviderId { get; } = typeof(PeerAuthenticationProvider).FullName!;

    /// <inheritdoc />
    public string Name => "Peer Login";

    /// <inheritdoc />
    public bool IsEnabled => true;

    /// <inheritdoc />
    public Task<ProviderAuthenticationResult> Authenticate(string username, string password)
    {
        return Authenticate(username, password, null);
    }

    /// <inheritdoc />
    public async Task<ProviderAuthenticationResult> Authenticate(string username, string password, User? resolvedUser)
    {
        // Jellyfin offers unassigned users to every provider; never take over another provider's account (R-LOGIN-9).
        if (resolvedUser is not null && !IsSourceBacked(resolvedUser))
        {
            throw new AuthenticationException("The account does not use Peer Login.");
        }

        var source = SourceClient.ParseSourceUrl(_sourceUrl());
        if (source is null)
        {
            LogInvalidSourceUrl();
            throw new AuthenticationException("Peer Login has no valid source URL.");
        }

        switch (await _source.AuthenticateAsync(source, username, password).ConfigureAwait(false))
        {
            case SourceResult.Accepted accepted:
                try
                {
                    return await AcceptAsync(accepted.Username, password, resolvedUser).ConfigureAwait(false);
                }
                finally
                {
                    await _source.LogoutAsync(source, accepted.AccessToken).ConfigureAwait(false);
                }

            case SourceResult.Unavailable when resolvedUser is not null && MatchesCachedPassword(resolvedUser, password):
                LogCachedSignIn(resolvedUser.Username);
                return new ProviderAuthenticationResult { Username = resolvedUser.Username };

            default:
                // A source rejection never falls back to the cached hash (R-LOGIN-2, R-LOGIN-4).
                throw new AuthenticationException("Invalid username or password.");
        }
    }

    /// <inheritdoc />
    public Task ChangePassword(User user, string newPassword)
    {
        // R-LOGIN-5
        throw new SecurityException("Change this password on the source server.");
    }

    private static bool IsSourceBacked(User user) =>
        string.Equals(user.AuthenticationProviderId, ProviderId, StringComparison.OrdinalIgnoreCase);

    private async Task<ProviderAuthenticationResult> AcceptAsync(string sourceUsername, string password, User? resolvedUser)
    {
        var userManager = _userManager();
        var user = resolvedUser ?? userManager.GetUserByName(sourceUsername);
        var changed = false;

        if (user is null)
        {
            // R-LOGIN-1
            user = await userManager.CreateUserAsync(sourceUsername).ConfigureAwait(false);
            user.AuthenticationProviderId = ProviderId;
            user.SetPermission(PermissionKind.IsAdministrator, false); // R-LOGIN-6
            changed = true;
            LogUserCreated(user.Username);
        }
        else if (!IsSourceBacked(user))
        {
            // R-LOGIN-9
            throw new AuthenticationException("The account does not use Peer Login.");
        }

        if (!MatchesCachedPassword(user, password))
        {
            // R-LOGIN-3
            user.Password = _crypto.CreatePasswordHash(password).ToString();
            changed = true;
        }

        if (changed)
        {
            await userManager.UpdateUserAsync(user).ConfigureAwait(false);
        }

        return new ProviderAuthenticationResult { Username = user.Username };
    }

    private bool MatchesCachedPassword(User user, string password) =>
        user.Password is not null && _crypto.Verify(PasswordHash.Parse(user.Password), password);

    [LoggerMessage(Level = LogLevel.Error, Message = "Peer Login refuses all sign-ins: set an HTTPS or loopback source URL in the plugin settings")]
    private partial void LogInvalidSourceUrl();

    [LoggerMessage(Level = LogLevel.Information, Message = "Created source-backed user {Username}")]
    private partial void LogUserCreated(string username);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Source server unavailable; signed in {Username} with the cached password")]
    private partial void LogCachedSignIn(string username);
}
