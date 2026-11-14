# NixOS modules

Import the modules from the flake's `nixosModules`:

| Module | Purpose |
| --- | --- |
| `jellyfin` | Sandboxed Jellyfin on localhost, an optional read-only media directory, and an optional Tailscale Serve HTTPS endpoint |
| `jellyfin-plugins` | Installs Nix-pinned plugin payloads before every start |
| `server-sync` | Pinned [Server Sync](https://github.com/JPKribs/jellyfin-plugin-serversync) release |
| `replica` | A replica: `jellyfin`, `server-sync`, the Peer Login plugin, and seeded link-cache settings |

A source server typically imports `jellyfin` and `server-sync`; a replica
imports `replica`.

```nix
# Source
{
  imports = [ sea-nettle.nixosModules.jellyfin sea-nettle.nixosModules.server-sync ];
  services.tailscale.enable = true;
  sea-nettle.jellyfin = {
    mediaDirectory = "/srv/media";
    servePort = 8445;
  };
}

# Replica
{
  imports = [ sea-nettle.nixosModules.replica ];
  services.tailscale.enable = true;
  sea-nettle.jellyfin = {
    servePort = 8445;
    replica.sourceUrl = "https://source.example.ts.net:8445";
  };
}
```

## Server

Jellyfin runs as `services.jellyfin.user` in an empty read-only filesystem. It
sees the Nix store, basic name-service files, the system CA bundle, its own
writable data, configuration, log and cache directories, and
`sea-nettle.jellyfin.mediaDirectory` read-only. It has no devices, so
hardware transcoding is not supported. If the media directory is absent,
Jellyfin fails to start with a message; mount the media and restart it.

Configuration stays writable. The network configuration is seeded once: HTTP
port 8096 on 127.0.0.1, automatic discovery and **Ignore virtual interfaces**
off. Jellyfin refuses to start unless `network.xml` keeps those values with
IPv4 on and HTTPS off, so a dashboard network change that would expose it stops
the server instead; the journal names the problem. `jellyfin-serve` proxies to
`http://127.0.0.1:8096`. On a server that already has a `network.xml`, edit it
to match, or delete it and run activation to reseed it. The firewall stays
closed to Jellyfin's ports, and setting `services.jellyfin.openFirewall` fails
evaluation.

With `servePort` set, `jellyfin-serve` publishes Jellyfin on that tailnet HTTPS
port. On stop it removes only its own handler. If another handler or Funnel
uses the port, it fails without retrying; reconcile the conflict, then restart
`jellyfin-serve`. Tailnet policy decides who can reach the port; Jellyfin still
requires its own sign-in.

## Plugins

Plugins are keyed by their manifest name, such as `"Server Sync"`. Each start
replaces the files in `${dataDir}/plugins/<name>` with the pinned payload, sets
`autoUpdate` to false, and keeps a dashboard **Disable**. A dashboard uninstall
is undone on the next start, and failed loads are retried. Another version
installed from the dashboard catalog is deleted on the next start. To uninstall
a plugin, remove it from the configuration, rebuild, and then uninstall it in
the dashboard.

Before changing plugin versions, take a Jellyfin backup and check the release's
Jellyfin compatibility. The modules assert the supported Jellyfin version.

## Dashboard setup

### Source

Open the source's HTTPS endpoint and complete the setup wizard. Create the
administrator account and ordinary user accounts. Add the media libraries under
the media directory. Disable saving artwork, NFO files, subtitles, and trickplay
next to the media; Jellyfin cannot write there.

### Replica

1. Open the replica's HTTPS endpoint and complete the setup wizard. Its
   administrator is a local account; keep it separate from source accounts.
2. Create a library at `${dataDir}/replica` (by default
   `/var/lib/jellyfin/replica`).
3. In Server Sync, add the source's HTTPS URL, sign in, and map the source
   library to the replica library with **Storage = Link**. Start with a small
   whitelist. Non-video items in a Link mapping are copied, not linked.
4. On the source, add the replica in Server Sync, pair the entries, allow
   linking, and grant only the peer permissions you need.
5. Check the mappings with Server Sync's connection and link checks, then
   enable content and history sync.
6. Users sign in to the replica with their source credentials (see Peer Login
   below). A new replica user starts with Jellyfin's default policy, which
   includes access to all libraries. After a user's first sign-in, map that
   user in Server Sync so their policy, history, and settings sync, or restrict
   them in the dashboard.

The `replica` module seeds Server Sync with a 50 GiB link cache, 30-day
retention, two episodes ahead, and a 5 MB/s download limit, only when Server
Sync has no configuration yet. The cache limit does not reserve disk space.
**Always Keep** creates permanent copies outside the cache budget; leave it
empty unless you have budgeted the space. Uncached videos need the source; fully
cached videos play during a source outage.

Do not copy databases between servers. To recover a broken peer, check its URL,
mappings, credentials, and pairing in the dashboard.

## Peer Login

Peer Login lets users sign in to the replica with their source credentials.
The `replica` module seeds its source URL from
`sea-nettle.jellyfin.replica.sourceUrl` once; change it later under
**Dashboard > Plugins > Peer Login**. The URL must use HTTPS, except for
loopback addresses; otherwise every Peer Login sign-in is refused.

- **First sign-in:** the replica asks the source. If the source accepts, the
  replica creates the user without administrator rights and caches a hash of
  the password.
- **Wrong or changed password:** if the source refuses, the replica refuses too,
  even if the password matches its cache.
- **Source outage:** a user who signed in before can sign in with the last
  password that the source accepted through the replica. New users cannot sign
  in. Source lockout does not apply to these attempts; set a lockout limit on the
  replica user if needed.
- **Password changes:** the replica refuses them, and clients show a generic
  error. Change the password on the source; the next replica sign-in that
  reaches the source updates the cache.
- **Administrator rights:** never granted or changed by the plugin. Grant them
  on the replica if a user needs them.
- **Existing replica users:** keep their current authentication provider. To
  switch one to source credentials, set **Authentication Provider** to Peer
  Login in the user's dashboard profile. Their current password stays valid
  during outages until their next sign-in that reaches the source.
- **Revoking access:** disabling or deleting a user on the source refuses their
  later sign-ins that reach the source. Their replica sessions and cached
  password stay valid, so disable or delete the replica user as well.
- **Local accounts:** a replica account that uses another provider, such as the
  setup-wizard administrator, never accepts source credentials, even if a
  source user has the same name.

Each sign-in opens a source session and the replica ends it immediately. If the
source becomes unreachable between those two steps, the session stays on the
source until that user's next replica sign-in that reaches it.
