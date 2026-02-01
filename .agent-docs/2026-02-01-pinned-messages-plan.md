# Pinned Messages Plan (2026-02-01)

## Requirements
- Multi-pinned messages in backend; UI shows latest pinned only.
- All members can pin in DM/public/private chats.
- Pin/unpin updates must participate in update sequence.
- Pinned header shows previous pinned after unpin (stack behavior).
- If pinned message content is missing, show "Pinned message unavailable".
- Embed view sits under chat header without breaking glass/gradient styling.

## Plan
1. [x] Protocol + update types
   - Add RPC method for pin/unpin message and result type.
   - Add `UpdatePinnedMessages` in core.proto and a matching server update in server.proto.
   - Ensure update carries ordered pinned message IDs.
2. [x] Server + DB
   - Add pinned metadata to messages (boolean + pinned_at timestamp) to support ordering.
   - Implement pin/unpin handler with membership checks; update pinned_at, insert update, bump chat updateSeq/lastUpdateDate.
   - Emit realtime `UpdatePinnedMessages` to participants.
   - Add/get pinned list from DB (ordered).
3. [x] Sync + persistence (InlineKit)
   - Add local pinned table (chat_id, message_id, position/pinned_at) for missing-message placeholders.
   - Apply `UpdatePinnedMessages` to pinned table and update bucket states.
4. [x] Apple clients (macOS + iOS)
   - Context menu Pin/Unpin using new transaction.
   - Pinned header embed under chat header; close unpins and reveals previous; tap scrolls to message.
   - Ensure background uses blur/glass/gradient-safe container.
5. [x] Web client
   - Data layer updates to store pinned message IDs and apply updates.
6. [ ] Tests / validation
   - Backend update sequence tests + pinned list ordering.
   - Smoke tests across DM/public/private.

## Notes
- UI shows most recent pinned; unpin reveals previous.
- Placeholder text: "Pinned message unavailable" when message content missing.
