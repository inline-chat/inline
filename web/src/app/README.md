# App shell (`web/src/app`, `web/src/main.tsx`, `web/src/features/chat`)

The running program: boot, the sign-in gate, the window, and the wiring that turns the packages into one app. Composition only; the logic lives in the packages and feature folders it mounts.

## Files

| File | What |
| --- | --- |
| `../main.tsx` | Entry: `startDocumentAppearance()` first, the boot mark, `boot()`, then `createRoot().render(<App>)`. |
| `boot.ts` | Everything created once, in order (below). Returns `AppServices`. |
| `boot-snapshot/` | The boot snapshot: read at start, paint from it before the core exists, reconcile, save on hide, erase on every end (its README). |
| `runtime.ts` | `AppRuntime`: the `AppModel` plus per-session wiring (history binding, badge, `pagehide` flush, boot marks, link role, the session hook), the "why the last account ended" notice, the shell hooks. DOM-free; tested with fakes. |
| `shell-model.ts` | `ShellModel`, one per session: the sidebar/pane split (sizes and collapse kept per account under `inline:layout:<userId>`), toasts, the status surface, the focus registry, the session's view hooks, type anywhere. |
| `pane-registry.ts` | Destination kind to pane view kind (`chat`, `chatInfo`, `settings`, `empty`, `unbuilt`); titles. `PaneArea.tsx` maps kinds to components (`paneViews`). |
| `warmup.ts` | `Warmup`: loads queued until after the first paint, one per idle slice, or from a timer when no idle slice comes for a second. |
| `view-chunks.ts` | Every code-split chunk by name (`chunkImporters`), what each phase requests before its first paint (`firstPaint`) and what loads right after it (`afterFirstPaint`; `bootWarmed` are boot's, the rest the shell's). `boot.ts` loads from it; `bun run size` reads it to decide what counts as initial. A chunk a feature loads through its own holder (the menu kit, the composer's autocomplete, paste and attachment strip) is named with the holder's specifier, so both are one chunk (`shell-warmup.test.ts` checks the specifiers match). |
| `notifications-chunk.ts` | Message notifications and the badge for a session (`attachMessageNotifications`), attached on the idle lane after the first paint; the permission prompt is made at once in `boot.ts`. |
| `layers-chunk.ts` | The reaction picker and the confirmation alert: the kit's popover and dialog controllers (`kitLayers`) and `MessageActionLayers`. Warmed after the first paint. |
| `signin-loader.ts` | `createAuthFlows` (`@inline/auth/flows` on first use: sign-in model, API, device facts, sign-out) and `LazySignIn` (what the app model holds while signed out; the setup hold). |
| `quick-search-chunk.ts`, `settings-chunk.ts` | The Quick Search (with the core-backed message source) and Settings chunks (dynamic imports only). |
| `ChunkPane.tsx` | A pane whose body is its own chunk (Settings, Chat Info): the title strip, then the body once its chunk is there; a failed load says so with Try Again. `PaneArea.tsx` uses it for both. |
| `chat-info-chunk.ts`, `ChatInfoBody.tsx`, `chat-info-pane.ts` | The `chatInfo` destination: its chunk (the body: `createChatInfoModel` and `ChatInfoPane`) and the model's options from the session and the pane (`chatInfoOptions`, tested). |
| `settings-chunk.ts`, `SettingsBody.tsx`, `settings-pane.ts` | The `settings` destination: its chunk (`SettingsBody`: `SettingsPaneModel` with a stable `onNavigate`, the account and shortcuts, then `SettingsView`). |
| `emoji-session.ts`, `emoji-storage.ts` | `SessionEmoji`, one per session (`ShellModel.emoji`): the emoji services and pickers loaded after the first paint or on first use, the composer's `:` source (`combinedSuggest` with `@`), recents per account (`inline:emoji:<userId>:<Mac key>`, erased on sign-out by `eraseAccountEmoji`). |
| `storage-sweep.ts` | `queueAccountStorageSweep`: the boot sweep (`src/core/account-storage-sweep.ts`) on the warm-up lane, never in the demo. |
| `quick-search-session.ts` | `wireSessionQuickSearch`: Quick Search for a session with local messages and server people (in the Quick Search chunk). |
| `shell-warmup.ts` | What the shell loads after its first paint and through which loader (`queueShellWarmup`, `shellWarmers`): `content` after the paint, the rest of `afterFirstPaint` on the idle lane through the holders the first use reads (`menuKit`, `loadAutocompleteChunk`, the shell's own loaders, `SessionEmoji`), the emoji table last. |
| `history-session.ts` | `createSessionHistory`: the browser history wrapped so every entry carries the history session it was written in; `endSession()` on an account's end makes every earlier entry read as `/`. |
| `status.ts` | Session status to surface (screen, banner, header, starting, none) and their words. |
| `perf.ts` | Boot and chat-switch marks and measures; the rows-to-screen stage marks (`stageNames`). |
| `focus.ts` | Window keydown into the keyboard dispatcher, focus regions (`data-focus-region`), the focus guard. |
| `unsaved-work.ts` | Sends in flight, non-empty composers, `pagehide` flushers. |
| `diagnostics.ts` | The redacted diagnostics text (Copy Diagnostics on the failure screen). |
| `views.ts` | `loadable(import)`: code splitting without React `lazy`. |
| `services.ts` | `AppServices`, the one stable prop the views get (runtime, view chunks, appearance, platform, preferences, warmup, clipboard, ...). |
| `demo-params.ts`, `dev-snapshot.ts` | Dev server and labs build only (`import.meta.env.DEV || __INLINE_DEMO__`): `?demo=` and `globalThis.__inlineApp`. A production `index.html` cannot reach either (`bun run size --entries`). |
| `App.tsx` | The gate. Main chunk. |
| `Shell.tsx`, `SidebarColumn.tsx`, `PaneArea.tsx`, `TitleStrip.tsx`, `StatusSurfaces.tsx`, `icons.tsx` | The signed-in window. Shell chunk. |
| `../features/chat/` | The chat pane: `ChatPaneModel` / `OpenChat` (framework-free; header, subtitle with typing), `createChatComposer`, `ChatContent` + `content-chunk.tsx` + `content-handlers.ts` + `download.ts` (message content, its handlers and names, file downloads, deferred), `MessageActions` + `MessageActionLayers.tsx` (message actions, reaction picker, the confirmation alert), `ChatPane.tsx`, `ChatHeader.tsx`, `ChatMessages.tsx` (`renderItem` over the message views). Per chat, loaded on demand: `chat-find.ts` + `find-chunk.ts` (find in chat), `chat-mentions.ts` + `mentions-chunk.ts` + `mention-models.ts` (`@` suggestions, rule 14), `chat-attachments.ts` + `attachments-chunk.ts` (attachments), `media-viewer-host.ts` + `media-viewer-chunk.ts` + `media-viewer.ts` + `MediaViewer.tsx` (the media viewer), `composer-emoji.ts` (the composer's emoji button). |
| `global.css` | Document-level rules only (see below). |
| `test-fixtures.ts` | Fakes for the tests (scripted core per connection, shared auth storage, sign-in server, timing). |

## Boot sequence

`main.tsx`:

1. `startDocumentAppearance()` (`@inline/ui/theme/stylex`): applies appearance and theme classes to `<html>` and removes the pre-paint script's stand-ins. The controller is passed to boot.
2. `createBootMetrics(performance)`, mark `inline.boot.start`.
3. `await boot(...)`, then render. `boot` awaits only the demo's dynamic import and the demo's in-memory login (development); in production it is synchronous.

`boot.ts`, in order:

1. The app `Log` with a `LogRingBuffer` (500 records) for diagnostics; console output only in development. Then `readBootSnapshot(localStorage)`, synchronously, before any await (`boot-snapshot/README.md`).
2. `createWebPlatform({ isSafeExternalUrl })`, the allowlist from `safeLink` (`@inline/chat-ui`), app links excluded.
3. The browser scheduler and the `Warmup` queue (idle slices, with a one-second timer when the page is never idle). The service worker's registration is its first task (after the first paint; its module loads then): `registerServiceWorker({ enabled: PROD && web, buildId, feed: platform.updates, hasUnsavedWork })`. `hasUnsavedWork` is `UnsavedWork.has()`: a send in flight, or a composer with text (each mounted composer registers itself). Sign-out clears its caches whether or not it registered yet.
4. Dev server and labs build only (`import.meta.env.DEV || __INLINE_DEMO__`; `__INLINE_DEMO__` is a build constant, `false` in `vite.config.ts`, `true` only in `tooling/vite.labs.config.ts`): `?demo=` (below) swaps the connector for `connectDemoAccount`, loaded with a dynamic import, so the production bundle has none of it. `vite.config.ts` refuses to run when `VITE_ENABLE_DEMO` is set in the environment (the old switch, which a stray CI variable could have turned on).
5. The auth store: `BrowserAuthSessionPersistence("inline-web-session")` (IndexedDB plus cross-tab broadcast; the earlier web app's key). Demo: an in-memory store logged in as the demo user. Then, outside the demo, the boot sweep is queued on the warm-up lane (`queueAccountStorageSweep`, security.md "Session and storage"): it loads its module after the first paint and removes the storage of accounts no session in this browser owns.
6. The `PreferencesStore` (`inline.preferences`, cross-tab over `BroadcastChannel("inline-preferences")`; settings/README.md), and in Electron the system spellchecker following `spellCheck`. Then the sign-in flows, which are not in the initial bundle: `createAuthFlows` loads `@inline/auth/flows` on first use and builds `createDeviceFacts` and `createSignInApi`; the app model's sign-in is a `LazySignIn` over `createSignInModel` (whose back-after-sign-in signs out through the runtime); sign-out loads the flows and runs `signOut` without its erase hook (the app model erases when the auth store reports the end; if the flows cannot load, it logs out locally).
7. `AppRuntime` (connector, platform, keyboard platform, clock, metrics, `localStorage`, build ID, protocol, the history (`createSessionHistory(createBrowserHistory(window), { storage: sessionStorage })`, see "When an account ends"), erase = service worker caches, opener for new tabs, the setup hold, the session hook: the notification permission prompt at once (its banner is on the first frame), then on the warmup lane `attachMessageNotifications` (`notifications-chunk.ts`) with the preferences' `notificationSounds` and `appBadge` (it owns the badge: the runtime's own badge effect is off, so there is one badge controller; nothing is missed by attaching late, the controller reads the core's `newMessages` list), and the boot snapshot read in step 1). With a snapshot for a user the auth store has not ruled out, the first session starts here from it, before the auth store has answered and before any connector call.
8. `bindWindowKeyboard(window, app.keyboard)`, `bindFocusGuard(window, ...)`, `appearanceCommands(appearance)` registered into the app's registry.
9. View chunks (`AppViews`, from `view-chunks.ts`): an effect loads `firstPaint[phase]` (the shell on `signedIn`; the sign-in screen and the flows on `signedOut`); `content` loads right after the shell's first paint, then the rest of `afterFirstPaint` on the warmup lane (`shell-warmup.ts`) and the emoji table last; `find`, `mentions`, `attachments` (with `attachmentStrip`), `chatInfo` and `mediaViewer` load on first intent only (see "Initial bundle").
10. Dev server and labs build: `globalThis.__inlineApp` (with `?renderCounts=1`, a render counter).

Nothing waits on the network. The neutral frame stands in while the auth store hydrates (local) and while a chunk loads (the service worker's cache after the first visit). With a boot snapshot the gate does not wait for the auth store: the shell paints from the snapshot as soon as its chunk is there.

## The gate (`App.tsx`)

| Phase | Renders |
| --- | --- |
| `booting` | Neutral frame in the window color (no sign-in flash for a signed-in user). |
| `signedOut` | `SignInScreen` (its own chunk) over the `LazySignIn`'s model (the flows' chunk), full window, `codeLength` 6; the neutral frame until both are there. Above it, when the account ended elsewhere: "You were signed out in another tab or window", or after a revocation "This session was ended". |
| `signedIn` | `Shell` (its own chunk), keyed by user. While `runtime.heldSignIn` is set (a new account at `setup`), the sign-in screen instead. |
| `signingOut` | Neutral frame, "Signing out…" (silent when the session ending was only painted from the boot snapshot and the auth store did not confirm it). Before the gate gets here, a core that reports `signingOut: true` (erasing; every intent refused) turns the whole shell into the "Signing out…" screen with no controls (`statusSurface`). |

A chunk that fails to load shows "Inline couldn't load" with Try Again. Sign-out here, in another tab, and by revocation take one path (`AppModel`); the runtime only records which one it was.

**When an account ends** (`runtime.ts`): the address bar goes back to `/` (the next account would otherwise open the last one's `/c/<id>/m/<id>` as a deep link; the account's stored workspace is cleared by `AccountSession.end({ erase: true })`), and the history's session ends (`history-session.ts`): a page cannot delete entries, so every entry the app writes carries its history session (`inlineSession` in `history.state`, kept per tab in `sessionStorage`), and an entry of an earlier session reads as `/` on Back and Forward, when read at the next sign-in, and in the address bar while signed out; and the runtime follows `end`'s outcome: `eraseFailed` or `timedOut` sets `eraseIncomplete`, and the sign-in screen says "Some data from your last session may still be on this device. It will be removed the next time Inline starts." (the boot sweep and the account's next start remove it). The next sign-in, the next end or Dismiss clears it.

**New account (setup).** The Mac shows profile setup before the main window. The auth store logs in inside the sign-in model's last request, so the app model starts the session at once (the core connects behind the screen). `LazySignIn.dispose()` waits a microtask: a model that then sits at `setup` (the server's `pendingSetup`) stays alive and `held`; the gate keeps the sign-in screen ("Your account is ready", Continue) over the started session. Continue moves it to `done` and the shell replaces it in the same frame; its "Sign out" (back) signs out here with no notice; the account ending any other way releases it. An existing account reaches `done` directly and goes to the shell at once (`done` is never held). Tests: `signin-hold.test.ts`.

## The shell

- `SplitView` (kit): sidebar on the leading side (240 px, 180 to 340, collapsible, as the Mac `Theme.swift`), pane area flexible. Sizes and collapse persist per account (`inline:layout:<userId>`, erased on sign-out). "Toggle Sidebar" (`Mod+S`) collapses it; focus never stays in a hidden sidebar.
- `TitleStrip`: the one component for every title area (sidebar and each pane), 46 px, marked `data-window-drag` so the desktop build can make it draggable in one place. While the sidebar is collapsed, the first pane's strip carries the toggle.
- A "Turn on notifications" banner above the panes (`attachNotifications(...).prompt`): shown while the browser has not been asked and the user has not dismissed it; it asks only from the click.
- Sidebar column: `SidebarView` (`features/sidebar`) with `ready` and a `SidebarHandle`, the update affordance ("Update ready: Reload", only when the platform's updater is `ready`; never reloads by itself; in a strip narrower than 320 px, so at the default 240 px sidebar, an icon button with those words as its name and tooltip, so the title keeps its room: `TitleStrip` is a size container), and an account footer with Sign Out.
- Toasts: the kit's region (`ShellModel.toasts`, `offset` 12 and 12) sits in the inline-end, block-end corner of a chat pane's message list, which attaches `toasts.container` (the newest attached wins; with none, the window's corner): above the composer, never over it or its send button.
- Pane area: one pane per workspace pane, left to right. Pointer down or focus inside a pane focuses it in the workspace. Each shows `paneViews[paneViewKind(destination)]`: the chat pane for `chat`, `message` and `thread`; Settings for `settings`; "No chat selected" for `empty`; the unbuilt pane for every other destination, which names the destination and its path (never an invite token) and leaves navigation working.
- Settings (`SettingsPane.tsx`): the title strip ("Settings"), then `SettingsView` with `page` from the destination, `onNavigate` = `workspace.openInPane(paneId, { kind: "settings", page })` (stable per pane), the appearance controller, the platform, the preferences, the account (`me`, this device's name from the flows' chunk, falling back to "This browser", Sign Out), the registry's shortcut reference, the notification prompt and the build ID. No `pendingCount` and no Clear Cached Media yet (see seams). Until its chunk is there the pane is its title strip over the window background.
- Sidebar: `SidebarView` gets `ready={session.sidebar.ready}`, `actions={session.actions.sidebarActionsFor}` (Pin, Mark Read/Unread, Close, Archive, then Notifications ▸ Default, All, Mentions, None and, for a thread, Follow or Unfollow Thread, then Copy Link; temporary rows Close and Keep) and `typingFor={shell.typingFor}` (`createComposeActivityIndex`, one `composeActions` subscription per session, disposed with the shell). Row menus are the kit's lazy context menu: the menu kit chunk is warmed on the idle lane (`menus`), and a request before it arrives opens when it does.
- Message actions (`ShellModel.messageActions`, one `MessageActions` per session): `session.attachActions` hooks (reply and edit to the composer of the pane showing the chat, copy text and copy link to the clipboard, the reaction picker, refusals and uncertain outcomes as toasts in the model's tone, a bot's answer as a toast, the text-selection check for Cmd/Ctrl+C, the delete confirmation), and `MessageActionLayers` mounted once its chunk is there (`layers-chunk.ts`: the reaction picker popover and the confirmation alert, whose words come from what it asks: "Delete message?", or a bot button's confirm step). The layers are made on the warmup lane after the first paint; a question or a picker asked before then loads them at once and opens with them (nothing runs unasked; if they cannot load, the question is declined with a toast "Couldn't open that").
- **Every delete asks first.** The hooks include `confirmDelete` (`ActionHooks`, view's "Confirming a delete"), which `SessionActions.delete` calls before deleting a sent message: the one function the row menu, the quick actions, the `message.delete` command (Mod+Backspace), the command bar and a future native menu all call. A message still sending is cancelled at once (the session decides; the Mac's Cancel).
- Chat info (`ChatInfoPaneView.tsx`): the `chatInfo` destination (`/c/<id>/info`, or the chat title in the header). Title strip "Chat Info", then the chunk's `ChatInfoBody`: `createChatInfoModel(chatInfoOptions(...))` keyed by chat (session client, dialog row, intents, offline from `health`); a tab change replaces the destination in that pane (no history entry), a participant opens their profile in that pane. The media tabs get the session's media layer (`shell.mediaSources`, shared with the panes), the media viewer stepping through the Media tab's rows (`chatInfoMediaRows`), `downloadMessageFile` for files (as the message list's Download) and links through `parseAppLink` then `openExternal`; Add People and Remove outcomes are toasts (`onNotice`). Until the chunk is there, the title strip over the window background; a failed load says so with Try Again.
- Find commands (`ShellModel`): `registerFindCommands` once per session, `target` = the focused pane's `ChatFind` (`registerFind(paneId, find, timelineElement)`, while that pane shows a chat), `readSelection` = the selection inside that pane's message list only.
- Media (`ShellModel.mediaSources`): the session's `createCoreMediaSources` (from the content chunk, made on first use, disposed with the shell); the media viewer (`ShellModel.mediaViewer`, `MediaViewerHost`), rendered by the shell (`MediaViewerLayer`) while open; the attachments loader (`ShellModel.attachments`, `SessionAttachments`).
- Quick Search (`wireSessionQuickSearch`): `messages` over the local `searchMessages`, `remote` over `searchUsers` (server people). The server's message search covers one chat, so messages in Quick Search stay local; find in chat merges the server's.
- Emoji (`ShellModel.emoji`, `SessionEmoji`): the reaction picker is the emoji feature's (`ReactionPickerController` in the layers' popover: the quick row from the message's own emoji, learned picks and the Mac's set, expanding to the full picker), with the eight common emoji as the row until its code is there; Add Reaction starts loading it. The composer's `suggest` is `combinedSuggest(mentions.suggest, shell.emoji)`: `@` people and `:` emoji from one function. The light half and the pickers' code are warmed after the first paint, and the 44.5 kB table last on the idle lane (`SessionEmoji.warmData`, the engine only; the drawability scan waits for the first real use), or at once by the first picker or `:`, through the services' own `import()`. Warmed because the service worker precaches it (a local fetch after the first visit), it is parse cost rather than first-frame cost, and with it the first picker opens with its data and reaction chips get their names.

## The chat pane (`features/chat`)

- `ChatPaneModel` per pane follows the pane's destination (`paneDestination`). `show` opens the new chat's `OpenChat` before disposing the old one: the old controller saves its place (`leave`) into the workspace view state and its lease is released (the resident cache keeps it). Same chat with a message destination: `jumpToMessage`, no reopen.
- `OpenChat`: the lease from `session.openChat(chatId, anchor)` (`{ around }` for a message link), a timeline controller (`request` to `model.request`, `markRead` to `model.markRead`, `savePlace` into view state), an effect turning rows into items with `timelineItems` (unread line fixed for the visit), `open` with the saved place, unread line or latest once the window is ready (in the same task for a resident chat, so it repaints from memory in the next frame), `setItems` after, `setReadState`, `connectionLost` on waiting for network, the header and subtitle (`chatSubtitle`: connection first).
- Jump-to-latest count: the timeline controller computes it from the dialog's `unreadCount` (server-owned; the core raises it on each incoming message) minus incoming messages read locally that the server has not caught up with. The pane feeds the dialog through `setReadState` (from `model.readState`, the session's `all` sidebar list) and the rows through `setItems`. `latest-count.test.ts` drives the whole chain: a new incoming row while reading above raises the count by one. If it does not move in a browser, look at `__inlineApp.openChat.unreadCount`: the dialog row did not change.
- Direction: titles, subtitles and names sit at the interface's inline start (`text-align: start` on the line); only the text inside (`<span dir="auto">`) takes its own direction.
- View: `TitleStrip` with `ChatHeader`, `TimelineView` (`features/timeline`) inside `MessageActionsRegion` with `renderItem` from `ChatMessages.tsx` (`MessageRowView` with the sender's user row, its content slots and row actions; a service row once the content chunk is there; `DaySeparatorRow`, `UnreadLineRow`), and `ComposerView` over `createChatComposer` (send and edit, save draft, synchronous draft for a resident chat, `followDraft` for a draft that arrives later unless the user typed, the send key and spell check from the preferences, the reply and edit banners from the rows, Up in an empty composer edits `model.lastEditableMessageId()`, Escape in an empty composer focuses the list). The pane re-keys the inner view per chat; the pane itself is reused.
- Message content (`chat-content.ts`, one `ChatContent` per pane): the row context's `content` is `slottedContent` over a slot component that reads the content chunk itself, so the chunk's arrival renders the slots, not the rows. The environment (`createContentEnv` with the session's core media sources) is created once when the chunk is there; its handlers (`content-handlers.ts`, in the chunk) act on the pane's current chat: app links, open replies (a `thread` destination, in the other pane when `replyThreadsInSidePane`), open peer, copy text, compose, bot buttons, forms and the media viewer (below). Until the chunk arrives a photo or video slot is a box of its final size (`mediaModel`); other content appears with the chunk and the timeline holds the reader's place.
- **Typing.** `OpenChat` subscribes the chat's compose activity (`createChatTyping`); `subtitle` is `chatSubtitle({ connection, typing, isDirect, peerIsBot })`, rule 15's order: the connection state, then typing and other activity ("Ada is typing", "Alan is sending photo"), then "bot" for a bot's direct message. `ChatHeader` draws a typing subtitle with `TypingLine` (accent, the Mac's dots, still under reduced motion). The composer reports this user's typing (`createComposeReporter`, owned by `createChatComposer`): `typing` on the first edit and at most every 3 s, a stop on send (before the message goes) and when the composer empties; and the uploads of media sent from it ("sending photo": `SessionAttachments.followUploads` runs the composer's `followUploadActivity` over `LazyAttachments.activity` once the attachments chunk is there). The sidebar's rows show the same activity (`ShellModel.typingFor`).
- **Find in chat** (`ChatFind`, one per chat shown, disposed on a switch): Mod+F loads `find-chunk.ts` on first use, creates `FindInChatModel` over `coreFindSource` (the device's index) with `server: coreServerFindSource` (`searchServerMessages` in this chat, merged by message ID in the model) and opens it. `jump` puts the match's ranges on its row (`FindHighlights.showRow`, read by the rows through `highlightRangesFor`, and by rich-block content through the slot's `highlightRanges`) and calls `timeline.jumpToMessage(id, { highlight: true })`, which for a message outside the loaded window (a server hit) asks for a window around it (`request({ around })` → `ChatModel.request` → `ensure { around }`) and lands when it arrives; close clears the highlight. Focus returns where it was on close, else to the composer. `FindBar` is an overlay in the message area (`position: relative`, no insets), with the sender from the store's user rows ("You", "Unknown").
- **Mentions** (`ChatMentions`, per chat): the composer's `@` source. While a private thread in a space that the viewer did not create has these models, its `spaceMembers` list is subscribed, so rule 14 knows the viewer's role: an owner or admin auto-adds as the creator does. The first `@` loads `mentions-chunk.ts` and creates the participants model and `createMentionSuggestions` (recent senders from the chat model); the list fills in when they arrive. After an accepted send with mentions, rule 14 (`mention-models.ts`): `autoAdd` posts `addChatParticipants { chatId, userIds }` at once and toasts "Added Alan to this thread" with Undo (`removeChatParticipant` per person); `prompt` asks in the confirmation alert ("Add Alan to this thread?", Add) and posts on Add; a refusal or uncertain outcome is a toast in the session's words; people whose add is on its way are left out of the next decision.
- **Sends** consume the draft: the chat model puts the composer's revision on `sendText.draftRevision` (`@inline/view/features` `ChatModel.send`), so the sidebar's "Draft:" goes in the send's own commit; the optimistic row carries the intent's `tx`, the same row the core shows while the send is in the outbox (`MessageRow.tx`), so a reload or a leader handoff does not show it twice. Media sends do the same (`features/composer/attachments.ts`): the first `sendMedia` carries `draftRevision`, and each optimistic row is installed under its intent's `tx` right after the intent (`store.addOverlay`), as `ChatModel.send` does.
- **Attachments** (`SessionAttachments` per session, `LazyAttachments` per composer): `ComposerView` gets the chat's attachments from the first frame (so the Attach button is there and nothing moves), empty until the first file (paste, drop, the button) loads `attachments-chunk.ts` and the session's `createAttachmentDrafts` (optimistic rows appended to the chat's window at latest through `placeRows`). The composer's options are `withAttachments` over the lazy model (`attachmentOptions`). `chatDropTarget` on the pane root and `DropOverlay` inside it (files dragged over the pane, also while editing a message: the file joins the strip, Save sends only the edit, the file goes with the next message, as on the Mac). The first file starts the attachments chunk and the strip's view (`attachmentStripChunk`) together.
- **Message content's handlers** (`content-handlers.ts`, in the content chunk): bot buttons (`onAction`): a callback goes to `session.actions.invokeAction` and spins until the final outcome (the session toasts a refusal and the bot's answer); copy (toast "Copied" with the start of what was copied, and its length when cut: `buttonDisclosure`), open link, open URL (app links through the router), compose (into the pane's composer at the caret, focused), unavailable (toast); a confirm step asks in the shell's confirmation alert first, with the app's own line under the bot's words: "Opens example.com" (the link's host, mail address or number) or "Copies “…”" (`disclosureText`, the alert's `detail`). A document's Download (`onDownload`): the file from the core's `media` query (priority `opened`), saved by an `<a download>` over an object URL under `downloadFileName(name)` (bidi controls and path separators removed); a failure toasts "Couldn't download the file". `buttons.ts` and `file-name.ts` are imported directly, not through the content index. Forms (`onSubmitForm`): `chatModel.submitForm`; confirmed resolves (the answer as a toast), a refusal rejects (the form returns to editing; the notice as a toast), uncertain resolves with a "Not confirmed yet" toast (a retry could submit twice). Photos and videos (`onOpenMedia`): the media viewer.
- **Media.** The content environment's sources are the session's core media layer; each pane attaches the layer's visibility controller to its timeline's scroll container (`ChatContent.scroller`, through a ref on the message area that reads `surface.element()`).
- **Media viewer** (`media-viewer-chunk.ts`, loaded on the first photo or video opened): a modal `<dialog>` in the top layer (the kit's `DialogController`: Escape and a backdrop press close it, focus returns to what opened it), the photo at fit size at its largest stored size (`sources.open` and `hold` while shown) or a video with the browser's controls, "2 of 5", Left and Right through the photos and videos of the loaded window (mirrored in right to left), a modal keyboard layer so the app's shortcuts wait. No zoom. Media that is not a message's own (a block image) shows alone.
- Row actions: one `MessageActionsController` per chat over `messageActions.actionsFor` (the session's list with Delete confirmed first; Cancel of a sending message does not ask); its keyboard-focused row is `session.actions.setFocused`, the target of the message commands. It registers as the chat's picker anchors (`MessageActions.registerPickerAnchors`): a picker from the menu points at `reactionAnchor(rowId)`, and the row stays active (`setPickerAnchor`) until the picker closes. The row context carries `emojiEngine` (`ShellModel.emojiEngine`: chips named "thumbs up, 3, including you" once the table is here) and `viewerId`.
- **Emoji button** (`composer-emoji.ts`, `ComposerView`'s `trailing` slot): a stand-in `IconButton` ("Emoji", same box) until the pickers' code and the services are there, then the emoji feature's `ComposerEmojiButton`; pressing the stand-in loads them and opens the picker when it exists. A choice goes in at the caret and focuses the editor. Reaction chips call `toggleReaction`; the reply line jumps to the replied message.
- Window: the timeline's window carries `contiguousThrough` from `window.certifiedThrough`; when the controller trims its rendered range, the pane calls `model.trimToRows` with the kept rows.

## Status surfaces

| Status | Where |
| --- | --- |
| `starting` | The shell renders; the sidebar shows its loading placeholder (`ready` false). |
| `ready` | Nothing. |
| `connecting`, `updating`, `waitingForNetwork` | The chat header's subtitle (rule 15), never a banner. |
| `storageNotKept` | Quiet banner above the panes: messages aren't kept on this device. |
| `storageFull` | Banner, plus a note above the composer; a rejected send keeps its text (composer). |
| `outdated`, `superseded` | Full-pane screen with Reload. |
| `failed` | Full-pane screen with the core's `failure`, Try Again (reload) and Copy Diagnostics. |
| `signedOut` (core) | Full-pane "Signing out" while the app model ends the account. |

## Commands, keyboard, focus

- One `keydown` listener on the window feeds `app.keyboard` (bubble phase, after fields handled their keys). `focusin` sets the dispatcher's scopes from `data-focus-region` (`sidebar`, `timeline`, `composer`), so Escape in the message list focuses the composer.
- Session view hooks (`ShellModel`): focus sidebar (`SidebarHandle.focus()`, showing a collapsed sidebar first), focus composer (the focused pane's), toggle sidebar, quick search (`wireQuickSearch` per session once its chunk is there, `QuickSearchPalette` mounted in the shell; the first Mod+K before then loads it, mounts the palette and opens it on the next frame; its usage is erased on sign-out).
- Type anywhere: the composer feature's `listenTypeAnywhere(document, activeComposer)` plus the dispatcher's `onTypeToFocus`, both to the focused pane's composer.
- Focus guard: when the focused element is removed (a chat swapped, a layer closed with its trigger gone), focus would fall to `body`; at the next frame the shell puts it in the composer, else the message list, else the sidebar. A click on something unfocusable is left alone, so text selection is never disturbed.
- Appearance commands (`appearanceCommands`) are in the registry; their keys are the browser's zoom in a tab, so they are unbound there.

## Demo mode (development only)

`http://localhost:8001/?demo=small` (or `medium`, `large`; optional `&seed=N&storage=opfs|memory`) boots straight into a signed-in demo session: the real core against the simulated server, no sign-in screen. `globalThis.__inlineDemo` is the demo control (`send({ kind: "deliver" })`, `stream`, `agent`, `network`, `faults`). Sign Out in demo mode returns to the sign-in screen; reload with the parameter to come back. The parameter is ignored in production builds (the code is not there).

`globalThis.__inlineApp` (dev server, and the labs build, which defines `__INLINE_DEMO__`; a getter): `{ phase, status, core, role, panes: [{ id, path, focused, chatRows }], sidebarCount, openChatRows, openChat: { chatId, rows, unreadCount, readMaxId, source }, measures, unsavedWork, renderCounts? }`. `openChat.unreadCount` and `readMaxId` are the dialog values the timeline's jump-to-latest count is computed from. `openChat.source` is how the focused pane's chat got its first rows: `memory` (its window was ready in the task that opened it: resident, or restored from the boot snapshot), `sqlite` (the core's first answer had rows, or the chat is empty), `network` (the core answered with none while still loading); null until opened. With `?renderCounts=1` (also remembered with the demo parameter), `renderCounts` has `counts()` and `reset()` over every `countRender` name (`timeline:row`, `timeline:list`, `sidebar:row`, `sidebar:list`, `quick-search:*`), installed in the app's own module instance.

## Performance marks

Each moment is a `performance.mark` and a `performance.measure` of the same name from the time origin (navigation start) to the mark. Boot moments are recorded once per page.

| Name | When |
| --- | --- |
| `inline.boot.start` | The entry module started. |
| `inline.boot.gate` | The auth store was read; the gate left `booting`. |
| `inline.boot.signin-paint` | After the first paint of the sign-in screen. |
| `inline.boot.shell-paint` | After the first paint of the signed-in shell. |
| `inline.boot.core-ready` | The core reported `phase: ready`. |
| `inline.boot.sidebar-rows` | After the paint following the first sidebar rows. |
| `inline.boot.chat-rows` | After the paint following the first chat rows. |
| `inline.boot.snapshot-paint` | After the first paint of a shell restored from the boot snapshot (`App.tsx`). |
| `inline.boot.snapshot-reconciled` | After the paint following the core's answer to the last list restored from the snapshot. |
| `inline.chat.switch` | From `inline.chat.switch.start` (a pane switching chats) to the paint after the new chat's rows. Only the latest is kept. |

"After paint" is a frame then a task. `__inlineApp.measures` lists them in milliseconds.

Rows reaching the screen in an open chat (an incoming message, a send, an edit), marks only, the latest of each kept, with `detail: { chatId }`:

| Name | When |
| --- | --- |
| `inline.patch.apply` | The store client applied a frame-lane batch (reactive's; not added yet). |
| `inline.timeline.rows` | The chat pane read the chat model's rows after a store change: in the same task as the batch, when it ends. |
| `inline.timeline.set-items` | `setItems` returned: the controller has the items and has published `rendered`. |
| `inline.timeline.commit` | A microtask after `setItems`, queued after React's: the view has committed the rows. |

The pane's stages hand off within one task: the store client applies a patch batch at the start of a frame, the chat model's signals change inside it, the pane's effect runs when the batch ends and calls `setItems` once (a burst of patches in one frame is one call), the controller publishes `rendered` synchronously, and React commits in the microtask its store subscription queued. `incoming.test.ts` holds this. A frame lost between a message's acknowledgement and its patch is upstream of the store client: the core commits the update, materializes the window and posts the patch from the worker (published a microtask after the commit), and the frame lane then waits for the next animation frame.

## `global.css`

StyleX compiles into CSS layers and unlayered CSS beats layered CSS, so `global.css` must hold nothing a theme or a StyleX class may need to change: no `color-scheme`, colors, backgrounds or fonts. The appearance controller puts the canvas color, label color and `color-scheme` on `<html>`; type is set by the app's StyleX roots from the kit's tokens. The file keeps `height: 100%` on `html, body, #root` and `margin: 0; overflow: hidden` on `body`.

## Initial bundle

What the signed-in shell needs for its first paint loads first (the entry and the shell chunk with their static imports); the rest is behind dynamic imports in framework-free code, each with a loading rule that never blanks or shifts the window. The chunks and when each loads are one table, `view-chunks.ts`; the measurement reads the same table (`docs/performance.md`, "Measuring the initial JavaScript": `bun run size`).

| Chunk | Loads | Before it arrives |
| --- | --- | --- |
| Sign-in screen, `@inline/auth/flows` | On `signedOut`; the flows also on sign-out and for the settings' device name | Neutral frame (signed out only) |
| Message content (`content-chunk.tsx`) | Right after the shell's first paint (a frame, then a task; not the idle lane) | Photo and video slots keep their final box and paint the blurred preview the row carries (the same object URL the content view takes over); other content appears with the chunk |
| Service worker registration | Warmup | Nothing to show |
| Notifications and badge (`notifications-chunk.ts`) | Warmup | The "Turn on notifications" banner is there from the first frame (its prompt is made at once); the tab badge appears a moment after the paint; nothing is missed (the core's `newMessages` list) |
| Message action layers (`layers-chunk.ts`: reaction picker, confirmation alert) | Warmup; or the first Delete, Add Reaction or bot confirm step | Nothing: the question or picker is held and opens with the chunk; if it cannot load, it is declined with a toast |
| Boot sweep (`storageSweep`) | Warmup (not in the demo) | Nothing to show |
| Menu kit (`menus`: `@inline/ui/menu-kit`, the shared `menuKit`) | Warmup; or the first secondary click, context menu key or Shift+F10 on a row | Nothing: the browser's menu is prevented at once and the menu opens where it would have when the chunk arrives |
| Composer autocomplete (`composerAutocomplete`) | Warmup (through `loadAutocompleteChunk`); or the first `@`, `:` or `/` | No popup; rows appear with the chunk; keys keep their plain meaning meanwhile |
| Composer HTML paste (`composerPaste`) | Warmup; or the first HTML paste | Plain text and the composer's own payloads paste at once; an HTML paste is parsed when it arrives, where the caret was |
| Emoji light half (`emoji`) and pickers (`emojiPickers`) | Warmup; or the first Add Reaction, emoji button or `:` | The reaction picker is the eight common emoji; the emoji button is a stand-in of the same size that loads them; the `:` list is empty until the table arrives |
| Emoji table (`features/emoji/engine.ts`, 44.5 kB) | Warmup, last (`SessionEmoji.warmData`: the engine only, not the drawability scan); or a picker opening, the first `:` | The quick row works without it; the full picker and the `:` list fill in when it arrives; chips are named by their emoji until then |
| Quick Search | Warmup; or the first Mod+K | The palette is a closed dialog; Mod+K opens it once loaded |
| Settings (`SettingsBody` and its model with `SettingsView`) | Warmup; or a pane opening `/settings` | The pane's title strip over the window background |
| Find in chat (`find-chunk`: model, source, bar) | The first Mod+F (or Mod+G) in a chat | Nothing: the commands are bound from the first frame; the bar opens with the chunk |
| Mentions (`mentions-chunk`: participants, suggestions, add policy) | The first `@` in a composer; a send with a mention | No list; it appears with the rows |
| Attachments (`attachments-chunk`: the drafts model) and the strip's view (`attachmentStrip`) | The first file pasted, dropped or picked (both at once) | The Attach button and drop target are there; the strip appears with the file |
| Chat info (`chat-info-chunk`: the body, its model and options) | A pane opening `/c/<id>/info` | The pane's title strip over the window background |
| Media viewer (`media-viewer-chunk`) | The first photo or video opened | Nothing: the viewer opens with the chunk |

The warmup lane runs one task per idle slice, and from a one-second timer when the page is never idle (a busy page could otherwise hold it for many seconds; the scheduler's idle timeouts come with no time left in them).

Chunking (`vite.config.ts`): one `boot` group holds the entry's static closure (Rolldown's `$initial` modules that are in the app entry's graph, never an entry module itself), so the entry is 3 files instead of 21. The labs build turns the group off (`tooling/vite.labs.config.ts`); `bun run size <dir> --entries` checks both builds: no page runs another page's entry, and no lab or demo code is reachable from a production `index.html`.

17 November, bundle pass, canonical method: signed in 259.5 kB in 34 files before, 245.8 kB in 14 files after; signed out 163.7 kB to 154.7 kB (performance.md has the table and the breakdown method).

17 November, fourth integration pass (same method, the tree as other agents were changing it): signed in 245.9 kB at the start, 251.5 kB at the end. Of this pass's own share (`--modules`): `src/app` 18.9 to 19.7 kB and `src/features/chat` 11.3 to 11.7 kB (emoji session, rule 14, downloads, sign-out state, sweep wiring; the Settings and Chat Info pane views and `SettingsPaneModel` moved into their chunks, about 2.1 kB of module gzip out of the shell), and `@inline/link` 5.3 to 7.2 kB: the boot sweep imports the package index dynamically (`src/core/account-storage-sweep.ts`), which keeps `multiplex.ts` and `carrier.ts` in the boot chunk (1.6 kB of the set, measured with `MEASURE_STUB=src/core/account-storage-sweep.ts`: 249.9 kB). The rest (`@inline/ui` 28.5 to 30.6 kB) is other agents' work in progress.

17 November, fifth integration pass (same method; no other agent in the tree): signed in **244.8 kB** in 19 files, signed out **157.2 kB** in 7 files, entry 138.9 kB in 3 files. Over the 235 kB interim budget by 9.8 kB; signed out is under its 160 kB. Deferred, own cost: content 48.6 kB (after paint), emoji table 44.5 (warmed last), chat info 41.0 (now with the media tabs' sources, viewer and download code), settings 26.8, emoji pickers 25.0, Quick Search 21.4, find 16.0, sign-in 15.2, mentions 7.4, menu kit 7.0, layers 6.6, auth flows 6.4, media viewer 4.9, emoji light half 4.9, attachments 4.5, composer autocomplete 4.3, notifications 4.2, attachment strip 2.7, paste 2.5. By package (`--modules`): react-dom 59.9, `@inline/ui` 23.3, `@inline/view` 20.7, `src/app` 20.6, `@inline/chat-ui` 15.3, `@inline/composer` 14.7, `src/features/chat` 12.7, sidebar 11.7, message 11.3, `@inline/timeline` 9.2, `src/features/composer` 7.3, `@inline/link` 5.4, `@inline/reactive` 4.8, `@inline/platform` 4.8, react 3.2.

What the first frame of the sidebar, the chat rows and a typeable composer does not need but still carries (attributed gzip, `--modules`): `@inline/ui` tooltip controller 1.17 and positioning 1.37 (tooltips open on hover or keyboard focus only; positioning serves them and the popovers), toast controller 1.97 (no toast can show before an action), typeahead 0.67 (menus and lists other than the sidebar's own); `@inline/chat-ui` `text/highlight.ts` 1.64 (find marks, only while find is open; check whether highlight entities use it before moving it); in `src/app` the boot snapshot's capture 1.65 and saver 0.91 (used at the first hide or idle save, not the paint) and diagnostics 0.41 (the failure screen's Copy Diagnostics). The `src/app` items stay: the saver also erases on what the core reports and must be there when the page hides, and Copy Diagnostics must work offline on a failure screen (a chunk may not be cached) and inside the click's activation for the clipboard; deferring both would save about 3 kB of the 9.8 kB over. The `@inline/ui` and `@inline/chat-ui` items (about 7 kB together) are those packages' to move.

## Seams and placeholders

- **Settings:** no `pendingCount` (the core does not expose unsent intents to the UI yet) and no `onClearCachedMedia` (no media cache API in the session yet): the sign-out dialog says nothing about unsent messages and Clear Cached Media is disabled with its reason.
- **Message content:** the media viewer has no zoom, and opens a message's own photos and videos (an album opens at its row's first item). Downloads save documents only (photos and videos open in the viewer).
- **Mentions:** `directPeers` (people from direct chats, searched only) is not passed: it would read every sidebar item's signal inside the suggestions' computed; it needs a peers list from the core or the sidebar model first.
- **Rule 14 before the space's list arrives:** the viewer's role comes from `spaceMembers`, subscribed when the mention models are made (the first `@` or a send with a mention); a send in the moment before it answers asks instead of auto-adding.
- **Boot sweep cost:** its module imports `@inline/link` (the index) and `@inline/client/sqlite` dynamically: the first keeps link's multiplexer in the boot chunk (1.6 kB), the second loads the SQLite module and the WASM loader (about 78 kB) on the idle lane at every start, for `sahPoolNames` alone.
- **Quick Search:** the palette cannot say "still indexing" (find README).
- **Toasts with two panes:** the region sits in the message list of the chat pane mounted last, not the focused one.
- **Clipboard:** `navigator.clipboard.writeText` (the platform has no clipboard capability yet).
- **Boot snapshot:** built (`boot-snapshot/`). The worker still starts only after the auth store answers; see that README.
- **Provider sign-in:** not enabled (the server's provider route does not accept web clients); `completeProvider` is not called at boot.
- **Diagnostics:** contain the app log only; `connectAccount` takes no `log`, so link and core records are not in the ring buffer.

## Browser check script

One pass, top to bottom, in one browser profile. Each line: what to do, then what must be seen. Unless a group says otherwise, use the development server (`bun run dev`, port 8001) at `http://localhost:8001/?demo=small`; groups marked **(production)** use the labs build (`bunx vite build -c tooling/vite.labs.config.ts --outDir <dir>`, served with `bunx vite preview --outDir <dir>`), which is a production build with the demo in it. In the console: `d = __inlineDemo`, and 2 s after load `s = d.status.get().samples` (each sample is `{ chatId, messageId }`; `src/core/demo/README.md`). `__inlineApp` is the app's state (see "Demo mode"). Check light and dark (Settings ▸ Appearance), and repeat the starred lines at a narrow window (600 px) and with `dir="rtl"` on `<html>`.

### Boot and first frame

1. Load `/?demo=small` → no sign-in screen; the sidebar lists chats within about a second; `__inlineApp.phase === "signedIn"`, `core.phase === "ready"`, `role === "leader"`, `sidebarCount > 0`.
2. Reload with the network throttled to Slow 4G → the neutral window color, then the shell; never a sign-in flash, never "No chats" before the list (a static placeholder instead).
3. Reload on a chat (`/c/<id>`) → the sidebar and that chat's rows paint from the boot snapshot before the core answers (`measures` has `inline.boot.snapshot-paint`), then reconcile without a jump.
4. With notifications not yet decided, reload → the "Turn on notifications" banner is in the first frame (the panes never move down later); its button asks only on click.

### Sidebar

5. Click a chat → the URL becomes `/c/<id>`, the row is selected, the header shows the title.
6. Secondary click a thread row → the menu opens at the pointer (the first one a moment after the menu code arrives, never the browser's menu meanwhile, and the row's ring at once): Pin, Mark Read or Unread, Close from Sidebar, Archive, Notifications ▸, Follow Thread, Copy Link.
7. Notifications ▸ → Default, All, Mentions, None with the current one checked; choose Mentions → reopen: Mentions checked; chat info's setting agrees; reload: kept.
8. Follow Thread → the item reads Unfollow Thread on reopen; a direct message's menu has Notifications but no Follow.
9. Shift+F10 and the context menu key on a focused row → the same menu with the first item highlighted; Escape returns focus to the row.
10. `await d.send({ kind: "typing", chatId: d.status.get().recentChatIds[2], ms: 10000 })` → that row's preview becomes "Ada is typing" (short wording) in the accent color after three dots; only that row changes; it clears when the typing ends. `action: "recordingVoice"` shows bars instead of dots.
11. `await d.send({ kind: "otherDevice", action: "pin", chatId: <id> })` → the row pins at once; `"archive"` removes it from Inbox.

### Chat and timeline

12. Open a chat, another, then the first → the first paints at once from memory (`__inlineApp.openChat.source === "memory"`, `measures` has `inline.chat.switch`).
13. Open `s.search.chatId` and scroll up → older pages load with no anchor drift; the jump-to-latest button shows a count when unread arrive below.
14. `d.send({ kind: "deliver" })` with that chat open and at the bottom → the row appears at the bottom in the same frame; in another chat, the sidebar row moves up with its unread count and the tab title counts unread direct messages.
15. `await d.send({ kind: "stream", action: "start", ratePerSecond: 20 })`, then `action: "stop"` → rows arrive smoothly, nothing jumps while you read above.

### Composer

16. Type and press Enter → the row appears at once; the composer clears after acceptance; reload: the message is there.
17. Type without sending, switch away → the sidebar row shows "Draft: …"; switch back: the text is there; reload: still there. Send it → the sidebar row shows the message, never "Draft:", and reload shows no draft.
18. Up in an empty composer → "Edit Message" with your last message; Enter saves, the row shows "edited". Escape in an empty composer moves focus to the message list.
19. The emoji button beside Send is there from the first frame at its final size (nothing in the input row moves when its code arrives). Click it → a popover with the full picker above the button (its placeholder first if the table is still loading); type `heart`, Return → ❤️ at the caret, focus back in the editor.
20. Type `:thu` → a list with `:thumbsup:` first; Enter inserts 👍. Reopen the button's picker: 👍 is among the frequent ones.
21. In `s.privateThread.chatId`, type `@` → people in the chat first, others below; type letters to filter; Enter inserts a mention chip.
22. Drag a file over the pane → the drop overlay covers it; drop → the strip shows the file with progress (the strip's code loads with the attachments model, one round trip); Send → the row appears at the bottom at once with its final size.
23. Start editing a message, then drop a file → the file joins the strip; Save sends only the edit; the file goes with the next Send (the Mac's rule).
24. `await d.send({ kind: "media", uploadLatencyMs: 3000 })`, send a photo → while it uploads, `d.status.get().ownCompose` is `uploadingPhoto` (others see "sending photo"); it ends when the upload ends.
25. Paste an image copied from a web page → it is attached. Copy a message with a mention from the composer in one tab and paste into another tab's composer → the mention survives as a chip.

### Message actions and reactions

26. Hover a message → Add Reaction and More appear in the capsule. Secondary click → Reply, Edit (own), Add Reaction…, Copy Message Link, Copy Text, Delete.
27. Add Reaction from the capsule → the picker opens at the button; move the pointer into the picker: the capsule stays (its row stays active). Add Reaction… from the menu → the picker points at the row's Add Reaction button (else its bubble). Choose → the chip shows at once; closing the picker lets the row go inactive.
28. Inspect a reaction chip (accessibility tree) → its name is "thumbs up, 1, including you" once the emoji table is warmed (a few seconds after load), the emoji itself before; its tooltip says "You".
29. Reply → the banner over the composer, focus in it. Delete → "Delete message?"; Cancel keeps it; Delete removes it. Focus a row with the keyboard and press Mod+Backspace → the same question; on a message still sending it cancels without asking.
30. `await d.send({ kind: "network", online: false })`, react or edit → a toast "You're offline", never "failed"; `online: true` again.

### Message content

31. Open `s.photo.chatId` at `s.photo.messageId` (`/c/<chat>/m/<message>`) → the blurred preview in the first frame, the image replaces it without the box moving; the same for `s.tallPhoto`, `s.widePhoto`, `s.video` (poster).
32. Click a photo → the viewer opens dark over the window, "2 of 5"; Left and Right step (mirrored in right to left); Escape or the backdrop closes and focus returns to the row; Mod+K does nothing while it is open.
33. Open `s.document` → Download saves the file under its own name (no bidi controls or slashes). Open `s.voice` → it plays.
34. Open `s.buttons` → a callback spins, then the bot's answer as a toast; Copy shows "Copied" and the start of the text; a button with a confirm step asks first, with "Opens <host>" under the bot's words; Cancel does nothing.
35. Open `s.form` → submit locks it; `await d.send({ kind: "actions", failNext: 1 })` and submit again → the form returns to editing with the reason.
36. Open `s.entities`, `s.forward`, `s.blocks` → formatting, the forward header and the block message's text once each; a service message is a centered line.

### Find and Quick Search

37. In `s.search.chatId`, Mod+F → a bar over the message area, focus in its field, the chat does not move.
38. Type `s.search.query` → the device's matches at once with the word marked, then the server's; `s.search.messageId` (older than the loaded window) among them. Down moves through the previews without moving the chat.
39. Enter on `s.search.messageId` → the chat opens a window around it (it was not loaded), scrolls to it, the row flashes, the word stays marked in orange; Mod+G and Mod+Shift+G step; Escape closes, the mark goes, focus returns where it was.
40. Select text in a message, Mod+F → the field holds the selection. Focus the sidebar, Mod+F → the browser's own find.
41. Mod+K → Quick Search; type a word from a message → a Messages section from the device; two letters of a person you have no chat with → a People section from the server; Enter opens; Escape returns focus.

### Chat info

42. Click the chat title in `s.privateThread.chatId` → "Chat Info": the header (title, kind, count), Participants and Settings; a tab change replaces the URL without a history entry; Enter on a participant opens their profile (unbuilt pane) and Back returns.
43. Media tab of `s.photo.chatId` → a square grid; thumbnails fill in near the viewport; Enter or a click opens the viewer, and Left and Right step through this tab's photos and videos.
44. Files tab of `s.document.chatId` → Download saves the file as in the chat. Voice tab plays. Links tab: an app link opens in the app, another in a new tab.
45. Add People (a private thread) → pick `s.privateThread.outsiderUserId`'s name, add → they appear at once and a toast says so; secondary click their row → Remove Participant asks "Remove participant?", then a toast.

### Mentions outside a private thread (rule 14)

46. In `s.privateThread.chatId` (a thread you did not create), mention `s.privateThread.outsiderUserId` and send → the alert asks "Add … to this thread?"; Cancel adds no one; again and Add → added, with a toast.
47. In a thread you created with under 10 messages → they are added at once, the toast has Undo; Undo removes them (chat info follows). Where the account is an owner or admin of the thread's space (chat info shows its role), a thread someone else created auto-adds the same way, with no question.

### Typing

48. Open a chat, `await d.send({ kind: "typing", chatId: <open chat>, ms: 10000 })` → the header subtitle says "Ada is typing" (thread) or "typing" (direct) in the accent color with dots; it clears when it ends; offline, "Waiting for network…" replaces it.
49. Type in the composer → `d.status.get().ownCompose` shows typing within a moment, then a stop after sending.

### Toasts

50. Trigger several toasts (Copy Text a few times, a reaction offline) → they stack in the inline-end, block-end corner of the message list, 12 px in from its edges, above the composer, never over it or the Send button, at every window width; in right to left, the left corner. On the Settings pane (no message list) they sit in the window's corner.

### Keyboard, focus and layout

51. Mod+S hides and shows the sidebar (the toggle moves to the pane's strip); focus never stays in a hidden sidebar. Alt+Up and Alt+Down (Ctrl+K and Ctrl+J on Mac) move between chats; focus stays in the new chat's composer, never `body`.
52. With focus on the page, type a letter → it lands in the composer. Click into the message list, press Escape → the composer.
53. Open three chats, Back twice, Forward once → the pane and the address bar follow.
54. Drag the separator, reload → the width is kept; collapse, reload → still collapsed. ★ At 600 px the panes stay usable; with `dir="rtl"` the sidebar is on the right.
55. Open `/settings` → its strip, the page list and General; arrow through pages (the URL follows, Back walks them); change the send key to Cmd/Ctrl+Enter → the composer's hint changes at once, Enter makes a new line; turn spell check off → no underlines.
56. Open `/u/1` → an unbuilt pane names the destination and its path; the sidebar and Back still work.

### Connection and tabs

57. `await d.send({ kind: "network", online: false })` → within a second the header subtitle says "Waiting for network…" (no banner); `online: true` clears it.
58. Open a second tab on the same URL → `__inlineApp.role === "follower"` there; send from it; close the first tab → the second becomes `leader` within about a second, nothing sent twice.

### Loading after the first paint (production)

59. Network panel, cache disabled, reload (file names by prefix) → before the shell paints only `index`, `boot`, `Shell` and their static imports; right after the paint `content`; then on idle, in order: `register`, `account` (the boot sweep; not in the demo), `notifications`, `layers`, `menu` (the menu kit), `autocomplete`, `paste`, `emoji`, `chunk` (the emoji pickers), `quick`, `settings`, and last `engine` (the emoji table, 44.5 kB). `flows` and `signin` do not load while signed in.
60. Throttle to Slow 4G, reload, and at once: secondary click a row (the menu opens when `menu` arrives, no browser menu meanwhile), Delete a message (the alert opens when `layers` arrives), Mod+K (the palette opens when `quick` arrives), click the emoji button (the picker opens when its code arrives).
61. The first `@` in a fresh load before idle → no popup until `autocomplete` arrives, then the list; every key kept its meaning meanwhile. The first file dropped loads `attachments` and `AttachmentStripView` side by side.
62. Open the emoji picker after the warm-up → the full grid at once (no placeholder): the table was warmed.
63. Production build with `?demo=small` on `bun run build` output (not labs) → the sign-in screen (no demo code); no console errors from the content policy (Trusted Types, styles); `performance.getEntriesByType("measure")` lists the `inline.boot.*` names.

### Signing out

64. Sign Out → at once the whole window is "Signing out…" with no controls, then the sign-in screen with the address bar at `/`.
65. Press Back (several times) on the sign-in screen → the address bar stays `/` (never the ended account's `/c/<id>`). Sign in again (reload with `?demo=small`) and press Back past the new account's own entries → `/`, never a chat of the previous session.
66. Emoji recents: before signing out `localStorage` has `inline:emoji:1:` keys; after, none for that user.

### Real account (local server on port 8000; not possible in the demo)

67. `/` signed out → sign-in; email, then the 6-digit code → the shell with no reload; reload → no sign-in flash.
68. A new email → "Your account is ready" stays over the started session until Continue; "Sign out" there returns to sign-in with no notice.
69. Two tabs signed in, Sign Out in one → the other shows "You were signed out in another tab or window".
70. Sign in as A, close the tab during sign-out, sign in as B → within seconds of the paint, `navigator.storage.getDirectory()` no longer holds A's pool or `accounts/u<A>/`.
71. With a second production build served over the first → "Update ready: Reload" (an icon at the default sidebar width, words past 320 px); it never reloads by itself while a send is in flight or the composer has text.

## Tests

`bunx vitest run src/app src/features/chat` from `web/` (Node, no DOM). Added in the fifth pass: the shell's warm-up order and loaders, and that each feature holder names the same module as its chunk (`shell-warmup.test.ts`); the emoji table warmed alone (`emoji-session.test.ts`); history entries from before a sign-out reading as `/` (`history-session.test.ts`) and Back after sign-out through the runtime never reaching the ended account's chats (`runtime.test.ts`); chat info's media tabs, viewer rows, downloads, links and member toasts (`chat-info-pane.test.ts`); the picker's anchor and the row kept active (`message-actions.test.ts`, with the real `MessageActionsController`); the strip's view loading with the model, upload activity forwarded and reported, files dropped while editing (`content-wiring.test.ts`); at the pane (`pane-features.test.ts`): a find jump to an unloaded server hit asking `ensure { around }`, rule 14 auto-adding for a space admin and asking for a member, the sidebar's `typingFor` from one subscription, the rows' `emojiEngine`, the composer's emoji button; `sidebarActionsFor`'s Notifications and Follow and `dialogFor` over `ChatRow.dialogId` (`packages/view`, `session-actions.test.ts`). Added in the fourth pass: sign-out puts the address bar at `/` and the next account opens on its own workspace; a failed or unconfirmed erase sets the sign-in notice and the next sign-in clears it (`runtime.test.ts`); the signing-out surface (`pieces.test.ts`); the boot sweep queued on the warm-up lane, never in the demo, one call in `boot.ts` (`storage-sweep.test.ts`); emoji per account (`emoji-session.test.ts`: nothing loads before the warm-up, the warm-up never loads the table, `:` fills in when it arrives, recents under the account's prefix and erased with it, one `suggest`); at the pane (`pane-features.test.ts`): rule 14 prompt (asks, posts on Add), auto-add with Undo, nothing asked twice while an add is on its way, a refusal's toast; find in chat asking `searchServerMessages` and merging its hits by message ID; Quick Search asking `searchUsers`; `:` and `@` from one composer and Add Reaction loading the emoji picker; bot button disclosure, copy preview and downloads under a safe name (`content-wiring.test.ts`); the chat model's `draftRevision` and `tx` (`packages/view`, `chat-model.test.ts`). Before: the gate (cold boot signed out and signed in, sign-in completing through the real sign-in model, sign-out here, sign-out in another tab over shared auth storage, revocation, a new sign-in clearing the notice), the setup hold (`signin-hold.test.ts`: held over a started session until Continue, `done` not held, backing out, the account ending elsewhere, `LazySignIn` loading, retry and disposal), per-session wiring (marks, badge, page hide, link role, the session hook, shell hooks), `ShellModel` (layout persistence, commands, focus registry, collapsed sidebar focus, Quick Search loaded on first intent or preloaded, its failure toast, disposal), the chat pane (following the destination, the model swap with a resident chat repainting in the same task and reporting `memory`, message jumps, clearing, drafts, sends, the subtitle), the incoming path (`incoming.test.ts`: one incoming row is one `setItems` in the frame task of the store change, a burst is one call, the stage order), message actions (`message-actions.test.ts`, over the real session: reply and edit to the chat's composer, delete asks first from the menu and from the `message.delete` command through the session's `confirmDelete` hook (the session's `delete` is not replaced), a sending message is cancelled without asking, detaching removes the hook, the generic confirmation, the picker reacts, message links, notices as toasts in the model's tone; the layers made late: a delete or picker asked before they arrive waits and opens with them, declining while waiting, a failed load declines with a toast and a later one retries, warming), what this pass mounted (`pane-features.test.ts`, over the real session, store client and feature models with the chat-info scripted core: the find model created on the first Mod+F for the focused pane's chat and disposed with it, its jump reaching the timeline and the row's ranges, cleared on close; the composer receiving real `@` suggestions after the chunk loads; the rule-14 notice; the subtitle's order of connection, typing and other activity, and bot; the reporter's typing on input, stop on send and when emptied, disposal with the composer), the content wiring (`content-wiring.test.ts`: the environment exists in the same task the chunk arrives, with no other event; a photo row's placeholder paints its blurred preview before the chunk with the object URL the content view then reuses; buttons to `invokeAction` with the spinner until the outcome, copy, links, compose, unavailable, confirm steps; forms confirmed, refused and uncertain; the session's media layer and its visibility on the scroller; opening media; the viewer's items, stepping, holding and closing; the viewer host's chunk, replacement and keyboard layer; attachments loaded on the first file, shared per chat, rows placed in the window), chat info (`chat-info-pane.test.ts`: the destination maps to its pane; tab changes replace, profiles open in the pane), and the pure pieces (registry, status surfaces, metrics, unsaved work, focus regions, diagnostics, the demo parameter, warmup (including its timer when no idle slice comes), the settings pane model). The bundle measurement's own tests: `bunx vitest run -c tooling/measure-vitest.config.ts`.
