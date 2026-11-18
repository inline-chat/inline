import {
  INLINE_MEDIA_UPLOAD_MAX_BYTES,
  INLINE_TRANSFER_PART_SIZE,
  INLINE_UPLOAD_MAX_PARTS,
} from "@inline-chat/protocol/transfers"

/**
 * Every number here comes from the native clients or the server. The source is
 * named next to each one; change them together.
 */

/** 512 KB. `NativeUpload.swift` `partSize`; `packages/protocol/src/transfers.ts`. */
export const PART_SIZE = INLINE_TRANSFER_PART_SIZE
/** `NativeUpload.swift` `maximumPartCount`; server `INLINE_UPLOAD_MAX_PARTS`. */
export const MAX_UPLOAD_PARTS = INLINE_UPLOAD_MAX_PARTS
/** Decimal byte limits by kind. `MediaUploadLimits` in `NativeUpload.swift`. */
export const MAX_UPLOAD_BYTES = INLINE_MEDIA_UPLOAD_MAX_BYTES

/** Parts in flight across every upload. `DurableUploadCoordinator.partWindowLimits` (2...8). */
export const UPLOAD_WINDOW_MIN = 2
export const UPLOAD_WINDOW_MAX = 8
/** `DurableUploadCoordinator.initialPartWindow`. */
export const UPLOAD_WINDOW_INITIAL = 4
/** A part under this latency grows the window by one. `adaptedPartWindow`. */
export const WINDOW_GROW_BELOW_MS = 1_000
/** A part over this latency halves the window. `adaptedPartWindow`. */
export const WINDOW_SHRINK_ABOVE_MS = 2_000
/** Tries per part. `maximumPartAttempts`. */
export const MAX_PART_ATTEMPTS = 2
/** Jittered pause before a part's second try. `transferPart`: 200...400 ms. */
export const PART_RETRY_MIN_MS = 200
export const PART_RETRY_MAX_MS = 400
/** Lost finish replies reconciled through `GetUploadState`. `maximumFinishReconciliationAttempts`. */
export const MAX_FINISH_RECONCILIATIONS = 3
/** Per-RPC stall bounds, not whole-upload deadlines. `mutationTimeout`, `stateProbeTimeout`, `cancellationCleanupTimeout`. */
export const MUTATION_TIMEOUT_MS = 60_000
export const STATE_PROBE_TIMEOUT_MS = 15_000
export const CANCEL_TIMEOUT_MS = 5_000
/** Bound on processing after every byte is accepted. `processingTimeout` default (600 s). */
export const PROCESSING_TIMEOUT_MS = 600_000
/** `maximumUploadProcessingRetrySeconds`; server answers 1 s. */
export const MAX_PROCESSING_RETRY_SECONDS = 30
/** Hash read size. `hashReadSize`. */
export const HASH_READ_SIZE = 1_048_576
/** A staged source older than this cannot resume: the server's hard expiry. `staleUploadAge`; server `INLINE_UPLOAD_HARD_TTL_MS`. */
export const STALE_UPLOAD_AGE_MS = 7 * 24 * 60 * 60 * 1_000
/** A source blob with no job row older than this is an orphan. `abandonedCopyAge`. */
export const ORPHAN_BLOB_AGE_MS = 60 * 60 * 1_000

/**
 * Web-only: automatic retries of a job that failed on a transient error, with
 * exponential backoff. Swift leaves this to the send path; here the engine owns
 * it so the loop has its own cap.
 */
export const MAX_JOB_ATTEMPTS = 5
export const JOB_RETRY_BASE_MS = 2_000
export const JOB_RETRY_MAX_MS = 30_000

/** Ranges in flight per download. `NativeDownloadClient` default (4); Swift window starts at 4. */
export const DOWNLOAD_RANGES_IN_FLIGHT = 4
/** A partial download records its resume point after this many bytes. Web-only. */
export const DOWNLOAD_CHECKPOINT_BYTES = 4 * PART_SIZE

/** `MediaCacheSweep.minimumAge`, `interval`, `launchDelay`. */
export const SWEEP_MINIMUM_AGE_MS = 7 * 24 * 60 * 60 * 1_000
export const SWEEP_INTERVAL_MS = 24 * 60 * 60 * 1_000
export const SWEEP_LAUNCH_DELAY_MS = 60_000

/** `AutoDownloadSettingsManager` defaults and clamp, in MiB (1024 * 1024). */
export const AUTO_DOWNLOAD_DEFAULT_MEDIA_MB = 25
export const AUTO_DOWNLOAD_DEFAULT_FILE_MB = 10
export const AUTO_DOWNLOAD_DEFAULT_VOICE_MB = 10
export const AUTO_DOWNLOAD_MAX_MB = 2_048

/** Web-only default cache budget. The Mac client has no byte budget; it relies on the sweep and Keep Media. */
export const DEFAULT_CACHE_BUDGET_BYTES = 1024 * 1024 * 1024

/** `ImageCompressionOptions.defaultPhoto` and `.defaultPNG`. */
export const JPEG_MAX_DIMENSION = 1_600
export const JPEG_QUALITY = 0.87
export const JPEG_MIN_COMPRESSION_RATIO = 0.8
export const PNG_MAX_DIMENSION = 1_280
export const PNG_MIN_COMPRESSION_RATIO = 0.9
/** Web-only: the local placeholder an optimistic row paints in its first frame. */
export const TINY_PREVIEW_MAX_DIMENSION = 40
export const TINY_PREVIEW_QUALITY = 0.5
