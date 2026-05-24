# Dialog Sidebar Fractional Order Plan

## Goal

Persist user-controlled dialog ordering with fractional index strings, make sidebar ordering local-first and stable, and add reorder support for sidebar items. Keep pinned chats independently orderable. Stop using `opened_at` / `openedDate` as the sidebar order source.

`@` mention indicators are intentionally out of scope for this pass.

## References

- Liveblocks: https://liveblocks.io/blog/how-crdts-and-sync-engines-keep-realtime-lists-ordered-with-fractional-indexing
- Figma: https://www.figma.com/blog/realtime-editing-of-ordered-sequences/

Both references point to the same practical model: give each item a sortable position value, order by that value, and generate a new value between neighboring items for inserts/reorders. Figma stores arbitrary-precision fractional positions as strings; Liveblocks calls out the practical benefit of lexicographically sortable string indices and notes key-growth concerns for repeated end inserts.

## Current State

- `openedDate` is currently part of the protobuf contract, Swift model, GRDB schema, server schema, encoders, open transaction, tests, and sidebar sort.
- `UpdateDialogOpenTransaction` sets `openedDate = Date()` optimistically when transitioning a dialog to open.
- The server also writes `openedDate` from `dialogOpenDefaultsForChat`, `dialogOpenFieldsForOpen`, and `setDialogOpenForUsers`.
- The macOS sidebar currently sorts pinned items first, then normal opened items by `openedDate asc`, with ID-based stable fallback.
- Pinned items are visible even if they are not open.

## Data Model

Use two nullable fractional index fields on `dialog`:

- `sidebarOrder: String?` for non-pinned open sidebar rows.
- `pinnedOrder: String?` for pinned rows.

This is cleaner than a single field because pinned and non-pinned rows are separate lanes. A dialog can keep its normal open order while pinned, and keep its pinned order after unpinning for possible future restore. Sorting can then be:

1. pinned rows ordered by `pinnedOrder`
2. separator
3. open non-pinned rows ordered by `sidebarOrder`

Fallbacks are still required during rollout:

- Pinned rows missing `pinnedOrder` fall back to current stable ID ordering.
- Open rows missing `sidebarOrder` fall back to stable ID ordering until they are reopened or reordered.
- No local/server backfill is needed for this pass because `open` has not shipped broadly.

`openedDate` becomes deprecated rather than immediately deleted. We should stop using it for sorting after the new fields exist, but keep the proto field number and DB column through at least one compatibility window.

## Fractional Index Implementation

Add a tiny deterministic implementation in both Swift and TypeScript:

- `between(left: String?, right: String?) -> String`
- `before(first: String?) -> String`
- `after(last: String?) -> String`
- `sequence(count:) -> [String]` for migrations/backfill

Use a lexicographically sortable ASCII-safe alphabet. We should prefer a small, well-tested implementation over pulling a dependency. Keep the alphabet identical between Swift and TypeScript and cover it with fixture tests shared conceptually across both languages.

Initial implementation can be simple:

- empty list returns a middle key
- append uses a key after the last key
- prepend uses a key before the first key
- move/reorder computes a key between the new previous and next neighbors

If key length gets too large, add a later compaction pass that rewrites keys in one lane and broadcasts normal dialog updates. That is not needed for the first reorder feature.

## Protocol

Add fields to `Dialog`:

- `optional string order = 14;`
- `optional string pinned_order = 15;`

Keep:

- `optional int64 opened_date = 12;`

Mark `opened_date` as deprecated in comments only for now. Do not reuse or remove field 12.

For reordering, add a focused request/result rather than overloading the open action:

- `UpdateDialogOrderInput`
  - `peer_id`
  - `pinned_order`
  - `order`
- `UpdateDialogOrderResult`
  - `dialog`

The client computes `order` locally from current neighbors and sends the resulting key. The server validates and persists it. If the server must resolve a collision, it can return the authoritative dialog with a different order key.

For opening, extend `UpdateDialogOpenInput` with optional `order`. Opening from closed should be local-first:

- client computes append-at-bottom key for the normal lane
- optimistic update writes `open = true`, clears archive/hidden state, and writes `order`
- server accepts/stores that key and echoes it back

## Server Work

1. Add nullable columns to `dialogs`:
   - `order text`
   - `pinned_order text`
2. Add useful indexes for user-scoped ordering:
   - `(user_id, order)`
   - `(user_id, pinned_order)`
3. Backfill:
   - no need for backfill. just drop date and move to order from now on.
4. Update encoders and API schema to include both order fields.
5. Update `dialogOpenDefaultsForChat`, `dialogOpenFieldsForOpen`, and `setDialogOpenForUsers`:
   - opening assigns `order` if absent or when transitioning from closed to open
   - closing sets `open = false` but does not need to clear `sidebarOrder`
   - pinning assigns `pinnedOrder` if absent and also ensures `open = true`
6. Add `messages.updateDialogOrder`.
7. Ensure send-message promotion paths use the same shared open helper, so DM/reply/mention promotion gets a reliable order key.

## Apple Work

1. Add `order` and `pinnedOrder` to `Dialog`, `ApiDialog`, GRDB coding keys, columns, and protobuf mapping.
2. Add a GRDB migration for the two fields without backfill.
3. Preserve local order fields in `Dialog.saveFull` when older server responses omit them, matching the current compatibility pattern used for locally-owned open state.
4. Add a small `FractionalIndex` helper in InlineKit with focused tests.
5. Update `UpdateDialogOpenTransaction`:
   - compute `order` before optimistic open
   - persist local `order` immediately
   - send `order` to server
   - do not use `openedDate` to sort or stabilize sidebar rows
6. Add `UpdateDialogOrderTransaction`:
   - optimistic local write
   - RPC
   - apply authoritative server dialog
   - rollback/retry behavior should follow existing transaction patterns
7. Update `SidebarViewModel.sortInboxItems`:
   - pinned first by `pinnedOrder`
   - normal open rows by `order`
8. Add sidebar drag reorder:
   - allow reordering within pinned lane
   - allow reordering within normal open lane
   - if possible, allow drag to pin/unpin as well. add pinnedOrder? and order? on pin/unpin actions.
   - compute neighbor keys from the post-drop list and call `UpdateDialogOrderTransaction`
9. Keep the existing sidebar visibility rules:
   - `chatListHidden == true` means not intended as a standalone chat list row
   - pinned rows still show regardless of archive/open state per current product direction

## Local-First Behavior

Opening a dialog should not wait for the server:

1. Fetch visible sidebar rows for the lane and scope.
2. Generate a new `order` after the last normal open row.
3. Save optimistic dialog state locally.
4. Render immediately.
5. Send the mutation with the same key.
6. Apply server ack without changing order unless the server returned a corrected key.

Reorder should be the same:

1. User drops row.
2. Client computes `between(prev.order, next.order)`.
3. Save local order immediately.
4. Send order mutation.
5. Apply ack.

This removes the current `openedDate` client/server clock mismatch from the sorting path.

## Open Questions / Choices

- Scope of ordering: default to per-user global dialog order, not per-space order. The same dialog will have the same relative order in Home and in a space sidebar. Per-space ordering would require a separate per-user/per-space order table and is more complexity than this feature needs right now.
- Reopen placement: when a closed dialog is opened again, generate a fresh append-at-bottom `order`. Closing clears the normal `order`.

## Tests

Swift:

- `FractionalIndex` orders generated keys correctly.
- `between(left, right)` produces a key strictly between neighbors.
- repeated appends stay sorted and bounded enough for expected sidebar sizes.
- `UpdateDialogOpenTransaction` assigns `sidebarOrder` on open and clears archive/hidden state.
- `SidebarViewModel` sorts pinned and normal lanes by order fields with stable fallback.
- GRDB migration adds order fields without backfill.

Server:

- opening a closed dialog accepts/stores client-provided `order`.
- reopening already-open dialogs does not unexpectedly move them unless a new transition occurs.
- closing hides normal open rows and clears their normal order.
- pinning assigns `pinnedOrder` and keeps dialog visible.
- reorder mutation persists, encodes, and broadcasts the new order.
- old clients without order fields still get compatible dialog payloads.

## Rollout

1. Add schema/proto fields and compatibility fallback.
2. Generate protocol clients.
3. Add local/server fractional index helpers with tests.
4. Update open/pin/reorder write paths.
5. Update sidebar sorting to prefer order keys.
6. Add sidebar drag reorder.
7. Run focused Swift tests/build and server tests/typecheck.
8. After deployed clients and backend are stable, remove `openedDate` from active code paths. Drop DB columns only in a later cleanup migration.
