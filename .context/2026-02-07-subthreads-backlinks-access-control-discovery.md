# Subthreads: Backlinks + Access Control + Discoverability (Spec) (2026-02-07)

From notes (Feb 7, 2026): "spec out subthreads with backlinks + better access control and new discoverability".

This is a product + architecture spec. It is intentionally explicit about tradeoffs because subthreads create long-lived complexity in permissions, navigation, and syncing.

## Problem

Threads today are the primary unit of conversation (chats). When a conversation branches, users need:
- a focused place for a sub-topic,
- a durable link back to the origin (backlink),
- optional restricted access (private side discussion), and
- a way to discover subthreads without cluttering the main chat list.

## Goals

- Create a "subthread" from a message or chat context.
- Subthread has a durable backlink to the parent message (and optionally parent chat).
- Permissions are safe by default, with an option to restrict access to a subset.
- Discoverability is strong in-context (from the parent message/chat), without flooding the main sidebar.

## Non-Goals (Initial)

- Deep nesting (subthread of subthread) as a first release.
- Public internet share links.
- Migrating existing messages into subthreads.

## Definitions

- Parent chat: the chat in which the originating message lives.
- Parent message: the specific message that spawned the subthread.
- Subthread chat: a normal chat object with a pointer back to parent (new fields).

## Data Model Proposal

### Chat table additions

Add optional fields to `chats`:
- `parent_chat_id` (nullable)
- `parent_message_id` (nullable)
- `root_chat_id` (nullable; for future nesting and fast grouping)
- `kind` or `chat_type` extension: either keep existing thread type and treat subthread as a thread with parent pointers, or add explicit `CHAT_TYPE_SUBTHREAD` (recommended for clarity).

Indexes:
- `(parent_chat_id, parent_message_id)` for listing subthreads for a message.
- `(parent_chat_id)` for listing subthreads for a chat.

### Message backlink fields (optional)

We can avoid new message fields initially if the backlink is stored on the subthread chat.
If we want fast rendering on the parent message, add a derived counter:
- `message_subthread_count` (denormalized; optional later)

## Permission Model (Access Control)

### Default behavior

- Subthread inherits parent chat visibility:
- Subthread inherits parent chat visibility. If parent is a private thread (participants-based), subthread participants default to the same set. If parent is a public space thread, subthread defaults to public space thread.

### Restricted subthread ("private side discussion")

Allow creating a subthread with explicit participants:
- Participants must be members of the space if parent is a space chat, and must always include the creator.

Visibility semantics:
- Only participants can read subthread messages.
- Non-participants should not learn content, but discoverability needs a decision:
Option A: subthread existence is hidden (strong privacy). Option B: show stub existence ("Private subthread") but no access (more discoverable). Recommendation: Option A initially (simpler and safer).

## API / Protocol Design

### New RPCs

1. `messages.createSubthread`
Input:
- `parent_chat_id`
- `parent_message_id`
- `title` (optional; default generated)
- `emoji` (optional)
- `visibility` enum: inherit, public_in_space, private_participants
- `participants` (optional; required for private)

Result:
- `subthread_chat`
- optionally "context" fields for UI: parent message excerpt, parent chat title

2. `messages.getSubthreadsForMessage`
Input:
- `parent_chat_id`
- `parent_message_id`

Result:
- list of subthread chats the user can access

### New updates

Add an update that links parent -> subthread:
- `UpdateSubthreadCreated` (includes parent ids + subthread chat summary)

Purpose:
- Parent chat can update UI immediately to show "subthread exists".

## UI/UX Proposal

### Creating a subthread

Entry point:
- Context menu on a message: "Start subthread"

Flow:
1. Choose visibility (inherit/public/private).
2. If private: choose participants.
3. Create and navigate into the subthread.

### Parent chat UI

On the parent message:
- Show a small "subthread" affordance (icon + count, or "1 subthread").
- Clicking opens a subthread list (if multiple) or navigates directly (if one).

In Chat Info:
- Add "Subthreads" section listing recent subthreads.

### Subthread UI

- Always show a "Back to parent" header:
- Always show a "Back to parent" header with parent chat name and an excerpt of the parent message; clicking returns to the parent message (go-to-message flow required).

## Discoverability Rules

- Subthreads should not appear in the main sidebar list by default.
- They appear:
They appear via the parent message affordance, in Chat Info list, and via search results (optional, later).

## Implementation Plan (Phased)

Phase 1 (server + proto + minimal UI):
- Add schema fields.
- Add `createSubthread` and `getSubthreadsForMessage`.
- Add `UpdateSubthreadCreated`.
- macOS/iOS: add message context menu item and basic subthread view with backlink header.

Phase 2 (UX polish + performance):
- Add message-level subthread count caching if needed.
- Add subthread list UI in parent message popover.
- Add search and keyboard shortcuts.

Phase 3 (advanced):
- Nested subthreads via `root_chat_id`.
- Stubs for private subthread existence (if desired).
- Cross-space linking constraints.

## Testing Plan

Server:
- Permission tests:
Creator can create private subthread with selected participants; non-participant cannot fetch/list/access.
- Update tests:
Participants receive `UpdateSubthreadCreated`.

Client manual:
- Create subthread in a public space thread and in a private participants thread.
- Verify backlink header navigates to parent message (requires go-to-message reliability work).
- Verify non-participants cannot discover/access (if Option A).

## Risks / Tradeoffs

- Backlink navigation depends on go-to-message reliability; implement that first or in parallel.
- Access control mistakes are security bugs; server must be the source of truth.
- Too much discoverability can clutter; too little makes the feature invisible. Default should bias toward in-context discoverability.

## Open Questions

- Do we want subthreads to be first-class chats in the sidebar for participants? (Probably not at first.)
- Do we want private subthreads to be visible as stubs to non-participants? (Default no.)
