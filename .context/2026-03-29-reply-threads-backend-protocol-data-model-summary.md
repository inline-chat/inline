# Reply Threads: Backend/Protocol/Data Model Summary

Date: 2026-03-29

## 1) Core relationship model

Reply threads are modeled as **linked child chats** (subthreads), not as inline message-only reply chains.

- Parent thread/chat: `chats.id = parent_chat_id`
- Anchor parent message: `(messages.chat_id, messages.message_id) = (parent_chat_id, parent_message_id)`
- Child reply thread chat: `chats.id`

A chat is a reply thread when:
- `chats.parent_chat_id IS NOT NULL`
- `chats.parent_message_id IS NOT NULL`

A linked subthread without `parent_message_id` is still structurally parented, but only message-anchored ones are “reply threads”.

## 2) Backend schema constraints (server)

Server schema (`server/src/db/schema/chats.ts`, drizzle migration `0065_add_reply_threads.sql`) enforces:

- `chats.parent_chat_id -> chats.id` FK
- `(chats.parent_chat_id, chats.parent_message_id) -> (messages.chat_id, messages.message_id)` FK
- `UNIQUE(parent_chat_id, parent_message_id)` to guarantee one reply thread per parent message
- Check: `parent_message_id` implies `parent_chat_id`
- Index: `chats_parent_chat_id_idx`

## 3) Protocol shape

`proto/core.proto` key fields:

- `Chat.parent_chat_id` and `Chat.parent_message_id`
- `Message.replies` (`MessageReplies`) for parent-message summary:
  - `chat_id` (child thread id)
  - `reply_count`
  - `has_unread`
  - `recent_replier_user_ids`

RPC methods:

- `createSubthread(CreateSubthreadInput)`
  - input: `parent_chat_id`, optional `parent_message_id`, optional title/description/emoji/participants
  - result: `chat`, `dialog`, `anchor_message`
- `getChat(GetChatInput)`
  - result includes `anchor_message`
- `showChatInSidebar(ShowChatInSidebarInput)`
  - used to promote hidden dialogs into sidebar-visible state

Updates:

- `UpdateChatOpen` carries `chat` + `dialog` (+ optional `user`) when a chat becomes sidebar-visible for a user
- Parent message summary refresh is delivered via `UpdateEditMessage` with updated `message.replies`

## 4) Backend runtime behavior

`messages.createSubthread`:

- Validates parent chat access and optional anchor message existence.
- Idempotent for anchored reply threads via `(parent_chat_id, parent_message_id)` lookup/unique constraint.
- Creates child chat inheriting parent access model.
- Materializes requester dialog with `sidebar_visible = false` for linked subthreads.
- Emits parent summary update (`message.replies`) when anchored.

Reply summary computation lives in `server/src/modules/subthreads.ts` (`getMessageRepliesMap`).

## 5) Sidebar visibility architecture

Reply-thread dialogs are intentionally created hidden first:

- `dialogs.sidebar_visible = false` means:
  - chat can still be opened directly
  - should not appear in sidebar lists
- Promotion path:
  - RPC `showChatInSidebar`
  - or update `UpdateChatOpen` from server

This allows per-user discoverability without polluting sidebar with every linked reply thread.

## 6) Apple local data model mapping

Local chat model (`InlineKit`) now mirrors server/proto linkage:

- `Chat.parentChatId`
- `Chat.parentMessageId`
- `Chat.isReplyThread` derived from `parentMessageId != nil`

Local dialog model now mirrors visibility state:

- `Dialog.sidebarVisible`

Local DB migrations (Apple):

- `chat.parentChatId`, `chat.parentMessageId`
- `dialog.sidebarVisible`

Update handling now applies `UpdateChatOpen` by persisting user/chat/dialog payloads.

## 7) End-to-end create/open flow (macOS current)

For “Reply in Thread” UI:

1. Call `createSubthread(parentChatId, parentMessageId)`
2. Persist returned `chat/dialog/anchor_message`
3. Fetch `getChat(peer: child)` and `getChatHistory(peer: child)`
4. Navigate into child chat

Sidebar lists filter out `dialog.sidebarVisible == false` (NULL treated as visible for backward compatibility).

## 8) Practical implications

- Reply threads are real chats with their own history/unread/dialog state.
- Parent timeline can show compact reply summary using `message.replies`.
- Hidden-by-default dialogs keep reply-thread UX discoverable from message context, not from immediate sidebar fan-out.
