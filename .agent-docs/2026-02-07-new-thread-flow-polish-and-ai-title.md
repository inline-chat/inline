# New Thread Flow: Polish + AI Title (2026-02-07)

From notes (Feb 1-6, 2026): "add new thread page", "Add optimistic new thread view", "new thread polish title, permissions, etc", "AI-generate title for new threads", "decrease height on new thread item".

Related existing docs (older, still relevant):
- `/.agent-docs/2026-01-23-create-thread-macos-plan.md`
- `/.agent-docs/2026-01-28-new-thread-optimistic-findings.md`
- `/.agent-docs/2026-01-29-new-thread-options-analysis.md`
- `/.agent-docs/2026-01-29-new-thread-plan-c.md`

## Goals

1. Creating a new thread feels instant and reliable.
2. We don’t create junk threads accidentally (clean up untitled/empty threads safely).
3. Permissions are correct (who can create threads where).
4. Title experience is calm:
5. Default title is sensible.
6. Rename is obvious (dbl click / Return).
7. AI title suggestion is optional and never blocks sending.

## Non-Goals (For Tomorrow)

1. Offline-first “Plan C” UUID threads (bigger backend change).
2. Perfect AI titles (we only need a decent suggestion loop).

## Current State (Observed From Notes + Code)

1. iOS routes include create thread destinations (`CreateChatView`) in `ContentView2`.
2. There are multiple explored plans (Z/A/B/C) and at least one prototype exists.
3. There is already cleanup logic that deletes untitled threads when archived in some cases (be careful, don’t expand accidentally).

## Decide The Creation UX (Pick One)

### Option 1: Plan Z (Lowest risk)

1. User taps "New thread".
2. Show a toast "Creating thread..." and navigate after server creates it.

Pros:
1. Minimal state and no local optimistic entities.

Cons:
1. Feels slow and can be jarring on poor networks.

### Option 2: Plan B (Recommended “tomorrow-shippable”)

1. User taps "New thread".
2. Immediately show a skeleton chat view (optimistic UI), but do not add a sidebar item yet.
3. When server chat is created, swap in the real chat view.
4. Only show the thread in the sidebar once user sends a message or names the thread.

Pros:
1. Fast-feeling without creating local fake DB entities.
2. Avoids sidebar junk threads.

Cons:
1. Needs careful navigation and cancellation behavior.

### Option 3: Plan A (More complex, but more “real” optimistic)

1. Create local synthetic Chat+Dialog immediately.
2. Replace with server IDs later.

Pros:
1. Very fast and offline tolerant.

Cons:
1. ID reconciliation complexity and edge cases across clients.

## Spec: Plan B Details

### UI states

1. Creating: show skeleton with:
2. Title placeholder (e.g. "New thread")
3. Spinner or subtle progress
4. Compose box active (optional)

2. Created but not yet committed to sidebar:
3. Chat is real, but sidebar item stays hidden until first message or title set.

3. Committed:
4. Sidebar shows the thread normally.

### Cancel behavior

1. If user navigates away before sending or naming:
2. If server chat was created: archive it or delete it if empty and untitled (explicit rule).
3. If server chat not created: cancel request cleanly.

### Permissions

Define and enforce:
1. Who can create threads in a space.
2. Whether thread creation in space requires a role (member vs admin).
3. Home threads are always allowed for the user.

Permissions must be server-enforced (UI gating is not enough).

### Height + density (“decrease height on new thread item”)

1. New thread row in sidebar should be visually compact.
2. The skeleton state should not expand the sidebar vertically.

## AI Title Suggestion (Optional, Non-Blocking)

### Trigger

1. After first message is sent in an untitled thread.
2. Or after a short delay if user pauses after typing.

### Flow

1. Server generates a suggested title from:
2. First message text.
3. Maybe the next one or two messages if available.

2. Client shows an inline suggestion chip:
3. "Suggested title: X" with buttons "Apply" and "Dismiss".

3. Dismiss should persist for that thread to avoid re-prompting.

### Privacy and quality constraints

1. Do not send more context than needed.
2. Never block sending a message on AI title generation.
3. If AI fails, do nothing and don’t show an error.

## Implementation Plan

### Phase 0: Align the plan across platforms

1. Confirm that macOS new UI and iOS will share the same Plan B state machine.
2. Define common acceptance behaviors (when sidebar item appears).

### Phase 1: macOS (new UI) implementation

1. Add skeleton view for create-thread route.
2. Ensure cancellation rules are applied.
3. Ensure rename and first-message commit logic is clear.

### Phase 2: iOS implementation

1. Mirror the same skeleton and commit rules for `CreateChatView`.
2. Ensure router state resets cleanly after success/cancel.

### Phase 3: Server permissions + AI title endpoint

1. Add server-side permission checks for thread creation in spaces (if not already strict).
2. Add an endpoint for "suggestThreadTitle" (or reuse an existing AI module).
3. Store suggested title state (or allow client to store dismissed state locally).

## Testing Checklist

1. Create thread, send first message: thread appears in sidebar and stays.
2. Create thread, navigate away without sending: thread does not remain as junk.
3. Create thread in a space without permission: server rejects cleanly and UI shows a readable error.
4. AI title suggestion:
5. Appears only once.
6. Apply sets title.
7. Dismiss stops future prompts.

## Acceptance Criteria

1. New thread creation feels instant even on slow networks.
2. No growing pile of untitled, empty threads from abandoned create flows.
3. AI suggestion is helpful and ignorable.

## Open Questions

1. Should we ever auto-delete empty threads, or only archive? Deleting reduces clutter but is higher risk.
2. What is the minimum message count to generate a good title (1 vs 2-3)?

