# New Thread (Optimistic) - Findings & Draft Plan

Date: 2026-01-28

## Goal (user request)
- No separate “new thread page”; create a new transaction that creates a thread optimistically and opens chat.
- Entry points: Quick Search “New Thread” + new main sidebar “New Thread” action (new UI only).
- Space vs home: if active space, create space thread; if home, create home thread.
- Mention auto-add: in private chat, if user @ mentions someone and lastMsgId < 5, auto-add; otherwise show prompt in participants toolbar (popover). Use NotificationCenter to communicate.
- Sidebar should show “Untitled” when title missing.

## Key constraints discovered
- Server `createChat` enforces: title required; for space threads, private requires participants; for home threads, participants required and public home threads unsupported.
- Proto `CreateChatInput.title` is required (string). Cannot be empty; must send placeholder (e.g., "Untitled") to satisfy server while UI can display "Untitled" on nil/empty.
- New UI uses `Nav2` routes; old UI uses `Nav` and `NewChatViewController`.

## Existing client primitives
- `CreateChatTransaction` exists (Transaction2) but **no optimistic()** implementation.
- `Dialog(optimisticForChat:)` exists and `UpdateNewChat.apply` also creates dialog optimistically.
- `ChatsViewModel` (new UI sidebar) uses DB observations:
  - Home: `HomeChatItem.all()` filtered to `space == nil` and `chat != nil`.
  - Space: `Dialog.spaceChatItemQuery()` filtered by spaceId.
- `ChatListItem.displayTitle` falls back to `"Chat"` (needs `"Untitled"`).
- `ChatParticipantsWithMembersViewModel` for private threads fetches participants only; mention UI would not suggest space members in a brand new private thread unless we add them.
- `ComposeAppKit.send()` extracts mention entities via `ProcessEntities.fromAttributedString`.

## Feasibility: true optimistic UI
- Feasible by inserting a temp Chat + Dialog + ChatParticipant for current user in GRDB.
- Chat IDs can be negative (pattern used by messages: temporaryMessageId = -randomId).
- Dialog IDs are derived from peer ID; negative chat IDs yield negative dialog IDs (allowed).
- Must delete/replace optimistic rows once server responds.
- **Important UX risk:** if we open chat immediately with temp chatId, sending messages will fail unless we gate send or migrate.

## Open decision (blocking)
- **Option A (recommended):** open optimistic chat immediately but disable sending until real chat ID arrives, then navigate to real chat.
- **Option B:** allow sending and implement migration from temp chatId to real chatId (complex).

## Proposed implementation (pending decision)
1. Add a new Transaction2 (e.g., `CreateThreadTransaction`):
   - `optimistic()`: create temp Chat (negative ID), Dialog(optimisticForChat:), ChatParticipant for current user, save in DB.
   - `apply()`: delete optimistic rows, save real Chat/Dialog, insert participants (and current user if private).
   - `failed()`: remove optimistic rows.
2. Update new UI entry points:
   - Quick Search “New Thread” command -> run new transaction and open chat (new UI only).
   - MainSidebar action item `.newThread` -> same flow (new UI only).
3. Title handling:
   - `ChatListItem.displayTitle` fallback to `"Untitled"` for nil/empty title.
4. Mention auto-add:
   - In `ComposeAppKit.send()`, inspect `entities` for mentions, if private thread + `lastMsgId < 5` -> auto add participants via `.addChatParticipant`.
   - If `lastMsgId >= 5`, post NotificationCenter with suggested user(s).
5. Participants toolbar prompt:
   - Add new small popover in `ParticipantsToolbarButton` that listens to NotificationCenter.
   - Popover shows avatar, name, primary “Add” button (`InlineButton` primary style) to call `.addChatParticipant`.

## Files likely to change
- `apple/InlineKit/Sources/InlineKit/Transactions2/*` (new transaction)
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift`
- `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift`
- `apple/InlineMac/Features/Sidebar/ChatListItem.swift`
- `apple/InlineMac/Views/Compose/ComposeAppKit.swift`
- `apple/InlineMac/Toolbar/Participants/ParticipantsToolbarButton.swift`
- `apple/InlineMac/Utils/Notifications.swift` (new Notification.Name)

## Notes
- New UI only; do not touch old UI CreateChat.
- Ensure no `.env` access.
- Use `NotificationCenter.default` for prompt payloads.
