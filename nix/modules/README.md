# NixOS modules

Import the modules from the flake's `nixosModules`:

| Module | Purpose |
| --- | --- |
| `jellyfin` | Sandboxed Jellyfin on localhost with its initial administrator, an optional read-only media directory, and an optional Tailscale Serve HTTPS endpoint |
| `jellyfin-plugins` | Installs Nix-pinned plugin payloads before every start |
| `server-sync` | Pinned [Server Sync](https://github.com/JPKribs/jellyfin-plugin-serversync) release and the `sea-nettle` setup and status command |
| `replica` | A replica: `jellyfin`, `server-sync`, the Peer Login plugin, and seeded link-cache settings |

A source server typically imports `jellyfin` and `server-sync`; a replica
imports `replica`.

```nix
# Source
{
  imports = [ sea-nettle.nixosModules.jellyfin sea-nettle.nixosModules.server-sync ];
  services.tailscale.enable = true;
  sea-nettle.jellyfin = {
    initialAdmin = {
      name = "admin";
      passwordFile = "/run/secrets/jellyfin-admin";
    };
    mediaDirectory = "/srv/media";
    servePort = 8445;
  };
}

# Replica
{
  imports = [ sea-nettle.nixosModules.replica ];
  services.tailscale.enable = true;
  sea-nettle.jellyfin = {
    initialAdmin = {
      name = "admin";
      passwordFile = "/run/secrets/jellyfin-admin";
    };
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

## Initial administrator

`sea-nettle.jellyfin.initialAdmin` is required. On a new server,
`jellyfin-initial-admin` creates this administrator and completes Jellyfin's
setup wizard as soon as Jellyfin starts. `jellyfin-serve` starts only after it
succeeds, because until then anyone who reaches Jellyfin can claim it. Local
processes can still reach it in the few seconds between Jellyfin's start and
the claim.

`passwordFile` is a runtime path outside the Nix store, such as a sops-nix or
agenix secret; it can be readable by root only. Trailing newlines in it are
ignored, and Jellyfin refuses an empty password. The password never reaches
the Nix store, command lines, or the journal.

Setup runs once. When the wizard is complete, the unit does nothing, so later
changes to `name` or the password file have no effect; manage the account in
the dashboard. Keep the file in place anyway: the unit loads it on every boot.
Without it, the journal shows
`jellyfin-initial-admin.service: Failed to set up credentials: No such file or directory`,
and `jellyfin-serve` stays down. Restore the file, then run
`systemctl start jellyfin-serve`, or `systemctl start jellyfin-initial-admin`
without `servePort`. Use the same command if the unit reports that Jellyfin
did not finish starting within 5 minutes.

If the unit reports that Jellyfin's first user already has a password, setup
was interrupted or someone else claimed the server first. If
`journalctl -u jellyfin-initial-admin` shows that an earlier run logged
`Set the password for <name>`, that run set it: restart `jellyfin.service`,
which then completes the wizard, and start the units again. Otherwise, even if
an earlier run could not reach Jellyfin, treat the server as claimed by
someone else: stop Jellyfin, delete its data directory
(`/var/lib/jellyfin` by default), run `systemd-tmpfiles --create` to recreate
it with the seeded configuration, and start the units again.

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

## Setting up a pair

`sudo sea-nettle setup` sets up Server Sync between the source and the
replica from `sea-nettle.jellyfin.setup`. Give both servers the same value,
for example from a shared file:

```nix
sea-nettle.jellyfin.setup = {
  source = {
    url = "https://source.example.ts.net:8445";
    # The account the replica signs in to on the source.
    syncAccount = {
      name = "replica-sync";
      passwordFile = "/run/secrets/replica-sync";
      administrator = true;
    };
  };
  replica = {
    url = "https://replica.example.ts.net:8445";
    # The account the source signs in to on the replica.
    syncAccount = {
      name = "source-sync";
      passwordFile = "/run/secrets/source-sync";
      administrator = false;
    };
  };
  libraries.movies = {
    name = "Movies";
    type = "movies";
    sourcePath = "/srv/media/movies";
    # Or: content = "all";
    content.whitelist = [ "Big Buck Bunny (2008)" ];
  };
  # Created on the source when missing; mapped on the replica.
  users = {
    alice = { };
    bob.passwordFile = "/run/secrets/jellyfin-bob";
  };
  syncHistory = true;
};
```

Both servers need both sync account password files: one server creates the
account, the other signs in to it. A user's `passwordFile` is needed only on
the source, to create a missing user.

Each run sets up the server it runs on and reports what waits for the other.
On a fresh pair, run it on the source, the replica, the source, and the
replica again. The runs:

- On the source: create the spec's missing users and libraries, the source's
  sync account, its caller grant, and an entry for the replica (Push, links
  allowed).
- On the replica: create the libraries under `${dataDir}/replica/<key>`, the
  replica's sync account, its caller grant, an entry for the source (Pull),
  and a **Storage = Link** mapping for each library, from its `sourcePath`.
  Mappings start disabled and are enabled, with content sync, once the link
  check passes. A whitelist item is a top-level folder or file under
  `sourcePath`.
- With an administrator source account, each spec user is mapped once they
  have signed in to the replica with their source password (see Peer Login
  below), on the next run. Until then the report lists them under "Waiting",
  which does not make the run exit 3. With `syncHistory`, history sync is
  turned on with the first mapping.

New libraries keep metadata, artwork, subtitles, lyrics, and trickplay in
Jellyfin's state, not beside the media.

**Sync accounts.** The source's sync account decides how links play:

- Limited: content and links only. The source streams every replica user's
  links as that account, so every replica user can play what it can see. Users
  are not mapped, and setup refuses `syncHistory`.
- Administrator: the source streams a link as the replica user's mapped
  source user, with that user's library access and limits. A replica user who
  is not in the spec's users, such as the replica's local administrator, cannot
  play links. Watch history can sync. A compromised replica has administrator
  access to the source.

Setup never changes an existing account's administrator rights or library
access; it reports a mismatch.

**Reruns.** Run setup again at any time. It only adds what is missing and
enables the spec's mappings; it never removes, disables, or rewrites existing
users, passwords, libraries, entries, keys, mappings, or grants. A rerun after
a dashboard change keeps the change. Where the dashboard contradicts the spec,
such as an entry with another URL or a mapping to another library, the report
names the conflict and how to resolve it. To stop syncing a library or user,
remove it from the spec before disabling it, or the next run enables it again.
Don't edit Server Sync in the dashboard while setup runs: its configuration is
saved whole, so a save at the same moment can be lost.

Exit statuses are the same as for `status`, below. An invalid spec exits 1
before anything changes.

### Dashboard settings

Setup leaves these to the dashboard. Non-video items in a Link mapping are
copied, not linked.

- The link cache: the `replica` module seeds a 50 GiB cache, 30-day
  retention, two episodes ahead, and a 5 MB/s download limit, only when Server
  Sync has no configuration yet. The cache limit does not reserve disk space.
  **Always Keep** creates permanent copies outside the cache budget; leave it
  empty unless you have budgeted the space. Uncached videos need the source;
  fully cached videos play during a source outage.
- The source's link limits for the replica: streams at once, per-user limits,
  and speeds.
- User settings and metadata sync.

A new replica user starts with Jellyfin's default policy, which includes access
to all libraries. Restrict them in the dashboard if needed.

Do not copy databases between servers. To recover a broken peer, run
`sea-nettle status` on both servers and follow its fixes.

## Checking a pair

`sudo sea-nettle status` checks this server's Server Sync setup and never
changes configuration. Run it on each server; each run covers one direction.
`sea-nettle setup` ends with the same report. `status` signs in as the initial
administrator with the password in `initialAdmin.passwordFile`, and signs out
before it exits. If the password was changed in the dashboard, update the file
to match: each refused run counts as a failed sign-in, and Jellyfin disables
the account once it reaches the account's lockout limit, if one is set.

It lists each peer with Server Sync's link check verdict, then what needs
attention and how to fix it: unreachable or unpaired peers, peers that do not
list this server, missing or wrong server IDs, mappings to deleted libraries
or users, and Peer Login users without a user mapping. Disabled entries are not
checked. `--json` prints the same report as JSON.

| Exit status | Meaning |
| --- | --- |
| 0 | Nothing needs attention |
| 3 | The report lists something that needs attention |
| 1 | The command failed; the error says why |
| 2 | Usage error |

The link check is the dashboard's **Check Link**. The peer answers it by calling
this server back to pair, so each run also repairs the pairing in its
direction. Pairing secrets live in Server Sync's database, not its
configuration.

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
  initial administrator, never accepts source credentials, even if a
  source user has the same name.

Each sign-in opens a source session and the replica ends it immediately. If the
source becomes unreachable between those two steps, the session stays on the
source until that user's next replica sign-in that reaches it.
