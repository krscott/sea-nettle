using MediaBrowser.Controller;
using MediaBrowser.Controller.Authentication;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.Plugins;
using MediaBrowser.Model.Cryptography;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.PeerLogin;

/// <summary>
/// Registers the Peer Login authentication provider.
/// </summary>
public class ServiceRegistrator : IPluginServiceRegistrator
{
    /// <inheritdoc />
    public void RegisterServices(IServiceCollection serviceCollection, IServerApplicationHost applicationHost)
    {
        serviceCollection.AddSingleton<IAuthenticationProvider>(services => new PeerAuthenticationProvider(
            () => Plugin.Instance?.Configuration.SourceUrl,
            // The user manager depends on all authentication providers, so resolve it lazily.
            () => services.GetRequiredService<IUserManager>(),
            services.GetRequiredService<ICryptoProvider>(),
            services.GetRequiredService<ILogger<PeerAuthenticationProvider>>()));
    }
}
