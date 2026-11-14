#!/usr/bin/env bash
# Usage: initial-admin.sh JELLYFIN_URL NAME
# Creates the first Jellyfin administrator, with the password from the systemd credential
# "password", and completes the startup wizard. Does nothing once the wizard is complete, so
# the account stays editable in the dashboard (R-SERVER-6).
set -euo pipefail
# Keeps $status from a request at the end of a pipeline.
shopt -s lastpipe

url=$1
name=$2
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

# While Jellyfin starts, a setup server answers 503 to most requests, but claims the wizard is
# incomplete on /System/Info/Public; the full server then answers 503 until its startup
# completes. Wait for an endpoint that only the started server answers.
request GET /Branding/Configuration --retry 150 --retry-delay 2 --retry-connrefused --retry-max-time 300
expect 200
request GET /System/Info/Public
expect 200
completed=$(jq .StartupWizardCompleted "$response") ||
    fatal "Jellyfin answered $call with invalid JSON: $(<"$response")"
case $completed in
true)
    echo "The Jellyfin startup wizard is already complete; leaving users unchanged."
    exit 0
    ;;
false) ;;
*) fatal "Jellyfin answered $call without a StartupWizardCompleted flag: $(<"$response")" ;;
esac

if ! grep -q '[^[:space:]]' "$password_file"; then
    fatal "The initial administrator password file is empty."
fi

# Creates the first user if none exists yet.
request GET /Startup/User
expect 200

echo "Setting the Jellyfin administrator name and password for $name."
# The password reaches curl only through a pipe, never through arguments or the environment.
jq -n --arg name "$name" --rawfile password "$password_file" \
    '{Name: $name, Password: ($password | sub("\n+$"; ""))}' |
    request POST /Startup/User -H 'Content-Type: application/json' --data-binary @-
if [[ $status == 403 ]]; then
    fatal "Jellyfin's first user already has a password, but the startup wizard is incomplete." \
        "If an earlier run of this unit set it (see journalctl -u jellyfin-initial-admin)," \
        "restart jellyfin.service, which then completes the wizard, and start" \
        "jellyfin-initial-admin.service and jellyfin-serve.service again." \
        "Otherwise someone else claimed this server: stop Jellyfin and delete its data directory."
fi
expect 204

request POST /Startup/Complete
expect 204
echo "Created the Jellyfin administrator $name and completed the startup wizard."
