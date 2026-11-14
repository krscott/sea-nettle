# sea-nettle requirements

Each requirement captures valuable behaviour or an invariant users rely on,
including latent durability, privacy, compatibility, and recoverability
guarantees. `DESIGN.md` describes how the requirements are met.

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
  changed or revoked on the source must stop working on the replica as soon as
  the source can say so.

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
  service restarts and system activation.

  Rationale: Administrators configure libraries, plugins, and peer credentials
  in the dashboard. A rebuild must not discard that work.

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
