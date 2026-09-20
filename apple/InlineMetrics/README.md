# Inline Metrics for Mac

A standalone, admin-only macOS 14+ companion app with small, medium and large desktop widgets. It does not modify or require the Inline chat app.

## Install a shared build

Unzip `Inline-Metrics-macOS.zip`, drag **Inline Metrics.app** into Applications, and open it. Sign in with your own Inline admin account, then right-click the desktop → **Edit Widgets** → **Inline Metrics**. Enable **Open at login** to keep it available after restarts. See [INSTALL.txt](INSTALL.txt) for the complete recipient instructions, including opening an internal development build.

The package supports Apple Silicon and Intel Macs. It contains no saved session, personal settings or cached metrics; those live outside the app bundle on each person's Mac. A normal Inline chat account does not grant admin access.

## Package a build for another admin

The committed Xcode project is ready to build; XcodeGen is only needed after changing `project.yml`.

```sh
cd apple/InlineMetrics
./scripts/package.sh --team YOUR_TEAM_ID
```

The script creates a universal **Release** build, verifies the app and widget signatures and architectures, and creates a ZIP with installation instructions under `build/packages/`. It leaves the currently installed app alone. An alternate installed signing identity can be selected with `--identity 'Developer ID Application: …'`.

The available development identity produces an internal build. For a normal Gatekeeper-approved download, a maintainer must use a Developer ID Application certificate and notarize the app with Apple; this script does not submit anything to Apple's services. [Apple's distribution signing guide](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

## Build and install

Requires Xcode, plus an installed Apple Development signing identity. Pass your certificate's team ID; personal signing settings are not checked in. Install XcodeGen if you need to regenerate the project.

```sh
cd apple/InlineMetrics
# Only needed after editing project.yml: xcodegen generate
xcodebuild -project InlineMetrics.xcodeproj -scheme InlineMetrics \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

Copy `build/Build/Products/Debug/Inline Metrics.app` into `~/Applications`, then open it. Sign in with your existing admin email, password and authenticator code. Finish any initial admin account setup on the website first.

Right-click the desktop → **Edit Widgets** → **Inline Metrics**, then select a widget size. The companion remains in the menu bar after closing its window. Enable **Open at login** to keep it available after restarting your Mac. Clicking a widget opens the companion and refreshes its data.

## Refresh and authentication

- The companion requests `/admin/metrics/overview` approximately every 5 minutes while running, on wake, and on manual refresh. It uses a macOS background activity with 30 seconds of scheduling tolerance. Sleeping Macs and system scheduling can delay checks.
- A change in aggregate values requests a widget reload immediately after the fetch. If values are unchanged, the companion requests a freshness update every 15 minutes. Manual refresh always requests a redraw. WidgetKit controls when those requests appear on the desktop; this is polling, not a server push subscription.
- Medium and large widgets include a refresh link that opens the companion and checks immediately.
- Closing the window keeps updates running; quitting the app stops fetching. After 45 minutes the widget asks you to open the app to update.
- Sign-in uses the existing `/admin/auth/login` endpoint and a stable User-Agent, because the server binds sessions to that value. The session lives in the app's login Keychain; passwords and authenticator codes are not saved.
- Existing server limits apply: a 24-hour idle timeout and a maximum 3-day session. Expiry requires signing in again in the companion. There is no token refresh endpoint. Long-lived unattended access would need a separately designed server capability with read-only metric permissions.
- The widget has no network entitlement or credential access. Its shared app-group file contains only aggregate counts and timestamps. Recent user identities and the server's placeholder MRR field are discarded when decoding.
- The widgets retain saved metrics during connection failures and label them as unavailable/stale. Signing out or an authentication rejection clears those metrics. Future timeline entries hide metrics at the known session expiry even if the app has quit.
- macOS app groups use the signing team prefix. The app and extension must be signed by the same team. An ad-hoc build is not sufficient to validate shared-container access.

## Chart and comparisons

Daily history uses full ISO 8601 timestamps from the server. The chart normalizes dates to UTC, orders and deduplicates days, and plots the latest seven distinct days. Older date-only cached history is also supported.

Red down arrows and green up arrows show percentage changes for active users, messages and new users versus the **entire previous UTC day**. Today is incomplete, so a decrease early in the day is not necessarily a decline in the daily trend. Zero-to-positive changes show “New”; unchanged values show a neutral dash. Missing comparison history does not produce a fabricated zero. The current API doesn't provide the matching previous-period values for weekly active users or waitlist counts, so those cards don't show changes. Weekly active users (active on 3+ days) cannot be reconstructed by summing daily active users.

The API's `newUsersLastDay` and `newWaitlistLastDay` count from UTC midnight, so their visible labels say “today”.

## Checks

```sh
swift test
```

Tests use a mock transport, temporary snapshot files and no production credentials. A successful build does not prove signed-in production behavior or desktop widget placement; those require signing in and adding the widget on the Mac.
