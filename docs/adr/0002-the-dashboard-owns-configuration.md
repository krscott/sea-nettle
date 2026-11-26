# The dashboard owns configuration; the NixOS modules only seed it

Operators configure libraries, plugins, and peer entries in the dashboard, and
Jellyfin and its plugins save their own configuration files. Writing those
files from Nix on every activation would discard that work. The modules
therefore write configuration only where none exists yet: the network
configuration, a replica's first Server Sync and Peer Login configuration, and
the initial administrator (R-SERVER-2, R-SERVER-6).

Where a later change could break a guarantee, the modules check the
configuration instead of resetting it. Jellyfin does not start while its
network configuration would expose it (R-SERVER-1), because a silent reset
would hide the change from the operator.

## Consequences

- Changing a seeded option, such as `replica.sourceUrl`, after the first start
  does not change the server. The operator changes the value in the dashboard.
- The `initialAdmin` options also tell the `sea-nettle` command whom to sign in
  as, so the operator keeps them in step with a dashboard change to that
  administrator.
- Pinned plugins are the exception: every service start restores their files
  (R-SERVER-3). A plugin that was disabled in the dashboard still stays
  disabled (R-SERVER-5).
