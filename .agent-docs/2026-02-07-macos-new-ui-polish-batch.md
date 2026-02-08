# macOS New UI Polish Batch (2026-02-07)

From notes (Feb 5-7, 2026): dark mode contrast, light mode black gradient, toolbar fade background, toolbar background clipped when sidebar collapsed, duration bold, time background, SF Symbols crushed, unread tabs/badges, pin icon removal/alignment, "Your Inline Account" label, remove translate, remove people when size is small, sidebar initial load lag, close button hover alignment, chat icon dark mode, send mode dark mode, reactions resize positioning.

This spec is for the macOS "new UI" path only. Avoid touching legacy sidebar/old UI unless explicitly needed.

## Goals

1. Fix the most visible new UI papercuts without triggering regressions.
2. Improve contrast and legibility in dark mode.
3. Remove “janky” transitions: clipping, flicker, bad fades, crushed symbols.
4. Make unread state and pin state readable at a glance.

## Non-Goals

1. Large redesign of the sidebar or toolbar IA.
2. Replacing the message view layout engine (only targeted fixes).

## Key Touchpoints (By Area)

Theme and contrast:
- `apple/InlineMacUI/Sources/MacTheme/Theme.swift`

New sidebar rows and badges:
- `apple/InlineMac/Views/Sidebar/NewSidebar/SidebarItemRow.swift`
- `apple/InlineMac/Views/Components/SidebarTabView.swift`
- `apple/InlineMac/Views/Components/SidebarTabButton.swift`

Toolbar background + clipping:
- `apple/InlineMac/Features/MainWindow/MainSplitView.swift`
- `apple/InlineMac/Features/Toolbar/MainToolbar.swift`
- Legacy toolbar (avoid): `apple/InlineMac/Views/ChatToolbar/ChatToolbarView.swift`

Message overlays (time/state, SF symbols):
- `apple/InlineMac/Views/Message/MessageTimeAndState.swift`

Video duration badge:
- `apple/InlineMac/Views/Message/Media/NewVideoView.swift`

## Priority Plan (Ship In Small Batches)

### P0: Toolbar background clipping when sidebar collapses

Symptom:
1. Toolbar background gets clipped or looks misaligned when the sidebar is collapsed.

Hypothesis:
1. A parent container is masking (`masksToBounds`) or applying corner radius in a way that clips the toolbar background.

Plan:
1. In `MainSplitView`, make masking conditional based on sidebar collapsed state.
2. Ensure the toolbar background extends under the titlebar/traffic lights region consistently.
3. Add a small debug mode (temporary) to visualize the toolbar background bounds during collapse/expand.

Acceptance:
1. Collapsing/expanding the sidebar never clips the toolbar background.
2. No animation jank during collapse.

### P0: Dark mode contrast

Symptom:
1. Some text feels too low-contrast in dark mode.

Plan:
1. Adjust `Theme` dynamic colors so secondary labels remain readable.
2. Reduce aggressive alpha usage in sidebar items and tabs.
3. Verify contrast specifically for:
4. Sidebar thread title, subtitle, unread counts, pinned markers.
5. Toolbar controls and their states.

Acceptance:
1. Sidebar labels remain readable without squinting.
2. Active tab is clearly distinct from inactive.

### P1: Light mode “black gradient” artifacts

Symptom:
1. Light mode shows a dirty/dark gradient in places where it should feel clean.

Plan:
1. Ensure gradients are appearance-conditional.
2. Avoid stacking multiple semi-transparent grays in light mode.
3. Audit `MainToolbarBackgroundView` and thread icon gradients for light mode.

Acceptance:
1. No “black haze” in light mode toolbar or icons.

### P1: SF Symbols crushed

Symptom:
1. Status/utility symbols look squeezed/crushed in some contexts.

Plan:
1. Avoid double-scaling symbol sizes (point size multiplied by backing scale, then drawn into a scaled layer).
2. Render symbols at logical point size and let the layer/backing scale handle retina fidelity.

Acceptance:
1. Symbols look crisp and proportionally correct at 1x/2x displays.

### P1: Time background and video duration styling

Symptom:
1. Time overlay background can be too heavy (especially in light mode).
2. Video duration badge font feels too bold.

Plan:
1. Make overlay background appearance-aware (light vs dark).
2. Adjust duration badge font weight to `.medium` or `.regular`.
3. Confirm readability against both bright and dark thumbnails.

Acceptance:
1. Overlays are readable without looking like a black sticker.

### P2: Unread tabs/badges and pin icon decision

Notes from backlog:
1. "add tabs with unread or something so you notice new threads"
2. "remove pin icon? it feels bad to have pin there"

Plan:
1. Unread: test an alternate unread indicator for sidebar items.
2. Examples: a subtle vertical bar, a small pill, or a dot with better alignment.
3. Tabs: ensure tabs can surface unread state (count or dot) without visual noise.
4. Pin: remove pin icon from rows, or relocate it into the avatar cluster, or only show it in the overflow menu.

Acceptance:
1. Unread threads are obvious without turning the sidebar into a Christmas tree.
2. Pinned state is still discoverable after any icon removal.

### P2: Toolbar button containers (“glass”)

Notes from backlog:
1. "if possible use glass containers for toolbar buttons"

Plan:
1. Apply a consistent background/outline style for toolbar buttons.
2. If macOS 26+ glass is available, use it as an enhancement behind a version check.
3. Provide a non-glass fallback for macOS 15-25 that still looks intentional.

Acceptance:
1. Toolbar buttons feel cohesive and tappable.

### P2: Remove translation surface / disable translation checks toggle

Notes:
1. "remove translate"
2. "disable translation checks toggle"

Plan:
1. Decide the desired end state:
2. Hide translation UI entirely (keep backend support), or keep but add a single master toggle.
3. Avoid removing underlying translation plumbing until usage is measured.

Acceptance:
1. Toolbar stays calm; translation controls do not dominate.

## “Small Fixes” Bucket (Do Opportunistically)

1. Close button alignment on hover.
2. Chat icon dark mode polish.
3. Send mode dark mode polish.
4. Sidebar initial load animation/lag.
5. “Your Inline Account” label under user name in sidebar.

For these, prefer:
1. Isolated UI changes in the new UI files.
2. Minimal or no layout rewrites.

## Testing Checklist

1. Toggle light/dark appearance and verify contrast and gradients.
2. Collapse/expand sidebar rapidly and verify no clipping.
3. Scroll message list and verify overlays and symbols look stable.
4. Verify unread + pin visuals for both DM and threads.

## Risks

1. Theme adjustments can cause subtle regressions across unrelated views; keep diffs small and use appearance-conditional branches.
2. Toolbar masking changes can affect window rounding and shadow; validate across window sizes and in fullscreen.

