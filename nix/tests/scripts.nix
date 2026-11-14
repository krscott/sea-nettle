# Runs the module helper scripts against scratch directories.
{ pkgs }:

let
  payload =
    version:
    pkgs.runCommand "example-plugin-${version}" { } ''
      mkdir -p "$out/lib"
      echo ${version} >"$out/Example.dll"
      echo ${version} >"$out/lib/Helper.dll"
      cat >"$out/meta.json" <<'EOF'
      ${builtins.toJSON {
        name = "Example";
        inherit version;
        status = "Active";
        autoUpdate = true;
        assemblies = [ "Example.dll" ];
      }}
      EOF
    '';

  network =
    fields:
    pkgs.writeText "network.xml" ''
      <?xml version="1.0" encoding="utf-8"?>
      <NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        ${fields}
      </NetworkConfiguration>
    '';
  localhost = "<LocalNetworkAddresses><string>127.0.0.1</string></LocalNetworkAddresses>";
  port = "<InternalHttpPort>8096</InternalHttpPort>";
  off = "<EnableHttps>false</EnableHttps><AutoDiscovery>false</AutoDiscovery>";
in
pkgs.runCommand "script-tests"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.jq
      pkgs.libxml2
    ];
  }
  ''
    set -euo pipefail
    install_plugin() { bash ${../modules/install-plugin.sh} "$@"; }
    check_network() { bash ${../modules/check-network.sh} "$@"; }
    dir="$TMPDIR/plugins/Example Plugin"
    meta="$dir/meta.json"

    # R-SERVER-3: a fresh install and a later start both restore the pinned files.
    install_plugin "$dir" ${payload "1.0.0.0"}
    jq -e '.version == "1.0.0.0" and .status == "Active" and .autoUpdate == false' "$meta"
    grep -qx 1.0.0.0 "$dir/Example.dll"
    grep -qx 1.0.0.0 "$dir/lib/Helper.dll"
    jq '.version = "2.0.0.0" | .autoUpdate = true' "$meta" >"$meta.new"
    mv "$meta.new" "$meta"
    echo tampered >"$dir/Example.dll"
    echo stale >"$dir/Stale.dll"
    mkdir "''${dir}_2.0.0.0"
    install_plugin "$dir" ${payload "1.0.0.0"}
    jq -e '.version == "1.0.0.0" and .autoUpdate == false' "$meta"
    grep -qx 1.0.0.0 "$dir/Example.dll"
    test ! -e "$dir/Stale.dll"
    test ! -e "''${dir}_2.0.0.0"

    # R-SERVER-5: a dashboard Disable survives restarts and version bumps.
    jq '.status = "Disabled"' "$meta" >"$meta.new"
    mv "$meta.new" "$meta"
    install_plugin "$dir" ${payload "1.0.0.0"}
    jq -e '.status == "Disabled"' "$meta"
    install_plugin "$dir" ${payload "1.1.0.0"}
    jq -e '.version == "1.1.0.0" and .status == "Disabled"' "$meta"
    grep -qx 1.1.0.0 "$dir/Example.dll"

    # Other statuses, such as a failed load, are retried as Active.
    jq '.status = "Malfunctioned"' "$meta" >"$meta.new"
    mv "$meta.new" "$meta"
    install_plugin "$dir" ${payload "1.1.0.0"}
    jq -e '.status == "Active"' "$meta"

    # A truncated manifest is replaced instead of blocking startup.
    printf '{"status": "Dis' >"$meta"
    install_plugin "$dir" ${payload "1.1.0.0"} 2>/dev/null
    jq -e '.version == "1.1.0.0" and .status == "Active"' "$meta"

    # R-SERVER-1: only a localhost-bound configuration starts.
    check_network ${network "${localhost}${port}${off}"}
    for bad in \
      ${network "${localhost}${port}"} \
      ${network "<LocalNetworkAddresses />${port}${off}"} \
      ${network "<LocalNetworkAddresses><string>0.0.0.0</string></LocalNetworkAddresses>${port}${off}"} \
      ${network "<LocalNetworkAddresses><string>127.0.0.1</string><string>192.0.2.1</string></LocalNetworkAddresses>${port}${off}"} \
      ${network "${localhost}<InternalHttpPort>8097</InternalHttpPort>${off}"} \
      ${network "${localhost}${port}<EnableHttps>true</EnableHttps><AutoDiscovery>false</AutoDiscovery>"} \
      ${network "${localhost}${port}<EnableHttps>false</EnableHttps><AutoDiscovery>true</AutoDiscovery>"} \
      "$TMPDIR/missing.xml"; do
      if check_network "$bad" 2>/dev/null; then
        echo "accepted $bad" >&2
        exit 1
      fi
    done

    touch "$out"
  ''
