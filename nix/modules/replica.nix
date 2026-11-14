# Regional replica: Server Sync link cache plus Peer Login against the source server.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sea-nettle.jellyfin.replica;
  jellyfin = config.services.jellyfin;
  configurations = "${jellyfin.dataDir}/plugins/configurations";

  serverSyncConfig = pkgs.writeText "server-sync.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <PluginConfiguration>
      <!-- An empty whitelist prevents legacy automatic peer grants. -->
      <PeerCallerGrants />
      <LinkCacheSizeGb>50</LinkCacheSizeGb>
      <LinkCacheRetentionDays>30</LinkCacheRetentionDays>
      <LinkCachePreCacheEpisodes>2</LinkCachePreCacheEpisodes>
      <MaxDownloadSpeed>5</MaxDownloadSpeed>
      <DownloadSpeedUnit>MB</DownloadSpeedUnit>
    </PluginConfiguration>
  '';

  peerLoginConfig = pkgs.writeText "peer-login.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <PluginConfiguration>
      <SourceUrl>${lib.escapeXML cfg.sourceUrl}</SourceUrl>
    </PluginConfiguration>
  '';

  # Seed once; dashboard changes stay writable and survive activation (R-SERVER-2).
  seed = argument: {
    C = {
      argument = toString argument;
      mode = "0600";
      inherit (jellyfin) user group;
    };
  };
  directory = {
    d = {
      mode = "0700";
      inherit (jellyfin) user group;
    };
  };
in
{
  imports = [
    ./jellyfin.nix
    ./jellyfin-plugins.nix
    ./server-sync.nix
  ];

  options.sea-nettle.jellyfin.replica.sourceUrl = lib.mkOption {
    type = lib.types.str;
    example = "https://source.example.net:8445";
    description = ''
      Source server URL for Peer Login. It is written only when the plugin has
      no configuration yet; later changes belong in the dashboard.
    '';
  };

  config = {
    assertions = [
      {
        assertion = lib.versions.majorMinor jellyfin.package.version == "12.4";
        message = "The Peer Login plugin requires Jellyfin 12.4; verify compatibility before upgrading.";
      }
      {
        # R-LOGIN-7
        # Mirrors SourceClient.ParseSourceUrl.
        assertion =
          builtins.match "(https://([^/:]+|\\[[0-9a-f:.]+])|http://(localhost|127\\.[0-9.]+|\\[::1]))(:[0-9]+)?(/.*)?" (
            lib.toLower cfg.sourceUrl
          ) != null;
        message = "sea-nettle.jellyfin.replica.sourceUrl must use HTTPS unless it is a loopback address.";
      }
    ];

    sea-nettle.jellyfin.plugins."Peer Login" = pkgs.callPackage ../../plugin/package.nix { };

    systemd.tmpfiles.settings.jellyfinReplica = {
      # Server Sync links live in Jellyfin's writable state.
      "${jellyfin.dataDir}/replica" = directory;
      ${configurations} = directory;
      "${configurations}/Jellyfin.Plugin.ServerSync.xml" = seed serverSyncConfig;
      "${configurations}/Jellyfin.Plugin.PeerLogin.xml" = seed peerLoginConfig;
    };
  };
}
