# Reply Threads v1 Gap Plan

Date: 2026-03-15
Inputs:
- `.agent-docs/2026-03-12-subthreads-plan-feedback-revision.md`
- `.agent-docs/2026-03-13-reply-threads-implementation-progress.md`
- current worktree in `server/`, `proto/`, `apple/InlineKit`, `apple/InlineIOS`, and `apple/InlineMac`

## Goal

Define what is still missing to call reply threads a solid v1 on both iOS and macOS, while preserving the current hidden-dialog architecture and avoiding churn in areas that are already structurally sound.

## Current Status Summary

### Server / data model

This area is in good shape for reply-thread v1:

- `chats.parent_chat_id` and `chats.parent_message_id` exist
- inherited access flows through `parent_chat_id`
- `createSubthread` exists and is idempotent for anchored reply threads
- linked subthreads create hidden dialogs on first open
- sidebar visibility is separated from dialog existence via `dialogs.sidebar_visible`
- parent messages expose `replies`
- reply summary realtime is centralized and currently piggybacks on parent `editMessage`
- reply summary refresh now covers create, send, unread/read changes, and delete

### Apple shared layer

This is mostly in place:

- `Chat` persists parent metadata
- `Message` persists `replies`
- hidden dialogs are filtered out of sidebar/home queries
- `chatOpen` is handled in realtime and sync
- `getChat` can open a thread without requiring a visible sidebar dialog
- `CreateSubthreadTransaction` exists and is already used by the shared Apple reply-thread open/create path

### macOS

macOS has the intended v1 shape:

- context menu has `Reply in Thread`
- parent message bubble shows a compact replies footer
- footer shows unread dot, reply count, and recent replier avatars
- footer opens the child thread
- child thread timeline prepends a `Replies` separator and anchor row

### iOS

iOS now has a low-risk v1 shape:

- context menu has `Reply in Thread`
- parent message bubble has a replies footer and tap-to-open
- child thread opens without requiring a visible sidebar row
- reply context is rendered inside the scrolling timeline model via a `Replies` separator + anchor context view
- replies footer now includes an explicit unread dot

## Status After Implementation

The originally identified v1 blockers are now closed:

- iOS reply-thread open/create flow is in place
- iOS reply summaries now render an explicit unread dot
- iOS reply context moved into the scrolling timeline model instead of an external top header
- both Apple app targets now compile successfully

What remains in this document is the residual follow-up surface after the v1 implementation phase, not missing core reply-thread functionality.

## Residual Gaps / Follow-ups

## Post-v1 hardening or parity work

### 1. iOS does not use a literal synthetic datasource row for the anchor

The original plan and product direction both converge on:

- `Replies` separator
- anchored parent message as an artificial first item in the child timeline

Current status:

- macOS prepends a separator + anchor item directly in the message timeline
- iOS now renders the reply context inside the scrolling timeline model via a global boundary supplementary view that contains the `Replies` separator and anchor context

Why this still matters:

- it is close to parity, but not literal parity
- if we later want identical scroll/selection/interaction semantics across Apple platforms, a true synthetic row model would be cleaner
- it still leaves some anchor-loading logic duplicated across surfaces

### 2. Anchor loading/presentation logic is still duplicated across Apple

Current state:

- iOS and macOS both work, but they do not share one `InlineKit` anchor-context source
- each platform still owns part of the anchor resolution/render lifecycle

This is no longer a v1 blocker, but it is still the main structural cleanup worth doing next if reply-thread UI evolves further.

## Product-scope follow-up, intentionally post-v1

### 3. The hidden-dialog model still lacks an explicit `Show in Sidebar` action/path

The model decision is already clear:

- linked reply-thread dialogs start hidden
- they promote when pinned, unarchived, or on received mention/reply
- they should also promote when the user explicitly chooses `Show in Sidebar`

Current status:

- the promotion logic is centralized server-side
- but there is no explicit API or client action yet for `Show in Sidebar`

This is not required for core reply-thread creation/open/view/send flows.
It is intentionally out of scope for reply-thread v1.

## Non-blocking cleanup

### 4. Old macOS floating-header file is still present but unused

`apple/InlineMac/Views/MessageList/ReplyThreadAnchorHeaderView.swift` is left over from the earlier macOS header approach and is no longer referenced by the live path.

This is cleanup, not a blocker.

## What Should Stay Out Of Reply-Thread v1

These are valid future directions, but they should not block v1:

- plain subthreads UI
- chat-level create/open UI for non-reply subthreads
- `getSubthreads`
- manual backlink/reference graph (`chat_links`)
- dedicated user-scoped reply-summary update instead of piggybacking on `editMessage`

## Confirmed v1 Boundary

Reply-thread v1 now means:

- right click / long press a message and create or open its reply thread
- open the child thread as a normal chat
- show reply summary under the parent message
- show unread dot in that summary on both Apple platforms
- render the anchor inside the child timeline model on both Apple platforms
- keep hidden-dialog semantics for durable state without flooding the sidebar

It does not require:

- generic subthreads UI
- reference links
- a new reply-summary update type

## Recommended Next Steps

### Phase A: Unify anchor loading behavior across Apple

- extract shared anchor reference / fetch / observation logic into `InlineKit`
- have both iOS and macOS consume the same shared anchor source
- keep only the row/view rendering platform-specific

### Phase B: Manual QA + cleanup

- manually QA:
  - create thread from a message
  - open existing thread from summary footer
  - unread dot changes after child unread/read transitions
  - anchor displays correctly after cold open and realtime updates
  - hidden thread stays out of sidebar until promotion trigger
- remove dead macOS header file after confirming no remaining references

## Bottom Line

The server/data model and Apple app targets are now in a good v1 state.
The main remaining work is follow-up hardening:

1. unify Apple anchor loading logic
2. manual QA of the end-to-end reply-thread UX
3. cleanup of the dead macOS floating-header file
