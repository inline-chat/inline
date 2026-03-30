# Reply Threads: High-Level Context

## Feature summary
- Reply threads are real child chats linked to a parent chat + parent message, not inline-only reply chains.
- Backend enforces one anchored reply thread per parent message (`UNIQUE(parent_chat_id,parent_message_id)`).
- Dialogs for linked subthreads start hidden (`sidebar_visible=false`) and appear in sidebar only after promotion.
- Protocol carries both thread linkage (`Chat.parent_*`) and parent-message summary (`Message.replies`).

## Key files (backend + client)
- Backend schema/runtime: `server/src/db/schema/chats.ts`, `server/src/db/migrations/0065_add_reply_threads.sql`, `server/src/functions/messages/createSubthread.ts`, `server/src/modules/subthreads.ts`
- Protocol: `proto/core.proto`
- Apple data/transactions: `apple/InlineKit/Sources/InlineKit/Models/Chat.swift`, `apple/InlineKit/Sources/InlineKit/Models/Dialog.swift`, `apple/InlineKit/Sources/InlineKit/Transactions2/CreateSubthreadTransaction.swift`, `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatTransaction.swift`, `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- Apple UI/nav: `apple/InlineMac/Views/Message/MessageView.swift`, `apple/InlineMac/Views/Message/MinimalMessageView.swift`, `apple/InlineMac/Toolbar/ChatTitleToolbar.swift`, `apple/InlineMac/Views/Chat/ChatIcon.swift`, `apple/InlineMac/Views/Chat/SidebarChatIcon.swift`

## Key data models
- Server `chats`: `parent_chat_id`, `parent_message_id` (FKs + uniqueness).
- Server `dialogs`: `sidebar_visible` (discoverability/promotion state).
- Protocol `Chat`: `parent_chat_id`, `parent_message_id`.
- Protocol `Message.replies`: `chat_id`, `reply_count`, `has_unread`, `recent_replier_user_ids`.
- Apple `Chat`: `parentChatId`, `parentMessageId`, `isReplyThread`.
- Apple `Dialog`: `sidebarVisible`.

## How it works (runtime)
- User triggers **Reply in Thread** on a message.
- Client fast-opens only if local `Chat + Dialog` already exist for `(parentChatId,parentMessageId)`.
- Otherwise client creates/fetches (`createSubthread` -> `getChat` -> `getChatHistory`) then navigates.
- Parent message summary comes from backend via `Message.replies` updates; sidebar visibility is controlled by promotion (`showChatInSidebar` / `UpdateChatOpen`).

## Already in place
- End-to-end create/open path implemented on macOS context menu (DMs + threads).
- RealtimeV2 transaction added for `createSubthread`; `getChat` persistence includes dialog + anchor message.
- Local DB/schema updated for reply-thread linkage and sidebar visibility.
- Sidebar filtering centralized so hidden reply-thread dialogs stay out unless promoted.
- Reply-thread icon/title behavior updated (reply symbol + parent-thread footer context).
