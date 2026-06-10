# Photo Thumbnail Generation Plan

Date: 2026-06-07

## Goal

Show collapsed/non-expanded chat photos from smaller photo representations instead of downloading and rendering the largest image in a small bubble. Full-size actions such as tap-to-open, save, share, and Quick Look should still use the largest available representation.

## Findings

- Inline already has the right protocol shape. `Photo` contains repeated `PhotoSize`; `PhotoSize` supports normal size types `b`, `c`, `d`, `f` plus embedded stripped size `s` with bytes.
- Server storage already has `photos` and `photo_sizes`. `photo_sizes.size` allows `b`, `c`, `d`, `e`, `f`, `y`, `x`, `w`, `v`, so `c`/`d` thumbnails do not require a DB enum migration.
- `uploadPhoto` currently uploads exactly one real file size: type `f`, using the normalized/original file dimensions. It also generates encrypted stripped thumbnail bytes on the `photos` row.
- `encodePhoto` already emits the stripped size plus every file-backed `photo_sizes` row as signed CDN/proxy URLs, so adding rows is automatically protocol-visible.
- Apple clients persist all protocol sizes and preserve local paths when protocol data refreshes.
- `PhotoInfo.bestPhotoSize()` intentionally means largest non-stripped size. It is used by `FileCache.download`, iOS `NewPhotoView`, macOS `NewPhotoView`, image prefetching, and tap/open paths.
- The shared `PlatformPhotoView` already has local-file downsampling and tiny thumbnail background support, but the active iOS/macOS message photo views instantiate their own `NewPhotoView` implementations.
- iOS `NewPhotoView` downloads `bestPhotoSize()` first, then asks Nuke to resize to width 300. That reduces decode cost after download, but network/disk/cache are still tied to the largest image.
- macOS `NewPhotoView` downloads `bestPhotoSize()` and then uses `ImageCacheManager`, which currently loads `NSImage(contentsOf:)` for the local file. That path is especially likely to keep large image representations around.
- Telegram's TL schema represents a photo as `sizes: Vector<PhotoSize>` and supports normal sizes, cached sizes, stripped sizes, progressive sizes, and path sizes. Its clients explicitly pick thumbnail/display representations, using helpers like smallest/largest representation and representation-for-display-size rather than treating "best" as display.

## Recommendation

Use the existing `Photo.sizes` protocol and add server-generated, CDN-backed display sizes. Then add explicit client selection helpers for display versus full-size use. Do not change `bestPhotoSize()` semantics globally, because upload, save, share, and full viewer code already relies on it meaning largest.

This is additive and backward-compatible:

- Old clients ignore nothing; they already store repeated sizes.
- New clients can use smaller sizes when present and fall back to `f` for older photos.
- No protocol field or DB migration is required for the first rollout.

## Size Policy

Recommended generated sizes:

- `s`: existing stripped thumbnail, max 40 px, embedded bytes, placeholder only.
- `c`: max edge 320 px, for reply previews, URL/card previews, grids, and compact thumbnails.
- `d`: max edge 800 px, for normal chat bubble display.
- `f`: existing normalized/original uploaded file, for full viewer/save/share.

Rules:

- Never upscale.
- Skip a generated size if it would duplicate a larger existing size within a small tolerance.
- Preserve alpha for PNG/WebP-normalized-to-PNG derivatives. Use JPEG derivatives for JPEG photos.
- Treat GIF carefully. Current protocol has no GIF photo format; do not expand GIF semantics in this thumbnail pass unless we decide to fix GIF photo handling as a separate task.

## Server Plan

1. Add a small photo variant helper under `server/src/modules/files/`, for example `photoVariants.ts`.
   - Input: normalized `File`, normalized metadata, desired variants.
   - Output: generated `File` plus metadata for `c` and `d`.
   - Implementation: `sharp(await file.arrayBuffer()).rotate().resize({ width: max, height: max, fit: "inside", withoutEnlargement: true })`.

2. Update `uploadPhoto`.
   - Keep the existing full upload as type `f`.
   - Keep the existing stripped thumbnail generation.
   - Generate `c` and `d` from the normalized file.
   - Upload each generated variant through `uploadFile`, not `uploadPhoto`, to avoid recursion and to reuse encrypted path/file row behavior.
   - Insert one `photo_sizes` row for each successful variant.
   - If derivative generation/upload fails, log a warning and continue with the full-size photo. Thumbnail generation is performance optimization, not a reason to fail message send.

3. Keep the source of truth simple.
   - `photos` is the logical media object.
   - `photo_sizes` rows are all file-backed representations.
   - `photos.stripped` remains only the tiny placeholder.

4. Make encoding deterministic.
   - Sort file-backed sizes by type priority (`b`, `c`, `d`, `f`) before encoding, with `s` still first.
   - Do not rely on DB relation ordering.

5. Backfill later.
   - First ship new upload behavior.
   - Add an idempotent backfill script/job for existing photos that are missing `c`/`d`.
   - Query photos with `f` but missing target sizes, fetch the full file from bucket, generate derivatives, upload derivative file rows, and insert missing `photo_sizes`.
   - Batch and rate-limit; start with recent/high-traffic photos.

## Client Plan

1. Add explicit selection helpers on `PhotoInfo`.
   - Keep `bestPhotoSize()` as largest/full.
   - Add a display helper, for example `bestDisplayPhotoSize(maxPixel:)`.
   - The display helper should ignore `s`, prefer the smallest available size whose max edge is close to or above the target, and fall back to the largest normal size.
   - For chat bubbles, cap target around 800 px so 3x devices do not frequently pick `f` for a 280 pt bubble.

2. Update `FileCache.download`.
   - Accept a specific `PhotoSize` or a selection mode such as `.display(maxPixel:)` / `.full`.
   - Key active downloads by photo id plus size type, not only photo id, so a thumbnail download does not block a later full-size download.
   - Save local files as `IMG{type}{photoId}.{ext}` and update the matching `PhotoSize.localPath`.

3. Update active message photo views.
   - iOS `NewPhotoView`: use display size for bubble image URL/download, but use full size for tap/open.
   - macOS `NewPhotoView`: same selection split. This alone prevents most full-size local loads because the local URL will point at `d` when available.
   - Use full-size dimensions for layout/aspect ratio if available; do not base bubble shape on the stripped size.
   - Update reload checks to compare the selected display size local path, not only `bestPhotoSize().localPath`.

4. Improve macOS decode path.
   - Short term: loading `d` instead of `f` substantially reduces the cost.
   - Follow-up: add target-size downsampling to `ImageCacheManager` or migrate message photos to `PlatformPhotoView` once tap/drag/Quick Look behavior is preserved.

5. Update prefetch/autodownload.
   - `ImagePrefetcher` should prefetch display size, not full size.
   - Full size should download on explicit user intent: open, save, share, Quick Look, or maybe if auto-download policy says full media is allowed.

6. Sender-side optimistic display.
   - New local photos currently have only local `f`.
   - Either generate local `c`/`d` rows in `FileCache.savePhoto`, or make message views downsample from local `f` until server sizes arrive.
   - Prefer generating local display rows eventually for macOS, because it avoids `NSImage(contentsOf:)` on a large file even before server sync.

## Alternatives Considered

- Client-only downsampling: lower server risk, but still downloads and caches the original file and does not fully address macOS `NSImage(contentsOf:)`.
- Dynamic resize endpoint such as `/file?id=...&w=...`: avoids stored variants, but adds request-time CPU, cache-key complexity, and new signing/proxy semantics.
- Client-generated thumbnails only: helps the sender's optimistic message, but recipients and other devices still need canonical server-side sizes.

## Validation

Server tests:

- Upload a large JPEG and assert `photo_sizes` has `c`, `d`, and `f` with expected dimensions and file rows.
- Upload a small image and assert duplicate larger variants are skipped.
- Assert `encodePhoto` emits stripped plus file-backed sizes in deterministic order.
- Assert derivative failure does not fail the upload when full size succeeds.

Apple tests:

- `PhotoInfo.bestDisplayPhotoSize(maxPixel:)` picks `d` for chat display when `c/d/f` exist, falls back to `f` for old photos, and never picks `s` as final display.
- `FileCache.download` updates the requested size's local path and can track display/full downloads separately.
- `NewPhotoView` display path asks for display size while tap/open asks for full size.

Manual/perf checks:

- Build/run iOS and macOS chat views with 10-20 high-resolution photos.
- Compare scroll smoothness, memory, downloaded bytes, and time-to-first-image before/after.
- Verify tap-to-open still shows full image and does not use the 800 px display thumbnail.
- Verify video/document thumbnails still render because they use `uploadPhoto` for thumbnail photo objects.

## Rollout

1. Ship server generation for new uploads.
2. Ship client display/full selection and display-size downloads.
3. Add backfill for existing photos.
4. Consider unifying message photo rendering on `PlatformPhotoView` after the functional rollout is stable.

## Risks

- Storage and upload cost increase by roughly two extra photo derivative files per uploaded photo.
- Server CPU increases due to sharp resizing. This should be bounded by upload rate and can be optimized with derivative skipping.
- Existing photos need backfill to benefit.
- macOS may still decode too much if a fallback old photo only has `f`; the client should downsample old photos as a fallback.
- GIF photo behavior is already underspecified by the current `Photo.Format`; avoid mixing that fix into this rollout unless explicitly scoped.

