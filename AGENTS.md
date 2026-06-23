# Agent Notes

## Scope

This repository contains Inline developer tooling and integration packages.

Key paths:

- `proto/` - core protobuf contract
- `packages/protocol/` - generated TypeScript protocol package
- `packages/sdk/` - realtime SDK
- `packages/bot-api-types/` - Bot API types
- `packages/bot-api/` - Bot API client
- `packages/oauth-core/` - shared OAuth helpers
- `packages/mcp/` - MCP package
- `packages/openclaw/` - OpenClaw plugin
- `cli/` - Inline CLI

## Working Rules

- Do not read, write, print, or modify `.env` files.
- Use `bun` for JS/TS package work.
- Keep workspace packages free of undeclared dependencies.
- Run focused package checks before pushing package changes.
- For small isolated helpers, keep tests beside the implementation.
