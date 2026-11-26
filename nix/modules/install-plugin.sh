#!/usr/bin/env bash
# Usage: install-plugin.sh PLUGIN_DIR PAYLOAD
# Makes PLUGIN_DIR hold exactly the pinned payload, keeping Jellyfin's mutable plugin status.
set -euo pipefail

plugin_dir=$1
payload=$2

# Catalog installs go to "<manifest name>_<version>", so the cleanup below finds them only if
# the directory carries the manifest name; the check also keeps deletions inside this plugin.
name=$(jq -r .name "$payload/meta.json")
if [[ ${plugin_dir##*/} != "$name" ]]; then
    echo "Plugin directory '${plugin_dir##*/}' must match the plugin's manifest name '$name'." >&2
    exit 1
fi

# A dashboard catalog install of another version goes to "<name>_<version>", and Jellyfin
# would load it instead of the pin (R-SERVER-3).
rm -rf -- "$plugin_dir"_[0-9]*

install -d -m 0700 "$plugin_dir"
find "$plugin_dir" -mindepth 1 -maxdepth 1 ! -name meta.json -exec rm -rf -- {} +
for file in "$payload"/*; do
    if [[ ${file##*/} != meta.json ]]; then
        cp -R --no-preserve=mode -- "$file" "$plugin_dir/"
    fi
done

# Pin the version (R-SERVER-3) and keep a dashboard Disable (R-SERVER-5). Any other status is
# reset, so Jellyfin retries a plugin that failed to load.
previous=$plugin_dir/meta.json
if [[ ! -f $previous ]]; then
    previous=$payload/meta.json
elif ! jq -e . "$previous" >/dev/null 2>&1; then
    echo "$previous is not valid JSON; replacing it, which re-enables the plugin if it was disabled." >&2
    previous=$payload/meta.json
fi
jq --slurpfile previous "$previous" \
    '.autoUpdate = false | if $previous[0].status == "Disabled" then .status = "Disabled" end' \
    "$payload/meta.json" >"$plugin_dir/meta.json.tmp"
chmod 0600 "$plugin_dir/meta.json.tmp"
mv "$plugin_dir/meta.json.tmp" "$plugin_dir/meta.json"
