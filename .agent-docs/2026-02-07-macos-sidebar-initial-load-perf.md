# macOS: Sidebar Initial Load Perf + Animation Lag (2026-02-07)

From notes (Feb 5, 2026): "fix sidebar initial load animation/lag".

## Goals

1. Sidebar appears immediately without noticeable stutter after app launch or login.
2. First render should avoid large animated layout changes.
3. Data loading should not block the main thread.

## Non-Goals

1. Rewriting the entire sidebar architecture.
2. Optimizing every possible micro-interaction; focus on the “first 2 seconds”.

## Likely Causes

1. Main-thread DB reads during sidebar initialization.
2. Expensive initial diff/apply of list snapshot (too many row updates).
3. Image/icon loads on first render (avatars, chat icons) doing work on main.
4. Layout thrash from constraints recalculations during initial window setup.

Key files:
- Sidebar controller: `apple/InlineMac/Features/Sidebar/MainSidebar.swift`
- Sidebar list: `apple/InlineMac/Features/Sidebar/MainSidebarList.swift`
- Sidebar view model: `apple/InlineMac/Features/Sidebar/ChatsViewModel.swift`

## Investigation Plan (Fast)

1. Add signposts around sidebar creation and first data snapshot apply.
2. Time profiler launch-to-sidebar-visible:
3. Cold start (after quit).
4. Warm start (app already running).

3. Capture main-thread hotspots:
4. GRDB reads
5. image decoding
6. layout/constraint passes

## Fix Plan (Phased)

### Phase 1: Remove main-thread work

1. Move DB fetch work in `ChatsViewModel` off main if it isn’t already.
2. For initial load, fetch only the minimal fields needed for the first render.
3. Defer secondary data (previews, counts) to a later refresh.

### Phase 2: Snapshot/refresh strategy

1. Apply the first snapshot without animations.
2. Coalesce subsequent updates for the first second after launch (debounce).
3. Avoid rebuilding the full list on small changes; apply incremental diffs.

### Phase 3: Images and icons

1. Ensure avatars and icons are cached and decode off main.
2. Prefer placeholder icons without animation on first load.

### Phase 4: Layout stability

1. Avoid changing row heights during the first render.
2. Ensure fonts and metrics are fixed before first snapshot apply.

## Acceptance Criteria

1. Sidebar is interactive within ~300ms on warm start.
2. No obvious “pop” animation where the sidebar reflows after first paint.

## Open Questions

1. Is the lag primarily DB, images, or layout? Instrumentation should decide.

