# OpenClaw Plugin Agent Instructions

## Compatibility

- Support OpenClaw from `2026.11.1` with a minimum-only range. Never add an upper bound to host peer or plugin API compatibility. The `0.0.x` line (`0.0.72`) is the legacy line for `2026.8.2` through `2026.10.x`.
- 1.0 uses the host's async SDK APIs and `MessagePresentation` only. Don't reintroduce the deprecated synchronous calls or the InteractiveReply bridge; they are removed in the first January 2027 stable host.
- Keep CI to at most three hosts: the minimum host, one intermediate release when the floor and `latest` differ, and npm `latest`; a pinned development host is build provenance, not a support cap.
- Keep the compatibility table in `README.md` updated whenever the plugin version, OpenClaw host requirement, or Inline realtime SDK dependency changes.
- The table should include the current plugin line plus at most five past plugin version lines. Prune older rows instead of letting the table grow indefinitely.
- Each compatibility row should state the plugin version, supported OpenClaw host range or minimum host version, Inline realtime SDK version, status, and any important migration note.
- When dropping OpenClaw host support, document the legacy plugin line in the table and update `peerDependencies.openclaw`, `openclaw.install.minHostVersion`, `openclaw.compat.pluginApi`, `openclaw.build.openclawVersion`, and `src/manifest.test.ts` together.
- Before a release, compare the latest OpenClaw changelog/API surface against SDK imports, channel routing, native command status, native approvals, and system event option usage.
