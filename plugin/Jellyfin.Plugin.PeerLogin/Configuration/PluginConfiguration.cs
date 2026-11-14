using MediaBrowser.Model.Plugins;

namespace Jellyfin.Plugin.PeerLogin.Configuration;

/// <summary>
/// Peer Login settings.
/// </summary>
public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// Gets or sets the base URL of the source Jellyfin server.
    /// </summary>
    public string SourceUrl { get; set; } = string.Empty;
}
