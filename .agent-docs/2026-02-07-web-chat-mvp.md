# Web Chat MVP (Spaces, Sidebar, Threads, Messages)

Date: 2026-02-07

## Goal

Ship a usable “basic chat” experience in the web app:

- Space picker (Home + spaces)
- Sidebar with DMs + threads (filtered by selected space)
- Chat view: load history, live updates (via realtime updates), send messages
- Basic reply-to (message thread) support in composer and message rendering

## Non-goals (for this pass)

- Full message virtualization/perf tuning
- Attachments, reactions, typing indicators, read receipts
- Advanced routing like `/space/:id/thread/:id` (we’ll keep a single dialog route)

## Plan

1. Protocol/db wiring
   - Add `Space` upsert mapping in `web/packages/client` and store spaces from `GetChatsResult.spaces`.
   - Apply `joinSpace` updates to local DB (so spaces list stays fresh).
   - Fix `useQueryObjects`/`useQueryRefs` to support dynamic predicates via explicit query keys.

2. Routing and authenticated layout
   - Add `/app/d/$dialogId` route for opening a dialog (DM or thread).
   - Move split layout (sidebar + content outlet) into `/app/route.tsx`, but keep `/app/login/*` unchanged via conditional layout.
   - Keep `/app/` as an empty state (“Select a chat”).

3. Space picker + sidebar
   - Store selected space in router search param `spaceId` (optional).
   - Sidebar header: dropdown Home + spaces.
   - Sidebar list:
     - Threads section: dialogs with `peerUserId == null` filtered by space.
     - DMs section: dialogs with `peerUserId != null` (global).
   - Make items navigable and highlight the active dialog.

4. Chat view
   - Ensure dialog exists via `getChat(peerId)` derived from `dialogId`.
   - Load initial history via `getChatHistory(peerId, limit)`.
   - Message list from DB filtered by `chatId`, sorted ascending (by `date`, then `id`).
   - “Load older” fetch (offsetId = oldest positive message id).
   - Composer: send via `sendMessage({ text, peerId, chatId, replyToMsgId? })`.

5. Basic reply-to (threads)
   - Message row: “Reply” action sets `replyToMsgId`.
   - Composer: show “Replying to …” banner with cancel.
   - Render reply context in message bubble when `replyToMsgId` exists and referenced message is in cache.

6. Verification
   - `cd web && bun run typecheck`
   - Quick smoke run via `cd web && bun run dev` (optional, user-run if preferred)

## Progress

- [x] 1. Protocol/db wiring
- [x] 2. Routing and authenticated layout
- [x] 3. Space picker + sidebar
- [x] 4. Chat view
- [x] 5. Basic reply-to (threads)
- [x] 6. Verification

## Follow-Ups Done

- [x] Sidebar: sort by pinned then recency (via `Chat.lastMsgId -> Message.date`) and show last-message preview/time.
- [x] Sidebar: “New thread” panel in header (creates a private thread in the selected space and navigates to it).
- [x] Realtime updates: fix dialog-id mapping for thread peers (thread dialogs are stored at `-chatId`).
- [x] New DM: add a “New” menu with DM picker; for spaces, fetch + cache members via `getSpaceMembers`.
- [x] Messages: basic edit/delete actions; keep `Chat.lastMsgId` correct when deleting last messages.
- [x] Chat polish: better initial loading/empty states, optimistic “(sending)” label for temporary message IDs, and an unread separator (from `Dialog.readMaxId`/`unreadCount`).
- [x] Client hooks: remove noisy `console.log` and improve `useQuery` dependency equality (length-aware).
- [x] Unread/read: call REST `readMessages` when a dialog is open and attached to bottom; update local dialog state (server skips realtime updates back to the same session). Sidebar unread indicator now also derives from `Chat.lastMsgId` vs `Dialog.readMaxId` for correctness on new messages.
- [x] New DM (Home): add remote user search via REST `searchContacts` (debounced) so you can start DMs outside of the “known users” cache.
- [x] Reply UX: clicking a reply preview scrolls to the referenced message (if loaded) and briefly highlights it.
- [x] Reply UX: if a reply target isn’t loaded yet, fetch older history around that message ID and then jump/highlight.
- [x] Message rendering: linkify `http(s)` URLs in message text (opens in a new tab).
- [x] Web build: avoid StyleX token alias resolution issues by switching a few `~/theme/tokens.stylex` imports to relative imports.
- [x] Sidebar: add `Archived` section (collapsible) and dialog actions menu per row (mark read/unread, archive/unarchive, pin/unpin).
- [x] Chat header: add archive + pin actions (pin disabled while archived).
- [x] Chat scroll: basic per-dialog scroll position restore (in-memory) so switching dialogs doesn’t snap to bottom.
- [x] Sending reliability: mark optimistic messages as `(failed)` on RPC failure and add a “Retry” action (reuses the same temp message id + randomId).
- [x] Sidebar: add basic search box to filter visible threads/DMs by title/name.
- [x] Threads: when opening a thread via deep link, sync the space picker search param (`spaceId`) to match the thread’s space.
