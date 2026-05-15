# macOS Direct Release

This folder is the local release path for the direct-distribution macOS app.
Use it for both beta and stable Sparkle releases. Do not use CI for the normal
release path.

Direct builds are unsandboxed and include Sparkle. TestFlight/App Store builds
are sandboxed and exclude Sparkle. Both use the same bundle identifier,
`chat.inline.InlineMac`, so they cannot be installed side by side.

## Release Commands

Run from `scripts/`.

```bash
# Check tools and show the pipeline without building or uploading.
bun run macos:release-app -- --channel stable --dry-run

# Publish stable.
bun run macos:release-app -- --channel stable

# Publish beta.
bun run macos:release-app -- --channel beta
```

The command runs:

1. Preflight tool checks.
2. Build, sign, create DMG, notarize, and staple.
3. Post-check the DMG, code signature, Gatekeeper, Sparkle keys, and archs.
4. Verify the built app metadata (`CFBundleVersion`, `InlineCommit`, and
   `SUFeedURL`) matches the selected release.
5. Upload the DMG to R2.
6. Verify the public DMG URL.
7. Sign and generate the Sparkle appcast.
8. Validate and upload the appcast.

Stable publishes to:

- `https://public-assets.inline.chat/mac/stable/<build>/Inline.dmg`
- `https://public-assets.inline.chat/mac/stable/appcast.xml`

Beta publishes to:

- `https://public-assets.inline.chat/mac/beta/<build>/Inline.dmg`
- `https://public-assets.inline.chat/mac/beta/appcast.xml`

Beta also updates the GitHub `tip` release by default. Add
`--skip-github-release` if you only want the Sparkle/R2 release. Stable does not
use a GitHub release tag unless you pass `--release-tag`.

Stable releases fail during preflight when the worktree is dirty. Commit the
changes first. For intentional local/dev stable builds only, pass `--allow-dirty`.

Every successful local release operation writes a non-secret record under:

```text
build/macos-release-history/
```

## Local Test Build

To build an installable local app without DMG creation, notarization, or upload:

```bash
cd scripts
bun run macos:build-local-app -- --channel stable
```

Output:

```text
build/InlineMacDirectLocal/Build/Products/DevBuild/Inline-Dev.app
```

This uses the isolated `DevBuild` flavor, enables `DEBUG_BUILD`, embeds the
selected Sparkle channel, and signs locally by default.

## Required Local Setup

Tools:

- Xcode selected with `xcode-select`.
- `create-dmg`.
- `curl`, `unzip`, `rsync`, `python3`, `xcrun`, `codesign`, `security`,
  `hdiutil`, `spctl`, `lipo`.

Signing and Sparkle env vars:

- `SPARKLE_PUBLIC_KEY` or `MACOS_SPARKLE_PUBLIC_KEY`.
- `SPARKLE_PRIVATE_KEY` or `MACOS_SPARKLE_PRIVATE_KEY`.
- `MACOS_CERTIFICATE_NAME`.
- `MACOS_PROVISIONING_PROFILE_BASE64` or `MACOS_PROVISIONING_PROFILE_PATH`
  when the direct entitlements include APS/keychain groups.

Notarization env vars, using one auth method:

- API key: `APPLE_NOTARIZATION_KEY`, `APPLE_NOTARIZATION_KEY_ID`,
  `APPLE_NOTARIZATION_ISSUER`.
- Apple ID: `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`.

R2 upload env vars:

- `PUBLIC_RELEASES_R2_ACCESS_KEY_ID`.
- `PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY`.
- `PUBLIC_RELEASES_R2_BUCKET`.
- `PUBLIC_RELEASES_R2_ENDPOINT`.
- `PUBLIC_RELEASES_R2_PUBLIC_BASE_URL`.

Sentry dSYM upload is skipped by default. Add `--upload-sentry-dsyms` when the
Sentry credential flow is available.

## Useful Options

```bash
# Pause after app/DMG creation so you can inspect locally before notarization.
bun run macos:release-app -- --channel stable --pause-before-notarize

# Resume from a step after fixing a transient failure.
bun run macos:release-app -- --channel stable --from post-check

# Skip a step explicitly.
bun run macos:release-app -- --channel beta --skip github

# Intentional local/dev stable build from a dirty worktree.
bun run macos:release-app -- --channel stable --allow-dirty
```

Known step ids:

```text
build, upload-sentry-dsyms, post-check, upload-dmg, verify-dmg,
gen-appcast, validate-appcast, upload-appcast, github
```

Aliases:

- `upload`: `upload-dmg` and `upload-appcast`.
- `appcast`: `gen-appcast`, `validate-appcast`, and `upload-appcast`.

## Versioning

The release build number is `git rev-list --count HEAD`. The app also records
the current short commit in `InlineCommit`.

If the marketing version needs to change, make that change and commit it before
running the local release. `macos:update-version` is a legacy helper that commits,
tags, and pushes for the old CI-triggered flow, so do not use it as the default
local release path.

## Rollback

Rollback republishes only `appcast.xml`; it does not delete uploaded DMGs and it
does not downgrade users who already installed the bad build.

```bash
cd scripts

# Roll stable back to the previous appcast item.
bun run macos:release-app -- --channel stable --rollback

# Roll back to a specific uploaded build.
bun run macos:release-app -- --channel stable --rollback --rollback-to-build 12345

# Preview rollback work.
bun run macos:release-app -- --channel stable --rollback --dry-run
```

## Appcast Prune

Use prune when a stale non-latest build should be removed from the live appcast
without changing the current latest build. This republishes only `appcast.xml`.

```bash
cd scripts

# Remove one stale build from stable.
bun run macos:release-app -- --channel stable --drop-build 12345

# Preview the prune path.
bun run macos:release-app -- --channel stable --drop-build 12345 --dry-run
```

If the build you pass is the latest appcast item, use rollback instead.

## Lower-Level Scripts

- `build-direct.sh`: build, sign, DMG, notarize, and staple.
- `sign-direct.sh`: sign an existing app bundle and nested Sparkle code.
- `post-check.sh`: validate DMG, stapling, Gatekeeper, signatures, Sparkle keys,
  and architecture.
- `release-direct.ts`: upload DMG and/or appcast to R2.
- `update_appcast.py`: generate the Sparkle appcast from `sign_update` output.
- `validate_appcast.py`: validate appcasts before upload.
- `rollback_appcast.py`: remove newer entries from an appcast for rollback.
- `prune_appcast.py`: remove one stale non-latest item from an appcast.
- `build-local-app.sh`: create a local `Inline-Dev.app` for testing.
