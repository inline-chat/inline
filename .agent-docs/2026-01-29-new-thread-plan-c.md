# New Thread (Plan C: Server-first, then open)

Date: 2026-01-29

## Goal
Implement a new "New Thread" workflow that creates the thread on the server first, then opens the real chat. No optimistic chat records.

## Constraints
- New UI only (Nav2 + new sidebar + CMD+K).
- Server requires non-empty title and participants for private threads.
- Home public threads unsupported.

## High-level flow
1) User triggers "New Thread" from sidebar or CMD+K.
2) Show a lightweight create screen/state (spinner + "Creating thread...").
3) Call `CreateChatTransaction` with:
   - title: "Untitled" (placeholder)
   - isPublic: false
   - participants: [currentUserId]
   - spaceId: active space when applicable
4) On success, navigate to `.chat(peer: .thread(realId))`.
5) On failure, show overlay error and return to previous route.

## UI entry points (new UI only)
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift`
- `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift`
- `apple/InlineMac/Features/Sidebar/MainSidebar.swift` / `MainSidebarHeader.swift` (new UI actions)

## Routing
- Add a dedicated Nav2 route for server-first create state, e.g. `.createThread`.
- Map the route to a simple view/controller that triggers create on appear.

## Client implementation detail
- Use `CreateChatTransaction` (Transaction2).
- Ensure title fallback is "Untitled" for empty titles in list UI.
  - `apple/InlineMac/Features/Sidebar/ChatListItem.swift`

## Error handling
- Use `OverlayManager` to show failures.
- Ensure no partial state persists (no optimistic records).

## Follow-ups (not in Plan C)
- Compose-first flow (Option E).
- Optimistic stub with send disabled (Option A).
- Mentions auto-add and participants toolbar prompt.

## Verification checklist
- "New Thread" creates a private thread with current user.
- Sidebar shows new thread with title "Untitled".
- On error, user is returned to prior chat and sees a toast/overlay.

## Open questions
- Do we need a visible "Creating" screen or just a transient spinner?
- Should we allow user to cancel during creation?
