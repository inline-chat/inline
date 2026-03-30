# iOS UI Backlog: Per-Space + Compact Thread UI + Archive UX (2026-02-07)

From notes (Feb 5-7, 2026): "ios: per-space, new ui, compact thread UI", "ios full width archive", "ios archive swipe should go all the way".

This is a product/UI spec to make iOS feel calmer and closer to the macOS multi-space model.

## Goals

1. Per-space navigation feels first-class (not a bolted-on tab).
2. Thread UI can be compact when appropriate (less chrome, more content).
3. Archive is easy to use:
4. Full-width archive list when desired.
5. Swipe to archive completes predictably (no half-gesture awkwardness).

## Current State (Anchors)

1. Root structure is `TabView` with tabs: Chats, Archived, Spaces.
2. Space navigation exists via `SpacesView` and `SpaceView`.
3. Create thread routes exist via `CreateChatView`.

Key file:
- `apple/InlineIOS/ContentView.swift` (root navigation)

## Spec: Per-Space UI

### Desired behaviors

1. The user can quickly scope Home to:
2. All threads (today’s behavior).
3. A specific space.
4. Space-less (home) threads only.

2. The UI makes the current scope obvious.
3. Switching scope should preserve scroll position when possible.

### Proposed UI design

1. Add a space scope picker in Home:
2. A small capsule control or compact header.
3. It should show current space name or "All".

2. For users with many spaces, include search inside the picker.

Implementation sketch:
1. Use `CompactSpaceList` as the source of truth for available spaces.
2. Store selected `spaceId` in a central place (router or an observable settings store).

## Spec: Compact Thread UI

### When to use compact

1. Compact mode in:
2. Threads with short titles.
3. Small devices.
4. When the user is “focused” on messaging.

2. Full mode in:
3. When there are participants, media, or heavy header actions.

### Proposed changes

1. Reduce header height and redundant elements.
2. Keep essential actions accessible (info, attachments, search).
3. Preserve readability for message list and compose.

## Spec: Archive UX

### Full-width archive

1. Provide a full-width archive list layout (especially on smaller devices).
2. Reduce nested navigation friction.

### Swipe behavior

1. Swipe-to-archive should complete with a single continuous gesture.
2. Avoid the feeling that the user must swipe twice or “hit a tiny threshold”.

## Implementation Plan (Incremental)

### Phase 1: Space scoping in Home

1. Add a `selectedSpaceId` state shared across Home and Spaces tab.
2. Filter the Home thread list based on selected scope.
3. Ensure deep links (space/thread links) set the correct scope when opening.

### Phase 2: Archive layout

1. Add a full-width archive list variant.
2. Add a user-facing setting if needed, or make it default on compact devices.

### Phase 3: Swipe completion

1. Update swipe action thresholds to allow full swipe.
2. Ensure haptics and animation feel crisp.

### Phase 4: Compact thread UI

1. Add a compact header variant and gate behind a feature flag.
2. Validate all actions still reachable.

## Testing Checklist

1. Switch between All and a specific space; thread list filters correctly.
2. Open a thread in a space via link; the scope picker reflects that space.
3. Archive list is usable and readable; no clipped controls.
4. Swipe-to-archive works consistently and is not fragile.

## Acceptance Criteria

1. A user with multiple spaces can stay oriented and switch scope quickly.
2. Archive interactions feel predictable and fast.
3. Compact UI option improves density without losing actions.

## Open Questions

1. Should per-space scoping live in the Chats tab only, or be a top-level combined “Spaces + Chats” experience?
2. Should compact mode be a setting, automatic, or both?

