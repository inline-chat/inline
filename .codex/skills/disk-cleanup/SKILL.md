---
name: disk-cleanup
description: Audit and reclaim disk space on macOS with guarded safe, extra, and deep cleanup tiers. Use when disk space is low, builds fail with no-space errors, or the user asks to inspect, clean, prune, or remove caches, temporary files, Docker artifacts, Xcode data, build outputs, node_modules, target directories, or other reproducible developer artifacts.
---

# Disk Cleanup

Use `scripts/disk-cleanup.sh` for repeatable audits and cleanup. Keep source, personal data, credentials, databases, Docker volumes, and `.env` files out of scope.

## Workflow

1. Run `scripts/disk-cleanup.sh <mode>` without mutation flags.
2. Report available disk space and the candidate groups with approximate sizes.
3. Call out anything surprising, currently active, or outside known disposable paths.
4. Ask for explicit confirmation naming the tier before deletion. A prior general request to free space is not confirmation for a particular destructive run.
5. After confirmation, run the same command with `--execute --yes`.
6. Run the audit again and report space recovered, failures, and skipped targets.

Never read, print, edit, or delete `.env` files. Do not broaden targets by improvising `rm`, `git clean`, or wildcard deletion. Do not run cleanup while a relevant build is active; inspect the repository's `.running` file when operating inside a project that uses one.

## Modes

Modes are cumulative:

- `safe`: old temporary files; Trash; Sparkle updater caches; old Xcode DerivedData entries; stale project build outputs in non-current projects; old `node_modules` and Rust `target` directories; stopped Docker containers; dangling Docker images; Docker build cache. Items may be recreated or redownloaded, but current-project and recently modified developer outputs are excluded.
- `extra`: everything in `safe`, plus hot package/module caches, all Xcode DerivedData, current-project build outputs (`build`, `.build`, `DerivedData`, and `target`), and common Bun/npm/Cargo/Go/SwiftPM/Playwright caches.
- `deep`: everything in `extra`, plus dependency trees across developer projects, unavailable Apple simulators, unused Docker images, and unused Docker networks. It still never deletes Docker volumes, databases, source, documents, downloads, archives, keychains, app support, or simulator devices that remain available.

Use `safe` by default when the user does not choose a tier. Treat `extra` and `deep` as increasingly disruptive because subsequent builds and installs may be slow or require network access.

## Script usage

```sh
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh safe
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh extra --project /absolute/project/path
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh deep --project /absolute/project/path
```

Execution requires the deliberate double opt-in:

```sh
.codex/skills/disk-cleanup/scripts/disk-cleanup.sh safe --execute --yes
```

Optional controls:

- `--project PATH`: identify the active project to protect in `safe` and clean in `extra`/`deep`; defaults to the current directory.
- `--dev-root PATH`: add a root searched for stale developer outputs; repeat as needed. Defaults to `~/dev` when present.
- `--older-than DAYS`: age threshold for stale targets in `safe`; defaults to 30 days.
- `--json`: emit machine-readable audit output. Do not combine with `--execute`.

If a tool such as Docker, Xcode, Bun, npm, Cargo, or Go is unavailable, skip its group and continue. Surface permission failures rather than escalating or deleting through another mechanism.
