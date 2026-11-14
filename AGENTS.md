# Agent notes

## Change order

- Work flows from `REQUIREMENTS.md` to `DESIGN.md` to code and tests. Start at the highest layer the change affects; most PRs change only design and code, or only code.
- For a bug fix, check whether a requirement was missing or violated. Add one when it captures a valuable durable guarantee; an implementation defect does not automatically create a new product promise.
- Any diff to `REQUIREMENTS.md` (addition, edit or retirement) needs explicit approval from a human reviewer. List every requirement ID, added, changed, or retired, near the top of the PR description. Don't merge until a human reviewer approves them.
- Never renumber, reuse or delete a requirement ID; instead, tag it `[retired]` and leave its description blank. Tests covering a `[test]` requirement carry its ID in a comment.

## Verification

- `just check` runs the fast checks that PR CI runs. `just verify` adds the
  heavy VM test; run it before merging changes to the modules, the plugin's
  Jellyfin integration, or the Jellyfin version.
- PR CI must stay under 5 minutes of wall-clock time. Keep heavy tests out of
  the flake's `checks` output; add them under `legacyPackages.<system>.heavyChecks`.
- After changing NuGet package references, run `just update-deps` and commit
  `plugin/deps.json`.
- The Jellyfin version is pinned in three places that must agree: the
  `Jellyfin.Controller` version in both `.csproj` files, `targetAbi` in
  `plugin/package.nix`, and the version assertions in `nix/modules/`.
