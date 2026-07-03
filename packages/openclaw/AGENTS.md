# OpenClaw Plugin Agent Instructions

## Compatibility

- Keep the compatibility table in `README.md` updated whenever the plugin version, OpenClaw host requirement, or Inline realtime SDK dependency changes.
- The table should include the current plugin line plus at most five past plugin version lines. Prune older rows instead of letting the table grow indefinitely.
- Each compatibility row should state the plugin version, supported OpenClaw host range or minimum host version, Inline realtime SDK version, status, and any important migration note.
- When dropping OpenClaw host support, document the legacy plugin line in the table and update `peerDependencies.openclaw`, `openclaw.install.minHostVersion`, `openclaw.compat.pluginApi`, `openclaw.build.openclawVersion`, and `src/manifest.test.ts` together.
- Before a release, compare the latest OpenClaw changelog/API surface against SDK imports, channel routing, native command status, native approvals, and system event option usage.
