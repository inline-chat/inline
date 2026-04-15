# macOS Release Verification Script Agent Doc

## Goal

Create a script that verifies a completed macOS direct-distribution release end to end without rebuilding anything.

The script should catch the exact class of problems we just checked manually:

- wrong DMG uploaded
- wrong GitHub release asset attached
- appcast pointing at the wrong build
- appcast metadata not matching the built app
- DMG/app missing notarization, stapling, or valid Developer ID signing

This is a verification tool only. Do not make it mutate release state.

## Proposed Location

- `scripts/macos/verify-release.ts`

Use Bun/TypeScript so it fits the rest of the local release tooling.

## CLI Shape

Support:

- `--channel stable|beta`
- `--release-tag <tag>`
- `--app-path <path>`
- `--dmg-path <path>`
- `--appcast-url <url>`
- `--dmg-url <url>`
- `--github-tag <tag>`
- `--json`

Defaults:

- `channel=beta`
- `app-path=<root>/build/InlineMacDirect/Build/Products/Release/Inline.app`
- `dmg-path=<root>/build/macos-direct/Inline.dmg`
- `appcast-url=https://public-assets.inline.chat/mac/<channel>/appcast.xml`
- `dmg-url` inferred from local build number if not provided
- `github-tag=tip` for beta, empty for stable unless explicitly passed

If `--release-tag` and `--github-tag` overlap, keep one source of truth. Prefer a single `--github-tag`.

## Required Checks

### 1. Local app metadata

Read `Contents/Info.plist` from the local app and capture:

- `CFBundleShortVersionString`
- `CFBundleVersion`
- `InlineCommit`
- `LSMinimumSystemVersion`
- `SUFeedURL`
- `SUPublicEDKey`

Fail if the app does not exist or if required keys are missing.

### 2. Local DMG facts

Collect:

- file size
- SHA-256
- modified time

This becomes the reference for remote comparisons.

### 3. Local signing and notarization

Run and validate:

- `xcrun stapler validate <dmg>`
- `spctl -a -vvv -t open --context context:primary-signature <dmg>`
- `codesign --verify --deep --strict --verbose=2 <app>`
- `codesign -dv --verbose=4 <app>`

Expected outcomes:

- DMG accepted by Gatekeeper
- source contains `Notarized Developer ID`
- app signature authority chain is Developer ID
- app has hardened runtime
- app shows `Notarization Ticket=stapled`

Do not just print the command output. Parse for specific signals and classify pass/fail clearly.

### 4. Mounted app inside shipped DMG

Mount the DMG read-only with `hdiutil attach -nobrowse -readonly -plist`.

Find the mounted `.app` and verify:

- `spctl -a -vvv <mounted-app>`
- `codesign -dv --verbose=4 <mounted-app>`

Compare the mounted app against the local built app:

- identifier
- team ID
- authority/origin
- `Notarization Ticket=stapled`
- optionally CDHash

Always detach the DMG in a `finally` path.

### 5. Remote appcast

Fetch the remote appcast and inspect the latest item only.

Extract:

- title
- `sparkle:version`
- `sparkle:shortVersionString`
- `sparkle:minimumSystemVersion`
- description text
- enclosure URL
- enclosure length
- enclosure signature

Verify:

- appcast build equals local `CFBundleVersion`
- appcast short version equals local `CFBundleShortVersionString`
- appcast enclosure URL equals expected DMG URL
- appcast enclosure length equals local DMG size
- appcast contains a non-empty Sparkle signature
- appcast minimum system version matches local `LSMinimumSystemVersion`

This last check matters. We already found a real mismatch:

- local app `LSMinimumSystemVersion = 15.2`
- published beta appcast `sparkle:minimumSystemVersion = 15.0`

The script must fail on that mismatch.

### 6. Remote DMG

Run:

- `curl -fsI <dmg-url>`

Verify:

- HTTP 200
- `content-length` equals local DMG size

If `etag` or other metadata is present, print it, but do not require it.

### 7. GitHub release asset

If a GitHub tag is configured, inspect the asset with `gh release view <tag> --json ...`.

Verify the DMG asset:

- exists
- filename is `Inline.dmg`
- asset size equals local DMG size
- if GitHub provides digest, it equals local SHA-256

For beta, this should usually check `tip`.

## Output Format

Default output should be human-readable and short.

Suggested sections:

- `Local app`
- `Local DMG`
- `Signing and notarization`
- `Remote appcast`
- `Remote DMG`
- `GitHub release`
- `Result`

For each check, print:

- `OK`
- `FAIL`
- `WARN`

On failure, print the exact mismatched values.

Example:

- `FAIL appcast minimum macOS mismatch: local=15.2 remote=15.0`

If `--json` is passed, emit structured results with:

- overall status
- check list
- local metadata
- remote metadata
- mismatches

## Exit Codes

- `0` if all required checks pass
- `1` if any required verification fails
- `2` for usage or missing prerequisite errors

## Implementation Notes

- Do not read or print `.env` contents.
- Reuse existing local command-line tools already expected by the release flow: `curl`, `gh`, `codesign`, `spctl`, `xcrun`, `hdiutil`, `shasum`.
- Keep network access read-only.
- Prefer parsing command output over raw passthrough.
- If `gh` is unavailable and GitHub verification is requested, fail with a clear prerequisite error.
- Mounting the DMG is safe, but always detach it even on failure.
- If the appcast contains multiple items, always verify the latest one.

## Nice-to-Have

- `--skip github`, `--skip remote`, or similar targeted skips
- support verifying a stable tagged release by explicit tag
- optional comparison of mounted-app plist values vs local plist values
- optional support for verifying a release solely from remote URLs when local artifacts are unavailable

## Non-Goals

- no rebuilding
- no uploading
- no appcast regeneration
- no modifying GitHub releases
- no rollback behavior

## Suggested Follow-Up

After this script exists, add a final verification step to the local release pipeline and/or expose a standalone command:

- `cd scripts && bun run macos:verify-release -- --channel beta`

That should run after upload and before declaring the release complete.
