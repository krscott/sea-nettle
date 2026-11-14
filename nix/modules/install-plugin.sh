#!/usr/bin/env bash
# Usage: install-plugin.sh PLUGIN_DIR PAYLOAD
# Installs a pinned plugin payload while keeping Jellyfin's mutable plugin status.
set -euo pipefail

plugin_dir=$1
payload=$2

install -d -m 0700 "$plugin_dir"
for file in "$payload"/*; do
    if [[ ${file##*/} != meta.json ]]; then
        install -m 0600 "$file" "$plugin_dir/"
    fi
done

# Pin the version (R-SERVER-3) and keep a dashboard Disable (R-SERVER-5).
previous=$plugin_dir/meta.json
if [[ ! -f $previous ]]; then
    previous=$payload/meta.json
fi
jq --slurpfile previous "$previous" \
    '.autoUpdate = false | if $previous[0].status == "Disabled" then .status = "Disabled" end' \
    "$payload/meta.json" >"$plugin_dir/meta.json.tmp"
chmod 0600 "$plugin_dir/meta.json.tmp"
mv "$plugin_dir/meta.json.tmp" "$plugin_dir/meta.json"
