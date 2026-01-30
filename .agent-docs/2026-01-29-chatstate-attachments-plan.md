# Plan: Move Compose Attachments into ChatState

## Goal
Make ChatState the single source of truth for compose attachments, with draft persistence via lightweight refs, and remove the pending-drop queue.

## Plan
- Define attachment state model in ChatState: in-memory `AttachmentItem` list for UI speed + persisted `DraftAttachmentRef` list for drafts.
- Add ChatState APIs and publishers for add/remove/clear, and for loading attachments from persisted refs.
- Update ComposeAppKit to render from ChatState and mutate it (remove local `attachmentItems`).
- Update sidebar drop to write attachments into ChatState (and draft refs) before navigation; remove PendingDropAttachments usage.
- Persist draft refs (ChatStateData or dialog draft field) and rehydrate attachments from DB media rows; handle missing items safely.
- Cleanup: remove pending queue + notifications, verify send/clear behavior, add manual test checklist.

## Notes
- Persist only lightweight refs (kind + mediaId). Keep full FileMediaItem in-memory.
- Media IDs should align with message linkage (photoId/videoId/documentId), which are stable even for local temp media (negative IDs).
