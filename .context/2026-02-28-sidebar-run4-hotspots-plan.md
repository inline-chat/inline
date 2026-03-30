# Sidebar Run 4 Hotspots Plan

Date: 2026-02-28
Trace: `/Users/mo/Downloads/sidebar items.trace`
Run analyzed: run `#3` in trace TOC (latest capture in this bundle)

## Summary
- Async route-open refactor is effective: route coordination and sidebar selection are no longer the dominant hotspot.
- Remaining stalls are mostly in chat view/message list setup and compose draft/layout.
- Main-thread hangs still exist during rapid switching/opening.

## Quantitative Snapshot
- Total samples: `17,766`
- Main-thread samples: `6,310`
- Potential hangs: `25`
  - Brief Unresponsiveness: `20`
  - Microhang: `4`
  - Hang: `1`
- Total hang time: `~4.71s`
- Max single hang: `502.97ms` at `00:08.790.720`

## Confirmed Hotspots (Run 4)
- Message list layout/render path:
  - `MessageListAppKit.viewDidLayout()`
  - `MessageListAppKit.updateScrollViewInsets()`
  - `MessageListAppKit.tableView(_:viewFor:row:)`
  - `MessageListAppKit.checkWidthChangeForHeights()`
  - `MessageTableCell.updateContent()`
- Compose path:
  - `ComposeAppKit.loadDraft()`
  - `ComposeAppKit.didLayout()`
- DB/SQL on critical path:
  - `DatabasePool.read`
  - `SerializedDatabase.sync`
  - `SQLQueryGenerator.makeStatement/makePreparedRequest`
  - `StatementAuthorizer.authorize`
  - `fetchOne`

## What Is Improved
- Route-open coordinator (`Nav2.requestOpenChat`) is active and low-cost.
- Sidebar route selection updates include pending state and are not the primary stall source now.
- Most opening routes now converge on the same async-preload path.

## Next Fix Plan (Post Baseline Commit)
1. Message list layout gating:
- Run inset/height recalculation in `viewDidLayout` only when relevant dimensions actually changed.
- Avoid repeated expensive work during transient layout cycles.

2. Row render cost reduction:
- Reuse per-row computed layout props keyed by `(messageId, width bucket, render mode)` to avoid recomputation in both `viewFor` and `heightOfRow`.

3. Compose draft fast path:
- Ensure draft hydration does not block first layout path; defer costly attributed processing where possible.

4. DB work reduction in hot UI loops:
- Keep fetch/statement generation off main in high-frequency paths; avoid repeated per-layout reads.

## Validation Plan
- Capture a focused Run 5 with same interaction phases.
- Compare:
  - count and duration of `potential-hangs`
  - main-thread samples in message list/layout functions
  - samples in DB/SQL generation functions during route-open windows
