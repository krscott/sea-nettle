# Each server sets up its own side of a pair

A `sea-nettle` run administers only the server it runs on, signed in as that
server's initial administrator, and does only that server's part of the setup
spec. One run that set up both servers would need both initial administrators'
passwords. That would put the source administrator's password on the replica or
on a workstation, and on the replica a compromise would then also expose the
source's administrator. The credentials of its peer that a server does hold are
those of the peer's sync account, whose rights the spec chooses: its password
and the entry key.

## Consequences

- A fresh pair takes four runs: on the source, the replica, the source, and the
  replica again. Each server's peer entry needs the sync account that the other
  server's run creates, so a run reports as findings what needs a run on the
  other server first.
- With an administrator as the source's sync account, a compromised replica
  still has administrator access to the source. That is the spec's choice;
  `setup` never grants administrator rights to make a spec work (R-PAIR-5).
