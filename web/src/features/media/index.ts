/**
 * The UI side of media: `MediaSources` for the content views over the core's
 * `media` query (shared, reference-counted subscriptions and object URLs with
 * a grace period), visibility hints for one timeline, and the object URL
 * rules. Framework-free. See README.md.
 */

export {
  createCoreMediaSources,
  type CoreMediaSources,
  type CoreMediaSourcesOptions,
  MEDIA_GRACE_MS,
  MEDIA_IDLE_LIMIT,
  type MediaClient,
  type MediaEntryState,
  type MediaStats,
} from "./sources"
export {
  browserObserver,
  type CreateObserver,
  MediaVisibility,
  type MediaVisibilityOptions,
  NEARBY_MARGIN,
  type ObserverEntry,
  type ObserverLike,
} from "./visibility"
export {
  type BlobUrlApi,
  browserBlobUrls,
  countingBlobUrls,
  type CountingBlobUrls,
  isPreviewableImage,
  OPAQUE_TYPE,
  safeBlob,
  safeMediaType,
} from "./object-urls"
export { attachmentKey, fileTarget, type MediaTarget, photoTarget, refId } from "./refs"
