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

- Install DMG on a clean Mac; verify Gatekeeper + notarization (launch without quarantine warnings).
- Confirm DMG includes `/Applications` symlink and app is codesigned.
- Install an older build; confirm Sparkle detects update and installs.
- Verify update channels:
  - Stable appcast URL (`/mac/stable/appcast.xml`)
  - Beta appcast URL (`/mac/beta/appcast.xml`)
- Confirm TestFlight build launches without Sparkle linked (no Sparkle.framework present).
- Confirm appcast signature validation succeeds (no “invalid signature” errors).
- Validate cache headers:
  - Appcast: `Cache-Control: no-cache, max-age=0, must-revalidate`
  - DMG: `Cache-Control: public, max-age=31536000, immutable`
- (Later) Add a Ghostty-style local test flow: host an appcast + DMG pair and verify update progression end-to-end.

## Locked Decisions (2026-01-21)

- Hosting: **Option 1**. Reuse existing assets bucket at `public-assets.inline.chat` with path-based channels.
  - Stable appcast: `https://public-assets.inline.chat/mac/stable/appcast.xml`
  - Beta appcast: `https://public-assets.inline.chat/mac/beta/appcast.xml`
  - Stable DMG: `https://public-assets.inline.chat/mac/stable/<build>/Inline.dmg`
  - Beta DMG: `https://public-assets.inline.chat/mac/beta/<build>/Inline.dmg`
- Direct distribution build: **unsandboxed**, Sparkle enabled.
- TestFlight/App Store build: **sandboxed**, Sparkle **excluded**.
- Sparkle configuration: **Option C** (post-build `PlistBuddy` edits in CI).
- Update channels: **two appcasts** (stable + beta) selected via `SPUUpdaterDelegate.feedURLString(for:)` (no Sparkle native channels).
- Update UI: **custom** via `SPUUpdater` + custom `SPUUserDriver`.
- Targets: **single app target** (`InlineMac`). Sparkle is manually integrated only for direct builds (no SPM).
- Bundle identifier: **reuse existing** (`chat.inline.InlineMac`). Note: direct + TestFlight builds cannot be installed side-by-side.

## Production Readiness

Not production-ready until:
- Hosting and sandboxing choices are finalized. (Now locked.)
- One end-to-end signed + notarized DMG update is verified.

## Detailed Implementation Plan (InlineMac + CI)

### A) App Architecture (Direct Builds Only)
1. Keep a single app target (`InlineMac`) and use build-config gating (`SPARKLE`) for direct builds.
2. Manually integrate Sparkle (no SPM) by downloading the Sparkle XCFramework in CI and linking only for Sparkle builds.
3. Use separate entitlements files: sandboxed for TestFlight builds, unsandboxed for direct builds.
4. Introduce a small Update module (new files under `apple/InlineMac/Features/Update/`):
   - `UpdateController`: wraps `SPUUpdater`.
   - `UpdateDriver`: custom `SPUUserDriver` to drive custom UI.
   - `UpdateDelegate`: implements `SPUUpdaterDelegate` and returns the correct appcast URL.
5. Add a channel setting (stable/beta) with UserDefaults-backed storage.
6. Add "Check for Updates…" menu item (App menu) wired to the update controller.
7. Ensure all Sparkle code is guarded with `#if SPARKLE` to keep TestFlight/App Store builds Sparkle-free.

### B) Info.plist (Option C, CI-only)
1. Post-build `PlistBuddy` edits in CI (Direct build only):
   - `CFBundleVersion` = commit count (`git rev-list --count HEAD`).
   - `SUPublicEDKey` = Sparkle public key from secrets.
   - `SUFeedURL` = stable appcast URL by default.
2. Do not store Sparkle keys in repo. Only public key in CI injection.

### C) Packaging + Notarization (Direct Builds Only)
1. Use `create-dmg` to generate `Inline.dmg` with `/Applications` symlink.
2. Notarize DMG via `notarytool`, then staple both DMG and app.

### D) Appcast + Uploads (Direct Builds Only)
1. Sign updates with Sparkle `sign_update` (EdDSA) and update appcast.
2. Upload DMG + appcast to `public-assets.inline.chat`:
   - `mac/stable/<build>/Inline.dmg`
   - `mac/beta/<build>/Inline.dmg`
3. Upload DMG artifact to the GitHub tag/release for the build.
4. Cache headers:
   - Appcast: `Cache-Control: no-cache, max-age=0, must-revalidate`
   - DMG: `Cache-Control: public, max-age=31536000, immutable`

### E) TestFlight/App Store Builds
1. Use existing App Store/TestFlight configuration.
2. Ensure Sparkle is not linked; no Sparkle frameworks in the app bundle.

## Master TODO List (with Breakpoints)

### Batch 1 — App-side scaffolding (review after this batch)
- Add update channel setting (stable/beta) + default.
- Add Update module skeleton (`UpdateController`, `UpdateDriver`, `UpdateDelegate`) behind `#if SPARKLE`.
- Add "Check for Updates…" menu item (guarded by `#if SPARKLE`).

### Batch 2 — Sparkle integration (review after this batch)
- Wire Update module into AppDelegate lifecycle.
- Add custom update UI view(s) and connect to UpdateDriver.

### Batch 3 — CI pipeline (review after this batch)
- Set `SPARKLE` compilation condition for direct builds only.
- Add build-config-gated link/embed steps (Sparkle builds only).
- Add build-number + Sparkle plist injection via `PlistBuddy`.
- Build + sign Sparkle helpers and app bundle.
- Create DMG via `create-dmg`.
- Notarize + staple DMG and app.

### Batch 4 — Appcast + uploads (review after this batch)
- Generate appcast (signed) and update content.
- Upload DMG + appcast to `public-assets.inline.chat` paths.
- Upload DMG to GitHub tag/release.
- Apply cache headers (appcast vs DMG).

### Batch 5 — Validation + release checklist (review after this batch)
- Install DMG on clean Mac (Gatekeeper + notarization).
- Install older build and verify Sparkle updates.
- Confirm TestFlight build launches without Sparkle linked.

## Modified Files (Tracking)

- `apple/InlineMac/Views/Settings/AppSettings.swift`
- `apple/InlineMac/Views/Settings/Views/GeneralSettingsDetailView.swift`
- `apple/InlineMac/Features/Update/UpdateController.swift`
- `apple/InlineMac/Features/Update/UpdateDriver.swift`
- `apple/InlineMac/Features/Update/UpdateDelegate.swift`
- `apple/InlineMac/Features/Update/UpdateViewModel.swift`
- `apple/InlineMac/Features/Update/UpdateWindowController.swift`
- `apple/InlineMac/Features/Update/UpdateWindowView.swift`
- `apple/InlineMac/App/AppMenu.swift`
- `apple/InlineMac/App/AppDelegate.swift`
- `apple/InlineMac/InlineMacDirect.entitlements`
- `scripts/macos/build-direct.sh`
- `scripts/macos/README.md`
- `scripts/macos/update_appcast.py`
- `scripts/macos/release-direct.ts`
- `scripts/package.json`
- `.github/workflows/macos-direct-release.yml`

## Production Deploy Steps (Draft)

1. Ensure Sparkle keys are set in CI secrets (public + private).
2. Run Direct build pipeline (Sparkle) and verify DMG + appcast URLs.
3. Validate Sparkle update flow on a clean macOS install.
4. Publish/trigger TestFlight build (no Sparkle).
5. Attach DMG to GitHub tag/release for traceability.
6. Confirm appcast + DMG links are reachable and cached as expected.

## Changelog (Future)

Not a priority right now. When needed, we can generate changelogs from git history
or use GitHub Releases notes and link them from the appcast.
