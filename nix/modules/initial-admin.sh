#!/usr/bin/env bash
# Usage: initial-admin.sh SYSTEM_XML JELLYFIN_URL NAME
# Creates the first Jellyfin administrator, with the password from the systemd credential
# "password", and completes the startup wizard. Does nothing once the wizard is complete, so
# the account stays editable in the dashboard (R-SERVER-6).
set -euo pipefail
# Keeps $status from a request at the end of a pipeline.
shopt -s lastpipe

system_config=$1
url=$2
name=$3
password_file=$CREDENTIALS_DIRECTORY/password
response=$(mktemp)
trap 'rm -f -- "$response"' EXIT

fatal() {
    printf '%s\n' "$*" >&2
    exit 1
}

# Usage: request METHOD PATH [CURL_ARG...]
# Sets $status and $call, and leaves the response body in $response.
request() {
    call="$1 $2"
    status=$(curl -sS -o "$response" -w '%{http_code}' --max-time 30 -X "$1" "${@:3}" "$url$2") ||
        fatal "Cannot reach Jellyfin at $url for $call."
}

# Usage: expect STATUS
expect() {
    if [[ $status != "$1" ]]; then
        fatal "Jellyfin answered $call with HTTP $status instead of $1: $(<"$response")"
    fi
}

# Whether system.xml marks the startup wizard complete. A new server may have no file yet.
wizard_complete() {
    local flag
    [[ -e $system_config ]] || return 1
    if ! flag=$(xmllint --xpath 'string(/ServerConfiguration/IsStartupWizardCompleted)' "$system_config"); then
        echo "Cannot read $system_config; treating the startup wizard as incomplete." >&2
        return 1
    fi
    [[ $flag == true ]]
}

# A claimed server never waits for Jellyfin's startup or depends on its API.
if wizard_complete; then
    echo "system.xml marks the startup wizard complete; leaving users unchanged."
    exit 0
fi

# While Jellyfin starts, a setup server answers 503 to most requests, but claims the wizard is
# incomplete on /System/Info/Public; the full server then answers 503 until its startup
# completes. Wait for an endpoint that only the started server answers.
request GET /Branding/Configuration --retry 150 --retry-delay 2 --retry-connrefused --retry-max-time 300
if [[ $status == 503 ]]; then
    fatal "Jellyfin did not finish starting within 5 minutes. Once it has, start" \
        "jellyfin-serve.service, or jellyfin-initial-admin.service without servePort."
fi
expect 200

# Jellyfin's startup completes the wizard, and saves system.xml, before the request above
# succeeds if an administrator with a password exists.
if wizard_complete; then
    echo "Jellyfin completed the startup wizard while starting; leaving users unchanged."
    exit 0
fi

# Creates the first user if none exists yet.
request GET /Startup/User
expect 200

# The password reaches curl only through a pipe, never through arguments or the environment.
jq -n --arg name "$name" --rawfile password "$password_file" \
    '{Name: $name, Password: ($password | sub("\n+$"; ""))}' |
    request POST /Startup/User -H 'Content-Type: application/json' --data-binary @-
if [[ $status == 403 ]]; then
    fatal "Jellyfin's first user already has a password, but the startup wizard is incomplete:" \
        "an earlier run was interrupted, or someone else claimed this server." \
        "See \"Initial administrator\" in sea-nettle's nix/modules/README.md."
fi
expect 204
echo "Set the password for $name; completing the startup wizard."

request POST /Startup/Complete
expect 204
echo "Created the Jellyfin administrator $name and completed the startup wizard."
