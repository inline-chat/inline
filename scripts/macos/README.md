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

## Scripts

- `build-direct.sh`: builds a Sparkle-enabled app, injects Info.plist keys,
  signs Sparkle helpers + app, creates a DMG, and optionally notarizes.
  Xcode signing is disabled during the build to avoid provisioning profile
  requirements; the app is signed manually afterward.
- `update_appcast.py`: generates/updates an appcast from `sign_update` output.
- `release-direct.ts`: uploads DMG + appcast to R2 with cache headers.

## Environment Variables

### Required for `build-direct.sh`

- `SPARKLE_PUBLIC_KEY` — Sparkle EdDSA public key (embedded into Info.plist).
- `MACOS_CERTIFICATE_NAME` — signing identity (Keychain name).

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

### Required for R2 uploads

- `PUBLIC_RELEASES_R2_ACCESS_KEY_ID`
- `PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY`
- `PUBLIC_RELEASES_R2_BUCKET`
- `PUBLIC_RELEASES_R2_ENDPOINT`
- `PUBLIC_RELEASES_R2_PUBLIC_BASE_URL` (expected: `https://public-assets.inline.chat`)
- `PUBLIC_RELEASES_R2_PREFIX` (set to `mac`)

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

### CI Secrets Mapping (GitHub Actions)

- `MACOS_CERTIFICATE`
- `MACOS_CERTIFICATE_PWD`
- `MACOS_CERTIFICATE_NAME`
- `MACOS_CI_KEYCHAIN_PWD`
- `MACOS_SPARKLE_PUBLIC_KEY`
- `MACOS_SPARKLE_PRIVATE_KEY`
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

## Local Dev Usage (Direct Build)

```
export SPARKLE_PUBLIC_KEY="..."
export MACOS_CERTIFICATE_NAME="Developer ID Application: ..."
export SKIP_NOTARIZE=1
bash scripts/macos/build-direct.sh
```

The resulting DMG is written to `build/macos-direct/Inline.dmg`.

## Notes

- Sparkle private key is **never** embedded in the app bundle. It is only used
  for appcast signing in the release pipeline.
- This script does not upload artifacts. Uploads and appcast updates are handled
  by CI steps in later pipeline stages.
