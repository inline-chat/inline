# Sparkle Direct Distribution Plan (2026-01-20)

This document consolidates the research and a production-ready plan to ship a Sparkle-powered auto-updating macOS DMG outside the App Store while preserving App Store/TestFlight distribution.

## Evidence from Local Repos

### Telegram macOS (local repo)
- A non-sandbox entitlements file exists with `com.apple.security.app-sandbox = false`.
- A separate sandbox entitlements file exists with `com.apple.security.app-sandbox = true`.
- This strongly suggests a dual-distribution setup (direct unsandboxed + App Store sandboxed).

Local file references:
- `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/Telegram-Mac.entitlements`
- `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/Telegram-Sandbox.entitlements`

### Ghostty macOS (local repo)
- The entitlements file contains no `com.apple.security.app-sandbox` key, implying unsandboxed distribution.
- Ghostty’s CI workflow downloads Sparkle tools, signs DMG via `sign_update`, updates appcast XML, and uploads artifacts to Cloudflare R2 with a custom domain.

Local file references:
- `/Users/mo/dev/ghostty/macos/Ghostty.entitlements`
- `/Users/mo/dev/ghostty/.github/workflows/release-tip.yml`

## Key Research (External Sources)

### Sparkle Documentation
- Sparkle 2 uses `SPUStandardUpdaterController` or `SPUUpdater` (deprecated `SUUpdater` only for legacy).
- Appcast requires `sparkle:version` (machine-readable) and `CFBundleVersion` must increase.
- `generate_keys` creates EdDSA key pairs; private key must stay off the hosting server.
- `sign_update` or `generate_appcast` must be used to sign updates.
- DMG is a recommended distribution format and should include an `/Applications` symlink.
- For sandboxed apps, `SUEnableInstallerLauncherService` and `-spks` + `-spki` mach-lookup exceptions are required.
- Avoid `codesign --deep`; sign Sparkle XPC services and helpers in order.

Docs:
- https://sparkle-project.org/documentation/
- https://sparkle-project.org/documentation/publishing/
- https://sparkle-project.org/documentation/customization/
- https://sparkle-project.org/documentation/sandboxing/
- https://sparkle-project.org/documentation/programmatic-setup/
- https://sparkle-project.github.io/documentation/api-reference/Classes/SUUpdater.html

### App Store / Distribution
- Separate build configurations/schemes are required to keep Sparkle out of App Store/TestFlight builds.
- Removing Sparkle after linking can cause runtime crashes; gating by build config is the safe path.

Docs:
- https://www.avanderlee.com/xcode/sparkle-distribution-apps-in-and-out-of-the-mac-app-store/

### Notarization / Signing
- Hardened runtime is required for notarization and must be enabled before notarization upload.

Docs:
- https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html

### CI / Notarization Experience
- GitHub Releases can be used for Sparkle distribution (per Steipete’s writeup), but a custom host gives better caching control.

Docs:
- https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears/

## Recommended Distribution Strategy

### High-Level Decision
- **Direct distribution (DMG + Sparkle):** Unsandboxed. Simpler Sparkle setup and fewer entitlements.
- **App Store/TestFlight:** Sandbox-enabled build without Sparkle linked.

This aligns with what’s observed in Telegram and Ghostty locally.

## Production Plan

### 1) Build Matrix and Schemes
- Create `Debug-Sparkle` / `Release-Sparkle` build configurations and a “Direct” scheme using them.
- App Store/TestFlight builds remain on existing configs (Sparkle-free).
- Add `SPARKLE` compiler flag for Sparkle builds; wrap Sparkle code in `#if SPARKLE`.
- Do not link Sparkle in App Store/TestFlight builds.

### 2) Sparkle Integration (Direct Build Only)
- Use `SPUStandardUpdaterController` or `SPUUpdater` (custom UI). Avoid deprecated `SUUpdater`.
- Add “Check for Updates…” menu item wired to Sparkle action.

Info.plist keys (Direct build only):
- `SUFeedURL`
- `SUPublicEDKey`

Optional:
- `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUScheduledCheckInterval`
- `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`

### 3) Sandboxing
- Direct build: **unsandboxed**.
- App Store/TestFlight build: sandboxed, no Sparkle.

If a sandboxed direct build is ever needed:
- Add `SUEnableInstallerLauncherService = YES`.
- Add `mach-lookup` exceptions for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`.
- Only enable `SUEnableDownloaderService` if you do not already require `com.apple.security.network.client`.

### 4) Keys + Signing
- Generate Sparkle EdDSA keys once via `generate_keys`.
- Embed public key (`SUPublicEDKey`) in Info.plist.
- Store private key only in CI secrets; never on hosting servers.

### 5) Packaging + Notarization
- Build using Xcode archive + export (or `xcodebuild archive` + `-exportArchive`).
- Ensure hardened runtime is enabled (required for notarization).
- Codesign Sparkle XPC services and helpers explicitly (no `--deep`).
- Build DMG with `/Applications` symlink.
- Notarize DMG with `notarytool`, then staple DMG and app.

### 6) Appcast Workflow
- Preferred: `generate_appcast` for signed appcast + delta updates.
- Ensure `CFBundleVersion` is monotonic.
- Optionally set `sparkle:minimumSystemVersion`.

### 7) GitHub Actions (Manual + Release)
- Download Sparkle tools in CI (from Sparkle release ZIP).
- Build Direct configuration and set Info.plist keys (build number + `SUPublicEDKey`).
- Codesign Sparkle helpers and app bundle.
- Create DMG, notarize, staple.
- Run `sign_update` or `generate_appcast`.
- Upload DMG and appcast; publish appcast after the DMG is live.

### 8) Hosting
- Ghostty uses Cloudflare R2 + custom domain. This is robust and CDN-friendly.
- Alternative: GitHub Releases with raw appcast URL (simpler, less control).

## Risks + Mitigations

- **App Store crash risk**: If Sparkle is linked then stripped, it can crash at launch. Use per-config linking.
- **Sandbox update failures**: Missing `-spks/-spki` entitlements cause update authorization errors. (Not relevant for unsandboxed direct build.)
- **Update not detected**: `CFBundleVersion` not incrementing prevents updates.
- **Notarization fail**: Missing hardened runtime or invalid signing order.

## Verification Checklist

- Install DMG on a clean Mac; verify Gatekeeper + notarization.
- Install older build; confirm Sparkle update is detected and installs.
- Confirm App Store/TestFlight build launches without Sparkle linked.

## Open Decisions

- Hosting: R2/custom domain vs GitHub Releases.
- Final confirmation: direct build unsandboxed (recommended).

## Production Readiness

Not production-ready until:
- Hosting and sandboxing choices are finalized.
- One end-to-end signed + notarized DMG update is verified.
