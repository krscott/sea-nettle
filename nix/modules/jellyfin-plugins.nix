# Installs Nix-pinned plugin payloads into Jellyfin's plugin directory on every start.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  jellyfin = config.services.jellyfin;
  plugins = config.sea-nettle.jellyfin.plugins;
  pluginsDir = "${jellyfin.dataDir}/plugins";

  installPlugin = pkgs.writeShellApplication {
    name = "jellyfin-install-plugin";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.jq
    ];
    text = builtins.readFile ./install-plugin.sh;
  };

  installAll = pkgs.writeShellScript "jellyfin-install-plugins" (
    lib.concatLines (
      [ "set -eu" ]
      ++ lib.mapAttrsToList (
        name: payload:
        "${lib.getExe installPlugin} ${
          lib.escapeShellArgs [
            "${pluginsDir}/${name}"
            "${payload}"
          ]
        }"
      ) plugins
    )
  );
in
{
  options.sea-nettle.jellyfin.plugins = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    default = { };
    description = ''
      Pinned plugin payloads, keyed by the plugin's manifest name. Each payload
      is a directory with the plugin assemblies and its `meta.json`.
    '';
  };

  config = lib.mkIf (plugins != { }) {
    # tmpfiles must not synthesize a root-owned parent on a fresh server.
    systemd.tmpfiles.settings.jellyfinPlugins.${pluginsDir}.d = {
      mode = "0700";
      inherit (jellyfin) user group;
    };

    systemd.services.jellyfin.serviceConfig.ExecStartPre = [ installAll ];
  };
}
