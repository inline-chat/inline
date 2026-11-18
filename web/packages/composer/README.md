# @inline/composer

The message input: our own editor, no editor library. A framework-free document model, its history, autocomplete triggers, the paste sanitizer, a controller with signals, and an imperative DOM binding for one `contenteditable` element.

`docs/architecture.md` places the composer model inside `view`. It is its own package for now so two agents do not share a package; it can move into `view` later without changing its API. It depends only on `@inline/core-protocol`, `@inline/reactive` and `@inline/ids`.

## Layout

| Path | What |
| --- | --- |
| `src/model/` | The document model and pure operations. No DOM. |
| `src/model/history.ts` | Undo and redo. |
| `src/model/triggers.ts` | `@`, `:` and `/` detection. |
| `src/model/shortcuts.ts` | `**bold**`. |
| `src/model/lines.ts` | The render model: lines and runs. |
| `src/internal.ts` | The composer's own clipboard format (tagged payloads, SHA-256 and HMAC), clipboard types, `quickPaste`. In the first frame. |
| `src/paste.ts` | Clipboard HTML to `{ text, entities }` (`sanitizePaste`). Loaded on first use: subpath `@inline/composer/paste`, or `loadPasteModule()`. |
| `src/clipboard.ts` | `loadPasteModule`, `pasteModuleIfLoaded`. |
| `src/keys.ts` | Keyboard routing as a pure function. |
| `src/controller.ts` | Signals, commands, send, reply, edit, drafts. |
| `src/dom/` | Rendering, selection mapping and the event binding. |

## The model

A document is `{ text, entities, selection, pendingMarks, revision }`, immutable per revision.

- `text` and `entities` have the shape of a message on the wire: `Entity` from `@inline/core-protocol`, offsets and lengths in UTF-16 code units. A draft stores exactly what would be sent. `ComposerEntity` adds `groupId` for group mentions, which the contract lacks (`TODO(contract)`).
- `selection` is `{ anchor, focus }` in the same offsets.
- `pendingMarks` are the marks the next typed text gets after toggling a mark at a caret; `null` means "inherit".
- `revision` goes up on every change to text or entities, including undo and redo, and never goes back. A selection change keeps it.

Entity kinds decide how ranges behave under edits:

| Kind | Types | Under edits |
| --- | --- | --- |
| Mark | bold, italic, underline, strikethrough, code, pre, textUrl, highlight, blockquote | Grows when typing strictly inside; does not grow at either edge unless pending; splits when typing inside with the mark toggled off; merges with an equal mark it touches; dropped when emptied |
| Atom | mention, groupMention, thread | Indivisible chip. A deletion or selection touching it covers all of it; a caret never sits inside it; it never spans a line |
| Derived | url, email, botCommand, phoneNumber and the rest | Kept and shifted while untouched; dropped when an edit touches its inside (the server detects these again) |

Invariants, enforced by `normalizeEntities` and `normalizeSelection` after every operation and checked by the property test:

1. Entities are sorted (offset, then outer first, then type and attributes), have positive length and lie within the text.
2. No entity boundary and no selection endpoint splits a surrogate pair.
3. Atoms do not overlap each other, never contain `\n`, and no other entity boundary falls inside one.
4. Equal marks never overlap or touch.
5. The selection is never strictly inside an atom.
6. Text contains `\n` as its only line break and no non-breaking spaces (see `normalizeText`).

Operations (`src/model/ops.ts`), each pure and total (no input offsets make them throw): `insertText`, `insertLineBreak`, `insertContent`, `replaceRange`, `deleteRange`, `deleteSelection`, `deleteBackward` and `deleteForward` by grapheme (`Intl.Segmenter`), word or line, `toggleMark` (range or pending), `setLink`, `removeLink`, `insertAtom`, `selectAll`, `sliceContent`, `trimmedContent` (for send), `diffText` (for read-back). All edits go through one primitive, `replaceEntities` in `doc.ts`.

**History.** A step is the content and selection before an edit. Consecutive typing (or consecutive deleting) coalesces while it continues from where it stopped and arrives within 1 s; a selection move, a pause, a toggled pending mark, or a structural edit starts a new step. Undo restores the step's selection. Capped at 200 steps.

**Triggers.** As in the Mac detectors (`apple/InlineKit/Sources/InlineKit/RichTextHelpers/`): `@` at the start or after whitespace; `:` plus at least one of `[A-Za-z0-9_+-]`, not after a letter, digit or underscore; `/` when only whitespace precedes it in the whole message and only whitespace follows the command word. Each returns the query and the range an accepted item replaces. A trigger touching an existing atom is ignored.

**Bold shortcut.** Typing the closing `**` of `**text**` on the current line removes the markers and bolds the text, as its own undo step. Content may not start or end with whitespace.

## Paste

`sanitizePaste({ html, text, internal }, { safeUrl, plain?, parseHtml?, clipboard? })` (`@inline/composer/paste`). Nothing from the clipboard is inserted as HTML.

- The composer's own copy writes `text/plain` plus `application/x-inline-composer`: JSON `{ v: 2, body, mac }`, where `body` is the JSON `{ v: 1, text, entities }` and `mac` the hex HMAC-SHA-256 of `body` under a secret key (`createInternalClipboard(key)`, `src/internal.ts`). A paste honors it only when the tag verifies (constant-time comparison); then the body is validated field by field and links go through `safeUrl` again. Any web page can set that type in its own copy handler with a mention whose text names one person and whose ID is another's; without the key it cannot make a matching tag, and editing a genuine payload (a swapped user ID) breaks it, so either falls back to the HTML or text. The payload never contains the key. The default (`documentClipboard`) is a random key per document: only this document's copies are honored. The web app passes one keyed per browser (`web/src/features/composer/clipboard-key.ts`), so its tabs honor each other's copies. SHA-256 is our own synchronous one (a copy event must set its data before it returns; WebCrypto is asynchronous), checked against the FIPS and RFC 4231 vectors. Text hidden only by styling (zero size, transparent, off screen) is pasted as visible plain text on purpose; what is hidden from layout is dropped.
- **Loaded on first use.** `src/paste.ts` (the HTML walker) is not imported by the controller or the binding. `quickPaste` (in `internal.ts`) decides plain text, plain paste and the composer's own payloads at once. An HTML paste before the module arrives is read from the clipboard inside the event, kept, and parsed when `loadPasteModule()` resolves; it is inserted where the caret was when pasted, mapped through whatever was typed or deleted meanwhile (text typed at the same point stays after it, so nothing is reordered), as its own undo step; several late pastes keep their order; a dispose before it arrives inserts nothing; a failed load inserts the plain text. `controller.hasLatePaste()` and `latePastes()` expose this for tests and labs. Drops of external HTML work the same way.
- HTML is parsed into an inert document and walked. Kept: bold, italic, underline, strikethrough, inline code, `pre` (with `language-*`), links that `safeUrl` accepts, line structure (blocks, `br`, list bullets and numbers, tab-separated table cells). Google Docs' `font-weight: normal` wrapper and style-based formatting are understood. Dropped: everything else, including scripts, styles, frames, media, forms, comments, hidden elements and all attributes.
- Text is normalized: CRLF and lone CR become `\n`, U+00A0 becomes a space, C0 controls and U+FEFF are removed. U+200C (Persian) and U+200D are kept.
- Falls back to plain text when the HTML has no text, is over 512 KB, or cannot be parsed. Mod+Shift+V pastes plain text.
- Files on the clipboard with no text go to the `onFiles` hook. Attachments are not in this package yet.

**Trusted Types.** `DOMParser.parseFromString` is a Trusted Types sink. Under the production policy (`require-trusted-types-for 'script'; trusted-types inline-script-url`, no `default` policy), an engine that enforces it refuses the string, `defaultHtmlParser` returns `null`, and paste falls back to plain text. To keep rich paste there, the app passes `parseHtml` built on a policy allowed by the CSP. That needs a policy name in the `trusted-types` directive, which is a shared-file decision.

## Controller

`createComposerController(options)` returns signals and commands.

- Signals: `doc`, `canSend`, `autocomplete` (the active `Trigger` or `null`), `reply`, `editing`, `sending`, `error`, `marks` (active at the selection), `canUndo`, `canRedo`.
- Commands: `insertText`, `insertLineBreak`, `deleteBackward`, `deleteForward`, `deleteSelection`, `apply(fn, kind)` for any model operation, `toggleMark`, `setLink` (refused if `safeUrl` refuses), `removeLink`, `insertAtom`, `acceptAutocomplete(item)`, `dismissAutocomplete`, `undo`, `redo`, `paste`, `drop`, `pasteFiles`, `clipboardPayload(content)` (what copy, cut and drag write), `hasLatePaste`, `latePastes`, `send`, `setReply`, `startEdit`, `cancelEdit`, `handleKeyDown`, `setDraft`, `flushDraft`, `dispose`.
- Options beyond the obvious: `clipboard` (an `InternalClipboard`; default `documentClipboard`), `loadPaste` (default `loadPasteModule`; tests inject one).
- Keys (`src/keys.ts`): the send key preference is Enter or Mod+Enter; Shift+Enter is always a new line; Mod+Enter always sends. Up in an empty composer calls `onEditLast`. Escape dismisses the autocomplete, then cancels an edit, then clears the reply. Mod+B, Mod+I, Mod+U, Mod+Shift+C (code, as on Mac) and Mod+Shift+X (strikethrough) format; Mod+Z, Mod+Shift+Z (and Ctrl+Y off Mac) undo and redo; Mod+K calls `onRequestLink`. While a trigger is active, arrows, Enter, Tab and Escape go to `onAutocompleteKey` first. Nothing is handled during a composition.
- Drafts: `saveDraft(text, entities, revision)` after 300 ms without changes (injected clock), and at once on `flushDraft` (the binding calls it on `visibilitychange` to hidden and `pagehide`) and `dispose`. Restoring a draft (`initial`, `setDraft`) does not save it back. No saves while editing a message: the draft is stashed (flushed first) and restored when the edit ends.
- Send: the request carries the trimmed text and entities and the revision sent. A pending draft save of that revision is cancelled. The composer clears only when `send` reports `accepted` and only if the document is still that revision; otherwise the text stays, and a rejection sets `error` to its reason and saves the draft.

## DOM binding

`attachComposer(element, controller, options)` makes `element` the editable surface and returns a detach function. A view calls it from a ref callback or `useElement`.

The surface holds one `div[data-line][dir=auto]` per line. Plain text is a text node, marked text a `span[data-marks]` with one text node, an atom a `span[data-atom][contenteditable=false]`. An empty line, or a line ending in an atom, ends with `br[data-filler]`. Text goes in as text nodes only. Class names come from the view (`classNames`, keyed by mark and atom type, `line`, `atom`, `link`). Lines are reconciled by common prefix and suffix, and a line whose DOM already matches the model is not touched.

Two input paths:

1. **Structural edits** go through the model. In `beforeinput`: `insertParagraph` and `insertLineBreak`; `insertText` when a mark is pending, the text has a line break, or the target touches an atom or spans lines; any deletion whose target touches an atom or a line break; `historyUndo`, `historyRedo`; `formatBold`, `formatItalic`, `formatUnderline`, `formatStrikeThrough`. Paste, drop and cut are taken in their own events. Other `format*` and list inputs are refused. In `keydown`: send, new line, format and history shortcuts, and autocomplete keys. The affected lines are re-rendered and the selection written back.
2. **Plain typing and IME** are left to the browser. `input`, a mutation observer and `selectionchange` read the surface back (`readDomText`, then `diffText` with the caret as a hint) into the model as an edit. If the browser's DOM differs from what the model renders (typing at the edge of a bold span, a browser-made `<b>`), that line is re-rendered. Between `compositionstart` and `compositionend` nothing is read back, rendered or handled; the read-back runs at `compositionend`.

Selection mapping (`src/dom/selection.ts`) uses one walk for text and offsets, so DOM the browser made maps as well as ours. A point inside an atom snaps to its edge. Going the other way, at a boundary the caret goes to the start of plain text, else the end of the previous text, so the browser types into the node whose formatting the model would give.

## What is verified where

| Covered | How |
| --- | --- |
| Every operation, entity rules, normalization, graphemes (ZWJ emoji, flags, combining marks), words, lines, atoms, marks, links | `model.test.ts` |
| Invariants 1 to 6, no throw, atoms never cut (labels in private-use brackets), undo then redo identity, undo to start | `property.test.ts`, 300 seeds × 120 random steps, mixed scripts. Re-run one with `COMPOSER_SEED=<seed>` |
| History coalescing, boundaries, cap, selection restore | `history.test.ts` |
| Trigger rules | `triggers.test.ts` |
| Clipboard tags: a genuine payload from another tab with the same key, forged payloads (zero tag, empty tag, another key, an untagged body), a replayed payload with edited user IDs, the key never in the payload, SHA-256 and HMAC vectors, constant-time comparison | `paste.test.ts` |
| Late paste: plain and own payloads without the module, keystrokes typed while it loads kept in order after the paste, two pastes in order, a deletion before it, a failed load, dispose, a late drop | `controller.test.ts`; through the DOM (clipboard read in the event, typed text read back) in `dom/binding.test.ts` |
| Paste: adversarial table (scripts, handlers, `javascript:`/`data:`/`vbscript:` links, frames, svg, math, templates, hidden content, comments, Word and Google Docs markup, nested formatting), structure, ZWNJ, NBSP, fallbacks, internal format validation | `paste.test.ts` under happy-dom |
| Key routing table | `keys.test.ts` |
| Draft debounce, flush, dispose, clear-after-accept, rejected and thrown sends, typing during send, edit and reply, autocomplete accept and keys, read-back diffing | `controller.test.ts`, virtual clock |
| Rendering, line identity, selection mapping both ways, read-back of DOM edits, composition deferral, `beforeinput` routing by synthetic events, keydown, paste, copy, `pagehide` flush, detach | `dom/binding.test.ts` under happy-dom |

happy-dom runs our code against its own DOM. It does not do real editing: it never fires `beforeinput` for typing, has no IME, no `getTargetRanges`, no caret movement, and its parser differs from browsers (it drops content after a `<script>` inside `<svg>`; the test says so). JavaScript evaluation is off in happy-dom, so "no script ran" there proves little; in browsers the inert `DOMParser` document is what guarantees it. The DOM tests prove the binding's logic, not engine behavior.

## Not verified: the manual browser matrix

Run on Chromium, WebKit (and real Safari) and Firefox, with a production build and the production CSP:

1. Typing: plain, fast, at line start and end, at both edges of bold, italic and link runs, after toggling a mark at a caret; check the model text, entities and caret after each.
2. IME: Japanese (Kotoeri or Google, conversion with candidate window, Enter to commit then Enter to send), Persian (ZWNJ with Shift+Space, mixed Persian and Latin on one line, digits). No text lost or doubled at `compositionend`; Enter during a composition never sends. Safari fires `compositionend` before its last `input`; Chrome after.
3. `beforeinput` coverage per engine: `insertParagraph` from Enter and from mobile keyboards, `deleteWordBackward`, `deleteSoftLineBackward`, `historyUndo` from the Edit menu, `formatBold` from the context menu, `insertReplacementText` from spelling correction. Confirm `getTargetRanges` returns usable ranges for deletions next to atoms.
4. Atoms: caret before and after a chip at line start and line end (the `br` filler), arrow keys across chips, Backspace and Delete next to chips, selecting across chips, chips in right-to-left lines.
5. Selection: double and triple click, Shift+arrows across lines, select all then type, selection across an empty line.
6. Undo and redo: typing bursts, after paste, after a mention, after the bold shortcut; the browser's own history must never act.
7. Paste: from Google Docs, Word, Notes, a web page, VS Code, a terminal, and from the composer itself (mentions survive); under the production CSP check whether rich paste falls back to plain text (Trusted Types).
8. Right-to-left and mixed-direction lines render with `dir=auto` per line; caret movement in them.
9. Focus without scroll (`preventScroll`, unreliable in WebKit before), spellcheck on and off, drag a selection within the composer, drop text and files.
10. Draft survives reload and tab close (`pagehide`); typing renders nothing outside the composer.

## Hooks left for later

Attachments (`onFiles`, `hasAttachments`), emoji data and slash command lists (the view supplies items and calls `acceptAutocomplete`), link editing UI (`onRequestLink`), typing broadcast (subscribe to `doc`).
