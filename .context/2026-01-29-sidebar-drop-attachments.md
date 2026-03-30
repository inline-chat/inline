# Summary

- Added drag/drop handling to new sidebar chat items to highlight on hover and accept file/image/video drops, routing them into a pending-attachment queue and navigating to the chat.
- Introduced a lightweight pending attachment store to bridge sidebar drops to the chat view when the compose UI is ready.
- Wired ChatViewAppKit to consume pending attachments on load and on notification, and added a compose helper to apply pasteboard attachments uniformly.

# Files Touched

- apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift
- apple/InlineMac/Views/ChatView/ChatViewAppKit.swift
- apple/InlineMac/Views/Compose/ComposeAppKit.swift
- apple/InlineMac/Views/Compose/PendingDropAttachments.swift

# TODO

- Rework pending attachment storage by adding attachment support to chat state and draft persistence, so drops are inserted into draft/state and automatically appear after navigation without a global pending queue.
