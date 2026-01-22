# Build Warnings (Sparkle local build)

Source: `SKIP_NOTARIZE=1 bash scripts/macos/build-direct.sh` (2026-01-22)

## Compiler warnings

- `apple/InlineMac/App/AppDelegate.swift:216:21` variable `self` was written to, but never read (`.sink { [weak self] ... }`).
- `apple/InlineMac/App/AppDelegate.swift:284:7` capture of `self` with non-Sendable type `AppDelegate` in a `@Sendable` closure.
- `apple/InlineMac/App/AppDependencies.swift:32:9` variable `result` was never mutated; consider changing to `let`.
- `apple/InlineMac/Features/MainWindow/MainSplitView.swift:238:17` value `self` was defined but never used.
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift:218:6` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift:221:6` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift:225:6` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift:229:6` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift:233:6` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift:236:6` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift:308:25` immutable value `dependencies` was never used.
- `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift:422:15` immutable value `dependencies` was never used.
- `apple/InlineMac/Features/Sidebar/MainSidebarSearchView.swift:225:8` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Features/TabBar/MainTabBar.swift:265:23` immutable value `id` was never used.
- `apple/InlineMac/Features/TabBar/MainTabBar.swift:318:30` main actor-isolated property `dependencies` cannot be accessed from outside of the actor; this is an error in Swift 6 language mode.
- `apple/InlineMac/Toolbar/ChatTitleToolbar.swift:201:25` no `async` operations occur within `await` expression.
- `apple/InlineMac/Utils/Extensions.swift:346:1` extension declares conformance of imported type `NSEdgeInsets` to imported protocols `Decodable`, `Encodable`; add `@retroactive` to silence.
- `apple/InlineMac/Utils/Notifications.swift:119:7` capture of `self` with non-Sendable type `NotificationsManager` in a `@Sendable` closure.
- `apple/InlineMac/Utils/ViewModifiers.swift:33:12` `onChange(of:perform:)` deprecated in macOS 14.0.
- `apple/InlineMac/Views/ChatInfo/ChatInfo.swift:33:22` `appendInterpolation` deprecated; localized string interpolation warning.
- `apple/InlineMac/Views/Common/CustomTooltip.swift:206:15` value `window` was defined but never used.
- `apple/InlineMac/Views/Common/CustomTooltip.swift:520:7` switch must be exhaustive (missing cases like `.cubicCurveTo`, `.quadraticCurveTo`).
- `apple/InlineMac/Views/Components/Devtools/SystemMetricsView.swift:76:11` capture of `self` with non-Sendable type `SystemMonitor` in a `@Sendable` closure.
- `apple/InlineMac/Views/Components/Devtools/SystemMetricsView.swift:85:11` capture of `self` with non-Sendable type `SystemMonitor` in a `@Sendable` closure.

## Tool warnings

- `appintentsmetadataprocessor` warning: Metadata extraction skipped. No AppIntents.framework dependency found.
