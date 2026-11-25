# sea-nettle requirements

Each requirement captures valuable behaviour or an invariant users rely on,
including latent durability, privacy, compatibility, and recoverability
guarantees. `GLOSSARY.md` defines the terms.

## Format

Write one requirement per bullet, as `- **R-AREA-N** [tag] Statement.` State
observable behaviour, not implementation, in short sentences.

Follow new or substantively changed requirements with a brief, indented
`Rationale:` paragraph. Explain why the guarantee matters, not how to implement
it; name non-obvious constraints when useful. Backfill existing rationales only
when relevant to the task, without a project-wide sweep. If the reason is unknown,
investigate or ask; never invent a rationale.

For new or substantively changed `[manual]` requirements, add a separate
indented `Manual test:` paragraph with concrete steps and expected results.
It says how to verify the behaviour; `Rationale:` says why it matters. Apply
this format when adding or editing requirements in existing projects too;
do not migrate or backfill unrelated requirements.

- The ID is stable. Never renumber or reuse an ID. To drop a requirement, keep
  its bullet, but remove its description and change its tag to `[retired]`.
- `[test]`: a test that the verify recipe (`just verify`) runs covers it. Each
  covering test carries the ID in a comment.
- `[manual]`: no automated test yet. A `Manual test:` paragraph says how an
  agent checks it.
- `[retired]`: no longer required. Kept so the ID stays taken.

## Replica sign-in (LOGIN)

- **R-LOGIN-1** [test] A user whose credentials the source accepts can sign in
  to the replica. The replica creates the account on that user's first sign-in.

  Rationale: Users sign in to the replica with their source credentials instead
  of maintaining a second set of accounts.

- **R-LOGIN-2** [test] The replica refuses a sign-in that the source rejects,
  even when it has an earlier password cached for that user.

  Rationale: The source is the authority for passwords. A password that was
  changed or revoked on the source must stop working for replica sign-ins as
  soon as the source can say so.

- **R-LOGIN-3** [test] While the source is unreachable, a user who signed in to
  the replica before can sign in with the last password that the source accepted
  through the replica.

  Rationale: The replica exists to keep media available near its users,
  including during source or network outages.

- **R-LOGIN-4** [test] While the source is unreachable, the replica refuses
  users who have never signed in to it.

  Rationale: Without the source, the replica cannot verify a password it has
  never seen.

- **R-LOGIN-5** [test] The replica refuses password changes for source-backed
  users.

  Rationale: The source owns the password. A replica-only change would diverge
  from the source and be replaced at the next sign-in that reaches the source.

- **R-LOGIN-6** [test] The login plugin never grants administrator rights.

  Rationale: Administration of the replica stays a deliberate local decision. A
  source administrator account must not control the replica by signing in.

- **R-LOGIN-7** [test] The login plugin sends credentials to the source only
  over HTTPS, except to loopback addresses.

  Rationale: Sign-ins forward plaintext passwords. Only loopback traffic, as in
  tests, stays on the host.

- **R-LOGIN-8** [test] The replica ends each source session that its sign-ins
  open. A session can remain only if the source becomes unreachable during the
  sign-in.

  Rationale: Without cleanup, every replica sign-in leaves a device and an
  access token behind on the source.

- **R-LOGIN-9** [test] The login plugin never signs in to, or takes over, a
  replica account that uses another authentication provider.

  Rationale: The replica's local administrator and other local accounts must not
  become reachable with source credentials, including when a source user has the
  same name.

## Server (SERVER)

- **R-SERVER-1** [test] Jellyfin is reachable only through localhost and the
  configured HTTPS endpoint. The firewall stays closed to Jellyfin's own ports.

  Rationale: Jellyfin's own HTTP port is unencrypted. Exposing it sends
  passwords and session tokens in cleartext and widens the attack surface.

- **R-SERVER-2** [test] Configuration changes made in the dashboard survive
  service restarts and system activation. A network change that would expose
  Jellyfin or move its local HTTP port stops Jellyfin from starting instead.

  Rationale: Administrators configure libraries, plugins, and peer credentials
  in the dashboard. A rebuild must not discard that work, and a silent reset of
  a network change would hide it.

- **R-SERVER-3** [test] Each service start restores every Nix-pinned plugin to
  its pinned version.

  Rationale: Plugins depend on the exact Jellyfin version. An unreviewed plugin
  version can break sign-in or sync.

- **R-SERVER-4** [test] Jellyfin cannot modify the media directory.

  Rationale: The media may be the only copy. Metadata writers or bugs in
  Jellyfin must not alter or delete it.

- **R-SERVER-5** [test] A Nix-pinned plugin disabled in the dashboard stays
  disabled across service restarts.

  Rationale: Administrators must be able to switch off a misbehaving plugin
  without a rebuild.

- **R-SERVER-6** [test] A new server gets the configured administrator account
  and a completed setup wizard before its HTTPS endpoint opens. The password
  comes from a file at runtime and is never written to the Nix store or the
  journal. Once setup is complete, restarts and configuration changes leave the
  account unchanged.

  Rationale: Until setup completes, anyone who can reach Jellyfin can claim its
  administrator account, change libraries, and browse the server's filesystem,
  so the tailnet must never reach an unclaimed server. The administrator then
  manages the account in the dashboard, and a rebuild must not revert those
  changes.

## Setup commands (PAIR)

- **R-PAIR-1** [test] `sea-nettle status` never changes Jellyfin or Server Sync
  configuration.

  Rationale: Operators run it to diagnose a live pair, often while something is
  already wrong. A diagnostic that edits peer entries, mappings, grants, users,
  or libraries could make a problem worse or undo dashboard work. Its link
  checks can renew pairing secrets. That is Server Sync's own repair path, and
  pairing secrets are not configuration.

- **R-PAIR-2** [test] The `sea-nettle` commands read credentials only from
  files. They never write passwords, access tokens, API keys, or pairing secrets
  to their output, logs, command lines, or the Nix store.

  Rationale: Reports get pasted into issues and chats. Command lines are visible
  to every local user. The Nix store is world-readable.

- **R-PAIR-3** [test] The `sea-nettle` commands end every Jellyfin session they
  open for their own calls before they exit. The only session that outlives a
  run is a sync account's token, which `sea-nettle setup` stores as the key of
  a new peer entry.

  Rationale: The commands sign in as an administrator. A token left behind stays
  valid until someone revokes it, and each one shows up as a device in the
  dashboard. A peer entry's key must keep working for the pair to sync.

- **R-PAIR-4** [test] `sea-nettle status` reports each of the following, with
  how to fix it, and exits with a distinct status when it reports any of them:
  - a peer that is unreachable, unpaired, or does not list this server;
  - a peer entry whose server ID is missing or doesn't match the peer;
  - a Peer Login user without a user mapping.

  Rationale: Otherwise these problems are silent. Content, history, and links
  stop flowing, and nothing points at the cause. The exit status lets scripts
  and tests gate on a healthy pair.

- **R-PAIR-5** [test] `sea-nettle setup` checks the whole setup spec before it
  changes anything. It refuses a spec that asks for something its sync accounts
  cannot do, such as syncing other users' watch history through a limited
  source account, and names each problem.

  Rationale: A spec that can never work would leave half-applied configuration
  to clean up by hand. Refusing it keeps a sync account's privileges a
  deliberate choice; setup never grants administrator rights to make a spec
  work.

- **R-PAIR-6** [test] `sea-nettle setup` adds what the spec asks for and
  enables the spec's mappings and the sync features they use. Otherwise it never
  removes, disables, or rewrites existing users, libraries, peer entries, keys,
  mappings, or caller grants. It never changes a user's password or
  administrator rights. When existing configuration contradicts the spec, it
  reports the conflict and how to resolve it, and leaves that configuration
  unchanged. A run with nothing to add or enable changes nothing.

  Rationale: Operators keep tuning a pair in the dashboard after setup. Setup
  must be safe to rerun at any time, including after a partial failure, without
  undoing or fighting that work.

- **R-PAIR-7** [test] `sea-nettle setup` grants peer caller access only to the
  spec's sync accounts. It enables a library or user mapping only after this
  server's link check to the peer passes; until then the mapping stays disabled.

  Rationale: An interrupted or failed run must never leave broader permissions
  than the spec asks for, or let content and history flow before the pair is
  validated.

- **R-PAIR-8** [test] A library that `sea-nettle setup` creates keeps generated
  metadata, artwork, subtitles, lyrics, and trickplay images in Jellyfin's own
  state, never beside the media.

  Rationale: The source media may be the only copy and is read-only to
  Jellyfin (R-SERVER-4). A library set to write beside it would fail those
  writes and lose what it generated.
