# macOS Direct Release (Sparkle)

This folder contains scripts for building the direct-distribution macOS app
with Sparkle (non-TestFlight) and preparing DMG artifacts.

## Overview

- Direct builds are **unsandboxed** and include Sparkle.
- TestFlight/App Store builds are **sandboxed** and exclude Sparkle.
- We reuse the **same bundle identifier** (`chat.inline.InlineMac`), which means
  direct and TestFlight builds cannot be installed side-by-side.

## Generating Sparkle Keys

1. Download Sparkle tools and run `generate_keys` once.
2. Store the **private key** in CI secrets (`MACOS_SPARKLE_PRIVATE_KEY`).
3. Use the **public key** for `SPARKLE_PUBLIC_KEY` (in CI: `MACOS_SPARKLE_PUBLIC_KEY`).

## Required Tools

- Xcode (via `xcode-select`)
- `create-dmg` (`npm install --global create-dmg`)
- `curl`, `unzip`, `rsync`
- `xcodeproj` gem (`gem install xcodeproj`) for `update-version.ts`

## Scripts

- `build-direct.sh`: builds a Sparkle-enabled app, injects Info.plist keys,
  signs Sparkle helpers + app, creates a DMG, and optionally notarizes.
  Xcode signing is disabled during the build to avoid provisioning profile
  requirements; the app is signed manually afterward.
- `update_appcast.py`: generates/updates an appcast from `sign_update` output.
- `validate_appcast.py`: validates Sparkle appcasts before upload.
- `release-direct.ts`: uploads DMG and/or appcast to R2 with cache headers.
- `release-local.sh`: runs a full local release (build → upload DMG → update appcast → upload appcast).
- `release-app.ts`: runs the same local release pipeline, but with an interactive TUI (shows progress, skipped steps, and failures clearly).
- `update-version.ts`: bumps the InlineMac marketing version, creates a `macos-vX.Y.Z` tag, and pushes to trigger CI.
- `appcast-only.sh`: updates the appcast only (no rebuild), with validation.

## Environment Variables

### Required for `build-direct.sh`

- `SPARKLE_PUBLIC_KEY` — Sparkle EdDSA public key (embedded into Info.plist).
- `MACOS_SPARKLE_PUBLIC_KEY` — accepted as an alias for `SPARKLE_PUBLIC_KEY`.
- `MACOS_CERTIFICATE_NAME` — signing identity (Keychain name).
- `MACOS_PROVISIONING_PROFILE_BASE64` or `MACOS_PROVISIONING_PROFILE_PATH` —
  required when using APS/keychain entitlements for direct distribution.

### Required for notarization (unless `SKIP_NOTARIZE=1`)

Choose one of the two auth methods below.

#### Option A: App Store Connect API key (recommended)

- `APPLE_NOTARIZATION_KEY`
- `APPLE_NOTARIZATION_KEY_ID`
- `APPLE_NOTARIZATION_ISSUER`

#### Option B: Apple ID + app-specific password

- `APPLE_ID`
- `APPLE_PASSWORD`
- `APPLE_TEAM_ID`

### Required for appcast signing

- `SPARKLE_PRIVATE_KEY` — Sparkle EdDSA private key (used by `sign_update`).
- `MACOS_SPARKLE_PRIVATE_KEY` — accepted as an alias for `SPARKLE_PRIVATE_KEY`.

### Required for R2 uploads

- `PUBLIC_RELEASES_R2_ACCESS_KEY_ID`
- `PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY`
- `PUBLIC_RELEASES_R2_BUCKET`
- `PUBLIC_RELEASES_R2_ENDPOINT`
- `PUBLIC_RELEASES_R2_PUBLIC_BASE_URL` (expected: `https://public-assets.inline.chat`)

### Optional

- `SPARKLE_VERSION` — Sparkle release version (default: 2.7.3)
- `SCHEME` — Xcode scheme for the macOS app (default: `Inline (macOS)`)
- `CHANNEL` — update channel (`stable` or `beta`, default: `stable`)
- `APPCAST_URL` — override appcast URL (defaults to `https://public-assets.inline.chat/mac/<channel>/appcast.xml`)
- `SPARKLE_DIR` — Sparkle download cache (default: `.action/sparkle`)
- `DERIVED_DATA` — Xcode derived data path (default: `build/InlineMacDirect`)
- `OUTPUT_DIR` — DMG output directory (default: `build/macos-direct`)
- `DMG_PATH` — output DMG path (default: `build/macos-direct/Inline.dmg`)
- `SKIP_NOTARIZE=1` — skip notarization (dev only)
- `UPLOAD_MODE` — for `release-direct.ts`: `all` (default), `dmg`, or `appcast`

### CI Secrets Mapping (GitHub Actions)

- `MACOS_CERTIFICATE`
- `MACOS_CERTIFICATE_PWD`
- `MACOS_CERTIFICATE_NAME`
- `MACOS_CI_KEYCHAIN_PWD`
- `MACOS_SPARKLE_PUBLIC_KEY`
- `MACOS_SPARKLE_PRIVATE_KEY`
- `MACOS_PROVISIONING_PROFILE_BASE64`
- `APPLE_NOTARIZATION_KEY`
- `APPLE_NOTARIZATION_KEY_ID`
- `APPLE_NOTARIZATION_ISSUER`
- `APPLE_ID`
- `APPLE_PASSWORD`
- `APPLE_TEAM_ID`
- `PUBLIC_RELEASES_R2_ACCESS_KEY_ID`
- `PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY`
- `PUBLIC_RELEASES_R2_BUCKET`
- `PUBLIC_RELEASES_R2_ENDPOINT`
- `PUBLIC_RELEASES_R2_PUBLIC_BASE_URL`

## GitHub Release Attachment

The workflow `macos-direct-release.yml` accepts an optional `tag` input. If set,
the DMG will be attached to that GitHub tag/release for traceability.

## Beta (Tip-Style) Releases

- Run the `macos-direct-release.yml` workflow manually with `channel = beta`.
- Leave `tag` empty so the workflow attaches the DMG to the `tip` release.
- The appcast is updated **after** the DMG is uploaded to avoid incomplete releases.

## Stable Release Guide

1. Ensure all CI secrets are set (including `MACOS_PROVISIONING_PROFILE_BASE64`).
2. Bump and tag the release:

```bash
bun run scripts/macos/update-version.ts --version X.Y.Z
```

Skip the confirmation prompt:

```bash
bun run scripts/macos/update-version.ts --version X.Y.Z -y
```

To undo the last macOS version bump (requires a clean git state):

```bash
bun run scripts/macos/update-version.ts --undo
```

3. CI will run `macos-direct-release.yml` on the `macos-vX.Y.Z` tag.
4. (Optional) Run `macos-direct-release.yml` manually with `channel = stable` if you need to rebuild.
5. Verify:
   - DMG is uploaded to R2 at `/mac/stable/<build>/Inline.dmg`.
   - Appcast at `/mac/stable/appcast.xml` points to the new build.
   - Notarization/stapling succeeded.

## Local Dev Usage (Direct Build)

```
export SPARKLE_PUBLIC_KEY="..."
export MACOS_CERTIFICATE_NAME="Developer ID Application: ..."
export SKIP_NOTARIZE=1
bash scripts/macos/build-direct.sh
```

The resulting DMG is written to `build/macos-direct/Inline.dmg`.

## Local Release (Stable/Beta)

The local release script uses the **same env var list as CI** (plus optional
`MACOS_PROVISIONING_PROFILE_PATH` for convenience).

```bash
bash scripts/macos/release-local.sh --channel stable
# or
bash scripts/macos/release-local.sh --channel beta
```

TUI version (recommended for local terminal usage):

```bash
cd scripts
bun run macos:release-app -- --channel beta
# or
bun run macos:release-app -- --channel stable
```

If you omit `--channel` in an interactive terminal, it will prompt you to choose (default: `beta`).

Skip steps (they remain visible as disabled in the UI):

```bash
cd scripts
bun run macos:release-app -- --channel beta --skip build,github
```

Dry run:

```bash
cd scripts
bun run macos:release-app -- --dry-run
```

Local release artifacts (signing key, sign_update output, appcast files) are
written under `build/macos-release-tmp/` and cleaned up each run.

## Appcast Only (No Rebuild)

```bash
bash scripts/macos/appcast-only.sh --channel beta
```

## Notes

- Sparkle private key is **never** embedded in the app bundle. It is only used
  for appcast signing in the release pipeline.
- This script does not upload artifacts. Uploads and appcast updates are handled
  by CI steps in later pipeline stages, with DMG uploads happening before appcast updates.
- Appcasts are validated locally and in CI before upload to avoid broken feeds.
