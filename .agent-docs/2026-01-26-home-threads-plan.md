# Home threads (non-space threads) — detailed plan

Date: 2026-01-26

## Summary
Add support for “home threads”: thread chats that do not belong to a space (`space_id` is null) and are scoped by explicit participants in `chat_participants`. This plan focuses on safe, incremental server changes first, then client updates, with explicit access and update routing, and clear tests/rollout.

## Goals
- Allow thread chats with `space_id = null` (home threads).
- Gate access to home threads by `chat_participants` (not space membership).
- Ensure updates, dialogs, and unread tracking work for home threads.
- Make creation flows support home threads (participants required, current user included).
- Keep existing space-thread behavior unchanged.

## Non‑Goals (for now)
- Public home threads (no space) — we will add later via special links.
- Space-level permissions or roles for home threads.
- Migrating old data unless existing records already rely on `space_id = null`.

## Open Questions / Decisions Needed
1) How should we persist the thread creator for home threads (new `createdBy` column on `chats`, or a separate ownership table)? Currently `chats` has no creator field.
2) Are any legacy clients still relying on `getDialogs(spaceId)` only (and never using realtime V2 / getChats)?

## Safety / Compatibility Notes
- `chats.space_id` is already nullable; no schema change required for nulls.
- Unique constraint on `(space_id, thread_number)` allows multiple nulls; avoid setting `thread_number` for home threads.
- `public_thread` should be `false` for home threads to keep them out of “public thread” queries.
- Keep all space‑thread permission checks unchanged.
- Add `chats.created_by` (nullable) for creator‑only participant management; set for home threads on creation.

---

## Plan

### Phase 0 — Audit and scoping (read‑only)
- Map all server paths that assume `chat.spaceId` exists for `thread` chats.
- Map client surfaces that filter by `spaceId` (Home vs Space list, create chat flows, chat info, etc.).
- Identify integration paths that use `spaceId` for Notion/Linear and ensure they tolerate `nil`.

### Phase 1 — Server: core access + update routing
1) Access guards
   - Update `AccessGuards.ensureChatAccess` to allow `thread` chats with `spaceId = null`.
   - New rule: for home threads, require `chat_participants` membership.
   - Cache results via `AccessGuardsCache` (same as private space threads).

2) Update groups
   - Update `getUpdateGroup` and `getUpdateGroupFromInputPeer` so home threads return `threadUsers` with participant IDs (no space membership).
   - Make `UpdateGroup.threadUsers.spaceId` optional (or add a new `homeThreadUsers` type) and adjust any callsites that assume it exists.

3) Thread fetch / create dialogs
   - Update `messages.getChat` to accept home threads:
     - If `spaceId` is null, validate participant membership and create a dialog with `spaceId = null` if missing.
   - Update `messages.getChats` to include home threads the user participates in (spaceId null).
     - Ensure dialogs created for home threads if missing.

4) Send / read / history
   - Confirm all message flows rely on `ensureChatAccess` and therefore work after Phase 1.
   - Add explicit tests for home thread access in `messages.getChatHistory`, `messages.sendMessage`, `messages.readMessages` if necessary.

5) Participant management
   - Enforce creator‑only add/remove for home threads.
   - Requires a persistent creator reference (`chats.created_by`).
   - Add authorization checks in add/remove flows: if `chat.spaceId` is null and `chat.createdBy !== currentUserId`, reject.
   - When removing a participant, delete their dialog and enqueue user‑bucket updates (similar to space threads).

### Phase 2 — Server: creation & visibility policies
1) Creation API
   - Update realtime `createChat` to allow `spaceId` optional / nullable.
     - If no spaceId: enforce `isPublic = false` and require participants.
     - Always include current user in participants.
     - Set `publicThread = false`, `threadNumber = null`, `spaceId = null`.
     - Store creator (`created_by = currentUserId`) for home threads to support creator‑only participant changes.
   - Consider adding a dedicated “createHomeThread” call if needed for clients.

2) Visibility / admin-only operations
   - `updateChatVisibility` should explicitly reject home threads (space required).
   - `deleteChat` should either reject home threads or add a home‑thread policy (based on decision above).

3) Dialog creation for participants
   - For home threads, create dialogs for all participants on creation (or on first access) to ensure they appear in Home.

### Phase 3 — Clients (Apple + Web)
1) InlineKit models + sync
   - Ensure `Chat.spaceId` and `Dialog.spaceId` are optional throughout.
   - Update any filtering logic that assumes thread implies space membership.
   - Verify Home list includes non‑space threads alongside DMs (no special separation).

2) iOS/macOS creation flows
   - Allow Create Chat without space:
     - `CreateChatView` should send `spaceId = nil` instead of `0`.
     - Participant picker should work without a space context (show recent users or search by username).
   - Update any UI that assumes `spaceId` is non‑nil for thread chats (chat info, message view integration actions, etc.).

3) Web client library
   - Update mappers and DB models if any implicit “thread => spaceId” assumption exists.
   - If the main web app is still landing‑only, skip UI changes; otherwise update thread list to include `spaceId = null` threads.

### Phase 4 — Tests & validation
- Server tests:
  - Access guard for home threads (participant vs non‑participant).
  - `getUpdateGroup` for home threads returns participant list.
  - `getChat` / `getChats` includes home threads with `spaceId = null`.
  - Create home thread: participants + dialogs created, current user included.
- Client tests:
  - InlineKit DB filters: home list includes home threads, space list excludes them.
  - Smoke flows: create home thread, send message, leave/remove participant.

### Phase 5 — Rollout & monitoring
- Gate with a server flag (optional) to limit creation of home threads until clients are ready.
- Add logging for home-thread creation and access denials to catch permission regressions.
- Monitor update fan‑out sizes; large participant lists may need batching later.

---

## Concrete file touchpoints (non‑exhaustive)

Server
- `server/src/db/schema/chats.ts`
- `server/drizzle/*` (new migration via `bun run db:generate <name>`)
- `server/src/modules/authorization/accessGuards.ts`
- `server/src/modules/updates/index.ts`
- `server/src/functions/messages.getChat.ts`
- `server/src/functions/messages.getChats.ts`
- `server/src/functions/messages.createChat.ts`
- `server/src/functions/messages.addChatParticipant.ts`
- `server/src/functions/messages.removeChatParticipant.ts`
- `server/src/functions/messages.updateChatVisibility.ts`

Apple
- `apple/InlineKit/Sources/InlineKit/ViewModels/HomeViewModel.swift`
- `apple/InlineMac/Features/Sidebar/ChatsViewModel.swift`
- `apple/InlineIOS/Features/CreateChat/CreateChatView.swift`
- `apple/InlineIOS/Features/CreateChat/SelectParticipantsView.swift`
- `apple/InlineIOS/Features/Chat/ChatView*.swift`

Web (if applicable)
- `web/packages/client/src/realtime/transactions/create-chat.ts`
- `web/packages/client/src/database/models.ts`

---

## Suggested sequencing
1) Server access + update routing + getChat/getChats tests.
2) Server creation flow + participant rules.
3) Apple clients (create + display + interactions).
4) Web client (if used) + smoke tests.

## Risks
- Silent exclusion of home threads from lists if any filter still assumes `spaceId != null`.
- Permission gaps in add/remove participant flows (currently no explicit access checks).
- Legacy clients relying only on `getDialogs(spaceId)` may never see home threads.

## Ready‑for‑prod checklist (post‑implementation)
- Home thread creation and access validated end‑to‑end on iOS/macOS.
- Server tests for home threads green.
- No regressions for space threads or DMs.
- Logging confirms home thread updates are delivered only to participants.
