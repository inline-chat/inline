# Quick Search view

The Cmd/Ctrl+K palette: one field that finds chats, people, spaces, commands and messages, over `QuickSearchModel` from `@inline/view/quick-search` (read that README for ranking, timing and outcomes). The Mac reference is `apple/InlineMac/Features/CommandBar/QuickSearchPopover.swift`: 510 wide, 56 below the window's top, sidebar-height rows, 11 px section headings, the Mac's empty-state wording. Lab: `web/lab-quicksearch.html` (source `web/src/lab/quicksearch/`).

## Files

| File | What |
| --- | --- |
| `wiring.ts` | `wireQuickSearch(session, options)`: the model for an `AccountSession`, usage, and performing outcomes. Framework-free, no DOM |
| `palette-controller.ts` | `QuickSearchPaletteController`: the dialog, the combobox field, the listbox, pointer and scroll handling, row presentation. DOM, no framework |
| `QuickSearchPalette.tsx` | The view: renders the controller |
| `present.ts` | Pure helpers: highlight segments, labels, shortcut keys, dates, item equality, the key map, scroll math, the message title column (`messageTitleMaxWidth`) |
| `core-sources.ts` | Sources over the core: `createCoreMessageSource` (local `searchMessages`), `createCoreRemoteSource` (server people, `searchUsers`), `coreSearchRequest` and `coreRemoteRequest` (one request as a promise) |

## Mounting and wiring

In the signed-in shell, once per session:

```ts
import { QuickSearchPalette, quickSearchUsageStorageKey, wireQuickSearch } from "~/features/quick-search"

// Next to the other session wiring (ShellModel), disposed with the session:
const quickSearch = wireQuickSearch(session, {
  clock: browserClock(),          // @inline/reactive
  storage: localStorage,          // usage, under quickSearchUsageStorageKey(userId)
  platform: app.keyboard.platform,
  keyboard: app.keyboard,         // a modal "dialog" layer while open: global shortcuts stay quiet
  messages: createCoreMessageSource({ client: session.client, coreResource: session.coreResource }),
  remote: createCoreRemoteSource({ client: session.client }),   // server people
})

// The session's `app.quickSearch` command (Mod+K) calls the view hook:
session.attachView({ ..., openQuickSearch: () => quickSearch.open() })

// On sign-out, erase the usage with the account's other data:
storage.removeItem(quickSearchUsageStorageKey(userId))   // or quickSearch.clearUsage() while wired
quickSearch.dispose()
```

```tsx
<QuickSearchPalette quickSearch={quickSearch} />
```

Mount the palette once, anywhere in the shell: it is a `<dialog>` shown with `showModal()`, so it is in the top layer and needs no portal. Closed, it renders the field and nothing else; the results mount when it opens.

### `wireQuickSearch(session, options)` returns `QuickSearchWiring`

- `model`, `usage`, `platform`, `commands` (the session's registry), `local` (candidates), `context` (the focused pane's space), `isOpen`.
- `open()` (no-op when open or disposed), `close()`, `toggle()`.
- `activate(item?, intent?)`: the model records usage and closes (the palette restores focus synchronously on close), then the outcome is performed. Returns the outcome.
- `perform(outcome)`: `open` → `workspace.open(destination, { intent })`; `openUser` → the person's direct chat if one is listed, else `options.openUser`, else the `user` destination; `openSpace` → `options.openSpace`, else the space's members page; `runCommand` → `registry.run(id, { source: "palette" })`; `createThread` → `options.createThread(spaceId, title)`, else the `newThread` destination; `none` → nothing. Returns false for `none` and for a command that did not run.
- `photoUrl(userId)`, `clearUsage()`, `dispose()` (cancels searches, unsubscribes, saves usage).

What it reads:

- **Chats**: dialogs of `sidebar(all)`, the session's visible sidebar list, then `sidebar(archived)`, each chat once, through `createRowLocalSource` (a candidate is rebuilt only when one of its rows changes). The `all` and `archived` lists are subscribed for the session's life so the first open is complete from local data; `includeAllChats: false` searches the visible list only.
- **Spaces**: the spaces of listed chats. **People without a chat**: none yet (see gaps).
- **Context**: the space of the focused pane's destination (a chat's space, a space page, a new thread). It scopes message search and enables the Create row.
- **Usage**: every change of the focused chat is recorded as a switch (a direct chat under its person's key), except the chat already visible when wired (a restored workspace).

### Server people (`createCoreRemoteSource`)

`createCoreRemoteSource({ client })` returns a `CoreRemoteSource`: the model's `QuickSearchRemoteSource` over the core's `searchUsers` request (`remoteSearch` resource, people as `UserRow` values that are not in the view store). Export it from the app's Quick Search chunk next to `createCoreMessageSource` and pass it as `remote`.

- **Timing** is the model's: it asks 250 ms after the last keystroke (`quickSearchTiming.remoteDelayMs`, the Mac's `searchGlobalUsers` sleep), only for two or more characters, and aborts the previous request on every new query. An abort unsubscribes, which cancels the request in the core; a released request never delivers.
- **Placement** is the model's: people are ranked (`rankRemoteUsers`), those already shown locally are dropped by user ID, the rest are listed under "Global Search" below every local section. The source also drops duplicate IDs within one answer and asks for at most `SEARCH_USERS_LIMIT` (20); a leading `@` is stripped.
- **Failure is quiet**: offline (at once when not connected), server or unavailable resolve with no people, so the local results stay and no error line shows. `state` (`RemotePeopleState`: `idle`, `pending`, `done` with `count`, `failed` with `reason`) says what happened, for a quiet hint if the palette ever wants one; `stats()` counts answered, cancelled and failed requests.
- **Messages stay local.** The server's message search (`searchServerMessages`) covers one chat at a time, so the Messages section keeps using the local index (`searchMessages`); the remote source returns people only. Find in chat is where server message hits are merged.

## Behavior

- **Field**: `role="combobox"` with `aria-controls`, `aria-expanded` and `aria-activedescendant`; it keeps DOM focus the whole time. It is not a controlled input: it owns its value while typing, and the model's text is written back only when it differs (open and close), so an input method's composition is never disturbed. `setQuery` runs in the `input` event, so local results render in the same frame; nothing runs while composing, and the query is set on `compositionend`.
- **List**: `role="listbox"`; each section is a `role="group"` labelled by its heading; options have stable IDs derived from the item ID. Rows show an avatar (photo, emoji or initials on the Apple colors) or a glyph, the title with matched ranges as `<mark>` text runs (never HTML strings), a secondary run (subtitle, or a message's snippet with its ranges), and a trailing label (kind, the command's category with its shortcut in `Kbd`, or a message's time). Titles are `dir="auto"`.
- **Keys** (`paletteKeyAction`): Down and Up move; Mod+Down and Mod+Up go to the last and first; Home and End do too when the field is empty (with text they move the caret); Tab and Shift+Tab jump sections; Enter activates here; Mod+Enter in the other pane; Mod+K closes; Ctrl+N and Ctrl+P move on the Mac. Escape is the dialog's (the kit's dismissal stack closes the topmost layer). Every handled key is `preventDefault`ed, so the app's keyboard dispatcher ignores it.
- **Pointer**: movement over a row makes it active; a pointer event without movement (a re-render or a scroll under a still pointer) changes nothing, judged against the last position recorded on the document. A click activates here, Mod-click in the other pane, a middle click in a new tab. Pressing a row never takes focus from the field.
- **Scrolling**: when the keyboard moves the highlight, the active row (and its section heading, for a section's first row) is scrolled into view in the next frame, reading layout before writing once. A new query scrolls to the top. Pointer hover never scrolls.
- **Close**: Escape, a press outside the panel, Enter or a click on a row, Mod+K. Focus returns to where it was before the palette opened.
- **States**: no rows shows "Searching…" (pending), "Failed to load", "No results found", or, for an empty query with nothing at all, a hint; never a blank box. With rows, pending searches show a quiet "Searching…" line below everything, and a failed section says so there; rows already shown never move.
- **Message hits**: the chat title keeps its own width up to `clamp(min(7em, 50%), 40%, 16em)` of the text column and never shrinks below that; the snippet takes the rest (`messageTitleMaxWidth` is the same rule as a pure function). Before, both shrank by content width, so a long snippet squeezed the title to three letters.
- **Rendering**: rows are `memo`ized on item content (`sameItem`): the model keeps identity for unchanged async results, and local items rebuilt per query skip their render when nothing they show changed. Each row reads its own `isActive(id)` signal, so moving the highlight renders two rows. Row data (segments, avatar colors and initials, dates, shortcut keys) is prepared once per item object.
- **Style**: StyleX with the kit's tokens, logical properties only, light and dark through the tokens, motion tokens (0 ms under reduced motion), a border under `prefers-contrast: more` and forced colors, an outline for the active row and underlined highlights under forced colors.

## Gaps in the contract (`TODO(contract)` in the code)

- `messages` and `remote` are injected (the app passes the core sources above); without them those sections never appear. The lab injects a message source over generated data and the real `createCoreRemoteSource`, answering `searchUsers` on its scripted core.
- `searchUsers` answers carry no total and no paging; the palette shows at most 20 server people.
- No query lists spaces, or known people without a direct chat (members, contacts).
- No intent creates a direct chat; `openUser` falls back to the person's page.
- The `newThread` destination has no title, so the Create row's title is dropped unless `createThread` is injected.

## Check in a real browser

The tests run in Node without a DOM. In the lab (`lab-quicksearch.html`, production build), check:

1. Cmd/Ctrl+K opens the palette in the frame after the key (`__quickSearchLab.measures.openToPaint`), focused, near the top; Escape, an outside press and Mod+K close it and focus returns to the element focused before (the Open button).
2. Typing paints results in the same frame; `renderCounts["quick-search:row"]` grows only by rows whose content changed; arrows grow it by two per move.
3. Arrow through a long list: the active row and section headings stay in view; hold the pointer still over the list while typing and scrolling with keys: the highlight must not jump to the row under the pointer.
4. An IME (Japanese, Pinyin, or a Persian keyboard with composition): nothing filters until the composition commits, and Enter that commits does not activate.
5. Screen reader (VoiceOver, NVDA): the field announces the active option and its group; the empty and error states are announced.
6. Light and dark, right to left (Persian and Hebrew titles, highlights in RTL text), reduced motion, increased contrast, forced colors (Windows High Contrast), a narrow window (16 px gutters).
7. Slow and failing sources: the bottom "Searching…" line and the messages error line appear below the rows and nothing above them moves. A failing server (any reason in the lab's "Server failure") shows no error line; `__quickSearchLab.remote` is `failed` with the reason.
8. Message hit columns: `__quickSearchLabControl.setViewportWidth(480 | 750 | 1280)`, type "rollout", read `__quickSearchLab.messageColumns`: `title` is the title's text width or `expectedTitleMax` (whichever is smaller, within a pixel), `snippet` takes the rest of `column`. `setViewportWidth(null)` restores the window.

## Tests

`bunx vitest run src/features/quick-search` from `web/`: the core sources (requests subscribe once and unsubscribe; aborts cancel; server people: the 250 ms delay, cancel on a new query with the stale answer never shown, people below local results without the ones already shown, quiet offline failure), the wiring over a real `AccountSession` on a scripted core (lists subscribed, archived chats and spaces found in the same task, the keyboard layer, every outcome kind with defaults and injected handlers, usage recorded on pick and on chat switch but not for the restored chat, message search scoped to the context space and cancelled on dispose, unsubscribe on dispose), and the pure helpers (highlights with surrogate pairs and RTL, labels, shortcut keys per platform, dates, item equality, the key map including composition, pointer intents, scroll math).
