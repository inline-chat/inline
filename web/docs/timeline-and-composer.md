# Timeline and composer

The message list and the message input are where a chat client is judged. Both have been built for Inline before, natively and in earlier web experiments, and the lessons are below. Read this before touching either, and read the named Mac files first: they are the behavioral reference.

Numbers marked "start" are starting values taken from the Mac client or from earlier measurements. Tune them with measurements and record the change in `decisions.md`.

Two terms used below. A chat is **resident** when its window of rows is held in memory on the UI thread, so it can paint without asking the core. A **reading hold** is the timeline pinning a message at a fixed offset from the top of the viewport while everything around it changes size.

## Timeline

### Shape

- Our own list. A bounded window of real rows in normal document flow inside one scroll container. No virtualizer library, no absolute positioning of rows.
  - Why: text selection across rows, find in page, and variable heights then work as the browser intends, and there is exactly one thing correcting scroll.
- The timeline view model owns the window query, the timeline items and the scroll intent. A small host interface gives it the DOM facts it needs (viewport size, row rectangles, scroll offset) and takes its commands (set offset, scroll to row). The view model is testable in Node against a fake host.
- Rows are pure and receive prepared data. Timeline items (sender runs, day separators, the unread line) are a computed in the view model.

### Window

- Start values: an initial window of about one and a half screens of rows (the Mac client uses `screenHeight / 24 + 30` rows); grow by pages while scrolling; trim to about 200 rows around the viewport once the window passes about 300.
- Trim only rows far from the viewport, never while the user is scrolling, and compensate the offset in the same frame.
- Load older when the top of the window is within one viewport of the scroll position, and newer within one viewport of the end, and only in response to user movement.
- While connected, a window shows only contiguous certified history (see `core.md`). Never stitch cached rows across a hole; an earlier version did and showed a gap in the middle of a conversation.
- Keep a few recent chats resident so switching back paints in the next frame. Never release a chat that is on screen.

### Anchor model

An anchor is a message identity plus an offset from the top of the viewport. It is never an index and never a raw `scrollTop`.

The timeline is always in one of four modes:

| Mode | Meaning |
| --- | --- |
| Following latest | At the bottom; new rows keep it at the bottom |
| Reading at an anchor | The user is somewhere in history; nothing moves what they are reading |
| Going to a target | A jump to a message, the unread line or latest is in progress |
| Restoring | Reopening a chat at its saved place |

Rules, from `apple/InlineMac/Views/MessageList/MessageListAppKit.swift` and `MessageListViewport.swift`:

- **Capture** every visible row with its offset, in reading order. **Restore** with the first one that still exists, so a deleted row does not lose the place. Skip corrections under half a pixel.
- **Following latest** is exact: only a list resting at the bottom (within 1 px) stays pinned through size changes. A reader coming back down reattaches inside a small follow zone (start: 44 px). One wheel tick upward detaches immediately.
- Rows arriving below a reader never move the reader and never detach or reattach them.
- **The user wins.** Any wheel, touch, key or scrollbar input cancels an in-flight jump or animation and releases a held position, in the same event.
- A held reading position survives width changes, composer height changes, inset changes and media loads. Only the user or an explicit navigation releases it.
- The saved place for a chat is captured when scrolling goes idle and cleared when the newest message is on screen, so a chat left a few lines up reopens at the bottom.

### Compensation

One owner. Only the timeline controller writes the scroll offset.

- Batch `ResizeObserver` entries per frame. Sum the height changes of rows above the anchor, apply that as one offset correction, then update the size cache. Read layout first, then write.
- On prepend, detect that the change is at the head and correct by the added height in the same frame as the rows are inserted.
- After a programmatic correction, ignore the scroll event it causes. Sub-pixel offsets make that event unreliable as a signal of user intent.
- Ignore zero-size entries from hidden elements.
- The browser's own scroll anchoring (`overflow-anchor`) is not available in every engine and fights a manual owner. Turn it off on the timeline container and do the work ourselves.
- Media reserves its box from metadata before it loads. A row never changes height because an image arrived.
- Budget: no visible drift on prepend, resize and media load. That means under 1 px after any single operation and nothing that accumulates over repeated ones (sub-pixel corrections are skipped on purpose). Earlier work reached 0 to 0.1 px with this model; the failures came from two owners correcting at once and from index-based anchors.

### Opening a chat

- Cached, at latest: paint from local rows in the first frame.
- Cached with unread: open at the unread line. The line's position is fixed when the chat opens and does not move as messages are read during the visit. The Mac client reads a window of 44 rows on each side of the last read message.
- Unread not cached: keep the list hidden while history around the unread line loads, show a spinner only after 250 ms, place the list once, then fade it in. Never land and then re-anchor. If the connection is lost, or the user sends or jumps, show latest instead.
- Opening a chat does not mark everything read. Read state advances as messages are actually seen, and never across uncertified history.

### Jump to a message

- If the target is in the window, scroll to it. If not, open a window around it (local first, then the server's page around it).
- Far jumps, more than two viewports away, animate in two phases so they feel like travel without rendering everything in between: the Mac client eases to half a viewport short, then eases onto the target (0.3 s then 0.4 s). Nearer jumps are one 0.4 s animation.
- Highlight the target briefly. A quoted reply aims at the quoted line.
- "Jump to latest" is always available when not following latest, and shows the count of new messages below.

### Streaming messages

- Agent messages can update 20 to 60 times a second. Keep the identity of each block in the message stable, update only the block that changed, and coalesce to at most one update per frame.
- A streaming row grows downward. If the reader is following latest, stay at the bottom; if they are reading above, nothing they see moves.
- Budget: under 4 ms of scripting per update, and no other row renders.

### Selection

- Message text is real, selectable text. Never draw the conversation on a canvas.
- Selection must survive rows leaving the window. Follow `apple/InlineMac/Views/MessageList/MessageListTextSelection.swift`: track the selection's endpoints by message identity and offset, cache the selected text of rows as they leave, and build the copied text from that. Dragging from beside the text selects whole messages.
- This is known to be hard on the web and has not been solved in earlier attempts. Treat it as its own piece of work with its own tests.

### Tests the timeline must have

- Unit, against a fake host: each mode transition; capture and restore with deleted rows; follow-zone and exact-bottom rules; user input cancelling a jump.
- Browser: anchor drift on prepend, on pane resize, on delayed media, and during streaming above the reader; open at unread; jump to an uncached message. Selection across a trimmed row is tested by the selection work, later.
- Render budgets: an incoming message renders one row; a reaction renders one row; typing renders none.

## Composer

### Shape

- Our own editor. Ideas may come from Lexical, ProseMirror and Telegram's web clients; the code is ours.
- The model is `{ text, entities }`, the same shape as a message on the wire. A draft stores exactly what would be sent.
- The surface is one `contenteditable` element with a block per line and `dir="auto"` on each line. Mentions and other atoms are non-editable inline chips.
- Two paths for input:
  - **Structural edits** go through the model: Enter, deleting across an atom, formatting, paste, drop, undo and redo, inserting a mention. Handle them in `beforeinput`, update the model, re-render the affected lines, restore the selection.
  - **Plain typing and IME composition** are left to the browser and read back from the DOM into the model (a mutation observer and a line-level diff). Never interfere with a composition in progress.
- The composer model lives in `view` and is tested in Node. The DOM binding is imperative code handed an element; it does not depend on the view framework.
- The EditContext API would remove much of the read-back work but is not available in every engine we support. Do not depend on it; it can be an optional path later.

### What we own because of that

- Undo and redo history. Programmatic DOM edits break the browser's own.
- Mapping between DOM selection and model offsets.
- Paste: HTML is converted to text and entities through a sanitizer, never inserted as HTML. Preserve the zero-width non-joiner (U+200C); Persian text depends on it. Files and images on the clipboard become attachments.
- Autocomplete anchored at the caret for `@`, `:` and `/`.
- Markdown-style shortcuts, only where they speed up typing.
- The send key preference (Enter or the platform modifier plus Enter), with Shift+Enter always a new line. Up arrow in an empty composer edits the last message.

### Durability

- Draft changes are saved through the core with a short debounce (start: 300 to 400 ms) and flushed on `visibilitychange` and `pagehide`. A draft restores synchronously with the chat.
- Sending commits the intent, the optimistic row and the consumption of that draft revision in one transaction. The composer clears only after that commit, and only if the draft is still the revision that was sent.
- If storage cannot accept the intent, the composer keeps the text and says why.
- Attachments that are not yet sent are durable obligations with their source bytes kept. They are never part of an evictable cache.

### Feel

- Typing never waits on the store, the network or a render of anything but the composer.
- Focus moves to the composer when the user starts typing anywhere sensible in the window.
- Growing or shrinking the composer does not move what the reader is looking at (the timeline holds its anchor).
- Focusing must not scroll the page. Use `preventScroll`, and check WebKit, where it has been unreliable.
- Spellcheck follows the user's settings. In Electron it uses the system spellchecker.

### Order of work

1. Plain text, drafts, send, edit, reply, mentions.
2. Paste and drop of files, attachments and upload progress.
3. Formatting entities and shortcuts, links.
4. Slash commands, emoji, the remaining autocompletes.

### Tests the composer must have

- Model: every structural edit, undo and redo, entity ranges under insert and delete, paste sanitizing.
- Browser, on Chromium, WebKit and Firefox: typing, selection mapping, IME composition driven through the browser's input protocol, paste of rich content, atoms at line edges, right-to-left and mixed-direction lines.
- A manual pass with Persian and Japanese input methods before a release.

## Media in the timeline

- Message metadata carries dimensions and a tiny preview, so a row has its final size and a placeholder in its first frame.
- Use native `<img>` and `<video>` first. Decode and transform off the main thread only where needed.
- A media scheduler, separate from sync, owns transfers and priorities: what is visible and what the user opened come first, then nearby rows, then everything else. Warm nearby rows when scrolling goes idle.
- Loaded state belongs to a media registry, not to the row, so a row that leaves and re-enters the window does not reload.
- Object URLs are reference-counted and revoked. Decoded frames and bitmaps are closed explicitly and capped by total pixels. Animations pause when off screen, in the background, or under reduced motion.
- When asking a canvas for an encoded image, check the type of the result; engines differ in what they return.

## Widgets in messages

Web content inside a message runs in a sandboxed frame on a separate registrable domain. Show a snapshot first; mount it live only when visible and settled, with a small cap on live frames. A widget never resizes its row under the reader's anchor, and the list owns vertical scrolling.
