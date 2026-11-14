# Evaluates the NixOS modules and checks their options and generated units.
{ nixpkgs, pkgs }:

let
  inherit (nixpkgs) lib;

  evalBare =
    modules:
    (lib.nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/null";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
        }
      ]
      ++ modules;
    }).config;

  eval =
    modules:
    evalBare (
      [
        {
          sea-nettle.jellyfin.initialAdmin = {
            name = "admin";
            passwordFile = "/run/secrets/jellyfin-admin";
          };
        }
      ]
      ++ modules
    );

  # Whether the unit that creates the initial administrator evaluates.
  initialAdminEvaluates =
    config:
    let
      admin = config.systemd.services.jellyfin-initial-admin.serviceConfig;
    in
    (builtins.tryEval (builtins.seq admin.ExecStart admin.LoadCredential)).success;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
  assertionsPass = config: failedAssertions config == [ ];
  assertionFails = config: fragment: lib.any (lib.hasInfix fragment) (failedAssertions config);
  assertionFailures =
    config: fragment: lib.length (lib.filter (lib.hasInfix fragment) (failedAssertions config));

  source = eval [
    ../modules/jellyfin.nix
    ../modules/server-sync.nix
    {
      sea-nettle.jellyfin = {
        mediaDirectory = "/srv/media";
        servePort = 8445;
      };
      services.tailscale.enable = true;
    }
  ];

  replica = eval [
    ../modules/replica.nix
    { sea-nettle.jellyfin.replica.sourceUrl = "https://source.example.net:8445"; }
  ];

  unit = config: config.systemd.services.jellyfin;
  sandbox = config: (unit config).serviceConfig;
  readScript = path: builtins.readFile path;
  execStartPre = config: map toString (lib.toList (sandbox config).ExecStartPre);
  # Each ExecStartPre command line followed by its script's contents.
  readStartPre =
    config:
    lib.concatMapStrings (command: command + readScript (lib.head (lib.splitString " " command))) (
      execStartPre config
    );
  tmpfiles = config: lib.foldl' (a: b: a // b) { } (lib.attrValues config.systemd.tmpfiles.settings);
  dataDir = config: config.services.jellyfin.dataDir;
  configurations = config: "${dataDir config}/plugins/configurations";

  checks = {
    "source and replica assertions pass" = assertionsPass source && assertionsPass replica;

    # R-SERVER-1
    "Jellyfin's own ports stay closed" =
      lib.all
        (
          config:
          !config.services.jellyfin.openFirewall
          && lib.all (port: !lib.elem port config.networking.firewall.allowedTCPPorts) [
            8096
            8920
            8445
          ]
          && config.networking.firewall.allowedUDPPorts == [ ]
        )
        [
          source
          replica
        ];

    # R-SERVER-1
    "opening the firewall fails evaluation" = assertionFails (eval [
      ../modules/jellyfin.nix
      { services.jellyfin.openFirewall = true; }
    ]) "keeps Jellyfin's own ports closed";

    # R-SERVER-1, R-SERVER-2
    "network configuration binds localhost" =
      let
        seeded = (tmpfiles source)."${source.services.jellyfin.configDir}/network.xml".C.argument;
      in
      lib.hasInfix "<LocalNetworkAddresses><string>127.0.0.1</string></LocalNetworkAddresses>" (
        builtins.readFile seeded
      )
      && lib.hasInfix "<AutoDiscovery>false</AutoDiscovery>" (builtins.readFile seeded)
      &&
        lib.all
          (
            config:
            lib.hasInfix "jellyfin-check-network ${lib.escapeShellArg "${config.services.jellyfin.configDir}/network.xml"}" (
              readStartPre config
            )
          )
          [
            source
            replica
          ];

    "hardware acceleration fails evaluation" = assertionFails (eval [
      ../modules/jellyfin.nix
      {
        services.jellyfin.hardwareAcceleration = {
          enable = true;
          type = "vaapi";
          device = "/dev/dri/renderD128";
        };
      }
    ]) "hardware transcoding cannot work";

    # R-SERVER-1
    "Serve proxies the HTTPS port to localhost only" =
      let
        serve = source.systemd.services.jellyfin-serve.serviceConfig;
      in
      lib.hasInfix "--https=8445 http://127.0.0.1:8096" (readScript serve.ExecStart)
      && lib.hasInfix "--https=8445 --set-path=/ off" (readScript serve.ExecStop)
      && serve.RestartPreventExitStatus == [ 3 ]
      && !(replica.systemd.services ? jellyfin-serve);

    # R-SERVER-6
    "Serve opens only after the initial administrator exists" =
      let
        serve = source.systemd.services.jellyfin-serve;
      in
      lib.elem "jellyfin-initial-admin.service" serve.requires
      && lib.elem "jellyfin-initial-admin.service" serve.after;

    # R-SERVER-6
    "the initial administrator is created after Jellyfin starts" =
      lib.all
        (
          config:
          let
            admin = config.systemd.services.jellyfin-initial-admin;
          in
          lib.elem "multi-user.target" admin.wantedBy
          && lib.elem "jellyfin.service" admin.requires
          && lib.elem "jellyfin.service" admin.after
          && admin.serviceConfig.Type == "oneshot"
          && admin.serviceConfig.RemainAfterExit
          && admin.serviceConfig.User == config.services.jellyfin.user
          && admin.serviceConfig.ProtectSystem == "strict"
        )
        [
          source
          replica
        ];

    # R-SERVER-6
    "the initial administrator is required" =
      initialAdminEvaluates source && !initialAdminEvaluates (evalBare [ ../modules/jellyfin.nix ]);

    # R-SERVER-6
    "the password file is read at runtime, outside the Nix store" =
      source.systemd.services.jellyfin-initial-admin.serviceConfig.LoadCredential
      == "password:/run/secrets/jellyfin-admin"
      && !initialAdminEvaluates (eval [
        ../modules/jellyfin.nix
        { sea-nettle.jellyfin.initialAdmin.passwordFile = lib.mkForce "${pkgs.writeText "pw" "secret"}"; }
      ]);

    # R-PAIR-2
    "sea-nettle gets the password file's path and the pinned Server Sync version" =
      lib.all
        (
          config:
          let
            wrapper = lib.findFirst (p: lib.getName p == "sea-nettle") null config.environment.systemPackages;
            script = readScript (lib.getExe wrapper);
          in
          lib.hasInfix "--url http://127.0.0.1:8096 --admin-name admin" script
          && lib.hasInfix "--password-file /run/secrets/jellyfin-admin" script
          && lib.hasInfix "--server-sync-version 12.2.11.4" script
        )
        [
          source
          replica
        ];

    "Serve without Tailscale fails evaluation" = assertionFails (eval [
      ../modules/jellyfin.nix
      { sea-nettle.jellyfin.servePort = 8445; }
    ]) "needs services.tailscale.enable";

    # R-SERVER-2
    "seeded configuration is copied only when absent" =
      let
        rules = tmpfiles replica;
      in
      lib.all (path: rules.${path} ? C && !(rules.${path} ? "C+")) [
        "${replica.services.jellyfin.configDir}/network.xml"
        "${configurations replica}/Jellyfin.Plugin.ServerSync.xml"
        "${configurations replica}/Jellyfin.Plugin.PeerLogin.xml"
      ];

    # R-SERVER-3
    "pinned plugins install before every start" =
      let
        install = readStartPre replica;
      in
      lib.hasInfix "set -eu\n" install
      && lib.hasInfix "/plugins/Server Sync" install
      && lib.hasInfix "/plugins/Peer Login" install
      && lib.hasInfix "jellyfin-server-sync-12.2.11.4" install
      && lib.hasInfix "jellyfin-plugin-peer-login-" install
      && (tmpfiles replica)."${dataDir replica}/plugins".d.user == replica.services.jellyfin.user;

    # Server Sync and Peer Login each pin the Jellyfin version.
    "plugins are pinned to Jellyfin 12.4" =
      assertionFailures (eval [
        ../modules/replica.nix
        {
          sea-nettle.jellyfin.replica.sourceUrl = "https://source.example.net";
          services.jellyfin.package = pkgs.jellyfin.overrideAttrs {
            version = "12.5.0";
            __intentionallyOverridingVersion = true;
          };
        }
      ]) "requires Jellyfin 12.4" == 2;

    # R-SERVER-4
    "media is mounted read-only" =
      let
        s = sandbox source;
      in
      s.TemporaryFileSystem == [ "/:ro" ]
      && lib.elem "-/srv/media" s.BindReadOnlyPaths
      && !lib.any (lib.hasPrefix "/srv") (s.BindPaths ++ s.ReadWritePaths)
      && s.ProtectSystem == "strict"
      && lib.elem "/srv/media" (unit source).unitConfig.RequiresMountsFor
      && lib.hasInfix "Media directory /srv/media is absent" (readStartPre source);

    "replica has no media directory" =
      !lib.any (lib.hasPrefix "-/srv") (sandbox replica).BindReadOnlyPaths
      && (tmpfiles replica) ? "${dataDir replica}/replica";

    # R-LOGIN-7
    "only HTTPS or loopback source URLs evaluate" =
      let
        accepts =
          url:
          assertionsPass (eval [
            ../modules/replica.nix
            { sea-nettle.jellyfin.replica.sourceUrl = url; }
          ]);
      in
      lib.all accepts [
        "https://source.example.net"
        "HTTPS://Source.example.net:8445/jellyfin"
        "https://[2001:db8::1]:8920"
        "http://localhost:8096"
        "http://LOCALHOST"
        "http://127.0.0.1:8096/"
        "http://[::1]:8096"
      ]
      && !lib.any accepts [
        "http://source.example.net:8096"
        "http://192.0.2.1"
        "https://"
        "https:///path"
        "ftp://source.example.net"
        "source.example.net"
        ""
      ];

    "source URL is seeded into Peer Login" =
      lib.hasInfix "<SourceUrl>https://source.example.net:8445</SourceUrl>"
        (
          builtins.readFile
            (tmpfiles replica)."${configurations replica}/Jellyfin.Plugin.PeerLogin.xml".C.argument
        );
  };

  failures = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
if failures == [ ] then
  pkgs.writeText "module-tests" (lib.concatLines (lib.attrNames checks))
else
  throw "Module checks failed:\n${lib.concatLines failures}"
