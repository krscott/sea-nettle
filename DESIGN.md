# sea-nettle design

sea-nettle runs a regional replica Jellyfin server next to a source server.
[Server Sync](https://github.com/JPKribs/jellyfin-plugin-serversync) syncs
content, watch history, playlists, and user settings between them. The Peer
Login plugin lets users sign in to the replica with their source credentials.
NixOS modules package the server setup and the plugins.

## Layout

| Path | Contents |
| --- | --- |
| `plugin/Jellyfin.Plugin.PeerLogin/` | Peer Login plugin (C#) |
| `plugin/Jellyfin.Plugin.PeerLogin.Tests/` | Plugin unit tests (xUnit, faked source HTTP and user store) |
| `plugin/package.nix`, `plugin/deps.json` | Nix package and its NuGet lock file |
| `tool/` | `sea-nettle` command (Python) and its unit tests |
| `nix/modules/` | NixOS modules and their operator docs (`README.md`) |
| `nix/tests/` | Module eval tests, script tests, and the VM test |

## Jellyfin version

The project targets Jellyfin 12.4: `net10.0` and `Jellyfin.Controller` 12.4.0
from NuGet. Each module that pins a plugin asserts the Jellyfin major and
minor version, so a Jellyfin upgrade fails evaluation until the plugin pins are
reviewed. Run the VM test on every Jellyfin bump: the authentication provider
interface is unstable, and `UserManager` calls its user reload path a hack to
be removed.

## Peer Login plugin

`PeerAuthenticationProvider` implements Jellyfin's `IAuthenticationProvider`
and `IRequiresResolvedUser`. It is installed only on the replica; the source
needs no changes.

### How Jellyfin calls the provider

`UserManager.AuthenticateUser` resolves the username to a local user first.

- A user with a stored `AuthenticationProviderId` is offered only to that
  provider.
- An unknown username, or a user without a provider, is offered to every
  enabled provider. A provider other than the default may create the user;
  Jellyfin then reloads it by the username the provider returns.
- After a successful sign-in, Jellyfin stores the provider's type name on the
  user. Administrators can change a user's provider in the dashboard.

The provider therefore refuses any resolved user whose provider is not Peer
Login, and refuses when the source returns the name of such a user (R-LOGIN-9).
Existing replica users keep their provider until an administrator switches them.

### Sign-in

The provider posts the username and password to the source's
`/Users/AuthenticateByName`, with a fixed client and device identity
(`Jellyfin Peer Login`). It requires an HTTPS source URL, or HTTP to a loopback
host, and refuses every sign-in without contacting the source otherwise
(R-LOGIN-7). The plugin's HTTP client never follows redirects, so a redirect
cannot carry credentials to another host; it counts as an unexpected answer.
The `replica` module asserts the same URL rule for its seeded URL.

| Source answer | Result |
| --- | --- |
| 2xx with a user name and token | Accept (below) |
| 401 or 403 | Refuse; never consult the cache (R-LOGIN-2) |
| Connection error, 10 s timeout, or 5xx | Unreachable (below) |
| Anything else (including redirects), or an unusable body | Refuse and log an error |

On accept, the provider:

1. Uses the resolved user, or looks the source's canonical username up locally.
   If none exists, it creates the user with that name and Jellyfin's default,
   non-administrator permissions, then sets Peer Login as its provider
   (R-LOGIN-1, R-LOGIN-6). It never changes the permissions of an existing user.
2. Stores a hash of the password in `User.Password` with
   `ICryptoProvider.CreatePasswordHash`, unless the stored hash already matches
   (R-LOGIN-3). This is the built-in provider's format, so an administrator
   can switch the user back to the default provider and keep the password.
3. Calls the source's `/Sessions/Logout` with the returned token, even if a
   local step failed (R-LOGIN-8). A failed logout is logged, not fatal.

When the source is unreachable, a resolved Peer Login user whose stored hash
matches signs in (R-LOGIN-3). Anyone else is refused (R-LOGIN-4). The stored
hash is the last password that the source accepted through the replica, or the
local password the account had before an administrator switched it to Peer
Login.

Jellyfin saves a new user with the default provider and no password before the
provider can set either, and the default provider accepts an empty password for
such a user. The provider hashes the password first, sets both in the next save,
and deletes the user if that save fails; if the delete fails too, it logs a
critical error naming the user. A crash between the two saves, or a concurrent
empty-password sign-in during that one save, could still use the incomplete
account.

`UserManager` holds a per-user lock while it calls the provider; unknown
usernames all share one lock key, so a hanging source delays every first
sign-in by up to the timeout. The lock is reentrant within the async flow, so
the provider may call `UpdateUserAsync`.

### Password changes

`ChangePassword` throws Jellyfin's `MediaBrowser.Controller.Net.SecurityException`,
which the API returns as 403 (`System.Security.SecurityException` becomes 500)
(R-LOGIN-5). This also blocks administrator password resets and the
forgot-password PIN flow for Peer Login users. Jellyfin hides exception
messages outside development mode, so clients show a generic error; the reason
is in the server log.

### Registration and configuration

`ServiceRegistrator` registers the provider as a singleton. The provider
resolves `IUserManager` lazily, because `UserManager` itself depends on every
registered authentication provider.

The plugin configuration has one field, `SourceUrl`, read on every sign-in. A
dashboard page edits it.

### Limits

These are deliberately out of scope for now:

- Server Sync user mappings are not created for new users; map each user in
  Server Sync once.
- Source lockout counts forwarded attempts, but cached-hash checks during an
  outage are limited only by the replica's own lockout policy.
- The source's administrator flag is never mirrored.
- New users get Jellyfin's default policy, including access to all libraries,
  until an administrator restricts them or Server Sync syncs their policy.
- Replica accounts are tied to source accounts by username only. Disabling or
  deleting a source user refuses its later sign-ins that reach the source, but
  existing replica sessions and the cached password stay valid; disable or
  delete the replica user as well.

## Plugin package

`plugin/package.nix` builds the plugin with `buildDotnetModule` and runs the
unit tests in its check phase. NuGet packages are pinned in `plugin/deps.json`.
`Jellyfin.Controller` is referenced with `ExcludeAssets="runtime"`, because
Jellyfin provides those assemblies.

The output is a Jellyfin plugin directory: `Jellyfin.Plugin.PeerLogin.dll` and
a generated `meta.json`. The manifest's GUID and name match `Plugin.Id` and
`Plugin.Name`.

## NixOS modules

All options live under `sea-nettle.jellyfin`. Modules import their
dependencies by path, so importing the same module twice is harmless.

### `jellyfin`

Enables `services.jellyfin` in a sandbox:

- An empty read-only root, with only the Nix store, name-service files, and
  Jellyfin's own data, configuration, log, and cache directories bound in.
  A private PID namespace and its own `/proc`.
- `mediaDirectory` (nullable) is bound read-only (R-SERVER-4). Jellyfin fails
  to start, with a clear message, while it is absent.
- No devices, so evaluation fails if `services.jellyfin.hardwareAcceleration`
  is enabled.
- `SSL_CERT_FILE` points at the system CA bundle, because `/etc/ssl/certs` is
  outside the sandbox.

Network configuration is seeded once with a systemd-tmpfiles `C` rule: HTTP
port 8096 on 127.0.0.1, IPv6, auto-discovery and virtual-interface filtering
off. The file stays writable (R-SERVER-2). Because an existing file is never
overwritten, `check-network.sh` refuses to start Jellyfin unless the file binds
only 127.0.0.1 on port 8096 with HTTPS and auto-discovery off (R-SERVER-1). It
also requires IPv4 on and virtual-interface filtering off: Jellyfin binds every
interface when its filters leave no address. Evaluation fails if
`services.jellyfin.openFirewall` is set (R-SERVER-1).

`servePort` (nullable) adds `jellyfin-serve`, which publishes
`http://127.0.0.1:8096` as tailnet HTTPS through Tailscale Serve. It refuses,
with exit status 3 and no restart, to touch a port that another handler or
Funnel uses, and on stop removes only its own handler.

`initialAdmin` (required) seeds the first administrator (R-SERVER-6). Until
Jellyfin's startup wizard completes, its first-time-setup policy lets any
caller use the startup, library, and environment endpoints. The
`jellyfin-initial-admin` oneshot runs `initial-admin.sh` after Jellyfin
starts, and `jellyfin-serve` requires it. The script exits at once if
`system.xml` says the wizard is complete, so a claimed server never waits for
Jellyfin's startup or depends on its API, including its Base URL. Otherwise it
waits up to 5 minutes for `/Branding/Configuration`, which Jellyfin answers
only after its startup finishes, and reads `system.xml` again: that startup
marks the wizard complete if an administrator with a password exists.
Otherwise it calls
`GET /Startup/User`, which creates the first user, then `POST /Startup/User`
with the name and password, and `POST /Startup/Complete`. It skips the
remote-access step, which would rewrite `network.xml`, and keeps Jellyfin's
default server name and language.

The unit runs as the Jellyfin user, because `system.xml` is private to it,
with a read-only file system. The password arrives through `LoadCredential`
and reaches curl through a pipe. `passwordFile` is typed `externalPath`, so
evaluation rejects store paths and path literals.

`POST /Startup/User` answers 403 when the first user already has a password.
The unit then fails without retrying, because that password may not be the
configured one. At startup, Jellyfin marks the wizard complete if an
administrator with a password exists (`EnsureStartupWizardIntegrity`), so
restarting Jellyfin recovers a run interrupted between the last two calls.
Local processes can still claim a new server in the seconds between Jellyfin's
start and the claim.

Through `Requires`, restarting Jellyfin restarts `jellyfin-initial-admin` and
then `jellyfin-serve`, so the endpoint returns only after the check. A missing
password file fails the unit at credential setup on every boot, which keeps
the endpoint closed.

### `jellyfin-plugins`

`plugins` maps a plugin directory name to a payload directory (assemblies and
`meta.json`), keyed by the plugin's manifest name; the script refuses any other key. Catalog
installs go to `<manifest name>_<version>`, so the cleanup below finds them
only under that key, and the check keeps deletions inside the plugin's own
directory. Before every start, `install-plugin.sh` makes
`${dataDir}/plugins/<name>` hold exactly the payload's files and rewrites
`meta.json` from the payload with `autoUpdate = false` (R-SERVER-3). It also
deletes `<name>_<version>` directories, where a dashboard catalog install would
put another version that Jellyfin would load instead. It keeps a `Disabled`
status (R-SERVER-5); any other status is reset, so failed loads are retried. An
unparsable `meta.json` is replaced with a warning. A tmpfiles rule creates the
plugins directory, owned by the service user, before Jellyfin can. Any failure
stops Jellyfin from starting.

Removing a plugin from `plugins` stops managing it but leaves its files; the
operator uninstalls it in the dashboard.

### `server-sync`

Pins a Server Sync release through `jellyfin-plugins`, and installs a
`sea-nettle` wrapper that passes the command this server's loopback URL, the
`initialAdmin` name and password file path, and the pinned Server Sync version.

### `replica`

Imports `jellyfin` and `server-sync`, and adds:

- the Peer Login package through `jellyfin-plugins`;
- `${dataDir}/replica` for Server Sync link libraries;
- Server Sync link-cache defaults and Peer Login's `sourceUrl`, each seeded
  once as plugin configuration and writable afterwards (R-SERVER-2).

## `sea-nettle` command

`sea-nettle status` checks one server's Server Sync setup. Operators run it on
each host; together, the two runs cover both directions of a pair. It is typed
Python with no dependencies outside the standard library.

It signs in to Jellyfin's loopback URL as the initial administrator, with the
password read from `initialAdmin.passwordFile` (R-PAIR-2), and signs out when
it finishes, even after a failure or on SIGTERM or SIGHUP (R-PAIR-3). If the
sign-out fails, it says how to remove the session and exits 1. It signs in
with a fixed device ID, so a successful sign-in revokes the token of an
earlier run that could not sign out, or of a run still going on the same host;
a 401 at sign-out therefore counts as signed out. Termination signals that
arrive during the sign-out wait for it.
Signing in updates the account's sign-in bookkeeping, as any sign-in does: its
last login date, and its failed-attempt count, which a failed sign-in raises
and a successful one resets. These are not configuration (R-PAIR-1).

Apart from its own session, every call it makes reads, except Server Sync's
link check, `POST /Sync/Hints/CheckPeer`, which it runs for each enabled entry
with a URL and a key (R-PAIR-1). The check calls the peer's `/Sync/Peer/Link`, and the
peer, if its entry for this server is enabled, calls back with a pairing
secret, which this server accepts only while that check is open. So each run
also pairs its direction: the pairing repair that the dashboard's **Check
Link** performs. The secrets live in Server Sync's database, not its
configuration.

Server Sync returns each entry's stored API key, encrypted, with its
configuration. The command's model keeps only whether a key is present. The
link check sends Server Sync's kept-key placeholder with the entry's `Key` and
URL, so Server Sync uses the key it stores for that entry, and only at its
saved URL (R-PAIR-2). Pairing needs that entry `Key`: Server Sync opens the
pairing window only for a saved entry whose URL is unchanged.

The report lists the peers with Server Sync's link check verdict, and what
needs attention, each with a fix (R-PAIR-4). Each rule is a pure function over
what the command read:

| Code | Condition |
| --- | --- |
| `server-sync-missing`, `server-sync-inactive` | No active Server Sync; its configuration is not assessed |
| `server-sync-version` | The loaded version differs from the pin |
| `no-peers` | No peer entries |
| `entry-duplicate-server-id` | Two entries record one server ID; Server Sync matches that peer's calls only to the first |
| `entry-incomplete` | An enabled entry lacks a URL or key |
| `entry-no-server-id` | No recorded server ID; pairing callbacks find entries by it |
| `entry-server-id-mismatch` | The recorded ID differs, ignoring case as Server Sync does, from the one the peer reports |
| `peer-unreachable`, `peer-not-listed`, `peer-unpaired`, `peer-link-warning` | The link check's first problem, in that order; a check with no answer within 5 minutes counts as unreachable |
| `mapping-missing-library`, `mapping-missing-user` | A mapping names a local library or user that no longer exists |
| `user-mapping-skipped` | A standard user's key with mappings for other users, which Server Sync skips |
| `unmapped-user` | A Peer Login user without an enabled user mapping |

Disabled entries are listed but not assessed. The exit status is 0 when
nothing needs attention, 3 when something does, 1 when the command fails, and
2 for usage errors.

Server Sync's caller whitelist matches the address a call comes from.
Jellyfin honours forwarded headers only for configured known proxies, and
`network.xml` configures none, so peer calls through a local proxy such as
Tailscale Serve arrive from 127.0.0.1. Peer grants therefore need no locations.

## Tests and CI

| Test | Covers | Runs in |
| --- | --- | --- |
| Plugin unit tests (package check phase) | R-LOGIN-1 to R-LOGIN-9 | `checks.plugin` |
| `sea-nettle` unit tests and type checks (package check phase) | R-PAIR-2, R-PAIR-4 | `checks.tool` |
| Module eval tests (`nix/tests/modules.nix`) | R-SERVER-1 to R-SERVER-4, R-SERVER-6, R-LOGIN-7, R-PAIR-2 | `checks.modules` |
| Script tests (`nix/tests/scripts.nix`) | R-SERVER-1, R-SERVER-3, R-SERVER-5 | `checks.scripts` |
| VM test (`nix/tests/replica-login.nix`) | R-LOGIN-1 to R-LOGIN-6, R-LOGIN-8, R-LOGIN-9, R-SERVER-1 to R-SERVER-6, R-PAIR-1 to R-PAIR-4 | `heavyChecks.replica-login` |

The VM test runs a source and a replica. Each serves HTTPS through nginx with a
test certificate that the other trusts. Until `sea-nettle` can set up a pair,
the test script configures Server Sync's entries, grants, and mappings through
its API, as the dashboard does. Tailscale Serve needs a
tailnet, so the source's `jellyfin-serve` keeps its dependencies but runs stub
commands.

PR CI stays under 5 minutes of wall-clock time, so agents waiting on it keep
their prompt cache. It runs only the fast checks: formatting, lint, and
`nix flake check` (the `checks` output). The VM test lives in
`legacyPackages.<system>.heavyChecks`, which `nix flake check` skips. It runs
locally through `just verify` and in CI on pushes to `main`. If cold builds
exceed the PR budget, add a Nix store cache to CI before cutting checks.
