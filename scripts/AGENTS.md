# Instructions for scripts

## Scope

- `scripts/` contains build, protocol generation, release, and repository helpers. Prefer existing scripts to one-off shell commands.
- Use `bun run typecheck`, `bun run lint`, or `bun run test` from `scripts/` when relevant; check `package.json` for each entry point.

## Release work

- Never print secrets, tokens, OTPs, or environment-file values. Release scripts use authenticated tools and may publish artifacts; run them only with authorization for the exact release.
- CLI release: `cd scripts && bun run release:cli`. macOS direct release: `cd scripts && bun run macos:release-app -- --channel <stable|beta|tip>`.
