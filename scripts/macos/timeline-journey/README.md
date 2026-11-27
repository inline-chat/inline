# Timeline journey harness (macOS, new message list)

Scripted journeys through the new message list (`TimelineMessageListAppKit`) with real message rows, on the perf
harness's seeded chats: signed out, no server, the same history every launch. One command builds Inline Debug,
runs the journeys, captures the window and prints the numbers:

```
scripts/macos/timeline-journey/run.sh <label>                      # all scenarios
JOURNEY=stream,send scripts/macos/timeline-journey/run.sh <label>  # some
NO_BUILD=1 JOURNEY=fling scripts/macos/timeline-journey/run.sh <label>
```

Results land in `build/timeline-journey/<label>/`:
- `<label>.jsonl`: one line per scenario;
- `<label>-<scenario>-<tag>.png`: captures of the window (real pixels via `screencapture -l`; `CAPTURES=inapp` uses
  the window's own drawing);
- `<label>-runner.log`, `build.log`.

`report.py <jsonl>` prints the summary again.

## How it runs

- The app: Inline Debug at `-O`, built with `USE_PRODUCTION_API=NO DEV_HOST=perf-harness.invalid` into
  `build/TimelineJourneyDD`. `--perf-harness` signs in a fixture user on a throwaway seeded database
  (`PerfHarnessFixture`: 5 chats, 4,200 messages). `-experimental.macTimelineList YES` selects the new list for the run
  only (the argument domain; the stored setting is untouched).
- The runner: `apple/InlineMac/Features/Developer/TimelineJourneyRunner.swift` (`--timeline-journey`), started from
  `AppDelegate`'s DEBUG block. Chats open through `MainWindowController.openChat` (a sidebar click's path).
- Input: trackpad events built as the HID system builds them, sent into the list's `scrollWheel(with:)` (fingers at
  120 Hz, then momentum at 60 Hz); resize by mouse events posted to the window's own resize loop. The pointer is
  never moved.
- Data changes: through the paths realtime updates take (`PerfHarnessFixture`): `receiveMessage`, `editMessage`
  (`saveMessage(publishChanges:)`, as `UpdateEditMessage`), `deleteMessages` (+ `messagesDeleted`),
  `insertPendingSend` / `confirmSend` (as `SendMessageTransaction.optimistic()` and `UpdateMessageId`).
- The window goes to slot APP of `~/dev/inline-chat/.lab-screen` (the built-in display); `run.sh` claims the slot and
  logs itself in `.running`.

## What each scenario measures

Every measured stretch (`Journey.measure`) reports, from a display link on the window: frames, hitches (an interval
over 1.5× the refresh, i.e. a missed frame) and lost frames, the worst interval; from the engine's diagnostics:
performs and their time, the slowest perform, rows made, attach time; main-thread CPU. Per-frame probes add:
`blankGapMaxPt` (the largest gap between placed rows' presented frames) and `edgeUncoveredMaxPt`; `driftMaxPt` /
`driftEndPt` (how far a tracked edge moved: the reading row's top, the newest row's bottom, or the newest row's
distance to the composer).

| scenario | does | should hold |
| --- | --- | --- |
| open | 5 chats × 2 rounds through the sidebar path | rows placed in the open call (first frame), no empty or stale frames, fast settle |
| fling | 12 fast flicks with momentum, up then down | no hitches, no blank gaps |
| drag | 4 slow drags of 60 events | per-event cost under a frame |
| stream | a new message at the bottom, then 50 growing edits at 60 ms | the newest row's bottom stays put (drift 0), each edit shows within a frame or two |
| stream-reading | the same while two screens up | the reading row never moves |
| edit | mid-history: grow and restore a row above the screen, above the reading row, below it | the reading row holds |
| delete | mid-history: below, above on screen, above the screen; then the newest at the bottom | the reading row holds; pinned stays pinned |
| send | pending then confirmed at the bottom; a send from history | the row keeps its view at confirm (no rows made), pinned; the send from history comes back to the bottom |
| arrive | an incoming message, a pending send, its confirmation, at rest on the newest row; one more while reading (run with `--timeline-journey-uncertified` too) | each ends with the newest row's bottom on the composer's edge (`*GapPt` 0, `followed`); reading, the read row holds |
| resize | live resize narrower and back, shorter and back, at the bottom and reading | pinned bottom / reading row hold, no hitches |
| composer | the draft grows six lines, then clears | the newest row keeps its distance to the composer |
| appearance | light → dark → light | settle time, no rows remade |

## Adding a scenario

1. Write `static func runMyThing(_ j: Journey) async` in `TimelineJourneyRunner`: get to a state with `j.show(peer)`,
   `j.toHistory(list)`, `j.untilRest(list)`; drive it through real paths (a fixture write in `PerfHarnessFixture` for
   data, `j.flick` / `j.drag` / `j.liveResize` for input); wrap what you measure in
   `await j.measure(blank:topOf:bottomOf:bottomOfNewest:composerGap:) { ... }` and store it in `j.result`;
   `await j.capture("tag")` (or `j.captureSoon` mid-motion) for what's worth looking at.
2. Add `Scenario(name: "my-thing", run: runMyThing)` to `scenarios`, a row to the table above, and, if its result
   has its own shape, a branch in `report.py`.
3. Data the fixture doesn't have yet (media, replies, reactions changing, a new kind of row): add a seeded chat or a
   writer to `PerfHarnessFixture` (Debug only), going through the same save and publish calls the app's update
   handlers use.

## Caveats

- Debug `-O` on synthetic data: compare runs of the same rig, at similar load (each line records the load average).
- No 120 Hz display here (external 75 Hz, built-in 60 Hz): read 120 fps as the per-frame work budget (8.3 ms).
- The fixture's history is local only (no server pages), so paging stops at the loaded window.
- Drift and blank probes run on the main thread each frame and add a little work to it.
