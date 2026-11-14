# Evaluates the NixOS modules and checks their options and generated units.
{ nixpkgs, pkgs }:

let
  inherit (nixpkgs) lib;

  eval =
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

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
  assertionsPass = config: failedAssertions config == [ ];
  assertionFails = config: fragment: lib.any (lib.hasInfix fragment) (failedAssertions config);

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
  execStartPre = config: lib.toList (sandbox config).ExecStartPre;
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

    # R-SERVER-1
    "network configuration binds localhost" =
      let
        seeded = (tmpfiles source)."${source.services.jellyfin.configDir}/network.xml".C.argument;
      in
      lib.hasInfix "<LocalNetworkAddresses><string>127.0.0.1</string></LocalNetworkAddresses>" (
        builtins.readFile seeded
      )
      && lib.hasInfix "<AutoDiscovery>false</AutoDiscovery>" (builtins.readFile seeded);

    # R-SERVER-1
    "Serve proxies the HTTPS port to localhost only" =
      let
        serve = source.systemd.services.jellyfin-serve.serviceConfig;
      in
      lib.hasInfix "--https=8445 http://127.0.0.1:8096" (readScript serve.ExecStart)
      && lib.hasInfix "--https=8445 --set-path=/ off" (readScript serve.ExecStop)
      && serve.RestartPreventExitStatus == [ 3 ]
      && !(replica.systemd.services ? jellyfin-serve);

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
        install = lib.concatMapStrings readScript (execStartPre replica);
      in
      lib.hasInfix "/plugins/Server Sync" install
      && lib.hasInfix "/plugins/Peer Login" install
      && lib.hasInfix "jellyfin-server-sync-12.2.11.4" install
      && lib.hasInfix "jellyfin-plugin-peer-login-" install
      && (tmpfiles replica)."${dataDir replica}/plugins".d.user == replica.services.jellyfin.user;

    "plugins are pinned to Jellyfin 12.4" = assertionFails (eval [
      ../modules/replica.nix
      {
        sea-nettle.jellyfin.replica.sourceUrl = "https://source.example.net";
        services.jellyfin.package = pkgs.jellyfin.overrideAttrs {
          version = "12.5.0";
          __intentionallyOverridingVersion = true;
        };
      }
    ]) "requires Jellyfin 12.4";

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
      && lib.hasInfix "Media directory /srv/media is absent" (
        lib.concatMapStrings readScript (execStartPre source)
      );

    "replica has no media directory" =
      !lib.any (lib.hasPrefix "-/srv") (sandbox replica).BindReadOnlyPaths
      && (tmpfiles replica) ? "${dataDir replica}/replica";

    # R-LOGIN-7
    "insecure source URL fails evaluation" =
      assertionFails (eval [
        ../modules/replica.nix
        { sea-nettle.jellyfin.replica.sourceUrl = "http://source.example.net:8096"; }
      ]) "must use HTTPS"
      && assertionsPass (eval [
        ../modules/replica.nix
        { sea-nettle.jellyfin.replica.sourceUrl = "http://127.0.0.1:8096"; }
      ]);

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
