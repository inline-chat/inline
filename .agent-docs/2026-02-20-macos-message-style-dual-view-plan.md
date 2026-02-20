# macOS Message Styles: Dual View + Dual Size Plan (2026-02-20)

## Context
We need a robust architecture for two message styles on macOS:
- Bubble (current baseline)
- Minimal (non-bubble, left-aligned)

This is not strictly experimental. One or both styles are expected to ship to production soon.

## Final Decisions
1. Use **two dedicated AppKit message view classes**, not one class with many `if` branches.
2. Use **two style-specific size calculation entrypoints** with shared helper functions extracted into small pure functions.
3. Pick style **once per chat/message list creation** (initial chat load only). No live switch handling in an already-open chat.
4. Minimal style is **left-aligned**.

## Why This Architecture
- Reduces long-term complexity and branch explosion in `MessageViewAppKit`.
- Makes each style easier to optimize and reason about independently.
- Avoids regressions from style-specific constraints/colors accidentally leaking through conditionals.
- Fits production-readiness better than a single highly-branchy class.

## Scope
### In Scope
- macOS message list rendering path (`MessageListAppKit -> MessageTableCell -> MessageView`).
- macOS message size computation path (`MessageSizeCalculator`).
- Style setting persisted in app settings.

### Out of Scope
- Live style reconfiguration for open chats.
- iOS/web parity.
- Restyling old/legacy non-message surfaces.

## Target File Changes
- `apple/InlineMac/Views/Settings/AppSettings.swift`
- `apple/InlineMac/Views/Settings/Views/ExperimentalSettingsDetailView.swift` (or appearance settings; exact placement can be decided at implementation)
- `apple/InlineMac/Views/Message/MessageViewTypes.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/MessageList/MessageTableRow.swift`
- `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`
- New files for dual views and shared helpers (names below)

## Proposed Type Design

### 1) Style model
Add a style model in macOS app settings:
- `MessageRenderStyle` enum (`bubble`, `minimal`) or boolean flag (either acceptable).
- Persisted in `UserDefaults`.

Even if UI uses a boolean toggle initially, keep internal value convertible to explicit style.

### 2) Message view protocol
Introduce a small protocol used by table cell to avoid hard-coding a concrete class:
- `updateTextAndSize(fullMessage:props:animate:)`
- `updateSize(props:)`
- `reflectBoundsChange(fraction:)`
- `setScrollState(_:)`
- `reset()`

### 3) Dual message view classes
- `BubbleMessageViewAppKit` (existing current implementation moved/renamed or wrapped)
- `MinimalMessageViewAppKit` (duplicated from bubble baseline and simplified/adjusted)

Both conform to the protocol above.

### 4) Dual size entrypoints
Inside `MessageSizeCalculator`, expose:
- `calculateBubbleSize(...)`
- `calculateMinimalSize(...)`

Internally share small helper functions for common measurement logic.

## Shared Helper Extraction (Size Calculator)
Extract and reuse the following helper stages so duplication is controlled:
1. `buildMessageFlags(...)`
2. `buildAttributedText(...)`
3. `measureText(...)`
4. `measureMedia(...)`
5. `measureDocumentAndAttachments(...)`
6. `buildReactionPlans(...)`
7. `buildTimePlan(...)`
8. `assembleWrapperAndFinalize(...)`

Each style entrypoint should only differ in style constants and style-specific assembly choices.

## Style-Specific Rules

### Bubble
- Keep current visual/spacing behavior as baseline.
- Preserve current outgoing/incoming alignment.

### Minimal
- No bubble background.
- Neutral text/link colors.
- Left-aligned (incoming and outgoing).
- Keep avatars/names logic explicit for readability; do not infer from bubble assumptions.
- Time/state behavior should be explicit for minimal style and not rely on bubble overlay assumptions.

## Initialization and Style Resolution
1. Resolve style in `MessageListAppKit` init from `AppSettings`.
2. Store style as an immutable property for that controller lifetime.
3. `MessageTableCell` creates the corresponding message view class based on that style.
4. Size calculations use the style-specific entrypoint.

No observers for style changes in open chat views.

## Cache and Identity Plan (Critical)
Even without live switching, style must be part of cache identity to prevent stale cross-style results when chats are reopened:
1. Include style in `MessageViewInputProps` and `MessageViewProps`.
2. Include style in size cache key generation (`MessageSizeCalculator.cacheKey`).
3. Include style in attributed text cache key (`CacheAttrs`) or invalidate `CacheAttrs` on style change before new list usage.

## Implementation Phases

### Phase 1: Foundations
- Add style setting in `AppSettings`.
- Add style field in message props types.
- Thread style through `MessageListAppKit` prop building.

### Phase 2: Size split
- Introduce dual `calculate...` entrypoints.
- Extract shared helper functions.
- Keep behavior parity for bubble path.

### Phase 3: View split
- Introduce protocol + dual message view classes.
- Move bubble behavior to dedicated class.
- Implement minimal class by duplication then simplify for minimal rules.

### Phase 4: Wiring
- Update `MessageTableCell` factory + reuse logic to work with style-aware view type.
- Ensure row height and `updateHeightsForRows` call style-matching size entrypoint.

### Phase 5: Verification
- Build/check touched packages.
- Manual QA scenarios (below).

## QA Checklist (Production-focused)
1. Large chat initial render performance is not worse than current baseline.
2. Scroll up/down + live resize: no clipping or reaction misalignment.
3. Text-only, emoji-only, photo+caption, video+caption, document, attachments, forwarded, reply, and reactions all render correctly in both styles.
4. Message update reuse path (`updateTextAndSize`) remains correct for edits/reactions/status changes.
5. Translation enabled/disabled path still updates text + sizing correctly.
6. Open chat A in one style, change setting, open chat B: new chat uses new style correctly (no stale cache artifacts).

## Risk Register and Mitigations
1. **Cache contamination**: style-specific cache keys + explicit cache invalidation if needed.
2. **Reuse regressions in table cell**: make style part of props identity and recreate cell view when style differs.
3. **Constraint drift in minimal style**: duplicate first, then prune; do not attempt deep abstraction in first pass.
4. **Calculator refactor breakage**: keep helper extraction incremental and diff-verify bubble output parity.

## Definition of Done
1. Code compiles and touched checks pass.
2. Bubble style remains behaviorally equivalent to current baseline.
3. Minimal style renders fully left-aligned and stable.
4. Style selection happens on initial chat load without live reload logic.
5. No obvious performance regression in manual stress pass.

## Notes for rollout
- Since this is production-oriented, we should keep a simple kill-switch setting for rapid rollback if needed.
- Once stable, setting placement can move from Experimental to Appearance without architecture changes.
