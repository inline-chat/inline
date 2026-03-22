# Message Action Rows v1 (iOS + macOS) Spec

Date: 2026-03-22
Owner: Apple client (InlineKit + InlineIOS + InlineMac)

## Goal
Ship client-side support for interactive message action rows (Telegram-style inline buttons) so bots can:
- Render rows of actions under a message.
- Receive callback invokes when users tap callback buttons.
- Show loading state while waiting for bot answer.
- Let bot answers clear loading and optionally show lightweight UI feedback.
- Support local copy-text actions with no bot roundtrip.

## v1 Scope
In scope:
- Render `MessageActions` rows on iOS and macOS in a compact, minimal style.
- Support action kinds:
  - `callback`: invoke bot via `invokeMessageAction` RPC.
  - `copy_text`: copy provided text to clipboard locally.
- Loading UX for callback taps:
  - Start loading immediately on tap.
  - Continue loading after `invokeMessageAction` returns `interaction_id`.
  - Stop loading on `updateMessageActionAnswered(interaction_id, ui?)`.
- Handle bot response UI:
  - If answered update includes toast text, show platform toast.
- Persist message actions in local DB so rows survive reload/restart.
- Respect server-side edit replacement semantics automatically via message edits:
  - absent actions => keep
  - present empty => clear
  - present non-empty => replace

Out of scope for v1:
- URL/open-webapp/alert action kinds.
- Multi-step modal UI for answers.
- Retry queueing of callback invokes when offline beyond normal transaction behavior.
- Bot HTTP webhook/getUpdates work.

## UX Requirements

### Placement
- Action rows appear directly below message content block, inside message visual group, before reply-thread footer/reactions-outside area.
- Respect outgoing/incoming alignment.
- Keep compact vertical rhythm (small spacing, low visual weight).

### iOS visual
- Row container: vertical stack of rows.
- Row: horizontal equal-width buttons.
- Button: small rounded rectangle, subtle border/fill, single-line text truncation.
- Spinner overlay for loading callback button.
- While a callback button is loading, only that button is disabled/spinning in v1.

### macOS visual
- Same structural layout (rows + equal-width buttons), AppKit-native controls.
- Compact height and typography matching message chrome.
- Spinner in loading callback button.

### Interaction behavior
- `callback` tap:
  1. Set local loading state.
  2. Send `invokeMessageAction(peer_id, message_id, action_id)`.
  3. Store `interaction_id` mapping when RPC returns.
  4. Clear loading on answer update for that interaction.
  5. If RPC fails, clear loading and show error toast.
- `copy_text` tap:
  - Copy payload text to clipboard immediately.
  - Show success toast.
  - No RPC.

### Duplicate taps
- Tapping a callback button already loading is ignored.

### Accessibility
- Button labels use action text.
- Loading button remains labeled and exposes busy/disabled state.

## Data Model + Persistence
- Store actions inside `Message.contentPayload` to keep attached structures consolidated:
  - `client.MessageContentPayload.actions`
  - `Message.actions` remains as a convenience property backed by `contentPayload.actions`.
- Save/merge rules:
  - On save from protocol message, incoming `actions` replaces local actions when present.
  - If incoming message omits actions, keep existing actions only when server message did not explicitly include change (handled naturally by message snapshot semantics + edit updates carrying actions).
- Keep `MessageActions` Codable helpers for local serialization paths.

## Realtime / Transactions

### New transaction
- `InvokeMessageActionTransaction` (`Method.invokeMessageAction`)
- Input:
  - peer
  - message_id
  - action_id
- Result:
  - `interaction_id` extracted from result branch.

### Answer update handling
- Handle `UpdateMessageActionAnswered` in updates engine:
  - Forward to client interaction state manager using `interaction_id`.
  - If `ui.toast.text` exists and non-empty, show platform toast.

## Client Interaction State Manager
Create shared manager in InlineKit:
- Tracks pending callback states keyed by `(peer, message_id, action_id)`.
- Tracks `interaction_id -> key` mapping after invoke RPC returns.
- Publishes current loading set via Combine so message views can update reactively.
- API:
  - `begin(...)`
  - `attachInteractionId(...)`
  - `finish(interactionId:)`
  - `fail(...)`
  - `isLoading(...)`

Design notes:
- Manager is a main-actor object that owns loading/interaction maps.
- UI reads from publisher and checks `isLoading` per button.

## iOS Implementation Plan
- `UIMessageView`:
  - Add message-action rows container + button rendering.
  - Subscribe to interaction-state publisher.
  - Route taps to:
    - callback invoke flow (async task + manager)
    - copy-text clipboard flow
  - Keep existing message layout intact; extend bottom anchoring logic to include actions container before reply-thread footer/external reactions.

## macOS Implementation Plan
- Add compact `MessageActionRowsView` (AppKit) used by:
  - `MessageViewAppKit`
  - `MinimalMessageViewAppKit`
- Wire view creation/update/removal in `setupView()` + `update(with:)` paths.
- Extend `MessageSizeCalculator.LayoutPlans` to include action row plan and top offset so row height is fully measured and row overlaps are avoided.

## Error Handling
- Invoke RPC failure:
  - clear loading state
  - show generic failure toast
- Missing/unknown action kind:
  - button is not rendered for v1 (skip invalid action)

## Acceptance Criteria
- Actions from bot messages render on both iOS and macOS.
- `copy_text` copies text and shows success toast.
- `callback` tap triggers invoke RPC and shows loading immediately.
- Loading clears when answered update arrives.
- Answered toast is shown if provided by bot.
- Actions update correctly after message edits (replace/clear/keep semantics).
- UI remains compact and does not regress existing message layout features (replies, reactions, attachments, media).
