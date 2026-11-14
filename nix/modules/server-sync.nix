# Pinned Server Sync release.
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

  assertions = [
    {
      assertion = lib.versions.majorMinor config.services.jellyfin.package.version == "12.4";
      message = "The pinned Server Sync plugin requires Jellyfin 12.4; verify compatibility before upgrading.";
    }
  ];

  sea-nettle.jellyfin.plugins."Server Sync" = payload;

  # Passes only the password file's path; the tool reads the file at runtime (R-PAIR-2).
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "sea-nettle";
      text = ''
        exec ${lib.getExe tool} ${
          lib.escapeShellArgs [
            "--url"
            cfg.localUrl
            "--admin-name"
            cfg.initialAdmin.name
            "--password-file"
            cfg.initialAdmin.passwordFile
            "--server-sync-version"
            version
          ]
        } "$@"
      '';
    })
  ];
}
