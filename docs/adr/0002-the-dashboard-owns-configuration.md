# The dashboard owns configuration; the NixOS modules only seed it

Operators configure libraries, plugins, and peer entries in the dashboard, and
Jellyfin and its plugins save their own configuration files. Writing those
files from Nix on every activation would discard that work. The modules
therefore write configuration only where none exists yet: the network
configuration, Server Sync's link cache settings, Peer Login's source URL, and
the initial administrator (R-SERVER-2, R-SERVER-6).

Where a later change could break a guarantee, the modules check the
configuration instead of resetting it. Jellyfin does not start while its
network configuration would expose it (R-SERVER-1), because a silent reset
would hide the change from the operator.

## Consequences

- Changing a seeded option, such as `replica.sourceUrl` or `initialAdmin`,
  after the first start has no effect. The operator changes the value in the
  dashboard.
- Pinned plugins are the exception: every service start restores their files
  (R-SERVER-3). A plugin that was disabled in the dashboard still stays
  disabled (R-SERVER-5).
