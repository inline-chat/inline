# @inline/platform

One capability interface with a web implementation now and an Electron implementation later. App code asks the platform; it never checks whether it runs in a browser or in Electron. Depends on `@inline/reactive` only. No view framework.

## Invariants

- **Importing touches no browser global.** Every module can be imported in Node and in a worker. Only `createWebPlatform` without an `env`, `webEnvFromGlobals` and `systemClock` read globals, and only when called. `src/node-import.test.ts` proves it.
- **Every capability is available or explicitly unavailable.** `Capability<T>` is `{ available: true, ...T }` or `{ available: false, reason }`. Callers hide the feature; nothing throws "not supported".
- **Policy is shared, effects are per platform.** The badge debounce, the notification rule and the URL safety check live in shared code. An implementation only performs the native effect.
- **Browser objects are injected** (`WebEnv`: `window`, `document`, `navigator`, `Notification`, `URL`, a clock, a favicon renderer), so every capability is tested against fakes or happy-dom.
- **No raw HTML sinks.** Elements are created with `createElement` and set through properties.

## Entry points

- `@inline/platform`: the types, `createWebPlatform`, the policies, `userGesture`, `createUpdateFeed`, the `DesktopBridge` type.
- `@inline/platform/testing`: `createFakePlatform` and `manualClock` for other packages' tests.

```ts
const platform = createWebPlatform({ isSafeExternalUrl: chatUiLinkAllowlist })
platform.badge.set(prominentUnreadChats)
if (platform.notifications.available) platform.notifications.show(request)
```

## Capabilities

| Capability | Web | Electron (to build, via the bridge) |
| --- | --- | --- |
| `info` | `kind: "web"`, OS from Client Hints or the user agent (iPad with a Mac UA counts as iOS), `shortcutModifier` `meta` on Apple systems else `ctrl`, `surface: "tab"` | `kind: "electron"`, OS from main, `surface: "window"` |
| `notifications` | Page `Notification`; unavailable where the API is missing. No actions, no inline reply | OS notifications from main; actions on Windows and macOS (Linux only if the server supports them); inline reply not on Linux |
| `badge` | `(n) ` title prefix, favicon drawn on a canvas, Badging API where it exists | Taskbar/dock count from main |
| `links` | `window.open(url, "_blank", "noopener,noreferrer")` after the injected check; initial deep link is the page URL | System browser after the same check (main checks again); `inline://` at launch and from a second instance |
| `files` | File System Access save dialog, else a download link; `reveal` unavailable | Native save dialog; `reveal` available |
| `storage` | `navigator.storage`: `persist()` only where the browser does not prompt (not Firefox), `persisted` and `estimate` as signals | Same Web APIs on the custom scheme, pending spike 4A |
| `lifecycle` | Visibility, focus, online as signals; freeze/resume (Page Lifecycle and back-forward cache); page hide; wake detector | Same, plus `powerMonitor` resume from main |
| `window` | `setTitle` (shares the title with the badge prefix); `newWindow`, `alwaysOnTop`, `titleBarOverlay` unavailable | All available; overlay on Windows and Linux |
| `updater` | State holder fed by the service worker glue (`WebPlatform.updates`), `apply` calls its handler | Fed by `electron-updater` through the bridge |
| `spellcheck`, `tray`, `launchAtLogin`, `globalShortcut` | Unavailable (`reason: "desktop-only"`) | Available |

### notifications

- `permission`: a signal. Follows changes the user makes in browser settings where the Permissions API reports them.
- `requestPermission(gesture)`: takes a `UserGesture`, which only `userGesture(event)` can mint, from a trusted click, key or pointer event. Without a valid token it never prompts and resolves to the current state. It does not prompt again once the user decided.
- `show(request)`: returns whether it was shown. `tag` is one per message (`messageNotificationTag(chatId, messageId)`, the Mac identifier). A tag already shown in this context is ignored (remembered for the last 500), on top of the browser replacing same-tag notifications. Cross-tab de-duplication is the caller's: only the leader shows notifications (package 2H). `urgent` maps to `requireInteraction`.
- `onClick`: the window is focused, the notification closed, then the listener gets `{ tag, data }`. `data` is plain structured-cloneable data (`{ chatId, messageId }` as strings) so it can cross the preload bridge or a service worker.
- `close(tag)`, `closeWhere(match)`: e.g. close a chat's notifications when it is read.
- `supportsActions`, `supportsInlineReply`, `onAction`: platform-dependent. On the web both flags are false and `onAction` never fires.

### badge

`badge.set(count, { immediate? })` takes the count of prominent unread chats (feature-map rule 9). Decreases show at once; increases after 500 ms; a newer value supersedes a pending one (`createBadgeController`, from the Mac `DockBadgeController`). Use `immediate` on sign-in, sign-out and when the user re-enables the badge. Labels cap at `99+`. Where there is no 2D canvas the favicon is skipped and the title prefix stays.

### lifecycle

`visible`, `focused`, `online` are signals; `freezes` has the exact shape of `LifecycleSource` in `@inline/link`, so the app passes it to link without either package importing the other. The core's `BrowserSignal` (`online`, `visibility`, `wake`) is fed from `online`, `visible` and `onWake` by the app wiring.

The wake detector runs a 10 s timer on wall-clock time and reports a gap above 75 s (interval plus 65 s tolerance). The tolerance sits above Chrome's one-minute throttling of hidden tabs, so a throttled tab does not look like a wake. It also checks immediately when the page becomes visible, regains focus or comes online. A long freeze reports a wake on resume, which the connection wants anyway.

### storage

`requestPersistence()` asks only where the browser decides without a prompt (Chromium by engagement, Safari grants). Firefox prompts, so it is not asked there (`canRequestSilently: false`). Eviction would drop unsent intents, so the app calls it at start.

### updater

`state` is `none`, `available` or `ready`; `apply()` does nothing unless `ready`. The web platform returns the write side as `updates` (`report`, `setApplyHandler`) for the service worker glue of package 2I. No service worker lives here.

## Policies (pure)

- `decideMessageNotification(facts)`: rule 12, ported from `MacNotifications.shouldScheduleMessageNotification` and the foreground presentation. In order: outgoing, not newly inserted, read, `countsAsUnread` false, call transcript, silent send, older than 2 minutes (or no date): no. An urgent nudge then notifies, even while viewing and in mode `none`, always with sound. Viewing the conversation: no. Then the effective mode (chat mode, or the global mode when the chat follows it; `importantOnly` reads as `mentions`): `all` yes; `none` no; `mentions` for DMs, mentions, replies to me, nudges; `onlyMentions` for mentions and nudges only. Returns the skip reason or `{ urgent, silent }`.
- `isViewingConversation({ visible, focused, openChatId, chatId })`: the web form of the Mac `isViewingChat`.
- `createBadgeController({ clock, apply })`, `badgeLabel(count)`.

## Fake platform

`createFakePlatform(options)` returns `{ platform, clock, notifications, badge, links, files, lifecycle, desktop, updates }`. It records notifications shown (with tag de-duplication), clicks and actions, badge values that reached the screen (the real debounce on the fake clock), opened and refused links, saved and revealed files. A test drives permission, visibility, focus, online state, freezes, page hides, deep links and time: `clock.advance(ms)` runs timers in order, `clock.sleep(ms)` jumps time as a sleeping machine does, which fires the wake detector. `desktop: true` gives a fake Electron platform with desktop capabilities available and recorded.

## Electron: what the preload bridge must provide

The Electron implementation builds `Platform` from a `DesktopBridge` (`src/desktop-bridge.ts`, types only), exposed by the preload with `contextBridge`. Each entry is a named call with plain arguments; there is no generic channel. The main process validates arguments and the sender on every call.

| Area | Calls |
| --- | --- |
| Info | `os`, `initialDeepLink` |
| Notifications | `notificationPermission()`, `requestNotificationPermission()`, `showNotification(request)`, `closeNotification(tag)`, `onNotificationClick`, `onNotificationAction`, `notificationSupportsActions`, `notificationSupportsInlineReply` |
| Badge | `setBadgeCount(count)` (already debounced in shared code) |
| Links | `openExternal(url)` (main re-checks the scheme), `onDeepLink` |
| Files | `saveFile(bytes, suggestedName)`, `revealInFolder(path)` (only paths the app saved) |
| Window | `setTitle`, `openWindow(path?)`, `setAlwaysOnTop`, `isAlwaysOnTop`, `titleBarInsets`, `onTitleBarInsets` |
| Lifecycle | `onSystemResume` (from `powerMonitor`) |
| Updater | `updateState`, `onUpdateState`, `applyUpdate` |
| Desktop only | `setSpellcheck`, `spellcheckEnabled`, `setTrayChats`, `onTraySelect`, `setLaunchAtLogin`, `launchAtLogin`, `setGlobalShortcut`, `globalShortcut` |

Visibility, focus, online and freeze come from the same DOM events as on the web; storage uses the same Web APIs once spike 4A confirms them on the custom scheme.

## Tests

`bun run test` from this directory: policies as decision tables, every web capability against happy-dom and injected fakes, the fake platform, and the Node import check.
