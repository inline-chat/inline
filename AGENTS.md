# Agent Notes

## Scope

This repository contains Inline developer tooling and integration packages.

Key paths:

- `proto/` - synced public protobuf contract; do not hand-edit generated release artifacts.
- `packages/protocol/` - synced generated TypeScript protocol package.
- `packages/bot-api-types/` - synced Bot API types package.
- `sdk/` - canonical realtime SDK source.
- `packages/bot-api/` - canonical Bot API client source.
- `packages/oauth-core/` - canonical shared OAuth helpers.
- `mcp/` - canonical MCP package.
- `openclaw/` - canonical OpenClaw plugin.
- `hermes-agent/` - canonical Hermes Agent adapter.
- `cli/` - canonical Inline CLI source.

## Working Rules

- Do not read, write, print, or modify `.env` files.
- Use `bun` for JS/TS package work.
- Keep workspace packages free of undeclared dependencies.
- Do not edit generated protocol or Bot API type output by hand; update it through the normal generated artifact sync.
- Run focused package checks before pushing package changes.
- For small isolated helpers, keep tests beside the implementation.
