# Apple clients

Open `Inline.xcodeproj` in this directory. Shared schemes include `Inline (macOS)`
and `Inline (iOS)`. Build and run the selected scheme with Xcode.

Use `Local.xcconfig.sample` as a reference for a gitignored `Local.xcconfig`. Review the API host and profile
before running. Physical iOS devices need a reachable host, not the Mac's localhost.

Select your development signing team in Xcode. Signing credentials and personal
Xcode settings are not distributed with this repository.

Run the macOS app first, then test on a physical iOS device. Check login,
send/receive, attachments, threads and reconnect after a network interruption.
Avoid running both builds concurrently on a resource-constrained machine.

Fast source checks, from the repository root:

```sh
bash scripts/apple/check-source-contracts.sh
```

These checks do not replace a build or signed-in device testing.

## Releases

`macOS Tip` and `iOS Early Testers` automatically select green Apple commits on
main. To publish Beta, run `macOS Beta` on main; it builds, signs and notarizes
the newest qualified source using the same publisher as Tip. Each channel has
its own build and feed. Beta retries allocate an unused build number so a
partial upload never requires overwriting a DMG.

Run `iOS TestFlight` on main to distribute the latest verified internal build to
the existing External Early Users group. It reuses the Xcode Cloud archive,
handles beta review and starts testing when approved. Pending Apple review is
reported as deferred; App Store submission remains in App Store Connect.

Apple publishing jobs use the main-only `apple` GitHub environment. Signing and
upload credentials shared with the CLI also live in its `cli` environment.
