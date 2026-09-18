# Local iOS apps

Run `bun run ios:debug -- --device-only --no-logs` from the repository root for
the regular Debug app.

Run `bun run ios:dev -- --device-only --no-logs` for **Inline-Dev**. Like macOS
Inline-Dev, this builds the current working tree with the release-based
`DevBuild` configuration, `DEBUG_BUILD` diagnostics, and the production API.
It installs alongside Inline and Inline Debug as `chat.inline.InlineIOS.devbuild`.

Sign in with your real account to sync its chats. The `devbuild` profile keeps
authentication, database encryption keys, and the local database separate from
the other iOS apps. The share extension uses the same profile and separate
recipient/avatar cache files. This does not copy the production app's local cache.

Production push delivery currently targets the regular iOS app's bundle ID, so
push notifications are not supported for this separate DevBuild. Foreground chat
sync uses the normal production connection.

The first build requires an Xcode account with permission to provision the new
app and extension identifiers for the Inline development team. The runner enables
automatic provisioning updates for DevBuild and retains the app's entitlements.

Both commands support `--device <hardware-UDID>`, `--no-launch` (build only), and
`--no-build` (reuse the existing build, then install and launch). Use `--logs` to
stream app logs. Physical devices are the default; simulator use requires an
explicit `--allow-simulator`.
