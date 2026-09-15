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
