# ChatList package lab

This is a standalone native consumer of `apple/ChatList`. It imports only `ChatListCore` and the platform host product. Its records, long selectable text, controls, and probes are lab content; the package owns row placement, compensation, virtualization, native scrolling, and animation.

The same `Shared/LabScenario.swift` creates immutable snapshots for macOS and iOS. Both apps have Older, Newer, Delete, Height, Top, Bottom, Both (height plus insets), Width, Latest, and Replay controls. The fixture stays below 720 rows while its 2,048 events exercise changing history windows. Top and Bottom draw translucent occlusions over the list and pass their sizes as `TimelineViewport` insets. Sticky group badges and avatars use `ChatListDecoration` placements in the native overlay callback. Native scroll-view content insets, sticky placement, and scroll compensation remain the package's responsibility.

The Replay control, or `--replay` launch argument, first exercises a 5,000-point native text cell with 150 repeated long passages. Its focused edits change the preceding child, height, insets, width, and older rows while a glyph deep in the passage remains selected as the observation point. The fixture then resets to the bounded ordinary window and runs 2,048 seeded edits on the package's explicit clock. It samples eight intermediate states per event at varied 60/120 Hz and longer intervals, checks ordered finite package geometry, compares every materialized native row, child, sticky decoration, and occlusion frame to package placement, and checks retained glyph screen positions. An independent clamp calculation distinguishes unavoidable boundary displacement from anchor error; retired rows and clipped glyphs are counted separately. The failure context includes origin, legal origin, row and child frames, native text offset, and intent. The JSON report retains the total failure count and first 256 detailed failures. A negative control moves the glyph within a cell while keeping list origin fixed; it demonstrates why origin alone cannot detect text drift. A JSON report is written to a unique `ChatListLabResults-*.json` path under `/tmp` on macOS or the app's Documents directory on iOS. The app and process log show its summary and path. macOS also accepts `--replay-exit` to write the report and terminate.

Generate the two-target project with `xcodegen generate --spec project.yml` from this directory. Build `ChatListMacLab` with `xcodebuild -project ChatListPackageLab.xcodeproj -scheme ChatListMacLab -configuration Debug build`. Build `ChatListPhoneLab` for a physical device with `xcodebuild -project ChatListPackageLab.xcodeproj -scheme ChatListPhoneLab -configuration Debug -destination 'generic/platform=iOS' build`, then install and launch it on a physical iPhone through Xcode. No simulator is required. Add `--replay` to the scheme's launch arguments to run the deterministic replay at launch. The apps use an automatic display clock for ordinary interaction and an explicit virtual clock for Replay; restart the app to resume real-time interaction after a replay.

The evidence levels are separate:

- **Core:** `ChatListCore` unit tests prove value-state geometry and transaction invariants without native views.
- **Native host:** this lab's replay exercises AppKit/UIKit cells, viewport updates, reuse, semantic anchors, sticky decorations, and native glyph screen coordinates. The clock samples are deliberate virtual presentations. The report times only `list.advance(to:)` as Debug virtual-presentation CPU work (p50/p95/max); it does not measure delivered display frames.
- **Pixels:** a screenshot or recorded-frame comparison is needed to inspect clipping, occlusion, glyph raster alignment, and frame-to-frame appearance. The geometry report does not prove those pixels.
- **Real display:** manual scrolling, text selection, resizing/rotation, and frame pacing on a live Mac and physical iPhone are required before claiming interactive quality. A build alone does not supply that evidence.

The project intentionally has no Inline app model, database, renderer, or production rich-content dependency. It has no persistence, network, or release path. Project generation, builds, installation, pixel captures, and real-display acceptance must be reported separately when performed; this README does not claim they have run.

## Focused physical iPhone cases

The `ChatListPhoneLab` scheme includes focused XCTest UI cases. They use the ordinary
native host with real swipes and text views. Three launch modes make particular
boundaries reproducible:

- `--bottom-occlusion-test` positions message 352 at the usable bottom after a
  real scroll, then checks opening and closing a 92-point bottom occlusion.
- `--resize-test` changes only the host height by 100 points, without a scroll
  gesture, and checks Latest and reading intent through shrink/grow and append.
- `--keyboard-test` opens a real system keyboard from a text field. A passive
  view constrained to `keyboardLayoutGuide` supplies its presentation position
  to one external frame clock. Each sample calls the package's public viewport
  and advance APIs; the lab never computes list compensation. This mode hides
  Replay so it cannot start a second clock.

The keyboard test confirms the system keyboard is visible and compares the
message with the independent keyboard notification's end-frame edge at settled
endpoints. During movement it compares the same native glyph immediately before
and after each guide-driven inset submission, retains before/open/close and
frame records in `Documents/KeyboardLabResults-*.json`, and counts missing
witnesses as failures. This is native geometry evidence, not a capture of
compositor-delivered pixels for every frame. No simulator is required or used.

For interactive-cancel acceptance on a physical iPhone, launch with
`--keyboard-test`, position message 352, and open the system keyboard. Drag the
list downward partway, then reverse upward without lifting the finger; the
keyboard should return to its open position. Repeat with a full downward drag
to complete dismissal. Preserve the `KeyboardLabResults-*.json` report and
check that both transitions have moving samples, zero measurement failures,
and same-tick native-glyph residuals no greater than 2 points. The UI test
automates completion; the continuous reverse gesture needs this manual check.

Build the physical test bundle without launching a device:

```sh
xcodebuild -project ChatListPackageLab.xcodeproj -scheme ChatListPhoneLab \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/chatlist-lab-derived -jobs 2 build-for-testing
```

Supply your signing team as needed. Once the physical phone is unlocked, use
`test-without-building` with `-destination 'platform=iOS,id=<physical-device-id>'`
and the same derived-data path. Keep failed reports alongside subsequent passes.

## September 26 qualification checkpoint

The shared package passed 104 core and 16 AppKit tests. The final Mac native
replay passed 2,048 seeded events plus five focused passage events, with 16,424
geometry samples and zero failures; see `results/macos-final-pass.json`.
The first three-case physical iPhone UI suite passed, with a settled prepend
pixel comparison showing no changed pixels in its 750 × 978 list viewport.
That prior suite does not qualify the three new focused cases above. Final
physical replay/UI reruns are pending device unlock; compilation and runtime
results remain distinct in the implementation receipt.

## September 27 qualification checkpoint

The package passes 106 core and 16 AppKit tests, including explicit initial-anchor
lock and atomic/held-preparation orientation regressions. The full physical
iPhone deterministic replay passes all 2,048 seeded plus five focused events:
16,424 geometry samples, 91,821 native cell samples, 15,141 retained-glyph samples,
and zero failures (`results/iphone-tenth-full-replay.json`). The earlier failing
glyph reports remain preserved. UIKit reset the lab text container height when
the frame changed; the fixture now restores unbounded layout before inspecting
retained glyphs.

Five of six physical UI cases passed in suite4. The actual keyboard did not
become visible in that run, so keyboard anchoring was not qualified. Subsequent
isolated attempts timed out enabling XCTest automation before test execution.
Interactive dismissal and actual orientation checks remain pending. Debug
virtual timing (p95 10.77ms, maximum627.39ms) is not delivered-frame performance
and does not establish fluid scrolling.

## Package keyboard tracking, reordering, and lag recording

- `--host-keyboard`: the package's `tracksKeyboard`, with no lab sampling adapter.
- `--reorder`: long-press and drag rows.
- `--markers`: a green bar on `keyboardLayoutGuide` and a magenta bar on the list's
  usable edge. When the list moves with the keyboard they stay level on every frame.

`testRecordKeyboardMotion` records four open/close cycles and fails on purpose so
the result bundle keeps its screen recording. Run it with
`TEST_RUNNER_CHATLIST_RECORD=host` or `=sampled` (the old lab adapter), then measure
the bars: `python3 measure_marker_lag.py <recording.mp4>`.
