# Inline contributor and agent guide

Inline is a native work chat application with a Bun/TypeScript server, Apple clients, and developer integrations.

## Layout

- `apple/`: iOS and macOS clients; `server/`: backend; `landing/`: website and product docs.
- `proto/`: canonical schemas; `packages/`: Inline SDK, MCP server and shared libraries.
- `plugins/`: Codex, OpenClaw, Hermes and Vercel Chat SDK integrations.
- `cli/`, `crates/`, `vendor/`: Rust CLI and its workspace dependencies.
- `skills/inline/`: distributable Inline skill; keep `plugins/codex/skills/inline/` identical.
- `web/` and `mobile/`: inactive drafts.

## Rules

- Never read, write, copy, move or delete environment files. Programs may consume them normally without printing their contents.
- Preserve unrelated local changes. Ask before deleting or discarding existing work.
- Use Bun for JavaScript and TypeScript tooling. Keep package identifiers and release versions independent.
- Never run simulator tooling without explicit approval. macOS checks are permitted.
- Do not deploy, publish packages, change remote refs or access production without explicit authorization.
- Do not change transport behavior as part of repository maintenance.
- Never edit a committed database migration; add a forward migration.
- Keep private planning, operational skills, credentials and user data outside this repository.
- Read any scoped instructions present before changing a subtree. Register project builds in `.running` and staging in `.committing`; record change scope in `.wip`.

## Checks

Run `bun install --frozen-lockfile`, then focused checks for the package you changed.
`bun run check:codex-plugin` checks the marketplace and bundled skill.
`bun run proto:sync-rust` updates the Rust schema copy from `proto/core.proto`.
`bun run build:integrations` builds the JavaScript integration workspaces.
External code contributions are currently closed; maintainers develop the project.
