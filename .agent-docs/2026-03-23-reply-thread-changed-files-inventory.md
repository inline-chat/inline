# Reply Thread Feature File Inventory

This inventory is based on:
- committed reply-thread backend/protocol work in `35084fb3`, `13904988`, and `24f8bc28`
- current worktree files that still contain reply-thread UI/client changes

## Committed Backend / Protocol Files

### Protocol
- `packages/protocol/src/server.ts`
- `proto/server.proto`

### Server migrations / schema
- `server/drizzle/0065_add_reply_threads.sql`
- `server/drizzle/0066_add_dialog_sidebar_visibility.sql`
- `server/drizzle/meta/0065_snapshot.json`
- `server/drizzle/meta/0066_snapshot.json`
- `server/drizzle/meta/_journal.json`
- `server/src/db/models/chats.ts`
- `server/src/db/schema/chats.ts`
- `server/src/db/schema/dialogs.ts`

### Server functions / modules / realtime
- `server/src/functions/messages.createSubthread.ts`
- `server/src/functions/messages.deleteMessage.ts`
- `server/src/functions/messages.getChat.ts`
- `server/src/functions/messages.getChatHistory.ts`
- `server/src/functions/messages.getChats.ts`
- `server/src/functions/messages.getMessages.ts`
- `server/src/functions/messages.markAsUnread.ts`
- `server/src/functions/messages.readMessages.ts`
- `server/src/functions/messages.searchMessages.ts`
- `server/src/functions/messages.sendMessage.ts`
- `server/src/functions/messages.showChatInSidebar.ts`
- `server/src/functions/messages.updateDialogNotificationSettings.ts`
- `server/src/methods/getDialogs.ts`
- `server/src/methods/updateDialog.ts`
- `server/src/modules/authorization/accessGuards.ts`
- `server/src/modules/message/unarchiveIfNeeded.ts`
- `server/src/modules/subthreads.ts`
- `server/src/modules/updates/index.ts`
- `server/src/modules/updates/sync.ts`
- `server/src/realtime/encoders/encodeChat.ts`
- `server/src/realtime/encoders/encodeDialog.ts`
- `server/src/realtime/encoders/encodeMessage.ts`
- `server/src/realtime/handlers/_rpc.ts`
- `server/src/realtime/handlers/messages.createSubthread.ts`
- `server/src/realtime/handlers/messages.getChat.ts`
- `server/src/realtime/handlers/messages.showChatInSidebar.ts`

### Server tests
- `server/src/__tests__/functions/deleteMessage.test.ts`
- `server/src/__tests__/functions/getChat.test.ts`
- `server/src/__tests__/functions/getChats.test.ts`
- `server/src/__tests__/functions/markAsUnread.test.ts`
- `server/src/__tests__/functions/messages.createSubthread.test.ts`
- `server/src/__tests__/functions/messages.showChatInSidebar.test.ts`
- `server/src/__tests__/functions/sendMessage.test.ts`
- `server/src/__tests__/functions/updateDialogNotificationSettings.test.ts`
- `server/src/__tests__/functions/updates.getUpdates.test.ts`
- `server/src/__tests__/methods/updateDialog.test.ts`
- `server/src/__tests__/modules/syncFlow.test.ts`

## Current Reply-Thread UI / Client Candidate Files

### iOS UI
- `apple/InlineIOS/Features/Chat/ChatView+extensions.swift`
- `apple/InlineIOS/Features/Chat/ChatView.swift`
- `apple/InlineIOS/Features/Chat/ChatViewUIKit.swift`
- `apple/InlineIOS/Features/Chat/CollectionViewLayout.swift`
- `apple/InlineIOS/Features/Chat/MessageCell.swift`
- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
- `apple/InlineIOS/Features/Chat/ReplyThreadAnchorHeaderView.swift`
- `apple/InlineIOS/Features/Chat/ReplyThreadContextSupplementaryView.swift`
- `apple/InlineIOS/Features/Message/UIMessageView+extensions.swift`
- `apple/InlineIOS/Features/Message/UIMessageView.swift`

### Shared Apple / InlineKit
- `apple/InlineKit/Sources/InlineKit/Database.swift`
- `apple/InlineKit/Sources/InlineKit/Models/Chat.swift`
- `apple/InlineKit/Sources/InlineKit/Models/Dialog.swift`
- `apple/InlineKit/Sources/InlineKit/Models/Message.swift`
- `apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolMessageReplies.swift`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/CreateSubthreadTransaction.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatTransaction.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/ShowChatInSidebarTransaction.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/TransactionTypeRegistry.swift`
- `apple/InlineKit/Sources/InlineKit/Utils/ReplyThreads.swift`
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift`
- `apple/InlineKit/Sources/InlineKit/ViewModels/HomeViewModel.swift`
- `apple/InlineKit/Sources/InlineKit/ViewModels/ShowInSidebarState.swift`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`
- `apple/InlineKit/Tests/InlineKitTests/ReplyThreadModelsTests.swift`

### Apple generated protocol
- `apple/InlineKit/Sources/InlineProtocol/client.pb.swift`
- `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`

### macOS UI
- `apple/InlineMac/Features/MainWindow/MainSplitView+Routes.swift`
- `apple/InlineMac/Features/Toolbar/MainToolbar.swift`
- `apple/InlineMac/Views/Chat/SidebarChatIcon.swift`
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MessageViewTypes.swift`
- `apple/InlineMac/Views/Message/MinimalMessageView.swift`
- `apple/InlineMac/Views/Message/ReplyThreadFooterView.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/MessageList/ReplyThreadAnchorHeaderView.swift`

### Current protocol/core candidates tied to Apple UI
- `packages/protocol/src/core.ts`
- `packages/protocol/src/server.ts`
- `proto/core.proto`
- `proto/server.proto`

## Mixed Files Requiring Hunk-Level Separation

These files are currently risky because reply-thread work may be interleaved with newer unrelated edits:
- `apple/InlineIOS/Features/Chat/ChatView.swift`
- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
- `apple/InlineIOS/Features/Message/UIMessageView.swift`
- `apple/InlineKit/Sources/InlineKit/Database.swift`
- `apple/InlineKit/Sources/InlineKit/Models/Message.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatTransaction.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/TransactionTypeRegistry.swift`
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MinimalMessageView.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `packages/protocol/src/core.ts`
- `proto/core.proto`

## Intended Branch-Out Scope

The intended isolation scope is reply-thread UI/client work only:
- Apple UI and InlineKit changes for viewing/opening/creating reply threads
- supporting Apple-generated protocol / core schema hunks needed for that UI

Not in scope for the reply-UI branch:
- committed backend/protocol server work already landed
- Notion changes
- message actions work
- unrelated slash-command, upload, translation, or formatting changes
