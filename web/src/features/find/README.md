# Find in chat

Mod+F in a chat: a bar over the top of the chat pane that searches this chat's messages on the device, lists the matches as previews, and steps through them in the chat. A port of the Mac app: `apple/InlineMac/Features/Chat/InChatSearch/InChatSearchBar.swift` (bar, previews, keys, focus), `apple/InlineKit/Sources/InlineSearch/InChatSearchViewModel.swift` (paging, stepping, count) and the Find menu in `AppMenu.swift` / `ChatViewAppKit.swift`. Lab: `web/lab-find.html` (source `web/src/lab/find/`).

Also here: `../quick-search/core-sources.ts`, the core-backed sources for Quick Search (end of this file).

## Files

| File | What |
| --- | --- |
| `find-model.ts` | `FindInChatModel`: query, debounce, paging, count, current match, stepping, the list and chat presentations, open and close. Framework-free, DOM-free |
| `find-source.ts` | `FindInChatSource` (pages and counts) and `coreFindSource(client)` over the core's `findInChat` and `countMessages`; `FindServerSource` and `coreServerFindSource(client)` over `searchServerMessages` |
| `commands.ts` | `registerFindCommands(registry, { target, readSelection })`: Find in Chat, Find Next, Find Previous |
| `find-bar-controller.ts` | `FindBarController`: the combobox field, the list's bounded window of rows, row presentation. DOM, no framework |
| `FindBar.tsx` | The view |
| `present.ts` | Pure: the key map, snippet runs, the list window, shortcut hints, dates |
| `selection.ts` | `chatSelectionText(document, root)`: the page's selection inside the chat, for seeding |

## Model (`FindInChatModel`)

```ts
const find = new FindInChatModel({
  chatId,
  source: coreFindSource(session.client),
  server: coreServerFindSource(session.client),   // optional: server hits for history the device does not hold
  clock, jump, captureFocus, onClose?,
})
find.open({ seed? }); find.setText("deploy"); find.next(); find.previous(); find.close()
```

Signals: `isOpen`, `text` (the field), `query` (trimmed), `state` (`idle | searching | results | noResults | indexIncomplete | error`), `hits` (loaded matches, newest first, each with `messageId`, `fromId`, `date`, `out`, `text`, `ranges`), `stale`, `count` (the core's, capped at 10,000), `total` (never below what is loaded), `current`, `currentIndex`, `position` (`{ index, total, capped }`), `counterText` ("3 of 128", "128 messages" while the list shows, "10,000+", "No results"), `showsResults`, `loadingMore`, `pagingFailed`, `hasOlder`, `indexComplete`, `canGoOlder`, `canGoNewer`, `fieldFocused`, `focusRequest`; with a server source also `serverFailed`, `serverSearching`, `serverCount`. `hits` are `FindHit`: a local hit has `cursor`, a server-only hit has `remote: true`.

Methods: `open({ seed })`, `close()`, `setText(text)`, `next()`, `previous()`, `moveActive(±1)`, `submit()`, `activate(hit)`, `setShowsResults(bool)`, `toggleResults()`, `loadMoreIfNeeded(index)`, `retry()`, `setFieldFocused(bool)`, `dispose()`.

Behavior (Mac values in `findTiming`):

- **Query.** The first page (100 matches) and the count are asked 120 ms after the last change. Spaces at either end change nothing. Fewer than two letters or digits is `idle` and asks nothing (the Mac's local rule). A new query aborts everything in flight (the core request is unsubscribed) and an answer for an older query is dropped even if the source ignored the abort. The previous query's matches stay listed (`stale`, dimmed) until the new first page, never stepped to.
- **Two presentations**, as on the Mac. A new query shows the previews. While they show, the arrows move through them and the chat does not move; hiding them (Enter, a click, the toggle) jumps to the chosen match. Over the chat, every step jumps.
- **Next and previous.** Next is the next older match (Mod+G, Enter over the chat, Up over the chat), previous the next newer one (Mod+Shift+G, Shift+Enter, Down over the chat). No wrap-around: next stops at the oldest match and previous at the newest (the Mac disables Find Next and Find Previous there). A step before any match arrived lands on the newest. Until the user moves, the current match follows the newest as pages arrive.
- **Paging.** A step past the loaded matches waits for the next page; the list asks for it 10 rows from its end. A page that advances nothing (same cursor) ends paging. A capped source that returns empty pages is followed up to 20 pages before "No results".
- **States.** `indexIncomplete`: nothing matched while the device is still indexing (`indexComplete` false; with matches the list footer says older matches may be missing). `error`: the first page failed; a later page failing keeps what is loaded and sets `pagingFailed`. `retry()` asks again. A failed count leaves the total at what is loaded.
- **Server hits** (with `server`). The server's first page (100) and its exact count (`countOnly`) are asked 350 ms after the last change (Mac `remoteDebounce`, `findTiming.serverDebounceMs`), never before the local first page is due. Local results show at once; server hits are merged in by message ID (the device's copy wins; a server-only hit is `remote: true`) and the list is newest first by message ID. The current match is kept by message ID, so it stays current when server pages grow the list; a hit the server adds older than the current one does not move it. A step past the loaded matches, or to a match below the last server page, waits for the next page of whichever source might hold one in between (Mac `resolvePendingStep`); the server's first page never holds up a step to a local match (it is asked at once when the step needs it). `loadMoreIfNeeded` pages both. The total is the server's count when it is at least the local one. While nothing is on the device, the state stays `searching` until the server answers. **Failure is quiet:** offline, refused or a failed page sets `serverFailed`, ends server paging, and keeps every local match; `retry()` asks the server again. A query change unsubscribes the server request in flight (it is on the same abort as the local one) and a late answer is dropped. Server message search covers this chat only (`SEARCH_MESSAGES` with a peer); server hits are not written to the replica.
- **Jump.** `jump({ chatId, messageId, ranges, query })`: `ranges` are `[start, end)` UTF-16 offsets into the message's text.
- **Focus.** `open()` calls `captureFocus()` once (not again while open) and `close()` calls what it returned. `open()` while open bumps `focusRequest`: the field takes focus and selects its text (Mac: Cmd+F while open). `close()` clears the query and cancels everything; `dispose()` also never restores focus.
- **Seed.** `open({ seed })` replaces the query with the seed's first line, whitespace collapsed, at most 128 characters (`selectionSeed`).

## View (`FindBar`)

```tsx
<FindBar model={find} platform={platform} sender={(fromId, out) => ({ name, seed, photoUrl })} />
```

- Renders nothing while closed. Open: a 36 px capsule (search glyph, the field, a spinner while searching, the counter as a polite live region, Next and Previous with their shortcut in the tooltip and `aria-keyshortcuts`, Show as List / Show in Chat, Close) at most 560 wide, 8 px below the top of the message area, centered; under it, the previews panel.
- **Overlay, not an inset.** The bar is `position: absolute` in the pane's message area (which must be `position: relative`) and does not call `surface.setInsets`. Why: `setInsets` re-places a held row (the unread line or a saved place while the reader has not moved) under the new top inset, which would move the chat when the bar opens or closes; the brief requires it not to. Jumps center the target (`centeredOffset`), which lands below a 36 px bar in any viewport taller than about 100 px. Mac sets a top overlay height instead; if the chat pane later wants targets placed below the panel, give the controller a separate "landing inset" that does not move holds.
- **Field.** `role="combobox"`, `aria-controls` the list, `aria-expanded` while previews show, `aria-activedescendant` the current preview; it keeps DOM focus throughout. Not a controlled input: the model's text is written back only when it differs; nothing is searched while an input method composes (set on `compositionend`).
- **Keys** (`findKeyAction`): Enter `submit` (over the list: show the chosen match; over the chat: next), Shift+Enter previous, Up and Down move through the list (newest on top) or step over the chat (Up older, like Telegram and the Mac), Escape closes (also when focus is on a bar button). Handled keys are `preventDefault`ed so the app's dispatcher ignores them.
- **Previews.** Avatar, sender, date (time today, "Mar 4" this year, else numeric), and one line of the message around the first match (24 characters before, 96 after; whitespace collapsed; ellipses) with every matched range in `<mark>` text runs (split text nodes, never HTML strings), `dir="auto"`. Rows are 54 px; at most seven show (and never more than half the viewport); only the rows near the viewport are in the DOM, with spacers for the rest, so thousands of matches stay a few dozen nodes. The current row is kept in view; the list scrolls itself, never the timeline. Pressing a row keeps focus in the field; a click activates it. Rows are memoized and each reads only whether it is current, so a step renders two rows.
- **Style.** StyleX with the kit's tokens, logical properties only, light and dark through the tokens, borders under increased contrast and forced colors (system colors for the current row and the marks there), the panel's fade is a motion token (0 ms under reduced motion).

## Commands

```ts
const unregister = registerFindCommands(session.registry, {
  target,                                              // ReadSignal<FindCommandTarget | undefined>
  readSelection: () => chatSelectionText(document, timelineElement),
})
```

| ID | Title | Shortcut | Enabled |
| --- | --- | --- | --- |
| `chat.find` | Find in Chat | Mod+F | a target, unless its bar is open and its field has focus |
| `chat.findNext` | Find Next | Mod+G (also F3 on Windows and Linux) | a target; while its bar is open, only if there is an older match. Closed: opens the bar (Mac) |
| `chat.findPrevious` | Find Previous | Mod+Shift+G (also Shift+F3) | the target's bar is open and there is a newer match |

Scope is `global`, gated by `target`: a chat pane has two focus regions (timeline and composer) and a command has one scope, so the "is a chat focused" rule is the target signal. Pass the focused pane's `FindInChatModel` while that pane shows a chat, else `undefined`. A disabled command does not match, so the key reaches the browser: without a chat, Mod+F is the browser's find.

**Rule for the browser's find:** Mod+F opens the bar, or focuses its field when focus is elsewhere. A second Mod+F while the field has focus falls through to the browser's own find. Mod+G at the oldest match and Mod+Shift+G at the newest fall through too (the browser's find next and previous then act on its own find, if open). None of the shortcuts is in the browser or OS reserved lists (`commands.test.ts` checks every platform).

## Mounting in the chat pane

The chat pane (`web/src/features/chat/`) does this; nothing in this folder touches it.

1. **One model per chat pane**, created with the pane's chat model and disposed with it. When the pane switches chats, close and dispose the old model and create a new one (or keep one per resident chat if the bar should survive switching; the Mac closes it).

   ```ts
   const find = new FindInChatModel({
     chatId,
     source: coreFindSource(session.client),
     server: coreServerFindSource(session.client),    // server hits; leave out for device-only find
     clock: browserClock(),
     jump: ({ messageId, ranges }) => {
       findHighlight.set({ messageId, ranges })       // for the row (see "Needs" below)
       timelineController.jumpToMessage(messageId)     // scrolls and flashes the row
     },
     captureFocus: () => {
       const before = document.activeElement
       return () => {
         if (before instanceof HTMLElement && before.isConnected && before !== document.body) before.focus({ preventScroll: true })
         else composer.focus()                         // the Mac returns focus to the composer
       }
     },
     onClose: () => findHighlight.set(undefined),
   })
   ```

2. **Render the bar** inside the message area, next to `TimelineView`, and make that area `position: relative`:

   ```tsx
   <div {...stylex.props(styles.messages /* position: relative */)}>
     <TimelineView surface={surface} renderItem={renderItem} />
     <FindBar model={find} platform={platform} sender={senderOf} />
   </div>
   ```

   `sender(fromId, out)` returns `{ name, seed?, photoUrl? }` from the store's user rows (`avatarSeed(user)` for the color seed); default "You" or "Unknown".

3. **Register the commands once per session** (or once per shell) with `target` = the focused pane's model when it shows a chat. `readSelection` should read the selection inside that pane's timeline element (`surface.element()`), so a selection in the composer never seeds the query.

4. **Insets: none.** Do not call `surface.setInsets` for the bar (see "Overlay, not an inset").

5. **Dispose** the model with the pane (`useModel` does it when the factory returns it, or call `find.dispose()`).

## Quick Search sources (`../quick-search/core-sources.ts`)

- `coreSearchRequest(client, query, signal)`: one `searchMessages`, `findInChat` or `countMessages` request as a promise: subscribes, resolves with the first `done` result (rejects `CoreSearchError` on `failed` or a result of the wrong kind), unsubscribes. Aborting unsubscribes at once and rejects with the signal's reason; a late answer is never delivered. Answers arrive in the frame after the core's patch (the store client's frame lane).
- `createCoreMessageSource({ client, coreResource })`: the Quick Search model's `QuickSearchMessageSource` over `searchMessages` (one subscription per query; the model's abort unsubscribes). Hits are copied to `MessageHit` field by field. `searchIndex` mirrors `CoreResource.searchIndex`; `resultsComplete` is the last answer's `indexComplete`.
- `createCoreRemoteSource({ client })`: server people (`searchUsers`), below local people; see `../quick-search/README.md`. `createNoopRemoteSource()` finds nothing (labs and tests). Server message search covers one chat only, so Quick Search's Messages section stays local; find in chat merges server hits itself (`coreServerFindSource`, above).

In the shell, where `wireQuickSearch` is called:

```ts
import { createCoreMessageSource, createCoreRemoteSource } from "~/features/quick-search/core-sources"

const messages = createCoreMessageSource({ client: session.client, coreResource: session.coreResource })
const remote = createCoreRemoteSource({ client: session.client })
const quickSearch = wireQuickSearch(session, { clock, storage, platform, keyboard, messages, remote })
```

**Index incomplete in Quick Search:** `QuickSearchMessageSource.search` returns hits only, so the model cannot say "still indexing". Until its interface carries it (see the report), the palette can read `messages.resultsComplete` and `messages.searchIndex`.

## Gaps (`TODO(contract)` in the code)

- Server hits carry no local cursor and the device may not hold the message: the jump goes through the same `jump` callback, so the chat pane's `jumpTo(messageId)` must open a window around a message that is not loaded (`ensure { around }`).
- `findInChat` hits carry `fromId` only; an old message's sender may not be in the view store, so previews fall back to "Unknown" unless the pane's `sender` can resolve it.
- The persistent highlight of the match inside the message text needs the message row and `MessageText` to take `highlightRanges` (see the report); today the row flashes as for any jump.
- Matches in file names (the Mac's `fileName` matching) are not indexed locally.

## Tests

`bunx vitest run src/features/find src/features/quick-search` from `web/`:

- `find-model.test.ts` (real store client, `coreFindSource` and `coreServerFindSource` over the scripted endpoint, manual clock). Server hits: local only (results before the server is asked; the server's copies change nothing), the server adds older hits (merged by ID, current match and index unchanged, steps reach them through `jump`, the next server page by `offsetId`, the server count as the total), a step at the oldest local match asks the server at once, the server fails (quiet, local stays, `retry`), nothing on the device (searching until the server answers), the query changes with a server page in flight (unsubscribed, late answer dropped). Local: debounce, whitespace, one-letter queries, superseded queries (unsubscribed; a late answer, and a source that ignores the abort), stale matches, count and position, capped and failed counts, no wrap-around, moving in the list without jumping then jumping on hide, activate, a step before results, paging on a step and on prefetch, a cursor that does not move, empty capped pages, index incomplete, first-page and later-page errors with retry, seeded open, focus requests, close restoring focus and leaving nothing in flight, dispose.
- `commands.test.ts` (real registry and keyboard dispatcher): disabled without a target, Mod+F seeded from the selection, the second Mod+F falling through, Mod+G opening and stepping and falling through at the oldest, Mod+Shift+G, Ctrl and F3 on Windows, no reserved or conflicting shortcut on any platform.
- `present.test.ts`: the key map (with composition), snippets (whitespace, cuts, several and overlapping ranges, surrogate pairs, right to left), the list window and reveal math, hints, the selection reader.
- `../quick-search/core-sources.test.ts`: request lifecycle, failure, wrong kind, abort before and during, mapping, the index state, no-op remote.

## Check in a real browser (the lab)

`lab-find.html` from a production labs build (`tooling/vite.labs.config.ts`). Query: `?theme=dark&dir=rtl&delay=400&mode=indexing&messages=8000&open=1&q=deploy`. `globalThis.__findLab` is a snapshot (read it again after each step); `globalThis.__findLabControl` has `open(seed?)`, `close()`, `shortcut("find" | "next" | "previous")` (real key events where focus is), `type(text)`, `compose(steps, commit)`, `key(name, modifiers)` (in the field), `next()`, `previous()`, `toggleResults()`, `activate(index)`, `scrollResultsToEnd()`, `selectText(messageId, start, end)`, `focusList()`, `setDelay(ms)`, `setMode("ready" | "indexing" | "error" | "failPaging")`, `setServer("off" | "older" | "fail")` (applies to the next query), `retry()`, `setTheme`, `setDir`, `resetRenderCounts()`, `settle(timeoutMs?)` (resolves with a snapshot when nothing is in flight).

1. Focus the list, `shortcut("find")`: the bar opens with focus in the field (`focusInField`), `chatScrollTop` unchanged. `close()` or Escape: focus back on the list (`focusRestores` + 1), `chatScrollTop` unchanged.
2. `type("deploy")`, `settle()`: 2,631 matches (seed 7, 4,000 messages), `counterText` "2,631 messages", `renderedOptions` a few dozen; `key("ArrowDown")` ×3 moves `currentIndex` without a jump (`jumpCount` 0) and `activeOptionRendered` stays true; `key("Enter")` jumps (`highlighted`, the lab row shows the marks); `shortcut("next")` and `shortcut("previous")` step and jump; `counterText` "N of 2,631".
3. Paging: `scrollResultsToEnd()` repeatedly, or step with `next()` past 100: `hits` grows by 100 per page, `core.find` counts requests.
4. `setMode("indexing")`: fewer matches and the footer note; with a query only old messages contain, "No messages found yet…". `setMode("error")`: "Couldn’t search messages." with Retry. `setMode("failPaging")`: the first page, then "Couldn’t load older matches." at the end.
5. `setDelay(800)` and type quickly: `core.cancelled` grows, only the last query's results show, the previous list stays (dimmed) until then.
6. Select text in a message (`selectText("3990", 0, 6)`), focus the list, `shortcut("find")`: the field holds the selection. With focus in the field, `shortcut("find")` returns false (left to the browser).
7. Server hits: `setServer("older")` (the device holds the newest quarter; the server holds all) and type a new query, `settle()`: `remoteHits` > 0, `hits` = local + remote, `serverCount` the full count, `total.count` equal to it; step with `next()` past the device's matches: `jumps` reach remote IDs. `setServer("fail")` and a new query: `serverFailed` true, `state` "results" with local hits only, no error shown; `setServer("older")` then `retry()`: remote hits arrive. `setServer("off")`: `remoteHits` 0 (the server's matches merge away). Snapshot fields: `remoteHits`, `serverFailed`, `serverSearching`, `serverCount`, `core.server` (server requests).
8. Light and dark, right to left (the bar and buttons mirror, Persian previews read right to left with marks in place), reduced motion, increased contrast, forced colors, a narrow window (the bar shrinks with 12 px gutters; the list never takes more than half the height), VoiceOver or NVDA (the field announces the active preview; the counter is announced).
