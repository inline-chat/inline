# Search Across Everything (Spec, 2026-02-07)

From notes (Feb 1-7, 2026): "spec out search across everything".

This spec is intentionally incremental: ship a useful v0 quickly, then harden performance and ranking.

## Goals

1. One query powers search across users, threads, spaces, and optionally messages.
2. Strict access control: never leak spaces/threads/messages the user cannot access.
3. Fast for common queries and scalable (no O(N) decrypt-and-scan over all messages).
4. Result UX is consistent across iOS/macOS/web (same types, same ranking rules, same pagination).

## Non-Goals (For v0)

1. Perfect relevance ranking.
2. Typo-tolerant matching everywhere.
3. Full plaintext indexing if we decide it conflicts with the product’s encryption posture.

## Current State (What Exists)

1. iOS/macOS "GlobalSearch" only searches users via REST `/searchContacts`.
2. Apple local home search exists (threads + users) via GRDB: `HomeSearchViewModel`.
3. Server supports per-chat message search over RPC (`messages.searchMessages`) by scanning, decrypting, and substring matching. This does not scale to cross-chat search.

Key files:
- Server user search: `server/src/methods/searchContacts.ts`, `server/src/db/models/users.ts`
- Per-chat message search: `server/src/modules/search/messagesSearch.ts`
- iOS user-only global search: `apple/InlineIOS/Features/Search/GlobalSearch.swift`
- macOS user-only global search: `apple/InlineMac/Views/Sidebar/GlobalSearch.swift`
- Apple local home search: `apple/InlineKit/Sources/InlineKit/ViewModels/HomeSearchViewModel.swift`

## Product Decision Points (Lock These Early)

1. Should global user search remain "public by username" or be scoped to shared spaces/contacts?
2. Should global search include messages in v0, or start with users/spaces/threads only?
3. Are we willing to store derived search indexes (tsvector) that are computed from decrypted content?

## Proposed API (Realtime RPC)

Add a new RPC (prefer realtime RPC to keep parity with other client transactions):

1. `searchGlobal`
2. Input fields:
3. `query: string`
4. `limit: int` (default 20)
5. `cursor?: string` (opaque)
6. `filters?: { includeUsers, includeSpaces, includeThreads, includeMessages, messageFilter? }`
7. `scope?: { spaceId?: ID }` (optional, for "search inside a space")

Result:
1. `results: [SearchResult]`
2. `nextCursor?: string`

`SearchResult` should be a oneof union:
1. `user { minUserInfo }`
2. `space { spaceSummary }`
3. `thread { chatSummary + spaceSummary? }`
4. `message { chatSummary + messagePreview + messageId }`

Notes:
1. Keep payloads minimal. The UI can fetch full detail on selection (open chat, go-to-message).
2. Include `score` as a float/int for deterministic client ordering.

## Access Control Requirements (Non-Negotiable)

1. Spaces: only spaces where the user is a member.
2. Threads/chats: only chats the user can access, constrained via `dialogs` (and `members` for space-public threads).
3. Messages: only messages within accessible chats.
4. Users: follow the chosen privacy model (public username search vs scoped).

## Implementation Plan

### Phase 0: Protocol + Plumbing

1. Define proto types and regenerate.
2. Add server realtime handler and function scaffold.
3. Add client transaction wrappers (Apple: `InlineKit` Realtime transaction; web: protocol client).

### Phase 1: v0 Search (No New Infra)

Goal: useful search across users + threads + spaces with simple matching.

Server queries:
1. Users: keep `UsersModel.searchUsers` (username ILIKE) or tighten if privacy requires.
2. Spaces: join `members` then `spaces`, match `name ILIKE` or `handle ILIKE`.
3. Threads: join `dialogs` then `chats`, match `title ILIKE` (and optionally `description ILIKE`).

Ranking heuristics:
1. Exact match beats prefix beats substring.
2. Threads with recent activity beat stale threads for the same match quality.
3. Spaces beat threads beat users only if match quality is similar (tunable).

Pagination:
1. Cursor is required for threads/spaces if results can be large.
2. For v0 it is acceptable to cap results (limit 20-50) and return no cursor.

### Phase 1b: Messages (Optional, Still No New Infra)

If messages must be included in v0, keep it explicitly bounded:
1. Only search the most recent N messages per chat (example: last 200).
2. Only search across the last M accessible chats (example: last 50 by activity).
3. Reuse existing decrypt+substring logic.

This is a stepping stone only. It will not scale to “search everything ever”.

### Phase 2: Full-Text Search (Scale)

Adopt Postgres full-text search for spaces/threads/messages:
1. Add tsvector columns for `spaces`, `chats`, and `messages`.
2. Add GIN indexes.
3. Use `websearch_to_tsquery` parsing and `ts_rank` ranking.
4. Add `pg_trgm` indexes for fuzzy/prefix matching on usernames/handles and short queries.

Encryption posture options:
1. Derived index columns (tsvector) computed server-side after decrypting message text.
2. A dedicated search table that stores plaintext is more flexible, but is a stronger privacy tradeoff.
3. If plaintext indexing is unacceptable, keep message search scoped only (per-chat, time-window).

## Client UX Plan

### iOS

1. Extend `GlobalSearchResult` union to include spaces/threads/messages.
2. Results UI: grouped sections (Spaces, Threads, Users, Messages) with a single list.
3. Selection behavior:
4. Space: navigate to space.
5. Thread: open thread.
6. Message: open thread and trigger go-to-message flow.

### macOS

1. Same union result model as iOS.
2. Reuse existing global search popover but add sections and keyboard navigation.
3. Message result selection should reuse the go-to-message work in `/.agent-docs/2026-02-07-chat-open-perf-pagination-go-to-message.md`.

### Web

1. Add a top-level command palette or search field (later).
2. Initially it can call the same `searchGlobal` RPC and reuse chat open routes.

## Testing Plan

1. Server: access control tests (space membership required, dialog required, public thread access guard).
2. Server: query parsing edge cases (leading `@`, case sensitivity, empty queries).
3. Clients: selection behavior opens correct destination and does not crash if result becomes inaccessible.
4. Performance: add basic timing logs on server for v0 queries; enforce a hard timeout.

## Acceptance Criteria (v0)

1. Searching for a space handle finds that space only if user is a member.
2. Searching for a thread title finds that thread only if user has a dialog/access.
3. Searching for `@username` finds user by username.
4. No results leak across spaces the user is not in.

## Open Questions

1. Do we want results to include "Create new thread" or "Invite user" actions inside search?
2. Should we surface local results instantly (GRDB) and then merge in server results, or always use server?
3. Do we want message results at all in v0, or keep that for Phase 2 with FTS?

