# Instructions for protocol schemas

## Scope

- `proto/core.proto` and the other schemas in `proto/` are the source of truth. `crates/protocol/proto/core.proto` is a copy for standalone Rust builds.

## Changes and checks

- After changing a schema, run `bun run generate:proto` from the repo root for TypeScript and Swift outputs. Use `cd scripts && bun run proto:generate-swift` when only Swift needs regeneration.
- Run `bun run proto:sync-rust` from the root when `core.proto` changes; `bun run public:sync` is an alias for this Rust copy, not a general public artifact sync.
- Review affected generated outputs and consumers. Do not hand-edit generated files or publish packages merely to test a local contract change.
