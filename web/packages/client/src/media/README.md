# Media core

The part of the account core that moves and keeps bytes: durable resumable uploads, ranged downloads, a cache with a budget, and a scheduler that decides what to fetch first. It runs in the core's worker (no DOM, no `window`, no view framework), next to sync and independent of it. Nothing here is wired into the host yet; `MediaCore` takes every dependency so the host can construct it.

The Mac and iOS implementation is the behavioral specification: `apple/InlineKit/Sources/InlineKit/Files/NativeUpload.swift`, `NativeDownload.swift`, `CDNRangeSource.swift`, `MediaCacheSweep.swift`, `ImageCompression.swift`, `UserSettings/AutoDownloadSettings.swift`. Wire mapping comes from `packages/protocol` (`rpcUploadTransport`, `rpcDownloadTransport`, `transfers.ts`), unchanged.

## Layout

| File | What it is |
| --- | --- |
| `index.ts` | `MediaCore`: the facade, and every public export. |
| `types.ts` | `MediaClock`, `MediaRpcCall`, `MediaFetch`, `MediaError`, deadline and sleep helpers. |
| `constants.ts` | Every number, with its Swift or server source. |
| `bytes.ts` | Hex, base64, incremental SHA-256, JSON for records with bytes and bigints. |
| `store/byte-store.ts` | `ByteStore` interface, `MemoryByteStore` (writers buffer until checkpoint, so a crash can be simulated). |
| `store/opfs-byte-store.ts` | `OpfsByteStore` (unverified, see below). |
| `upload/job.ts` | `UploadJobRecord`, `MediaJobStore`, `MemoryMediaJobStore`, `ByteStoreJobStore` (one JSON file per job). |
| `upload/part-window.ts` | `PartWindow`: the adaptive part window shared by every upload of the account. |
| `upload/upload-engine.ts` | `UploadEngine`: staging, hashing, create, parts, finish, resume, cancel, expiry, retries, events. |
| `download/range-source.ts` | `RangeSource`; `HttpRangeSource` (signed URL, `Range`/`If-Range`, link refresh); `RpcRangeSource` (`GET_FILE_PART`, per-part SHA-256). |
| `download/download.ts` | `downloadToCache`: ordered ranges into a cache writer, resume, abort, verification. |
| `cache/media-cache.ts` | `MediaCache`: entries by file and variant, budget, LRU, pins, sweep, erase. |
| `scheduler.ts` | `MediaScheduler`: priorities, concurrency, dedupe, cancellation, auto-download limits, offline pause. |
| `settings.ts` | `MediaSettings`, `shouldAutoDownload`. |
| `image/prepare-image.ts` | `ImagePreparer` interface, the preparation logic over an `ImageCodec`, and the browser codec (unverified). |
| `testing/transfer-server.ts` | `TransferServer`: the scripted server for tests (upload state machine, `GET_FILE_PART`, signed HTTP ranges, faults). |

## Public API

```ts
const media = await MediaCore.open({ accountKey, rpc, fetch, store: new OpfsByteStore(), settings, imagePreparer: browserImagePreparer })
media.subscribe((event) => ...)            // plain data: upload-state, upload-progress, upload-complete, download-*
await media.startUpload({ id, source, fileName, mimeType, kind }, { pin: [previewKey] })
await media.uploadCompletion(id)           // resolves with the server's UploadComplete, now or later
await media.releaseUpload(id)              // the consumer has it: forget the job
media.cancelUpload(id); media.retryUpload(id)
media.setVisible(assets); media.setNearby(assets); media.setPrefetch(assets)
const handle = media.open(asset)           // explicit: first, no auto limit, pinned for the viewer; handle.release()
await media.read(key)                      // Blob from the cache
media.setOnline(online)
await media.sweep(() => referencedFileIds) // daily cache sweep + orphaned upload sources
await media.updateSettings(settings)
await media.erase()                        // sign-out: this account's jobs, sources and cache
```

The pieces (`UploadEngine`, `MediaCache`, `MediaScheduler`, `downloadToCache`, the range sources, the stores) are exported for tests and for a host that wants to compose them differently.

## Design

**Uploads.** A job is durable before anything is sent. Order: the source blob is written (`uploads/<id>.body`), then the job row; a blob with no row is an orphan, removed after an hour by `collectOrphans`. The row holds the source path, the retry identity (`clientUploadId`, 16 random bytes, persisted), the server `uploadId` once known, the acknowledged parts (offset = index × 512 KB), the SHA-256, the server expiry, the completion, and the attempt count.

- A run hashes the source if needed, then establishes the upload: with a known `uploadId` it asks `GetUploadState` first and sends nothing before that answer; without one (the create reply was lost) it replays `CreateUpload` under the same identity, which the server deduplicates per session. A state probe that fails also falls back to the create replay.
- A single-part file rides inside create (`inline_data`) when a window slot is free at once; an older server ignores it and the part goes the usual way.
- Parts move through the shared `PartWindow`. A failed part asks the state: accepted means done, a terminal server state starts over under a new identity, otherwise one retry after 200 to 400 ms. Every acknowledged part is persisted.
- Finish follows `DurableUploadCoordinator`: `missing` re-sends those parts, `processing` waits the server's delay (1 to 30 s) on the clock under a 600 s bound, and a lost finish reply is reconciled through the state (up to 3 times).
- **Exactly once:** the completion is persisted before any event, then the source is deleted. A restart finds the job complete and sends nothing; `uploadCompletion` returns the stored result until the consumer calls `releaseUpload`. A lost final acknowledgement resolves through the state or the idempotent finish to the same file.
- Server upload expired or canceled behind our back: the identity is replaced and the job starts again from its kept source. A job older than 7 days fails as `expired` and its source is dropped.
- Transient failures pause the job and retry with backoff (2 s doubling to 30 s) up to 5 attempts, then `failed` (retryable); `retry` restarts the budget. Offline stops jobs without spending attempts.
- Cancel aborts the run, marks the row `canceled` with `cancelPending`, deletes the source, and calls `CancelUpload`; the row goes once the server confirms, and an unconfirmed cancel is retried on the next open or when back online.

**Downloads.** `downloadToCache` fetches 512 KB ranges in order with up to 4 in flight, so memory stays at four ranges. Each range must be exactly the bytes asked for with an unchanged total; the total must match the message's size when given; RPC ranges are checked against their SHA-256, and a whole-file SHA-256 is checked before commit when the caller has one. The partial's total and validator (`ETag`) are saved beside it; a resume sends `If-Range`, and a changed file restarts from zero once. Checkpoints every 2 MB record the resume point; an orderly stop keeps every verified byte. A rejected signed link is refreshed once (`refreshUrl`).

**Cache.** Entries are keyed by file ID and variant (`b`, `c`, `d`, `f`, `s` photo sizes, `file`, or another short name). Least recently used entries go first when over budget; pinned entries (`viewer`, `upload`, `keep`) and entries being written are never evicted. The index is rebuilt from a listing at open; recency across restarts is the write time. The sweep matches `MediaCacheSweep`: once a day, only files unchanged for 7 days, references read after listing, nothing removed if references cannot be read; Keep Media (`keepMediaDays`) removes older entries even if referenced; stale partials go too. `erase` removes the account's whole cache.

**Scheduler.** One task per cache key however many ask. Priority is the highest claim: opened, visible, nearby, prefetch; ties go in arrival order. Up to 4 files at once, at most 1 of them a prefetch. `setVisible`, `setNearby` and `setPrefetch` replace their set; a task with no claims left is canceled (its partial kept). Automatic claims obey the auto-download limits; an explicit `open` ignores them. Transient failures retry twice with backoff; a failed file is skipped by automatic claims until opened. Offline stops running downloads without spending attempts.

**Images.** `prepareImage(blob, "photo" | "original")` returns `{ blob, mimeType, width, height, tinyPreview }` or "send as a document". JPEG and other types go to JPEG within 1600 px at 0.87; PNG stays PNG within 1280 px; when the result is over 80% (JPEG) or 90% (PNG) of the original, the original goes, as in `ImageCompressor`. The encoded type is checked: a canvas that returns another type than asked (WebKit and WebP, for example) never passes for it. The server takes only JPEG and PNG photos, so anything else must be re-encoded or sent as a document. GIF goes as a document.

## Constants and their sources

| Constant | Value | Source |
| --- | --- | --- |
| `PART_SIZE` | 512 KB | `NativeUpload.swift` `partSize`; `transfers.ts` |
| `MAX_UPLOAD_PARTS` | 1000 | `maximumPartCount`; server `INLINE_UPLOAD_MAX_PARTS` |
| `MAX_UPLOAD_BYTES` | photo 40 MB, video and document 500 MB, voice 20 MB | `MediaUploadLimits` |
| `UPLOAD_WINDOW_MIN/MAX/INITIAL` | 2, 8, 4 | `partWindowLimits`, `initialPartWindow` |
| `WINDOW_GROW_BELOW_MS`, `WINDOW_SHRINK_ABOVE_MS` | 1 s, 2 s | `adaptedPartWindow`; a failed attempt also halves |
| `MAX_PART_ATTEMPTS` | 2 | `maximumPartAttempts` |
| `PART_RETRY_MIN/MAX_MS` | 200, 400 | `transferPart` jitter |
| `MAX_FINISH_RECONCILIATIONS` | 3 | `maximumFinishReconciliationAttempts` |
| `MUTATION_TIMEOUT_MS`, `STATE_PROBE_TIMEOUT_MS`, `CANCEL_TIMEOUT_MS` | 60 s, 15 s, 5 s | per-RPC stall bounds in `DurableUploadCoordinator` |
| `PROCESSING_TIMEOUT_MS`, `MAX_PROCESSING_RETRY_SECONDS` | 600 s, 30 s | `processingTimeout`, `maximumUploadProcessingRetrySeconds` |
| `HASH_READ_SIZE` | 1 MB | `hashReadSize` |
| `STALE_UPLOAD_AGE_MS` | 7 days | `staleUploadAge`; server `INLINE_UPLOAD_HARD_TTL_MS` |
| `ORPHAN_BLOB_AGE_MS` | 1 hour | `abandonedCopyAge` |
| `MAX_JOB_ATTEMPTS`, `JOB_RETRY_BASE/MAX_MS` | 5, 2 s, 30 s | web only |
| `DOWNLOAD_RANGES_IN_FLIGHT` | 4 | `NativeDownloadClient` default; Swift window starts at 4 |
| `DOWNLOAD_CHECKPOINT_BYTES` | 2 MB | web only |
| `SWEEP_MINIMUM_AGE_MS`, `SWEEP_INTERVAL_MS`, `SWEEP_LAUNCH_DELAY_MS` | 7 days, 24 h, 60 s | `MediaCacheSweep` |
| `AUTO_DOWNLOAD_DEFAULT_*_MB`, `AUTO_DOWNLOAD_MAX_MB` | media 25, file 10, voice 10; max 2048 (MiB) | `AutoDownloadSettingsManager` |
| `DEFAULT_CACHE_BUDGET_BYTES` | 1 GiB | web only; the Mac has no byte budget |
| `JPEG_*`, `PNG_*` | 1600 px / 0.87 / 0.8; 1280 px / 0.9 | `ImageCompressionOptions.defaultPhoto`, `.defaultPNG` |
| `TINY_PREVIEW_*` | 40 px, 0.5 | web only |

## Storage layout

All under one prefix per account, so erase is one recursive delete and accounts never see each other's files:

```
accounts/<accountKey>/media/
  uploads/<jobId>.body            staged source of an unsent attachment (never evictable)
  jobs/<jobId>.json               upload job row (default job store)
  cache/<fileUniqueId>~<variant>  cached file
  cache/<id>~<variant>.partial    resumable download body
  cache/<id>~<variant>.partial.json   { totalSize, validator }
  sweep-stamp                     last sweep time
```

Byte stores: OPFS in the browser, memory in tests. Bytes and 64-bit integers in job rows are encoded as `{"$b": base64}` and `{"$n": decimal}`; nothing goes through a JavaScript `number`.

## Recommended schema change (not made)

Job rows live in their own JSON files because the replica schema belongs to another owner. The recommended change, for sign-off before it lands, is a replica table so a send intent and its upload jobs commit in one transaction (core invariant 2):

```sql
CREATE TABLE media_upload_jobs (
  id TEXT PRIMARY KEY,                 -- logical attachment ID
  transaction_id TEXT,                 -- the send intent that owns it, if any
  source_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  kind INTEGER NOT NULL,
  byte_count INTEGER NOT NULL,
  metadata BLOB,                       -- UploadVideoMetadata / UploadVoiceMetadata, protobuf
  thumbnail_file_unique_id TEXT,
  state TEXT NOT NULL,
  sha256 BLOB,
  client_upload_id BLOB NOT NULL,
  identity_generation INTEGER NOT NULL DEFAULT 0,
  upload_id BLOB,
  part_count INTEGER,
  accepted_parts BLOB,                 -- bitmap, one bit per part
  server_expires_at INTEGER,
  complete BLOB,                       -- UploadComplete, protobuf
  failure TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  cancel_pending INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX media_upload_jobs_transaction ON media_upload_jobs(transaction_id);
```

A `MediaJobStore` over it replaces `ByteStoreJobStore`; nothing else changes.

## Verified, and only against the scripted server

Every test runs the real engine, cache, scheduler and downloader on a virtual clock against `TransferServer`, an in-memory model of the server's upload state machine and `/file` range serving, with faults: lost acknowledgement, late duplicate part, failure before a request arrives, a held request at every step with a restart, slow parts, server-side expiry, a session that cannot see an upload, wrong or changing lengths, truncated and failing bodies, rejected links. None of it has run against the real server, in a browser, or on OPFS.

Not verified:

- `OpfsByteStore` and `browserImageCodec` in any browser. `createWritable` arrived late in Safari; orientation, color space and `convertToBlob` types differ by engine.
- CORS on the media origin: `HttpRangeSource` needs `Range` and `If-Range` allowed and `Content-Range` and `ETag` exposed, or a cross-origin download cannot resume.
- The real RPC adapter: the core's `ProtocolClient.callRpc` takes no `AbortSignal`; the host must wrap it so an abort settles the promise (and a late reply is dropped).
- Hashing a 500 MB source in a worker with the JavaScript SHA-256 (correct against `node:crypto`, speed not measured).

## Do V2 sockets accept the transfer RPCs?

Yes. The V2 message handler sends every `rpcCall` to `handleRpcCall` with no method allowlist (`server/src/realtime/message.ts:224-229`); `handleRpcCall` checks only authentication (`server/src/realtime/handlers/_rpc.ts:175`) and handles all six transfer methods (`_rpc.ts:1347-1376`); the operations label their carrier `v2` (`server/src/modules/uploads/operations.ts:80, 220, 292`; `server/src/modules/files/downloads.ts:330, 369`). V2 frames may be 16 MB once authenticated (`server/src/realtime/admission.ts:5`), so a 512 KB part fits. A transfer-only V3 socket allows only these and `GET_ME` (`server/src/modules/inlineProtocol/application.ts:43-44, 363`). HTTP RPC does not: transfer methods are deliberately absent (`server/src/realtime/httpRpc.ts:44-48`, enforced at 256). `/v3/uploads/{id}` is a one-shot whole-body PUT for V3-bound keys, not resumable (`server/src/modules/inlineProtocol/uploads.ts:120-160`).

One consequence: an upload belongs to its owner, which on V3 includes the permanent auth key and on V2 does not (`operations.ts:166-170`; `server/src/db/models/inlineUploads.ts:221-223`). An upload started over V2 is invisible to the same session over V3 and the reverse. The engine handles this by replaying create, which starts a fresh upload; the old one idles out after 24 hours. Also, V2 has no replay window, so a resent transfer RPC re-executes; every transfer RPC is idempotent, so this is safe.
