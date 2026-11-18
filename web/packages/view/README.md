# @inline/view

Framework-free view layer: navigation, the workspace model, the command registry and the keyboard. Plain TypeScript classes and functions that expose signals from `@inline/reactive` and methods. No React, no DOM globals: browser objects (`window`, `history`, `navigator`, `localStorage`) are passed in. Everything runs in Node tests.

Feature models (the app, the account session, the sidebar, chats) are under `@inline/view/features`; their API, invariants and the wiring the app follows are in `src/features/README.md`. The timeline and composer controllers are their own packages.

## Destinations and URLs

A `Destination` (`src/workspace/destination.ts`) says *where*: what a pane shows. How it opens (this pane, the other pane, a new tab) is a separate `OpenIntent`. The set follows the Mac app's `Nav3Route`.

| Destination | App path | Notes |
| --- | --- | --- |
| `empty` | `/` | A pane with nothing selected |
| `chat` | `/c/<chatId>` | Same path as the public `inline.chat/c/<id>` link |
| `message` | `/c/<chatId>/m/<messageId>` | Also reads `/c/<id>/message/<id>` |
| `thread` | `/c/<parentChatId>/t/<threadId>` | A reply thread with its parent. `/c/<threadId>` opens the thread alone |
| `chatInfo` | `/c/<chatId>/info[/<tab>]` | Tabs: files, media, voice, links, participants. An unknown tab reads as no tab |
| `user` | `/u/<userId>` | |
| `allChats` | `/chats` | |
| `archived` | `/archived` | |
| `newThread` | `/new`, `/space/<spaceId>/new` | |
| `createSpace` | `/space/new` | |
| `space` | `/space/<spaceId>/<page>` | Pages: members, settings, integrations, grid |
| `settings` | `/settings[/<page>]` | Pages from the Mac app's `SettingsCategory`. An unknown page reads as settings |
| `search` | `/search[?q=<text>]` | |
| `signIn` | `/sign-in[?next=<app path>]` | `next` must decode to an app destination; absolute URLs and `//host` are dropped |
| `joinSpace` | `/s/<handle>` | Same as `inline.chat/s/<handle>`; reads `@handle` too |
| `invite` | `/invite/<token>` | Same as `inline.chat/invite/<token>`; the token is a credential |

- IDs are positive int64 decimal strings (branded, from `@inline/ids`), without leading zeros. Handles and invite tokens are validated as in `InlineDeepLink.swift`.
- `encodeDestination` writes the canonical path; `decodeAppPath` reads one and returns `{ ok, destination, reason }`. It never throws: unknown or malformed input decodes to `empty` with reason `unknown` or `malformed`.
- `parseLink(href)` reads any link Inline understands: app paths, `https://app.inline.chat/...`, the public `https://inline.chat/{c,s,invite}/...` forms, and `inline://` / `in://` deep links (`chat/<id>`, `chat/<id>/message/<id>`, `thread/<id>`, `user/<id>`, `join/public/<handle>`, `join/invite/<token>`, plus the query-key aliases). It returns `undefined` for anything else, so the caller can treat the link as external. The desktop app can reuse it for deep links.
- `toDeepLink`, `toPublicLink` and `toAppUrl` go the other way.
- The URL holds only the shareable destination. Pane layout, scroll place and history live in the workspace and its snapshot.

## Workspace

`Workspace` (`src/workspace/workspace.ts`) holds the panes, each with its own back and forward history (capped at `historyLimit`, 50 by default, dropping the oldest), the focused pane, and a per-destination view-state bag.

- Signals: `state`, `panes`, `focusedPaneId`, `focusedPane`, `focusedDestination`, `canGoBack`, `canGoForward`, `canClosePane`.
- `open(destination, { intent, focus })` with intents `here`, `otherPane` (the neighbor, created if missing), `newPane` (up to `maxPanes`, 3 by default; then like `otherPane`), `newTab` and `newWindow` (handed to the injected `opener`; without one, like `here`). Opening what a pane already shows is a no-op.
- `replace`, `back`, `forward`, `goToEntry` (history menus), `focus`, `focusAdjacent`, `closePane` (never the last pane), `backEntries` / `forwardEntries` (nearest ten, like the Mac history menu).
- `subscribe(listener)` reports `push`, `replace`, `move`, `focus` and `layout` changes in order; the history binding uses it.
- `viewState`: an LRU bag (200 entries) keyed by `viewStateKey(destination)`. A chat, a message in it and a thread opened alone share the chat's key. Values must be plain JSON.

One pane is the normal case. A second pane is another element of `panes`; nothing else changes.

### Persistence

`serializeWorkspace` writes a versioned JSON snapshot (`v: 1`): panes with entry IDs and app paths, the focused pane, the ID counter and the view-state bag. Destinations are stored as app paths, so the URL codec is the stable format. Sign-in and join flows are left out, as the Mac app leaves out invite flows.

`restoreWorkspace(raw, options)` and `parseWorkspaceSnapshot` are tolerant: unreadable entries are dropped, indexes clamped, duplicate IDs renumbered, histories trimmed to the cap. The pre-pane shape (`{ history: string[], historyIndex }`, no version) is migrated into one pane. A snapshot from a newer version, or one that is not JSON, gives a fresh workspace. `createWorkspaceStore(localStorage, key)` wraps storage and swallows its errors. Key the store by account.

### Back and Forward policy

`bindWorkspaceToHistory(workspace, history)` connects the workspace to a session history. `createBrowserHistory(window)` is the History API; `createMemoryHistory()` is for tests and for windows that do not own an address bar (there, skip the binding and call the workspace directly).

1. The address bar shows the focused pane's destination.
2. Navigating the focused pane pushes one browser entry; `replace` replaces it. Navigating a pane without focusing it does not touch browser history.
3. Focusing another pane or closing one replaces the current entry, so the URL follows focus without adding entries.
4. Every entry the app writes is stamped with its workspace, pane and pane entry. Browser Back and Forward onto a stamped entry move that pane to that entry and focus it. With one pane this is exactly the pane's back and forward. With two, they walk the user's visits in order, and focus follows the pane that moves.
5. A stamped entry whose pane is gone, or whose entry fell off the cap, reopens its URL in that pane if it still exists, otherwise in the focused pane.
6. An entry the app did not stamp (first load, a typed URL, an entry from an earlier session) opens its URL in the focused pane, which keeps the restored history behind it. `/` and malformed paths keep the restored workspace and show its URL.
7. The in-app Back and Forward commands act on the focused pane only. When the neighboring browser entry is that pane's neighboring entry they call `history.go` so both stay in step; otherwise they move the pane and replace the current entry.

The app never pushes entries the user did not cause (browsers skip entries pushed without a user gesture anyway), so browser Back leaves the app only from the first entry of the tab's session history. After a reload, the stamps in the surviving browser entries match the restored workspace, so Back and Forward keep working. All of this is tested with the memory adapter in `history-binding.test.ts`; it has not yet been checked in a real browser.

## Commands

`CommandRegistry` (`src/commands/registry.ts`) holds every command:

```ts
registry.register({
  id: "chat.markRead",            // stable, dotted; never rename
  title: "Mark as Read",
  category: "chat",               // one of commandCategories
  scope: "sidebar",               // default "global"
  shortcuts: {
    default: "Alt+Shift+R",       // any OS without its own entry
    mac: ["Mod+Shift+R"],         // the Mac app's key
    browser: { mac: [] },         // overrides in a browser tab, where Cmd+Shift+R reloads; [] unbinds
  },
  enabled: canMarkRead,           // ReadSignal<boolean>; default always on
  repeat: false,                  // run again while the key is held
  whileTyping: "auto",            // "auto" | "always" | "never"
  run: ({ source, event }) => markRead(),
})
```

To add a command: pick an ID and category, check the Mac app (`AppMenu.swift`, `GlobalHotkeys.swift`) for its shortcut, check `reserved.ts` for anything the browser or OS owns on each platform and add a `browser` override for those, register it from the feature that owns the handler, and keep the registration's dispose function. The tests in `navigation.test.ts` that check reserved shortcuts and conflicts run over every registered command; give a new feature's commands the same test.

Shortcut syntax: modifiers `Mod` (Cmd on Mac, Ctrl elsewhere), `Ctrl` (always Control), `Cmd`/`Meta`, `Alt`/`Option`, `Shift`; keys are letters, digits, punctuation (`[`, `,`, or names like `Comma`), `ArrowUp`, `Escape`, `Enter`, `Tab`, `Space`, `Backspace`, `Delete`, `Home`, `End`, `PageUp`, `PageDown`, `F1` to `F24`. A malformed shortcut throws at registration.

Platforms are an OS (`mac`, `windows`, `linux`) and a surface (`desktop` for Electron, `browser` for a tab). `detectPlatform({ navigator, desktop })` takes its inputs by injection.

### Keyboard

`KeyboardDispatcher` resolves a `KeyboardEvent`-shaped object to a command and runs it:

- Precedence: layers (menus, dialogs; newest first; a modal layer stops the search), then the focused region's scopes (`setFocusScopes(["composer"])`), then `global`. A disabled command does not match, so the key falls through.
- Never during IME composition (`isComposing`, `Process`, keyCode 229).
- In a text field, keys that could be typing are left to the field: plain and shifted keys, Option with a character on Mac, and AltGr (Ctrl+Alt with a character) on Windows and Linux. Cmd or Ctrl shortcuts, Alt with arrows, and function keys still work. `whileTyping: "always"` opts a plain key in (Escape to leave a field).
- A held key repeats only commands with `repeat: true`; other repeats are swallowed.
- A matched key gets `preventDefault`. An event already prevented is ignored.
- A character typed outside any field, with no command bound, calls `onTypeToFocus` so the app can focus the composer, as the Mac app does.

Letters match the character typed (layout-aware); Option on Mac and non-Latin layouts fall back to the physical key. Digits and punctuation match the physical key.

### Reserved shortcuts

`reserved.ts` lists what the OS owns everywhere and what a browser owns in a tab: new tab, window and close, tab switching, history keys, the address bar, reload, zoom, developer tools, and app settings on Mac. Shortcuts pages commonly take over on purpose (Mod+K, Mod+F, Mod+S) are not listed.

### First commands

`registerNavigationCommands(registry, deps)` registers, with the Mac app's shortcuts where it has them:

| Command | Mac app | Windows, Linux app | Browser tab |
| --- | --- | --- | --- |
| `navigation.back` / `forward` | Cmd+[ / Cmd+] | Alt+Left / Alt+Right | none: the browser's own Back and Forward follow the policy above |
| `navigation.previousChat` / `nextChat` | Option+Up/Down, Ctrl+K/P, Ctrl+J/N | Alt+Up/Down | as desktop |
| `focus.sidebar` | Cmd+Shift+E | Ctrl+Shift+E | Mac only (Firefox owns Ctrl+Shift+E) |
| `focus.composer` | Escape, in the message list | same | same |
| `app.quickSearch` | Cmd+K | Ctrl+K | as desktop |
| `view.toggleSidebar` | Cmd+S | Ctrl+S | as desktop |
| `app.settings` | Cmd+, | Ctrl+, | Windows and Linux only |
| `window.closePane` | Cmd+W, with more than one pane | Ctrl+W | none |

Handlers call the workspace, the history binding, or injected callbacks (`selectAdjacentChat`, `focusRegion`, `openQuickSearch`, `toggleSidebar`, `openSettings`).

### Shortcut reference

`buildShortcutReference(registry, platform)` and `buildShortcutReferences(registry)` return plain data grouped by platform and category, with a canonical combo, a display string (`⌘K`, `Ctrl+K`) and an Electron accelerator for each key. The settings page and the native menu read this.

## Invariants

- No DOM or framework import; browser objects are injected.
- Decoding URLs and snapshots never throws.
- `decodeAppPath(encodeDestination(d))` returns `d` for every destination.
- The address bar never contains pane layout.
- The app adds browser history entries only for navigations the user caused.
- No registered command binds a reserved shortcut on any platform.
