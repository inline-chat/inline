# GRDB SQLCipher Fork Refresh Plan (2026-02-15)

## Goal

Replace Inline's current GRDB/GRDBQuery fork lineage with fresh upstream-based forks from `groue`, enable SQLCipher using GRDB's native package instructions, retag/release in `inline-chat`, and update Inline to consume the new versions.

## Steps

1. [x] Gather baseline versions and dependency pins in `inline`.
2. [x] Create fresh local clones from upstream `groue/GRDB.swift` and `groue/GRDBQuery`.
3. [x] Apply `GRDB+SQLCipher` package configuration in GRDB.swift.
4. [x] Update GRDBQuery package dependency to point to `inline-chat/GRDB.swift`.
5. [x] Validate both packages resolve/build at least at package level.
6. [x] Repoint remotes to `inline-chat/*`, force-push refreshed histories.
7. [x] Create GitHub releases/tags aligned with upstream GRDB.swift and compatible GRDBQuery versioning.
8. [x] Update `inline` repo dependency pins and lockfiles as needed.
9. [ ] Run focused checks in `inline` and summarize production readiness/risk.

## Notes

- Existing local `/Users/mo/dev/GRDB.swift` and `/Users/mo/dev/GRDBQuery` are intentionally ignored.
- No destructive file operations; use dedicated workspace under `/Users/mo/dev/inline-worktrees/grdb-forks-refresh`.
- `groue/GRDB.swift` latest release observed: `v7.10.0` (2026-02-15).
- `groue/GRDBQuery` latest release observed: `0.11.0` (2025-03-15).
- `GRDB.swift` SQLCipher fork build passed locally (`swift package resolve && swift build`).
- `GRDBQuery` build passed locally against `inline-chat/GRDB.swift@7.10.0` (`swift package resolve && swift build`).
- Force-pushed:
  - `inline-chat/GRDB.swift` main -> `37fa975af1f81d3b89f76cba3d69147d66256d1c`
  - `inline-chat/GRDBQuery` main -> `61c12a8c00a2da3dd8fa0c925e358663fcef47a0`
- Releases:
  - `inline-chat/GRDB.swift` `v7.10.0`: https://github.com/inline-chat/GRDB.swift/releases/tag/v7.10.0
  - `inline-chat/GRDBQuery` `0.11.5`: https://github.com/inline-chat/GRDBQuery/releases/tag/0.11.5
- `InlineKit` focused `swift build` is currently blocked by repeated transient network failures downloading Sentry binary artifacts from GitHub Releases (not a GRDB compile error).
