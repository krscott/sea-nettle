set positional-arguments

default:
    just --list

# Build the Peer Login plugin package; this runs its unit tests.
build:
    nix build -L .#jellyfin-plugin-peer-login

# Run the plugin unit tests with the local .NET SDK.
test:
    dotnet test plugin/Jellyfin.Plugin.PeerLogin.Tests

# Format files, or all tracked files when no files are provided.
format *files:
    @just _format write "$@"

# Check formatting without changing files.
format-check *files:
    @just _format check "$@"

[private]
_format mode *files:
    #!/usr/bin/env bash
    set -euo pipefail

    declare -a files=()
    declare -a cs_files=()
    mode="$1"
    shift

    if (($# == 0)); then
        mapfile -d '' -t files < <(git ls-files -z)
    else
        files=("$@")
    fi

    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            continue
        fi

        case "$file" in
            justfile|Justfile|.justfile|*/justfile|*/Justfile|*/.justfile)
                if [[ "$mode" == check ]]; then
                    just --unstable --fmt --check --justfile "$file"
                else
                    just --unstable --fmt --justfile "$file"
                fi
            ;;
            *.nix)
                if [[ "$mode" == check ]]; then
                    nixfmt --check "$file"
                else
                    nixfmt "$file"
                fi
            ;;
            *.sh|.githooks/*|*/.githooks/*)
                if [[ "$mode" == check ]]; then
                    shfmt -d -i 4 "$file"
                else
                    shfmt -w -i 4 "$file"
                fi
            ;;
            *.cs)
                cs_files+=("$file")
            ;;
        esac
    done

    if ((${#cs_files[@]} > 0)); then
        declare -a verify=()
        if [[ "$mode" == check ]]; then
            verify=(--verify-no-changes)
        fi
        dotnet format whitespace . --folder "${verify[@]}" --include "${cs_files[@]}"
    fi

# Check tracked shell scripts and Git hooks.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        case "$file" in
            *.sh|.githooks/*) shellcheck "$file" ;;
        esac
    done < <(git ls-files -z)

# Run the fast checks that PR CI runs: formatting, lint, Nix eval tests, and plugin unit tests.
check: format-check lint
    nix flake check -L --no-update-lock-file

# Run the heavy NixOS VM test of a source and a replica Jellyfin.
vm-test:
    nix build -L --no-link --no-update-lock-file .#heavyChecks.replica-login

# Run every test that covers a requirement.
verify: check vm-test

# Regenerate the plugin's NuGet lock file after changing package references.
update-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    fetch_deps=$(nix build --no-link --print-out-paths .#jellyfin-plugin-peer-login.fetch-deps)
    "$fetch_deps" plugin/deps.json

# Format staged files for git pre-commit.
pre-commit:
    #!/usr/bin/env bash
    set -euo pipefail

    declare -a staged_files
    declare -a format_files=()
    declare -A partially_staged
    file=''

    mapfile -d '' -t staged_files < <(
        git diff --cached --name-only --diff-filter=ACMR -z
    )

    while IFS= read -r -d '' file; do
        partially_staged["$file"]=1
    done < <(git diff --name-only -z)

    for file in "${staged_files[@]}"; do
        if [[ -v partially_staged["$file"] ]]; then
            continue
        fi

        format_files+=("$file")
    done

    if ((${#format_files[@]} == 0)); then
        exit 0
    fi

    just format "${format_files[@]}"
    git add -- "${format_files[@]}"

# Install a pre-commit hook that formats git-changed files.
install-hooks:
    git config core.hooksPath .githooks
