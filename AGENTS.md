# Inline contributor and agent guide

Inline is a native work chat application with a Bun/TypeScript server, Apple clients, and developer integrations.

## Layout

- `apple/`: iOS and macOS clients; `server/`: backend; `landing/`: website and product docs.
- `proto/`: canonical schemas; `packages/`: Inline SDK, MCP server and shared libraries.
- `plugins/`: ChatGPT/Codex, OpenClaw, Hermes and Vercel Chat SDK integrations.
- `cli/`, `crates/`, `vendor/`: Rust CLI and its workspace dependencies.
- `skills/inline/`: distributable Inline skill; keep `plugins/chatgpt/skills/inline/` identical.

## Rules

- Never read, write, copy, move or delete environment files. Programs may consume them normally without printing their contents.
- Preserve unrelated local changes. Ask before deleting or discarding existing work.
- Use Bun for JavaScript and TypeScript tooling. Keep package identifiers and release versions independent.
- Never run simulator tooling without explicit approval. macOS checks are permitted.
- Do not deploy, publish packages, change remote refs or access production without explicit authorization.
- Don't edit a committed database migration; add a forward migration.
- Keep private planning, operational skills, credentials and user data outside this repository.
- Use `../secret-sauce` for private skills, guides, product context, and raw collaboration history in `.context/`; follow its `AGENTS.md` and keep labs local in its ignored `experiments/`. In Secret Sauce, automatically commit relevant work after tasks finish and pull/push regularly as needed without asking for approval, preserving teammates' work.
- Register project builds in `.running` and staging in `.committing`; record changed file list in `.wip`. Use those files to coordinate work.
