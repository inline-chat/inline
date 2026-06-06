# iOS Active Chat Update Gating

Date: 2026-06-05

## Goal

Reduce iOS chat lag by stopping message UI update publishing for chats the user is not actively viewing, while still applying all realtime and sync updates to the database.

## Performance Investigation Summary

The most likely lag source is the message update pipeline. `MessagesPublisher` is main-actor isolated, and several update paths synchronously hydrate `FullMessage` with `FullMessage.queryRequest()` before publishing UI updates. That query pulls a large graph: sender and profile photos, forwarded users, replies, reactions, attachments, media metadata, translations, and related entities. Realtime updates such as reactions, attachment changes, edits, deletes, and history reloads can trigger this work repeatedly.

The second major source is the iOS message cell renderer. `MessageCollectionViewCell.configure` removes the existing message view and creates a new `UIMessageView` for meaningful updates. The message view then rebuilds subviews, constraints, attributed text, link styling, reactions, attachments, and media views. This makes every reconfigure expensive.

The chat list also does too much work. `HomeChatItem.all()` fetches rich data for every row, and SwiftUI views sort/filter those arrays in computed properties. Chat list updates animate broad `items` changes and run translation checks for every row change. The Telegram macOS sidebar pattern suggests a better direction: stable lightweight row entries, sorted indexes, precomputed presentation, off-main diff preparation, and granular row merges.

Startup and navigation add amplification: launch updates share-extension data by fetching home chat items, `HomeView.onAppear` refetches `getMe`, `getChats`, and `getSpaces`, experimental home can fetch dialogs for every space, and navigation persists state with multiple detached tasks on every mutation.

## Ordered Plan

1. Active-chat scoped update publishing.
   Keep applying all updates to the DB, but only hydrate/publish message UI updates for the peer currently visible on iOS. This avoids wide main-actor reads for background chats and preserves optimistic updates in the active chat.

2. Initial message sync/open-chat load.
   When a chat becomes active, reload the current local message window so skipped inactive publishes are recovered from DB. Move initial `FullMessage` hydration off-main in a later pass.

3. Telegram-style chat list pipeline.
   Replace rich home rows with a lightweight `ChatListEntry`, stable ordering keys, precomputed row presentation, and diffed row updates. Avoid sorting/filtering rich rows in SwiftUI body paths.

4. Reusable/updatable iOS message view.
   Build a new message view using the macOS architecture as reference: `MessageViewProps`, layout plans, no-op/size-only/content-update/rebuild decisions, reusable subviews, and structural rebuilds only when the constraint shape changes.

5. Defer broad animation/translation cleanup unless an obvious bug appears.
   The obvious exception is translation reconfiguring every message in a peer; this should be narrowed when touching the update pipeline.

## Step 1 Implementation Scope

Implemented an iOS-only active chat registry in `MessagesPublisher`.

- `activateChat(peer:)` returns an active-chat token and increments the active count for that peer.
- `deactivateChat(_:)` removes the token and clears the peer when no active token remains.
- Publisher methods check the active peer before hydrating or sending UI updates.
- macOS behavior remains unchanged behind `#if os(iOS)`.
- `ChatView` registers on appear and unregisters on disappear.
- `ChatView` now treats a chat as active only while the view is visible and the scene is foreground active.
- If SwiftUI reuses a `ChatView` for a different peer, the previous active token is removed before the new peer is activated.
- When a peer transitions from inactive to active, `MessagesPublisher` sends a local reload for that peer. If the message view already exists, it refreshes from DB; if not, the initial load reads DB normally.

## Expected Benefit

Background chat updates continue to update local data, unread state, sidebar state, and sync state through the DB. They no longer force the iOS message list to hydrate rich message graphs or reconfigure cells for chats that are not visible.

The biggest expected win is during bursts: reactions, edits, attachments, catch-up reloads, and send-status updates for inactive chats should no longer occupy the main actor through `MessagesPublisher`.

## Risks

- A chat view that remains alive but is not active can miss publisher events. The activation reload is intended to recover from DB when the user returns.
- If a view does not receive `onDisappear` reliably, scene-phase deactivation and peer-change token replacement reduce the chance of stale active peers. The token/count model makes duplicate appearances safe, but lifecycle validation is still needed.
- This does not solve heavy initial hydration or expensive iOS cell rebuilding. It only reduces unnecessary background publish work.

## Safety Review

- Persistence is not gated. Checked publisher call sites for message saves, realtime updates, send/edit/delete/reaction transactions, media/file reloads, and history fetches; these write local DB state first and use `MessagesPublisher` only to invalidate visible message UI.
- Inactive-chat publisher skips should therefore not lose data. Returning to a chat activates the peer and triggers a local reload from DB.
- Active local optimistic updates still publish because the compose/reaction/edit/delete actions happen from the visible chat.
- macOS behavior remains unchanged because active-peer gating is iOS-only.
- The remaining correctness dependency is SwiftUI lifecycle delivery. Runtime validation should confirm `onAppear`, `onDisappear`, and scene-phase transitions keep exactly the visible foreground chat active.

## Validation Needed

- Build `Inline (iOS)` or the relevant package after resolving any unrelated dirty-tree issues.
- Run on simulator/device and verify:
  - Active chat receives new messages, edits, reactions, deletes, and send-status updates.
  - Background chat updates still update the chat list/unread state through DB observations.
  - Returning to a previously open chat refreshes missed changes from local DB.
  - Main-thread stalls decrease during background update bursts.
