# Multi-Space Workflow + Space Picker + Move Thread (2026-02-07)

From notes (Feb 3-7, 2026): "fix multi-space workflow", "space picker for my sanity", "design: way to view multiple spaces", "move to/out of space", "let user move a thread to another space / make it space-less".

Related existing planning:
- `/.agent-docs/2026-01-26-home-threads-plan.md` (space-less threads / "home threads")

## Goals

- Switching spaces is fast, obvious, and does not break navigation.
- Users can move a thread between spaces, and out of a space into "Home" (space-less) when appropriate.
- Clients stay consistent via a single update type that moves dialogs/chats across lists.

## Non-Goals (For Tomorrow)

- Public home threads (space-less but visible to all) unless explicitly decided; default should remain private.
- Multi-account or cross-workspace federation.

## Current State (What Exists)

Data model:
- `Chat.spaceId` and `Dialog.spaceId` are already optional (nullable `space_id` in DB).
- There is no first-class "move thread" RPC/update today.

macOS:
- New sidebar has a Space Picker overlay in the header (Home + spaces + Create Space).
Files: `apple/InlineMac/Features/Sidebar/MainSidebar.swift`, `apple/InlineMac/Features/Sidebar/SpacePickerOverlayView.swift`.

iOS:
- Space picker exists as a popover in the experimental root.
File: `apple/InlineIOS/UI/SpacePickerMenu.swift`.

Server:
- Creation supports `spaceId` but not moves.
Files: `server/src/functions/messages.createChat.ts`, `server/src/methods/createThread.ts` (space-only).

## Product Decisions Needed (Explicit)

1. Who can move threads?
- Default recommendation:
Space threads: only space owner/admin can move a thread out of the space or into another space. Home threads: creator can move into a space (and becomes space-owned rules).

2. What happens when moving a public space thread to Home?
- There are no "public home threads" today; moving out must become a private home thread.
- Require selecting participants (must include current user).

3. Title conflicts in the destination space.
- Option A: block with an explicit "rename first" error.
- Option B: auto-suffix title ("Design (2)").
- Recommendation: block first (predictable), add auto-suffix later.

## Proposed UX (Mac First)

### Space Switching

- Keep the existing header Space Picker as the primary control.
- Optional: add an "All spaces" view that is just a filtered Home list including space threads grouped by space.

### Move Thread Entry Points

macOS:
- Chat Info: add a "Move..." section with actions "Move to Space..." and "Move to Home".
- Sidebar context menu on a thread item: "Move to..."

iOS:
- Chat Info: overflow menu "Move..."
- Picker presented as a sheet:
Destination: Home or a Space. If needed: visibility + participants screen.

## Backend Design (Core)

### API Shape (Recommended)

Add a new RPC:
- `messages.moveChat`

Input fields (conceptual):
- `chat_id` (required)
- `to_space_id` (optional; absent or 0 means Home)
- `to_is_public` (optional; required when moving into a space)
- `participants` (optional; required when moving to Home or moving into a private space thread)

Output:
- updated `Chat` and relevant `Dialog` records (or just `chat_id` + update stream).

### Server Semantics

When moving chat:
- Update `chats.space_id` to destination.
- Update all `dialogs.space_id` for that chat to destination (so it renders under the right place).
- If moving into a space: enforce space membership rules; set `public_thread` based on `to_is_public`; if private, ensure `chat_participants` is set to selected participants and dialogs exist only for those users.
- If moving to Home: force `public_thread = false`; require participants; update `chat_participants` to that list; ensure dialogs exist only for them.
- Update sequencing:
- Bump chat bucket `seq` and ensure `lastUpdateDate` is touched so clients refetch if they miss the explicit update.

### Client Update (Required)

Add a new update type `UpdateChatSpaceChanged` (name TBD) that includes:
- `chat_id`
- `from_space_id` (optional)
- `to_space_id` (optional)
- `is_public`
- `participants_changed` (optional hint) or just rely on normal participant updates.

Reason:
- This lets clients move a chat/dialog across lists without a full reload, and ensures a deterministic UI update.

### Key Server Files (Likely Touchpoints)

- Proto: `proto/core.proto` (RPC + update payload), `proto/server.proto` (server update mapping if needed).
- Server implementation: `server/src/functions/messages.*` (new function), `server/src/db/schema/chats.ts`, `server/src/db/schema/dialogs.ts`, `server/src/db/models/chats.ts` or `server/src/db/models/messages.ts` (wherever chat mutations live), `server/src/modules/updates/*` (enqueue + push).

## Apple Client Implementation Plan

InlineKit:
- Add new update apply path: update Chat + Dialog spaceId and coalesce list updates.
- Ensure list queries treat `spaceId nil` as Home and non-nil as space lists.

macOS:
- Add UI actions to trigger move RPC.
- After success: navigate to destination (Home or Space) and keep the moved chat open.

iOS:
- Add Chat Info move UI and wire to transaction.

## Testing Plan

Server tests:
- Move space->space: chat/dialog spaceId updated; correct access enforcement.
- Move space->home: rejects if missing participants; forces private; participant dialogs created; others removed.
- Move home->space: requires `to_is_public` and/or participants depending on visibility.
- Update fanout: only relevant users receive update.

Client tests (manual + minimal automated):
- Move a thread while it is open; confirm sidebar moves and chat stays open.
- Ensure old space list no longer shows it; destination list shows it.
- Ensure a non-participant loses access immediately after move to Home.

## Risks / Tradeoffs

- Adding a new update type touches all clients (macOS, iOS, web if used).
- Moving a chat across spaces affects permissions; bugs can become security issues if checks are wrong.
- Title/threadNumber conflicts need a clear product rule to avoid weird failures.

## Open Questions

- Do we want "All spaces" as a first-class view, or just rely on fast switching?
- Should moving a thread preserve its public/private setting by default, or always ask?
