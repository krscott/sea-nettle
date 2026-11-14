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
| `nix/modules/` | NixOS modules and their operator docs (`README.md`) |
| `nix/tests/` | Module eval tests, the install-script test, and the VM test |

## Jellyfin version

The project targets Jellyfin 12.4: `net10.0` and `Jellyfin.Controller` 12.4.0
from NuGet. Each module that installs a plugin asserts the Jellyfin major and
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
(R-LOGIN-7). The `replica` module asserts the same rule for its seeded URL.

| Source answer | Result |
| --- | --- |
| 2xx with a user name and token | Accept (below) |
| 401 or 403 | Refuse; never consult the cache (R-LOGIN-2) |
| Connection error, 10 s timeout, or 5xx | Unreachable (below) |
| Anything else, or an unparsable body | Refuse and log an error |

On accept, the provider:

1. Uses the resolved user, or looks the source's canonical username up locally.
   If none exists, it creates the user with that name, sets Peer Login as its
   provider, and clears the administrator permission (R-LOGIN-1, R-LOGIN-6). It
   never changes the administrator permission of an existing user.
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

`UserManager` holds a per-user lock while it calls the provider. Its lock is
reentrant within the async flow, so the provider may call `UpdateUserAsync`.

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
- `SSL_CERT_FILE` points at the system CA bundle, because `/etc/ssl/certs` is
  outside the sandbox.

Network configuration is seeded once with a systemd-tmpfiles `C` rule: HTTP
port 8096 on 127.0.0.1, IPv6 and auto-discovery off. The file stays writable
(R-SERVER-1, R-SERVER-2). Evaluation fails if `services.jellyfin.openFirewall`
is set (R-SERVER-1).

`servePort` (nullable) adds `jellyfin-serve`, which publishes
`http://127.0.0.1:8096` as tailnet HTTPS through Tailscale Serve. It refuses,
with exit status 3 and no restart, to touch a port that another handler or
Funnel uses, and on stop removes only its own handler.

### `jellyfin-plugins`

`plugins` maps a plugin directory name to a payload directory (assemblies and
`meta.json`). Before every start, `install-plugin.sh` copies each payload into
`${dataDir}/plugins/<name>` and rewrites `meta.json` from the payload with
`autoUpdate = false` (R-SERVER-3). It keeps a `Disabled` status (R-SERVER-5);
any other status is reset, so failed loads are retried. A tmpfiles rule creates
the plugins directory, owned by the service user, before Jellyfin can.

Removing a plugin from `plugins` stops managing it but leaves its files; the
operator uninstalls it in the dashboard.

### `server-sync`

Pins a Server Sync release through `jellyfin-plugins`.

### `replica`

Imports `jellyfin` and `server-sync`, and adds:

- the Peer Login package through `jellyfin-plugins`;
- `${dataDir}/replica` for Server Sync link libraries;
- Server Sync link-cache defaults and Peer Login's `sourceUrl`, each seeded
  once as plugin configuration and writable afterwards (R-SERVER-2).

## Tests and CI

| Test | Covers | Runs in |
| --- | --- | --- |
| Plugin unit tests (package check phase) | R-LOGIN-1 to R-LOGIN-9 | `checks.plugin` |
| Module eval tests (`nix/tests/modules.nix`) | R-SERVER-1 to R-SERVER-4, R-LOGIN-7 | `checks.modules` |
| Install-script test (`nix/tests/plugin-install.nix`) | R-SERVER-3, R-SERVER-5 | `checks.plugin-install` |
| VM test (`nix/tests/replica-login.nix`) | R-LOGIN-1 to R-LOGIN-6, R-LOGIN-8, R-LOGIN-9, R-SERVER-1 to R-SERVER-5 | `heavyChecks.replica-login` |

The VM test runs a source and a replica. The source serves HTTPS through nginx
with a test certificate that the replica trusts.

PR CI stays under 5 minutes of wall-clock time, so agents waiting on it keep
their prompt cache. It runs only the fast checks: formatting, lint, and
`nix flake check` (the `checks` output). The VM test lives in
`legacyPackages.<system>.heavyChecks`, which `nix flake check` skips. It runs
locally through `just verify` and in CI on pushes to `main`. If cold builds
exceed the PR budget, add a Nix store cache to CI before cutting checks.
