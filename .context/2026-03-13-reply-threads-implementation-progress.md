# Reply Threads Implementation Progress

Date: 2026-03-13
Source plan: `.agent-docs/2026-03-12-subthreads-plan-feedback-revision.md`
Status: phase-complete for v1 implementation

## Scope

Implement the reply-thread MVP as message-anchored subthreads:

- child chats stored on `chats`
- `parent_chat_id` for structural/inherited access
- `parent_message_id` for reply-thread anchoring
- no eager dialog creation for linked subthreads
- hidden dialogs created on first open for linked subthreads
- sidebar visibility separated from durable dialog state
- open/send/history flows should work as normal chat flows
- parent message should surface reply-thread summary
- child thread should render the anchored parent message at the top and support back navigation

## Phases

### Phase 0: Track + lock invariants

Status: completed

- [x] Load revised plan and current implementation surfaces
- [x] Confirm current dialog/getChat/getChats/history/send constraints
- [x] Record implementation decisions as code lands

### Phase 1: Schema + proto

Status: completed

- [x] Add `parent_chat_id` and `parent_message_id` to `server.chats`
- [x] Extend protocol `Chat`
- [x] Add `createSubthread`
- [x] Allow `GetChatResult` to omit dialog and include anchor message
- [x] Add parent-message reply-thread summary to protocol `Message`
- [x] Add user-scoped `chatOpen` update for sidebar-visible chats

### Phase 2: Server model + access + creation

Status: completed

- [x] Implement inherited access through `parent_chat_id`
- [x] Validate reply-thread anchors against parent message existence
- [x] Implement idempotent reply-thread creation/open
- [x] Switch linked-thread dialog materialization to hidden first-open dialogs
- [x] Return parent-message reply summary
- [x] Restrict `chatOpen` to sidebar-visible dialog creation and promotion paths
- [x] Filter hidden linked-thread dialogs out of both `getChats` and legacy `getDialogs` sidebar feeds

### Phase 3: Apple data + transactions

Status: completed

- [x] Persist new chat/message parent fields locally
- [x] Handle `chatOpen` in realtime and sync reducers
- [x] Handle `getChat` without a dialog row
- [x] Save anchor message on open
- [x] Add transaction wrapper for `createSubthread`
- [x] Persist dialog sidebar visibility locally
- [x] Filter hidden dialogs out of sidebar/home queries

### Phase 4: Apple UI

Status: completed

- [x] Add message action for `Reply in a Thread`
- [x] Open/create subthread and navigate into child chat
- [x] Open existing reply threads by tapping the replies footer under the parent message bubble
- [x] Render the anchor context at the top of the child thread view
- [x] Render anchor row as first item in child timeline
- [x] Support back navigation to parent chat
- [x] Show reply summary on parent message row
- [x] Add macOS `Reply in Thread` context-menu action
- [x] Add macOS replies footer under the parent message bubble
- [x] Add recent replier user ids to replies summary so macOS can render avatars

### Phase 5: Validation

Status: completed

- [x] Run focused server tests
- [x] Run focused Swift build/tests for touched packages
- [x] Verify reply-summary unread state updates when child thread unread state changes
- [x] Confirm macOS app-target build
- [x] Confirm iOS app-target build
- [x] Review production risks and readiness

### Phase 6: User-ready polish

Status: completed

- [x] Keep hidden reply threads out of the sidebar on open and send
- [x] Add explicit `Show in Sidebar` action and RPC for hidden reply threads
- [x] Add reply-thread toolbar action to open the parent chat/thread
- [x] Use reply-thread-specific iconography in the sidebar
- [x] Render the reply anchor like a real message row with the `Replies` separator below it
- [x] Polish reply summaries with wider layout, no blue leading line, loading affordance, and hover feedback where applicable
- [x] Inherit parent translation state when opening reply threads on macOS

## Notes

- The current Apple chat-open path is dialog-centric. Linked subthreads require a chat-open path that does not depend on sidebar dialog materialization.
- The current server `getChats` path eagerly creates dialogs for all accessible top-level chats. That behavior must stay for top-level chats and opt out for linked subthreads.
- We added a dedicated user-scoped `chatOpen` update instead of overloading chat-scoped `newChat`. This keeps "chat exists" separate from "this user now has a sidebar dialog for it".
- The dialog model has been revised: linked reply threads now create a real per-user dialog on first open, but it defaults to hidden from sidebar/home lists until explicitly promoted.
- This keeps read position, archive, pin, and notification state dialog-backed without forcing every opened thread into the sidebar.
- The legacy `getDialogs` server feed also needed filtering because current Apple space sidebars still use it in some paths; hidden reply-thread dialogs are now excluded there too.
- Promotion from hidden dialog to sidebar-visible dialog is now centralized and intentionally limited: hidden reply-thread dialogs promote on pin, unarchive, received mention/reply, and the explicit `Show in Sidebar` action.
- `Show in Sidebar` now ships as a dedicated action/RPC instead of being implicit in open/send flows.
- For v1, reply-summary realtime still piggybacks on parent `editMessage` updates. That keeps the client simple and centralized, but read/unread churn in very large threads may eventually warrant a dedicated user-scoped summary update.
- Focused validation so far:
  - `cd server && bun run typecheck`
  - `cd server && bun test src/__tests__/functions/markAsUnread.test.ts`
  - `cd server && bun test src/__tests__/functions/getChat.test.ts`
  - `cd server && bun test src/__tests__/functions/messages.createSubthread.test.ts`
  - `cd server && bun test src/__tests__/functions/sendMessage.test.ts`
  - `cd server && bun test src/__tests__/modules/syncFlow.test.ts`
  - `cd apple/InlineKit && swift build`
  - `cd apple/InlineKit && swift test --filter ReplyThreadModelsTests`
  - `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration Debug build`
  - `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (iOS)" -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/inline-ios-replythreads-v1 build`

## Production readiness

- Core reply-thread v1 flows are implemented and compile on server, shared Apple code, macOS, and iOS.
- Security risk is unchanged from the parent chat/message architecture; reply threads reuse existing access checks and dialog-backed per-user state.
- Performance risk is acceptable for v1:
  - hidden dialogs are created only on first open, not eagerly fanned out
  - reply-summary realtime still piggybacks on parent `editMessage`, which is simple but may need a dedicated user-scoped update if very large threads create noisy read/unread churn later
  - iOS uses an in-list boundary supplementary for the reply anchor context rather than a true synthetic datasource row, which keeps v1 lower risk but leaves a small parity/future-flexibility follow-up
- Main remaining ship risk is manual UX QA, not a known architecture hole.

## Current iOS v1 shape

- The parent message row now stores and renders reply-thread summary locally, and iOS shows it as a low-risk tappable footer under the bubble.
- Tapping that footer navigates into the linked child thread using the normal `.chat(peer: .thread(...))` route.
- The message context menu now includes `Reply in Thread`; it opens the existing reply thread or creates it on demand and then navigates in.
- The child thread no longer requires a local dialog row in order to open.
- The child thread now renders reply context inside the scrolling timeline model on iOS via an in-list `Replies` separator plus anchor context view, replacing the old external header path.
- The iOS replies footer now includes an explicit unread dot in addition to unread tint, matching the macOS summary model more closely.
- The iOS replies footer now reserves trailing space for a loading spinner while the child thread is being resolved/opened.

## Current macOS v1 shape

- The message context menu now includes `Reply in Thread`; it opens the existing reply thread or creates it on demand and then navigates in.
- Parent messages now show a compact replies footer under the bubble on macOS, with recent replier avatars, unread dot state, and direct navigation into the child thread.
- Child reply threads render a `Replies` separator followed by an artificial anchor row as the first items in the timeline instead of a floating header.
- Reply-thread toolbars now expose both `Show in Sidebar` for hidden threads and an overflow action to jump back to the parent chat/thread.
- macOS reply-thread navigation inherits translation state from the parent thread and keeps reply-footers hidden-thread-safe by default.
- macOS still shares the hidden-dialog/open-directly behavior from the Apple data layer, so child threads do not require a visible sidebar row to open.
