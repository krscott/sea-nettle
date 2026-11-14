# Sandboxed Jellyfin bound to localhost, with an optional Tailscale Serve HTTPS endpoint.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sea-nettle.jellyfin;
  jellyfin = config.services.jellyfin;
  media = cfg.mediaDirectory;
  httpPort = 8096;
  upstream = "http://127.0.0.1:${toString httpPort}";

  initialNetwork = pkgs.writeText "jellyfin-network.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <NetworkConfiguration>
      <InternalHttpPort>${toString httpPort}</InternalHttpPort>
      <EnableIPv4>true</EnableIPv4>
      <EnableIPv6>false</EnableIPv6>
      <LocalNetworkAddresses><string>127.0.0.1</string></LocalNetworkAddresses>
      <AutoDiscovery>false</AutoDiscovery>
      <IgnoreVirtualInterfaces>false</IgnoreVirtualInterfaces>
    </NetworkConfiguration>
  '';

  networkConfig = "${jellyfin.configDir}/network.xml";

  checkNetwork = pkgs.writeShellApplication {
    name = "jellyfin-check-network";
    runtimeInputs = [ pkgs.libxml2 ];
    text = builtins.readFile ./check-network.sh;
  };

  checkMedia = pkgs.writeShellScript "jellyfin-check-media" ''
    if [ ! -d ${lib.escapeShellArg media} ]; then
      echo ${lib.escapeShellArg "Media directory ${media} is absent. Mount it before starting Jellyfin."} >&2
      exit 1
    fi
  '';

  serve =
    action:
    let
      port = toString cfg.servePort;
    in
    pkgs.writeShellScript "jellyfin-serve-${action}" ''
      set -eu
      status=$(${lib.getExe pkgs.tailscale} serve status --json)
      if ! printf '%s' "$status" | ${lib.getExe pkgs.jq} -e --arg port ${port} --arg upstream ${upstream} '
        [.Web // {} | to_entries[] | select(.key | endswith(":" + $port))] as $web |
        ([.AllowFunnel // {} | to_entries[] | select((.key | endswith(":" + $port)) and .value)] | length == 0) and
        ((.TCP[$port] == null and ($web | length) == 0) or
         (.TCP[$port] == {"HTTPS":true} and ($web | length) == 1 and
          $web[0].value.Handlers == {"/":{"Proxy":$upstream}}))
      ' >/dev/null; then
        echo 'Serve port ${port} belongs to another handler or Funnel. Reconcile it before managing Jellyfin.' >&2
        exit 3
      fi
      exec ${lib.getExe pkgs.tailscale} serve --bg --https=${port} ${
        if action == "start" then upstream else "--set-path=/ off"
      }
    '';
in
{
  options.sea-nettle.jellyfin = {
    mediaDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/srv/media";
      description = "Media directory that Jellyfin reads but cannot modify, or null for none.";
    };

    servePort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 8445;
      description = "Tailnet HTTPS port that Tailscale Serve proxies to Jellyfin, or null for no HTTPS endpoint.";
    };
  };

  config = {
    assertions = [
      {
        # R-SERVER-1
        assertion = !jellyfin.openFirewall;
        message = "sea-nettle.jellyfin keeps Jellyfin's own ports closed; reach it through localhost or sea-nettle.jellyfin.servePort.";
      }
      {
        assertion = !jellyfin.hardwareAcceleration.enable;
        message = "sea-nettle.jellyfin hides devices from Jellyfin, so hardware transcoding cannot work; disable services.jellyfin.hardwareAcceleration.";
      }
      {
        assertion = cfg.servePort != null -> config.services.tailscale.enable;
        message = "sea-nettle.jellyfin.servePort needs services.tailscale.enable.";
      }
    ];

    services.jellyfin.enable = true;

    # Seed once; dashboard changes stay writable and survive activation (R-SERVER-1, R-SERVER-2).
    systemd.tmpfiles.settings.jellyfinNetwork.${networkConfig}.C = {
      argument = toString initialNetwork;
      mode = "0600";
      inherit (jellyfin) user group;
    };

    systemd.services.jellyfin = {
      environment = {
        HOME = jellyfin.dataDir;
        XDG_CACHE_HOME = jellyfin.cacheDir;
        # /etc/ssl/certs links through /etc/static, which is outside this sandbox.
        SSL_CERT_FILE = config.security.pki.caBundle;
      };
      unitConfig.RequiresMountsFor = lib.optional (media != null) media;
      serviceConfig = {
        # Existing configuration is never overwritten, so check it (R-SERVER-1).
        ExecStartPre = [
          "${lib.getExe checkNetwork} ${lib.escapeShellArg networkConfig}"
        ]
        ++ lib.optional (media != null) checkMedia;
        # An empty root exposes only the paths below, even when the service user owns other data.
        TemporaryFileSystem = [ "/:ro" ];
        # Mount fresh proc inside a private PID namespace, not host /proc.
        PrivatePIDs = true;
        MountAPIVFS = true;
        BindReadOnlyPaths = [
          "/nix/store"
          "/etc/resolv.conf"
          "/etc/hosts"
          "/etc/nsswitch.conf"
          "/etc/passwd"
          "/etc/group"
          # UTC hosts may have no localtime file; libc defaults to UTC.
          "-/etc/localtime"
        ]
        # R-SERVER-4
        ++ lib.optional (media != null) "-${media}";
        BindPaths = lib.unique [
          jellyfin.dataDir
          jellyfin.configDir
          jellyfin.logDir
          jellyfin.cacheDir
        ];
        ProtectHome = true;
        ProtectSystem = lib.mkForce "strict";
        PrivateDevices = true;
        PrivateIPC = true;
        # The service user may be shared with other services; never remove its IPC objects.
        RemoveIPC = lib.mkForce false;
        ReadWritePaths = lib.unique [
          jellyfin.dataDir
          jellyfin.configDir
          jellyfin.logDir
          jellyfin.cacheDir
        ];
      };
    };

    systemd.services.jellyfin-serve = lib.mkIf (cfg.servePort != null) {
      description = "Jellyfin tailnet HTTPS endpoint";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tailscaled.service"
        "jellyfin.service"
      ];
      requires = [
        "tailscaled.service"
        "jellyfin.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = serve "start";
        ExecStop = serve "stop";
        Restart = "on-failure";
        RestartSec = 5;
        RestartPreventExitStatus = [ 3 ];
      };
    };
  };
}
