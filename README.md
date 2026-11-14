# sea-nettle

Run a regional replica Jellyfin server next to a source server. Users sign in
to the replica with their source credentials, and
[Server Sync](https://github.com/JPKribs/jellyfin-plugin-serversync) keeps
content, watch history, and settings in step.

The flake provides:

- `packages.<system>.jellyfin-plugin-peer-login`: the Peer Login Jellyfin
  plugin, which authenticates replica users against the source.
- `nixosModules.jellyfin`, `jellyfin-plugins`, `server-sync`, and `replica`.
  See [the module docs](nix/modules/README.md) for setup.

`REQUIREMENTS.md` lists the guarantees, and `DESIGN.md` explains how the
project meets them.

## Development

Enter the development shell with `nix develop`, then run:

```sh
just test         # plugin unit tests with the local .NET SDK
just build        # Nix plugin package (runs the unit tests)
just format       # format tracked files
just check        # fast checks: formatting, lint, nix flake check
just vm-test      # NixOS VM test of a source and a replica (needs KVM)
just verify       # check + vm-test
just update-deps  # regenerate plugin/deps.json after changing NuGet packages
```

Formatting and lint cover tracked files; stage new files with `git add` first.
Install the formatting hook with `just install-hooks`.

Update Nix inputs with `nix flake update`. A Jellyfin version change fails
evaluation until the plugin pins are reviewed.
