# Media (UI side)

The content views' `MediaSources` over the core's `media` query, visibility hints for a timeline, and the rules for object URLs. Framework-free; the views that use it are in `features/content` (media boxes, the upload overlay) and `features/composer` (the attachment strip). The core side is `web/packages/client/src/host/README.md` ("Media", "Attachments and media sends"); the contract is `MediaResource` in `@inline/core-protocol`.

Lab: `web/lab-attachments.html` (`src/lab/attachments/`).

## What the chat pane does

```ts
import { createCoreMediaSources } from "~/features/media"
import { createContentEnv } from "~/features/content"
import { createAttachmentDrafts, withAttachments, DropTarget, ComposerView, DropOverlay } from "~/features/composer"

// 1. Once per signed-in session (next to the store client). Dispose on sign-out.
const sources = createCoreMediaSources({
  client,                                   // the session's StoreClient
  // optional: onCancelUpload(owner) / onResend(owner) to route through the chat model
  //   (default: deleteMessages by client key / retrySend, posted directly)
})
const attachmentDrafts = createAttachmentDrafts({ client, userId })   // also once per session; dispose on sign-out

// 2. The content environment gets the sources (instead of the CDN stand-in).
const env = chunk.createContentEnv({ sources, handlers, names, me: userId })   // chat-content.ts

// 3. Per pane: a visibility controller on the timeline's scroll container.
const visibility = useModel(() => sources.createVisibility(), [sources])
<div ref={useElement(visibility)} /* the element that scrolls the timeline */>

// 4. Per chat: the composer model with the chat's attachments, and the strip.
const attachments = attachmentDrafts.forChat(chatId)
const model = createComposerModel(withAttachments({ send, saveDraft, safeUrl, ... }, attachments))
<ComposerView model={model} attachments={attachments} />

// 5. Per pane: the drop target on the pane's root (position: relative), the overlay inside it.
const drop = useModel(() => new DropTarget({ onFiles: (files) => attachmentsOfCurrentChat().add(files) }), [])
// Enabled while editing a message too, as on the Mac: the files wait in the strip for the next send.
<div ref={useElement(drop)} style="position: relative"> ... <DropOverlay target={drop} /> </div>

// Sign-out: sources.dispose(); attachmentDrafts.dispose()
```

In `chat-composer.ts` that means wrapping the options it already builds: `createComposerModel(withAttachments({ ...today's options }, attachments))`, and in `ChatPane.tsx` passing `attachments` to `ComposerView`. `withAttachments` sets `onFiles` (paste and drop on the editor), `hasAttachments` (Send is enabled with attachments and no text), `send` (attachments go as `sendMedia`, text and edits to the given `send`) and `errorText` (words for the attachment reasons). For the optimistic rows to appear at the end of the chat window in the same frame (as text sends do), pass `placeRows: (row) => ({ row, appendTo: [windowSub] })` to `createAttachmentDrafts`; without it they appear with the core's patch, a frame later.

`sources.open(source)` asks again with priority `opened` (no auto-download limit); a media viewer calls it for what the user opened, and holds what it shows with `sources.hold(source)` or the source's `part`.

## Sources (`sources.ts`)

`createCoreMediaSources(options)` returns `CoreMediaSources`, which implements the content views' `MediaSources` plus `upload`, `source(ref)`, `detail(source)`, `hold`, `open`, `createVisibility`, `stats` and `dispose`.

- **Which bytes** (`refs.ts`). A row with `MessageRow.upload` (a send from this device not on the server yet) shows its attachment (`{ kind: "attachment" }`); a video's or document's thumbnail of such a row stays pending (the attachment's bytes are the file). A message's photo asks for the variant that covers the box at the device pixel ratio (`chat-ui` `photoVariantFor`); video (GIFs) and voice ask for the whole file. Media without an owner (block images, link previews) and server media without a `fileUniqueId` (the core cannot serve it) fall back to `cdnMediaSources`.
- **Sharing.** Entries are keyed by asset and variant (`file:<fileUniqueId>:<variant>`, `attachment:<id>`): ten rows showing the same image share one entry, one subscription and one object URL. `photo(...)` returns the same `MediaSource` object for the same key.
- **Holding.** A view hands its media box to `source.part` (`useElement`). The entry is held while any box is attached.
- **Asking.** A held box inside a timeline that has a visibility controller subscribes when the box first becomes visible and stays subscribed while held. A box outside every timeline subscribes at once (after the commit's microtask, when the decision is made). Before an answer arrives the source is `pending`.
- **State.** `MediaSourceState`: `pending` (absent, queued, downloading with `progress`), `ready` with a URL, `failed`. `detail(source)` has the core's phase, bytes and failure.
- **A send completing** (the row loses `upload` and names the server's photo): the box keeps showing the local image until the server copy is ready, so it never returns to its placeholder and fades in again. `photo(...)` remembers which attachment a row (`chatId:clientKey`) showed while sending; for that row's server photo, while the server entry is not ready, it returns a stand-in source whose state is the server's when ready, else the attachment's ready URL, else (while mounted) the last local URL it showed (the decoded pixels stay on screen even after the core released the attachment and its URL was revoked). The stand-in holds both entries while mounted, so the server copy is asked for (visibility and hints as usual) while the local one shows; the URL changes once, from local to server, never through pending. A re-render while mounted gets the same source; after it lets go the row gets the server's own source. Only photos (not a video's poster).
- **Retry and open** subscribe again with priority `opened` and keep showing the current answer until the new subscription says something other than `absent`; then the old subscription goes.
- **Uploads.** `upload(owner)` returns the `UploadSource` of a send from this device (`owner.attachmentId`): the attachment's upload progress (`phase`, `fraction`), `cancel` ("Cancel Upload": `deleteMessages` with the client key, which cancels the upload) and `resend` (`retrySend`). It shares the attachment's entry with the row's preview.
- `stats()`: entries, held, subscribed, live URLs, idle. `dispose()`: unsubscribes everything and revokes every URL; parts become no-ops.

### Object URL lifetime (the rules)

1. A URL is made only when the entry's resource is `ready` with a `Blob`. Never for `absent`, `queued`, `downloading` or `failed`.
2. One URL per blob: a later `ready` with the same blob keeps it; a different blob (or a retry after the element failed to decode it) replaces it, revoking the old one.
3. Leaving `ready` (a later `failed` or `absent`) revokes it.
4. After the last box lets go, the entry keeps its subscription and URL for **`MEDIA_GRACE_MS` = 10 s**, then unsubscribes and revokes. Why 10 s: the timeline trims rows far from the viewport and re-adds them when the reader scrolls back, and a chat switched away from and back to remounts its rows; both happen within seconds, and within the grace the row shows its image in its first frame (same URL, already in the content views' `LoadedMedia`, so no fade). Longer would pin more files in the core's cache for nothing; the core keeps a file pinned exactly while a subscription holds it, so the blob is readable for as long as its URL exists. At most `MEDIA_IDLE_LIMIT` (256) released entries wait; beyond that the oldest is dropped at once. Entries a render created but no box ever held go after the same period.
5. `dispose()` revokes everything.
6. **Types.** A URL carries the blob's type only for allowlisted raster image, video and audio types; anything else (SVG, HTML, unknown) is retyped `application/octet-stream` (`safeBlob`, a slice, no copy). A `blob:` URL has the app's origin: opened in a tab, an SVG or HTML blob would run as the app. `<img>`, `<video>` and `<audio>` still sniff and play opaque bytes. The composer's thumbnails are made only for raster images (`isPreviewableImage`).
7. Bytes reach the DOM only through `<img>`, `<video>` and `<audio>` `src` (and the blurred preview's CSSOM background, which `features/content` owns). No HTML sinks.

Tests prove 1 to 6 with a fake URL API that records every URL made and revoked and flags strays (`test-support.ts` `fakeBlobUrls`).

## Visibility (`visibility.ts`)

`sources.createVisibility()` returns a `MediaVisibility` for one timeline. `attach(container)` creates two `IntersectionObserver`s rooted at the scroll container, shared by every box: one with no margin (visible) and one with a margin of one container height above and below (`NEARBY_MARGIN`, `"100% 0px"`: nearby). One observer cannot do both: a box moving from "near" to "visible" stays inside the expanded root, so an observer with the margin reports nothing for that move.

Changes from either observer and from boxes leaving are coalesced to one update per frame (`requestAnimationFrame`), across every timeline of the session:

- **Visible**: held entries shown by a visible box subscribe (priority `visible`).
- **Nearby**: boxes within the margin whose entry has not subscribed go to the core as one `mediaHints` intent (message references only; attachments are local). The intent replaces the context's nearby set, so the set is the union of every timeline's; it is sent only when it changed (an empty set once, to clear).
- **Opened** is not a hint in the contract (`mediaHints` has only `nearby`): it is the subscription's priority, set by `retry()` and `open()`.

## Files

| File | What |
| --- | --- |
| `sources.ts` | `createCoreMediaSources`: entries, holding, subscriptions, URLs, grace period, uploads, hints. |
| `visibility.ts` | `MediaVisibility`: two shared observers per timeline. |
| `refs.ts` | Which `MediaRef` and key a view's media maps to. Pure. |
| `object-urls.ts` | `BlobUrlApi`, `browserBlobUrls`, `countingBlobUrls`, `safeMediaType`, `safeBlob`, `isPreviewableImage`. |
| `test-support.ts` | Scripted core over a real store client, fake URLs, fake observers, manual defer and frame. Tests and the lab only. |

Tests: `bunx vitest run src/features/media` from `web/` (Node, no DOM): a send completing (the URL seen by a mounted image goes local, local, then server and never pending, through the attachment going absent and the server copy downloading; the server copy is asked for meanwhile; the same source on re-render; every URL revoked and nothing subscribed after the rows go; a row first seen after the server copy is ready, or from another device, gets the server's source; rows released before the server answers leave nothing), sharing across ten rows, the grace period (a row returning keeps its URL; a remount in one task keeps everything), the idle limit, entries never held, no URL for absent, queued, downloading or failed, URL replacement by blob identity, safe types, dispose, retry keeping the old answer, a fresh URL after a decode failure, open, fallbacks, attachments and thumbnails of local sends, upload progress, cancel and resend (and the app's own handlers), visibility gating, hints batched per frame and not repeated, release clearing hints, boxes outside a timeline, attachment refs never hinted and shared refs de-duplicated.

## Not verified here

Browser behavior needs the lab from a production build (`bunx vite build -c tooling/vite.labs.config.ts`): real `IntersectionObserver` margins on a scroll container, `blob:` images under the production content policy (`img-src blob:` is allowed), decode-then-reveal with blob URLs, and the live URL count returning to zero after "Remove all" and "Skip grace".
