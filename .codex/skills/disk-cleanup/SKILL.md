---
name: disk-cleanup
description: Audit and reclaim disk space on macOS with cold-first replacement-cost classification and guarded safe, extra, and deep inventories. Use when disk space is low, builds fail with no-space errors, or the user asks to inspect, clean, prune, or remove caches, temporary files, Docker artifacts, Xcode data, build outputs, node_modules, target directories, or other reproducible developer artifacts without immediately forcing expensive rebuilds or downloads.
---

# Disk Cleanup

Use `scripts/disk-cleanup.sh` for repeatable audits. Keep source, personal data, credentials, databases, Docker volumes, `.env` files, mounted device filesystems, and active build state out of scope.

## Workflow

1. Check free space, `.running`, and exact `xcodebuild`, Cargo, Rust, and Swift compiler processes.
2. Run `scripts/disk-cleanup.sh cold` first. Search for at least the requested amount before proposing hot caches.
3. Report exact paths, sizes, age/activity, and replacement impact in these buckets:
   - no immediate replacement: superseded installers/apps, updater downloads, old diagnostics, and one-off temp/export artifacts;
   - rebuild only if reopened: generated outputs inside backups, dormant labs/clones, old one-off DerivedData, and old incremental state;
   - hot/expensive: current targets, package/module caches, current DerivedData, device support, and release-reuse trees;
   - excluded: source, personal/user data, databases, credentials, mounted devices, and irreplaceable history.
4. Inspect large Rust targets before proposing them. Separate `target/debug/incremental` from `deps`, release, and cross-build outputs; recent targets are hot even when large.
5. Ask for confirmation naming literal paths. A general request to free space is not deletion approval.
6. Immediately before deletion, remeasure each approved path and recheck relevant processes. Delete one literal path at a time; never feed a generated list or shell variable to a recursive deletion command.
7. Re-audit and report actual space recovered, failures, and skipped targets.

The helper is audit-only and deliberately refuses `--execute`. It omits any candidate containing `.env` or `.env.*` instead of measuring it. Never read, print, edit, or delete `.env` files. Do not broaden targets with `git clean`, wildcards, cache resets, or generated deletion loops. Do not delete while a relevant build is active.

Use filesystem-bounded size checks (`du -x`) and inspect mounts before counting or deleting. Never treat `~/Library/Developer/CoreDevice/DeviceFS` as Mac cache space: it is commonly a mounted projection of a physical device, and deleting there can affect device-visible data.

Preserve complete current-project package caches, current Xcode DerivedData, iOS DeviceSupport, simulator runtimes in use, downloaded toolchains pinned by a checkout, and reusable release DerivedData. Large size alone is not evidence that a cache is cold.

## Modes

Modes become increasingly disruptive; `cold` is the default and is separate from the cumulative legacy tiers:

- `cold`: old temporary/updater data, old one-off DerivedData entries, inactive Xcode apps, and generated `.build`, `target`, `_build`, or `DerivedData*` trees that are at least 100 MiB, have no recently modified files, and sit outside hot project state. It excludes shared/current DerivedData, `node_modules`, package-manager caches, current build/release trees, and mounted device filesystems. Default age is 7 days.
- `safe`: old temporary files; Trash; Sparkle updater caches; old Xcode DerivedData entries; stale project build outputs in non-current projects; old `node_modules` and Rust `target` directories. Items may be recreated or redownloaded, but current-project and recently modified developer outputs are excluded. Default age is 30 days.
- `extra`: everything in `safe`, plus hot package/module caches, all Xcode DerivedData, current-project build outputs (`build`, `.build`, `DerivedData`, and `target`), and common Bun/npm/Cargo/Go/SwiftPM/Playwright caches.
- `deep`: everything in `extra`, plus dependency trees across developer projects and inventories of unavailable Apple simulators and Docker state. It still excludes Docker volumes, databases, source, documents, downloads, archives, keychains, app support, and available simulator devices.

Use `cold` by default. Treat `safe`, `extra`, and `deep` as triage inventories, not permission to delete; subsequent builds and installs may be slow or require network access.

## Script usage

```sh
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh cold
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh extra --project /absolute/project/path
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh deep --project /absolute/project/path
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh cold --protect /absolute/active/dependency-root
```

`--json` includes each target's replacement-impact class. Either legacy execution flag, `--execute` or `--yes`, returns a clear refusal for compatibility with older invocations.

Optional controls:

- `--project PATH`: identify the active project to protect in `safe` and clean in `extra`/`deep`; defaults to the current directory.
- `--dev-root PATH`: add a root searched for stale developer outputs; repeat as needed. Roots are canonicalized before scanning, and filesystem root, mounted volumes, and CoreDevice projections are refused. Defaults to `~/dev` when present.
- `--protect PATH`: exclude an additional active project or dependency root from every inventory; repeat as needed. Use it for active neighboring checkouts as well.
- `--older-than DAYS`: age threshold for stale targets; defaults to 7 days for `cold` and 30 days otherwise.
- `--json`: emit machine-readable audit output.

Candidates are reported as canonical absolute paths and ordered from cheaper replacement impact toward hot/redownload state; irrecoverable Trash entries come last. If a tool such as Docker, Xcode, Bun, npm, Cargo, or Go is unavailable, skip its group and continue. Surface permission failures rather than escalating or deleting through another mechanism. Treat APFS clone-aware `du` sizes as estimates; verify recovered space with `df` after any approved deletion.
