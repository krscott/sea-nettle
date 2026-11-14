#!/usr/bin/env bash
# Usage: check-network.sh NETWORK_XML
# Refuses to start Jellyfin unless it listens only on 127.0.0.1:8096 (R-SERVER-1).
set -euo pipefail

config=$1
query='boolean(/NetworkConfiguration[
    count(LocalNetworkAddresses/string) = 1 and LocalNetworkAddresses/string = "127.0.0.1"
    and InternalHttpPort = 8096 and not(EnableHttps = "true") and AutoDiscovery = "false"])'

if [[ $(xmllint --xpath "$query" "$config" 2>/dev/null) != true ]]; then
    echo "$config must bind only 127.0.0.1 on HTTP port 8096, with HTTPS and auto-discovery off." >&2
    echo "Edit it, or delete it to restore the default on the next system activation." >&2
    exit 1
fi
