# Pinned Server Sync release and the `sea-nettle` command.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sea-nettle.jellyfin;
  # The flake's `checks.tool` runs the tests; hosts need not build pyright.
  tool = (pkgs.callPackage ../../tool/package.nix { }).overridePythonAttrs { doCheck = false; };
  version = "12.2.11.4";
  archive = pkgs.fetchurl {
    url = "https://github.com/JPKribs/jellyfin-plugin-serversync/releases/download/v${version}/jellyfin-plugin-serversync-${version}.zip";
    hash = "sha256-u5uP9m2hi+JnLQ9peAPgO/exSqikF/DECpCFpcpS8P0=";
  };
  inherit (lib) mkOption types;

  syncAccount =
    server: peer:
    types.submodule {
      options = {
        name = mkOption {
          type = types.nonEmptyStr;
          example = "${peer}-sync";
          description = "Dedicated account on the ${server} that the other server's Server Sync entry signs in as. Setup on the ${server} creates it.";
        };
        passwordFile = mkOption {
          type = types.externalPath;
          example = "/run/secrets/${server}-sync";
          description = "Runtime file, outside the Nix store, that holds the account's password. Both servers read it: one creates the account, the other signs in to it.";
        };
        administrator = mkOption {
          type = types.bool;
          description = "Whether the account is a Jellyfin administrator. A limited source account carries content and links only, and the source streams every replica user's links as it; syncHistory needs an administrator.";
        };
      };
    };

  server =
    role: peer:
    types.submodule {
      options = {
        url = mkOption {
          type = types.nonEmptyStr;
          example = "https://${role}.example.ts.net:8445";
          description = "The ${role}'s HTTPS URL, as the other server reaches it.";
        };
        syncAccount = mkOption { type = syncAccount role peer; };
      };
    };

  library = types.submodule (
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.nonEmptyStr;
          default = name;
          description = "Library name on both servers.";
        };
        type = mkOption {
          type = types.enum [
            "movies"
            "tvshows"
            "music"
            "musicvideos"
            "homevideos"
            "boxsets"
            "books"
            "mixed"
          ];
          description = "Jellyfin collection type.";
        };
        sourcePath = mkOption {
          type = types.str;
          example = "/srv/media/movies";
          description = "The library's folder on the source, under its media directory.";
        };
        content = mkOption {
          type = types.either (types.enum [ "all" ]) (
            types.submodule {
              options.whitelist = mkOption {
                type = types.nonEmptyListOf types.str;
                example = [ "Big Buck Bunny (2008)" ];
                description = "Top-level items to sync, as paths relative to sourcePath.";
              };
            }
          );
          example = {
            whitelist = [ "Big Buck Bunny (2008)" ];
          };
          description = ''What the replica syncs from the library: "all", or a whitelist.'';
        };
      };
    }
  );

  user = types.submodule {
    options.passwordFile = mkOption {
      type = types.nullOr types.externalPath;
      default = null;
      description = "Runtime file with the password for creating the user on the source, or null to require an existing user. An existing user's password is never changed.";
    };
  };

  setup = cfg.setup;
  # The spec holds paths to password files, never passwords (R-PAIR-2).
  specFile = pkgs.writeText "sea-nettle-setup.json" (
    builtins.toJSON {
      inherit (setup) source replica syncHistory;
      libraries = lib.mapAttrsToList (key: l: l // { inherit key; }) setup.libraries;
      users = lib.mapAttrsToList (name: u: u // { inherit name; }) setup.users;
    }
  );
  setupArgs = lib.optionals (setup != null) (
    [
      "--spec"
      specFile
      "--role"
      cfg.role
    ]
    ++ lib.optionals (cfg.role == "replica") [
      "--replica-root"
      "${config.services.jellyfin.dataDir}/replica"
    ]
  );

  payload =
    pkgs.runCommand "jellyfin-server-sync-${version}" { nativeBuildInputs = [ pkgs.unzip ]; }
      ''
        mkdir -p "$out"
        unzip -q ${archive} -d "$out"
      '';
in
{
  imports = [
    ./jellyfin.nix
    ./jellyfin-plugins.nix
  ];

  options.sea-nettle.jellyfin = {
    role = mkOption {
      type = types.enum [
        "source"
        "replica"
      ];
      default = "source";
      internal = true;
      description = "This server's role in the setup spec; the replica module sets it.";
    };

    setup = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            source = mkOption { type = server "source" "replica"; };
            replica = mkOption { type = server "replica" "source"; };
            libraries = mkOption {
              type = types.attrsOf library;
              default = { };
              description = "Libraries to create on both servers and map as links, by key. The key names the replica's library folder.";
            };
            users = mkOption {
              type = types.attrsOf user;
              default = { };
              description = "Ordinary source users, by name. With an administrator source account, each is mapped to their replica account after their first replica sign-in; the source streams their links only through that mapping.";
            };
            syncHistory = mkOption {
              type = types.bool;
              default = false;
              description = "Sync the mapped users' watch history to the replica. Needs an administrator source account.";
            };
          };
        }
      );
      default = null;
      description = "What `sea-nettle setup` sets up. Use the same value on both servers; each run sets up its own side.";
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.versions.majorMinor config.services.jellyfin.package.version == "12.4";
        message = "The pinned Server Sync plugin requires Jellyfin 12.4; verify compatibility before upgrading.";
      }
      {
        assertion =
          setup == null
          || lib.all (key: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" key != null) (
            lib.attrNames setup.libraries
          );
        message = "sea-nettle.jellyfin.setup.libraries keys may hold only letters, digits, \".\", \"_\" and \"-\".";
      }
      {
        # Jellyfin sees only the media directory.
        assertion =
          setup == null
          || cfg.role != "source"
          || lib.all (
            l: cfg.mediaDirectory != null && lib.hasPrefix "${cfg.mediaDirectory}/" "${l.sourcePath}/"
          ) (lib.attrValues setup.libraries);
        message = "Each sea-nettle.jellyfin.setup.libraries.<key>.sourcePath must lie in sea-nettle.jellyfin.mediaDirectory.";
      }
    ];

    sea-nettle.jellyfin.plugins."Server Sync" = payload;

    # Passes only password file paths; the tool reads the files at runtime (R-PAIR-2).
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "sea-nettle";
        text = ''
          exec ${lib.getExe tool} ${
            lib.escapeShellArgs (
              [
                "--url"
                cfg.localUrl
                "--admin-name"
                cfg.initialAdmin.name
                "--password-file"
                cfg.initialAdmin.passwordFile
                "--server-sync-version"
                version
              ]
              ++ setupArgs
            )
          } "$@"
        '';
      })
    ];
  };
}
