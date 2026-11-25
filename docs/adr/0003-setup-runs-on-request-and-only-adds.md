# `setup` runs when an operator asks, and only adds

`sea-nettle setup` runs only when an operator invokes it, never at boot or
activation. A run adds what the setup spec asks for and is missing. Where
existing configuration contradicts the spec, it reports a conflict and leaves
that configuration as it is (R-PAIR-6). Reconciling the servers to the spec on
every boot was rejected: it would make a second ongoing owner of configuration
that the dashboard and Server Sync's own tasks also save.

## Consequences

- Removing a library or a user from the spec removes nothing from either
  server.
- The spec's mappings, and the sync features they use, are what a rerun turns
  back on. To stop syncing a library or a user, the operator removes it from
  the spec before disabling it.
- Server Sync saves its whole configuration without a version check. A run
  applies its changes to the configuration as it is just before each save, but
  a dashboard save at the same moment can still be lost.
