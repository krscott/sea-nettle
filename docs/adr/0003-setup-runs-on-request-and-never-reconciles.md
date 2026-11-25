# `setup` runs when an operator asks, and never reconciles

`sea-nettle setup` runs only when an operator invokes it, never at boot or
activation. A run adds what the setup spec asks for and is missing, and turns
on the mappings and sync features that the spec asks to have on. Where other
existing configuration contradicts the spec, it reports a conflict and leaves
that configuration as it is (R-PAIR-6). Reconciling the servers to the spec on
every boot was rejected: it would make a second ongoing owner of the
configuration document that the dashboard and Server Sync's own tasks also
save.

## Consequences

- Removing a library or a user from the spec removes nothing from either
  server.
- A rerun restores what the spec asks for after the operator turned it off or
  removed it in the dashboard: a mapping, its sync features, or a whitelist
  item. To stop syncing something, the operator removes it from the spec first.
