# Main Tab Strip Reintroduction Plan (2026-02-19)

## Goal
Reintroduce a top tab strip in `MainSplitView` using a new macOS UI package target (`NSCollectionView`-based), and gate it behind a persisted menu bar toggle (default off).

## Tasks
- [x] Create `InlineMacTabStrip` target in `apple/InlineMacUI/Package.swift`.
- [x] Implement reusable collection-based tab strip UI in the new target.
- [x] Add app-side adapter that binds `Nav2` state and actions to tab strip API.
- [x] Integrate tab strip area into `MainSplitView` with feature flag wiring.
- [x] Add `AppSettings` persisted key for the tab strip toggle (default `false`).
- [x] Add View menu toggle in `AppMenu` with check state + validation.
- [x] Run `swift build` checks for `apple/InlineMacUI`.

## Progress Log
- Initial plan created.
- Added `InlineMacTabStrip` target and implemented collection-based tab strip UI primitives/controllers.
- Added `MainTabStripController` adapter in app target with `Nav2` observation and spaces menu integration.
- Reintroduced top tabs area in `MainSplitView` and feature-gated it via `AppSettings.shared.showMainTabStrip`.
- Added View menu toggle (`Show Tab Strip`) with persisted state and menu-item validation state sync.
- `cd apple/InlineMacUI && swift build` succeeded (warnings only, no new errors).
