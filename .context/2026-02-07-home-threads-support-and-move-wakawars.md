# Home Threads Support + “Move wakawars to Home” (2026-02-07)

From notes (Feb 1, 2026): "add thread supports to home", "move \"wakawars\" to home".

This is a focused “tomorrow-ready” wrapper that ties together:
1. Home threads (space-less threads) support.
2. Moving an existing space thread out of a space into Home.

## Existing Plans To Reuse

1. Home threads deep plan: `/.agent-docs/2026-01-26-home-threads-plan.md`
2. Move-to/out-of-space UX + RPC: `/.agent-docs/2026-02-07-multi-space-workflow-space-picker-move-thread.md`

## Goals

1. Threads can live in Home (`spaceId = nil`) and behave correctly (access, dialogs, updates, unread).
2. Moving a thread out of a space is supported and safe (becomes a private home thread).
3. “wakawars” can be moved out of its space and still be usable by the intended participants.

## Non-Goals

1. Public home threads.
2. Space-level visibility settings for home threads.

## Product Rules (Lock These)

1. Home threads are always private.
2. Access is via explicit participants (`chat_participants`) and corresponding dialogs.
3. Moving a space thread to Home requires selecting participants (must include current user).
4. After move, non-participants must immediately lose access and stop receiving updates.

## Current State (Important Inconsistency)

Home list behavior is currently inconsistent across clients:
1. Home list data is sourced from `HomeChatItem.all()` and is not inherently filtered by `spaceId`.
2. iOS Home currently does not explicitly filter out space threads.
3. macOS new sidebar Home currently does not explicitly filter out space threads.
4. macOS `ChatsViewModel` home source does filter to `space == nil`.

Implication:
1. Even if server home threads work perfectly, “Home” may still show space threads until we standardize the filter.

Key touchpoints:
1. Shared data source: `apple/InlineKit/Sources/InlineKit/ViewModels/HomeViewModel.swift`
2. iOS Home UI: `apple/InlineIOS/MainViews/HomeView.swift`
3. macOS new sidebar: `apple/InlineMac/Views/Sidebar/NewSidebar/NewSidebar.swift`
4. macOS reference behavior: `apple/InlineMac/Features/Sidebar/ChatsViewModel.swift`

## Implementation Plan (High Level)

### Phase 1: Ensure home threads are supported end-to-end

1. Server access guard supports `spaceId = nil` threads (participant membership).
2. Server update fan-out for home threads targets participants only.
3. `getChat/getChats` includes home threads in Home lists.
4. Clients treat `spaceId = nil` threads as Home items.

Use the detailed plan:
- `/.agent-docs/2026-01-26-home-threads-plan.md`

Client detail for Phase 1:
1. Define Home list as: dialogs where `dialog.spaceId == nil` (DMs + home threads).
2. Define Space list as: dialogs where `dialog.spaceId == <spaceId>`.
3. Prefer `Dialog.spaceId` as the source of truth (it is already optional in the schema).

### Phase 2: Implement “Move to Home” operation

Two options:
1. One-off operational move for wakawars (fastest): an admin script/DB update to set `space_id = null` and enforce private participants.
2. Productize: implement `messages.moveChat` RPC + update type.

1. Implement `messages.moveChat` RPC and update type (move space -> home).
2. Enforce rules:
3. Force `public_thread = false`.
4. Require explicit participant list.
5. Update `chats.space_id = null` and set `chat_participants`.
6. Create/remove dialogs accordingly.

Use the move spec:
- `/.agent-docs/2026-02-07-multi-space-workflow-space-picker-move-thread.md`

### Phase 3: Apply to “wakawars”

1. From macOS Chat Info or sidebar context menu, use “Move to Home”.
2. Pick the intended participants.
3. Verify the moved thread appears under Home and no longer appears under the old space.

## Testing Checklist

1. Create a home thread, add participants, send messages, confirm all participants receive updates.
2. Move a space thread to Home:
3. Participants list enforced.
4. Non-participants lose access immediately.
5. Updates are only delivered to participants.
3. Move “wakawars” and confirm it behaves like a normal home thread.

## Acceptance Criteria

1. Home threads are stable and do not break sync/unread.
2. Move-to-Home is permission safe and deterministic across clients.
