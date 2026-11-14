using System;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;
using Jellyfin.Data;
using Jellyfin.Database.Implementations.Enums;
using MediaBrowser.Controller.Authentication;
using MediaBrowser.Controller.Net;
using Xunit;

namespace Jellyfin.Plugin.PeerLogin.Tests;

public class PeerAuthenticationProviderTests
{
    private static readonly string PeerProviderId = PeerAuthenticationProvider.ProviderId;

    // R-LOGIN-1
    [Fact]
    public async Task SourceAcceptedSignInCreatesTheUser()
    {
        var harness = new Harness();
        harness.Source.Accept("Alice");

        var result = await harness.SignIn("alice", "secret");

        Assert.Equal("Alice", result.Username);
        var user = harness.Find("Alice");
        Assert.NotNull(user);
        Assert.Equal("Alice", user.Username);
        Assert.Equal(PeerProviderId, user.AuthenticationProviderId);
        Assert.Contains("Alice", harness.Updates);

        var request = harness.Source.Requests.First();
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("https://source.example/jellyfin/Users/AuthenticateByName", request.Uri.AbsoluteUri);
        Assert.Equal("""{"Username":"alice","Pw":"secret"}""", request.Body);
        Assert.Contains("DeviceId=", request.Authorization, StringComparison.Ordinal);
    }

    // R-LOGIN-1
    [Fact]
    public async Task SourceAcceptedSignInReusesTheSourceBackedUser()
    {
        var harness = new Harness();
        var existing = harness.AddUser("Alice", PeerProviderId, "secret");
        harness.Source.Accept("Alice");

        var result = await harness.SignIn("Alice", "secret");

        Assert.Equal("Alice", result.Username);
        Assert.Same(existing, harness.Find("Alice"));
        Assert.Empty(harness.Updates);
    }

    // R-LOGIN-2
    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task SourceRejectionRefusesTheCachedPassword(HttpStatusCode status)
    {
        var harness = new Harness();
        harness.AddUser("Alice", PeerProviderId, "secret");
        harness.Source.Respond(status);

        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "secret"));
        Assert.Empty(harness.Updates);
    }

    // R-LOGIN-2
    [Theory]
    [InlineData(HttpStatusCode.NotFound)]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.TemporaryRedirect)]
    [InlineData(HttpStatusCode.PermanentRedirect)]
    public async Task UnexpectedSourceStatusRefusesTheCachedPassword(HttpStatusCode status)
    {
        var harness = new Harness();
        harness.AddUser("Alice", PeerProviderId, "secret");
        harness.Source.Respond(status);

        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "secret"));
        Assert.Single(harness.Source.Requests);
    }

    // R-LOGIN-2
    [Theory]
    [InlineData("<html>not json</html>", 0)]
    [InlineData("""{"User":{"Name":"Alice"}}""", 0)]
    [InlineData("""{"AccessToken":"source-token"}""", 1)]
    [InlineData("""{"User":{"Name":""},"AccessToken":"source-token"}""", 1)]
    public async Task UnusableSourceAnswerRefusesTheCachedPassword(string body, int logouts)
    {
        var harness = new Harness();
        harness.AddUser("Alice", PeerProviderId, "secret");
        harness.Source.RespondOk(body);

        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "secret"));

        // R-LOGIN-8: any returned token is logged out.
        Assert.Equal(logouts, harness.Source.Logouts.Count());
    }

    // R-LOGIN-3
    [Theory]
    [MemberData(nameof(Outages))]
    public async Task SourceOutageAcceptsTheCachedPassword(string outage)
    {
        var harness = new Harness();
        harness.AddUser("Alice", PeerProviderId, "secret");
        harness.Source.Outage(outage);

        var result = await harness.SignIn("Alice", "secret");

        Assert.Equal("Alice", result.Username);
        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "wrong"));
    }

    // R-LOGIN-3
    [Fact]
    public async Task SourceAcceptedPasswordReplacesTheCachedPassword()
    {
        var harness = new Harness();
        harness.AddUser("Alice", PeerProviderId, "old");
        harness.Source.Accept("Alice");

        await harness.SignIn("Alice", "new");
        harness.Source.Fail(new HttpRequestException("connection refused"));

        Assert.Equal("Alice", (await harness.SignIn("Alice", "new")).Username);
        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "old"));
    }

    // R-LOGIN-4
    [Theory]
    [MemberData(nameof(Outages))]
    public async Task SourceOutageRefusesUnknownUsers(string outage)
    {
        var harness = new Harness();
        harness.Source.Outage(outage);

        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "secret"));
        Assert.Null(harness.Find("Alice"));
    }

    // R-LOGIN-5
    [Fact]
    public async Task PasswordChangeIsRefused()
    {
        var harness = new Harness();
        var user = harness.AddUser("Alice", PeerProviderId, "secret");

        await Assert.ThrowsAsync<SecurityException>(() => harness.Provider.ChangePassword(user, "new"));
        await Assert.ThrowsAsync<SecurityException>(() => harness.Provider.ChangePassword(user, string.Empty));
        Assert.True(harness.Crypto.Verify(MediaBrowser.Model.Cryptography.PasswordHash.Parse(user.Password!), "secret"));
    }

    // R-LOGIN-6
    [Fact]
    public async Task CreatedUserIsNotAnAdministrator()
    {
        var harness = new Harness();
        harness.Source.Accept("Alice", isAdministrator: true);

        await harness.SignIn("Alice", "secret");

        Assert.False(harness.Find("Alice")!.HasPermission(PermissionKind.IsAdministrator));
    }

    // R-LOGIN-6
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SignInKeepsTheLocalAdministratorFlag(bool isAdministrator)
    {
        var harness = new Harness();
        var user = harness.AddUser("Alice", PeerProviderId, "old");
        user.SetPermission(PermissionKind.IsAdministrator, isAdministrator);
        harness.Source.Accept("Alice", isAdministrator: !isAdministrator);

        await harness.SignIn("Alice", "new");

        Assert.Equal(isAdministrator, user.HasPermission(PermissionKind.IsAdministrator));
    }

    // R-LOGIN-7
    [Theory]
    [InlineData("http://source.example")]
    [InlineData("http://192.0.2.1:8096")]
    [InlineData("ftp://source.example")]
    [InlineData("source.example")]
    [InlineData("")]
    [InlineData(null)]
    public async Task InsecureSourceUrlSendsNoCredentials(string? sourceUrl)
    {
        var harness = new Harness { SourceUrl = sourceUrl };
        harness.AddUser("Alice", PeerProviderId, "secret");
        harness.Source.Accept("Alice");

        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "secret"));
        Assert.Empty(harness.Source.Requests);
    }

    // R-LOGIN-7
    [Fact]
    public void SourceRedirectsAreNotFollowed()
    {
        using var handler = SourceClient.CreateHandler();

        Assert.False(handler.AllowAutoRedirect);
    }

    // R-LOGIN-7
    [Theory]
    [InlineData("https://source.example")]
    [InlineData("http://localhost:8096")]
    [InlineData("http://127.0.0.1:8096")]
    [InlineData("http://[::1]:8096")]
    public async Task SecureOrLoopbackSourceUrlIsUsed(string sourceUrl)
    {
        var harness = new Harness { SourceUrl = sourceUrl };
        harness.Source.Accept("Alice");

        await harness.SignIn("Alice", "secret");

        Assert.StartsWith(sourceUrl, harness.Source.Requests.First().Uri.AbsoluteUri, StringComparison.Ordinal);
    }

    // R-LOGIN-8
    [Fact]
    public async Task SourceSessionIsLoggedOut()
    {
        var harness = new Harness();
        harness.Source.Accept("Alice");

        await harness.SignIn("Alice", "secret");

        var logout = Assert.Single(harness.Source.Logouts);
        Assert.Equal(HttpMethod.Post, logout.Method);
        Assert.Equal("https://source.example/jellyfin/Sessions/Logout", logout.Uri.AbsoluteUri);
        Assert.Contains($"Token=\"{FakeSource.Token}\"", logout.Authorization, StringComparison.Ordinal);
    }

    // R-LOGIN-8
    [Fact]
    public async Task SourceSessionIsLoggedOutWhenTheLocalSignInFails()
    {
        var harness = new Harness();
        harness.AddUser("Alice", Harness.DefaultProviderId, "secret");
        harness.Source.Accept("Alice");

        await Assert.ThrowsAsync<AuthenticationException>(() => harness.Provider.Authenticate("alice2", "secret", null));

        Assert.Single(harness.Source.Logouts);
    }

    // R-LOGIN-1, R-LOGIN-8
    [Fact]
    public async Task UserThatCannotBeSavedIsRemoved()
    {
        // A half-created user would sign in with an empty password through the default provider.
        var harness = new Harness { FailUpdates = true };
        harness.Source.Accept("Alice");

        await Assert.ThrowsAsync<InvalidOperationException>(() => harness.SignIn("Alice", "secret"));

        Assert.Null(harness.Find("Alice"));
        Assert.Single(harness.Source.Logouts);
    }

    [Fact]
    public async Task FailedCleanupKeepsTheOriginalError()
    {
        var harness = new Harness { FailUpdates = true, FailDeletes = true };
        harness.Source.Accept("Alice");

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => harness.SignIn("Alice", "secret"));

        Assert.Equal("database is locked", error.Message);
    }

    // R-LOGIN-9
    [Fact]
    public async Task OtherProviderUserIsRefusedWithoutContactingTheSource()
    {
        var harness = new Harness();
        var user = harness.AddUser("Alice", Harness.DefaultProviderId, "secret");
        harness.Source.Accept("Alice");

        await Assert.ThrowsAsync<AuthenticationException>(() => harness.SignIn("Alice", "secret"));

        Assert.Empty(harness.Source.Requests);
        Assert.Equal(Harness.DefaultProviderId, user.AuthenticationProviderId);
    }

    // R-LOGIN-9
    [Fact]
    public async Task SourceNameMatchingAnOtherProviderUserIsRefused()
    {
        var harness = new Harness();
        var user = harness.AddUser("Admin", Harness.DefaultProviderId, "local");
        harness.Source.Accept("Admin");

        // The typed name resolved no local user, but the source answers with an existing local account's name.
        await Assert.ThrowsAsync<AuthenticationException>(() => harness.Provider.Authenticate("admin-alias", "remote", null));

        Assert.Equal(Harness.DefaultProviderId, user.AuthenticationProviderId);
        Assert.True(harness.Crypto.Verify(MediaBrowser.Model.Cryptography.PasswordHash.Parse(user.Password!), "local"));
        Assert.Empty(harness.Updates);
    }

    public static TheoryData<string> Outages() => [.. FakeSource.Outages];
}
