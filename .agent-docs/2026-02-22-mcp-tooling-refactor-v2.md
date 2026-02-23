# MCP Tooling Refactor v2 (2026-02-22)

## Goal
Refactor MCP tool surface and retrieval pipeline so common workflows (especially DM-targeted lookups like "last message I sent to Dena") are deterministic, efficient, and low-call.

## Problems in v1
- Tool surface is too narrow (`search`, `fetch`, `messages.send`), forcing model guesswork.
- Chat/message retrieval is inefficient: cross-chat search loops over many chats and performs per-chat network calls.
- Chat resolution is title-heavy and can pick wrong targets (e.g. DM vs thread with similar name).
- Responses lack enough structured metadata for robust model planning.

## Plan
1. Add a typed chat model in MCP inline API:
   - classify chats (`dm`, `space_thread`, `home_thread`)
   - expose DM counterpart identity when available
   - cache `getChats` snapshot per MCP session with short TTL
2. Add deterministic chat resolution:
   - new `chats.resolve` API that scores candidates by identity + title with explicit tie/disambiguation fields
3. Add message listing API:
   - new `messages.list` API with sender filter (`me`, `others`, `any`) and `limit`
4. Add MCP v2 tools while preserving compatibility:
   - `chats.list`, `chats.resolve`, `messages.list`, `messages.search`, `messages.get`, existing `messages.send`
   - keep `search` and `fetch` as compatibility wrappers
5. Improve docs/contracts:
   - update package README and web docs for v2 usage patterns
6. Tests:
   - add tests for new tool behavior
   - ensure v1 wrappers still work

## Constraints
- Keep OAuth/session behavior unchanged.
- Keep strict consent boundary enforcement for spaces/DMs/home threads.
- No breaking removal of current v1 tools in this pass.
