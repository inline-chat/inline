# Bots + SDK + "Inline Updates" Thread (Spec + Research) (2026-02-07)

From notes (Feb 3-7, 2026): "bots spec so Moein can create a bot and send stuff into a thread", "make sdk for simple bots based off of the cli?", "idea: special cli that gave agent raw access to protocol buffers", "see if we can create a public/global thread for Inline updates with readonly permissions", "investigate how telegram bots communicate updates".

This doc focuses on two things:
1. A pragmatic bot platform spec that fits Inline's current architecture.
2. A product surface for "Inline Updates" as a read-only thread (like a channel).

## Research: Telegram Bot Update Model (Local Docs)

Telegram uses two mutually exclusive delivery modes for bot updates:
- Long polling (`getUpdates`) with offset-based acknowledgements.
- Webhooks (`setWebhook`) with retries and optional secret token.

Key semantics worth copying:
- Updates are queued on the server until confirmed.
- The client confirms by calling `getUpdates(offset = last_update_id + 1)`.
- `allowed_updates` filters update types.

Local reference:
- `/Users/mo/dev/telegram/telegram_bot_api.html` (getUpdates + setWebhook sections)

## Goals

- Make it easy to build a bot that can receive events (new messages, edits, reactions, membership changes), send messages into a thread/chat, and run reliably without websockets if desired (long polling).
- Keep security tight: bots have scoped permissions; no blanket access to all chats/spaces by default.
- Provide a CLI-based SDK path so integrations can ship quickly.

## Non-Goals (Initial)

- Rich interactive UI (buttons, slash commands) beyond text.
- Full webhook infra on day 1 (we can start with long polling and add webhooks later).
- Multi-tenant public bot directory.

## Proposed Bot Architecture (Incremental)

### Bot identity

- Represent bots as "users" with a `bot=true` flag (or a separate bot table).
- Bots authenticate with a dedicated token type `bot_token` scoped to allowed spaces/chats.

### Delivery mechanism: Bot Updates Queue (Telegram-style)

Add server-side updates queue for bots:
- `bot_updates` table with columns `bot_id`, `update_id` (monotonic per bot), `type`, `payload` (JSON or binary proto), `created_at`.

RPC:
- `bots.getUpdates(offset, limit, timeout, allowed_updates)`
Behavior:
- Long poll up to `timeout` seconds.
- Return ordered updates.
- Confirm updates by calling with offset > update_id (same as Telegram).

Why this is good:
- Works from any environment.
- Easy to integrate into `inline` CLI.
- Provides a stable "at least once" stream that can be replayed.

### Alternative delivery: Realtime/WebSocket

Optionally later:
- `bots.connect` realtime session that streams updates.
- More complex operationally; keep for later.

## Sending Messages (Bot -> Inline)

Simplest:
- Allow bot tokens to call existing `messages.sendMessage` RPC.

Constraints:
- Only for chats the bot is explicitly allowed in.
- For space threads, bot must be a member or explicitly permitted.

## CLI SDK Proposal

### 1. `inline bot login`

- Store bot token in a separate profile.
- Allow selecting target space/chat defaults.

### 2. `inline bot listen --json`

- Runs `bots.getUpdates` long poll loop.
- Prints one JSON object per update (newline-delimited JSON).
- Supports `--allowed-updates` filter.

### 3. `inline bot send --thread <id> --text ...`

- Convenience wrapper over sendMessage.

### 4. "Raw protocol access" for agents (advanced)

If we want the idea from notes:
- `inline rpc call <MethodName> --json-request <file>`
- `inline rpc listen --updates`
- Enables parallel requests and raw access for internal agent tooling.

This should stay internal-only unless we harden it.

## Security Model (Must-Haves)

- Bot tokens must be revocable.
- Scopes: read updates (only from allowed chats), write messages (only to allowed chats), admin (optional; for member management).
- Rate limits on sendMessage and getUpdates long polling loops.
- Audit logging for bot actions.

## "Inline Updates" Read-Only Thread (Product Surface)

Problem:
- We want a public-ish place for product updates but with tight posting permissions.

Proposal:
- Create a special space (or reuse an existing internal space) with a thread "Inline Updates".
- Make it readable to all users (or all users in a given company), but writable only by Inline team/bot.

Implementation options:
1. Chat-level permission: `canPost` false for normal members.
2. A bot is the only poster; normal users are members with read-only role.

Requires:
- new role or permission bit on members/participants.
- enforcement on server in sendMessage for that chat.

## Implementation Plan (Phased)

Phase 1 (internal bots, CLI first):
- Add bot token type and minimal auth.
- Add `bot_updates` queue and `bots.getUpdates`.
- CLI: `inline bot listen`, `inline bot send`.

Phase 2 (permissions + UI):
- Add UI to add bot to a space/chat with scopes.
- Add audit log + rate limits.

Phase 3 (Inline Updates thread):
- Implement read-only roles/permissions.
- Create and ship the global updates thread.

## Testing Plan

Server:
- Unit tests for getUpdates offset semantics (no duplicates when offset advances).
- Permission tests (bot cannot read/write outside scope).

CLI:
- Integration test for `inline bot listen --json` using a fake server.

Manual:
- Create a bot, add to a test space, send message into a thread, receive update via long poll.

## Risks / Tradeoffs

- Building a second "updates queue" system may overlap with existing sync updates; but bot needs a stable external interface and long polling fits well.
- Read-only thread introduces a new permission axis; enforce carefully to avoid breaking normal chats.

## Open Questions

- Do we store bot updates payload as JSON (easy) or binary proto (stable, harder to debug)?
- Should bots be able to access DMs? (Default no.)
- Should Inline Updates be truly global across all users, or opt-in per workspace/company?
