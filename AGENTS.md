# Agent notes

## Requirements, glossary and decisions

- `REQUIREMENTS.md` lists the observable behaviours and invariants sea-nettle
  must keep, by stable ID.
- `GLOSSARY.md` defines the domain terms. It is the naming authority for code,
  commands, messages and docs: use its terms, and do not use a word listed
  under _Avoid_ for that term's concept. When a concept has no term, or a term
  no longer fits, change the glossary in the same PR. Keep implementation
  detail out of it. Names fixed by an outside contract keep their spelling:
  the `--json` report's keys and finding codes, Server Sync's field names, and
  dashboard paths.
  Existing code, messages and requirement wording still use some avoided
  words; issue #11 renames them. Use the glossary's terms in new work.
  TODO: remove these two sentences once #11 is closed.
- `docs/adr/` records decisions that are hard to reverse, surprising without
  context, and the result of a real trade-off. Read the ADRs for an area before
  changing it, and add one only when all three hold.
- A reason that explains one piece of code belongs in a comment at that code.

## Change order

- Work flows from `REQUIREMENTS.md` to code and tests. Start at the highest layer the change affects; most PRs change only code.
- For a bug fix, check whether a requirement was missing or violated. Add one when it captures a valuable durable guarantee; an implementation defect does not automatically create a new product promise.
- Never renumber, reuse or delete a requirement ID; instead, tag it `[retired]` and leave its description blank. Tests covering a `[test]` requirement carry its ID in a comment.

## Verification

- `just check` runs the fast checks that PR CI runs. `just verify` adds the
  heavy VM test; run it before merging changes to the modules, the plugin's
  Jellyfin integration, or the Jellyfin version. Jellyfin's authentication
  provider interface is unstable.
- PR CI must stay under 5 minutes of wall-clock time, so that agents waiting
  on it keep their prompt cache. Keep heavy tests out of the flake's `checks`
  output; add them under `legacyPackages.<system>.heavyChecks`. If cold builds
  exceed the budget, add a Nix store cache to CI before cutting checks.
- After changing NuGet package references, run `just update-deps` and commit
  `plugin/deps.json`.
- The Jellyfin version is pinned in three places that must agree: the
  `Jellyfin.Controller` version in both `.csproj` files, `targetAbi` in
  `plugin/package.nix`, and the version assertions in `nix/modules/`.
