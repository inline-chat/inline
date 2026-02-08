# macOS Non-Bubble Message View (Feature Flag) (2026-02-07)

From notes (Feb 6-7, 2026): "no bubble", "non-bubble message views".

Related detailed plan with patches:
- `/.agent-docs/non-bubble-message-view-plan.md`

## Goals

- Add a feature-flagged non-bubble message layout on macOS.
- Preserve readability and alignment while avoiding regressions in sizing, selection, and media layout.
- Keep implementation reversible (flag + minimal touchpoints).

## Non-Goals

- Shipping as default immediately.
- iOS/web parity in the first iteration (macOS first).

## Proposed UX

When enabled:
- No bubble backgrounds.
- Neutral text + link colors (not outgoing-colored).
- Left alignment for both incoming and outgoing (optional; recommended for calm reading).
- Time/state shown inline or on hover, not as overlays on media.
- Avatar logic: show avatars for incoming messages even in DMs (optional; plan suggests showing more avatar context).

## Implementation Plan (Based On Existing Plan)

1. Add feature flag
- `enableNonBubbleMessages` in macOS `AppSettings`.
- Surface in experimental settings.

2. Thread flag through message view props
- Add `isNonBubble` to `MessageViewInputProps` and `MessageViewProps`.
- Set from settings when building props in message list.

3. Update layout + styling
- `MessageViewAppKit` should use clear bubble background, use label/link colors for text, adjust outgoing alignment rules, and disable time overlay in non-bubble mode.
- `MessageSizeCalculator` should remove bubble insets from sizing and adjust media max sizes if needed.
- `MessageTimeAndState` should support neutral coloring.

Primary touchpoints (from plan):
- `apple/InlineMac/Views/Settings/AppSettings.swift`
- `apple/InlineMac/Views/Settings/Views/ExperimentalSettingsDetailView.swift`
- `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
- `apple/InlineMac/Views/Message/MessageViewTypes.swift`
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MessageTimeAndState.swift`
- `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`

## Acceptance Criteria

1. Feature flag toggles non-bubble layout without restarting app.
2. Message list remains stable: no layout jumps during scroll.
3. Media messages look correct (no time overlay collisions).
4. Performance is not worse than bubble mode on large chats.

## Test Plan

Manual:
- Toggle setting on/off in a large chat.
- Scroll quickly; verify no jitter and correct sizing.
- Verify link colors and selection states.

## Risks / Tradeoffs

- Hover-based UI can be less discoverable; ensure time/state still accessible.
- Some outgoing-specific styling will be reduced; verify users still understand authorship (avatars/names become more important).
