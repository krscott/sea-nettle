# Sandboxed Jellyfin bound to localhost, with an optional Tailscale Serve HTTPS endpoint.
{
  config,
  lib,
  pkgs,
  utils,
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

  initialAdmin = pkgs.writeShellApplication {
    name = "jellyfin-initial-admin";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.libxml2
    ];
    text = builtins.readFile ./initial-admin.sh;
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

    initialAdmin = {
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        example = "admin";
        description = "Name of the administrator that a new server is created with. Changes after the first setup do not rename the administrator; `sea-nettle` signs in with this name, so keep it in step with the dashboard.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.externalPath;
        example = "/run/secrets/jellyfin-admin";
        description = "Runtime file, outside the Nix store, that holds the initial administrator's password. It must exist on every boot. Changes after the first setup do not change the password; `sea-nettle` signs in with this file, so keep it in step with the dashboard.";
      };
    };

    servePort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 8445;
      description = "Tailnet HTTPS port that Tailscale Serve proxies to Jellyfin, or null for no HTTPS endpoint.";
    };

    localUrl = lib.mkOption {
      type = lib.types.str;
      default = upstream;
      readOnly = true;
      internal = true;
      description = "Jellyfin's loopback HTTP URL, for local tools.";
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

    # Seed once: claim a new server before anyone else can (R-SERVER-6).
    systemd.services.jellyfin-initial-admin = {
      description = "Jellyfin initial administrator";
      wantedBy = [ "multi-user.target" ];
      after = [ "jellyfin.service" ];
      requires = [ "jellyfin.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe initialAdmin)
          "${jellyfin.configDir}/system.xml"
          upstream
          cfg.initialAdmin.name
        ];
        LoadCredential = "password:${cfg.initialAdmin.passwordFile}";
        # Reads Jellyfin's configuration, which only its user can read, and changes nothing on disk.
        User = jellyfin.user;
        Group = jellyfin.group;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        # The script bounds its own waits; this is a backstop.
        TimeoutStartSec = "10min";
      };
    };

    systemd.services.jellyfin-serve = lib.mkIf (cfg.servePort != null) {
      description = "Jellyfin tailnet HTTPS endpoint";
      wantedBy = [ "multi-user.target" ];
      # Never publish an unclaimed server (R-SERVER-6). Through `requires`, a Jellyfin restart
      # runs the initial-administrator check again before the endpoint returns.
      after = [
        "tailscaled.service"
        "jellyfin.service"
        "jellyfin-initial-admin.service"
      ];
      requires = [
        "tailscaled.service"
        "jellyfin.service"
        "jellyfin-initial-admin.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = serve "start";
        ExecStop = serve "stop";
        Restart = "on-failure";
        RestartSec = 5;
        # Exit status 3 is a port that another handler or Funnel uses, which no retry fixes.
        RestartPreventExitStatus = [ 3 ];
      };
    };
  };
}
