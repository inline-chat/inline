# MCP ChatGPT + Claude MVP Plan (2026-02-20)

## Scope (confirmed)
- Build minimum viable compatibility for ChatGPT Apps and Claude remote MCP.
- Do not implement persisted MCP sessions yet.
- Do not handle multiple MCP servers.
- Remove link dependency in tool payloads; return message content + source chat context.

## Tasks
1. Update MCP tool outputs and schemas
- Remove URL fields from `search`/`fetch` payloads.
- Ensure results include message text snippet and source chat title (or fallback identifier).
- Keep stable message IDs for fetch lookups.
- Status: completed

2. Add ChatGPT Apps metadata hints on tools
- Add `_meta` tool fields used by Apps SDK clients.
- Keep server-side behavior unchanged for non-Apps MCP clients.
- Status: completed

3. Improve MCP auth interoperability
- Include explicit scope hints in `WWW-Authenticate` challenges.
- Expand protected-resource metadata with supported scopes for OAuth-aware clients.
- Status: completed

4. Tests + docs
- Update/extend unit tests for new payload and auth metadata behavior.
- Update `packages/mcp/README.md` to describe current MVP tool payload contract.
- Status: completed

## Exit criteria
- `packages/mcp` tests pass.
- Output contracts reflect no-link requirement.
- OAuth/MCP metadata and challenge responses are explicit enough for Claude/OpenAI clients to negotiate auth.
