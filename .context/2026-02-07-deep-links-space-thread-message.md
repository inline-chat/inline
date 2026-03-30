# Deep Links: Space / Thread / Message Links (2026-02-07)

From notes (Feb 7, 2026): "space links, thread links".

## Goals

1. Users can copy a link to a space/thread/message and share it.
2. Opening a link routes to the correct destination on macOS, iOS, and web.
3. Deep links do not bypass permissions. If the user cannot access the target, show a clear error.
4. Message deep links integrate with “go to message” and remote backfill.

## Non-Goals (For First Pass)

1. Universal Links and HTTPS redirect infrastructure (can be added later).
2. Cross-account and multi-tenant routing beyond the current auth model.

## Current State

1. macOS supports custom URL schemes and handles:
2. `inline://user/<id>` (opens DM)
3. `inline://integrations/...` (integration callback)
4. iOS only has URL handling in the integrations settings card.
5. There is no shared deep-link parser module.

Key files:
- macOS handler: `apple/InlineMac/App/AppDelegate.swift`
- iOS integration URL handler: `apple/InlineIOS/Features/Settings/IntegrationCard.swift`

## URL Scheme Spec (Custom Scheme)

Support both schemes (already partially supported on macOS):
1. `inline://`
2. `in://` (alias)

Hosts and formats:
1. `inline://user/<userId>`
2. `inline://space/<spaceId>`
3. `inline://thread/<threadId>`
4. `inline://thread/<threadId>/message/<messageId>`

Notes:
1. Prefer stable numeric IDs (Int64 / proto ID).
2. Keep the scheme host simple and not overloaded with query params.
3. If we later add web Universal Links, we can map these patterns 1:1.

## Routing Behavior (Per Link Type)

1. User: open the DM (existing behavior).
2. Space: open space view (space overview or thread list).
3. Thread: open thread chat view.
4. Message: open thread chat view and scroll to the target message (with remote load if needed).

## macOS Implementation Plan

1. Extend `handleCustomURL` in `apple/InlineMac/App/AppDelegate.swift`:
2. Add new cases for `space` and `thread`.
3. For `thread/.../message/...`, parse both IDs and route.

Thread routing:
1. `dependencies.nav.open(.chat(peer: .thread(id: threadId)))`

Message routing:
1. Open chat first.
2. After chat state is available, trigger scroll-to-message (use existing `ChatsManager`/`ChatState` scroll APIs).
3. If message is not in local DB, rely on the "go to message" plan to fetch around the target.

Best practice:
1. Coalesce: avoid opening multiple windows or spamming navigation if multiple URLs arrive quickly.
2. Always bring app to foreground before routing (macOS already does this).

## iOS Implementation Plan

1. Add a global `.onOpenURL` handler at the root (`ContentView2`).
2. Parse the URL using a shared parser (see below).
3. Route using the existing `Router` destinations:
4. Space: `.space(id)`
5. Thread: `.chat(peer: .thread(id:))`
6. Message: `.chat(peer: .thread(id:))` then scroll.

Message scroll plan:
1. Add a lightweight "pending deep link" state (threadId + messageId) stored in `Router` or a global nav coordinator.
2. When `ChatView` appears for that thread, consume the pending messageId and call `scrollTo(msgId:)`.

## Web Implementation Plan (Optional)

If we want shared links to work outside native apps:
1. Add routes like `/t/<threadId>` and `/t/<threadId>/m/<messageId>`.
2. Later add a redirect page that offers "Open in app" via custom scheme.

## Shared Parser (Recommended)

Add a small shared parser that returns a typed destination:
1. `DeepLink.user(id)`
2. `DeepLink.space(id)`
3. `DeepLink.thread(id)`
4. `DeepLink.message(threadId, messageId)`

This should live in a shared Swift module (or duplicated initially, but that’s worse long-term).

## Security

1. Never assume the user can access the target.
2. If access fails, show a toast or modal with a friendly message.
3. Do not leak existence of private threads via error details.

## Testing

1. Unit tests for parsing each URL format.
2. Manual tests:
3. Open space link while app closed.
4. Open message link while app running.
5. Open a link to a thread you do not have access to (expect error).

## Acceptance Criteria

1. Copying a thread link and opening it reliably navigates to the correct thread on macOS.
2. Copying a message link navigates and scrolls to the message (after remote load if needed).
3. iOS routes links consistently once the root handler is added.

