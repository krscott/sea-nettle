# Runs the plugin install script against a scratch plugin directory.
{ pkgs }:

let
  payload =
    version:
    pkgs.writeTextDir "meta.json" (
      builtins.toJSON {
        name = "Example";
        inherit version;
        status = "Active";
        autoUpdate = true;
        assemblies = [ "Example.dll" ];
      }
    );
in
pkgs.runCommand "plugin-install-test"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail
    install_plugin() { bash ${../modules/install-plugin.sh} "$@"; }
    dir="$TMPDIR/plugins/Example Plugin"
    meta="$dir/meta.json"

    # R-SERVER-3: a fresh install and a later start both restore the pinned version.
    install_plugin "$dir" ${payload "1.0.0.0"}
    jq -e '.version == "1.0.0.0" and .status == "Active" and .autoUpdate == false' "$meta"
    jq '.version = "2.0.0.0" | .autoUpdate = true' "$meta" >"$meta.new"
    mv "$meta.new" "$meta"
    install_plugin "$dir" ${payload "1.0.0.0"}
    jq -e '.version == "1.0.0.0" and .autoUpdate == false' "$meta"

    # R-SERVER-5: a dashboard Disable survives restarts and version bumps.
    jq '.status = "Disabled"' "$meta" >"$meta.new"
    mv "$meta.new" "$meta"
    install_plugin "$dir" ${payload "1.0.0.0"}
    jq -e '.status == "Disabled"' "$meta"
    install_plugin "$dir" ${payload "1.1.0.0"}
    jq -e '.version == "1.1.0.0" and .status == "Disabled"' "$meta"

    # Other statuses, such as a failed load, are retried as Active.
    jq '.status = "Malfunctioned"' "$meta" >"$meta.new"
    mv "$meta.new" "$meta"
    install_plugin "$dir" ${payload "1.1.0.0"}
    jq -e '.status == "Active"' "$meta"

    touch "$out"
  ''
