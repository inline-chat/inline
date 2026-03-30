# Repo Hygiene + macOS Modularization (2026-02-07)

From notes (Feb 1-7, 2026): "work on repo hygiene", "small: add multi-package note in agents.md", "convert macOS into packages ?!? / break down macOS into distinct packages so build/test from agent works".

This spec is about making work repeatable and testable (especially for agents) without requiring `xcodebuild`.

## Goals

1. Make macOS app logic buildable and testable via SwiftPM (`swift build` / `swift test`) in small targets.
2. Keep the Xcode app target thin (entrypoints, resources, entitlements).
3. Align platform minimums across packages to avoid conditional compilation drift.
4. Reduce “repo friction” so tomorrow’s feature work is faster and safer.

## Non-Goals

1. Reorganize the entire repo layout in one pass.
2. Rewrite UI architecture (only move code into testable modules).

## Current State

1. SwiftPM packages exist for shared logic and UI:
2. `apple/InlineKit`
3. `apple/InlineUI`
4. `apple/InlineMacUI`
5. `apple/InlineIOSUI`

2. The macOS app is an Xcode target under `apple/Inline.xcodeproj` and sources live in `apple/InlineMac/...`.
3. Agent guidance prefers `swift build` / `swift test` and avoids full app builds with `xcodebuild`, which means macOS app-only code is currently hard to validate in CI/agent loops.
4. There is a platform policy mismatch risk:
5. Repo docs say macOS min is 15.
6. `apple/InlineMacUI/Package.swift` still targets `.macOS(.v14)` (TODO to update).

## Spec: Add A SwiftPM Package For macOS App Code

Create a new package:
1. `apple/InlineMacApp/Package.swift`

Proposed targets:
1. `InlineMacCore`
2. `InlineMacServices`
3. `InlineMacFeatures`
4. `InlineMacViews`
5. `InlineMacWindows`

Mapping guideline:
1. `apple/InlineMac/Models` and `apple/InlineMac/Utils` -> `InlineMacCore`
2. `apple/InlineMac/Services` -> `InlineMacServices`
3. `apple/InlineMac/Features` -> `InlineMacFeatures`
4. `apple/InlineMac/Views` -> `InlineMacViews`
5. `apple/InlineMac/Windows` -> `InlineMacWindows`

Xcode target after migration:
1. Keep `apple/InlineMac/main.swift`, `apple/InlineMac/App/AppDelegate.swift`, entitlements, assets.
2. Everything else imports from `InlineMacApp` package targets.

## Plan: Incremental Migration (Low Risk)

### Phase 0: Platform alignment + documentation

1. Align macOS minimum version across SwiftPM packages to macOS 15 (or decide the real min and update docs).
2. Add a short "multi-package note" to `AGENTS.md` explaining where Apple code lives and what agents are allowed to build/test.

Deliverable for this phase can be only a doc update (no code move yet).

### Phase 1: Create package + move leaf modules

1. Create `apple/InlineMacApp` with empty targets and wiring.
2. Move small leaf utilities first (no UI, minimal dependencies).
3. Update imports in the macOS app target.
4. Add `swift test` coverage for at least one moved module to validate the pipeline.

### Phase 2: Services and state

1. Move services (settings controllers, hotkeys, helpers) to `InlineMacServices`.
2. Prefer injecting dependencies instead of singletons where possible to make tests feasible.

### Phase 3: Features and views

1. Move new UI feature code into `InlineMacFeatures` and `InlineMacViews`.
2. Keep AppKit bridging and window controllers in `InlineMacWindows`.
3. Add targeted unit tests for non-UI behavior (formatters, URL parsing, permission logic, etc).

## Repo Hygiene Checklist (Ongoing)

1. Keep generated content out of git (verify `.gitignore` covers expected folders).
2. Decide a consistent policy for `Package.resolved` in Apple packages (commit or ignore, but be consistent).
3. Keep scripts consistent and well logged (avoid silent failure; see macOS release doc).
4. Prefer small atomic commits when refactoring modules to reduce merge pain.

## Acceptance Criteria

1. Agents can run `cd apple/InlineMacApp && swift build` successfully.
2. At least one `swift test` suite exists for macOS app logic without `xcodebuild`.
3. macOS minimum version is consistent across packages and docs.

## Risks / Tradeoffs

1. Moving files changes Xcode project references; do it in small batches to avoid breaking local builds.
2. Some AppKit code is hard to unit test; focus tests on pure logic layers.
3. Version alignment may force `#available` gating for APIs used by older package targets.

## Open Questions

1. Should we create a new package `InlineMacApp`, or extend `InlineMacUI` with more targets? A separate package keeps boundaries clearer.
2. What is the true minimum macOS version for the app today (14 vs 15)?

