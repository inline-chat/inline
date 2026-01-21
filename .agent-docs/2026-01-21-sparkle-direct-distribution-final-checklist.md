# Sparkle Direct Distribution Final Checklist (2026-01-21)

This checklist reflects what is **already implemented in the repo** vs **still pending** based on the current working tree.

## ✅ App-side (implemented)

- [x] Sparkle code gated with `#if SPARKLE`.
  - `apple/InlineMac/Features/Update/UpdateController.swift`
  - `apple/InlineMac/Features/Update/UpdateDelegate.swift`
  - `apple/InlineMac/Features/Update/UpdateDriver.swift`
  - `apple/InlineMac/Features/Update/UpdateViewModel.swift`
  - `apple/InlineMac/Features/Update/UpdateWindowController.swift`
  - `apple/InlineMac/Features/Update/UpdateWindowView.swift`
- [x] Update controller wired into app lifecycle (`startIfNeeded`) and manual check action.
  - `apple/InlineMac/App/AppDelegate.swift`
- [x] “Check for Updates…” menu item wired to AppDelegate action.
  - `apple/InlineMac/App/AppMenu.swift`
- [x] Update channel setting (stable/beta) added to app settings.
  - `apple/InlineMac/Views/Settings/AppSettings.swift`
  - `apple/InlineMac/Views/Settings/Views/GeneralSettingsDetailView.swift`
- [x] Direct distribution entitlements file (unsandboxed) added.
  - `apple/InlineMac/InlineMacDirect.entitlements`

## ✅ Build + packaging scripts (implemented)

- [x] Direct build script (Sparkle download, build, plist injection, codesign, DMG, notarize).
  - `scripts/macos/build-direct.sh`
- [x] Appcast generation/update script.
  - `scripts/macos/update_appcast.py`
- [x] R2 upload script with cache headers.
  - `scripts/macos/release-direct.ts`
- [x] Script entry in `scripts/package.json`.
  - `scripts/package.json` (`release:macos`)
- [x] Documentation for local + CI usage.
  - `scripts/macos/README.md`

## ✅ CI workflow (implemented, not yet run)

- [x] GitHub Actions workflow for direct release (manual dispatch).
  - `.github/workflows/macos-direct-release.yml`

## ⏳ External prerequisites (pending / user action)

- [ ] Sparkle keys generated and stored.
  - `MACOS_SPARKLE_PUBLIC_KEY` (CI) + `SPARKLE_PUBLIC_KEY` (local)
  - `MACOS_SPARKLE_PRIVATE_KEY` (CI)
- [ ] Developer ID Application certificate exported + base64 secret created.
  - `MACOS_CERTIFICATE`
  - `MACOS_CERTIFICATE_PWD`
  - `MACOS_CERTIFICATE_NAME`
  - `MACOS_CI_KEYCHAIN_PWD`
- [ ] App Store Connect notarization API key created.
  - `APPLE_NOTARIZATION_KEY`
  - `APPLE_NOTARIZATION_KEY_ID`
  - `APPLE_NOTARIZATION_ISSUER`
- [ ] R2 (public assets) secrets configured.
  - `PUBLIC_RELEASES_R2_ACCESS_KEY_ID`
  - `PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY`
  - `PUBLIC_RELEASES_R2_BUCKET`
  - `PUBLIC_RELEASES_R2_ENDPOINT`
  - `PUBLIC_RELEASES_R2_PUBLIC_BASE_URL`
  - `PUBLIC_RELEASES_R2_PREFIX=mac`
- [ ] GitHub Actions permissions allow `contents: write` for release uploads.

## ⏳ Validation steps (pending / run once prerequisites are set)

- [ ] Local direct build (optional): `bash scripts/macos/build-direct.sh`
  - Expected DMG: `build/macos-direct/Inline.dmg`
- [ ] First CI run: `.github/workflows/macos-direct-release.yml`
  - Validate appcast URL and DMG URL by channel.
- [ ] Gatekeeper + notarization check on clean macOS install.
- [ ] Sparkle update flow test (older build → update).
- [ ] Confirm TestFlight build launches without Sparkle framework linked.
- [ ] Confirm cache headers for appcast vs DMG in R2.

## Notes

- Direct and TestFlight builds reuse the same bundle ID (`chat.inline.InlineMac`) and cannot be installed side-by-side.
- Sparkle keys are not stored in repo; public key is injected during build.
