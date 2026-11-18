# Composer view

`ComposerView` renders a `ComposerModel`: the editing surface, the send button, the reply and edit banners, the send error line and the autocomplete popup. The editor itself is `@inline/composer` (model, controller, DOM binding); this folder renders around it and never reimplements editing. Lab: `web/lab-composer.html` (source in `web/src/lab/composer/`).

## Mounting

The caller creates the model, because the chat pane drives it as well as the view does (reply, edit, draft, focus). One model per chat is the simple shape: disposing it flushes the pending draft.

```tsx
import { ComposerView, createComposerModel } from "~/features/composer"

const model = useModel(
  () =>
    createComposerModel({
      initial: draftRow, // { text, entities, revision }, restored synchronously
      send: async (request) => toSendOutcome(await core.intent(...)), // resolve { status: "accepted" } only after the durable commit
      saveDraft: (text, entities, revision) => core.intent({ kind: "saveDraft", chatId, text, entities, revision }),
      safeUrl: (url) => safeLink(url)?.href ?? null, // @inline/chat-ui
      sendKey: settings.sendKey, // SendKey or ReadSignal<SendKey>
      suggest: (trigger) => mentionRows(trigger), // called in a computed; may read signals
      describeMessage: (id) => ({ senderName, text: previewText(...) }), // reply/edit banner; may read signals
      onEditLast: () => { model.composer.startEdit({ messageId }, { text, entities }); return true },
      onEscapeEmpty: () => timeline.focus(),
    }),
  [chatId],
)

<ComposerView model={model} placeholder="Message Ada" />
```

### What the caller supplies

| Option | Required | What |
| --- | --- | --- |
| `send` | yes | Commit the message (`request.kind` is `send` or `edit`, with `replyTo` or `edit`). Resolve `{ status: "accepted" }` only after the intent, the optimistic row and the draft consumption are committed; anything else keeps the text and shows the reason. Pass the core's `IntentRejection` as `reason` (`storageFull`, `notSignedIn`, `invalid`, `unavailable`, ...). A throw counts as "outcome unknown". |
| `saveDraft` | no | Persist the draft after 300 ms without changes, on `visibilitychange`/`pagehide`, and on dispose. Never while editing a message. |
| `safeUrl` | yes | The link allowlist for paste and links. |
| `initial` | no | The stored draft, restored in the first frame. |
| `sendKey`, `platform` | no | Send key preference (`enter` or `modEnter`; a signal follows the setting live) and `mac` or `other` (detected by default). |
| `suggest` | no | Rows for the active `@`, `:` or `/` trigger: `{ id, title, subtitle?, avatar?, glyph?, item, onAccept? }`, where `item` is the composer's `AutocompleteItem`. Return `[]` to show nothing. Asynchronous sources expose a signal and read it here. `onAccept` is called once after that row was accepted and inserted (Enter, Tab, click), never for a dismissed list or a stale click; a throw in it never undoes the insertion. The emoji source sets it (recents and frecency); mentions do not need it. |
| `describeMessage` | no | `{ senderName?, text }` for the reply and edit banners, or null while unknown (the banner still shows and dismisses). |
| `onEditLast` | no | Up arrow in an empty composer. |
| `onEscapeEmpty` | no | Escape in an empty composer: hand focus to the message list. |
| `errorText` | no | Words for a rejection reason; default `sendErrorText`. |
| `autocompleteChunk` | no | The autocomplete chunk already loaded (`{ createAutocompleteCursor }` in tests and labs), or its loader. Default: `loadAutocompleteChunk` on the first trigger in a page. |
| `clipboard` | no | The composer's own clipboard payloads. Default `appClipboard` (`clipboard-key.ts`): tagged with this browser's key, so a copy in one tab of the app pastes with its mentions and formatting in another. |
| everything else | no | Passed to `createComposerController` (`clock`, `draftDebounceMs`, `history`, `onRequestLink`, `onFiles`, `hasAttachments`, `parseHtml`, `loadPaste`). |

`ComposerView` props: `model`, `placeholder` (default "Message"; the Mac app says "Message {first name}" in a DM, "Reply" in a reply thread, "New thread"), `label` (accessible name, default the placeholder), `spellcheck` (default true), `showSendHint` (default true), `attachments`, `trailing` (controls before the send button, at a fixed size from the first frame: the chat pane's emoji button).

### What the pane calls

`model.composer` is the composer controller (`setReply`, `startEdit`, `cancelEdit`, `setDraft`, `flushDraft`, `insertText`, ...). On the model itself: `focus()` (the "focus composer" command; no scroll, caret where the model has it; false before the surface is mounted), `send()`, `dismissBanner()`, and the signals `focused`, `empty`, `banner`, `errorText`, `sendHint`. `listenTypeAnywhere(document, () => activeModel)` installs type anywhere to focus once for the app.

## Behavior

- **Surface.** One `div` handed to `attachComposer` through the model's `surface` part (`useElement`); React renders no children into it. Lines and atoms get StyleX class names through `ComposerClassNames`. It grows with its content from 34 px to 300 px and then scrolls; growth is plain CSS (min and max block size), with no measurement in the view.
- **Placeholder.** An absolutely positioned sibling with `pointer-events: none` and `aria-hidden`, shown while the model is empty and no IME composition is running (a composition does not reach the model until it ends). The editor carries `aria-placeholder`.
- **Send button.** Always rendered at a fixed size, so nothing shifts. `aria-disabled` (not `disabled`, which would drop keyboard focus mid-send) when nothing can be sent; a turning arc and `aria-busy` while the intent is being accepted; "Save" while editing. Pointer presses keep focus in the editor. `aria-keyshortcuts` follows the send key.
- **Banners.** "Reply to {name}" or "Edit Message" (the Mac app's words) with a one-line preview and a dismiss button; dismissing an edit restores the stashed draft. Escape clears them first (the controller's rule).
- **Errors.** A rejected send keeps the text and shows the reason in a `role=alert` line under the composer that the editor is described by; the next edit clears it.
- **Autocomplete.** A `popover="manual"` layer placed above the trigger character (flipping below without room) with the kit's positioning, re-placed before paint when the rows or the surface change. The list is the kit's `ListboxController` in passive form: focus stays in the editor, which points at the active row with `aria-activedescendant`; arrows move without wrapping, Enter or Tab accept, Escape dismisses, a click accepts, hover moves the cursor. Keys arrive through the composer controller's routing, which ignores keys during a composition. The popup hides while the editor is not focused and shows again on return, without losing the trigger. A new query puts the cursor on the first row; new rows for the same query keep it.
- **Focus.** `focus()` uses `preventScroll` and writes the model's selection back. Escape in an empty composer (when nothing else took it) calls `onEscapeEmpty`. Type anywhere: a plain character key while focus is not in a field focuses the composer before the key is handled (Option and AltGr characters included; shortcuts, Space, navigation keys and compositions excluded).
- **Styling.** StyleX and the kit's tokens; composer metrics from the Mac glass composer in `composer.stylex.ts`. Logical properties throughout, so the chrome mirrors in right to left; each line is `dir="auto"` from the binding. No focus ring on the editor (as on Mac); the pill's border tints while focus is inside. Buttons keep the kit's `:focus-visible` ring. Transitions use the motion tokens; the pending arc stops under reduced motion.
- **Render cost.** `ComposerView` reads no signal itself. The placeholder, send button, banner and error line each read their own signals, so typing renders nothing except when emptiness or sendability flips; moving the autocomplete cursor renders two rows.

## Loaded on first use (for the app's chunk table)

Plain typing, Enter to send, IME composition and undo are in the first frame and wait for none of these. Each loader is framework-free, loads once per page, and the same specifier in `web/src/app/view-chunks.ts` resolves to the same chunk, so registering it there both counts it in `bun run size` and warms it.

| Register in `chunkImporters` | Loads | Before it arrives |
| --- | --- | --- |
| `composerPaste: () => import("@inline/composer/paste")` | The first HTML paste or drop (`loadPasteModule`, `@inline/composer`); warm it in `afterFirstPaint` | Plain text and the composer's own payloads paste at once without it. An HTML paste is read from the clipboard inside the paste event and parsed when it arrives, inserted where the caret was, before anything typed meanwhile (keystrokes keep their order). If it cannot load, the plain text goes in. |
| `composerAutocomplete: () => import("../features/composer/autocomplete-chunk")` | The first `@`, `:` or `/` (`loadAutocompleteChunk`, `autocomplete.ts`): the list's cursor (the kit listbox) and `AutocompletePopup` | No popup; rows are computed (sources start loading) and appear with the chunk; every key keeps its plain meaning meanwhile. Later composers have it from their first frame. |
| `attachmentStrip: () => import("../features/composer/AttachmentStripView")` | The first file added (`attachmentStripChunk.load()`, `strip-chunk.ts`; `ComposerAttachments.add` calls it) | Nothing (no file yet). To start it with the attachments model, call `attachmentStripChunk.load()` where `LazyAttachments.add` loads the attachments chunk. |

`AttachButton` and `DropOverlay` stay in `AttachmentStrip.tsx` (first frame); `AttachmentStrip` is now a thin wrapper that renders `AttachmentStripView` once a file exists and the chunk is here.

Measured (analysis build, 17 November, this tree): the signed-in set lost `paste.ts` (2.5 kB, now its own chunk), the autocomplete chunk (4.3 kB with the kit listbox, selection and popup) and `AttachmentStripView` (2.7 kB). The clipboard tag added `internal.ts` (1.8 kB with its SHA-256) to the first frame, because a copy must write its payload synchronously.

## Rich paste between tabs

`clipboard-key.ts`: `appClipboard` (the model's default), `createAppClipboard(storage)`, `browserClipboardKey`, `CLIPBOARD_KEY_STORAGE` (`inline.composer.clipboardKey`). One random 32-byte key per browser profile in the origin's `localStorage`, read on every copy and paste, made at first use; payloads carry an HMAC-SHA-256 of their body under it (never the key), checked in constant time. Another origin's page cannot read the key, so it cannot forge a mention; an edited payload (a swapped user ID) fails the check and pastes as plain text. Without storage, a key per document (rich paste inside the tab only). Not account data; sign-out need not remove it.

## Attachments

Paste, drop and the "Attach files" button add files to a strip above the editor; Send sends them. Framework-free model in `attachments.ts`, views in `AttachmentStrip.tsx`; the media layer's side is `features/media/README.md`, which also has the chat pane's wiring.

```ts
const drafts = createAttachmentDrafts({ client, userId })       // once per session; dispose on sign-out
const attachments = drafts.forChat(chatId)                       // survives the composer model being recreated
const model = createComposerModel(withAttachments({ send, saveDraft, safeUrl, ... }, attachments))
<ComposerView model={model} attachments={attachments} />          // without `attachments`: text only, as before
```

- **Durable at once.** Each file goes to the core with `attachFile` the moment it is added (bytes staged, upload started). The strip follows it through the attachment's own `media` subscription: staging, uploading with a fraction, uploaded, failed. Remove posts `discardAttachment` (after `attachFile` settled).
- **Send** (`attachments.wrapSend`, installed by `withAttachments`): with attachments, one `sendMedia` per attachment with its optimistic row (`optimisticMediaRow`, final size at once), the text, entities, reply and the draft's `revision` (`draftRevision`, so the commit consumes the draft) on the first (the Mac's `GlassComposeAppKit.send`); each row is installed right after its intent under the intent's `tx` (`client.store.addOverlay`, so it is the row the core shows from the outbox, as `ChatModel.send` does for text); otherwise, and for edits, the given `send`. The composer clears only after the core accepted the first message (which carries the text). Attachments the core refused stay, with a note; a later send reuses their client keys, so the core deduplicates. Send waits for each attachment to be staged and described (`ATTACHMENT_INFO_TIMEOUT_MS`, 15 s), and refuses with `attachmentFailed` while one failed to stage.
- **Limits.** 500 MB a file (`MAX_ATTACHMENT_BYTES`, the server's `MAX_FILE_SIZE` and the Mac's `MediaUploadLimits` for video and documents; photos are compressed by the core before its 40 MB photo limit applies), no empty files, at most 20 in the strip (`MAX_ATTACHMENTS`, web only; the Mac has no count limit). Refusals are worded in the strip's `role=alert` line ("“huge.mov” is too large. The upload limit is 500 MB.").
- **Thumbnails** are object URLs of raster images only, revoked when the item leaves the strip (or is sent) and on dispose.
- **Size, length and preview** (`attachment-probe.ts`). A photo or video is decoded a task after it is added (the strip shows it first), one file at a time for the session, bounded (`ATTACHMENT_PROBE_TIMEOUT_MS` 6 s; a video's metadata and frame `VIDEO_PROBE_TIMEOUT_MS` 4 s), and `attachFile` then carries `width`, `height`, `duration` and `preview`: a complete JPEG at most 40 px on the long side, on white, quality 20, the server's stripped thumbnail (`server/src/modules/files/strippedThumbnail.ts`); the Mac makes none of its own. Without a decode (unsupported, too slow) the file goes on without them. Documents are handed over at once. The decoded bitmap is closed as soon as its preview is drawn. Tests inject `prober`.
- **Photo or file** (the Mac's `shouldSendAsFile`, `apple/InlineMac/Views/Compose/GlassComposeAppKit.swift`): an image whose sides are more than 20:1, or both under 50 px, goes as a file (`attachFile.as: "document"`).
- **Upload activity.** `attachments.activity` (optional on the interface): the strongest kind of a *sent* attachment whose upload still runs (`uploadingVideo`, then `uploadingPhoto`, then `uploadingDocument`), null otherwise; attachments only sitting in the strip are not reported. A sent attachment keeps its media subscription until its upload ends, then lets go. The pane reports it with `followUploadActivity(attachments.activity, reporter)` (`reporter` is the chat's `createComposeReporter`; returns a dispose that ends a running activity). `LazyAttachments` forwards it as `activity: computed(() => this.#inner.get()?.activity?.get() ?? null)`.
- **Retry** of a failed item hands the same file to the core under a new attachment ID and discards the old one.
- **Drop target.** `DropTarget` (framework-free) on the chat pane's root shows `DropOverlay` while files are dragged over the pane (a depth counter through child crossings; text drags ignored) and adds dropped files; a drop the editor already took is not added twice.
- **While editing a message**, as on the Mac (`GlassComposeAppKit.handleAttachments` and `handleFileDrop` check only `canMutateDraft`, true while editing; `send()` with `editingMsgId` sends only the edit): a file pasted or dropped joins the strip, the Attach button stays enabled, Save sends only the edit, and the files go with the next message. The chat pane's drop target follows this too (`chatDropTarget` in `features/chat/chat-attachments.ts`, enabled whenever the chat has attachments).
- The strip's controls: each chip has "Remove {name}", a failed one "Try {name} again".

## Files

| File | What |
| --- | --- |
| `attachments.ts` | `createComposerAttachments`, `createAttachmentDrafts`, `withAttachments`, `followUploadActivity`, `attachHints`, limits and wording. |
| `attachment-probe.ts` | `AttachmentProber`, `browserAttachmentProber`, `serialProber`, `encodePreview`, `previewSize`, `sendsAsFile`. |
| `strip-chunk.ts`, `AttachmentStripView.tsx` | The strip's lazy view and its loader (`attachmentStripChunk`). |
| `autocomplete-chunk.ts`, `autocomplete-cursor.ts` | The autocomplete chunk: `createAutocompleteCursor` (the kit listbox) and `AutocompletePopup`. |
| `clipboard-key.ts` | The browser's clipboard key and `appClipboard`. |
| `drop-target.ts` | `DropTarget`: files dragged over a chat pane. |
| `AttachmentStrip.tsx` | `AttachmentStrip`, `AttachButton`, `DropOverlay`. |
| `model.ts` | `createComposerModel`: controller, autocomplete, banner, error text, focus, and the `surface` and `popup` parts. |
| `autocomplete.ts` | `createComposerAutocomplete`: rows from `suggest`, `onAccept`, the cursor once its chunk is here (`cursor`, `chunk` signals), key handling, `loadAutocompleteChunk`. DOM-free. |
| `text.ts` | Send hint, error words, the type-anywhere and Escape rules. Pure. |
| `type-anywhere.ts` | The document listener for type anywhere. |
| `dom.ts` | Browser glue: the rectangle of a model range (via `offsetToDomPoint`), editable-target check. |
| `ComposerView.tsx`, `AutocompletePopup.tsx`, `icons.tsx` | Views. |
| `composer.stylex.ts` | Composer metrics. |

Tests (`bunx vitest run src/features/composer` from `web/`): the accept hook (once per accepted row, never for a dismissed list, a throwing hook), the autocomplete chunk (not loaded for plain typing, once on the first `@`, keys plain and in order until it arrives); probes (size, preview and `as: "document"` reach `attachFile`; a task later; one decode at a time across chats; failures and timeouts; oversize previews; removed before the probe ends), the preview encoder's size, color and type check, upload activity and `followUploadActivity`, editing with files (Mac rule), the strip's view loading on the first file; attachments (add, progress, remove, a refused stage and a failed upload with retry, send with one and with three, a rejected send keeping them and reusing client keys, a partly refused send, waiting for the core, limits, inside a real composer model, per-chat drafts), the drop target (Node `EventTarget`s), and the autocomplete list against the real composer controller and kit listbox (opening, cursor, query changes, key routing including composition, Escape, pointer accept, failing sources, one source call per query), the model (mentions as atoms, send and rejection words, live send key, banners and dismissal, emptiness, focus before mount, draft flush on dispose), the text rules, and type anywhere with a stand-in document. The `surface` and `popup` parts are browser glue and are checked in the lab.

## Labs for the new behavior

- `web/lab-composer.html`: `__composerLab` adds `acceptedSuggestions` (each accepted row's id, from its `onAccept`), `autocompleteChunk` and `cursorReady` (false until the first trigger loads the chunk), `pasteModuleLoaded`, `latePaste`, `clipboardKeyStored`. `__composerLabControls` adds `payloadForSelection()` (select text with a mention, call it in tab A), `pasteInternal(raw, text)` (call it in tab B with that string: the mention must survive), `forgedPayload(text?, userId?)` (a payload under another key: must paste as plain text), `pasteHtml(html?, text?)` (late when the paste module is not loaded yet), `selectAll()`. Buttons: "Paste forged mention", "Paste HTML".
- `web/lab-attachments.html`: `__attachmentsLab` adds `attachHints` (per `attachFile`: `as`, `width`, `height`, `duration`, `previewBytes`), `activity`, `stripLoaded`, `editing`, `ownPhotoUrls` (each own photo row's URL: it stays the local one until the server copy is ready). `__attachmentsLabControl` adds `setEditing(on)`, `pasteFile()`, `addOddImages()` (a 40×30 and a 2100×100 image: both must show `as: "document"`).

## Check in real browsers

Chromium, WebKit (Safari) and Firefox, in the lab, light and dark, both directions, wide and narrow:

1. Placeholder: never takes a click or the caret; disappears on the first character and during an IME composition (Japanese, before commit); returns after send and after deleting everything.
2. Growth: typing and Shift+Enter grow the composer line by line without a jump, stop at 300 px and scroll; the caret stays visible; shrinking after send is immediate.
3. Send button: does not move or resize between idle, ready and pending; stays focused when activated from the keyboard during a pending send; clicking it leaves the caret in the editor.
4. Autocomplete: opens above the `@` (below near the top of the window), aligned to the `@` in both directions and on a right-to-left line; follows when the composer grows or the window resizes; arrows, Enter, Tab, Escape, click and hover work while focus stays in the editor (check `document.activeElement`); a screen reader (VoiceOver, NVDA) announces the active row; Enter during a Japanese composition with the list open commits the composition and does not accept a row; the list hides on window blur and returns.
5. Delayed mention source: the list appears when rows arrive, without a flash or wrong position in the first frame.
6. Banners: reply and edit show and dismiss from the button and with Escape; focus returns to the editor; long names and right-to-left previews truncate at the inline end.
7. Errors: "Reject: storage full" keeps the text and shows the line; typing clears it; "Uncertain" shows the unknown-outcome text; "Hold" lets you type during a pending send and keeps the new text after acceptance.
8. Focus: "Focus composer" and type anywhere do not scroll the page (WebKit has been unreliable with `preventScroll`) and put the caret where it was; Escape in an empty composer moves focus to the message list; Option and AltGr characters typed outside the composer land in it.
9. Reduced motion and forced colors: the pending arc stands still; the send button and the editor stay visible in forced colors.

## Needs from the composer package

- No caret or range rectangle API: `dom.ts` builds one from the exported `offsetToDomPoint`. A `rangeRect(root, range)` in the binding would remove that.
- Nothing exposes "composition in progress"; the model listens for `compositionstart`/`compositionend` on the surface itself to hide the placeholder.
- While a trigger is active but has no rows, Escape still dismisses the trigger (the controller marks it dismissed whenever `onAutocompleteKey` returns false), so a first Escape with an empty list does not clear a reply. Harmless; noted.
