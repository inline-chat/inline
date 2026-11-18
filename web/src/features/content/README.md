# Message content views

Everything a message holds beyond its text: photos, videos, GIFs, stickers, documents, voice notes, rich blocks and agent cards, link previews and external tasks, bot buttons, service rows, the forward line, "Sent via" and the reply thread summary. The views render the framework-free models from `@inline/chat-ui` (`media/`, `blocks/`, `attachments/`, `service/`) and compute nothing those models already compute. Lifecycle (decode-then-reveal, GIF playback, voice playback, forms, timers) lives in framework-free controllers here, unit-tested without a DOM.

Lab: `web/lab-content.html` (`src/lab/content/`). `?appearance=dark&theme=pink&dir=rtl` sets the starting state.

## Plugging into a message row

```tsx
import { contentRenderer, createContentEnv } from "~/features/content"

const env = createContentEnv({ handlers, names, me, canUse })        // once per list (or app)
const context: MessageRowContext = { times, isDM, handlers, renderContent: contentRenderer(env) }
```

`contentRenderer(env)` returns null for a message with nothing to draw (`messageHasContent`), so text-only rows keep their layout. Keep `env` and the renderer stable: a new `env` re-renders every row's content. Render service messages (`row.service`) with `ServiceRow` instead of a message row; it returns null for a transcript turn by its own speaker, which is an ordinary message.

### Placement (read before wiring)

The row has one slot, above the text. `MessageContent` draws its sections in a fixed order (`forward`, `media`, `blocks`, `attachments`, `via`, `buttons`, `replies`); pass `sections` to draw a subset once the row has more slots. Until the row changes (see the report's "Needs from others"):

- **Rich block messages draw their text twice**: the blocks are a projection of `row.text`, and the row also renders `row.text`. The lab works around it by handing the row a copy without `text` and `entities` and giving `MessageContent` the full row. The row needs a way to let the content replace its text.
- Link previews, "Sent via", bot buttons and the reply summary belong below the text (buttons and the summary below the bubble on the Mac); today they sit above it.
- Stickers and PNG photos without a caption are `noBubble` in the model; the row still draws its bubble.

## Components

| Component | Props | Notes |
| --- | --- | --- |
| `MessageContent` (memo) | `message: MessageRow`, `env: ContentEnv`, `sections?: readonly ContentSection[]` | One per row. Creates a `RowContent` (model memo, disclosure state, buttons in flight) with `useModel`, keyed by env, row ID and tone (`message.out`). |
| `contentRenderer(env, sections?)` | | A `renderContent` for `MessageRowContext`. |
| `ServiceRow` (memo) | `message`, `env`, `itemKey?` | A whole timeline row (centered pill; transcripts start-aligned, full width). Link segments call `onServiceLink`. |
| `ForwardLine`, `ViaLine`, `RepliesSummary` (memo) | `model`, `ctx: RowContent` | Exported for a row that places them itself. |
| `VisualMedia`, `DocumentRow`, `VoiceRow`, `BlockImage`, `Album`, `PhotoBox` | model plus `ctx` | Media pieces. `PhotoBox` is a non-interactive photo of known size for use inside links and cards. |
| `RichBlocks`, `BlockView` (memo) | `blocks` / `block`, `ctx` | One component per block kind; memoized by node identity. |
| `FormView`, `ButtonRows`, `ActionButton`, `CardButtons`, `UrlPreviewCard`, `ExternalTaskCard`, `Attachments` | model plus `ctx` | |

### `ContentEnv` (`createContentEnv(input)` fills defaults)

| Field | Default | Notes |
| --- | --- | --- |
| `sources: MediaSources` | `cdnMediaSources()` | `photo(photo, box)`, `video(video)`, `voice(voice)` return a `MediaSource`: a `state` signal (`pending`, `ready` with a URL, `failed`) and `retry()`. Called while rendering: cheap, and the same source for the same input. The default uses the rows' signed `cdnUrl` after the link allowlist and never refreshes; the media scheduler replaces it. |
| `previews: PreviewUrls` | new | Object URLs for blurred previews, ref-counted by bytes identity, revoked after the last user (a same-task remount keeps the URL). Call `dispose()` on sign-out. |
| `loaded: LoadedMedia` | new (512) | URLs already revealed this session: a row that comes back shows its image without the fade. |
| `playback: PlaybackGroup` | new | One voice note plays at a time. |
| `gif: GifPlaybackController` | new | GIFs play muted and looped while visible, the page is visible and motion is allowed. |
| `handlers: ContentHandlers` | `{}` | See below. A missing handler disables its control. |
| `names: ContentNames` | `{}` | `user(id)` → `{ name, seed?, photoUrl? }` (task headlines, reply avatars, "Sent via" sender), `forwardTitle(forward)`, `botName(id)`. |
| `me`, `canUse(grant)` | none | The viewer, for the forward target; the grant check for buttons and forms (without it everything is enabled and the server decides). |
| `layout` | `{}` | `availableWidth` (default 420), `style` (`bubble` / `minimal`), `locale`. |
| `text`, `links`, `now` | none | Passed to the block tree (phone links, app origins; `now()` in seconds expires task suggestions). |
| `debug` | none | `onBlockRender(rowId, key)`, `onMediaStatus(rowId, key, status)`. Called during render; labs only. |

### The media layer (`sources`)

`createContentEnv` defaults to `cdnMediaSources` (the row's signed `cdnUrl`). The app passes the real layer, `createCoreMediaSources` from `features/media` (see its README), which implements the same interface over the core's `media` query. The interface grew additively on 17 November for it:

- `photo(photo, box, owner?, thumbnail?)`, `video(video, owner?)`, `voice(voice, owner?)`: `owner` (`MediaOwner`: chat, message ID, the local attachment ID of a send, client key, row state) names the message whose own media this is; `MessageContent` builds it with `RowContent.mediaOwner(row)` (one object per distinct value) and passes it to `VisualMedia`, `DocumentRow` and `VoiceRow` as the optional `owner` prop. Block images and link previews are asked for without one.
- `MediaSource.part?`: every media box (photo, video, GIF, sticker, block image, `PhotoBox`, document, voice) hands its element to it with `useElement`, so a layer that loads on demand holds the bytes while the box is on the page and can watch its visibility. A GIF's box holds both its thumbnail and its video.
- `MediaSourceState.pending.progress?`: download progress, when known.
- `upload?(owner)`: an `UploadSource` (`state`: phase and fraction; `part`; `cancel()`; `resend()`) for a send from this device. `UploadOverlay` draws it inside the box while the row is `sending` (a progress ring with "Cancel Upload") or `failed` ("Resend"); a document without a thumbnail shows it in its 36 px icon slot. Nothing changes size: the overlay is an absolute layer or takes the slot's fixed size. `upload.ts` has the pure rules (`showsUpload`, `ringFraction`).

`ContentHandlers` extends `MessageTextHandlers` (`onMention`, `onThreadRef`, `onBotCommand`, `onAppLink`, `onExternalLink`) with: `onOpenMedia({ rowId, key, kind, photo, video, index? })`, `onDownload({ rowId, media })`, `onSubmitForm({ rowId, formId, values })` (resolve on success, reject to let the user retry), `onAction({ rowId, button })` (callback, copy, compose, open link, confirm; return a promise to show a spinner on a callback), `onCompose(text)`, `onOpenPeer(peer)`, `onForward(target)`, `onOpenReplies({ rowId, chatId })`, `onServiceLink(link)`, `onCopyText(text)`.

## Invariants

- **Final size in the first frame.** Visual media, block images and link-preview media boxes take their width from the model and their height from `aspect-ratio`, so a narrow column scales them without a later reflow. Albums, documents, voice notes, task cards and widget placeholders have fixed sizes. Loading, failing, retrying and revealing happen inside the box (absolute layers).
- **Preview, then decoded image.** The blurred preview is the box's background from the row's bytes (an object URL set through the CSSOM, never a `data:` string or inline `<style>`). The image sits at opacity 0 and is shown after `img.decode()` (GIFs after `loadeddata`); reduced motion makes the fade 0 ms. A failed load shows a quiet retry button inside the box.
- **Native elements.** `<img>` (`decoding="async"`), `<video>` for GIFs only (muted, looped, `playsInline`, `preload="metadata"`, poster first; not mounted under reduced motion), `<audio preload="none">` behind our own control. Nothing here fetches; only elements' own `src` loads. No iframes: a widget is a placeholder of its reserved height.
- **Streaming renders one block.** `ContentMemo` passes every model through `reuseTree` and the block tree through `updateBlockTree`, so unchanged parts keep identity across fresh row copies; `BlockView` is memoized by node and the stable `RowContent`.
- **Links** come only from the allowlist (`safeLink` output in the models): previews, task cards and `openUrl` buttons are anchors with `target="_blank" rel="noopener noreferrer"` and call `onExternalLink` first. A refused URL leaves text, or a disabled button with "This action isn’t available".
- **Secrets.** A secret form field is a password input that never starts filled; answers live in the `FormController` for the life of the view only and secret ones are emptied after a successful submit.
- **One submit.** `FormController` wraps `chat-ui`'s `beginSubmit` / `submitSucceeded` / `submitFailed`.
- No effects, Suspense or HTML sinks in views; StyleX with the kit's tokens (`chatText` for message text), logical properties, `dir` from the model or `auto`.

## Controllers (framework-free, unit-tested)

`RevealController` (`url`, `kind`, `loaded`, `onStatus`; `status`, `instant`, `part`, `retry`), `PreviewUrls`, `LoadedMedia`, `GifPlaybackController` (injectable visibility, page and motion conditions), `VoicePlayerController` + `PlaybackGroup`, `FormController` + `formLockReason`, `ActionRunner` + `presentButton`, `ElapsedTimer`, `TransientFlag`, `ContentMemo`, `DisclosureState`, `messageHasContent`, `cdnMediaSources`, `splitFileName`.

Tests: `bunx vitest run src/features/content` from `web/` (30 tests, Node, fakes for elements and a manual clock; `media-owner.test.ts` covers `RowContent.mediaOwner` and the upload rules).

## Lab

`lab-content.html`: every media kind (fast, slow, failing once, never arriving, missing), every block kind and status, every agent card state, forms (type "fail" as the release name to see a refused submit), attachments, button behaviors, headers and service rows, in real `MessageRowSignalView` rows; a streaming agent message with per-block render counts; and a height check. All bytes are made in the page: pictures on a canvas, real stripped thumbnails from a small encoder against `strippedJpeg`'s header, WAV voice notes, GIFs recorded to WebM with `MediaRecorder`. No StrictMode, so render counts are real.

Automation: `globalThis.__contentLabControl` has `setAppearance("light" | "dark" | "system")`, `setTheme(id)`, `setDirection("ltr" | "rtl")`, `setCanApprove(bool)`, `setSlowDelay(ms)`, `reloadMedia()`, `checkHeights()` (resolves to the results), `startStream(rate)`, `stopStream()`, `resetStream()`, `streamCounts()`. `globalThis.__contentLab` exposes `log`, `heights`, `streaming`, `blockRenders` and `rows`.

## Check in a real browser

Not checkable in Node; use the lab from a production build (`bunx vite build -c tooling/vite.labs.config.ts`):

- Height check: every row "yes" (before equals after) in light, dark, right to left and at a narrow width.
- Previews paint blurred immediately; images fade in after decode, without a jump; under reduced motion they appear without a fade and GIFs show a still frame.
- The failing photo and album item show a retry button inside the box; retry loads them.
- Streaming at 30 and 60 updates a second: only the growing paragraph's count rises; the heading and disclosure stay at 1.
- Code blocks, tables, diffs, albums and long commands scroll sideways inside themselves, never the page.
- Disclosures open and close with the keyboard (Enter and Space on the summary); toggles survive streaming updates; the running one shows a live timer and a shimmer (none under reduced motion).
- Forms: keyboard complete; one submit; the secret field is empty after a successful submit; a refused submit returns to editing with the message.
- Buttons: the callback shows a spinner for 1.5 s; the unavailable and gated buttons are disabled with their reason visible; "Viewer can approve" enables the gated ones.
- Voice: play, pause, seek by click and with arrow keys (mirrored in right to left); starting one note pauses the other.
- Production content policy: no violations in the console (blob images, media and the preview backgrounds are allowed by `img-src` and `media-src`).
- Forced colors and `prefers-contrast: more`: cards, chips and buttons keep visible borders.
