# Create Thread (macOS) Plan

## Goal
Create a new "Create Thread" page for macOS that opens from the sidebar "+ New thread" action. The action should create a private thread with only the current user and the title "Untitled", open it optimistically so the user can type immediately, and allow inline editing of the chat icon and title from the chat header.

## Key Findings (current code)
- Sidebar "New thread" routes to `Nav2Route.newChat`.
  - `apple/InlineMac/Features/Sidebar/MainSidebar.swift`
  - `apple/InlineMac/Features/Sidebar/MainSidebarHeader.swift`
- `Nav2Route.newChat` renders the existing create-chat form.
  - `apple/InlineMac/Features/MainWindow/MainSplitView+Routes.swift`
  - `apple/InlineMac/Views/NewChatScreen/NewChatVC.swift`
  - `apple/InlineMac/Views/NewChatScreen/CreateChatView.swift`
- Toolbar chat title and icon are display-only.
  - `apple/InlineMac/Toolbar/ChatTitleToolbar.swift`
- There is no RPC for updating chat title or emoji.
  - `proto/core.proto`
  - `server/src/functions/messages.updateChatVisibility.ts`

## Plan

### 1) Routing and entry points
- Add a dedicated route for the new page.
  - Update `apple/InlineMac/App/Nav2.swift` with `case createThread` (or rename `newChat` to `createThread` if preferred).
- Wire the sidebar "New thread" action to the new route.
  - `apple/InlineMac/Features/Sidebar/MainSidebar.swift` -> `handleNewThread`
  - `apple/InlineMac/Features/Sidebar/MainSidebarHeader.swift` -> `openNewThread`
- Map the new route to a new view controller.
  - `apple/InlineMac/Features/MainWindow/MainSplitView+Routes.swift`

### 2) New Create Thread page
- Add a new view/controller that does not show the old CreateChat form.
  - `apple/InlineMac/Views/NewChatScreen/CreateThreadView.swift`
  - `apple/InlineMac/Views/NewChatScreen/CreateThreadVC.swift` (if AppKit wrapper needed)
- On appear, it should:
  - Create an optimistic private thread with title "Untitled" and participants = [currentUserId].
  - Navigate to/open the chat immediately.
  - Kick off the real `createChat` RPC in the background.

### 3) Optimistic creation and reconciliation
- Add a helper to create a local optimistic thread.
  - Likely in `apple/InlineKit/Sources/InlineKit/DataManager.swift`
  - Uses existing models `Chat` and `Dialog`:
    - `apple/InlineKit/Sources/InlineKit/Models/Chat.swift`
    - `apple/InlineKit/Sources/InlineKit/Models/Dialog.swift`
- Use a temporary local chat ID (negative or high-range) to avoid collisions.
- Save:
  - `Chat(type: .thread, title: "Untitled", isPublic: false, spaceId: activeSpaceId, emoji: nil)`
  - `Dialog(optimisticForChat: chat)`
- Run the real request:
  - `apple/InlineKit/Sources/InlineKit/Transactions2/CreateChatTransaction.swift`
  - Inputs: title = "Untitled", isPublic = false, participants = [currentUserId]
- When server responds:
  - Save real chat + dialog (transaction already does this).
  - Migrate draft from temp dialog to real dialog.
  - Remove the optimistic temp chat/dialog.
  - Navigate to `.chat(peer: .thread(realId))` via `nav2`.
- Failure handling:
  - Remove optimistic chat/dialog.
  - Show error overlay via `OverlayManager`.
  - Navigate back or leave user in previous chat.

### 4) Immediate typing behavior
- Two possible strategies (pick one):
  - A) Open ChatView immediately on the optimistic peer and allow typing; block send until real ID exists.
  - B) A minimal create-thread page that has a compose field and caches text, then opens real chat when created.
- If A:
  - `apple/InlineMac/Views/ChatView/ChatViewAppKit.swift` handles optimistic state.
  - `apple/InlineMac/Views/Compose/ComposeAppKit.swift` blocks sending until chatId is real.
  - Draft migration uses `apple/InlineKit/Sources/InlineKit/Drafts.swift`.

### 5) Editable title and icon in toolbar
- Make the chat title inline-editable in the toolbar.
  - `apple/InlineMac/Toolbar/ChatTitleToolbar.swift`
  - Replace static label with editable field on click; support Enter to save and Esc to cancel.
- Make the chat icon editable.
  - Add click handling to `ChatIconView` (inside ChatTitleToolbar).
  - Use system emoji picker (`showEmojiAndSymbols:`) or reuse the simple picker UI from `CreateChatView`.

### 6) Add update-chat RPC (title + emoji)
- Add a new RPC to update chat info:
  - `proto/core.proto`: `UpdateChatInfoInput`, `UpdateChatInfoResult`
  - `server/src/functions/messages.updateChatInfo.ts`
  - `server/src/realtime/handlers/_rpc.ts`
- Regenerate protos:
  - `bun run generate:proto`
  - `bun run proto:generate-swift`
- Apply updates on client:
  - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift` -> persist to DB

### 7) Validate sidebar + cache updates
- Ensure DB update triggers UI refresh (ObjectCache observes Chat updates).
  - `apple/InlineKit/Sources/InlineKit/ObjectCache/ObjectCache.swift`
  - `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift`

### 8) Tests and verification
- Server tests for update-chat info (permissions, broadcast).
- Client manual checks:
  - New thread action opens immediately with title "Untitled".
  - Title/icon edits persist and update sidebar + toolbar.
  - Failure cleanup removes optimistic stub.

## Open Questions
1) Should inline title/icon editing be available for all chats, or only newly created threads?
2) Is empty title allowed, or should it normalize to "Untitled"?
3) Which immediate-typing strategy do you want (Option A vs B in step 4)?
4) Should the old CreateChat form remain for public threads, or be replaced entirely?

## Production Readiness
Not production-ready until the new update-chat RPC and optimistic creation flow are fully implemented and tested.
