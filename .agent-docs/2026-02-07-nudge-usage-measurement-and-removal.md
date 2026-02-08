# Nudge: Measure Usage + Decide Removal (2026-02-07)

From notes (Feb 5-7, 2026): "remove nudge? find a way to see how much a feature is used", "figure out nudge".

Related existing doc:
- `/.agent-docs/2026-01-21-nudge-media-type-plan.md`

## Goals

1. Know whether nudge is used enough to justify UI/maintenance cost.
2. If usage is low, remove or hide nudge without breaking old clients/messages.
3. Avoid collecting sensitive analytics content; track only counts and coarse metadata.

## Non-Goals

1. Perfect product analytics pipeline across all features.
2. Removing nudge server-side in a way that breaks message rendering.

## Current State

1. Nudge is represented as `mediaType = "nudge"` (per existing plan doc).
2. There is a nudge UI surface (button) and a corresponding send path.

## Measurement Spec

### Events to record

1. `nudge_sent`
2. Fields: `client` (ios/mac/web/cli), `spaceId?`, `chatId`, `isDM`, `timestamp`.

2. `nudge_received`
3. Fields: `client`, `chatId`, `timestamp`.

4. `nudge_interacted`
5. Fields: `client`, `chatId`, `timestamp`.

Notes:
1. Do not record message text.
2. Do not record participant identities beyond the existing chatId/spaceId.

### Storage

Option A (Fast): existing analytics service
1. Record via `Analytics` where available.

Option B (Server-first): server counters
1. Add a simple daily aggregate table keyed by date + client type.

## Decision Thresholds

Propose a simple rubric:
1. If fewer than X nudges per active user per week, hide by default.
2. If feature is nearly unused, remove the UI entry point but keep rendering/support for historical messages.

## Removal / Hiding Plan

### Phase 1: Add “Hide nudge” toggle

1. Add a settings toggle to hide the nudge button.
2. Keep the send path intact for now.

### Phase 2: Hide by default (if low usage)

1. Default-off for new installs.
2. Keep the toggle to enable.

### Phase 3: Remove UI surface (if near-zero usage)

1. Remove button from compose UI.
2. Keep message rendering and server handling so old messages still display.

Backwards compatibility:
1. Keep accepting `mediaType = "nudge"` indefinitely.
2. If we stop generating nudges, old clients might still send them; still handle.

## Testing Checklist

1. Nudge send still works when enabled.
2. Hiding toggle removes the UI surface but does not break compose.
3. Existing nudges render correctly after UI changes.

## Acceptance Criteria

1. We can answer: how many nudges were sent last week by client type.
2. We can disable/hide nudge without breaking existing messages.

## Open Questions

1. Where should nudge analytics live (client analytics vs server aggregates)?
2. Do we want nudges to behave differently in DMs vs threads?

