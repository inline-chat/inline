# Settings (`web/src/features/settings`)

The `settings` destination's view, and the local preferences store the composer, notifications and navigation read. Pages, order and wording follow the Mac app (`apple/InlineMac/Views/Settings/`): `SettingsCategory` for pages, `SettingsSearchItem` for rows and search.

## Files

| File | What |
| --- | --- |
| `preferences.ts` | `PreferencesStore`: the local preferences, versioned, tolerant parse, signals and setters, storage, cross-tab channel, sync hand-over. Framework-free |
| `catalog.ts` | Pages and their searchable rows as data; rows read their titles from here |
| `search.ts` | The Mac `SettingsSearch` matcher and the index built from the listed pages' rows |
| `settings-model.ts` | `SettingsModel`: page list (kit `ListboxController`), destination sync, search field and results, reveal and highlight, narrow column |
| `controls.ts` | `BoundToggle` (a switch over a setting's signal), `ClearMediaAction`, `refreshEstimateOnShow` |
| `format.ts` | Bytes with `Intl`, key caps, shortcut filter, and the plain-language copy for send keys, sign-out, permission, storage and updates |
| `SettingsView.tsx`, `Rows.tsx`, `icons.tsx`, `pages/*.tsx` | The views. No effects; lifecycle through `useModel` and `useElement` |
| `types.ts` | `SettingsViewProps`, `SettingsAccount` |

## Mounting it for the `settings` destination

The shell maps `{ kind: "settings", page? }` to a pane that renders:

```tsx
<SettingsView
  page={destination.page}                     // undefined for /settings (opens General)
  onNavigate={paneModel.openSettingsPage}     // stable for the pane's life, see below
  appearance={appearance}                     // startDocumentAppearance()
  platform={platform}                         // createWebPlatform(...)
  preferences={preferences}                   // the app's one PreferencesStore
  account={{ me: session.me, deviceName: device.deviceName, signOut: () => app.signOut() }}
  pendingCount={unsentCount}                  // optional, default 0
  shortcuts={buildShortcutReference(app.registry, detectPlatform({ navigator, desktop: false }))}
  notificationPrompt={notifications.prompt}   // from attachNotifications; optional
  buildId={BUILD_ID}
  onClearCachedMedia={() => media.clearCache()} // optional; disabled with a reason without it
/>
```

- `onNavigate(page)` should be `workspace.openInPane(paneId, { kind: "settings", page })` (a history entry per page, so Back walks pages as the Mac settings window's Back does). Keep the function stable: a new identity rebuilds the view's model and drops the search text. Create it in the pane's model, not inline.
- The view renders the page from `props.page`, so after Back the first frame is already the right page. It syncs its list selection at commit through a ref part (`model.destination(page)`), never during render.
- `account` absent: the Account page is not listed, and `/settings/account` shows "not available".
- Pages the web lacks (`privacy`, `sessions`, `bots`, `connectors`, `audio-video`, `experimental`, `debug`) are not listed; a link to one shows a short "not available on the web yet" page instead of falling back silently.
- Page IDs reuse the destination's: Keyboard Shortcuts is `hotkeys`, About is `updates` (the nearest Mac pages).
- `shortcuts` is plain data built once; rebuild it if commands are registered later (or pass a new value on re-render).
- The region needs a definite height (it fills its pane: `block-size: 100%`). Its two columns collapse to one below 600px of its own width (a container query, not the window width).

## The preferences store

```ts
// Once per page, next to startDocumentAppearance(), before any view:
const preferences = new PreferencesStore({
  storage: webPreferencesStorage(localStorage),
  channel: broadcastPreferencesChannel(new BroadcastChannel("inline-preferences")),
})
```

| Field | Default (Mac) | Read by |
| --- | --- | --- |
| `sendKey`: `"enter"` or `"modEnter"` | Enter sends | Composer: `new ComposerModel({ sendKey: preferences.sendKey, ... })` (the same `SendKey` type) |
| `spellCheck` | on | Composer view: `<ComposerView spellcheck={useSignal(preferences.spellCheck)} />`. In Electron also mirror it to `platform.spellcheck.setEnabled` |
| `replyThreadsInSidePane` | off | Whoever opens a reply thread: `intent: preferences.replyThreadsInSidePane.peek() ? "otherPane" : "here"` |
| `notificationSounds` | on | `attachNotifications({ settings: { soundEnabled: () => preferences.notificationSounds.peek() } })` |
| `appBadge` | on | `attachNotifications({ badgeEnabled: preferences.appBadge })` |

Unread badge style is not here: the appearance controller already owns it (`appearance.unreadBadgeStyle`, `"dot"` or `"numbered"`; the sidebar's `unreadStyle` is `"dot"` or `"count"`). The Appearance page edits it there.

Invariants:

- One object, `version: 1`, stored as JSON under `inline.preferences`, device-wide (like appearance and like the Mac's `UserDefaults`). Nothing personal, so sign-out leaves it.
- `parsePreferences(anything)` never throws; invalid fields take defaults, valid ones are kept. An unversioned object is read with the current names and the Mac's (`sendsWithCmdEnter`, `checkSpellingWhileTyping`, `openReplyThreadsInSidePane`, `disableNotificationSound`, `showDockBadgeUnreadDMs`). A newer version is read field by field, and its unknown fields are kept when this build writes.
- A setter updates the signal, storage and the other tabs in the same task. A receiving tab applies the value without writing storage or posting back; a context ignores its own echo. Storage that throws keeps the value for the session.
- Each field is its own computed signal: changing one does not notify readers of another.

### Syncing

`attachSync({ fields, values, write })` hands fields to the core when it can sync them: while attached, the core's value wins for those fields (the local one shows until the core knows), setters write through to `write` and still update local storage as the cached value for the next start, and detaching falls back to local. Views and readers do not change.

Which would move: `notificationSounds`, once the protocol carries it (the Mac keeps its own sound toggle local today but syncs `NotificationSettings.silent`, which is the same intent). The others stay device-local, as on the Mac: the send key, spell check, the side pane and the badge are per-device choices there. Notification modes (global and per chat) are not here at all; they belong to the core's user settings when the protocol has them.

## Behavior

- Every control applies at once; there is no Save. Switches are the kit's `ToggleController` bound to the store (`BoundToggle`), so a change in another tab moves them.
- Keyboard: search field, then the page list (one tab stop; arrows move the selection and the page, Home/End, typeahead, Enter opens), then the page's controls in reading order. From the search field Down moves to the list; while searching, arrows move through the results (`aria-activedescendant`, APG combobox with an always-visible listbox), Enter jumps to the active result, Escape clears.
- Search: every query word must prefix-match a word of a row's title, keywords, section or page title (case, accents and width ignored); ranked title prefix > title word > keyword > context, as the Mac. Rows of unlisted pages never match. Jumping opens the page, scrolls the row to the center, focuses its first control and highlights the row for 1.2 s.
- Narrow (below 600px of the region): one column. A click or Enter on a page shows it; arrows only move through the list. The back control returns to the list and focuses it. A navigation from outside (Back, a link) shows what it opened; `/settings` shows the list.
- Account: avatar, name, username, email, this device's name, and Sign Out behind an alert dialog that says local data on this device is erased and how many unsent messages will be lost.
- Notifications: the permission in plain words; "Turn On Notifications" passes `userGesture(event.nativeEvent)` from the click; when blocked, says to change it in the browser's site settings (system settings in Electron).
- Data & Storage: the usage estimate (refreshed each time the page shows), persistence and what it means, Clear Cached Media (one run at a time, then a fresh estimate).
- Keyboard Shortcuts: the registry's reference for this platform, commands with a key only, grouped by category, key caps in `Kbd` with a spoken label, filtered by name, category or key.
- About: build ID, the updater's state with "Reload to Update" when ready, and the terms and privacy links through `platform.links.openExternal` (the anchors keep their address for copy and middle click).
- Styling: StyleX and the kit's tokens, logical properties; the back chevron flips in right to left; motion uses the motion tokens (0 ms under reduced motion); selection and focus use the tokens forced colors maps.

## Lab

`lab-settings.html` (`src/lab/settings/`): `SettingsView` over a real `AppearanceController` on the document (in-memory storage, no boot record), the fake platform with lab-controlled permission, storage, usage and updater, an in-memory store plus a second store on the same channel as "another tab", and stubbed account data. `globalThis.__settingsLab` (a getter) is the state; `globalThis.__settingsLabControl` has `navigate`, `back`, `forward`, `setOS`, `setPermission`, `setStorage`, `setEstimate`, `setUpdate`, `setNarrow`, `showNarrowAppearance`, `setDir`, `setAppearance`, `setTheme`, `setSignedIn`, `setAccountLoading`, `setPendingCount`, `setMediaHandler`, `otherTabUpdate(patch)`. Query: `?page=appearance&theme=dark&dir=rtl&width=narrow&os=windows&permission=denied&storage=notPersistent&update=ready`.

## Check in a real browser

Not verified yet; nothing here has run in a browser.

1. Light, dark and each theme: the region, the page list selection, search results, the switch, highlighted rows. Forced colors: selection, focus rings and switch state stay visible.
2. Keyboard only: Tab order (search, list, back control when narrow, controls); arrows in the list change page and the URL; Enter on a search result focuses the control; Escape clears the search and nothing else.
3. Narrow (lab "Narrow", or a pane under 600px): list first for `/settings`, page first for `/settings/general`; back control; arrows do not leave the list; a link from outside opens the page.
4. Right to left: layout mirrors, chevron points the right way, the build ID stays left to right.
5. Back and Forward walk pages, and the list follows.
6. Cross-tab: two app tabs, change the send key in one, the other's General page and composer follow without reload.
7. Notifications: "Turn On Notifications" prompts in Chrome, Firefox and Safari from the click; after a decision the button goes; blocked shows the site-settings note.
8. Data & Storage: the usage number is plausible and localized; Clear Cached Media disables while running.
9. Sign Out: the dialog traps focus, Escape and Cancel return focus to the button, the destructive button signs out.
10. Reduced motion: the row highlight appears without fading.
11. Production build under the content policy (no inline styles or scripts, Trusted Types).

## Tests

`bunx vitest run src/features/settings` from `web/` (Node, no DOM): the preferences store (parse, defaults, Mac-name migration, newer versions and unknown-field keeping, per-field notification, storage failures, reset and reload, cross-tab without echo, foreign and own messages, dispose, the sync hand-over), the catalog and search index (ranking, folding, all words, ties, hidden pages), the settings model (destination sync and echo, narrow column rules, Enter, Back, unavailable pages, search keys, reveal across pages and on the current page, highlight timing, dispose), the bound switch and media action, and the formatters.
