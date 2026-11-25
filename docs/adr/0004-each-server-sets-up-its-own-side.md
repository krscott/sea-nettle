# Each server sets up its own side of a pair

A `sea-nettle` run signs in as an administrator only to the server it runs on,
and does only that server's part of the setup spec. One run that set up both
servers would need both administrators' passwords. That would put the source
administrator's password on the replica or on a workstation, so a compromised
replica would also expose the source's administrator. The only credential of
its peer that a server holds is the password of the peer's sync account, whose
rights the spec chooses.

## Consequences

- A fresh pair takes four runs: on the source, the replica, the source, and the
  replica again. Each server's peer entry needs the sync account that the other
  server's run creates, and each run reports what waits for the other server.
- `sea-nettle status` on one server checks one direction of the pair. The
  operator runs it on both.
- With an administrator as the source's sync account, a compromised replica
  still has administrator access to the source. That is the spec's choice;
  `setup` never grants administrator rights to make a spec work (R-PAIR-5).
