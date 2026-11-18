# Desktop shell

The Electron app for Windows and Linux, and later an optional Mac build. Read this before working in `web/desktop` or on the `platform` interface.

The desktop app is the web app in a native frame. It loads the same bundle, runs the same core, and adds only what a browser tab cannot do. If a desktop feature needs app logic, the logic goes in the shared code behind the `platform` interface, not in Electron's main process.

Facts in this guide about Electron were checked against Electron 45 in November 2026. Re-check them when you start; Electron ships a major version every eight weeks.

## Shape

- **Main process** (`web/desktop`): windows, native menus, tray, notifications, deep links, single-instance lock, updater, the custom protocol. Small, with no app logic and no account data.
- **Preload:** a narrow, typed bridge that implements the `platform` interface for the renderer. Every call is a named capability with validated arguments. No generic "invoke anything" channel.
- **Renderers:** the same bundle as the web app.
- **The core** runs once per account in a long-lived context that is the permanent leader; every visible window is a follower over the same protocol the browser tabs use. Closing all windows does not stop the core while the app is running.

### Where the core lives

The default is a hidden window whose dedicated worker hosts the core, with SQLite WASM on OPFS, exactly as in a browser. That keeps one code path.

Two things must be confirmed by a short spike before building on it:

1. That OPFS with synchronous access handles in a dedicated worker, Web Locks, and persistent storage all work on the custom scheme. They need a secure context; Electron's documentation does not state this for custom schemes.
2. That a hidden window is not throttled or suspended in a way that stalls the socket or timers (check `backgroundThrottling` and occlusion behavior on each OS).

If either fails, the fallback was already proven in an earlier lab: native SQLite in a utility process, with the core's storage interface implemented over a message port. The core's storage and transport are injected, so this is a different host, not a different core. Record which one you chose and why.

## Security

Follow Electron's security checklist in full. The parts that matter most here:

- Renderers are sandboxed with context isolation, and have no Node integration.
- The app is served from a custom scheme registered as standard and secure, with fetch and service worker support, through `protocol.handle`. Guard against path traversal. Never load from `file://` and never load remote code.
- The same Content Security Policy as the web build, sent as a response header from the protocol handler.
- Deny by default: navigation away from the app (`will-navigate`), new windows (`setWindowOpenHandler`), and permission requests (`setPermissionRequestHandler`; Electron approves everything unless told otherwise). Allow only what the app uses.
- External links open in the system browser after passing the same scheme allowlist as the web app.
- Validate the sender of every IPC message.
- Fuses for release builds: `runAsNode`, `nodeOptions`, `nodeCliInspect` and the extra `file://` privileges off; cookie encryption, ASAR integrity validation and "only load app from ASAR" on. ASAR integrity is enforced on macOS and Windows, not Linux.
- Playwright drives Electron through the inspector, which needs `nodeCliInspect` on. Keep a separate test build configuration; never ship it.

## Native features

Each of these is a capability on the `platform` interface, with a web implementation (possibly a no-op) and an Electron one.

| Capability | Notes |
| --- | --- |
| Menus | Built from the command registry. One source for shortcuts and enabled state |
| Windows | New window, per-window workspace, window state restored on launch, always on top |
| Title bar | Hidden title bar with the native controls overlay on Windows and Linux; our toolbar fills the title area and stays draggable |
| Notifications | Click opens the exact message. Action buttons work on Windows and macOS, and on Linux only when the notification server supports them; inline reply is not available on Linux |
| Badge and tray | Count of prominent unread chats, using the same rule as the Mac dock badge; tray menu lists unread chats |
| Deep links | `inline://` registered as a protocol; a second launch forwards its link to the running instance |
| Single instance | One app instance per user |
| Files | Native save dialogs, drag files out, open in folder |
| Spellcheck | The system spellchecker, following the user's setting |
| Launch at login | A setting |
| Global shortcut | "Focus Inline", user-set |
| Updates | Background download, apply on restart, a visible "Update ready" state |

## Packaging and updates

- **Windows and Linux first.** The Mac build is the same shell with Mac window chrome, for people who prefer it to the native app; it follows.
- **Updater decides the packager.** Electron's built-in updater covers Windows and macOS only. On Linux, self-updating AppImage, deb and rpm packages are supported by `electron-updater` from electron-builder; Flatpak and Snap update through their stores. The default is therefore electron-builder with `electron-updater`, NSIS on Windows, and AppImage plus deb and rpm on Linux. Electron Forge is the alternative if its Vite integration and automatic fuse and integrity handling outweigh that; with Forge, Linux updates need another answer.
- **Signing.** Windows builds must be signed to avoid SmartScreen warnings. Signing accounts and certificates are an owner decision and need sign-off before the first public build.
- **Channels.** Stable and beta, with staged rollout. Update metadata and artifacts are served from our own storage.
- **Linux display servers.** Electron runs on Wayland natively by default. Keep a documented way to force X11, and test on both.

## Performance and memory

The budgets in `performance.md` apply. In addition:

- One core for all windows. A second window costs a renderer, not a second database or socket.
- Measure memory of the whole app (all processes) after a working day's use; a large Electron app is judged on this more than on anything else.
- Start-up budget: a window with the last chat painted from the boot snapshot within 500 ms of launch on the reference Windows machine, measured from process start.
- Do not keep hidden windows or preloaded views around to make things feel faster without measuring what they cost.

## Tests

- Launch, single-instance hand-off, deep link opening a chat, notification click, update check against a local feed, window state restore.
- The web end-to-end suite also runs against the packaged app, so the shared code is proven inside the shell.
- A check that the release build has the release fuses.

## Order of work

1. The storage and background spike above.
2. A window loading the bundle from the custom scheme under the content policy, with the sandbox on.
3. The core as permanent leader; a second window as follower.
4. Menus from the command registry, deep links, single instance.
5. Notifications, badge, tray.
6. Packaging, signing, updates, channels.
7. The rest of the capability table.
