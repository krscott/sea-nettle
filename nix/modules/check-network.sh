#!/usr/bin/env bash
# Usage: check-network.sh NETWORK_XML
# Refuses to start Jellyfin unless it listens only on 127.0.0.1:8096 (R-SERVER-1).
# Jellyfin binds every interface when its filters leave no address, so loopback must
# survive the IPv4 and virtual-interface filters.
set -euo pipefail

config=$1
query='boolean(/NetworkConfiguration[
    count(LocalNetworkAddresses/string) = 1 and LocalNetworkAddresses/string = "127.0.0.1"
    and InternalHttpPort = 8096 and not(EnableHttps = "true") and AutoDiscovery = "false"
    and EnableIPv4 = "true" and IgnoreVirtualInterfaces = "false"])'

if ! valid=$(xmllint --xpath "$query" "$config") || [[ $valid != true ]]; then
    echo "$config must bind only 127.0.0.1 on HTTP port 8096, with IPv4 on and HTTPS, auto-discovery, and IgnoreVirtualInterfaces off." >&2
    echo "Edit it, or delete it to restore the default on the next system activation." >&2
    exit 1
fi
